-- Run only inside the isolated test-env KOReader runtime.
require("setupkoenv")
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. package.path

local ffi = require("ffi")
require("ffi/posix_h")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local Files = require("bilicomics/storage/files")
local Budget = require("bilicomics/jobs/storage_budget")
local tests, evidence = {}, {}

local protocol_calls, client_constructions = 0, 0
local protocol_key = "bilicomics/protocol/client"
local original_client = package.loaded[protocol_key]
package.loaded[protocol_key] = { new = function()
    client_constructions = client_constructions + 1
    return setmetatable({}, { __index = function()
        return function()
            protocol_calls = protocol_calls + 1
            return nil, { kind = "unexpected_protocol", message = "This scenario must not invoke the protocol client." }
        end
    end })
end }
local Worker = require("bilicomics/jobs/worker")
package.loaded[protocol_key] = original_client

local function test(name, fn)
    local ok, failure = xpcall(fn, debug.traceback)
    tests[#tests + 1] = { name = name, passed = ok, error = ok and nil or failure }
    print((ok and "PASS " or "FAIL ") .. name)
end

local function rawCapacity()
    local status = ffi.new("struct statvfs[1]")
    assert(ffi.C.statvfs(output, status) == 0, "The isolated output directory must support statvfs")
    local block_size = tonumber(status[0].f_frsize)
    local total = tonumber(status[0].f_blocks) * block_size
    assert(block_size > 0 and total > 0 and total < math.huge, "The test filesystem must have finite positive capacity")
    return total, block_size, tonumber(status[0].f_bavail) * block_size
end

local function absent(path)
    assert(lfs.attributes(path) == nil, "The isolated missing-path fixture must not exist")
    return path
end

test("Available storage uses real filesystem bytes", function()
    local total, block_size, raw_available = rawCapacity()
    local available, err = Budget.available(output)
    assert(type(available) == "number" and available >= 0 and available <= total and err == nil,
        "Available storage must be a finite byte count on the output filesystem")
    assert(available % block_size == 0, "Available bytes must represent complete filesystem fragments")
    evidence = { filesystem_capacity_bytes = total, filesystem_fragment_bytes = block_size,
        raw_available_bytes = raw_available, budget_available_bytes = available, ffi_os = ffi.os, ffi_arch = ffi.arch }
end)

test("A failed statvfs call never reuses a previous successful capacity", function()
    local missing = absent(output .. "/budget-absent-directory")
    for _ = 1, 3 do
        local valid, valid_error = Budget.available(output)
        assert(type(valid) == "number" and valid_error == nil, "The preceding real capacity query must succeed")
        local result, err = Budget.available(missing)
        assert(result == nil and type(err) == "table" and err.kind == "storage",
            "A nonexistent path must return a storage error rather than the preceding free-byte count")
    end
    assert(lfs.attributes(missing) == nil, "Inspecting a missing path must not create it")
end)

test("A regular file cannot be used as a parent directory for storage inspection", function()
    local fixture = output .. "/fixtures/page-a.png"
    assert(lfs.attributes(fixture, "mode") == "file", "The shared image fixture must exist")
    local valid = Budget.available(output)
    assert(type(valid) == "number", "A successful query must precede the ENOTDIR boundary")
    local result, err = Budget.available(fixture .. "/unreachable")
    assert(result == nil and err and err.kind == "storage", "An invalid path component must not produce usable free bytes")
end)

test("Zero requested reserve allows an existing readable filesystem", function()
    local ok, err = Budget.check(output, 0, 0)
    assert(ok == true and err == nil, "An explicit zero reserve must not silently become the default reserve")
end)

test("A reserve larger than filesystem capacity fails without allocating data", function()
    local total = rawCapacity()
    local minimum = total + Budget.default_minimum + 1
    local ok, err = Budget.check(output, minimum, 0)
    assert(ok == nil and err and err.kind == "low_space", "An impossible reserve must be rejected")
    assert(err.required_bytes == minimum and type(err.available_bytes) == "number"
        and err.available_bytes < err.required_bytes, "The shortage must expose usable byte counts")
end)

test("Expected image output is included in the storage reserve", function()
    local total = rawCapacity()
    local minimum, expected = 4096, total + 1
    local ok, err = Budget.check(output, minimum, expected)
    assert(ok == nil and err and err.kind == "low_space", "The next image write must fit in addition to the minimum reserve")
    assert(err.required_bytes == minimum + expected, "The reported requirement must include both storage commitments")
end)

test("Storage query errors propagate through the budget check", function()
    local missing = absent(output .. "/budget-missing-check-directory")
    local ok, err = Budget.check(missing, 0, 0)
    assert(ok == nil and err and err.kind == "storage", "Unknown capacity must not be treated as sufficient storage")
end)

for _, kind in ipairs({ "download_page", "download_cover" }) do
    test(kind .. " is rejected before any protocol work when the reserve exceeds available bytes", function()
        local total, _, available = rawCapacity()
        local minimum = total + Budget.default_minimum + 1
        assert(minimum > available, "The requested reserve must exceed actual available bytes without filling the disk")
        local path = absent(output .. "/budget-blocked-" .. kind .. ".part")
        local before_calls, before_clients = protocol_calls, client_constructions
        local result, err = Worker.execute({ kind = kind, temporary_path = path,
            source_path = "/synthetic/page", url = "https://i0.hdslb.com/synthetic-cover.png",
            minimum_free_bytes = minimum, max_bytes = 4096 })
        assert(result == nil and err and err.kind == "low_space", "The worker must return the storage shortage")
        assert(err.required_bytes == minimum + 4096, "The worker must forward the explicit minimum and transfer budget")
        assert(protocol_calls == before_calls and client_constructions == before_clients,
            "Insufficient storage must stop before constructing a client or obtaining tokens and images")
        assert(lfs.attributes(path) == nil, "Rejected downloads must not create temporary output")
    end)
end

test("Worker rejects an unavailable output directory before protocol work", function()
    local directory = absent(output .. "/budget-missing-worker-directory")
    local before_calls, before_clients = protocol_calls, client_constructions
    local result, err = Worker.execute({ kind = "download_page", source_path = "/synthetic/page",
        temporary_path = directory .. "/page.part", minimum_free_bytes = 0, max_bytes = 1 })
    assert(result == nil and err and err.kind == "storage", "An unavailable output directory must report a storage error")
    assert(protocol_calls == before_calls and client_constructions == before_clients,
        "Unknown storage capacity must stop before any protocol operation")
    assert(lfs.attributes(directory) == nil, "The worker budget guard must not create its missing directory")
end)

local passed = true
for _, item in ipairs(tests) do passed = passed and item.passed end
Files.write(output .. "/budget-result.json", json.encode({ tests = tests, passed = passed, evidence = evidence,
    scope = "Real statvfs on an isolated existing directory; impossible numeric reserves; no image downloads or account access" }, { pretty = true }))
assert(passed, "One or more storage budget contract tests failed")
