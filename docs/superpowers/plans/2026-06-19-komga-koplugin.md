# Komga KOReader Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a KOReader plugin that subscribes to Komga series, downloads their unread CBZ files to a Kobo, and syncs read progress bi-directionally via Komga's REST API.

**Architecture:** All non-trivial logic lives in small pure Lua modules under `komga/` with injected dependencies (HTTP client, settings backend, filesystem), making them unit-testable with `busted` on the desktop. KOReader-bound glue (real HTTP+JSON client, DocSettings sidecar access, plugin menu/events) is thin and verified on-device. The sync orchestrator wires the pure modules together.

**Tech Stack:** Lua 5.1/LuaJIT (KOReader runtime), `busted` + `luassert` for desktop unit tests, Komga REST API (`X-API-Key` auth), KOReader plugin API (`WidgetContainer`, `LuaSettings`, `DocSettings`, `NetworkMgr` events).

---

## File Structure

```
komga.koplugin/
  _meta.lua                  -- plugin metadata (name, fullname, description)
  main.lua                   -- plugin lifecycle, menu, event handlers (KOReader glue)
  komga/
    time.lua                 -- PURE: ISO-8601 -> epoch parsing
    paths.lua                -- PURE: filename sanitization + target path building
    reconcile.lua            -- PURE: bi-directional progress conflict resolution
    diff.lua                 -- PURE: which unread books need downloading
    api.lua                  -- Komga endpoints over an injected client + DTO mapping
    client.lua               -- KOReader-bound HTTP+JSON transport (glue)
    store.lua                -- persistent state over an injected settings backend
    progress_tracker.lua     -- KOReader-bound DocSettings sidecar access (glue)
    sync.lua                 -- orchestrator: download -> reconcile -> cleanup
  spec/                      -- busted unit tests
    helpers.lua              -- in-memory fakes (client, backend, fs)
    time_spec.lua
    paths_spec.lua
    reconcile_spec.lua
    diff_spec.lua
    api_spec.lua
    store_spec.lua
    sync_spec.lua
  .busted                    -- busted config
  README.md                  -- install + usage instructions
```

**Module boundaries (interfaces other modules rely on):**

- **client** (injected into `api`): `client:get_json(path) -> table|nil, err`, `client:patch_json(path, tbl) -> ok, err`, `client:download(path, destPath) -> ok, err`.
- **backend** (injected into `store`): `backend:readSetting(key) -> value`, `backend:saveSetting(key, value)`, `backend:flush()`. (LuaSettings already implements these.)
- **fs** (injected into `sync`): `fs.exists(path) -> bool`, `fs.mkdir(path)`, `fs.rename(from, to)`, `fs.delete(path)`.
- **tracker** (injected into `sync`): `tracker:localState(rec) -> {page, ts}|nil`, `tracker:applyPage(rec, page)`.

**Normalized book shape** (produced by `api.map_book`, consumed everywhere):
```
{ id, seriesId, seriesName, title, pageCount,
  remote = { page, completed, lastModified } | nil }
```

**Manifest record shape** (stored by `store`):
```
{ id, seriesId, seriesName, title, filePath, pageCount,
  syncedPage, syncedTs, completed }
```
`syncedPage/syncedTs/completed` describe the last reconciled state. A freshly
downloaded book has `syncedTs = 0` and no local read state (so it is not treated
as a local change until actually read).

---

## Task 1: Project scaffold + test harness

**Files:**
- Create: `_meta.lua`
- Create: `.busted`
- Create: `spec/helpers.lua`
- Create: `spec/smoke_spec.lua`

- [ ] **Step 1: Install the test toolchain**

Run:
```bash
brew install lua luarocks 2>/dev/null; luarocks install busted
busted --version
```
Expected: prints a busted version (e.g. `2.x`). If `luarocks` needs sudo, use `luarocks --local install busted` and ensure `~/.luarocks/bin` is on `PATH`.

- [ ] **Step 2: Write the plugin metadata**

`_meta.lua`:
```lua
local _ = require("gettext")
return {
    name = "komga",
    fullname = _("Komga Sync"),
    description = _("Subscribe to Komga series, download unread CBZ files, and sync reading progress bi-directionally."),
}
```

- [ ] **Step 3: Write the busted config**

`.busted`:
```lua
return {
    default = {
        verbose = true,
        ROOT = { "spec" },
        lpath = "./?.lua;./?/init.lua",
    },
}
```

- [ ] **Step 4: Write shared test fakes**

