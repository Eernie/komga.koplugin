local Paths = require("komga.paths")
local Diff = require("komga.diff")
local Reconcile = require("komga.reconcile")
local Time = require("komga.time")

local Sync = {}

local function downloadNew(api, store, fs)
    local dir = store:config("download_dir")
    for _, seriesId in ipairs(store:subscriptions()) do
        local unread = api:unread_books(seriesId)
        for _, b in ipairs(Diff.to_download(unread, store:books())) do
            local path = Paths.book_path(dir, b.seriesName, b.title)
            fs.mkdir(Paths.parent(path))
            local ok = api:download_book(b.id, path .. ".part")
            if ok then
                fs.rename(path .. ".part", path)
                store:upsertBook({
                    id = b.id, seriesId = b.seriesId, seriesName = b.seriesName,
                    title = b.title, filePath = path, pageCount = b.pageCount,
                    syncedPage = nil, syncedTs = 0, completed = false,
                })
            end
        end
    end
end

local function reconcileAll(api, store, tracker)
    for id, rec in pairs(store:books()) do
        local book = api:get_book(id)
        local remote = nil
        if book and book.remote then
            remote = {
                page = book.remote.page,
                completed = book.remote.completed,
                ts = Time.parse_iso8601(book.remote.lastModified),
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
    end
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

-- deps = { api, store, tracker, fs, now }
function Sync.run(deps)
    downloadNew(deps.api, deps.store, deps.fs)
    reconcileAll(deps.api, deps.store, deps.tracker)
    cleanup(deps.store, deps.fs)
    deps.store:setLastSyncTs(deps.now())
end

return Sync
