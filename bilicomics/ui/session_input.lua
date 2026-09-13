local bit = require("bit")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
require("ffi/posix_h")

local Input = { max_bytes = 131072 }
local extensions = { txt = true, json = true, cookies = true }
local nofollow = ffi.arch == "arm" and 32768 or 131072
local read_flags = bit.bor(ffi.C.O_RDONLY, ffi.C.O_CLOEXEC, ffi.C.O_NONBLOCK, nofollow)

local function failure(code) return nil, { kind = "session_file", code = code } end

function Input.accepts(path)
    if type(path) ~= "string" or path:find("%z") then return false end
    local extension = path:match("%.([^./]+)$")
    return extension ~= nil and extensions[extension:lower()] == true
end

function Input.read(path)
    if not Input.accepts(path) or path:sub(1, 1) ~= "/" then return failure("format") end
    local selected = lfs.symlinkattributes(path)
    if not selected or selected.mode ~= "file" then return failure("regular_file") end
    if selected.size > Input.max_bytes then return failure("size") end
    if ffi.os ~= "Linux" then return failure("read") end
    local fd = ffi.C.open(path, read_flags)
    if fd < 0 then return failure("read") end
    local ok, content, err = pcall(function()
        -- Inspect the opened object, not a path that can be replaced after selection.
        local opened = lfs.attributes("/proc/self/fd/" .. fd)
        if not opened or opened.mode ~= "file" or opened.dev ~= selected.dev or opened.ino ~= selected.ino then
            return failure("regular_file")
        end
        if opened.size > Input.max_bytes then return failure("size") end
        local buffer, parts, length = ffi.new("uint8_t[4096]"), {}, 0
        while length <= Input.max_bytes do
            local remaining = math.min(4096, Input.max_bytes + 1 - length)
            local amount = tonumber(ffi.C.read(fd, buffer, remaining))
            if amount < 0 then return failure("read") end
            if amount == 0 then break end
            length = length + amount
            if length > Input.max_bytes then return failure("size") end
            parts[#parts + 1] = ffi.string(buffer, amount)
        end
        local value = table.concat(parts)
        if #value == 0 or value:find("%z") then return failure("format") end
        return value
    end)
    ffi.C.close(fd)
    if not ok then return failure("read") end
    return content, err
end

return Input
