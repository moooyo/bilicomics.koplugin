-- Test-only late patch. Its filename sorts before the production provider patch.
-- It never registers a provider, constructs Runtime, or opens a document.
local lfs = require("libs/libkoreader-lfs")
local json = require("rapidjson")
local DataStorage = require("datastorage")
local data = DataStorage:getDataDir():gsub("/+", "/"):gsub("/+$", "")
local function read(path)
    assert(lfs.symlinkattributes(path, "mode") == "file", "Expected a regular cold-probe file")
    local file = assert(io.open(path, "rb"))
    local value = assert(file:read("*a")); assert(file:close()); return value
end
local function write(path, value)
    local file = assert(io.open(path, "wb"))
    assert(file:write(value)); assert(file:flush()); assert(file:close())
end
local input = json.decode(read(data .. "/plugins/bili-native-probe.koplugin/cold-input.json"))
assert(input.run_id:match("^[a-f0-9]+$") and input.mid:match("^986543%d+$"), "Invalid cold probe identity")
if input.phase == "cleanup" then
    -- Select FileManager before startup document selection, without persisting
    -- these temporary values. The ordinary app-process driver restores originals.
    G_reader_settings:saveSetting("start_with", "filemanager")
    G_reader_settings:delSetting("lastfile")
    local disabled = G_reader_settings:readSetting("plugins_disabled", {})
    disabled.bilicomics = true
    G_reader_settings:saveSetting("plugins_disabled", disabled)
    return
end
if input.phase ~= "cold" then return end

local ffi = require("ffi")
require("ffi/posix_h")
local sha = require("ffi/sha2")
local socket = require("socket")
local UIManager = require("ui/uimanager")
local Device = require("device")
local registry = require("document/documentregistry")
local production = data .. "/plugins/bilicomics.koplugin"
local root = data .. "/bili-cold-" .. input.run_id
local seed = json.decode(read(root .. "/seed.json"))
assert(seed.run_id == input.run_id and seed.account_key == "bili_" .. input.mid)
local report = { run_id = input.run_id, scenario = "cold", phase = "started", passed = false,
    pid = tonumber(ffi.C.getpid()), uid = tonumber(ffi.C.getuid()), ffi_arch = ffi.arch, ffi_os = ffi.os,
    data_root = data, default_data_root = data .. "/bilicomics", production_plugin = production,
    patches_dir = DataStorage:getPatchesDir(), account_key = seed.account_key,
    assertions = {}, source_sha256 = {}, workers = 0, automatic_open_calls = {},
    scope = "Unmodified production late patch and native lastfile selection; observation only, no active open" }
local finished = false
local function save()
    local target = root .. "/cold-report.json"
    write(target .. ".pending", json.encode(report))
    assert(os.rename(target .. ".pending", target))
end
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
local function runtimeState()
    local runtime = package.loaded["bilicomics/runtime"]
    return runtime and runtime.peek() or nil
end
local function fail(message)
    if finished and report.passed == false then return end
    finished = true
    report.phase, report.passed, report.error = "complete", false, tostring(message)
    save()
