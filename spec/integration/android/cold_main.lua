-- App-process preparation and recovery for the native automatic-startup probe.
-- The cold phase is observed exclusively by the earlier late user-patch guard.
local lfs = require("libs/libkoreader-lfs")
local json = require("rapidjson")
local DataStorage = require("datastorage")
local function read(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == nil then return nil end
    assert(mode == "file", "Expected a regular probe or settings file")
    local file = assert(io.open(path, "rb"))
    local value = assert(file:read("*a")); assert(file:close()); return value
end
local function write(path, value)
    local file = assert(io.open(path, "wb"))
    assert(file:write(value)); assert(file:flush()); assert(file:close())
end
local data = DataStorage:getDataDir():gsub("/+", "/"):gsub("/+$", "")
local research = data .. "/plugins/bili-native-probe.koplugin"
local input = json.decode(assert(read(research .. "/cold-input.json")))
assert(input.run_id:match("^[a-f0-9]+$") and input.mid:match("^986543%d+$"), "Invalid cold probe identity")
assert(input.bundle_relative == "cold-" .. input.run_id .. "/bundle", "Invalid cold probe bundle")
if input.phase == "cold" then return { disabled = true } end

local ffi = require("ffi")
require("ffi/posix_h")
local sha = require("ffi/sha2")
local android = require("android")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local socket = require("socket")
local bundle = research .. "/" .. input.bundle_relative
local production = data .. "/plugins/bilicomics.koplugin"
local root = data .. "/bili-cold-" .. input.run_id
local default_root = data .. "/bilicomics"
local account_key = "bili_" .. input.mid
local account_root = default_root .. "/accounts/" .. account_key
local private_account = android.dir .. "/bilicomics/accounts/" .. account_key
local control = android.dir .. "/bili-cold-control-" .. input.run_id
local patch = DataStorage:getPatchesDir() .. "/2-bilicomics-provider.lua"
if not lfs.symlinkattributes(root) then assert(lfs.mkdir(root)) end
assert(lfs.symlinkattributes(root, "mode") == "directory")
local report = { run_id = input.run_id, scenario = input.phase, phase = "started", passed = false,
    assertions = {}, source_sha256 = {}, pid = tonumber(ffi.C.getpid()), uid = tonumber(ffi.C.getuid()),
    ffi_arch = ffi.arch, ffi_os = ffi.os, data_root = data, default_data_root = default_root,
    production_plugin = production, account_root = account_root, account_key = account_key,
    private_control_root = control, patches_dir = DataStorage:getPatchesDir(), startup_patch = patch,
    scope = "Native PluginLoader installation and automatic lastfile startup; synthetic offline content only" }
local function save()
    local target = root .. "/" .. input.phase .. "-report.json"
    write(target .. ".pending", json.encode(report))
    assert(os.rename(target .. ".pending", target))
end
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
local function complete()
    if report.phase == "complete" then return end
    report.phase = "complete"
    UIManager:show(WidgetContainer:new{ dimen = require("device").screen:getSize() })
    save()
end
local function fail(message)
    report.passed, report.error = false, tostring(message)
    UIManager:nextTick(complete)
end
local function sourceHashes(source_root, recovering)
    local intact = true
    for relative, expected in pairs(input.source_sha256) do
        assert(type(relative) == "string" and not relative:match("^/") and not relative:find("..", 1, true))
        local ok, value = pcall(read, source_root .. "/" .. relative)
        local digest = ok and value and sha.sha256(value) or nil
        report.source_sha256[relative] = digest
        intact = intact and digest == expected
        if not recovering then check("Frozen production bytes: " .. relative, digest == expected) end
    end
    report.source_integrity = intact
    return intact
end
local function backupPrivateSettings()
    assert(lfs.symlinkattributes(control) == nil, "The private control directory must be new")
    assert(lfs.mkdir(control))
    local filename = assert(G_reader_settings.file)
    assert(filename == data .. "/settings.reader.lua"
        or filename:sub(1, #android.dir + 1) == android.dir .. "/", "Expected native reader settings")
    local state = { run_id = input.run_id, account_key = account_key, filename = filename, files = {} }
    for index, suffix in ipairs({ "", ".old" }) do
        local value = read(filename .. suffix)
        local record = { suffix = suffix, existed = value ~= nil, backup = "settings-" .. index .. ".backup" }
        if value then
            record.sha256 = sha.sha256(value)
            write(control .. "/" .. record.backup, value)
        end
        state.files[#state.files + 1] = record
    end
    write(control .. "/state.json", json.encode(state))
    report.settings_path = filename
end
local function prepare()
    check("Actual production plugin was absent during preparation", lfs.symlinkattributes(production) == nil)
    check("New shared account is unoccupied", lfs.symlinkattributes(account_root) == nil)
    check("New private account is unoccupied", lfs.symlinkattributes(private_account) == nil)
    for _, directory in ipairs({ default_root, default_root .. "/accounts" }) do
        local mode = lfs.symlinkattributes(directory, "mode")
        check("Default namespace parent is not redirected: " .. directory, mode == nil or mode == "directory")
    end
    check("Preparation does not initialize Runtime", package.loaded["bilicomics/runtime"] == nil)
    check("Preparation starts without a custom provider", not require("document/documentregistry").known_providers.bilicomics_document)
    backupPrivateSettings()
    local disabled = {}
    for _, entry in ipairs(require("pluginloader"):_discover()) do
        if entry.name ~= input.plugin_name and entry.name ~= "bilicomics" then disabled[entry.name] = true end
    end
    G_reader_settings:saveSetting("plugins_disabled", disabled)
    G_reader_settings:saveSetting("plugins_disable_external", false)
    G_reader_settings:saveSetting("start_with", "filemanager")
    G_reader_settings:delSetting("lastfile")
    G_reader_settings:saveSetting("color_rendering", false)
    G_reader_settings:flush()

    package.path = bundle .. "/?.lua;" .. bundle .. "/?/init.lua;" .. package.path
    local Files = require("bilicomics/storage/files")
    local Header = require("bilicomics/storage/image_header")
    local Settings = require("bilicomics/settings")
    local settings = Settings.open(default_root)
    settings:set("active_account_key", account_key)
    settings:set("account_summary:" .. account_key, { id = input.mid, name = "Synthetic cold startup account" })
    local store = require("bilicomics/storage/store").open{ root = account_root, account_key = account_key }
    local seeded, seed_error = xpcall(function()
        local pages = require("bilicomics/storage/page_store").new{ root = account_root, account_key = account_key, store = store }
        local header = Header.read(bundle .. "/fixture.png")
        check("Synthetic grayscale fixture has the expected geometry", header.format == "png" and header.width == 600 and header.height == 2400)
        local comic, episode, revision = "984201", "98420101", "cold_1"
        store:upsertComic{ id = comic, title = "Synthetic automatic startup", latest_order = 1 }
        store:upsertEpisodes(comic, { { id = episode, comic_id = comic, order = 1,
            title = "Pinned owned offline chapter", access = "owned", extra = { current_revision = revision } } })
        local descriptor = { schema_version = 1, account_key = account_key, comic_id = comic,
            episode_id = episode, revision = revision,
            pages = { { id = "cold-page-1", index = 1, width = header.width, height = header.height } } }
        local descriptor_path = pages:ensureDescriptor(descriptor)
        local temporary = pages.temporary_root .. "/cold-fixture.part"
        Files.atomicWrite(temporary, Files.read(bundle .. "/fixture.png", 8 * 1024 * 1024), account_root)
        pages:commitPage({ episode_id = episode, revision = revision, index = 1, expected_content_generation = 0 },
            { temporary_path = temporary, checksum = Files.digest(temporary), format = header.format,
              width = header.width, height = header.height,
              geometry = { source_width = header.width, source_height = header.height, exif_orientation = 1 } })
        pages:pinEpisode(episode, revision, true)
        local anchor = { schema_version = 1, page_id = "cold-page-1", index = 1, x = 0, y = 0.30,
            rotation = 0, mode = "continuous", zoom_mode = "pagewidth", zoom_ratio = 1, geometry_generation = 0 }
        store:putAnchor(episode, revision, anchor)
        check("Seed uses complete pinned owned production storage", pages:isComplete(episode, revision)
            and store:isPinned(episode, revision) and store:getEpisode(episode).access == "owned")
        local seed = { run_id = input.run_id, account_key = account_key, default_data_root = default_root,
            descriptor_path = descriptor_path, descriptor_sha256 = sha.sha256(Files.read(descriptor_path)),
            fixture_sha256 = sha.sha256(Files.read(bundle .. "/fixture.png")), episode_id = episode,
            revision = revision, anchor = anchor, expected_pixel = 100 }
        write(root .. "/seed.json", json.encode(seed))
        report.seed = seed
    end, debug.traceback)
    store:close()
    assert(seeded, seed_error)
    check("Preparation never initialized an account controller", package.loaded["bilicomics/runtime"] == nil
        and package.loaded["bilicomics/controller"] == nil)
    check("Preparation never registered a document provider", not require("document/documentregistry").known_providers.bilicomics_document)
    report.passed = true
    UIManager:nextTick(complete)
end
local function observeInstall()
    local started = socket.gettime()
    local function poll()
        local ok, err = xpcall(function()
            assert(socket.gettime() - started < 40, "Native plugin installation observation timed out")
            local runtime = package.loaded["bilicomics/runtime"]
            local app = runtime and runtime.peek()
            local plugin = app and app.host_ui and app.host_ui.bilicomics
            if not plugin then UIManager:scheduleIn(0.05, poll); return end
            local entry_source = debug.getinfo(plugin.init, "S").source
            check("Native PluginLoader instantiated the actual production entry",
                entry_source:gsub("/+", "/") == "@" .. production .. "/main.lua"
                and plugin.app == app and not plugin.initialization_error)
            check("Native Runtime selected only the seeded default account", app.root == default_root
                and app.account.key == account_key and app.account.root == account_root and app.account.session == nil)
            check("Native main installed its real startup patch", not plugin.startup_error and read(patch) ~= nil)
            local packaged = assert(read(production .. "/patches/2-bilicomics-provider.lua"))
            local installed_path = assert(entry_source:match("^@(.+)/main%.lua$")):gsub("/%./", "/"):gsub("/+$", "")
            local expected, replacements = packaged:gsub("local preferred_path = nil", function()
                return "local preferred_path = " .. string.format("%q", installed_path)
            end, 1)
            check("Installed default startup patch has exact production bytes", replacements == 1 and read(patch) == expected)
            local seed = json.decode(assert(read(root .. "/seed.json")))
            G_reader_settings:saveSetting("start_with", "last")
            G_reader_settings:saveSetting("lastfile", seed.descriptor_path)
            G_reader_settings:flush()
            report.entry_source, report.patch_sha256 = entry_source, sha.sha256(expected)
            report.lastfile, report.start_with, report.passed = seed.descriptor_path, "last", true
            complete()
        end, debug.traceback)
        if not ok then fail(err) end
    end
    UIManager:scheduleIn(0.05, poll)
end
local function cleanup()
    local state_bytes = read(control .. "/state.json")
    if not state_bytes then
        report.no_owned_settings_changed = true
        report.settings_restored = false
        report.passed = true
        UIManager:nextTick(complete)
        return
    end
    local state = json.decode(state_bytes)
    assert(state.run_id == input.run_id and state.account_key == account_key
        and state.filename == G_reader_settings.file, "Invalid private recovery ownership")
    local restored, failures = true, {}
    for _, record in ipairs(state.files) do
        local ok, err = pcall(function()
            assert(record.suffix == "" or record.suffix == ".old")
            local target = state.filename .. record.suffix
            if record.existed then
                local original = assert(read(control .. "/" .. record.backup))
                assert(sha.sha256(original) == record.sha256, "Private settings backup changed")
                write(target, original)
                assert(read(target) == original, "Private settings restoration changed bytes")
                if record.suffix == "" then
                    G_reader_settings.data = require("luasettings"):open(control .. "/" .. record.backup).data
                end
            else
                if lfs.symlinkattributes(target) then
                    assert(lfs.symlinkattributes(target, "mode") == "file")
                    assert(os.remove(target))
                end
                assert(lfs.symlinkattributes(target) == nil)
                if record.suffix == "" then G_reader_settings.data = {} end
            end
        end)
        if not ok then restored = false; failures[#failures + 1] = tostring(err) end
    end
    report.settings_restored, report.restore_errors = restored, failures
    report.private_account_was_not_created = lfs.symlinkattributes(private_account) == nil
    report.passed = restored and report.private_account_was_not_created
    UIManager:nextTick(complete)
end

save()
local ok, err = xpcall(function()
    check("Ordinary official Android process", report.uid >= 10000 and ffi.arch == "x86")
    check("Native shared DataStorage is unchanged", data == "/storage/emulated/0/koreader")
    if input.phase == "cleanup" then
        -- Recovery does not depend on any production file, registry, or Runtime.
        cleanup()
        sourceHashes(bundle, true)
    else
        sourceHashes(input.phase == "prepare" and bundle or production, false)
        if input.phase == "prepare" then prepare()
        elseif input.phase == "install" then observeInstall()
        else error("Unknown cold probe phase") end
    end
end, debug.traceback)
if not ok then fail(err) end
return { disabled = true }
