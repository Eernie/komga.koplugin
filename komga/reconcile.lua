local Reconcile = {}

-- Furthest-progress-wins reconciliation. Whichever source has read further into
-- the book becomes the truth; the other side is brought up to it. Timestamps are
-- intentionally ignored: a newer-but-earlier position never overrides a further
-- one, so you can't lose your furthest reading spot.
--
-- A source with no progress of its own (no sidecar / no readProgress) falls back
-- to the last synced baseline, never to 0 -- otherwise an absent side would look
-- like "page 0" and wipe out the other side's real progress.
--
-- record:      { syncedPage, syncedTs, pageCount }
-- localState:  { page, ts }                       | nil
-- remoteState: { page, completed, ts }            | nil
-- returns:     { type = "push"|"pull"|"sync"|"noop", page, completed }
function Reconcile.decide(record, localState, remoteState)
    local syncedPage = record.syncedPage or 0
    local localPage = (localState and localState.page) or syncedPage
    local remotePage = (remoteState and remoteState.page) or syncedPage

    local function completedAt(page)
        return record.pageCount ~= nil and page >= record.pageCount
    end

    if localPage > remotePage then
        -- Device is further along: push its page up to the server.
        return { type = "push", page = localPage, completed = completedAt(localPage) }
    elseif remotePage > localPage then
        -- Server is further along: pull its page down to the device.
        local completed = (remoteState and remoteState.completed) or completedAt(remotePage)
        return { type = "pull", page = remotePage, completed = completed }
    else
        -- Both already agree. If that page is past the recorded baseline (e.g.
        -- both reached the end independently) record it so completed books can
        -- still be cleaned up; otherwise there's nothing to do.
        if localPage ~= syncedPage then
            local completed = completedAt(localPage) or (remoteState and remoteState.completed) or false
            return { type = "sync", page = localPage, completed = completed }
        end
        return { type = "noop" }
    end
end

return Reconcile
