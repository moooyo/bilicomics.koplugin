-- Research driver for the unchanged official KOReader APK. No real network or purchase.
local ffi = require("ffi")
require("ffi/posix_h")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local sha = require("ffi/sha2")
local android = require("android")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local source = debug.getinfo(1, "S").source
local plugin_root = assert(source:match("^@(.+)/main%.lua$")):gsub("/+", "/")
local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a"); file:close(); return value
end
local function write(path, value)
    local file = assert(io.open(path, "wb"))
    assert(file:write(value)); assert(file:flush()); assert(file:close())
end
local input = json.decode(assert(read(plugin_root .. "/integration-input.json")))
assert(input.run_id:match("^[a-f0-9]+$") and input.mid:match("^986541%d+$"), "Invalid synthetic identity")
assert(input.bundle_relative == "integration-" .. input.run_id .. "/bundle", "Invalid isolated bundle path")
local root = DataStorage:getDataDir():gsub("/+", "/") .. "/bili-integration-" .. input.run_id
local bundle = plugin_root .. "/" .. input.bundle_relative
local private_root = android.dir .. "/bili-integration-control-" .. input.run_id
local account_key = "bili_" .. input.mid
local session_path = android.dir .. "/bilicomics/accounts/" .. account_key .. "/session.dat"
if lfs.attributes(root, "mode") ~= "directory" then assert(lfs.mkdir(root)) end
local report = { run_id = input.run_id, phase = "started", scenario = input.phase, assertions = {},
    root = root, bundle = bundle, private_control_root = private_root, private_session_path = session_path,
    pid = tonumber(ffi.C.getpid()), uid = tonumber(ffi.C.getuid()), ffi_arch = ffi.arch, ffi_os = ffi.os,
    selinux_context = read("/proc/self/attr/current"), source_sha256 = {}, apk_modified = false,
    scope = "Actual Android APK native UI/controller/SQLite/fork; synthetic protocol only" }
local function save()
    local path = root .. "/" .. input.phase .. "-report.json"
    write(path .. ".pending", json.encode(report))
    assert(os.rename(path .. ".pending", path))
end
save()
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
local function keepAlive()
    if not report.keepalive then
        report.keepalive = true
        UIManager:show(WidgetContainer:new{ dimen = require("device").screen:getSize() })
    end
end
local function complete(result)
    if report.phase == "complete" then return end
    report.phase = "complete"
    if result then
        report.chain = result
        report.passed = result.passed == true
    end
    keepAlive(); save()
end
local function removeSyntheticSession()
    if lfs.attributes(session_path, "mode") == "file" then assert(os.remove(session_path)) end
    return lfs.attributes(session_path, "mode") == nil
end

