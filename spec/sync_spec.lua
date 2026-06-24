local Sync = require("komga.sync")
local Store = require("komga.store")
local H = require("spec.helpers")

-- A fake api. opts.series maps seriesId -> list of normalized books (each may
-- carry a `remote` table), as returned by api:series_books.
local function fake_api(opts)
    return {
        calls = {},
        list_series = function(self)
            return opts.series_list or {}
        end,
        series_books = function(self, seriesId)
            table.insert(self.calls, { op = "series_books", seriesId = seriesId })
            return (opts.series and opts.series[seriesId]) or {}
        end,
        set_progress = function(self, id, page, completed)
            table.insert(self.calls, { op = "set_progress", id = id, page = page, completed = completed })
            return true
        end,
        download_book = function(self, id, dest)
            table.insert(self.calls, { op = "download_book", id = id, dest = dest })
            return true
        end,
    }
end

local function fake_tracker(states)
    return {
        applied = {},
        localState = function(self, rec) return states[rec.id] end,
        applyPage = function(self, rec, page) self.applied[rec.id] = page end,
    }
end

local function find_call(calls, op, key, val)
    for _, c in ipairs(calls) do
        if c.op == op and (key == nil or c[key] == val) then return c end
    end
    return nil
end

describe("Sync.run", function()
    it("downloads new unread books and records them in the manifest", function()
        local store = Store.new(H.fake_backend())
        store:setConfig("download_dir", "/Komga")
        store:subscribe("s1")
        local api = fake_api({
            series = { s1 = { { id = "b1", seriesId = "s1", seriesName = "Saga", title = "Vol 1", pageCount = 10, remote = nil } } },
        })
        local fs = H.fake_fs()
        Sync.run({ api = api, store = store, tracker = fake_tracker({}), fs = fs, now = function() return 1000 end })

        assert.is_not_nil(find_call(api.calls, "download_book", "id", "b1"))
        assert.is_not_nil(find_call(fs.calls, "rename"))
        local rec = store:getBook("b1")
        assert.is_not_nil(rec)
        assert.equals("/Komga/Saga/Vol 1.cbz", rec.filePath)
    end)

    it("pulls remote progress for a book changed only on the server", function()
        local store = Store.new(H.fake_backend())
        store:setConfig("download_dir", "/Komga")
        store:subscribe("s1")
        store:upsertBook({ id = "b1", seriesId = "s1", seriesName = "Saga", title = "V1",
            filePath = "/Komga/Saga/V1.cbz", pageCount = 10, syncedPage = 1, syncedTs = 100 })
        local api = fake_api({
            series = { s1 = { { id = "b1", seriesId = "s1",
                remote = { page = 6, completed = false, lastModified = "2024-01-15T10:30:00Z" } } } },
        })
        local tracker = fake_tracker({ b1 = nil }) -- no local read since sync
        Sync.run({ api = api, store = store, tracker = tracker, fs = H.fake_fs(), now = function() return 1000 end })

        assert.equals(6, tracker.applied.b1)
        assert.equals(6, store:getBook("b1").syncedPage)
    end)

    it("pushes local progress for a book changed only on the device", function()
        local store = Store.new(H.fake_backend())
        store:setConfig("download_dir", "/Komga")
        store:subscribe("s1")
        store:upsertBook({ id = "b1", seriesId = "s1", pageCount = 10, syncedPage = 1, syncedTs = 100 })
        local api = fake_api({ series = { s1 = { { id = "b1", seriesId = "s1", remote = nil } } } })
        local tracker = fake_tracker({ b1 = { page = 4, ts = 500 } })
        Sync.run({ api = api, store = store, tracker = tracker, fs = H.fake_fs(), now = function() return 1000 end })

        local call = find_call(api.calls, "set_progress", "id", "b1")
        assert.is_not_nil(call)
        assert.equals(4, call.page)
    end)

    it("deletes completed-and-synced books and removes them from the manifest", function()
        local store = Store.new(H.fake_backend())
        store:setConfig("download_dir", "/Komga")
        store:subscribe("s1")
        store:upsertBook({ id = "b1", seriesId = "s1", pageCount = 10, filePath = "/Komga/S/V.cbz",
            syncedPage = 10, syncedTs = 100, completed = true })
        local api = fake_api({ series = { s1 = { { id = "b1", seriesId = "s1",
            remote = { page = 10, completed = true, lastModified = "2024-01-15T10:30:00Z" } } } } })
        local fs = H.fake_fs()
        Sync.run({ api = api, store = store, tracker = fake_tracker({}), fs = fs, now = function() return 1000 end })

        assert.is_not_nil(find_call(fs.calls, "delete", "path", "/Komga/S/V.cbz"))
        assert.is_nil(store:getBook("b1"))
    end)

    it("purges books from unsubscribed series (manifest + files) on sync", function()
        local store = Store.new(H.fake_backend())
        store:setConfig("download_dir", "/Komga")
        store:subscribe("s1")
        store:upsertBook({ id = "keep", seriesId = "s1", filePath = "/Komga/A/1.cbz", pageCount = 5 })
        store:upsertBook({ id = "drop", seriesId = "s2", filePath = "/Komga/B/1.cbz", pageCount = 5 })
        local fs = H.fake_fs()
        local api = fake_api({ series = { s1 = { { id = "keep", seriesId = "s1", remote = nil } } } })
        Sync.run({ api = api, store = store, tracker = fake_tracker({}), fs = fs, now = function() return 1 end })

        assert.is_not_nil(store:getBook("keep"))
        assert.is_nil(store:getBook("drop"))
        assert.is_not_nil(find_call(fs.calls, "delete", "path", "/Komga/B/1.cbz"))
    end)

    it("caps downloads at max_unread_per_series (next N in order)", function()
        local store = Store.new(H.fake_backend())
        store:setConfig("download_dir", "/Komga")
        store:setConfig("max_unread_per_series", 2)
        store:subscribe("s1")
        local books = {}
        for i = 1, 5 do
            books[i] = { id = "b" .. i, seriesId = "s1", seriesName = "S", title = "V" .. i, pageCount = 10, remote = nil }
        end
        local api = fake_api({ series = { s1 = books } })
        Sync.run({ api = api, store = store, tracker = fake_tracker({}), fs = H.fake_fs(), now = function() return 1 end })

        local dl = 0
        for _, c in ipairs(api.calls) do if c.op == "download_book" then dl = dl + 1 end end
        assert.equals(2, dl)
        assert.is_not_nil(store:getBook("b1"))
        assert.is_not_nil(store:getBook("b2"))
        assert.is_nil(store:getBook("b3"))
    end)

    it("refills toward the cap as earlier books are finished/removed", function()
        local store = Store.new(H.fake_backend())
        store:setConfig("download_dir", "/Komga")
        store:setConfig("max_unread_per_series", 2)
        store:subscribe("s1")
        -- already one unread on device -> only one more should download
        store:upsertBook({ id = "b1", seriesId = "s1", title = "V1", filePath = "/Komga/S/V1.cbz", pageCount = 10, completed = false })
        local books = {}
        for i = 1, 5 do
            books[i] = { id = "b" .. i, seriesId = "s1", seriesName = "S", title = "V" .. i, pageCount = 10, remote = nil }
        end
        local api = fake_api({ series = { s1 = books } })
        Sync.run({ api = api, store = store, tracker = fake_tracker({}), fs = H.fake_fs(), now = function() return 1 end })

        local dl = 0
        for _, c in ipairs(api.calls) do if c.op == "download_book" then dl = dl + 1 end end
        assert.equals(1, dl)
    end)

    it("prepares reader settings from the series reading direction on download", function()
        local store = Store.new(H.fake_backend())
        store:setConfig("download_dir", "/Komga")
        store:subscribe("s1")
        local api = fake_api({
            series = { s1 = { { id = "b1", seriesId = "s1", seriesName = "Manga", title = "V1", pageCount = 10 } } },
            series_list = { { id = "s1", metadata = { readingDirection = "RIGHT_TO_LEFT" } } },
        })
        local prepared = {}
        Sync.run({ api = api, store = store, tracker = fake_tracker({}), fs = H.fake_fs(),
            now = function() return 1 end,
            prepareReader = function(path, dir) prepared[#prepared + 1] = { path = path, dir = dir } end })

        assert.equals(1, #prepared)
        assert.equals("RIGHT_TO_LEFT", prepared[1].dir)
        assert.equals("/Komga/Manga/V1.cbz", prepared[1].path)
    end)

    it("records the last sync timestamp", function()
        local store = Store.new(H.fake_backend())
        store:setConfig("download_dir", "/Komga")
        Sync.run({ api = fake_api({}), store = store,
            tracker = fake_tracker({}), fs = H.fake_fs(), now = function() return 4242 end })
        assert.equals(4242, store:lastSyncTs())
    end)
end)
