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

    it("most recent wins when both changed (local newer -> push)", function()
        local a = Reconcile.decide(record(),
            { page = 12, ts = 300 },
            { page = 4, completed = false, ts = 250 })
        assert.equals("push", a.type)
        assert.equals(12, a.page)
    end)

    it("most recent wins when both changed (remote newer -> pull)", function()
        local a = Reconcile.decide(record(),
            { page = 6, ts = 250 },
            { page = 9, completed = false, ts = 300 })
        assert.equals("pull", a.type)
        assert.equals(9, a.page)
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