end
save()
local ok, err = xpcall(function()
    check("Ordinary official cold-start process", report.uid >= 10000 and ffi.arch == "x86")
    check("Observer precedes production provider registration", registry.known_providers.bilicomics_document == nil)
    check("Observer starts before Runtime initialization", runtimeState() == nil)
    report.guard_registry_empty = true
    for relative, expected in pairs(input.source_sha256) do
        assert(type(relative) == "string" and not relative:match("^/") and not relative:find("..", 1, true))
        local digest = sha.sha256(read(production .. "/" .. relative))
        report.source_sha256[relative] = digest
        check("Frozen default-installed production bytes: " .. relative, digest == expected)
    end
    local original_path = package.path
    package.path = production .. "/?.lua;" .. production .. "/?/init.lua;" .. original_path
    local Runner = require("bilicomics/jobs/runner")
    package.path = original_path
    Runner.submit = function(_self, request)
        report.workers = report.workers + 1
        report.blocked_request = { kind = request and request.kind, method = request and request.method }
        fail("Cold offline startup attempted to dispatch a worker")
        error("The cold-start observer blocks every worker before dispatch")
    end
    local ReaderUI = require("apps/reader/readerui")
    check("Observer imports do not register the custom provider", registry.known_providers.bilicomics_document == nil)
    check("Observer imports do not initialize Runtime", runtimeState() == nil)
    local original_show = ReaderUI.showReader
    ReaderUI.showReader = function(self, file, ...)
        local observation = { file = file, provider_registered = registry.known_providers.bilicomics_document ~= nil,
            runtime_initialized = runtimeState() ~= nil }
        report.automatic_open_calls[#report.automatic_open_calls + 1] = observation
        save()
        return original_show(self, file, ...)
    end
    local started = socket.gettime()
    local settled_at
    local function poll()
        if finished then return end
        local observed, failure = xpcall(function()
            assert(socket.gettime() - started < 40, "Automatic native ReaderUI startup timed out")
            local reader = ReaderUI.instance
            if not reader or not reader.document or reader.document.file ~= seed.descriptor_path
                or not reader.bilicomics_integration then
                UIManager:scheduleIn(0.05, poll); return
            end
            local app = runtimeState()
            local anchor = require("bilicomics/reader/anchors").capture(reader)
            local pixel = Device.screen.bb:getPixel(math.floor(Device.screen:getWidth() / 2),
                math.floor(Device.screen:getHeight() / 8)):getR()
            report.observed_view = { file = reader.document.file, pixel = pixel,
                source_y = anchor and anchor.y, expected_y = seed.anchor.y }
            if not anchor or math.abs(anchor.y - seed.anchor.y) >= 0.005 or pixel ~= seed.expected_pixel then
                UIManager:scheduleIn(0.05, poll); return
            end
            if not settled_at then settled_at = socket.gettime(); UIManager:scheduleIn(0.2, poll); return end
            check("Native startup selected the seeded document exactly once", #report.automatic_open_calls == 1
                and report.automatic_open_calls[1].file == seed.descriptor_path)
            check("Production patch registered the provider before native selection", report.automatic_open_calls[1].provider_registered)
            check("Native open resolved services from an uninitialized Runtime", not report.automatic_open_calls[1].runtime_initialized)
            check("Native ReaderUI automatically opened the custom document", reader.document.provider == "bilicomics_document"
                and reader.document.file == seed.descriptor_path and reader.document:isPageReady(1))
            local plugin = reader.bilicomics
            check("Native reader contains the actual production plugin", plugin and not plugin.initialization_error
                and debug.getinfo(plugin.init, "S").source:gsub("/+", "/") == "@" .. production .. "/main.lua")
            check("Native service resolution uses the untouched default namespace", app and app.root == data .. "/bilicomics"
                and app.account.key == seed.account_key and app.account.root == data .. "/bilicomics/accounts/" .. seed.account_key)
            check("Cold account has no session", app.account.session == nil and not app.account.session_valid)
            check("Cold document retains the immutable descriptor", sha.sha256(read(seed.descriptor_path)) == seed.descriptor_sha256)
            check("Cold owned chapter remains complete and pinned", app.account.pages:isComplete(seed.episode_id, seed.revision)
                and app.account.store:isPinned(seed.episode_id, seed.revision)
                and app.account.store:getEpisode(seed.episode_id).access == "owned")
            check("Cold startup restored the original source anchor", anchor.page_id == seed.anchor.page_id
                and anchor.index == seed.anchor.index and math.abs(anchor.y - seed.anchor.y) < 0.005)
            check("Cold startup restored native continuous page-width presentation", reader.view.page_scroll == true
                and reader.zooming.zoom_mode == "pagewidth")
            check("Cold native framebuffer contains the expected source pixels", pixel == 100)
            check("Cold startup dispatched no workers", report.workers == 0)
            report.passed, report.phase, report.settled_seconds = true, "complete", socket.gettime() - settled_at
            finished = true
            save()
        end, debug.traceback)
        if not observed then fail(failure) end
    end
    UIManager:scheduleIn(0.05, poll)
end, debug.traceback)
if not ok then fail(err) end
