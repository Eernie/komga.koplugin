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
