local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
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

local DEFAULT_SYNC_INTERVAL = 24 * 3600 -- seconds

-- Fires whenever WiFi connects. A full sync (downloads + reconcile-all) only
-- runs if it's been at least the configured interval since the last one, so we
-- don't re-sync on every reconnect (closing a book turns WiFi on, too). Per-book
-- progress is already pushed immediately by onCloseDocument; manual "Sync now"
-- always runs regardless of the interval.
function Komga:onNetworkConnected()
    local interval = self.store:config("sync_interval") or DEFAULT_SYNC_INTERVAL
    if os.time() - self.store:lastSyncTs() < interval then return end
    UIManager:scheduleIn(3, function() self:syncNow() end)
end

function Komga:_bookByPath(path)
    for _, rec in pairs(self.store:books()) do
        if rec.filePath == path then return rec end
    end
    return nil
end

-- When a managed comic is closed, push just that book's progress to Komga right
-- away -- but only if already online (no WiFi prompt). KOReader has already
-- saved the sidecar by the time CloseDocument fires, so the page is current.
-- If offline, the next full sync picks it up.
function Komga:onCloseDocument()
    local doc = self.ui and self.ui.document
    local path = doc and doc.file
    if not path then return end
    local rec = self:_bookByPath(path)
    if not rec then return end
    local server_url = self.store:config("server_url")
    local api_key = self.store:config("api_key")
    if not server_url or not api_key then return end
    local ls = self.tracker:localState(rec)
    if not ls then return end

    -- Capture everything up front: by the time WiFi connects and the callback
    -- runs, the reader (and this plugin instance) may already be torn down.
    local bookId, page = rec.id, ls.page
    local completed = rec.pageCount ~= nil and ls.page >= rec.pageCount
    local function push()
        local ok, err = pcall(function()
            Api.new(Client.new(server_url, api_key)):set_progress(bookId, page, completed)
        end)
        if not ok then
            Logger.info("KOMGA close-push failed book=" .. tostring(bookId) .. " err=" .. tostring(err))
        end
    end

    if NetworkMgr:isOnline() then
        push()
    else
        -- User chose: turn WiFi on to push on close.
        NetworkMgr:turnOnWifiAndWaitForConnection(push)
    end
end

function Komga:_settingsDialog()
    local interval_hours = (self.store:config("sync_interval") or DEFAULT_SYNC_INTERVAL) / 3600
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Komga settings"),
        fields = {
            { description = _("Server URL"), text = self.store:config("server_url") or "",
              hint = "https://komga.example.com" },
            { description = _("API key"), text = self.store:config("api_key") or "",
              hint = _("X-API-Key") },
            { description = _("Download folder"), text = self.store:config("download_dir") or "",
              hint = "/mnt/onboard/komga" },
            { description = _("Min hours between WiFi syncs"), text = tostring(interval_hours),
              input_type = "number", hint = "24" },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                local f = dialog:getFields()
                self.store:setConfig("server_url", f[1])
                self.store:setConfig("api_key", f[2])
                self.store:setConfig("download_dir", f[3])
                local hours = tonumber(f[4]) or 24
                self.store:setConfig("sync_interval", math.floor(hours * 3600))
                UIManager:close(dialog)
                UIManager:show(InfoMessage:new{ text = _("Komga settings saved.") })
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
            { text = _("Settings"), callback = function() self:_settingsDialog() end },
        },
    }
end

return Komga
