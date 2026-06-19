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

-- In-memory filesystem. Functions take only their real args (no self), matching
-- how komga/sync.lua invokes them (fs.exists(p), fs.mkdir(p), ...).
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

return H
