-- Observation-only late user patch for the official reader.lua startup probe.
-- It never registers a document provider or initializes a plugin itself.
local output = assert(os.getenv("BILICOMICS_STARTUP_PROBE_ROOT"))
local Registry = require("document/documentregistry")
local PluginLoader = require("pluginloader")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local json = require("rapidjson")

local report = {
    entrypoint = "official reader.lua",
    plugins_loaded_at_late_patch = PluginLoader.enabled_plugins ~= nil,
    provider_at_late_patch = Registry:getProviders(output .. "/chapter.bcomic") ~= nil,
}
local original = ReaderUI.showReader
ReaderUI.showReader = function(self, file, ...)
    if not report.first_show then
        local runtime = package.loaded["bilicomics/runtime"]
        report.first_show = {
            file = file,
            provider_available = Registry:hasProvider(file),
            plugins_loaded = PluginLoader.enabled_plugins ~= nil,
            runtime_initialized = runtime and runtime.peek() ~= nil or false,
        }
    end
    return original(self, file, ...)
end
UIManager:scheduleIn(1, function()
    if rawget(_G, "bilicomics_startup_bootstrap") ~= nil then
        report.fixture_bootstrap_called = _G.bilicomics_startup_bootstrap == true
    end
    if rawget(_G, "bilicomics_startup_plugin_init") ~= nil then
        report.fixture_plugin_initialized = _G.bilicomics_startup_plugin_init == true
    end
    report.reader_opened = ReaderUI.instance ~= nil
    report.reader_provider = ReaderUI.instance and ReaderUI.instance.document.provider or nil
    report.actual_plugin_present = ReaderUI.instance and ReaderUI.instance.bilicomics ~= nil or false
    report.reader_integration_attached = ReaderUI.instance and ReaderUI.instance.bilicomics_integration ~= nil or false
    if ReaderUI.instance then
        report.visible_pixel = require("device").screen.bb:getPixel(300, 100):getR()
    end
    report.filemanager_opened = require("apps/filemanager/filemanager").instance ~= nil
    local file = assert(io.open(output .. "/startup-results.json", "wb"))
    file:write(json.encode(report)); file:close()
    if ReaderUI.instance then ReaderUI.instance:onClose() end
    local manager = require("apps/filemanager/filemanager").instance
    if manager then manager:onClose() end
    UIManager:quit()
end)
