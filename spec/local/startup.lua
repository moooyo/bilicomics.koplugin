-- Supported early user patch: guard first, then the actual native plugin entry.
local profile = assert(os.getenv("BILICOMICS_ACCEPTANCE_PROFILE"))
local plugin = assert(os.getenv("BILICOMICS_ACCEPTANCE_PLUGIN"))
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
package.preload["bilicomics/runtime"] = function() error("The local acceptance guard was not installed") end
assert(not package.loaded["bilicomics/runtime"], "The acceptance guard must precede Runtime")
assert(assert(loadfile(profile .. "/support/readonly_guard.lua"))().install(profile))
local online_observer
if os.getenv("BILICOMICS_ACCEPTANCE_REFRESH_FAVORITES") == "1" then
    online_observer = assert(loadfile(profile .. "/support/renewable_online.lua"))().install(profile)
end
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
            local function finishStartup()
            if app.account.key == "anonymous" and app.account.session == nil and screens.route == "continue"
                and not screens.dialog and not screens.session_input then
                UIManager:forceRePaint()
                require("device").screen.bb:writePNG(profile .. "/native-ui-before-import.png")
                if os.getenv("BILICOMICS_ACCEPTANCE_CAPTURE_ACCOUNT") == "1" then
                    screens:showAccount()
                    UIManager:forceRePaint()
                    require("device").screen.bb:writePNG(profile .. "/native-account-before-import.png")
                    screens:showLibrary("continue")
                end
            end
            local file = assert(io.open(profile .. "/native-ui-ready.json", "wb"))
            file:write(require("rapidjson").encode({ native_plugin_ui_opened = true, readonly_guard_installed = true,
                selected_plugin_loaded = true, source_refresh_available = type(app.refreshDownloadSources) == "function",
                version_replacement_available = type(app.replaceDownloadVersion) == "function",
                qr_signin_available = type(app.beginQRLogin) == "function",
                session_maintenance_available = app.account.session_manager ~= nil,
                session_present = app.account.session ~= nil,
                session_valid = app.account.session_valid == true,
                renewable_session = app.account.session ~= nil and app.account.session.refresh_token ~= nil,
                invalidated_session = app.account.authentication_invalidated == true }), "\n")
            file:close()
            local autoclose = tonumber(os.getenv("BILICOMICS_ACCEPTANCE_AUTOCLOSE")) or 0
            if autoclose > 0 and autoclose <= 30 then
                UIManager:scheduleIn(autoclose, function()
                    require("ui/elements/common_exit_menu_table").exit.callback()
                    local active = require("bilicomics/runtime").peek()
                    local closed = assert(io.open(profile .. "/native-ui-closed.json", "wb"))
                    closed:write(require("rapidjson").encode({ native_exit_requested = true,
                        runtime_closed = active == nil or active.closed == true }), "\n")
                    closed:close()
                end)
            end
            end
            local import_file = os.getenv("BILICOMICS_ACCEPTANCE_IMPORT_FILE")
            if import_file and import_file ~= "" then
                assert(import_file == assert(profile:match("^(.*)/[^/]+$")) .. "/fresh-auth-input.json",
                    "Only the candidate's one-time authentication input may be imported")
                assert(app.account.key == "anonymous" and app.account.session == nil,
                    "The one-time import requires a fresh anonymous candidate profile")
                local handle = assert(io.open(import_file, "rb"))
                local input = handle:read(131073); handle:close()
                assert(input and #input <= 131072, "The one-time authentication input is invalid")
                local raw_runner = app.account.raw_runner
                local submissions = raw_runner.sequence or 0
                app:importSession(input, function(value, err)
                    local record = assert(io.open(profile .. "/native-session-import.json", "wb"))
                    record:write(require("rapidjson").encode({ succeeded = value ~= nil and value.session_valid == true,
                        account_changed = app.account.key ~= "anonymous", session_present = app.account.session ~= nil,
                        session_valid = app.account.session_valid == true,
                        renewable_session = app.account.session ~= nil and app.account.session.refresh_token ~= nil,
                        validation_worker_submissions = (raw_runner.sequence or 0) - submissions,
                        production_runner = getmetatable(raw_runner) == require("bilicomics/jobs/runner"),
                        error_kind = err and err.kind, error_code = err and err.code, http_status = err and err.status }), "\n")
                    record:close()
                    if value then assert(os.remove(import_file), "The one-time input could not be removed") end
                    finishStartup()
                end)
                input = nil
            else
                if online_observer then online_observer:refreshOnce(app, finishStartup)
                else finishStartup() end
            end
        end)
        return
    end
    if require("socket").gettime() - started < 30 then UIManager:scheduleIn(0.1, openNativeUI) end
end
UIManager:nextTick(openNativeUI)
