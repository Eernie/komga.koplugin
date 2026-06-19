local Diff = require("komga.diff")

describe("Diff.to_download", function()
    it("returns books not present in the manifest", function()
        local unread = { { id = "a" }, { id = "b" }, { id = "c" } }
        local manifest = { a = { id = "a" } }
        local out = Diff.to_download(unread, manifest)
        assert.equals(2, #out)
        assert.equals("b", out[1].id)
        assert.equals("c", out[2].id)
    end)

    it("returns everything when manifest is empty", function()
        local out = Diff.to_download({ { id = "x" } }, {})
        assert.equals(1, #out)
    end)

    it("returns nothing when all are present", function()
        local out = Diff.to_download({ { id = "x" } }, { x = { id = "x" } })
        assert.equals(0, #out)
    end)
end)
