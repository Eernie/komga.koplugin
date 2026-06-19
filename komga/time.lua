local Time = {}

-- Days from 1970-01-01 to y-m-d (proleptic Gregorian), Howard Hinnant's
-- algorithm. Timezone-independent: gives the exact UTC day count regardless of
-- the machine's local timezone (the previous os.time/os.date approach was off
-- by the local DST offset).
local function days_from_civil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor((y >= 0 and y or y - 399) / 400)
    local yoe = y - era * 400
    local mp = (m > 2) and (m - 3) or (m + 9)
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- Parse "2026-06-19T11:00:02Z" (and common variants) to a UTC epoch. The
-- timestamp is treated as UTC (Komga emits Z / +00:00); any offset is ignored.
function Time.parse_iso8601(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, se = s:match("(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not y then return nil end
    return days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
        + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
end

return Time
