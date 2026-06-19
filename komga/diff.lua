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
