local ffi = require("ffi")
require("ffi/posix_h")
local Util = require("bilicomics/util")

local Budget = { default_minimum = 64 * 1024 * 1024, default_image_limit = 32 * 1024 * 1024 }

function Budget.available(path)
    local ok, available = pcall(function()
        local status = ffi.new("struct statvfs[1]")
        if ffi.C.statvfs(path, status) ~= 0 then return nil end
        local bytes = tonumber(status[0].f_bavail) * tonumber(status[0].f_frsize)
        if bytes < 0 or bytes >= math.huge then return nil end
        return bytes
    end)
    if not ok or not available then return nil, Util.error("storage", "Available storage could not be determined.") end
    return available
end

function Budget.check(path, minimum, expected_write)
    local available, err = Budget.available(path)
    if not available then return nil, err end
    local required = math.max(0, minimum or Budget.default_minimum) + math.max(0, expected_write or 0)
    if available < required then
        return nil, Util.error("low_space", "Free storage is insufficient for another image. Remove downloads or automatic cache, then resume.",
            { available_bytes = available, required_bytes = required })
    end
    return true
end

return Budget
