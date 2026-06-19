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
