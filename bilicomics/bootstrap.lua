-- BiliComics provider registration before KOReader selects its startup document.
local Bootstrap = {}
local registered = false
local resolving = false
local marker = "-- BiliComics managed startup provider bootstrap v1\n"
local patch_name = "2-bilicomics-provider.lua"
local temporary_sequence = 0

local function failure(kind, code, message)
    return nil, { kind = kind, code = code, message = message, retryable = kind == "storage" }
end

local function absolute(path)
    local lfs = require("libs/libkoreader-lfs")
    if path:sub(1, 1) ~= "/" then path = lfs.currentdir() .. "/" .. path end
    path = path:gsub("/%./", "/"):gsub("/+$", "")
    for part in path:gmatch("[^/]+") do assert(part ~= "..", "The plugin path must be resolved") end
    return path
end

function Bootstrap.pluginPath()
    local source = debug.getinfo(1, "S").source
    local path = source:match("^@(.+)/bilicomics/bootstrap%.lua$")
    return path and absolute(path)
end

function Bootstrap.register(plugin_path)
    if registered then return true end
    plugin_path = plugin_path or Bootstrap.pluginPath()
    if plugin_path then
        plugin_path = absolute(plugin_path)
        package.path = plugin_path .. "/?.lua;" .. plugin_path .. "/?/init.lua;" .. package.path
    end
    local Provider = require("bilicomics/reader/document")
    local registry = require("document/documentregistry")
    if not registry.known_providers[Provider.provider] then Provider:register(registry) end
    Provider:setServicesResolver(function(requested_key)
        if resolving then return nil end
        resolving = true
        -- Runtime construction may install the controller's own resolver. Return the
        -- requested services directly; never call the provider resolver recursively.
        local ok, controller = pcall(function() return require("bilicomics/runtime").get(nil) end)
        resolving = false
        if not ok or not controller or controller.closed then return nil end
        local account = controller.account
        if account and requested_key == account.key then return account.reader_services end
        return nil
    end)
    registered = true
    return true
end

function Bootstrap.startupCapability()
    local is_android, android = pcall(require, "android")
    if is_android and android.prop and android.prop.flavor == "fdroid" then
        return failure("capability", "fdroid", "This KOReader build disables startup user patches")
    end
    local userpatch = require("userpatch")
    if userpatch.arePatchesDisabled and userpatch.arePatchesDisabled() then
        return failure("capability", "patches_disabled", "KOReader startup user patches are disabled")
    end
    return { available = true }
end

function Bootstrap.isOwnedDescriptor(path, data_root)
    if type(path) ~= "string" or path:find("%z") then return false end
    local ok, owned = pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local root = absolute(data_root or (require("datastorage"):getDataDir() .. "/bilicomics"))
        path = absolute(path)
        if path:sub(1, #root + 1) ~= root .. "/" then return false end
        local relative = path:sub(#root + 2)
        if not relative:match("^accounts/[^/]+/documents/[^/]+/[^/]+/[^/]+/chapter%.bcomic$") then return false end
        local current = root
        if lfs.symlinkattributes(current, "mode") ~= "directory" then return false end
        for component in relative:gmatch("[^/]+") do
            current = current .. "/" .. component
            if lfs.symlinkattributes(current, "mode") == "link" then return false end
        end
        return true
    end)
    return ok and owned == true
end

-- Call only when startup bootstrap is unavailable. Keep native history, descriptor
-- identity and source anchors; only remove the unsafe automatic startup target.
function Bootstrap.prepareFallback(data_root)
    local file = G_reader_settings:readSetting("lastfile")
    if not Bootstrap.isOwnedDescriptor(file, data_root) then return { cleared = false } end
    local ok = pcall(function()
        G_reader_settings:delSetting("lastfile")
        G_reader_settings:flush()
    end)
    if not ok then return failure("storage", "startup_fallback", "The safe startup target could not be saved") end
    return { cleared = true, file = file }
end

local function read(path, limit)
    local file = assert(io.open(path, "rb"))
    local data = file:read(limit + 1)
    file:close()
    assert(#data <= limit, "The startup patch exceeds its size limit")
    return data
end

function Bootstrap.installStartupPatch(plugin_path)
    local capability, capability_error = Bootstrap.startupCapability()
    if not capability then return nil, capability_error end
    local lfs = require("libs/libkoreader-lfs")
    local ffiutil = require("ffi/util")
    local temporary
    local ok, result, err = pcall(function()
        plugin_path = absolute(assert(plugin_path or Bootstrap.pluginPath(), "The plugin directory is required"))
        local source_path = plugin_path .. "/patches/" .. patch_name
        assert(lfs.symlinkattributes(source_path, "mode") == "file", "The packaged startup patch is missing")
        local source = read(source_path, 32768)
        assert(source:sub(1, #marker) == marker, "The packaged startup patch has an invalid owner")
        local changes
        source, changes = source:gsub("local preferred_path = nil", function()
            return "local preferred_path = " .. string.format("%q", plugin_path)
        end, 1)
        assert(changes == 1, "The packaged startup patch has no installation path slot")
        local directory = absolute(require("datastorage"):getPatchesDir())
        assert(require("util").makePath(directory), "Cannot create the startup patch directory")
        assert(lfs.symlinkattributes(directory, "mode") == "directory", "Invalid startup patch directory")
        local destination = directory .. "/" .. patch_name
        local previous
        local mode = lfs.symlinkattributes(destination, "mode")
        if mode then
            if mode ~= "file" then
                return failure("capability", "foreign_patch", "The startup patch path is already occupied")
            end
            previous = read(destination, 32768)
            if previous:sub(1, #marker) ~= marker then
                return failure("capability", "foreign_patch", "An existing startup patch belongs to another owner")
            end
            if previous == source then return { path = destination, installed = true, changed = false } end
        end
        repeat
            temporary_sequence = temporary_sequence + 1
            temporary = destination .. ".temporary." .. tostring(os.time()) .. "." .. temporary_sequence
        until not lfs.symlinkattributes(temporary)
        local file = assert(io.open(temporary, "wb"))
        local written, write_error = file:write(source)
        if written then written, write_error = file:flush() end
        if written then written, write_error = ffiutil.fsyncOpenedFile(file, true) end
        local closed, close_error = file:close()
        assert(written and closed, write_error or close_error)
        -- Recheck immediately before replacement to preserve concurrent external edits.
        local current_mode = lfs.symlinkattributes(destination, "mode")
        if previous then
            assert(current_mode == "file" and read(destination, 32768) == previous,
                "The startup patch changed during installation")
        else
            assert(current_mode == nil, "The startup patch appeared during installation")
        end
        assert(os.rename(temporary, destination), "Cannot commit the startup patch")
        temporary = nil
        assert(ffiutil.fsyncDirectory(directory), "Cannot persist the startup patch directory")
        return { path = destination, installed = true, changed = true }
    end)
    if temporary then pcall(os.remove, temporary) end
    if not ok then return failure("storage", "startup_patch_install", "The startup provider bootstrap could not be installed safely") end
    return result, err
end

return Bootstrap
