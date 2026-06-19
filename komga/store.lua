local Store = {}
Store.__index = Store

function Store.new(backend)
    return setmetatable({ b = backend }, Store)
end

-- config -----------------------------------------------------------------
function Store:config(key)
    local cfg = self.b:readSetting("config") or {}
    return cfg[key]
end

function Store:setConfig(key, value)
    local cfg = self.b:readSetting("config") or {}
    cfg[key] = value
    self.b:saveSetting("config", cfg)
    self.b:flush()
end

-- subscriptions ----------------------------------------------------------
function Store:subscriptions()
    return self.b:readSetting("subscribed_series") or {}
end

function Store:isSubscribed(id)
    for _, s in ipairs(self:subscriptions()) do
        if s == id then return true end
    end
    return false
end

function Store:subscribe(id)
    if self:isSubscribed(id) then return end
    local subs = self:subscriptions()
    subs[#subs + 1] = id
    self.b:saveSetting("subscribed_series", subs)
    self.b:flush()
end

function Store:unsubscribe(id)
    local subs = self:subscriptions()
    local out = {}
    for _, s in ipairs(subs) do
        if s ~= id then out[#out + 1] = s end
    end
    self.b:saveSetting("subscribed_series", out)
    self.b:flush()
end

-- books manifest ---------------------------------------------------------
function Store:books()
    return self.b:readSetting("books") or {}
end

function Store:getBook(id)
    return self:books()[id]
end

function Store:upsertBook(rec)
    local books = self:books()
    books[rec.id] = rec
    self.b:saveSetting("books", books)
    self.b:flush()
end

function Store:removeBook(id)
    local books = self:books()
    books[id] = nil
    self.b:saveSetting("books", books)
    self.b:flush()
end

function Store:markSynced(id, state)
    local books = self:books()
    local rec = books[id]
    if not rec then return end
    rec.syncedPage = state.page
    rec.syncedTs = state.ts
    rec.completed = state.completed
    self.b:saveSetting("books", books)
    self.b:flush()
end

-- last sync --------------------------------------------------------------
function Store:lastSyncTs()
    return self.b:readSetting("last_sync_ts") or 0
end

function Store:setLastSyncTs(ts)
    self.b:saveSetting("last_sync_ts", ts)
    self.b:flush()
end

return Store