local ok, returned = xpcall(function()
    check("Ordinary official APK process", report.uid >= 10000 and ffi.arch == "x86")
    check("Independent shared-storage run root", root:match("^/storage/emulated/0/koreader/bili%-integration%-") ~= nil)
    local source_integrity = true
    for relative, expected in pairs(input.source_sha256) do
        local bytes = read(bundle .. "/" .. relative)
        local digest = bytes and sha.sha256(bytes)
        report.source_sha256[relative] = digest
        if input.phase == "cleanup" then
            -- Recovery must not depend on an intact production test bundle.
            source_integrity = source_integrity and digest == expected
            report.assertions[#report.assertions + 1] = { name = "Unmodified staged source: " .. relative,
                passed = digest == expected }
        else
            check("Unmodified staged source: " .. relative, digest == expected)
        end
    end
    if input.phase == "setup" then
        check("Synthetic account did not preexist", lfs.attributes(session_path) == nil
            and lfs.attributes(session_path:match("^(.*)/session%.dat$")) == nil)
        assert(lfs.mkdir(private_root))
        local filename = assert(G_reader_settings.file, "Native settings have no backing file")
        local original = read(filename)
        local old = read(filename .. ".old")
        local state = { filename = filename, existed = original ~= nil, account_key = account_key,
            session_path = session_path, original_sha256 = original and sha.sha256(original) or nil,
            old_existed = old ~= nil, old_sha256 = old and sha.sha256(old) or nil }
        if original then write(private_root .. "/settings.backup", original) end
        if old then write(private_root .. "/settings-old.backup", old) end
        write(private_root .. "/state.json", json.encode(state))
        local disabled = {}
        for _, entry in ipairs(require("pluginloader"):_discover()) do
            if entry.name ~= input.plugin_name then disabled[entry.name] = true end
        end
        G_reader_settings:saveSetting("plugins_disabled", disabled)
        G_reader_settings:saveSetting("start_with", "filemanager")
        G_reader_settings:saveSetting("color_rendering", false)
        G_reader_settings:flush()
        report.settings_path = filename
        report.passed = true
        UIManager:nextTick(function() complete() end)
        return { disabled = true }
    elseif input.phase == "cleanup" then
        local saved = read(private_root .. "/state.json")
        if saved then
            local state = json.decode(saved)
            assert(state.account_key == account_key and state.session_path == session_path)
            report.synthetic_session_removed = removeSyntheticSession()
            if state.existed then
                local original = assert(read(private_root .. "/settings.backup"))
                assert(sha.sha256(original) == state.original_sha256)
                write(state.filename, original)
                G_reader_settings.data = require("luasettings"):open(private_root .. "/settings.backup").data
                report.settings_restored = read(state.filename) == original
            else
                if lfs.attributes(state.filename) then assert(os.remove(state.filename)) end
                G_reader_settings.data = {}
                report.settings_restored = lfs.attributes(state.filename) == nil
            end
            if state.old_existed then
                local old = assert(read(private_root .. "/settings-old.backup"))
                assert(sha.sha256(old) == state.old_sha256)
                write(state.filename .. ".old", old)
                report.settings_restored = report.settings_restored and read(state.filename .. ".old") == old
            elseif lfs.attributes(state.filename .. ".old") then
                assert(os.remove(state.filename .. ".old"))
            end
            report.passed = report.settings_restored and report.synthetic_session_removed and source_integrity
        else
            -- An early setup failure changed no native configuration or account session.
            -- Without the setup ownership record, never remove a candidate account file.
            report.settings_restored = true
            report.synthetic_session_removed = true
            report.no_owned_session_created = true
            report.passed = source_integrity
        end
        UIManager:nextTick(function() complete() end)
        return { disabled = true }
    end
    assert(input.phase == "online" or input.phase == "offline", "Invalid integration phase")
    package.path = bundle .. "/?.lua;" .. bundle .. "/?/init.lua;" .. package.path
    -- Keep automatically installed startup files within this test's shared-storage root.
    DataStorage.getPatchesDir = function() return root .. "/patches" end
    local context = { bundle = bundle, fixture = bundle .. "/fixture.png", root = root,
        phase = input.phase, mid = input.mid, plugin_name = input.plugin_name, android_private = android.dir }
    context.complete = function(result)
        context.finished = true
        complete(result)
    end
    context.progress = function(result)
        if not context.finished then report.chain = result; save() end
    end
    UIManager:nextTick(function()
        -- PluginLoader restores its search path after evaluating plugin main files.
        -- The isolated nested bundle needs its test-only path reinstated afterwards.
        package.path = bundle .. "/?.lua;" .. bundle .. "/?/init.lua;" .. package.path
        keepAlive()
    end)
    local production_class = assert(loadfile(bundle .. "/spec/integration/android/chain.lua"))()(context)
    check("Native plugin class uses actual production main", debug.getinfo(production_class.init, "S").source
        == "@" .. bundle .. "/main.lua")
    report.phase = "running"; save()
    return production_class
end, debug.traceback)
if not ok then
    report.passed, report.error = false, returned
    local runtime = package.loaded["bilicomics/runtime"]
    if runtime then pcall(runtime.close) end
    UIManager:nextTick(function() complete() end)
    return { disabled = true }
end
return returned
