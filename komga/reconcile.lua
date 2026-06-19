local Reconcile = {}

-- record:      { syncedPage, syncedTs, pageCount }
-- localState:  { page, ts }                       | nil
-- remoteState: { page, completed, ts }            | nil
-- returns:     { type = "push"|"pull"|"noop", page, completed }
function Reconcile.decide(record, localState, remoteState)
    local syncedTs = record.syncedTs or 0

    local localChanged = localState ~= nil and (localState.ts or 0) > syncedTs
    local remoteChanged = remoteState ~= nil and (remoteState.ts or 0) > syncedTs

    if not localChanged and not remoteChanged then
        return { type = "noop" }
    end

    local function pushAction()
        local page = localState.page
        local completed = record.pageCount ~= nil and page >= record.pageCount
        return { type = "push", page = page, completed = completed }
    end

    local function pullAction()
        return { type = "pull", page = remoteState.page, completed = remoteState.completed }
    end

    if localChanged and not remoteChanged then
        return pushAction()
    elseif remoteChanged and not localChanged then
        return pullAction()
    else
        if (localState.ts or 0) >= (remoteState.ts or 0) then
            return pushAction()
        else
            return pullAction()
        end
    end
end

return Reconcile