`spec/helpers.lua`:
```lua
local H = {}

-- In-memory settings backend (matches LuaSettings interface used by store).
function H.fake_backend(initial)
    local data = initial or {}
    return {
        data = data,
        readSetting = function(self, k) return data[k] end,
        saveSetting = function(self, k, v) data[k] = v end,
        flush = function(self) end,
    }
end

-- In-memory Komga client. `responses` maps a path to a decoded table.
-- `calls` records every interaction for assertions.
function H.fake_client(responses)
    return {
        responses = responses or {},
        calls = {},
        get_json = function(self, path)
            table.insert(self.calls, { op = "get", path = path })
            local r = self.responses[path]
            if r == nil then return nil, "404" end
            return r
        end,
        patch_json = function(self, path, tbl)
            table.insert(self.calls, { op = "patch", path = path, body = tbl })
            return true
        end,
        download = function(self, path, dest)
            table.insert(self.calls, { op = "download", path = path, dest = dest })
            return true
        end,
    }
end

-- In-memory filesystem.
function H.fake_fs()
    return {
        existing = {},
        calls = {},
        exists = function(self, p) return self.existing[p] == true end,
        mkdir = function(self, p) table.insert(self.calls, { op = "mkdir", path = p }) end,
        rename = function(self, a, b)
            table.insert(self.calls, { op = "rename", from = a, to = b })
            self.existing[b] = true
        end,
        delete = function(self, p)
            table.insert(self.calls, { op = "delete", path = p })
            self.existing[p] = nil
        end,
    }
end

return H
```

Note: `fake_fs` returns methods callable as `fs.exists(fs, p)`. The `sync` module will call them as `fs:exists(p)` style is avoided — see Task 9, which calls `fs.exists(fs, p)`? No: `sync` calls them as plain functions `fs.exists(path)`. To keep both forms simple, `sync` receives an `fs` table whose functions take only their real args. Adjust here:

Replace the `fake_fs` body so methods take only real args (no self):
```lua
function H.fake_fs()
    local self = { existing = {}, calls = {} }
    self.exists = function(p) return self.existing[p] == true end
    self.mkdir = function(p) table.insert(self.calls, { op = "mkdir", path = p }) end
    self.rename = function(a, b)
        table.insert(self.calls, { op = "rename", from = a, to = b })
        self.existing[b] = true
    end
    self.delete = function(p)
        table.insert(self.calls, { op = "delete", path = p })
        self.existing[p] = nil
    end
    return self
end
```

- [ ] **Step 5: Write a smoke test**

`spec/smoke_spec.lua`:
```lua
local H = require("spec.helpers")

describe("test harness", function()
    it("provides a fake backend", function()
        local b = H.fake_backend({ x = 1 })
        assert.equals(1, b:readSetting("x"))
        b:saveSetting("x", 2)
        assert.equals(2, b:readSetting("x"))
    end)
end)
```

- [ ] **Step 6: Run the smoke test**

Run: `busted`
Expected: `1 success / 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add _meta.lua .busted spec/helpers.lua spec/smoke_spec.lua
git commit -m "chore: scaffold plugin metadata and busted test harness"
```

---

## Task 2: `komga/time.lua` — ISO-8601 parsing

**Files:**
- Create: `komga/time.lua`
- Test: `spec/time_spec.lua`

- [ ] **Step 1: Write the failing test**

`spec/time_spec.lua`:
```lua
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `busted spec/time_spec.lua`
Expected: FAIL — module `komga.time` not found.

- [ ] **Step 3: Implement**

`komga/time.lua`:
```lua
local Time = {}

-- Convert a broken-down UTC time table to an epoch, independent of the
-- machine's local timezone (the classic timegm trick).
local function timegm(t)
    local localEpoch = os.time(t)
    if not localEpoch then return nil end
    local utcParts = os.date("!*t", localEpoch)
    local localParts = os.date("*t", localEpoch)
    utcParts.isdst = false
    localParts.isdst = false
    local offset = os.time(localParts) - os.time(utcParts)
    return localEpoch + offset
end

