local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Trapper = require("ui/trapper")
local Logger = require("logger")
local NetworkMgr = require("ui/network/manager")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local ffiUtil = require("ffi/util")
local _ = require("gettext")

local Store = require("komga.store")
local Client = require("komga.client")
local Api = require("komga.api")
local Tracker = require("komga.progress_tracker")
local Sync = require("komga.sync")

local Komga = WidgetContainer:extend{
    name = "komga",
    is_doc_only = false,
}

-- Real filesystem adapter passed to Sync.
local function realFs()
    return {
        exists = function(p) return lfs.attributes(p, "mode") ~= nil end,
        mkdir = function(p) util.makePath(p) end,
        rename = function(a, b) os.rename(a, b) end,
        delete = function(p)
            if lfs.attributes(p, "mode") == "directory" then
                ffiUtil.purgeDir(p) -- recursive; util.purgeDir does not exist
            else
                os.remove(p)
            end
        end,
    }
end

function Komga:init()
    self.settings_path = DataStorage:getSettingsDir() .. "/komga.lua"
    self.store = Store.new(LuaSettings:open(self.settings_path))
    if not self.store:config("download_dir") then
        self.store:setConfig("download_dir", DataStorage:getDataDir() .. "/komga")
    end
    self.tracker = Tracker.new()
    self.ui.menu:registerToMainMenu(self)
end

function Komga:_api()
    local client = Client.new(self.store:config("server_url"), self.store:config("api_key"))
    return Api.new(client), client
end

-- Ensures WiFi is up (DNS fails otherwise), then runs the sync.
function Komga:syncNow()
    if not self.store:config("server_url") or not self.store:config("api_key") then
        UIManager:show(InfoMessage:new{ text = _("Set Komga server URL and API key first.") })
        return
    end
    if self.syncing then return end -- guard against overlapping syncs
    NetworkMgr:runWhenOnline(function() self:_runSync() end)
end

-- Runs the sync in-process (KOReader's network stack does not work in a forked
-- subprocess) but cooperatively: Trapper:wrap + Trapper:info yield to the UI
-- between books, so the UI stays responsive and the popup is dismissable.
function Komga:_runSync()
    if self.syncing then return end
    self.syncing = true

    Trapper:wrap(function()
        local ok, err = pcall(function()
            Sync.run({
                api = self:_api(), store = self.store, tracker = self.tracker,
                fs = realFs(), now = function() return os.time() end,
                log = function(m) Logger.info("KOMGA " .. m) end,
                -- Trapper:info yields to the UI and returns false if dismissed.
                progress = function(text) return Trapper:info(_("Komga: ") .. text) end,
            })
        end)
        Trapper:clear()
        self.syncing = false
        local msg = ok and _("Komga: sync complete.") or (_("Komga: sync failed: ") .. tostring(err))
        UIManager:show(InfoMessage:new{ text = msg })
    end)
end

-- Fires whenever WiFi connects (per the "every WiFi connect" decision).
-- Deferred so it never blocks startup; the sync itself runs in a subprocess.
function Komga:onNetworkConnected()
    UIManager:scheduleIn(3, function() self:syncNow() end)
end

function Komga:_promptValue(title, key)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = self.store:config(key) or "",
        buttons = {{
            { text = _("Cancel"), id = "cancel", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                self.store:setConfig(key, dialog:getInputText())
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Komga:_manageSeries()
    local api = self:_api()
    local ok, series = pcall(function() return api:list_series() end)
    if not ok or not series then
        UIManager:show(InfoMessage:new{ text = _("Could not fetch series from Komga.") })
        return
    end
    local items = {}
    for _, s in ipairs(series) do
        local subscribed = self.store:isSubscribed(s.id)
        items[#items + 1] = {
            text = (subscribed and "☑ " or "☐ ") .. (s.metadata and s.metadata.title or s.name),
            callback = function()
                if self.store:isSubscribed(s.id) then
                    self.store:unsubscribe(s.id)
                    -- Drop its downloaded books + files right away.
                    Sync.purgeUnsubscribed(self.store, realFs())
                else
                    self.store:subscribe(s.id)
                end
                self:_manageSeries() -- refresh
            end,
        }
    end
    local menu
    menu = Menu:new{
        title = _("Select series to subscribe"),
        item_table = items,
        onMenuChoice = function(_, item) item.callback() end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function Komga:addToMainMenu(menu_items)
    menu_items.komga = {
        text = _("Komga Sync"),
        sub_item_table = {
            { text = _("Sync now"), callback = function() self:syncNow() end },
            { text = _("Manage series"), callback = function() self:_manageSeries() end },
            { text = _("Server URL"), callback = function() self:_promptValue(_("Komga server URL"), "server_url") end },
            { text = _("API key"), callback = function() self:_promptValue(_("Komga API key"), "api_key") end },
            { text = _("Download folder"), callback = function() self:_promptValue(_("Download folder"), "download_dir") end },
        },
    }
end

return Komga
