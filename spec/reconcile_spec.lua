local Reconcile = require("komga.reconcile")

local function record(over)
    local r = { syncedPage = 1, syncedTs = 100, pageCount = 20 }
    for k, v in pairs(over or {}) do r[k] = v end
    return r
end

describe("Reconcile.decide", function()
    it("does nothing when neither side changed", function()
        local a = Reconcile.decide(record(), nil, nil)
        assert.equals("noop", a.type)
    end)

    it("pushes when only local changed", function()
        local a = Reconcile.decide(record(), { page = 5, ts = 200 }, nil)
        assert.equals("push", a.type)
        assert.equals(5, a.page)
        assert.is_false(a.completed)
    end)

    it("marks completed on push when local reached the last page", function()
        local a = Reconcile.decide(record(), { page = 20, ts = 200 }, nil)
        assert.equals("push", a.type)
        assert.is_true(a.completed)
    end)

    it("pulls when only remote changed", function()
        local a = Reconcile.decide(record(), nil,
            { page = 8, completed = false, ts = 200 })
        assert.equals("pull", a.type)
        assert.equals(8, a.page)
    end)

    it("furthest wins when both changed (local further -> push)", function()
        local a = Reconcile.decide(record(),
            { page = 12, ts = 300 },
            { page = 4, completed = false, ts = 250 })
        assert.equals("push", a.type)
        assert.equals(12, a.page)
    end)

    it("furthest wins when both changed (remote further -> pull)", function()
        local a = Reconcile.decide(record(),
            { page = 6, ts = 250 },
            { page = 9, completed = false, ts = 300 })
        assert.equals("pull", a.type)
        assert.equals(9, a.page)
    end)

    it("furthest wins even when it is the older change (local further but stale -> push)", function()
        -- Local read further (page 12) but its save is older than the remote's.
        -- Timestamp is ignored; the furthest position must survive.
        local a = Reconcile.decide(record(),
            { page = 12, ts = 100 },
            { page = 4, completed = false, ts = 999 })
        assert.equals("push", a.type)
        assert.equals(12, a.page)
    end)

    it("furthest wins even when it is the older change (remote further but stale -> pull)", function()
        local a = Reconcile.decide(record(),
            { page = 3, ts = 999 },
            { page = 15, completed = false, ts = 100 })
        assert.equals("pull", a.type)
        assert.equals(15, a.page)
    end)

    it("never regresses to a lower remote page (server moved backward -> push)", function()
        -- Device at the synced baseline (no new local read), server jumped back
        -- below it. Furthest wins keeps the device's further position.
        local a = Reconcile.decide(record({ syncedPage = 10 }),
            { page = 10, ts = 100 },
            { page = 3, completed = false, ts = 999 })
        assert.equals("push", a.type)
        assert.equals(10, a.page)
    end)

    it("records the baseline when both sides already agree past it (sync)", function()
        -- Both reached the last page independently; nothing to push or pull, but
        -- the manifest must learn it's finished so cleanup can delete it.
        local a = Reconcile.decide(record(),
            { page = 20, ts = 300 },
            { page = 20, completed = true, ts = 300 })
        assert.equals("sync", a.type)
        assert.equals(20, a.page)
        assert.is_true(a.completed)
    end)

    it("does nothing when both agree at the synced baseline", function()
        local a = Reconcile.decide(record({ syncedPage = 7 }),
            { page = 7, ts = 50 },
            { page = 7, completed = false, ts = 50 })
        assert.equals("noop", a.type)
    end)

    it("treats a missing synced baseline as 0 (first sync, remote only)", function()
        -- Record with no syncedTs/syncedPage baseline (e.g. freshly downloaded).
        local a = Reconcile.decide(
            { pageCount = 20 },
            nil,
            { page = 3, completed = false, ts = 50 })
        assert.equals("pull", a.type)
        assert.equals(3, a.page)
    end)
end)
