-- Two real test-env processes start from the same cold cache. The test delays
-- the actual rename syscall result to make the previous replacement race wide.
local root, module_dir, private, output, worker = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4]), assert(arg[5])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local ffi = require("ffi")
require("ffi/posix_h")
ffi.cdef[[int usleep(unsigned int usec);]]
ffi.cdef[[int biliwasm_run(const char *path, const char *request, char **output);]]
local real = ffi.C
local JSON = require("bilicomics/protocol/json")
local ready = false
package.loaded.android = { dir = private }
ffi.C = setmetatable({}, { __index = function(_, name)
    if name == "open" then
        return function(path, ...)
            local fd = real.open(path, ...)
            if fd >= 0 and path == module_dir .. "/native/bin/android-x86_64/libbiliwasm.so" and not ready then
                ready = true
                local file = assert(io.open(output .. "/ready-" .. worker, "wb")); file:write("ready"); file:close()
                local started = false
                for _ = 1, 20000 do
                    file = io.open(output .. "/start", "rb")
                    if file then file:close(); started = true; break end
                    real.usleep(1000)
                end
                assert(started, "The race start barrier timed out")
            end
            return fd
        end
    elseif name == "renameat" then
        return function(...)
            local result = real.renameat(...)
            if result == 0 then
                local file = assert(io.open(output .. "/published-" .. worker, "wb")); file:write("published"); file:close()
                real.usleep(700000)
            end
            return result
        end
    end
    return real[name]
end })
local library, detail = require("bilicomics/protocol/native_library").load("libbiliwasm.so", {
    module_dir = module_dir, target = "android-x86_64",
})
ffi.C = real
assert(library, detail and detail.message)
assert(library.biliwasm_run)
local file = assert(io.open(output .. "/worker-" .. worker .. ".json", "wb"))
file:write(assert(JSON.encode({ loaded = true, detail = detail }))); file:close()
