-- Supported early user patch: guard first, then the actual native plugin entry.
local profile = assert(os.getenv("BILICOMICS_ACCEPTANCE_PROFILE"))
local plugin = assert(os.getenv("BILICOMICS_ACCEPTANCE_PLUGIN"))
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
package.preload["bilicomics/runtime"] = function() error("The local acceptance guard was not installed") end
assert(not package.loaded["bilicomics/runtime"], "The acceptance guard must precede Runtime")
assert(assert(loadfile(profile .. "/support/readonly_guard.lua"))().install(profile))
G_reader_settings:saveSetting("extra_plugin_paths", { assert(plugin:match("^(.*)/[^/]+$")) })
assert(require("bilicomics/bootstrap").installStartupPatch(plugin))
package.preload["bilicomics/runtime"] = nil
local UIManager = require("ui/uimanager")
local FileManager = require("apps/filemanager/filemanager")
local ReaderUI = require("apps/reader/readerui")
local started = require("socket").gettime()
local function openNativeUI()
    local host = ReaderUI.instance or FileManager.instance
    if host and host.bilicomics then
        local handler = host.bilicomics.onShowBiliComics
        -- PluginLoader wraps native event handlers in callable HandlerSandbox tables.
        local entry = type(handler) == "table" and handler.f or handler
        assert(type(entry) == "function" and debug.getinfo(entry, "S").source == "@" .. plugin .. "/main.lua",
            "The native plugin entry does not match the selected acceptance build")
        assert(debug.getinfo(require("bilicomics/runtime").get, "S").source == "@" .. plugin .. "/bilicomics/runtime.lua",
            "The loaded Runtime does not match the selected acceptance build")
        host.bilicomics:onShowBiliComics()
        UIManager:nextTick(function()
            local app, screens = require("bilicomics/runtime").peek()
            assert(app and not app.closed and app.account and screens and screens.widget,
                "The native plugin UI did not initialize successfully")
            if app.account.key == "anonymous" and app.account.session == nil and screens.route == "continue"
                and not screens.dialog and not screens.session_input then
                UIManager:forceRePaint()
                require("device").screen.bb:writePNG(profile .. "/native-ui-before-import.png")
            end
            local file = assert(io.open(profile .. "/native-ui-ready.json", "wb"))
            file:write(require("rapidjson").encode({ native_plugin_ui_opened = true, readonly_guard_installed = true,
                selected_plugin_loaded = true, source_refresh_available = type(app.refreshDownloadSources) == "function",
                version_replacement_available = type(app.replaceDownloadVersion) == "function" }), "\n")
            file:close()
        end)
        return
    end
    if require("socket").gettime() - started < 30 then UIManager:scheduleIn(0.1, openNativeUI) end
end
UIManager:nextTick(openNativeUI)
