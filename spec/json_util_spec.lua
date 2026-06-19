local JsonUtil = require("komga.json_util")

-- Stand-in for rapidjson.null: a unique singleton value (rapidjson uses a
-- userdata; here a unique table serves the same identity-comparison role).
local NULL = setmetatable({}, { __tostring = function() return "null" end })

describe("JsonUtil.denull", function()
    it("removes top-level null-sentinel fields", function()
        local t = JsonUtil.denull({ a = 1, b = NULL }, NULL)
        assert.equals(1, t.a)
        assert.is_nil(t.b)
    end)

    it("removes nested null-sentinel fields", function()
        local t = JsonUtil.denull(
            { readProgress = NULL, media = { pagesCount = NULL, x = 5 } }, NULL)
        assert.is_nil(t.readProgress)
        assert.is_nil(t.media.pagesCount)
        assert.equals(5, t.media.x)
    end)

    it("walks into array elements", function()
        local t = JsonUtil.denull(
            { content = { { id = "a", rp = NULL }, { id = "b", rp = { page = 3 } } } }, NULL)
        assert.is_nil(t.content[1].rp)
        assert.equals(3, t.content[2].rp.page)
    end)

    it("leaves non-null values untouched and returns the same table", function()
        local inp = { a = "s", n = 3, sub = { b = true } }
        local out = JsonUtil.denull(inp, NULL)
        assert.equals(inp, out)
        assert.equals("s", out.a)
        assert.is_true(out.sub.b)
    end)

    it("handles non-table input", function()
        assert.equals(5, JsonUtil.denull(5, NULL))
        assert.is_nil(JsonUtil.denull(nil, NULL))
    end)
end)
