local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local JSON = require("rapidjson")
local logger = require("logger")
local JsonUtil = require("komga.json_util")

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
        logger.info("KOMGA http GET " .. path .. " -> " .. tostring(status))
        return nil, tostring(status)
    end
    local ok, decoded = pcall(JSON.decode, body)
    if not ok then return nil, "json decode error" end
    -- rapidjson decodes JSON null to a truthy userdata sentinel; normalize to nil.
    return JsonUtil.denull(decoded, JSON.null)
end

function Client:patch_json(path, tbl)
    local status = self:_request("PATCH", path, tbl)
    if type(status) ~= "number" or status < 200 or status >= 300 then
        logger.info("KOMGA http PATCH " .. path .. " -> " .. tostring(status))
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
