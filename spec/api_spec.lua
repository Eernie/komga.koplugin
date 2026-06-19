local Api = require("komga.api")
local H = require("spec.helpers")

describe("Api.map_book", function()
    it("normalizes a Komga book DTO", function()
        local dto = {
            id = "b1", seriesId = "s1", seriesTitle = "My Series",
            name = "file-name", metadata = { title = "Nice Title" },
            media = { pagesCount = 22 },
            readProgress = { page = 7, completed = false, lastModified = "2024-01-15T10:30:00Z" },
        }
        local b = Api.map_book(dto)
        assert.equals("b1", b.id)
        assert.equals("s1", b.seriesId)
        assert.equals("My Series", b.seriesName)
        assert.equals("Nice Title", b.title)
        assert.equals(22, b.pageCount)
        assert.equals(7, b.remote.page)
        assert.equals("2024-01-15T10:30:00Z", b.remote.lastModified)
    end)

    it("falls back to name when metadata title is absent, and nil remote with no progress", function()
        local b = Api.map_book({ id = "b2", name = "raw", media = { pagesCount = 1 } })
        assert.equals("raw", b.title)
        assert.is_nil(b.remote)
    end)
end)

describe("Api endpoints", function()
    it("lists subscribed-able series from the paged content array", function()
        local client = H.fake_client({
            ["/api/v1/series?unpaged=true"] = { content = { { id = "s1", name = "A" }, { id = "s2", name = "B" } } },
        })
        local api = Api.new(client)
        local series = api:list_series()
        assert.equals(2, #series)
        assert.equals("s1", series[1].id)
    end)

    it("lists unread books for a series as normalized books", function()
        local client = H.fake_client({
            ["/api/v1/series/s1/books?read_status=UNREAD&unpaged=true"] =
                { content = { { id = "b1", seriesId = "s1", name = "n", media = { pagesCount = 5 } } } },
        })
        local api = Api.new(client)
        local books = api:unread_books("s1")
        assert.equals(1, #books)
        assert.equals("b1", books[1].id)
        assert.equals(5, books[1].pageCount)
    end)

    it("gets a single normalized book", function()
        local client = H.fake_client({
            ["/api/v1/books/b1"] = { id = "b1", name = "n", media = { pagesCount = 3 } },
        })
        local api = Api.new(client)
        local b = api:get_book("b1")
        assert.equals("b1", b.id)
    end)

    it("PATCHes read-progress with page and completed", function()
        local client = H.fake_client({})
        local api = Api.new(client)
        local ok = api:set_progress("b1", 9, true)
        assert.is_true(ok)
        local call = client.calls[1]
        assert.equals("patch", call.op)
        assert.equals("/api/v1/books/b1/read-progress", call.path)
        assert.equals(9, call.body.page)
        assert.is_true(call.body.completed)
    end)

    it("downloads a book file to a destination path", function()
        local client = H.fake_client({})
        local api = Api.new(client)
        local ok = api:download_book("b1", "/tmp/x.cbz")
        assert.is_true(ok)
        assert.equals("/api/v1/books/b1/file", client.calls[1].path)
        assert.equals("/tmp/x.cbz", client.calls[1].dest)
    end)
end)
