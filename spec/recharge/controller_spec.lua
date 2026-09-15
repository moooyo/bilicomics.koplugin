-- Integration checks with the real Controller, SessionRunner, recharge journal and SQLite.
-- Credentials, transport and workers are synthetic; the runner must isolate networking.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local ffi = require("ffi")
if not pcall(function() return ffi.C.readlink end) then ffi.cdef[[long readlink(const char *path, char *buf, unsigned long size);]] end
local namespace = ffi.new("char[256]")
local namespace_size = tonumber(ffi.C.readlink("/proc/self/ns/net", namespace, 256))
assert(namespace_size and namespace_size > 0 and namespace_size < 256)
assert(ffi.string(namespace, namespace_size) ~= assert(os.getenv("BILI_RECHARGE_PARENT_NETNS")), "Run in an isolated network namespace")
local route_file, route_count = assert(io.open("/proc/net/route", "rb")), 0
for line in route_file:lines() do if line:match("%S") and not line:match("^Iface%s") then route_count = route_count + 1 end end
assert(route_file:close()); assert(route_count == 0, "The isolated namespace must have no network routes")
local network_attempts = 0
require("bilicomics/protocol/transport").request = function()
    network_attempts = network_attempts + 1
    error("Actual network requests and CreateOrder calls are forbidden")
end
local Controller = require("bilicomics/controller")
local Session = require("bilicomics/protocol/session")
local Settings = require("bilicomics/settings")
local Store = require("bilicomics/storage/store")
local Service = require("bilicomics/recharge/service")
local Recharge = require("bilicomics/protocol/recharge")
local json = require("rapidjson")
local tests, active, assertions, sequence = {}, {}, 0, 0
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local function check(condition, message)
    assertions = assertions + 1
    assert(condition, message or "Unexpected recharge integration result")
end
local function syntheticSession(account_id, now, suffix)
    local session = Session.new{ cookies = { SESSDATA = "synthetic-session-" .. (suffix or account_id),
        bili_jct = "synthetic-csrf", DedeUserID = account_id, buvid3 = "synthetic-device" }, refresh_token = "synthetic-refresh" }
    assert(session:withIdentity({ id = account_id, name = "Synthetic recharge account" }, now))
    return session