-- Parse "2024-01-15T10:30:00Z" (and common variants) to an epoch (UTC).
function Time.parse_iso8601(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, se = s:match("(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not y then return nil end
    return timegm({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(se),
        isdst = false,
    })
end

return Time
```

- [ ] **Step 4: Run to verify it passes**

Run: `busted spec/time_spec.lua`
Expected: PASS (4 successes).

- [ ] **Step 5: Commit**

```bash
git add komga/time.lua spec/time_spec.lua
git commit -m "feat: add ISO-8601 to epoch parsing"
```

---

## Task 3: `komga/paths.lua` — filename sanitization + path building

**Files:**
- Create: `komga/paths.lua`
- Test: `spec/paths_spec.lua`

- [ ] **Step 1: Write the failing test**

`spec/paths_spec.lua`:
```lua
local Paths = require("komga.paths")

describe("Paths.sanitize", function()
    it("replaces filesystem-illegal characters with underscore", function()
        assert.equals("a_b_c", Paths.sanitize("a/b:c"))
        assert.equals("x_y_z_", Paths.sanitize('x?y"z|'))
    end)
    it("trims trailing whitespace", function()
        assert.equals("name", Paths.sanitize("name   "))
    end)
end)

describe("Paths.book_path", function()
    it("joins dir/series/title.cbz with sanitized parts", function()
        local p = Paths.book_path("/mnt/Komga", "Saga: Vol", "Issue #1")
        assert.equals("/mnt/Komga/Saga_ Vol/Issue #1.cbz", p)
    end)
end)

describe("Paths.parent", function()
    it("returns the directory portion of a path", function()
        assert.equals("/mnt/Komga/Saga", Paths.parent("/mnt/Komga/Saga/Issue.cbz"))
    end)
end)

describe("Paths.sidecar_dir", function()
    it("maps a .cbz path to its .sdr sidecar directory", function()
        assert.equals("/mnt/Komga/S/I.sdr", Paths.sidecar_dir("/mnt/Komga/S/I.cbz"))
    end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `busted spec/paths_spec.lua`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

`komga/paths.lua`:
```lua
local Paths = {}

function Paths.sanitize(name)
    name = tostring(name or "")
    name = name:gsub('[/\\:%*%?"<>|]', "_")
    name = name:gsub("%s+$", "")
    return name
end

function Paths.book_path(dir, series, title)
    return dir .. "/" .. Paths.sanitize(series) .. "/" .. Paths.sanitize(title) .. ".cbz"
end

function Paths.parent(path)
    return (path:gsub("/[^/]*$", ""))
end

function Paths.sidecar_dir(cbzPath)
    return (cbzPath:gsub("%.cbz$", ".sdr"))
end

return Paths
```

- [ ] **Step 4: Run to verify it passes**

Run: `busted spec/paths_spec.lua`
Expected: PASS (5 successes).

- [ ] **Step 5: Commit**

```bash
git add komga/paths.lua spec/paths_spec.lua
git commit -m "feat: add path sanitization and book path building"
```

---

## Task 4: `komga/reconcile.lua` — bi-directional conflict resolution

This is the core correctness-critical module. All four change cases plus
most-recent-wins must be covered.

**Files:**
- Create: `komga/reconcile.lua`
- Test: `spec/reconcile_spec.lua`

- [ ] **Step 1: Write the failing test**

`spec/reconcile_spec.lua`:
```lua
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
        local a = Reconcile.decide(
            record({ syncedTs = nil, syncedPage = nil }),
            nil,
            { page = 3, completed = false, ts = 50 })
        assert.equals("pull", a.type)
        assert.equals(3, a.page)
    end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `busted spec/reconcile_spec.lua`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

`komga/reconcile.lua`:
```lua
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `busted spec/reconcile_spec.lua`
Expected: PASS (8 successes).

- [ ] **Step 5: Commit**

```bash
git add komga/reconcile.lua spec/reconcile_spec.lua
git commit -m "feat: add bi-directional progress conflict resolution"
```

---

## Task 5: `komga/diff.lua` — which unread books to download

**Files:**
- Create: `komga/diff.lua`
- Test: `spec/diff_spec.lua`

- [ ] **Step 1: Write the failing test**

`spec/diff_spec.lua`:
```lua
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `busted spec/diff_spec.lua`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

`komga/diff.lua`:
```lua
local Diff = {}

-- unread:   array of normalized books (need .id)
-- manifest: table keyed by book id
-- returns:  array of books from `unread` whose id is absent from `manifest`
function Diff.to_download(unread, manifest)
    local out = {}
    for _, b in ipairs(unread) do
        if manifest[b.id] == nil then
            out[#out + 1] = b
        end
    end
    return out
end

return Diff
```

- [ ] **Step 4: Run to verify it passes**

Run: `busted spec/diff_spec.lua`
Expected: PASS (3 successes).

- [ ] **Step 5: Commit**

```bash
git add komga/diff.lua spec/diff_spec.lua
git commit -m "feat: add unread-book download diff"
```

---

## Task 6: `komga/api.lua` — endpoints + DTO mapping over injected client

**Files:**
- Create: `komga/api.lua`
- Test: `spec/api_spec.lua`

- [ ] **Step 1: Write the failing test**

`spec/api_spec.lua`:
```lua
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `busted spec/api_spec.lua`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

`komga/api.lua`:
```lua
local Api = {}
Api.__index = Api

function Api.new(client)
    return setmetatable({ client = client }, Api)
end

-- Normalize a Komga book DTO to the internal book shape.
function Api.map_book(d)
    local rp = d.readProgress
    return {
        id = d.id,
        seriesId = d.seriesId,
        seriesName = d.seriesTitle,
        title = (d.metadata and d.metadata.title) or d.name,
        pageCount = d.media and d.media.pagesCount,
        remote = rp and {
            page = rp.page,
            completed = rp.completed,
            lastModified = rp.lastModified,
        } or nil,
    }
end

function Api:list_series()
    local res = self.client:get_json("/api/v1/series?unpaged=true")
    if not res or not res.content then return {} end
    return res.content
end

function Api:unread_books(seriesId)
    local path = "/api/v1/series/" .. seriesId .. "/books?read_status=UNREAD&unpaged=true"
    local res = self.client:get_json(path)
    if not res or not res.content then return {} end
    local out = {}
    for _, dto in ipairs(res.content) do
        out[#out + 1] = Api.map_book(dto)
    end
    return out
end

function Api:get_book(bookId)
    local dto = self.client:get_json("/api/v1/books/" .. bookId)
    if not dto then return nil end
    return Api.map_book(dto)
end

function Api:set_progress(bookId, page, completed)
    return self.client:patch_json(
        "/api/v1/books/" .. bookId .. "/read-progress",
        { page = page, completed = completed })
end

function Api:download_book(bookId, destPath)
    return self.client:download("/api/v1/books/" .. bookId .. "/file", destPath)
end

return Api
```

- [ ] **Step 4: Run to verify it passes**

Run: `busted spec/api_spec.lua`
Expected: PASS (7 successes).

- [ ] **Step 5: Commit**

```bash
git add komga/api.lua spec/api_spec.lua
git commit -m "feat: add Komga REST endpoints and DTO mapping"
```

---

## Task 7: `komga/store.lua` — persistent state over injected backend

**Files:**
- Create: `komga/store.lua`
- Test: `spec/store_spec.lua`

- [ ] **Step 1: Write the failing test**

`spec/store_spec.lua`:
```lua
local Store = require("komga.store")
local H = require("spec.helpers")

local function newStore(initial)
    return Store.new(H.fake_backend(initial))
end

describe("Store config", function()
    it("reads and writes config values", function()
        local s = newStore()
        s:setConfig("server_url", "https://komga.local")
        assert.equals("https://komga.local", s:config("server_url"))
    end)
end)

describe("Store subscriptions", function()
    it("subscribes, checks, and unsubscribes series ids", function()
        local s = newStore()
        assert.is_false(s:isSubscribed("s1"))
        s:subscribe("s1")
        s:subscribe("s1") -- idempotent
        assert.is_true(s:isSubscribed("s1"))
        assert.same({ "s1" }, s:subscriptions())
        s:unsubscribe("s1")
        assert.is_false(s:isSubscribed("s1"))
    end)
end)

describe("Store books manifest", function()
    it("upserts, fetches, and removes book records", function()
        local s = newStore()
        s:upsertBook({ id = "b1", title = "T", syncedTs = 0 })
        assert.equals("T", s:getBook("b1").title)
        s:removeBook("b1")
        assert.is_nil(s:getBook("b1"))
    end)

    it("markSynced records page, ts, and completed on an existing book", function()
        local s = newStore()
        s:upsertBook({ id = "b1", title = "T", syncedTs = 0 })
        s:markSynced("b1", { page = 12, ts = 999, completed = true })
        local b = s:getBook("b1")
        assert.equals(12, b.syncedPage)
        assert.equals(999, b.syncedTs)
        assert.is_true(b.completed)
    end)
end)

describe("Store last sync", function()
    it("stores and reads the last sync timestamp", function()
        local s = newStore()
        assert.equals(0, s:lastSyncTs())
        s:setLastSyncTs(555)
        assert.equals(555, s:lastSyncTs())
    end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `busted spec/store_spec.lua`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

`komga/store.lua`:
```lua
local Store = {}
Store.__index = Store

function Store.new(backend)
    return setmetatable({ b = backend }, Store)
end

-- config -----------------------------------------------------------------
function Store:config(key)
    local cfg = self.b:readSetting("config") or {}
    return cfg[key]
end

function Store:setConfig(key, value)
    local cfg = self.b:readSetting("config") or {}
    cfg[key] = value
    self.b:saveSetting("config", cfg)
    self.b:flush()
end

-- subscriptions ----------------------------------------------------------
function Store:subscriptions()
    return self.b:readSetting("subscribed_series") or {}
end

function Store:isSubscribed(id)
    for _, s in ipairs(self:subscriptions()) do
        if s == id then return true end
    end
    return false
end

function Store:subscribe(id)
    if self:isSubscribed(id) then return end
    local subs = self:subscriptions()
    subs[#subs + 1] = id
    self.b:saveSetting("subscribed_series", subs)
    self.b:flush()
end

function Store:unsubscribe(id)
    local subs = self:subscriptions()
    local out = {}
    for _, s in ipairs(subs) do
        if s ~= id then out[#out + 1] = s end
    end
    self.b:saveSetting("subscribed_series", out)
    self.b:flush()
end

-- books manifest ---------------------------------------------------------
function Store:books()
    return self.b:readSetting("books") or {}
end

function Store:getBook(id)
    return self:books()[id]
end

function Store:upsertBook(rec)
    local books = self:books()
    books[rec.id] = rec
    self.b:saveSetting("books", books)
    self.b:flush()
end

function Store:removeBook(id)
    local books = self:books()
    books[id] = nil
    self.b:saveSetting("books", books)
    self.b:flush()
end

function Store:markSynced(id, state)
    local books = self:books()
    local rec = books[id]
    if not rec then return end
    rec.syncedPage = state.page
    rec.syncedTs = state.ts
    rec.completed = state.completed
    self.b:saveSetting("books", books)
    self.b:flush()
end

-- last sync --------------------------------------------------------------
function Store:lastSyncTs()
    return self.b:readSetting("last_sync_ts") or 0
end

function Store:setLastSyncTs(ts)
    self.b:saveSetting("last_sync_ts", ts)
    self.b:flush()
end

return Store
```

- [ ] **Step 4: Run to verify it passes**

Run: `busted spec/store_spec.lua`
Expected: PASS (5 successes).

- [ ] **Step 5: Commit**

```bash
git add komga/store.lua spec/store_spec.lua
git commit -m "feat: add persistent store for config, subscriptions, manifest"
```

---

## Task 8: `komga/sync.lua` — orchestrator

Wires together api, store, reconcile, diff, paths, tracker, and an injected fs.
Tested with fakes to verify the full download -> reconcile -> cleanup sequence.

**Files:**
- Create: `komga/sync.lua`
- Test: `spec/sync_spec.lua`

- [ ] **Step 1: Write the failing test**

`spec/sync_spec.lua`:
```lua
local Sync = require("komga.sync")
local Store = require("komga.store")
local H = require("spec.helpers")

-- A fake api with controllable responses (already-normalized books).
local function fake_api(opts)
    return {
        calls = {},
        unread_books = function(self, seriesId)
            table.insert(self.calls, { op = "unread_books", seriesId = seriesId })
            return opts.unread[seriesId] or {}
        end,
        get_book = function(self, id)
            table.insert(self.calls, { op = "get_book", id = id })
            return opts.books and opts.books[id] or nil
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
            unread = { s1 = { { id = "b1", seriesId = "s1", seriesName = "Saga", title = "Vol 1", pageCount = 10 } } },
            books = { b1 = { id = "b1", remote = nil } },
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
        store:upsertBook({ id = "b1", seriesId = "s1", seriesName = "Saga", title = "V1",
            filePath = "/Komga/Saga/V1.cbz", pageCount = 10, syncedPage = 1, syncedTs = 100 })
        local api = fake_api({
            unread = {},
            books = { b1 = { id = "b1", remote = { page = 6, completed = false, lastModified = "2024-01-15T10:30:00Z" } } },
        })
        local tracker = fake_tracker({ b1 = nil }) -- no local read since sync
        Sync.run({ api = api, store = store, tracker = tracker, fs = H.fake_fs(), now = function() return 1000 end })

        assert.equals(6, tracker.applied.b1)
        assert.equals(6, store:getBook("b1").syncedPage)
    end)

    it("pushes local progress for a book changed only on the device", function()
        local store = Store.new(H.fake_backend())
        store:setConfig("download_dir", "/Komga")
        store:upsertBook({ id = "b1", pageCount = 10, syncedPage = 1, syncedTs = 100 })
        local api = fake_api({ unread = {}, books = { b1 = { id = "b1", remote = nil } } })
        local tracker = fake_tracker({ b1 = { page = 4, ts = 500 } })
        Sync.run({ api = api, store = store, tracker = tracker, fs = H.fake_fs(), now = function() return 1000 end })

        local call = find_call(api.calls, "set_progress", "id", "b1")
        assert.is_not_nil(call)
        assert.equals(4, call.page)
    end)

    it("deletes completed-and-synced books and removes them from the manifest", function()
        local store = Store.new(H.fake_backend())
        store:setConfig("download_dir", "/Komga")
        store:upsertBook({ id = "b1", pageCount = 10, filePath = "/Komga/S/V.cbz",
            syncedPage = 10, syncedTs = 100, completed = true })
        local api = fake_api({ unread = {}, books = { b1 = { id = "b1",
            remote = { page = 10, completed = true, lastModified = "2024-01-15T10:30:00Z" } } } })
        local fs = H.fake_fs()
        Sync.run({ api = api, store = store, tracker = fake_tracker({}), fs = fs, now = function() return 1000 end })

        assert.is_not_nil(find_call(fs.calls, "delete", "path", "/Komga/S/V.cbz"))
        assert.is_nil(store:getBook("b1"))
    end)

    it("records the last sync timestamp", function()
        local store = Store.new(H.fake_backend())
        store:setConfig("download_dir", "/Komga")
        Sync.run({ api = fake_api({ unread = {} }), store = store,
            tracker = fake_tracker({}), fs = H.fake_fs(), now = function() return 4242 end })
        assert.equals(4242, store:lastSyncTs())
    end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `busted spec/sync_spec.lua`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

`komga/sync.lua`:
```lua
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `busted spec/sync_spec.lua`
Expected: PASS (5 successes).

- [ ] **Step 5: Run the full suite**

Run: `busted`
Expected: all specs pass (Tasks 1–8).

- [ ] **Step 6: Commit**

```bash
git add komga/sync.lua spec/sync_spec.lua
git commit -m "feat: add sync orchestrator (download, reconcile, cleanup)"
```

---

## Task 9: `komga/client.lua` — KOReader HTTP+JSON transport (glue)

KOReader-bound; not unit-tested (depends on KOReader's bundled `socket.http`,
`ssl.https`, `ltn12`, and `rapidjson`). Verified on-device in Task 12.

**Files:**
- Create: `komga/client.lua`

- [ ] **Step 1: Implement the client**

`komga/client.lua`:
```lua
local socket_url = require("socket.url")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local JSON = require("rapidjson")

local Client = {}
Client.__index = Client

-- baseUrl e.g. "https://komga.example.com", apiKey from settings.
function Client.new(baseUrl, apiKey)
    return setmetatable({
        baseUrl = (baseUrl or ""):gsub("/+$", ""),
        apiKey = apiKey,
    }, Client)
end

function Client:_transport(url)
    return url:match("^https://") and https or http
end

function Client:_request(method, path, bodyTbl)
    local url = self.baseUrl .. path
    local reqBody = bodyTbl and JSON.encode(bodyTbl) or nil
    local respChunks = {}
    local headers = {
        ["X-API-Key"] = self.apiKey,
        ["Accept"] = "application/json",
    }
    if reqBody then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#reqBody)
    end
    local _, status = self:_transport(url).request({
        url = url,
        method = method,
        headers = headers,
        source = reqBody and ltn12.source.string(reqBody) or nil,
        sink = ltn12.sink.table(respChunks),
    })
    return status, table.concat(respChunks)
end

function Client:get_json(path)
    local status, body = self:_request("GET", path)
    if type(status) ~= "number" or status < 200 or status >= 300 then
        return nil, tostring(status)
    end
    local ok, decoded = pcall(JSON.decode, body)
    if not ok then return nil, "json decode error" end
    return decoded
end

function Client:patch_json(path, tbl)
    local status = self:_request("PATCH", path, tbl)
    if type(status) ~= "number" or status < 200 or status >= 300 then
        return false, tostring(status)
    end
    return true
end

-- Streams the response body straight to a file (no full in-memory buffer).
function Client:download(path, destPath)
    local url = self.baseUrl .. path
    local f, ferr = io.open(destPath, "wb")
    if not f then return false, ferr end
    local _, status = self:_transport(url).request({
        url = url,
        method = "GET",
        headers = { ["X-API-Key"] = self.apiKey },
        sink = ltn12.sink.file(f),
    })
    if type(status) ~= "number" or status < 200 or status >= 300 then
        os.remove(destPath)
        return false, tostring(status)
    end
    return true
end

return Client
```

- [ ] **Step 2: Lua-syntax-check the file**

Run: `luac -p komga/client.lua 2>&1 || lua -e "loadfile('komga/client.lua')"`
Expected: no syntax errors (no output). (Requires/`rapidjson` etc. resolve only inside KOReader — that's fine; we only check syntax here.)

- [ ] **Step 3: Commit**

```bash
git add komga/client.lua
git commit -m "feat: add KOReader HTTP+JSON Komga client"
```

---

## Task 10: `komga/progress_tracker.lua` — DocSettings sidecar access (glue)

KOReader-bound; depends on `DocSettings` and `lfs`. The exact sidecar keys for
paged formats (CBZ) are centralized as constants at the top so they can be
adjusted in one place if on-device testing (Task 12) shows different keys.

**Files:**
- Create: `komga/progress_tracker.lua`

- [ ] **Step 1: Implement the tracker**

`komga/progress_tracker.lua`:
```lua
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")

-- KOReader stores the current page for paged documents (CBZ/PDF) under this
-- key. VERIFY ON DEVICE (Task 12): open a managed CBZ, turn pages, close it,
-- and inspect its .sdr/metadata.lua for the actual key; adjust if needed.
local PAGE_KEY = "last_page"

local Tracker = {}
Tracker.__index = Tracker

function Tracker.new()
    return setmetatable({}, Tracker)
end

-- Returns the device's current read state for a managed book, or nil if the
-- book has no sidecar yet (never opened => no local change).
function Tracker:localState(rec)
    if not DocSettings:hasSidecarFile(rec.filePath) then
        return nil
    end
    local ds = DocSettings:open(rec.filePath)
    local page = ds:readSetting(PAGE_KEY)
    if not page then return nil end
    local sidecar = DocSettings:getSidecarFile(rec.filePath)
    local ts = lfs.attributes(sidecar, "modification") or 0
    return { page = page, ts = ts }
end

-- Writes a pulled page into the book's sidecar so KOReader opens it there.
function Tracker:applyPage(rec, page)
    local ds = DocSettings:open(rec.filePath)
    ds:saveSetting(PAGE_KEY, page)
    if rec.pageCount and rec.pageCount > 0 then
        ds:saveSetting("percent_finished", page / rec.pageCount)
    end
    ds:flush()
end

return Tracker
```

- [ ] **Step 2: Lua-syntax-check the file**

Run: `luac -p komga/progress_tracker.lua 2>&1 || lua -e "loadfile('komga/progress_tracker.lua')"`
Expected: no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add komga/progress_tracker.lua
git commit -m "feat: add DocSettings-backed progress tracker"
```

---

## Task 11: `main.lua` — plugin lifecycle, menu, events (glue)

KOReader-bound. Provides the real `fs`, wires the client/store/tracker into
`Sync`, registers the menu, and triggers sync on the WiFi-connected event.

**Files:**
- Create: `main.lua`

- [ ] **Step 1: Implement the plugin**

`main.lua`:
```lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")

local Store = require("komga/store")
local Client = require("komga/client")
local Api = require("komga/api")
local Tracker = require("komga/progress_tracker")
local Sync = require("komga/sync")

local Komga = WidgetContainer:extend{
    name = "komga",
    is_doc_only = false,
}

-- Real filesystem adapter passed to Sync.
local function realFs()
    return {
        exists = function(p) return lfs.attributes(p, "mode") ~= nil end,
        mkdir = function(p) util.makePath(p) end,
        rename = function(a, b) os.rename(a, b) end,
        delete = function(p)
            if lfs.attributes(p, "mode") == "directory" then
                util.purgeDir(p)
            else
                os.remove(p)
            end
        end,
    }
end

function Komga:init()
    local path = DataStorage:getSettingsDir() .. "/komga.lua"
    self.store = Store.new(LuaSettings:open(path))
    if not self.store:config("download_dir") then
        self.store:setConfig("download_dir", DataStorage:getDataDir() .. "/komga")
    end
    self.tracker = Tracker.new()
    self.ui.menu:registerToMainMenu(self)
end

function Komga:_api()
    local client = Client.new(self.store:config("server_url"), self.store:config("api_key"))
    return Api.new(client), client
end

function Komga:syncNow()
    if not self.store:config("server_url") or not self.store:config("api_key") then
        UIManager:show(InfoMessage:new{ text = _("Set Komga server URL and API key first.") })
        return
    end
    UIManager:show(InfoMessage:new{ text = _("Komga: syncing…"), timeout = 2 })
    local api = self:_api()
    local ok, err = pcall(function()
        Sync.run({
            api = api, store = self.store, tracker = self.tracker,
            fs = realFs(), now = function() return os.time() end,
        })
    end)
    local msg = ok and _("Komga: sync complete.") or (_("Komga: sync failed: ") .. tostring(err))
    UIManager:show(InfoMessage:new{ text = msg })
end

-- Fires whenever WiFi connects (per the "every WiFi connect" decision).
function Komga:onNetworkConnected()
    self:syncNow()
end

function Komga:_promptValue(title, key)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = self.store:config(key) or "",
        buttons = {{
            { text = _("Cancel"), id = "cancel", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                self.store:setConfig(key, dialog:getInputText())
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Komga:_manageSeries()
    local api = self:_api()
    local ok, series = pcall(function() return api:list_series() end)
    if not ok or not series then
        UIManager:show(InfoMessage:new{ text = _("Could not fetch series from Komga.") })
        return
    end
    local items = {}
    for _, s in ipairs(series) do
        local subscribed = self.store:isSubscribed(s.id)
        items[#items + 1] = {
            text = (subscribed and "☑ " or "☐ ") .. (s.metadata and s.metadata.title or s.name),
            callback = function()
                if self.store:isSubscribed(s.id) then
                    self.store:unsubscribe(s.id)
                else
                    self.store:subscribe(s.id)
                end
                self:_manageSeries() -- refresh
            end,
        }
    end
    local menu
    menu = Menu:new{
        title = _("Select series to subscribe"),
        item_table = items,
        onMenuChoice = function(_, item) item.callback() end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function Komga:addToMainMenu(menu_items)
    menu_items.komga = {
        text = _("Komga Sync"),
        sub_item_table = {
            { text = _("Sync now"), callback = function() self:syncNow() end },
            { text = _("Manage series"), callback = function() self:_manageSeries() end },
            { text = _("Server URL"), callback = function() self:_promptValue(_("Komga server URL"), "server_url") end },
            { text = _("API key"), callback = function() self:_promptValue(_("Komga API key"), "api_key") end },
            { text = _("Download folder"), callback = function() self:_promptValue(_("Download folder"), "download_dir") end },
        },
    }
end

return Komga
```

- [ ] **Step 2: Lua-syntax-check the file**

Run: `luac -p main.lua 2>&1 || lua -e "loadfile('main.lua')"`
Expected: no syntax errors.

- [ ] **Step 3: Run the full unit suite once more**

Run: `busted`
Expected: all pure-module specs still pass.

- [ ] **Step 4: Commit**

```bash
git add main.lua
git commit -m "feat: add plugin lifecycle, menu, and WiFi-connect sync trigger"
```

---

## Task 12: README + on-device verification

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write install/usage docs**

`README.md`:
```markdown
# Komga Sync — KOReader plugin

Subscribe to Komga series, download their unread CBZ files to your Kobo, and
sync reading progress bi-directionally with your Komga server.

## Requirements
- A Kobo (or other device) running [KOReader](https://koreader.rocks).
- A Komga server (v1.x) reachable from the device, with an **API key**
  (Komga → Account Settings → Generate API Key).

## Install
1. Copy the whole `komga.koplugin` folder into KOReader's `plugins/` directory:
   - Kobo: `.adds/koreader/plugins/komga.koplugin`
2. Restart KOReader.

## Configure
Top menu → **Komga Sync**:
1. **Server URL** — e.g. `https://komga.example.com`
2. **API key** — paste your Komga API key.
3. **Download folder** — defaults to KOReader's data dir `/komga`.
4. **Manage series** — tick the series you want synced.
5. **Sync now** — runs a sync immediately.

After that, a sync runs automatically on every WiFi connection: new unread
books download, progress syncs both ways (most-recent change wins on conflict),
and finished books are removed from the device once their completion is on Komga.
```

- [ ] **Step 2: Deploy to a device/emulator and verify the round-trip**

Manual verification checklist (record results in the commit message):
1. Install per README; confirm **Komga Sync** appears in the top menu.
2. Set Server URL + API key; **Manage series** lists your Komga series and
   toggling persists across menu reopen.
3. **Sync now** downloads unread CBZs into the download folder; they open in
   KOReader.
4. **Sidecar key check:** open a downloaded CBZ, turn several pages, close it,
   then inspect `<book>.sdr/metadata.lua`. Confirm the current page is stored
   under `last_page`. If it is a different key, update `PAGE_KEY` in
   `komga/progress_tracker.lua` and re-test.
5. **Push:** after reading a few pages, trigger **Sync now**; confirm the book's
   read progress (page) updates in the Komga web UI.
6. **Pull:** change a book's progress in the Komga web UI, **Sync now**, reopen
   the book, confirm it opens at the Komga page.
7. **Conflict:** advance both sides, sync, confirm the most-recently-changed
   side wins.
8. **Cleanup:** finish a book, sync, confirm the local `.cbz` and `.sdr` are
   removed and the book is marked read on Komga.
9. **WiFi trigger:** toggle WiFi off/on; confirm a sync fires.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add install/usage README and on-device verification notes"
```

---

## Self-Review Notes (spec coverage)

- Auth via `X-API-Key` → `komga/client.lua` (Task 9).
- Native REST (no OPDS) → `komga/api.lua` (Task 6), `client.lua` (Task 9).
- Subscribe to series → `store.lua` subscriptions (Task 7), menu (Task 11).
- Download unread only → `api:unread_books` (Task 6), `Diff.to_download` (Task 5), `Sync.downloadNew` (Task 8).
- Bi-directional progress + most-recent-wins → `reconcile.lua` (Task 4), `Sync.reconcileAll` (Task 8), `progress_tracker.lua` (Task 10).
- Cleanup after completed+synced → `Sync.cleanup` (Task 8).
- Sync on every WiFi connect → `onNetworkConnected` (Task 11); manual "Sync now" (Task 11).
- `.part` temp download + rename → `Sync.downloadNew` (Task 8), `client:download` (Task 9).
- Error handling (graceful abort, local-first progress) → `syncNow` pcall (Task 11), reconcile pushes only after success (Task 8).

**Known device-dependent risk:** the paged-format sidecar page key
(`PAGE_KEY = "last_page"`) and the exact WiFi event name (`onNetworkConnected`)
are KOReader internals verified in Task 12; both are isolated to a single
constant/handler for easy adjustment.
