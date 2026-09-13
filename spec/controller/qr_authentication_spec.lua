-- Exercise QR account transitions with real storage and controlled authentication workers.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local Controller = require("bilicomics/controller")
local Session = require("bilicomics/protocol/session")
local Storage = require("bilicomics/session_storage")
local Settings = require("bilicomics/settings")
local Files = require("bilicomics/storage/files")
local Codec = require("bilicomics/storage/codec")
local json = require("rapidjson")
local tests, active, assertion_count, fixture_count = {}, {}, 0, 0
local now = 1800000000
local function check(value, message)
    assertion_count = assertion_count + 1
    assert(value, message)
end
local function syntheticSession(identifier, suffix, renewable)
    local session = assert(Session.parse("SESSDATA=synthetic-" .. suffix .. "; DedeUserID=" .. identifier .. "; bili_jct=synthetic-csrf"))
    assert(session:withIdentity({ id = identifier, name = "Synthetic account" }, now))
    if renewable then session.refresh_token = "synthetic-refresh-" .. suffix end
    return session
end
local function callbacks()
    local calls = {}
    return calls, function(value, err) calls[#calls + 1] = { value = value, error = err } end
end
local function fixture(options)
    options = options or {}
    fixture_count = fixture_count + 1
    local root = output .. "/qr-case-" .. fixture_count
    local storage = Storage.new{ data_root = root, android = false }
    local settings = Settings.open(root)
    local original
    if not options.anonymous then
        original = syntheticSession("42", "original", false)
        assert(storage:save(original))
        settings:set("active_account_key", original.account_key)
    end
    local ui = { queue = {} }
    function ui:nextTick(callback) self.queue[#self.queue + 1] = callback end
    function ui:scheduleIn() end
    function ui:unschedule() end
    function ui:close() end
    function ui:drain()
        local remaining = 1000
        while #self.queue > 0 do
            remaining = remaining - 1
            assert(remaining > 0, "Deferred callbacks did not settle")
            table.remove(self.queue, 1)()
        end
    end
    local context = { connected = true, storage = storage, ui = ui, root = root, original = original, runners = {} }
    local function runnerFactory()
        local runner = { tasks = {}, all = {}, canceled = {}, submitted = 0 }
        function runner:submit(request, task_options, callback)
            self.submitted = self.submitted + 1
            local identifier = "raw-" .. self.submitted
            local task = { id = identifier, request = request, options = task_options, callback = callback }
            self.tasks[identifier], self.all[identifier] = task, task
            self.latest = task
            if context.immediate then
                self.tasks[identifier] = nil
                callback(context.immediate(request))
            end
            return identifier
        end
        function runner:cancel(identifier)
            local task = self.tasks[identifier]
            if task then
                self.tasks[identifier], self.canceled[identifier] = nil, true
                task.callback(nil, { kind = "canceled", transmitted = false })
            end
            return task ~= nil
        end
        function runner:close()
            self.closed = true
            local pending = {}; for identifier in pairs(self.tasks) do pending[#pending + 1] = identifier end
            for _, identifier in ipairs(pending) do self:cancel(identifier) end
        end
        function runner:suspend() self.suspended = true end
        function runner:resume() self.suspended = false end
        function runner:promote() end
        context.runners[#context.runners + 1] = runner
        return runner
    end
    context.app = Controller.new{ root = root, ui_manager = ui, runner_factory = runnerFactory,
        session_storage = storage, settings = settings, network = { isConnected = function() return context.connected end } }
    active[#active + 1] = context.app
    context.raw = context.app.account.raw_runner
    function context:finish(task, value, err)
        self.raw.tasks[task.id] = nil
        task.callback(value, err)
        self.ui:drain()
    end
    function context:begin(key)
        local calls, callback = callbacks()
        self.app:beginQRLogin(callback)
        local task = self.app.account.raw_runner.latest
        self:finish(task, { url = "https://passport.bilibili.com/synthetic-qr", key = key or "synthetic-key", expires_at = now + 180 })
        return task, calls
    end
    return context
end
local function test(name, callback)
    local before = assertion_count
    local ok, failure = xpcall(callback, debug.traceback)
    for _, app in ipairs(active) do if not app.closed then pcall(app.close, app) end end
    active = {}
    tests[#tests + 1] = { name = name, passed = ok, assertions = assertion_count - before, error = ok and nil or failure }
    print((ok and "PASS " or "FAIL ") .. name)
end

test("Anonymous and invalidated accounts can begin an isolated QR sign-in", function()
    for _, anonymous in ipairs({ true, false }) do
        local c = fixture{ anonymous = anonymous }
        local account = c.app.account
        if not anonymous then c.app:_invalidateAuthentication(account) end
        local task, calls = c:begin()
        check(task.request.kind == "auth" and task.request.method == "generateQR" and task.request.session == nil,
            "QR generation must use its own credential-free auth request")
        check(task.options.retry_attempts == 1 and task.options.before_start() == true, "QR generation must have a bounded runnable request")
        check(#calls == 1 and calls[1].value.key == "synthetic-key" and c.app.account == account,
            "Generating a code must not replace the selected account")
        check(c.app.qr_login.task_id == nil, "Completed generation must release its worker slot")
    end
end)

test("Waiting and scanned statuses preserve the account until verified confirmation", function()
    local c = fixture()
    local original = c.app.account
    c:begin()
    for _, status in ipairs({ "waiting", "scanned" }) do
        local calls, callback = callbacks()
        c.app:pollQRLogin("synthetic-key", callback)
        local task = c.raw.latest
        check(task.request.method == "pollQR" and task.request.arguments[1] == "synthetic-key", "Poll must retain its active code key")
        c:finish(task, { status = status, session = { cookies = { SESSDATA = "synthetic-unverified" } } })
        check(#calls == 1 and calls[1].value.status == status and calls[1].value.session == nil,
            "Nonterminal statuses must expose no credential payload")
        check(c.app.account == original and c.app.account.session.cookies.SESSDATA == "synthetic-original",
            "A scan without confirmation must not alter the selected credentials")
    end
    local replacement = syntheticSession("43", "qr-confirmed", true)
    replacement.cookie_expires_at, replacement.last_refreshed_at = now + 3600, now
    local calls, callback = callbacks()
    c.app:pollQRLogin("synthetic-key", callback)
    c:finish(c.raw.latest, { status = "confirmed", session = replacement:serialize() })
    check(#calls == 1 and calls[1].value.status == "confirmed" and calls[1].error == nil, "Confirmation must report success after saving")
    check(c.app.account.key == "bili_43" and c.app.account.session_valid and c.app.qr_login == nil,
        "Confirmation must activate exactly the verified account and retire the QR state")
    local saved = assert(c.storage:load("bili_43"))
    check(saved.refresh_token == replacement.refresh_token and saved.cookie_expires_at == now + 3600,
        "The renewable session must survive private storage")
    check(not Codec.encode(c.app:getAccount()):find("synthetic-refresh", 1, true), "Public account state must omit refresh credentials")
    check(c.raw.closed and c.app.settings:get("active_account_key") == "bili_43", "The old account worker must close before persistent selection changes")
end)

test("Confirmed QR replacement clears a previous invalid-session marker", function()
    local c = fixture()
    c.app:_invalidateAuthentication(c.app.account)
    c:begin()
    c.app:pollQRLogin("synthetic-key", function() end)
    c:finish(c.raw.latest, { status = "confirmed", session = syntheticSession("42", "renewed-login", true):serialize() })
    check(c.app.account.session_valid and c.app.account.store:getSetting("session_invalidated") == false,
        "A newly verified same-account QR session must clear durable invalidation")
    check(c.app:getAccount().renewable == true, "The account view must advertise renewal capability without secrets")
end)

test("Wrong keys and duplicate polls cannot create overlapping QR requests", function()
    local c = fixture()
    c:begin()
    local calls, callback = callbacks()
    local before = c.raw.submitted
    c.app:pollQRLogin("wrong-key", callback); c.ui:drain()
    check(c.raw.submitted == before and calls[1].error.kind == "canceled", "A wrong key must not reach the worker")
    c.app:pollQRLogin("synthetic-key", function() end)
    local first = c.raw.latest
    c.app:pollQRLogin("synthetic-key", callback); c.ui:drain()
    check(c.raw.submitted == before + 1 and calls[2].error.kind == "canceled", "Only one poll may remain in flight")
    check(c.app.qr_login.task_id == first.id, "A rejected duplicate must not retire the original poll")
end)

test("Expired QR codes retire their key without replacing the current account", function()
    local c = fixture()
    local account = c.app.account
    c:begin()
    local calls, callback = callbacks()
    c.app:pollQRLogin("synthetic-key", callback)
    c:finish(c.raw.latest, { status = "expired" })
    local before = c.raw.submitted
    c.app:pollQRLogin("synthetic-key", callback); c.ui:drain()
    check(c.app.qr_login == nil and c.app.account == account, "Expiration must retain the existing account")
    check(#calls == 2 and calls[1].value.status == "expired" and calls[2].error.kind == "canceled"
        and c.raw.submitted == before, "An expired key must never be polled again")
end)

test("Canceled and superseded generation callbacks cannot resurrect stale QR state", function()
    local c = fixture()
    local calls, callback = callbacks()
    c.app:beginQRLogin(callback)
    local old = c.raw.latest
    c.app:beginQRLogin(callback)
    local current = c.raw.latest
    old.callback({ key = "stale-key", url = "https://passport.bilibili.com/stale" })
    check(c.raw.canceled[old.id] and #calls == 0 and c.app.qr_login.task_id == current.id,
        "Superseding a code must cancel and ignore its old generation callback")
    c.app:cancelQRLogin()
    current.callback({ key = "late-key", url = "https://passport.bilibili.com/late" })
    check(c.raw.canceled[current.id] and c.app.qr_login == nil and #calls == 0, "Cancel must ignore even a late successful generation")
end)

test("Cancel suspend and close reject late confirmed credentials", function()
    for _, operation in ipairs({ "cancelQRLogin", "suspend", "close" }) do
        local c = fixture()
        local original = c.app.account
        c:begin()
        local calls, callback = callbacks()
        c.app:pollQRLogin("synthetic-key", callback)
        local task = c.raw.latest
        c.app[operation](c.app)
        task.callback({ status = "confirmed", session = syntheticSession("43", "stale-confirmation", true):serialize() })
        c.ui:drain()
        check(c.raw.canceled[task.id] and c.app.qr_login == nil and #calls == 0,
            operation .. " must retire in-flight confirmation without feedback")
        check(c.storage:load("bili_43") == nil and (c.app.closed or c.app.account == original),
            operation .. " must not save or activate stale confirmed credentials")
    end
end)

test("Connectivity failures stop new and queued QR generation", function()
    local c = fixture()
    local calls, callback = callbacks()
    c.connected = false
    c.app:beginQRLogin(callback); c.ui:drain()
    check(c.raw.submitted == 0 and calls[1].error.kind == "network" and c.app.qr_login == nil,
        "Offline QR generation must fail without worker submission")
    c.connected = true
    c.app:beginQRLogin(callback)
    local task = c.raw.latest
    c.connected = false
    local allowed, err = task.options.before_start()
    check(allowed == false and err.kind == "network" and err.transmitted == false,
        "A disconnect before worker startup must stop the queued request")
    c:finish(task, nil, err)
    check(c.app.qr_login == nil and c.app.account.session_valid, "A QR connectivity error must not invalidate existing credentials")
end)

test("Poll failures allow an explicit retry without altering the existing account", function()
    local c = fixture()
    local account = c.app.account
    c:begin()
    local calls, callback = callbacks()
    c.app:pollQRLogin("synthetic-key", callback)
    c:finish(c.raw.latest, nil, { kind = "network" })
    check(#calls == 1 and calls[1].error.kind == "network" and c.app.qr_login.task_id == nil,
        "A failed poll must release its worker slot while retaining its code")
    c.app:pollQRLogin("synthetic-key", callback)
    c:finish(c.raw.latest, { status = "scanned" })
    check(#calls == 2 and calls[2].value.status == "scanned" and c.app.account == account,
        "Explicit poll retry must preserve the account until confirmation")
end)

test("A private save failure preserves the previous selected account and saved file", function()
    local c = fixture()
    local account, old_bytes = c.app.account, Files.read(assert(c.storage:path("bili_42")))
    c:begin()
    local calls, callback = callbacks()
    c.app:pollQRLogin("synthetic-key", callback)
    local real_save = c.storage.save
    c.storage.save = function() return nil, { kind = "storage", code = "synthetic-save" } end
    c:finish(c.raw.latest, { status = "confirmed", session = syntheticSession("43", "save-failure", true):serialize() })
    c.storage.save = real_save
    check(#calls == 1 and calls[1].value == nil and calls[1].error.kind == "storage", "Failed private persistence must not report signed-in success")
    check(c.app.account == account and c.app.account.session_valid and not c.raw.closed
        and c.app.settings:get("active_account_key") == "bili_42", "Private save failure must leave the existing account fully selected")
    check(Files.read(assert(c.storage:path("bili_42"))) == old_bytes and c.storage:load("bili_43") == nil,
        "Failed QR replacement must preserve the original file without saving the candidate")
end)

test("Explicit import cancels QR polling and late QR success cannot replace the imported account", function()
    local c = fixture()
    c:begin()
    c.app:pollQRLogin("synthetic-key", function() error("A canceled QR poll must not call its consumer") end)
    local old = c.raw.latest
    local calls, callback = callbacks()
    c.app:importSession("SESSDATA=synthetic-import; DedeUserID=44", callback)
    local imported = c.raw.latest
    check(c.raw.canceled[old.id] and imported.request.method == "validateSession", "Explicit import must supersede the active QR poll")
    c:finish(imported, { session = syntheticSession("44", "import", false):serialize() })
    old.callback({ status = "confirmed", session = syntheticSession("43", "stale-qr", true):serialize() })
    c.ui:drain()
    check(#calls == 1 and c.app.account.key == "bili_44" and c.storage:load("bili_43") == nil,
        "A late QR confirmation must not overwrite the newly imported account")
end)

test("Starting QR sign-in retires an older pending import without canceling the new QR", function()
    local c = fixture()
    local account = c.app.account
    local import_calls, import_callback = callbacks()
    c.app:importSession("SESSDATA=synthetic-pending-import; DedeUserID=44", import_callback)
    local imported = c.raw.latest
    check(imported.request.method == "validateSession", "The earlier import must already be dispatched")
    local qr_calls, qr_callback = callbacks()
    c.app:beginQRLogin(qr_callback)
    local generated, state = c.raw.latest, c.app.qr_login
    c:finish(imported, { session = syntheticSession("44", "superseded-import", false):serialize() })
    check(#import_calls == 0 and c.app.account == account and c.storage:load("bili_44") == nil,
        "An older import result must not save credentials or replace the selected account")
    check(c.app.qr_login == state and state.task_id == generated.id and not c.raw.canceled[generated.id]
        and not c.raw.closed, "The superseded import must leave the new QR worker and state active")
    c:finish(generated, { key = "new-qr-key", url = "https://passport.bilibili.com/new-qr", expires_at = now + 180 })
    check(#qr_calls == 1 and qr_calls[1].value.key == "new-qr-key" and c.app.qr_login == state,
        "The newer QR generation must still finish normally after the stale import callback")
end)

test("Synchronous authentication workers do not leave phantom in-flight QR requests", function()
    local c = fixture()
    c.immediate = function(request)
        if request.method == "generateQR" then return { key = "instant", url = "https://passport.bilibili.com/instant", expires_at = now + 180 } end
        return { status = "waiting" }
    end
    local calls, callback = callbacks()
    c.app:beginQRLogin(callback)
    check(#calls == 1 and c.app.qr_login.task_id == nil, "Immediate generation must leave the code pollable")
    c.app:pollQRLogin("instant", callback)
    check(#calls == 2 and calls[2].value.status == "waiting" and c.app.qr_login.task_id == nil,
        "Immediate polling must not retain its already-completed task identifier")
end)

local passed = true
for _, result in ipairs(tests) do passed = passed and result.passed end
local report = { passed = passed, groups = #tests, assertions = assertion_count, tests = tests,
    scope = "Real Controller, Session, SessionStorage, SQLite and PageStore with controlled QR worker results",
    synthetic_credentials_only = true, real_network_requests = 0, purchase_requests = 0 }
Files.write(output .. "/qr-authentication-result.json", json.encode(report, { pretty = true }))
print(json.encode(report, { pretty = true }))
if not passed then os.exit(1) end
