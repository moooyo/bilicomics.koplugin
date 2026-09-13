-- Native authentication acceptance driver. Run only through the remote launcher.
require("setupkoenv")
local source, work, phase = assert(arg[1]), assert(arg[2]), assert(arg[3])
assert(phase == "login" or phase == "restart" or phase == "rehearse")
assert(os.getenv("BILI_AUTH_DRIVER") == "1")
if phase ~= "rehearse" then assert(os.getenv("BILI_LIVE_AUTHORIZED") == "1") end
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local json = require("rapidjson")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local Files = require("bilicomics/storage/files")
local driver_root = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local Scope = assert(loadfile(driver_root .. "/live_acceptance_scope.lua"))()
local private = work .. "/private"
local parent_pid = tonumber(ffi.C.getpid())
local result_path = private .. "/" .. phase .. "-driver.json"
local qr_path = private .. "/qr.png"
local app, login, UIManager, Device, Runtime, screens, plugin, menu
local runners, stopping, confirmed = {}, false, false
local checked_info, bookshelf_entered, native_menu_opened
local visible_cover_urls, approved_covers = {}, {}
local report = { schema = 1, code = 10, passed = false, running = true,
    checks = { live_network_enabled = phase ~= "rehearse", source_worker_unmodified = true,
        controller_initialized = false, native_dialog_visible = false, qr_ready = false,
        login_confirmed = false, saved_session_verified = false, restart_loaded_session = false,
        cookie_info_verified = false, server_refresh_required = false, refresh_verified = false,
        confirmation_verified = false, maintenance_verified = false, workers_closed = false,
        production_main_initialized = false, native_menu_opened_bookshelf = false,
        native_menu_opened_account = false, native_account_qr_button_used = false,
        site_context_saved = false, favorites_sync_completed = false, history_sync_completed = false,
        automatic_bookshelf_sync_verified = false, credential_rotation_deferred = false },
    counts = { workers_started = 0, workers_completed = 0, heartbeats = 0,
        generateQR = 0, pollQR = 0, cookieInfo = 0, refreshSession = 0, confirmRefresh = 0,
        ensureSiteContext = 0, library_favorites = 0, library_history = 0, visible_cover = 0,
        covers_completed = 0, covers_failed = 0, bookshelf_help_acknowledgements = 0,
        rejected_submissions = 0, session_saves = 0 }, network = {} }

local function write(path, value) Files.atomicWrite(path, json.encode(value)) end
local function publicState() write(result_path, report) end
local function removeQR()
    if Files.exists(qr_path) then Files.assertRegular(qr_path, private); assert(os.remove(qr_path)) end
    report.checks.qr_ready = false
end
local function collectNetwork()
    local total = {}
    for name in lfs.dir(private) do
        if name:match("^" .. phase .. "%-transport%-%d+%.json$") then
            local packet = assert(json.decode(Files.read(private .. "/" .. name, 65536)))
            for category, values in pairs(packet) do
                local item = total[category] or { requests = 0, responses = 0, transmitted = 0, rejections = 0 }
                for _, key in ipairs({ "requests", "responses", "transmitted", "rejections" }) do
                    item[key] = item[key] + (tonumber(values[key]) or 0)
                end
                if type(values.http_code) == "number" then item.http_code = values.http_code end
                if type(values.service_code) == "number" then item.service_code = values.service_code end
                total[category] = item
            end
        end
    end
    report.network = total
end
local function savedSessionMatches()
    local active = app and app.account
    if not active or not active.session or not active.session_valid then return false end
    local saved = app.session_storage:load(active.key)
    if not saved then return false end
    local path = assert(app.session_storage:path(active.key))
    local info = lfs.symlinkattributes(path)
    return saved:sameCredentials(active.session) and saved.account_key == active.key
        and saved.pending_refresh_token == active.session.pending_refresh_token
        and saved.refresh_blocked == active.session.refresh_blocked
        and saved.confirmation_blocked == active.session.confirmation_blocked
        and info and info.mode == "file" and info.permissions == "rw-------"
        and tonumber(info.uid) == tonumber(ffi.C.getuid())
