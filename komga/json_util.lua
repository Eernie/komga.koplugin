local JsonUtil = {}

-- Recursively replace every occurrence of `nullSentinel` with nil. This exists
-- because rapidjson decodes JSON `null` to a userdata sentinel (rapidjson.null)
-- that is truthy in Lua; the rest of the plugin assumes JSON null == Lua nil.
-- Converting at the decode boundary keeps all downstream code null-safe.
function JsonUtil.denull(v, nullSentinel)
    if type(v) ~= "table" then return v end
    for k, val in pairs(v) do
        if val == nullSentinel then
            v[k] = nil
        elseif type(val) == "table" then
            JsonUtil.denull(val, nullSentinel)
        end
    end
    return v
end

return JsonUtil
