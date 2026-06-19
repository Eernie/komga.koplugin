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
