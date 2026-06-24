local Paths = require("komga.paths")
local Diff = require("komga.diff")
local Reconcile = require("komga.reconcile")
local Time = require("komga.time")

local Sync = {}

-- Download books that aren't in the manifest yet and aren't already finished on
-- Komga. `seriesBooks` is seriesId -> list of normalized books (pre-fetched).
-- progress(text) -> false means the user asked to stop.
-- Count books already on the device for a series that aren't finished yet.
local function unreadOnDevice(store, seriesId)
    local n = 0
    for _, rec in pairs(store:books()) do
        if rec.seriesId == seriesId and not rec.completed then n = n + 1 end
    end
    return n
end

local function downloadNew(api, store, fs, seriesBooks, progress)
    local dir = store:config("download_dir")
    -- 0 (or unset) = no limit; otherwise keep at most N unread books per series.
    local limit = tonumber(store:config("max_unread_per_series")) or 0
    for seriesId, books in pairs(seriesBooks) do
        local kept = limit > 0 and unreadOnDevice(store, seriesId) or 0
        for _, b in ipairs(books) do
            if not store:getBook(b.id) and not (b.remote and b.remote.completed) then
                if limit > 0 and kept >= limit then break end -- series cap reached
                if progress and progress(string.format("downloading %s", b.title or "")) == false then
                    return false
                end
                local path = Paths.book_path(dir, b.seriesName, b.title)
                fs.mkdir(Paths.parent(path))
                if api:download_book(b.id, path .. ".part") then
                    fs.rename(path .. ".part", path)
                    store:upsertBook({
                        id = b.id, seriesId = b.seriesId, seriesName = b.seriesName,
                        title = b.title, filePath = path, pageCount = b.pageCount,
                        syncedPage = nil, syncedTs = 0, completed = false,
                    })
                    kept = kept + 1
                end
            end
        end
    end
    return true
end

local function reconcileOne(api, store, tracker, id, rec, remoteBook)
    local remote = nil
    if remoteBook and remoteBook.remote then
        remote = {
            page = remoteBook.remote.page,
            completed = remoteBook.remote.completed,
            ts = Time.parse_iso8601(remoteBook.remote.lastModified),
        }
    end
    local localState = tracker:localState(rec)
    local action = Reconcile.decide(rec, localState, remote)
    if action.type == "push" then
        if api:set_progress(id, action.page, action.completed) then
            store:markSynced(id, { page = action.page, ts = localState.ts, completed = action.completed })
        end
    elseif action.type == "pull" then
        tracker:applyPage(rec, action.page)
        store:markSynced(id, { page = action.page, ts = remote.ts, completed = action.completed })
    end
    return action.type
end

local function reconcileAll(api, store, tracker, log, progress, seriesBooks)
    local remoteById = {}
    for _, books in pairs(seriesBooks) do
        for _, b in ipairs(books) do remoteById[b.id] = b end
    end
    local books = store:books()
    local total = 0
    for _ in pairs(books) do total = total + 1 end
    local i, n_push, n_pull, n_noop, n_err = 0, 0, 0, 0, 0
    for id, rec in pairs(books) do
        i = i + 1
        if progress and i % 25 == 0 then
            if progress(string.format("syncing %d/%d", i, total)) == false then break end
        end
        -- Isolate each book so one failure can't abort the whole reconcile.
        local ok, result = pcall(reconcileOne, api, store, tracker, id, rec, remoteById[id])
        if not ok then
            n_err = n_err + 1
            log(string.format("reconcile ERROR %s '%s': %s", tostring(id), tostring(rec.title), tostring(result)))
        elseif result == "push" then
            n_push = n_push + 1
        elseif result == "pull" then
            n_pull = n_pull + 1
        else
            n_noop = n_noop + 1
        end
    end
    log(string.format("reconcile summary: push=%d pull=%d noop=%d err=%d", n_push, n_pull, n_noop, n_err))
end

-- Remove books (manifest record + local file + sidecar) whose series is no
-- longer subscribed. Keeps the manifest in sync with the subscription set, so
-- reconcile never wastes time on (or re-creates progress for) dropped series.
function Sync.purgeUnsubscribed(store, fs, log)
    log = log or function() end
    local subscribed = {}
    for _, sid in ipairs(store:subscriptions()) do subscribed[sid] = true end
    local removed = 0
    for id, rec in pairs(store:books()) do
        if not subscribed[rec.seriesId] then
            if rec.filePath then
                fs.delete(rec.filePath)
                fs.delete(Paths.sidecar_dir(rec.filePath))
            end
            store:removeBook(id)
            removed = removed + 1
        end
    end
    if removed > 0 then log(string.format("purged %d books from unsubscribed series", removed)) end
    return removed
end

local function cleanup(store, fs)
    for id, rec in pairs(store:books()) do
        if rec.completed and rec.syncedPage and rec.pageCount and rec.syncedPage >= rec.pageCount then
            fs.delete(rec.filePath)
            fs.delete(Paths.sidecar_dir(rec.filePath))
            store:removeBook(id)
        end
    end
end

-- deps = { api, store, tracker, fs, now, log?, progress? }
-- progress(text) -> false signals a user-requested stop.
function Sync.run(deps)
    local api, store, fs = deps.api, deps.store, deps.fs
    local log = deps.log or function() end
    local progress = deps.progress
    log("sync start")
    Sync.purgeUnsubscribed(store, fs, log)
    -- One bulk fetch per subscribed series (each book carries its readProgress),
    -- so reconcile needs no per-book network calls.
    local seriesBooks = {}
    for _, sid in ipairs(store:subscriptions()) do
        if progress then progress("fetching series") end
        seriesBooks[sid] = api:series_books(sid)
    end
    downloadNew(api, store, fs, seriesBooks, progress)
    reconcileAll(api, store, deps.tracker, log, progress, seriesBooks)
    cleanup(store, fs)
    store:setLastSyncTs(deps.now())
    log("sync done")
end

return Sync
