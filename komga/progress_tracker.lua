local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")

-- KOReader stores the current 1-based page for paged documents (CBZ/PDF) under
-- this key. Verified on-device: a CBZ sidecar (metadata.cbz.lua) contains
-- ["last_page"] alongside ["doc_pages"].
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
    -- findSidecarFile returns the metadata.*.lua path; its mtime marks when
    -- progress was last saved (i.e. when the book was last read).
    local sidecar = DocSettings:findSidecarFile(rec.filePath)
    local ts = (sidecar and lfs.attributes(sidecar, "modification")) or 0
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

-- Pre-configure the reader for a freshly downloaded book based on the Komga
-- series readingDirection, by writing the matching keys into its sidecar:
--   RIGHT_TO_LEFT  -> right-to-left page turning (manga)
--   WEBTOON/VERTICAL -> continuous vertical scroll, fit-width (webtoon)
-- Only touches a book with no sidecar yet, so it never overrides a book the
-- user has already opened and adjusted.
function Tracker:applyReadingDirection(filePath, direction)
    if not direction then return end
    if DocSettings:hasSidecarFile(filePath) then return end
    local ds = DocSettings:open(filePath)
    if direction == "RIGHT_TO_LEFT" then
        ds:saveSetting("inverse_reading_order", true)
    elseif direction == "WEBTOON" or direction == "VERTICAL" then
        ds:saveSetting("kopt_page_scroll", 1)       -- continuous scroll
        ds:saveSetting("kopt_zoom_mode_genus", 4)   -- page
        ds:saveSetting("kopt_zoom_mode_type", 1)    -- width (fit-width)
        ds:saveSetting("kopt_page_gap_height", 0)   -- seamless: no gap between pages
        ds:saveSetting("show_overlap_enable", true) -- keep some overlap when scrolling
    else
        return -- LEFT_TO_RIGHT / unknown: leave defaults, nothing to write
    end
    ds:flush()
end

return Tracker