end
local function shutdown(code, passed)
    if stopping then return end
    stopping = true
    report.code, report.passed, report.running = code, passed == true, false
    pcall(removeQR)
    if login then pcall(login.close, login) end
    if app then
        local closed = pcall(function()
            if screens then screens:close() end
            if Runtime then Runtime.close() else app:close() end
        end)
        report.checks.controller_closed = closed and app.closed == true
    end
    local closed = true
    for runner in pairs(runners) do
        closed = closed and runner.stopped and next(runner.tasks) == nil and #runner.queue == 0
    end
    report.checks.workers_closed = closed
    if not closed or not report.checks.controller_closed then report.passed = false end
    if not pcall(collectNetwork) then report.passed = false; report.code = 49 end
    publicState()
    if UIManager then UIManager:quit() end
end
local function fail() shutdown(49, false) end

local ok = xpcall(function()
    -- The guard observes the production transport and denies every unrelated endpoint.
    -- It never records URLs, headers, request bodies, identities, cookies or QR keys.
    local Transport = require("bilicomics/protocol/transport")
    local transport_request = Transport.request
    local child_events = {}
    local function event(category, key, value)
        local item = child_events[category] or { requests = 0, responses = 0, transmitted = 0, rejections = 0 }
        item[key] = value ~= nil and value or item[key] + 1
        child_events[category] = item
        write(private .. "/" .. phase .. "-transport-" .. tostring(ffi.C.getpid()) .. ".json", child_events)
    end
    function Transport:request(request)
        local category = Scope.transportCategory(request, phase)
        if not category and phase ~= "rehearse" and Scope.coverAllowed(request, approved_covers) then category = "visible_cover" end
        local allowed = category ~= nil and tonumber(ffi.C.getpid()) ~= parent_pid
            and not Files.exists(private .. "/stop")
        if not allowed then
            event("rejected", "rejections")
            return nil, { kind = "scope_guard", code = "authentication_scope", transmitted = false,
                retryable = false, message = "The authentication acceptance scope rejected this request." }
        end
        event(category, "requests")
        local value, err = transport_request(self, request)
        if value then
            event(category, "responses")
            if type(value.status) == "number" then event(category, "http_code", value.status) end
            local decoded_ok, decoded = pcall(json.decode, value.body or "")
            if decoded_ok and type(decoded) == "table" and type(decoded.code) == "number" then
                event(category, "service_code", decoded.code)
            end
        end
        if value and value.transmitted == true or err and err.transmitted == true then event(category, "transmitted") end
        return value, err
    end

    local Runner = require("bilicomics/jobs/runner")
    local runner_new, runner_submit, runner_start = Runner.new, Runner.submit, Runner._start
    Runner.new = function(options)
        assert(not options or options.worker == nil)
        local runner = runner_new(options); runners[runner] = true; return runner
    end
    function Runner:submit(request, options, callback)
        local method = Scope.submissionName(request, phase, checked_info)
        if request.kind == "download_cover" and phase ~= "rehearse" and screens and screens.route == "favorites"
            and visible_cover_urls[request.url] and Files.within(request.temporary_path, app.account.root .. "/covers")
            and request.max_bytes == 4 * 1024 * 1024 then
            method = "visible_cover"
            approved_covers[request.url] = request.temporary_path
        end
        local limits = { generateQR = 1, pollQR = 100, cookieInfo = 2, refreshSession = 2,
            ensureSiteContext = 2, library_favorites = 2, library_history = 2, visible_cover = 24 }
        local allowed = method ~= nil and limits[method] ~= nil and report.counts[method] < limits[method]
        if not allowed then
            report.counts.rejected_submissions = report.counts.rejected_submissions + 1
            error("The authentication acceptance scope rejected a worker")
        end
        report.counts[method] = report.counts[method] + 1
        publicState()
        return runner_submit(self, request, options, function(value, err, update)
            report.counts.workers_completed = report.counts.workers_completed + 1
            if method == "cookieInfo" and value then
                assert(type(value.refresh) == "boolean" and type(value.timestamp) == "number")
                checked_info = { refresh = value.refresh, timestamp = value.timestamp }
                report.checks.cookie_info_verified = true
                report.checks.server_refresh_required = value.refresh
                if Scope.rotationDeferred(value) then
                    report.deferred, report.checks.credential_rotation_deferred = true, true
                    report.checks.saved_session_verified = savedSessionMatches()
                    publicState()
                    UIManager:nextTick(function() shutdown(24, false) end)
                    return
                end
            elseif method == "library_favorites" and value and not err then report.checks.favorites_sync_completed = true
            elseif method == "library_history" and value and not err then report.checks.history_sync_completed = true
            elseif method == "visible_cover" then
                local key = value and not err and "covers_completed" or "covers_failed"
                report.counts[key] = report.counts[key] + 1
            end
            if err and type(err.code) == "number" then report.service_code = err.code end
            if err and type(err.status) == "number" then report.http_code = err.status end
            if callback then return callback(value, err, update) end
        end)
    end
    function Runner:_start(task)
        runner_start(self, task)
        if task.pid then
            assert(tonumber(task.pid) ~= parent_pid)
            report.counts.workers_started = report.counts.workers_started + 1
        end
    end

    G_defaults = require("luadefaults"):open()
    local DataStorage = require("datastorage")
    assert(Files.within(DataStorage:getDataDir(), private))
    G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
    local disabled = {}
    for entry in lfs.dir("plugins") do
        local name = entry:match("^(.*)%.koplugin$")
        if name then disabled[name] = true end
    end
    G_reader_settings:saveSetting("plugins_disabled", disabled)
    Device = require("device")
    require("document/canvascontext"):init(Device)
    require("gettext").current_lang = "zh_CN"
    UIManager = require("ui/uimanager")
    local keeper = require("ui/widget/container/widgetcontainer"):new{}
    UIManager:show(keeper)
    local Controller = require("bilicomics/controller")
    local request_cover = Controller.requestCover
    function Controller:requestCover(comic_id)
        local comic = self:getComic(comic_id)
        local cover = comic and require("bilicomics/cover_source").resolve(comic.cover_url)
        if self == app and screens and screens.route == "favorites" and cover then visible_cover_urls[cover.url] = true end
        return request_cover(self, comic_id)
    end
    local Plugin = assert(loadfile(source .. "/main.lua"))()
    local registered
    plugin = Plugin:new{ ui = { menu = { registerToMainMenu = function(_, value) registered = value end } } }
    assert(registered == plugin and not plugin.initialization_error)
    Runtime = require("bilicomics/runtime")
    app, screens = Runtime.peek()
    assert(app and screens)
    report.checks.production_main_initialized = true
    report.checks.controller_initialized = app.account ~= nil and app.account.raw_runner ~= nil
    local storage_save = app.session_storage.save
    function app.session_storage:save(session)
        local saved, err = storage_save(self, session)
        if saved then report.counts.session_saves = report.counts.session_saves + 1 end
        return saved, err
    end
    menu = {}
    plugin:addToMainMenu(menu)
    assert(menu.bilicomics and type(menu.bilicomics.callback) == "function"
        and type(menu.bilicomics.hold_callback) == "function")
    local function openBookshelf()
        menu.bilicomics.callback()
        assert(screens.route == "favorites" and screens.widget)
        report.checks.native_menu_opened_bookshelf = true
        native_menu_opened = true
    end
    local function sessionHasSiteContext()
        local session = app.account.session
        if not session or not session.cookies.buvid3 then return false end
        local saved = app.session_storage:load(app.account.key)
        local header = saved and saved:cookieHeader("manga.bilibili.com") or ""
        return saved and saved.cookies.buvid3 == session.cookies.buvid3 and header:find("buvid3=", 1, true) ~= nil
    end
    local function finishBookshelf(code)
        local synchronized = report.checks.favorites_sync_completed and report.checks.history_sync_completed
        if phase ~= "restart" and not synchronized then return false end
        if screens.dialog or screens.context_dialog then
            local dialog = screens.dialog
            local translate = require("bilicomics/ui/i18n")
            local heading = translate("Bookshelf help") .. "\n\n"
            if dialog and dialog == screens.context_dialog and type(dialog.title) == "string"
                and dialog.title:sub(1, #heading) == heading then
                local button
                for _, row in ipairs(dialog.buttons or {}) do
                    for _, item in ipairs(row) do
                        if item.text == translate("Got it") and type(item.callback) == "function" then button = item end
                    end
                end
                assert(button and button.enabled ~= false and phase ~= "restart"
                    and report.counts.bookshelf_help_acknowledgements == 0)
                report.counts.bookshelf_help_acknowledgements = report.counts.bookshelf_help_acknowledgements + 1
                button.callback()
            end
            return false
        end
        -- A queued first-visit dialog or its deferred repaint must run before completion is considered.
        if screens.bookshelf_help_ticket then return false end
        for runner in pairs(runners) do if next(runner.tasks) or #runner.queue > 0 then return false end end
        if app.account.session_manager.active or app.notify_pending then return false end
        assert(screens.route == "favorites" and screens.widget)
        local sync = app:getBookshelfSyncState()
        if sync.syncing or not sync.has_cache or sync.error then return false end
        local items, cards = app:getBookshelfItems(), screens.cards or {}
        if #items > 0 and not screens.bookshelf_help_seen then return false end
        local columns, rows = screens.grid_columns, screens.grid_rows
        if type(columns) ~= "number" or type(rows) ~= "number" or columns < 1 or rows < 1 then return false end
        local capacity = columns * rows
        local offset = ((screens.page or 1) - 1) * capacity
        local expected = math.min(capacity, math.max(0, #items - offset))
        if #cards ~= expected or screens.widget.view_page ~= screens.page
            or screens.widget.view_route ~= "favorites" or screens.widget.view_epoch ~= screens.epoch then return false end
        local members, seen = {}, {}
        for _, comic in ipairs(items) do members[tostring(comic.id)] = true end
        local order = screens.bookshelf_order_ids or {}
        for index, card in ipairs(cards) do
            local key = card.comic and tostring(card.comic.id)
            if not key or not members[key] or seen[key] or order[offset + index] ~= key then return false end
            seen[key] = true
        end
        local view = app:getBookshelfViewState()
        if #items > 0 and (not view.help_seen or phase == "login"
            and report.counts.bookshelf_help_acknowledgements ~= 1) then return false end
        UIManager:forceRePaint()
        local size = screens.widget.content:getSize()
        assert(size.w <= Device.screen:getWidth() and size.h <= Device.screen:getHeight())
        report.checks.bookshelf_help_dismissed = #items == 0 or view.help_seen == true
        report.checks.bookshelf_cards_match_current_page = true
        report.checks.bookshelf_native_frame_rendered = true
        report.checks.bookshelf_unobstructed = screens.dialog == nil and screens.context_dialog == nil
        report.counts.expected_visible_cards = expected
        report.checks.automatic_bookshelf_sync_verified = synchronized == true
        report.checks.site_context_saved = sessionHasSiteContext() == true
        report.checks.saved_session_verified = savedSessionMatches()
        report.counts.favorite_items = #app:getLibrary("favorites")
        report.counts.history_items = #app:getLibrary("history")
        report.counts.visible_cards = #(screens.cards or {})
        if phase == "restart" then
            local previous = assert(json.decode(Files.read(private .. "/login-driver.json", 2 * 1024 * 1024)))
            report.checks.bookshelf_cache_restored = previous.checks.automatic_bookshelf_sync_verified == true
                and report.counts.favorite_items == previous.counts.favorite_items
                and report.counts.history_items == previous.counts.history_items
            assert(report.checks.bookshelf_cache_restored)
        end
        report.checks.visible_cover_workers_settled = report.counts.visible_cover
            == report.counts.covers_completed + report.counts.covers_failed
        write(private .. "/session-input-path.json", { session_path = assert(app.session_storage:path(app.account.key)) })
        shutdown(code, report.checks.saved_session_verified and report.checks.site_context_saved
            and report.checks.visible_cover_workers_settled and report.checks.bookshelf_unobstructed
            and report.checks.bookshelf_cards_match_current_page and report.checks.bookshelf_help_dismissed)
        return true
    end
    local function tick()
        if stopping then return end
        local success = pcall(function()
            report.counts.heartbeats = report.counts.heartbeats + 1
            if Files.exists(private .. "/stop") then shutdown(42, false); return end
            if phase ~= "restart" then
                if confirmed then
                    report.checks.login_confirmed = true
                    if not bookshelf_entered then removeQR(); bookshelf_entered = true; openBookshelf() end
                    if finishBookshelf(20) then return end
                elseif login and (login.status == "waiting" or login.status == "scanned") then
                    if not report.checks.qr_ready then
                        UIManager:forceRePaint()
                        local size = assert(login.dialog).movable:getSize()
                        assert(size.w <= Device.screen:getWidth() and size.h <= Device.screen:getHeight())
                        Device.screen.bb:writePNG(qr_path)
                        report.checks.qr_ready = true
                    end
                    report.code = login.status == "scanned" and 12 or 11
                elseif login and login.status == "expired" then shutdown(41, false); return
                elseif login and login.status == "error" then
                    collectNetwork()
                    local denied = report.network.rejected and report.network.rejected.rejections == 1
                    shutdown(phase == "rehearse" and 23 or 40, phase == "rehearse" and denied); return
                end
            elseif report.checks.maintenance_verified and finishBookshelf(21) then return end
            publicState()
            UIManager:scheduleIn(0.25, tick)
        end)
        if not success then fail() end
    end
    if phase == "restart" then
        report.checks.restart_loaded_session = savedSessionMatches()
        assert(report.checks.restart_loaded_session)
        local before = app.account.session
        assert(before.refresh_token and not before.pending_refresh_token
            and not before.refresh_blocked and not before.confirmation_blocked)
        app.account.session_manager:ensure(function(session, err)
            local success = pcall(function()
                local complete = session ~= nil and err == nil and report.checks.cookie_info_verified
                    and savedSessionMatches() and not session.refresh_blocked
                    and not session.confirmation_blocked and not session.pending_refresh_token
                complete = complete and not report.checks.server_refresh_required and report.counts.confirmRefresh == 0
                report.checks.maintenance_verified = complete == true
                report.checks.saved_session_verified = savedSessionMatches()
                if not complete then shutdown(40, false); return end
                if not native_menu_opened then openBookshelf() end
            end)
            if not success then fail() end
        end)
    else
        assert(app.account.session == nil and app.account.key == "anonymous")
        openBookshelf()
        menu.bilicomics.hold_callback()
        assert(screens.route == "account" and screens.widget)
        report.checks.native_menu_opened_account = true
        local label = require("bilicomics/ui/i18n")("Sign in with QR code")
        local button
        for _, row in ipairs(screens.focus or {}) do
            for _, item in ipairs(row) do if item.text == label and type(item.callback) == "function" then button = item end end
        end
        assert(button)
        button.callback()
        login = assert(screens.qr_login)
        report.checks.native_account_qr_button_used = true
        report.checks.native_dialog_visible = login.dialog ~= nil
        local on_close = login.on_close
        login.on_close = function(...)
            removeQR()
            return on_close(...)
        end
        local on_confirmed = login.on_confirmed
        login.on_confirmed = function(...)
            local result = on_confirmed(...)
            confirmed = true
            return result
        end
    end
    publicState()
    UIManager:scheduleIn(0.25, tick)
    UIManager:run()
end, function() return "authentication_driver_failure" end)
if not ok then pcall(fail) end
if not stopping then pcall(function() shutdown(42, false) end) end
os.exit((report.passed or report.deferred) and 0 or 1)
