-- Run only in an isolated official KOReader runtime on test-env.
-- Usage: KO_HOME=<output>/data luajit bootstrap_spec.lua <plugin_root> <output>
-- The caller must create KO_HOME before loading KOReader's DataStorage module.
require("setupkoenv")
assert(jit.os == "Linux", "This verification must run on the authorized Linux test host")
local plugin_root, output = assert(arg[1]), assert(arg[2])
package.path = plugin_root .. "/?.lua;" .. package.path

local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local json = require("rapidjson")
local patches_dir = DataStorage:getPatchesDir()
assert(output:sub(1, 1) == "/" and patches_dir:sub(1, #output + 1) == output .. "/",
    "DataStorage must be isolated inside the requested output directory")
assert(lfs.symlinkattributes(output, "mode") == "directory", "The output directory must exist")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)

local report = { mode = "bootstrap", patches_dir = patches_dir, assertions = {} }
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
local function read(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    assert(file:close())
    return data
end
local function write(path, data)
    local file = assert(io.open(path, "wb"))
    assert(file:write(data))
    assert(file:close())
end
local function make_directory(path)
    assert(require("util").makePath(path))
    assert(lfs.symlinkattributes(path, "mode") == "directory")
end
local function no_temporary_files()
    for name in lfs.dir(patches_dir) do
        if name:find(".temporary.", 1, true) then return false end
    end
    return true
end

local function run()
    local Bootstrap = require("bilicomics/bootstrap")
    local patch_name = "2-bilicomics-provider.lua"
    local marker = "-- BiliComics managed startup provider bootstrap v1\n"
    local fixture_plugin = output .. "/fixture 'quoted' plugin.koplugin"
    local source_path = fixture_plugin .. "/patches/" .. patch_name
    make_directory(fixture_plugin .. "/patches")
    local packaged_source = read(plugin_root .. "/patches/" .. patch_name)
    write(source_path, packaged_source)
    local destination = patches_dir .. "/" .. patch_name
    check("bootstrap starts with an empty isolated destination", lfs.symlinkattributes(destination) == nil)

    local installed, failure = Bootstrap.installStartupPatch(fixture_plugin)
    check("startup patch installs into real DataStorage", installed and installed.installed
        and installed.changed and installed.path == destination, failure)
    local first_content = read(destination)
    check("installed patch preserves its owner", first_content:sub(1, #marker) == marker)
    check("installed path is safely quoted", first_content:find(
        "local preferred_path = " .. string.format("%q", fixture_plugin), 1, true) ~= nil)
    check("installation does not mutate the packaged source", read(source_path) == packaged_source)
    local first_inode = lfs.attributes(destination, "ino")
    installed, failure = Bootstrap.installStartupPatch(fixture_plugin)
    check("repeated installation is idempotent", installed and installed.installed and not installed.changed, failure)
    check("idempotent installation keeps content and inode", read(destination) == first_content
        and lfs.attributes(destination, "ino") == first_inode)
    check("successful installation leaves no temporary files", no_temporary_files())

    local updated_source = packaged_source .. "\n-- Synthetic owned update.\n"
    write(source_path, updated_source)
    installed, failure = Bootstrap.installStartupPatch(fixture_plugin)
    check("an owned startup patch can be updated", installed and installed.changed, failure)
    check("owned update reaches the destination", read(destination):find("-- Synthetic owned update.", 1, true) ~= nil)
    installed = Bootstrap.installStartupPatch(fixture_plugin)
    check("owned update is subsequently idempotent", installed and not installed.changed)

    local foreign_content = "-- A foreign startup patch.\nreturn 'preserve me'\n"
    assert(os.remove(destination))
    write(destination, foreign_content)
    local rejected, rejection = Bootstrap.installStartupPatch(fixture_plugin)
    check("a foreign same-name patch is rejected", rejected == nil and rejection
        and rejection.kind == "capability" and rejection.code == "foreign_patch")
    check("foreign content is preserved", read(destination) == foreign_content)

    assert(os.remove(destination))
    local outside_target = output .. "/symlink-target.lua"
    write(outside_target, foreign_content)
    assert(lfs.link(outside_target, destination, true))
    rejected, rejection = Bootstrap.installStartupPatch(fixture_plugin)
    check("a destination symlink is rejected", rejected == nil and rejection.code == "foreign_patch")
    check("destination symlink and target are preserved", lfs.symlinkattributes(destination, "mode") == "link"
        and read(outside_target) == foreign_content)
    assert(os.remove(destination))

    local saved_source = source_path .. ".original"
    assert(os.rename(source_path, saved_source))
    assert(lfs.link(saved_source, source_path, true))
    rejected, rejection = Bootstrap.installStartupPatch(fixture_plugin)
    check("a packaged source symlink is rejected", rejected == nil and rejection.code == "startup_patch_install")
    check("source symlink rejection writes no destination", lfs.symlinkattributes(destination) == nil
        and read(saved_source) == updated_source)
    assert(os.remove(source_path))
    assert(os.rename(saved_source, source_path))

    local saved_directory = patches_dir .. ".original"
    local redirected_directory = output .. "/redirected-patches"
    make_directory(redirected_directory)
    assert(os.rename(patches_dir, saved_directory))
    assert(lfs.link(redirected_directory, patches_dir, true))
    rejected, rejection = Bootstrap.installStartupPatch(fixture_plugin)
    check("a patches directory symlink is rejected", rejected == nil and rejection.code == "startup_patch_install")
    check("directory symlink rejection preserves the target", lfs.symlinkattributes(patches_dir, "mode") == "link"
        and lfs.symlinkattributes(redirected_directory .. "/" .. patch_name) == nil)
    assert(os.remove(patches_dir))
    assert(os.rename(saved_directory, patches_dir))

    local userpatch = require("userpatch")
    check("isolated user patches initially enabled", not userpatch.arePatchesDisabled())
    userpatch.togglePatchesDisabled()
    check("native disable marker exists", userpatch.arePatchesDisabled()
        and lfs.attributes(patches_dir .. "/.patches_disabled", "mode") == "file")
    rejected, rejection = Bootstrap.installStartupPatch(fixture_plugin)
    check("disabled user patches report a capability limit", rejected == nil and rejection.kind == "capability"
        and rejection.code == "patches_disabled")
    check("disabled installation writes no startup patch", lfs.symlinkattributes(destination) == nil)
    userpatch.togglePatchesDisabled()
    check("native user patches can be restored", not userpatch.arePatchesDisabled())

    local original_android = package.loaded.android
    package.loaded.android = { prop = { flavor = "fdroid" } }
    rejected, rejection = Bootstrap.installStartupPatch(fixture_plugin)
    check("F-Droid reports its startup-patch capability limit", rejected == nil and rejection.kind == "capability"
        and rejection.code == "fdroid")
    check("F-Droid installation writes no startup patch", lfs.symlinkattributes(destination) == nil)
    package.loaded.android = original_android
    check("normal capability returns after F-Droid simulation", Bootstrap.startupCapability() ~= nil)
    check("rejected installations leave no temporary files", no_temporary_files())

    local data_root = DataStorage:getDataDir() .. "/bilicomics"
    local descriptor_directory = data_root .. "/accounts/bootstrap-account/documents/comic/episode/revision"
    make_directory(descriptor_directory)
    local owned_descriptor = descriptor_directory .. "/chapter.bcomic"
    local descriptor_content = '{"schema_version":1,"synthetic":"preserve descriptor"}\n'
    write(owned_descriptor, descriptor_content)
    local history_path = DataStorage:getDataDir() .. "/history/bootstrap-sentinel.lua"
    make_directory(DataStorage:getDataDir() .. "/history")
    write(history_path, "return { synthetic = 'preserve history' }\n")
    local anchor_path = data_root .. "/accounts/bootstrap-account/anchor-sentinel.json"
    write(anchor_path, '{"synthetic":"preserve anchor","x":0.25,"y":0.75}\n')
    local history_content, anchor_content = read(history_path), read(anchor_path)
    check("default namespace descriptor is owned", Bootstrap.isOwnedDescriptor(owned_descriptor))
    check("explicit namespace descriptor is owned", Bootstrap.isOwnedDescriptor(owned_descriptor, data_root))
    G_reader_settings:saveSetting("start_with", "last")
    G_reader_settings:saveSetting("lastfile", owned_descriptor)
    G_reader_settings:flush()
    local original_capability = Bootstrap.startupCapability
    Bootstrap.startupCapability = function() error("Fallback must not recheck startup capability") end
    local fallback, fallback_error = Bootstrap.prepareFallback()
    Bootstrap.startupCapability = original_capability
    check("fallback clears only the owned startup target", fallback and fallback.cleared
        and fallback.file == owned_descriptor and G_reader_settings:readSetting("lastfile") == nil, fallback_error)
    check("fallback preserves the last-document startup preference", G_reader_settings:readSetting("start_with") == "last")
    local persisted = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
    check("fallback removal is persisted", persisted:readSetting("lastfile") == nil
        and persisted:readSetting("start_with") == "last")
    check("fallback preserves the descriptor identity", read(owned_descriptor) == descriptor_content)
    check("fallback preserves native history and source anchors", read(history_path) == history_content
        and read(anchor_path) == anchor_content)
    fallback = Bootstrap.prepareFallback()
    check("fallback is idempotent", fallback and not fallback.cleared
        and G_reader_settings:readSetting("lastfile") == nil and G_reader_settings:readSetting("start_with") == "last")

    local function preserve_target(name, path, root)
        check(name .. " is not owned", not Bootstrap.isOwnedDescriptor(path, root))
        G_reader_settings:saveSetting("lastfile", path)
        local result = Bootstrap.prepareFallback(root)
        check(name .. " is not cleared", result and not result.cleared
            and G_reader_settings:readSetting("lastfile") == path
            and G_reader_settings:readSetting("start_with") == "last")
    end
    local external_descriptor = output .. "/external/chapter.bcomic"
    make_directory(output .. "/external")
    write(external_descriptor, "external comic sentinel\n")
    preserve_target("external comic file", external_descriptor)
    check("external comic content is preserved", read(external_descriptor) == "external comic sentinel\n")
    preserve_target("ordinary document", descriptor_directory .. "/chapter.epub")
    preserve_target("other comic filename", descriptor_directory .. "/another.bcomic")
    preserve_target("wrong namespace layout", data_root .. "/documents/comic/episode/revision/chapter.bcomic")
    preserve_target("namespace prefix collision", data_root .. "-foreign/accounts/a/documents/c/e/r/chapter.bcomic")
    preserve_target("parent traversal", descriptor_directory .. "/../revision/chapter.bcomic")
    preserve_target("embedded NUL", owned_descriptor .. "\0suffix")
    check("non-string startup targets are not owned", not Bootstrap.isOwnedDescriptor(false)
        and not Bootstrap.isOwnedDescriptor(42) and not Bootstrap.isOwnedDescriptor({}))

    local saved_descriptor = owned_descriptor .. ".original"
    assert(os.rename(owned_descriptor, saved_descriptor))
    assert(lfs.link(external_descriptor, owned_descriptor, true))
    preserve_target("descriptor symlink", owned_descriptor)
    check("fallback preserves the descriptor symlink target", read(external_descriptor) == "external comic sentinel\n"
        and lfs.symlinkattributes(owned_descriptor, "mode") == "link")
    assert(os.remove(owned_descriptor))
    assert(os.rename(saved_descriptor, owned_descriptor))

    local comic_directory = data_root .. "/accounts/bootstrap-account/documents/comic"
    local saved_comic_directory = comic_directory .. ".original"
    assert(os.rename(comic_directory, saved_comic_directory))
    assert(lfs.link(saved_comic_directory, comic_directory, true))
    preserve_target("descriptor ancestor symlink", owned_descriptor)
    check("ancestor symlink target is preserved", read(owned_descriptor) == descriptor_content)
    assert(os.remove(comic_directory))
    assert(os.rename(saved_comic_directory, comic_directory))

    local saved_data_root = data_root .. ".original"
    assert(os.rename(data_root, saved_data_root))
    assert(lfs.link(saved_data_root, data_root, true))
    preserve_target("namespace root symlink", owned_descriptor)
    check("namespace root symlink target is preserved", read(owned_descriptor) == descriptor_content)
    assert(os.remove(data_root))
    assert(os.rename(saved_data_root, data_root))

    local custom_root = output .. "/custom-namespace"
    local custom_directory = custom_root .. "/accounts/a/documents/c/e/r"
    make_directory(custom_directory)
    local custom_descriptor = custom_directory .. "/chapter.bcomic"
    write(custom_descriptor, descriptor_content)
    preserve_target("unselected custom namespace", custom_descriptor)
    check("explicit custom namespace is recognized", Bootstrap.isOwnedDescriptor(custom_descriptor, custom_root))
    G_reader_settings:saveSetting("lastfile", custom_descriptor)
    fallback = Bootstrap.prepareFallback(custom_root)
    check("explicit custom namespace fallback clears its own target", fallback and fallback.cleared
        and G_reader_settings:readSetting("lastfile") == nil
        and G_reader_settings:readSetting("start_with") == "last")
    check("all fallback sentinels remain intact", read(owned_descriptor) == descriptor_content
        and read(custom_descriptor) == descriptor_content and read(history_path) == history_content
        and read(anchor_path) == anchor_content)

    local Provider = require("bilicomics/reader/document")
    local Registry = require("document/documentregistry")
    local original_register, original_resolver = Provider.register, Provider.setServicesResolver
    local register_calls, resolver_calls, runtime_calls = 0, 0, 0
    local captured_resolver
    Provider.register = function(self, registry)
        register_calls = register_calls + 1
        return original_register(self, registry)
    end
    Provider.setServicesResolver = function(self, fn)
        resolver_calls = resolver_calls + 1
        captured_resolver = fn
        return original_resolver(self, fn)
    end
    local services = { synthetic = true }
    local controller = { account = { key = "bootstrap-account", reader_services = services } }
    local runtime_mode = "normal"
    local reentrant_result
    -- Block construction of the production runtime and all network acquisition.
    local original_runtime = package.loaded["bilicomics/runtime"]
    package.loaded["bilicomics/runtime"] = { get = function(argument)
        runtime_calls = runtime_calls + 1
        assert(argument == nil)
        if runtime_mode == "error" then error("Synthetic runtime initialization failure") end
        if runtime_mode == "reentrant" then reentrant_result = captured_resolver("bootstrap-account") end
        return controller
    end }
    check("provider was not previously registered", Registry.known_providers[Provider.provider] == nil)
    check("provider registration succeeds", Bootstrap.register(fixture_plugin) == true)
    check("registration uses the real native registry", Registry.known_providers[Provider.provider] ~= nil
        and register_calls == 1 and resolver_calls == 1)
    check("registration keeps runtime construction lazy", runtime_calls == 0)
    local registered_path = package.path
    check("repeated registration succeeds", Bootstrap.register(fixture_plugin) == true)
    check("registration is idempotent", register_calls == 1 and resolver_calls == 1 and package.path == registered_path)
    check("lazy resolver returns the requested account", captured_resolver("bootstrap-account") == services
        and runtime_calls == 1)
    check("lazy resolver rejects another account", captured_resolver("another-account") == nil)
    controller.closed = true
    check("lazy resolver rejects a closed controller", captured_resolver("bootstrap-account") == nil)
    controller.closed = false
    runtime_mode = "error"
    check("lazy resolver handles runtime construction errors", captured_resolver("bootstrap-account") == nil)
    runtime_mode = "normal"
    check("resolver guard recovers after an initialization error", captured_resolver("bootstrap-account") == services)
    runtime_mode = "reentrant"
    local before_reentry = runtime_calls
    check("recursive runtime initialization returns the outer services", captured_resolver("bootstrap-account") == services)
    check("recursive resolver entry is bounded", reentrant_result == nil and runtime_calls == before_reentry + 1)
    runtime_mode = "normal"
    package.loaded["bilicomics/bootstrap"] = nil
    local reloaded_bootstrap = require("bilicomics/bootstrap")
    local before_reload = runtime_calls
    check("bootstrap reload accepts an existing provider", reloaded_bootstrap.register(fixture_plugin) == true)
    check("bootstrap reload does not duplicate native providers", register_calls == 1 and resolver_calls == 2)
    check("bootstrap reload remains lazy", runtime_calls == before_reload)
    Provider.register, Provider.setServicesResolver = original_register, original_resolver
    package.loaded["bilicomics/runtime"] = original_runtime
end

local ok, failure = xpcall(run, debug.traceback)
report.ok = ok
if not ok then report.error = failure end
write(output .. "/bootstrap-results.json", json.encode(report, { pretty = true }))
print("BOOTSTRAP_SPEC_JSON=" .. json.encode(report))
if not ok then os.exit(1) end
