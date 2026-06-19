local Time = require("komga.time")

describe("Time.parse_iso8601", function()
    it("returns nil for nil/garbage input", function()
        assert.is_nil(Time.parse_iso8601(nil))
        assert.is_nil(Time.parse_iso8601("not a date"))
    end)

    it("parses a UTC timestamp to a positive epoch", function()
        local t = Time.parse_iso8601("2024-01-15T10:30:00Z")
        assert.is_number(t)
        assert.is_true(t > 0)
    end)

    it("parses to the exact UTC epoch, independent of local timezone", function()
        -- 2026-06-19T11:00:02Z == 1781866802. Must hold regardless of the test
        -- machine's TZ/DST (the old parser was an hour off under DST).
        assert.equals(1781866802, Time.parse_iso8601("2026-06-19T11:00:02Z"))
        assert.equals(1704067200, Time.parse_iso8601("2024-01-01T00:00:00Z"))
    end)

    it("orders later timestamps after earlier ones", function()
        local a = Time.parse_iso8601("2024-01-15T10:30:00Z")
        local b = Time.parse_iso8601("2024-01-15T10:30:05Z")
        assert.is_true(b > a)
    end)

    it("tolerates fractional seconds and offsets", function()
        assert.is_number(Time.parse_iso8601("2024-01-15T10:30:00.123Z"))
        assert.is_number(Time.parse_iso8601("2024-01-15T10:30:00+00:00"))
    end)
end)
