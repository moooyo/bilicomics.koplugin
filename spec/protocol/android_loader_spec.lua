-- Filesystem and race-defense checks run on test-env. Actual Bionic execution
-- is verified separately inside the official Android APK.
local root, output = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local ffi = require("ffi")
require("ffi/posix_h")
ffi.cdef[[int chmod(const char *path, unsigned int mode);]]
local lfs = require("libs/libkoreader-lfs")
local JSON = require("bilicomics/protocol/json")
local sha256 = require("ffi/sha2").sha256
local Util = require("util")
local real_load = ffi.load
local target = "android-x86_64"
local passed, serial = {}, 0

local function read(path)
    local file = assert(io.open(path, "rb"))
    local bytes = file:read("*a"); file:close()
    return bytes
end
local function write(path, bytes, private)
    local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
    if private then assert(ffi.C.chmod(path, 384) == 0) end
end
local function mkdir(path, private)
    Util.makePath(path)
    if private then assert(ffi.C.chmod(path, 448) == 0) end
end
local function fdCount()
    local count = 0
    for name in lfs.dir("/proc/self/fd") do if tonumber(name) then count = count + 1 end end
    return count
end
local function fixture()
    serial = serial + 1
    local base = output .. "/case-" .. serial
    local private = base .. "/private"
    local module = base .. "/protocol"
    mkdir(private, true); mkdir(module .. "/native/portable")
    mkdir(module .. "/native/bin/" .. target)
    local records = {}
    for _, name in ipairs({ "libbiliwasm.so", "libbilicrypto.so" }) do
        local bytes = "Verified synthetic native bytes " .. serial .. " " .. name
        local hash = sha256(bytes)
        local source = module .. "/native/bin/" .. target .. "/" .. name
        local destination = private .. "/bilicomics-native/" .. target .. "/" .. hash .. "/" .. name
        write(source, bytes)
        records[name] = { bytes = bytes, hash = hash, source = source, destination = destination }
        local portable = name == "libbilicrypto.so"
        local entry = { sha256 = hash, bytes = #bytes, path = (portable and "../bin/" or "bin/") .. target .. "/" .. name }
        local manifest = module .. (portable and "/native/portable/manifest.json" or "/native/manifest.json")
        write(manifest, assert(JSON.encode({ libraries = { [target] = entry } })))
    end
    package.loaded.android = { dir = private }
    package.loaded["bilicomics/protocol/native_library"] = nil
    local loader = require("bilicomics/protocol/native_library")
    local function load(name)
        return loader.load(name or "libbiliwasm.so", { module_dir = module, target = target })
    end
    local function prepare(name)
        local record = records[name or "libbiliwasm.so"]
        mkdir(private .. "/bilicomics-native", true)
        mkdir(private .. "/bilicomics-native/" .. target, true)
        mkdir(record.destination:match("^(.*)/[^/]+$"), true)
        return record
    end
    return { base = base, private = private, module = module, records = records, load = load, prepare = prepare }
end
local function test(name, fn)
    local ok, err = pcall(fn)
    ffi.load = real_load
    assert(ok, name .. ": " .. tostring(err))
    passed[#passed + 1] = name
    print("PASS " .. name)
end
local function rejected(case, code)
    local before = fdCount()
    local value, err = case.load()
    assert(value == nil and err and err.code == code, "Unexpected rejection: " .. tostring(err and err.code))
    assert(fdCount() == before, "A failed load leaked descriptors")
end

test("both libraries use distinct retained verified FDs and stable cache hits", function()
    local case, paths = fixture(), {}
    ffi.load = function(path)
        assert(path:match("^/proc/self/fd/%d+$"))
        paths[#paths + 1] = path
        return { bytes = read(path) }
    end
    local before = fdCount()
    local first, first_info = assert(case.load("libbiliwasm.so"))
    local second, second_info = assert(case.load("libbilicrypto.so"))
    assert(paths[1] ~= paths[2] and fdCount() == before + 2)
    assert(first.bytes == case.records["libbiliwasm.so"].bytes and second.bytes == case.records["libbilicrypto.so"].bytes)
    for _, info in ipairs({ first_info, second_info }) do
        assert(lfs.attributes(info.path, "permissions") == "rw-------")
        assert(lfs.attributes(info.path:match("^(.*)/[^/]+$"), "permissions") == "rwx------")
        assert(read(info.path) == read(info == first_info and paths[1] or paths[2]))
    end
    for _ = 1, 20 do assert(case.load("libbiliwasm.so") == first); assert(case.load("libbilicrypto.so") == second) end
    assert(#paths == 2 and fdCount() == before + 2, "Cache hits leaked or reused a new dlopen name")
    write(case.records["libbiliwasm.so"].source, string.rep("x", #first.bytes))
    rejected(case, "source_integrity")
end)

test("source leaf symlinks are rejected even when their bytes match", function()
    local case = fixture()
    local record = case.records["libbiliwasm.so"]
    assert(os.rename(record.source, record.source .. ".original"))
    assert(lfs.link(record.source .. ".original", record.source, true))
    rejected(case, "source_open")
end)

test("private directory symlinks are not traversed", function()
    local case = fixture()
    mkdir(case.base .. "/outside", true)
    assert(lfs.link(case.base .. "/outside", case.private .. "/bilicomics-native", true))
    rejected(case, "directory")
    assert(not lfs.attributes(case.base .. "/outside/" .. target))
end)

test("private cache directories with broad permissions are rejected", function()
    local case = fixture()
    mkdir(case.private .. "/bilicomics-native")
    assert(ffi.C.chmod(case.private .. "/bilicomics-native", 511) == 0)
    rejected(case, "directory_permissions")
end)

test("existing destination symlinks are rejected without changing their target", function()
    local case = fixture()
    local record = case.prepare()
    local outside = case.base .. "/outside-file"
    write(outside, record.bytes, true)
    assert(lfs.link(outside, record.destination, true))
    rejected(case, "cache_open")
    assert(read(outside) == record.bytes)
end)

test("unexpected cache hardlinks are rejected", function()
    local case = fixture()
    local record = case.prepare()
    local outside = case.base .. "/outside-file"
    write(outside, record.bytes, true)
    assert(lfs.link(outside, record.destination))
    rejected(case, "file_permissions")
end)

test("cache digest mismatch is rejected without loading or overwriting", function()
    local case = fixture()
    local record = case.prepare()
    write(record.destination, string.rep("x", #record.bytes), true)
    rejected(case, "cache_integrity")
    assert(read(record.destination) == string.rep("x", #record.bytes))
end)

test("a dlopen failure closes all transient descriptors", function()
    local case = fixture()
    ffi.load = function() error("Synthetic dlopen failure") end
    local before = fdCount()
    local value, err = case.load()
    assert(value == nil and err.kind == "native_library" and fdCount() == before)
    local record = case.records["libbiliwasm.so"]
    for name in lfs.dir(record.destination:match("^(.*)/[^/]+$")) do
        assert(not name:match("^%.part%-"), "A failed load left its private temporary file")
    end
end)

test("path replacement at dlopen cannot change the verified inode", function()
    local case = fixture()
    local record = case.records["libbiliwasm.so"]
    ffi.load = function(path)
        assert(os.rename(record.destination, record.destination .. ".previous"))
        write(record.destination, string.rep("x", #record.bytes), true)
        return { bytes = read(path) }
    end
    local library = assert(case.load())
    assert(library.bytes == record.bytes and read(record.destination) ~= record.bytes)
end)

package.loaded.android = nil
local result = assert(io.open(output .. "/android-loader-result.json", "wb"))
result:write(assert(JSON.encode({ passed = #passed, cases = passed,
    scope = "Real Linux filesystem operations with an injected Android files directory; dlopen behavior is separately verified in the official APK." })))
result:close()
