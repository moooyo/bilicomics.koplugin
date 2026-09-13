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
local private = work .. "/private"
local parent_pid = tonumber(ffi.C.getpid())
local result_path = private .. "/" .. phase .. "-driver.json"
local qr_path = private .. "/qr.png"
local app, login, UIManager, Device
local runners, stopping, confirmed = {}, false, false
local report = { schema = 1, code = 10, passed = false, running = true,
    checks = { live_network_enabled = phase ~= "rehearse", source_worker_unmodified = true,
        controller_initialized = false, native_dialog_visible = false, qr_ready = false,
        login_confirmed = false, saved_session_verified = false, restart_loaded_session = false,
        cookie_info_verified = false, server_refresh_required = false, refresh_verified = false,
        confirmation_verified = false, maintenance_verified = false, workers_closed = false },
    counts = { workers_started = 0, workers_completed = 0, heartbeats = 0,
        generateQR = 0, pollQR = 0, cookieInfo = 0, refreshSession = 0, confirmRefresh = 0,
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
        local closed = pcall(app.close, app)
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
    local parse = require("socket.url").parse
    local child_events = {}
    local function event(category, key, value)
        local item = child_events[category] or { requests = 0, responses = 0, transmitted = 0, rejections = 0 }
        item[key] = value ~= nil and value or item[key] + 1
        child_events[category] = item
        write(private .. "/" .. phase .. "-transport-" .. tostring(ffi.C.getpid()) .. ".json", child_events)
    end
    local function formKeys(body, allowed)
        if type(body) ~= "string" or #body > 32768 then return false end
        local seen = {}
        for field in body:gmatch("[^&]+") do
            local key, value = field:match("^([a-z_]+)=(.+)$")
            if not key or not allowed[key] or seen[key] or value:find("[%c%s]") then return false end
            seen[key] = true
        end
        for key in pairs(allowed) do if not seen[key] then return false end end
        return true
    end
    function Transport:request(request)
        local parsed = parse(request.url or "") or {}
        local method, category = request.method or "GET", nil
        local passport = parsed.host == "passport.bilibili.com"
        local plain_get = method == "GET" and request.body == nil
        if plain_get and passport and parsed.path == "/x/passport-login/web/qrcode/generate"
            and phase == "login" then category = "qr_generate"
        elseif plain_get and passport and parsed.path == "/x/passport-login/web/qrcode/poll"
            and phase == "login" then category = "qr_poll"
        elseif plain_get and parsed.host == "api.bilibili.com" and parsed.path == "/x/web-interface/nav"
            and (phase == "login" or phase == "restart") then category = "identity_check"
        elseif plain_get and passport and parsed.path == "/x/passport-login/web/cookie/info"
            and phase == "restart" then category = "cookie_info"
        elseif phase == "restart" and report.checks.server_refresh_required then
            if plain_get and parsed.host == "www.bilibili.com" and type(parsed.path) == "string"
                and #parsed.path <= 1200 and parsed.path:match("^/correspond/1/%x+$") then category = "refresh_challenge"
            elseif passport and method == "POST" and parsed.path == "/x/passport-login/web/cookie/refresh"
                and formKeys(request.body, { csrf = true, refresh_csrf = true, source = true, refresh_token = true }) then
                category = "refresh"
            elseif passport and method == "POST" and parsed.path == "/x/passport-login/web/confirm/refresh"
                and formKeys(request.body, { csrf = true, refresh_token = true }) then category = "confirm"
            end
        end
        local allowed = category ~= nil and tonumber(ffi.C.getpid()) ~= parent_pid
            and parsed.scheme == "https" and not parsed.user and not parsed.password
            and (not parsed.port or tostring(parsed.port) == "443") and not parsed.fragment
            and request.output_path == nil and not Files.exists(private .. "/stop")
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
        local method = request.method
        local allowed = request.kind == "auth" and ((phase == "login" or phase == "rehearse")
            and (method == "generateQR" or method == "pollQR") or phase == "restart"
            and (method == "cookieInfo" or method == "refreshSession" or method == "confirmRefresh"))
        if method == "generateQR" then allowed = allowed and report.counts.generateQR == 0 end
        if method == "pollQR" then allowed = allowed and report.counts.pollQR < 100 end
        if method == "cookieInfo" then allowed = allowed and report.counts.cookieInfo == 0 end
        if method == "refreshSession" then
            local info = request.arguments and request.arguments[1] and request.arguments[1].info
            allowed = allowed and report.counts.refreshSession == 0 and report.checks.cookie_info_verified
                and type(info) == "table" and info.refresh == report.checks.server_refresh_required
        end
        if method == "confirmRefresh" then
            allowed = allowed and report.counts.confirmRefresh == 0 and report.checks.server_refresh_required
                and report.checks.refresh_verified and savedSessionMatches()
                and request.session and request.session.pending_refresh_token ~= nil
                and request.session.confirmation_blocked == true
        end
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
                report.checks.cookie_info_verified = true
                report.checks.server_refresh_required = value.refresh
            elseif method == "refreshSession" and value and report.checks.server_refresh_required then
                report.checks.refresh_verified = value.pending_refresh_token ~= nil and value.last_refreshed_at ~= nil
            elseif method == "confirmRefresh" and value == true then report.checks.confirmation_verified = true end
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
    Device = require("device")
    require("document/canvascontext"):init(Device)
    require("gettext").current_lang = "zh_CN"
    UIManager = require("ui/uimanager")
    local keeper = require("ui/widget/container/widgetcontainer"):new{}
    UIManager:show(keeper)
    app = require("bilicomics/controller").new{ root = DataStorage:getDataDir() .. "/bilicomics",
        ui_manager = UIManager, network = { isConnected = function() return true end } }
    report.checks.controller_initialized = app.account ~= nil and app.account.raw_runner ~= nil
    local storage_save = app.session_storage.save
    function app.session_storage:save(session)
        local saved, err = storage_save(self, session)
        if saved then report.counts.session_saves = report.counts.session_saves + 1 end
        return saved, err
    end
    local function tick()
        if stopping then return end
        local success = pcall(function()
            report.counts.heartbeats = report.counts.heartbeats + 1
            if Files.exists(private .. "/stop") then shutdown(42, false); return end
            if phase ~= "restart" then
                if confirmed then
                    report.checks.login_confirmed = true
                    report.checks.saved_session_verified = savedSessionMatches()
                    shutdown(20, report.checks.saved_session_verified); return
                end
                if login and (login.status == "waiting" or login.status == "scanned") then
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
            end
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
                if report.checks.server_refresh_required then
                    complete = complete and report.checks.refresh_verified and report.checks.confirmation_verified
                else
                    complete = complete and report.counts.confirmRefresh == 0
                end
                report.checks.maintenance_verified = complete == true
                report.checks.saved_session_verified = savedSessionMatches()
                shutdown(report.checks.server_refresh_required and 22 or 21, complete)
            end)
            if not success then fail() end
        end)
    else
        assert(app.account.session == nil and app.account.key == "anonymous")
        login = require("bilicomics/ui/qr_login").new{ controller = app,
            is_current = function() return not stopping end,
            on_dialog = function() report.checks.native_dialog_visible = true end,
            on_close = function() removeQR() end,
            on_confirmed = function() confirmed = true end }
        login:start()
    end
    publicState()
    UIManager:scheduleIn(0.25, tick)
    UIManager:run()
end, function() return "authentication_driver_failure" end)
if not ok then pcall(fail) end
if not stopping then pcall(function() shutdown(42, false) end) end
os.exit(report.passed and 0 or 1)
