local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local ffiutil = require("ffi/util")
local sha = require("ffi/sha2")

local Files = {}

function Files.component(value)
    value = tostring(assert(value, "Missing path identity"))
    assert(#value > 0 and #value <= 256, "Invalid path identity")
    return (value:gsub("[^A-Za-z0-9_-]", function(char)
        return string.format("%%%02X", char:byte())
    end))
end

function Files.parent(path)
    return assert(path:match("^(.*)/[^/]+$"), "A parent directory is required")
end

function Files.mkdir(path)
    local missing, current = {}, path:sub(1, 1) == "/" and "" or "."
    for part in path:gmatch("[^/]+") do
        current = current .. "/" .. part
        if not lfs.attributes(current) then missing[#missing + 1] = current end
    end
    assert(util.makePath(path))
    for i = #missing, 1, -1 do
        assert(ffiutil.fsyncDirectory(missing[i]))
        local parent = Files.parent(missing[i])
        assert(ffiutil.fsyncDirectory(parent == "" and "/" or parent))
    end
end

function Files.exists(path)
    return path and lfs.attributes(path, "mode") == "file"
end

function Files.size(path)
    return path and tonumber(lfs.attributes(path, "size")) or 0
end

function Files.within(path, root)
    if type(path) ~= "string" or path:find("\\", 1, true) or path:find("%z") then return false end
    for part in path:gmatch("[^/]+") do
        if part == "." or part == ".." then return false end
    end
    return path:sub(1, #root + 1) == root .. "/"
end

function Files.assertContained(path, root)
    assert(Files.within(path, root), "File escapes its storage namespace")
    local current = root
    assert(lfs.symlinkattributes(current, "mode") == "directory", "Invalid storage directory")
    local relative = path:sub(#root + 2)
    for part in relative:gmatch("[^/]+") do
        current = current .. "/" .. part
        assert(lfs.symlinkattributes(current, "mode") ~= "link", "Symbolic links are not accepted in storage")
    end
end

function Files.assertRegular(path, root)
    Files.assertContained(path, root)
    assert(lfs.attributes(path, "mode") == "file", "Expected a regular image file")
end

function Files.syncDirectory(path)
    assert(ffiutil.fsyncDirectory(path))
end

function Files.syncFile(path)
    local file = assert(io.open(path, "rb"))
    local ok, err = ffiutil.fsyncOpenedFile(file, true)
    file:close()
    assert(ok, err)
end

function Files.read(path, limit)
    local file = assert(io.open(path, "rb"))
    local value = file:read(limit and limit + 1 or "*a")
    file:close()
    assert(not limit or #value <= limit, "File exceeds its allowed size")
    return value
end

function Files.write(path, data)
    local file = assert(io.open(path, "wb"))
    local ok, err = file:write(data)
    if ok then ok, err = file:flush() end
    if ok then ok, err = ffiutil.fsyncOpenedFile(file, true) end
    local closed, close_err = file:close()
    assert(ok and closed, err or close_err)
end

function Files.atomicWrite(path, data, root)
    if root then Files.assertContained(path, root) end
    Files.mkdir(Files.parent(path))
    local temporary = path .. ".pending"
    if root then Files.assertContained(temporary, root) end
    Files.write(temporary, data)
    assert(os.rename(temporary, path))
    Files.syncDirectory(Files.parent(path))
end

function Files.digest(path)
    local file = assert(io.open(path, "rb"))
    local update, bytes = sha.sha256(), 0
    while true do
        local chunk, err = file:read(65536)
        if err then file:close(); error(err, 0) end
        if not chunk then break end
        update(chunk)
        bytes = bytes + #chunk
    end
    assert(file:close())
    assert(bytes > 0, "Image is empty")
    return update(), bytes
end

function Files.walk(root, callback)
    if lfs.symlinkattributes(root, "mode") ~= "directory" then return end
    for name in lfs.dir(root) do
        if name ~= "." and name ~= ".." then
            local path = root .. "/" .. name
            local mode = lfs.symlinkattributes(path, "mode")
            if mode == "directory" then Files.walk(path, callback)
            elseif mode == "file" then callback(path) end
        end
    end
end

return Files
