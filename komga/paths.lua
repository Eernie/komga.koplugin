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