end
local function fixture()
    sequence = sequence + 1
    local env = { root = output .. "/case-" .. sequence, now = 1800000000, results = {}, raws = {}, loads = {}, saves = {} }
    local settings = Settings.open(env.root)
    settings:set("active_account_key", "bili_42")
    local sessions = { bili_42 = syntheticSession("42", env.now) }
    local storage = { is_android = false }
    function storage:load(key) env.loads[#env.loads + 1] = key; return sessions[key] and Session.new(sessions[key]:serialize()) end
    function storage:save(session)
        sessions[session.account_key] = Session.new(session:serialize())
        env.saves[#env.saves + 1] = session.account_key
        return true
    end
    function storage:removeLegacy() end
    local ui = { queue = {}, timers = {} }
    function ui:nextTick(callback) self.queue[#self.queue + 1] = callback end
    function ui:scheduleIn(seconds, callback) self.timers[callback] = seconds end
    function ui:unschedule(callback) self.timers[callback] = nil end
    function ui:close() end
    function ui:drain()
        local remaining = 1000
        while #self.queue > 0 do
            remaining = remaining - 1; assert(remaining > 0, "Deferred callbacks did not settle")
            table.remove(self.queue, 1)()
        end
    end
    local function factory()
        local raw = { tasks = {}, order = {}, submitted = {}, started = {}, sequence = 0 }
        function raw:count(kind, method) return self.submitted[kind .. ":" .. (method or "")] or 0 end
        function raw:submit(request, options, callback)
            assert(not self.closed, "A closed controlled worker must not accept work")
            self.sequence = self.sequence + 1
            local id = "raw-" .. self.sequence
            local key = request.kind .. ":" .. (request.method or "")
            self.submitted[key] = (self.submitted[key] or 0) + 1
            if request.kind == "recharge" then
                local account = env.app.account
                local saved = account.store:getSetting(account.recharge_service.setting_key).orders[request.local_id]
                check(saved and saved.state == "creating" and saved.amount_cents == request.amount_cents,
                    "The recharge intent must be durable before even queueing a worker")
                check(options.cancelable == false and options.resource == "recharge", "Recharge mutations cannot be preempted")
                if env.submit_failure == "before" then error("Synthetic worker submission failure before dispatch") end
                if env.submit_failure == "after" then
                    local allowed, err = options.before_start()
                    assert(allowed == true, err and err.kind)
                    self.started.recharge = (self.started.recharge or 0) + 1
                    error("Synthetic worker submission failure after dispatch")
                end
            end
            local task = { id = id, request = request, options = options or {}, callback = callback }
            self.tasks[id], self.order[#self.order + 1] = task, id
            return id
        end
        function raw:find(kind, method)
            for _index, id in ipairs(self.order) do
                local task = self.tasks[id]
                if task and task.request.kind == kind and (not method or task.request.method == method) then return task end
            end
        end
        function raw:start(task)
            assert(task and self.tasks[task.id] == task, "A queued controlled worker is required")
            if task.started then return true end
            assert(not self.suspended, "Suspended workers cannot dispatch")
            local allowed, err = true
            if task.options.before_start then allowed, err = task.options.before_start() end
            if allowed ~= true then self.tasks[task.id] = nil; task.callback(nil, err); ui:drain(); return false end
            task.started = true
            self.started[task.request.kind] = (self.started[task.request.kind] or 0) + 1
            return true
        end
        function raw:finish(task, value, err)
            if not self:start(task) then return false end
            self.tasks[task.id] = nil
            task.callback(copy(value), copy(err)); ui:drain(); return true
        end
        function raw:cancel(id)
            local task = self.tasks[id]; if not task then return false end
            self.tasks[id] = nil
            task.callback(nil, { kind = "canceled", transmitted = task.started == true, definitive = task.started ~= true })
            return true
        end
        function raw:promote() end
        function raw:suspend() self.suspended = true end
        function raw:resume() self.suspended = false end
        function raw:close()
            local pending = {}; for _index, id in ipairs(self.order) do if self.tasks[id] then pending[#pending + 1] = self.tasks[id] end end
            for _index, task in ipairs(pending) do
                if task.close_result then self.tasks[task.id] = nil; task.callback(copy(task.close_result), nil)
                else self:cancel(task.id) end
            end
            self.closed = true
        end
        env.raws[#env.raws + 1] = raw
        return raw
    end
    env.app = Controller.new{ root = env.root, ui_manager = ui, runner_factory = factory,
        session_storage = storage, settings = settings, clock = function() return env.now end,
        network = { isConnected = function() return true end } }
    active[#active + 1] = env.app
    env.ui, env.raw, env.account = ui, env.app.account.raw_runner, env.app.account
    env.account.session_manager.last_checked_at = env.now
    function env:time(value) self.now = value; self.app.account.session_manager.last_checked_at = value end
    function env:configData()
        return assert(Recharge.normalizeConfig({ pay_amount_ranges = {
            { pay_amount = 10, gold_amount = 1000 }, { pay_amount = 25, gold_amount = 2500 },
        }, show_text = "Synthetic server terms" }, self.now))
    end
    function env:config()
        local result, failure
        self.app:getRechargeConfig(function(value, err) result, failure = value, err end)
        self.raw:finish(assert(self.raw:find("client", "getRechargeConfig")), self:configData())
        assert(result, failure and failure.kind)
        self.config_value = result
        return result
    end
    function env:create(input, token)
        self.app:createRechargeOrder(input or "10.00", function(value, err)
            self.results[#self.results + 1] = { value = value, error = err }
        end, token or assert(self.config_value).confirmation_token)
        self.ui:drain()
        return self.raw:find("recharge")
    end
    function env:receipt(order_id)
        return { order_id = order_id or "900719925474099312345678901", code_url = "https://pay.bilibili.com/synthetic-order",
            qr_validated = true, amount_cents = 1000 }
    end
    function env:pendingOrder(order_id)
        self:config(); local task = assert(self:create())
        self.raw:finish(task, self:receipt(order_id))
        local result = self.results[#self.results]
        assert(result.value and result.value.state == "pending", result.error and result.error.kind)
        return result.value, task
    end
    function env:refresh(local_id)
        local answers = {}
        self.app:refreshRechargeOrder(local_id, function(value, err) answers[#answers + 1] = { value = value, error = err } end)
        self.ui:drain(); return answers
    end
    function env:history(records)
        local task = assert(self.raw:find("client", "rechargeHistory"), "A controlled history page is required")
        local options = task.request.arguments[1]
        self.raw:finish(task, { records = records, page_num = options.page_num, page_size = options.page_size,
            order_year = options.order_year, order_month = options.order_month })
        return options
    end
    function env:wallet()
        local task = self.raw:find("client", "wallet")
        if task then self.raw:finish(task, { remain_gold = 1200, remain_coupon = 0 }) end
    end
    function env:journal(account)
        account = account or self.account
        return account.store:getSetting(account.recharge_service.setting_key)
    end
    return env
end
local function test(name, callback)
    local before = assertions
    local ok, failure = xpcall(callback, debug.traceback)
    for _index, app in ipairs(active) do if not app.closed then pcall(app.close, app) end end
    active = {}
    tests[#tests + 1] = { name = name, passed = ok, assertions = assertions - before, error = ok and nil or failure }
    print((ok and "PASS " or "FAIL ") .. name)
end

test("Configuration is coalesced, copied and required for every explicit creation", function()
    local env, answers = fixture(), {}
    check(env.app:getRechargeConfigSnapshot() == nil and #env.app:getRechargeOrders() == 0, "Local getters must not request recharge work")
    for index = 1, 2 do env.app:getRechargeConfig(function(value) answers[index] = value end) end
    check(env.raw:count("client", "getRechargeConfig") == 1, "Concurrent configuration reads must share one worker")
    env.raw:finish(assert(env.raw:find("client", "getRechargeConfig")), env:configData())
    check(answers[1].confirmation_token == answers[2].confirmation_token and answers[1] ~= answers[2], "Waiters receive separate snapshots of one confirmation")
    local snapshot = env.app:getRechargeConfigSnapshot(); snapshot.options[1].amount_cents = 1
    check(env.app:getRechargeConfigSnapshot().options[1].amount_cents == 1000, "UI mutation cannot change the pinned configuration")
    env.config_value = answers[1]
    env:create("10.01"); env:create("1e1"); env:create("0")
    check(env.raw:count("recharge") == 0 and #env.results == 3, "Unsupported or malformed amounts never queue a mutation")
    for _index, result in ipairs(env.results) do check(result.error and result.error.kind == "invalid_recharge_amount" and result.error.transmitted == false, "Rejected amounts are conclusively local") end
    local previous = answers[1].confirmation_token
    local newer = env:config()
    check(newer.confirmation_token ~= previous, "A new configuration requires a new confirmation token")
    env:create("10.00", previous)
    check(env.results[#env.results].error.kind == "confirmation_required" and env.raw:count("recharge") == 0, "Old confirmations cannot create an order")
    env:time(env.now + 301); env:create()
    check(env.results[#env.results].error.kind == "confirmation_required" and env.raw:count("recharge") == 0, "Expired confirmations remain non-transmitting")
end)

test("Creation is durable before dispatch and cannot be repeated or guessed from balance", function()
    local env = fixture(); local config = env:config(); local task = assert(env:create("10.00"))
    local saved = env:journal().orders[task.request.local_id]
    check(saved.state == "creating" and (env.raw.started.recharge or 0) == 0, "Creating must be committed before transmission")
    check(task.request.amount_cents == 1000 and task.request.option_fingerprint == config.options[1].fingerprint, "Worker receives the exact confirmed cents and terms")
    env:create("10.00", config.confirmation_token)
    check(env.raw:count("recharge") == 1, "A reused confirmation cannot queue another CreateOrder")
    env:config(); env:create()
    check(env.raw:count("recharge") == 1 and env.results[#env.results].error.kind == "recharge_busy", "A second fresh confirmation cannot overlap creation")
    env.raw:finish(task, env:receipt())
    local record = env.results[#env.results].value
    check(record.order_id == "900719925474099312345678901" and type(record.order_id) == "string" and record.state == "pending", "Long server order identity is retained exactly")
    local before = #env.results; task.callback(env:receipt("900719925474099399999999999"), nil); env.ui:drain()
    check(#env.results == before and env.app:getRechargeOrders()[1].order_id == record.order_id, "A repeated worker callback cannot replace the receipt")
    env.account.store:putSetting("wallet", { remain_gold = 999999, updated_at = env.now })
    check(env.app:getRechargeOrders()[1].state == "pending", "A higher balance does not prove this order was credited")
    env.app:close()
    local store = Store.open{ root = env.account.root, account_key = env.account.key }
    local reopened = Service.new{ store = store, account_key = env.account.key, clock = function() return env.now end }
    check(reopened:get(record.id).order_id == record.order_id and reopened:get(record.id).state == "pending", "The exact pending receipt survives reopening SQLite")
    store:close()
end)

test("Timeout is unknown and never creates an automatic retry", function()
    local env = fixture(); env:config(); local task = assert(env:create())
    env.raw:finish(task, nil, { kind = "timeout", transmitted = true })
    local result = env.results[#env.results]
    check(result.value.state == "unknown" and env.raw:count("recharge") == 1 and env.raw:find("recharge") == nil, "A transmitted timeout remains unknown without replay")
    local answers = env:refresh(result.value.id)
    check(#answers == 1 and answers[1].value.state == "unknown" and env.raw:count("client", "rechargeHistory") == 0, "Missing order identity cannot be guessed from history")
    env:create()
    check(env.raw:count("recharge") == 1, "The consumed confirmation cannot retry an unknown mutation")
    local second = env:pendingOrder("900719925474099312345678902")
    check(#env.app:getRechargeOrders() == 2 and second.id ~= result.value.id, "A separately confirmed new order preserves all earlier unresolved records")
end)

test("Authentication renewal cannot replay a transmitted recharge mutation", function()
    local env = fixture(); env:config(); local task = assert(env:create())
    env.raw:finish(task, nil, { kind = "authentication", transmitted = true })
    check(env.raw:count("recharge") == 1 and env.raw:find("auth", "cookieInfo") ~= nil, "An auth failure may maintain the session but cannot resend creation")
    env.raw:finish(assert(env.raw:find("auth", "cookieInfo")), { refresh = false, timestamp = env.now * 1000 })
    local renewed = syntheticSession("42", env.now, "renewed"); renewed.refresh_checked_at = env.now
    env.raw:finish(assert(env.raw:find("auth", "refreshSession")), renewed:serialize())
    local confirmation = env.raw:find("auth", "confirmRefresh"); if confirmation then env.raw:finish(confirmation, true) end
    check(env.raw:count("recharge") == 1 and env.raw:find("recharge") == nil, "New credentials are never authority to replay CreateOrder")
    check(#env.results == 1 and env.results[1].value.state == "unknown", "The original mutation settles as unknown after maintenance")
end)

for _mode_index, failure_mode in ipairs({ "before", "after" }) do
    test("Worker submission exception " .. failure_mode .. " dispatch settles after asynchronous maintenance", function()
        local env = fixture(); env:config()
        env.account.session_manager:ensure(function() end, true)
        env.submit_failure = failure_mode
        env:create()
        check(#env.results == 0 and env.raw:count("recharge") == 0, "Creation waits for the existing asynchronous maintenance")
        env.raw:finish(assert(env.raw:find("auth", "cookieInfo")), { refresh = false, timestamp = env.now * 1000 })
        local renewed = Session.new(env.account.session:serialize()); renewed.refresh_checked_at = env.now
        env.raw:finish(assert(env.raw:find("auth", "refreshSession")), renewed:serialize())
        local confirmation = env.raw:find("auth", "confirmRefresh"); if confirmation then env.raw:finish(confirmation, true) end
        local result = env.results[1]
        local expected = failure_mode == "before" and "failed_not_submitted" or "unknown"
        check(#env.results == 1 and result.value and result.value.state == expected
            and env:journal().orders[result.value.id].state == expected, "The exception must settle once in the correct durable terminal category")
        check(env.raw:count("recharge") == 1 and (env.raw.started.recharge or 0) == (failure_mode == "before" and 0 or 1)
            and env.raw:find("recharge") == nil, "A submission exception cannot trigger an automatic creation retry")
    end)
end

test("Creation receipt observed during account close is saved only to its original journal", function()
    local env = fixture(); env:config(); local task = assert(env:create())
    env.raw:start(task); task.close_result = env:receipt()
    local old = env.account
    local adopted = assert(env.app:_adoptValidatedSession(syntheticSession("84", env.now):serialize()))
    env.ui:drain()
    check(adopted.account_key == "bili_84" and #env.results == 0 and #env.app:getRechargeOrders() == 0, "Late creation receipts cannot notify or populate the replacement account")
    task.callback(env:receipt("900719925474099399999999998"), nil); env.ui:drain()
    check(#env.app:getRechargeOrders() == 0, "Replayed old callbacks cannot change the new account journal")
    local store = Store.open{ root = old.root, account_key = old.key }
    local records = assert(Service.new{ store = store, account_key = old.key, clock = function() return env.now end }:list())
    check(#records == 1 and records[1].order_id == "900719925474099312345678901" and records[1].state == "pending", "A received receipt is durable even when its UI callback is retired")
    store:close()
end)

test("Storage failure before creation prevents transmission", function()
    local env = fixture(); env:config(); assert(env.app:_rechargeService())
    local store, original = env.account.store, env.account.store.putSetting
    store.putSetting = function(self, key, value)
        if key:find("recharge.journal", 1, true) then error("Synthetic recharge storage failure") end
        return original(self, key, value)
    end
    env:create()
    local result = env.results[#env.results]
    check(result.error.kind == "storage" and result.error.transmitted == false and result.error.definitive == true
        and env.raw:count("recharge") == 0, "An uncommitted confirmation must never reach CreateOrder")
    store.putSetting = original
end)

test("A received but unsaved receipt stays recoverable without recreating the order", function()
    local env = fixture(); env:config(); local task = assert(env:create())
    local store, original = env.account.store, env.account.store.putSetting
    store.putSetting = function(self, key, value)
        if key:find("recharge.journal", 1, true) then error("Synthetic receipt commit failure") end
        return original(self, key, value)
    end
    env.raw:finish(task, env:receipt())
    local observed = env.results[#env.results].value
    check(observed.persistence_pending == true and observed.credited_confirmed == false and observed.order_id == env:receipt().order_id,
        "An unsaved receipt is retained with an explicit persistence boundary")
    env:config(); env:create()
    check(env.raw:count("recharge") == 1 and env.results[#env.results].error.kind == "persistence_pending", "Unpersisted evidence blocks another creation")
    store.putSetting = original
    local answers = env:refresh(observed.id); env:history({})
    check(#answers == 1 and answers[1].value.state == "pending" and not answers[1].value.persistence_pending
        and env:journal().orders[observed.id].order_id == observed.order_id and env.raw:count("recharge") == 1, "Explicit recovery saves the original receipt without resubmission")
end)

local function unrelated(count, prefix)
    local records = {}
    for index = 1, count do records[index] = { order_id = tostring(prefix or "88000") .. tostring(index), raw_pay_amount = 1000, product_amount = 1000 } end
    return records
end

test("History walks full pages and both boundary years using the exact order ID", function()
    local env = fixture()
    env:time(os.time{ year = 2025, month = 12, day = 30, hour = 12 })
    local record = env:pendingOrder()
    env:time(os.time{ year = 2025, month = 12, day = 31, hour = 20 })
    local answers = env:refresh(record.id)
    local joined = env:refresh(record.id)
    check(env.raw:count("client", "rechargeHistory") == 1, "Concurrent history checks for one order must be single flight")
    local first = env:history(unrelated(50, "880000"))
    check(first.order_year == 2026 and first.page_num == 1 and first.page_size == 50, "China boundary year is queried with an explicit page size")
    local second = env:history({ { order_id = record.order_id .. "0", raw_pay_amount = 1000, product_amount = 1000 } })
    check(second.order_year == 2026 and second.page_num == 2 and #answers == 0, "A same-amount near-match on another page is not this order")
    local third = env:history({ { order_id = record.order_id, raw_pay_amount = 1, product_amount = 999 } })
    check(third.order_year == 2025 and third.page_num == 1, "UTC and creation-year history is checked after the newer year")
    check(#answers == 1 and #joined == 1 and answers[1].value.state == "credited"
        and answers[1].value.order_id == record.order_id and answers[1].value.credited_confirmed == true, "Exact server history identity is the credit evidence")
    env:wallet()
end)

test("Repeated history pages terminate with a limit and still inspect the older year", function()
    local env = fixture(); env:time(os.time{ year = 2025, month = 12, day = 30, hour = 12 }); local record = env:pendingOrder()
    env:time(os.time{ year = 2026, month = 1, day = 2, hour = 12 })
    local answers, repeated = env:refresh(record.id), unrelated(50, "990000")
    env:history(repeated); env:history(repeated)
    local last = env:history({})
    check(last.order_year == 2025 and env.raw:count("client", "rechargeHistory") == 3, "A repeated full page cannot loop or skip the older year")
    check(#answers == 1 and answers[1].error.kind == "recharge_history_limit" and answers[1].value.state == "pending"
        and not answers[1].value.history_match, "A bounded unsuccessful search cannot claim credit")
end)

test("Ten distinct full pages cap one year without claiming no payment", function()
    local env = fixture(); env:time(os.time{ year = 2025, month = 12, day = 30, hour = 12 }); local record = env:pendingOrder()
    env:time(os.time{ year = 2026, month = 1, day = 2, hour = 12 }); local answers = env:refresh(record.id)
    for page = 1, 10 do
        local options = env:history(unrelated(50, "770000" .. page))
        check(options.order_year == 2026 and options.page_num == page, "History follows each bounded page exactly once")
    end
    local last = env:history({})
    check(last.order_year == 2025 and #answers == 1 and answers[1].error.kind == "recharge_history_limit"
        and answers[1].value.state == "pending" and env.raw:count("recharge") == 1, "The page cap preserves uncertainty and the original order")
end)

test("An observed credit is not confirmed until its journal commit succeeds", function()
    local env = fixture(); local record = env:pendingOrder(); local answers = env:refresh(record.id)
    local store, original = env.account.store, env.account.store.putSetting
    store.putSetting = function(self, key, value)
        if key:find("recharge.journal", 1, true) then error("Synthetic credited-state commit failure") end
        return original(self, key, value)
    end
    env:history({ { order_id = record.order_id } })
    check(#answers == 1 and answers[1].error.kind == "storage" and answers[1].value.persistence_pending == true
        and answers[1].value.credited_confirmed == false and env:journal().orders[record.id].state == "pending",
        "Unsaved credit evidence must not be presented as a durable credited result")
    check(env.raw:find("client", "wallet") == nil, "A failed credit commit cannot trigger balance-based success inference")
    store.putSetting = original
    local recovered = env:refresh(record.id)
    check(#recovered == 1 and recovered[1].value.credited_confirmed == true and not recovered[1].value.persistence_pending
        and env:journal().orders[record.id].state == "credited" and env.raw:count("recharge") == 1, "Saving retained evidence confirms the same order without recreating it")
end)

local passed = network_attempts == 0
for _index, result in ipairs(tests) do passed = passed and result.passed end
local report = { spec = "recharge-controller", passed = passed, synthetic_only = true,
    actual_order_created = false, actual_payment_made = false, network_namespace_isolated = true,
    no_network_routes = true, network_attempts = network_attempts, assertions = assertions, count = assertions, tests = tests }
local file = assert(io.open(output .. "/controller-result.json", "wb"))
assert(file:write(json.encode(report, { pretty = true }))); assert(file:close())
print(json.encode({ passed = passed, tests = #tests, assertions = assertions }))
assert(passed, "One or more recharge controller integration checks failed")
