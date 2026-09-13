-- Exercise the final purchase dispatch guard with real Controller, SessionRunner and SQLite.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local ffi = require("ffi")
ffi.cdef[[long readlink(const char *path, char *buf, unsigned long size);]]
local namespace = ffi.new("char[128]")
local size = ffi.C.readlink("/proc/self/ns/net", namespace, 128)
assert(size > 0 and ffi.string(namespace, size) ~= assert(os.getenv("BILI_DISPATCH_PARENT_NETNS")),
    "Run in an isolated network namespace")
local network_attempts = 0
require("bilicomics/protocol/transport").request = function()
    network_attempts = network_attempts + 1
    error("Actual network requests are forbidden")
end
local Controller = require("bilicomics/controller")
local Session = require("bilicomics/protocol/session")
local Storage = require("bilicomics/session_storage")
local Settings = require("bilicomics/settings")
local Store = require("bilicomics/storage/store")
local Files = require("bilicomics/storage/files")
local Value = require("bilicomics/purchase/value")
local Fetch = require("bilicomics/purchase/quote_fetch")
local json = require("rapidjson")
local tests, active, assertions, sequence = {}, {}, 0, 0
local function check(value, message)
    assertions = assertions + 1
    assert(value, message or "Unexpected purchase dispatch result")
end
local function fixture()
    sequence = sequence + 1
    local root = output .. "/case-" .. sequence
    local env = { now = 1800000000, root = root, results = {} }
    local session = Session.new{ cookies = { SESSDATA = "synthetic-session", bili_jct = "synthetic-csrf", DedeUserID = "42" },
        refresh_token = "synthetic-refresh" }
    assert(session:withIdentity({ id = "42", name = "Synthetic account" }, env.now))
    local storage, settings = Storage.new{ data_root = root, android = false }, Settings.open(root)
    assert(storage:save(session))
    settings:set("active_account_key", "bili_42")
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
    local function runnerFactory()
        local raw = { tasks = {}, order = {}, submitted = {}, started = {}, sequence = 0 }
        function raw:submit(request, options, callback)
            self.sequence = self.sequence + 1
            local id = "raw-" .. self.sequence
            self.tasks[id] = { id = id, request = request, options = options or {}, callback = callback }
            self.order[#self.order + 1] = id
            self.submitted[request.kind] = (self.submitted[request.kind] or 0) + 1
            return id
        end
        function raw:find(kind, method)
            for _, id in ipairs(self.order) do
                local task = self.tasks[id]
                if task and task.request.kind == kind and (not method or task.request.method == method) then return task end
            end
        end
        function raw:start(task)
            assert(task and self.tasks[task.id] == task, "A queued controlled worker is required")
            assert(not self.suspended, "A suspended runner cannot dispatch")
            if task.started then return true end
            local allowed, err = true
            if task.options.before_start then allowed, err = task.options.before_start() end
            if allowed ~= true then
                self.tasks[task.id] = nil
                task.callback(nil, err)
                ui:drain()
                return false
            end
            task.started = true
            self.started[task.request.kind] = (self.started[task.request.kind] or 0) + 1
            return true
        end
        function raw:finish(task, value, err)
            if not self:start(task) then return false end
            self.tasks[task.id] = nil
            task.callback(value, err)
            ui:drain()
            return true
        end
        function raw:cancel(id)
            local task = self.tasks[id]
            if not task then return false end
            self.tasks[id] = nil
            task.callback(nil, { kind = "canceled", transmitted = task.started == true })
            return true
        end
        function raw:promote() end
        function raw:suspend() self.suspended = true end
        function raw:resume() self.suspended = false end
        function raw:close()
            local ids = {}; for id in pairs(self.tasks) do ids[#ids + 1] = id end
            for _, id in ipairs(ids) do self:cancel(id) end
            self.closed = true
        end
        return raw
    end
    env.app = Controller.new{ root = root, ui_manager = ui, runner_factory = runnerFactory,
        clock = function() return env.now end, session_storage = storage, settings = settings,
        network = { isConnected = function() return true end } }
    active[#active + 1] = env.app
    env.account, env.ui = env.app.account, ui
    env.raw, env.service, env.store = env.account.raw_runner, env.account.purchases, env.account.store
    env.service.clock = function() return env.now end
    env.account.session_manager.last_checked_at = env.now
    env.store:upsertComic{ id = "1", title = "Synthetic comic" }
    env.store:upsertEpisodes("1", { { id = "10", comic_id = "1", title = "Synthetic chapter", order = 1, access = "locked" } })
    function env:detail(owned)
        return { comic = { id = "1", title = "Synthetic comic" }, episodes = {
            { id = "10", comic_id = "1", title = "Synthetic chapter", order = 1, access = owned and "owned" or "locked" } },
            extra = { id = 1, ep_list = { { id = 10, ord = 1, is_locked = not owned, pay_mode = 1,
                unlock_type = owned and 1 or 0, pay_gold = 30, is_in_free = false,
                unlock_expire_at = "0000-00-00 00:00:00" } } } }
    end
    function env:quoteResponse()
        local info = { ep_id = "10", comic_id = "1", ep_original_gold = 30, pay_gold = 30, remain_gold = 100,
            is_locked = true, original_gold = 30, remain_lock_ep_num = 1, remain_lock_ep_gold = 30,
            after_lock_ep_num = 1, after_lock_ep_gold = 30,
            batch_buy = { { batch_limit = 1, amount = 1, usable = true, original_gold = 30, pay_gold = 30 } } }
        if self.scope then
            return assert(Fetch.run({ purchaseInfo = function() return Value.copy(info) end,
                comicDetail = function() return self:detail() end },
                { episode_id = "10", comic_id = "1", scope = self.scope, payment = "coin" }))
        end
        return { info = info, detail = self:detail() }
    end
    function env:queuePurchase(scope)
        self.scope = scope
        self.app:quotePurchase("10", scope, "coin", function(quote, err) assert(quote, err and err.kind); self.quote = quote end)
        self.raw:finish(self.raw:find("quote"), self:quoteResponse())
        self.app:purchase(self.quote, "read", function(intent, err)
            self.results[#self.results + 1] = { intent = intent, error = err }
        end)
        self.raw:finish(self.raw:find("quote"), self:quoteResponse())
        local task = assert(self.raw:find("purchase_submit"))
        self.intent_id = task.request.intent_id
        local intent = assert(self.store:getPurchase(self.intent_id))
        check(intent.state == "submitting" and (self.raw.started.purchase_submit or 0) == 0,
            "The confirmation must be durable before dispatch")
        return task, intent
    end
    function env:rejectExpired(task)
        check(self.raw:start(task) == false, "An expired purchase must be refused before transmission")
        check((self.raw.started.purchase_submit or 0) == 0 and self.raw.submitted.quote == 2,
            "Expiration must not transmit, reprice or retry a purchase")
        check(#self.results == 1 and self.results[1].intent.state == "rejected", "The caller must receive one rejected result")
        local intent = self.store:getPurchase(self.intent_id)
        check(intent.state == "rejected" and intent.transaction_evidence == "not_transmitted",
            "The journal must distinguish local expiry from server rejection")
        check(intent.error.kind == "quote_expired" and intent.error.transmitted == false and intent.error.definitive == true,
            "Expiration must retain conclusive non-transmission evidence")
        check(self.raw:find("purchase_submit") == nil and self.raw:find("quote") == nil,
            "A blocked confirmation must not recreate a queued purchase")
    end
    function env:reopenIntent()
        self.app:close()
        local store = Store.open{ root = self.account.root, account_key = self.account.key }
        local intent = store:getPurchase(self.intent_id)
        store:close()
        return intent
    end
    return env
end
local function test(name, callback)
    local before = assertions
    local ok, failure = xpcall(callback, debug.traceback)
    for _, app in ipairs(active) do if not app.closed then pcall(app.close, app) end end
    active = {}
    tests[#tests + 1] = { name = name, passed = ok, assertions = assertions - before, error = ok and nil or failure }
    print((ok and "PASS " or "FAIL ") .. name)
end

test("A queued purchase expiring before dispatch is durably rejected without a retry", function()
    local env = fixture()
    local task, intent = env:queuePurchase()
    env.now = intent.quote.expires_at + 1
    env:rejectExpired(task)
    local saved = env:reopenIntent()
    check(saved.state == "rejected" and saved.transaction_evidence == "not_transmitted", "The rejection must survive reopening SQLite")
end)

test("A queued purchase cannot outlive its confirmed quote across suspend and resume", function()
    local env = fixture()
    local task, intent = env:queuePurchase()
    env.app:suspend()
    check(env.raw.tasks[task.id] ~= nil and env.raw.suspended, "Suspension must preserve the queued fixture")
    env.now = intent.quote.expires_at + 1
    check(env.app:resume() == true, "The account must resume")
    env:rejectExpired(task)
end)

test("Session maintenance cannot authorize an expired purchase with its new credentials", function()
    local env = fixture()
    local task, intent = env:queuePurchase()
    env.account.session_manager:ensure(function() end, true)
    check(env.raw:start(task) == false and #env.results == 0, "Queued dispatch must join in-progress maintenance")
    env.now = intent.quote.expires_at + 1
    env.raw:finish(env.raw:find("auth", "cookieInfo"), { refresh = false, timestamp = env.now * 1000 })
    local refreshed = Session.new(env.account.session:serialize())
    refreshed.cookies.SESSDATA = "synthetic-renewed"
    refreshed.refresh_checked_at = env.now
    env.raw:finish(env.raw:find("auth", "refreshSession"), refreshed:serialize())
    check(env.account.session.cookies.SESSDATA == "synthetic-renewed", "Maintenance must complete before the expiry guard")
    env:rejectExpired(assert(env.raw:find("purchase_submit")))
end)

test("An unexpired confirmation transmits once and reconciles without replay", function()
    local env = fixture()
    local task = env:queuePurchase()
    env.now = env.now + 5
    check(env.raw:finish(task, { accepted = true }), "An unexpired confirmation must start")
    check(env.store:getPurchase(env.intent_id).state == "accepted", "A received receipt must be durable")
    env.raw:finish(env.raw:find("reconcile_purchase"), { detail = env:detail(true) })
    check(#env.results == 1 and env.results[1].intent.state == "access_confirmed", "The original read continuation must remain available")
    local allowed, err = env.service:authorizeSubmission(env.intent_id)
    check(not allowed and err.kind == "duplicate_submission" and err.transmitted == false,
        "A completed confirmation cannot authorize another transmission")
    check(env.raw.started.purchase_submit == 1 and env.raw.submitted.quote == 2, "Success must neither repeat nor reprice the purchase")
end)

test("A failed rejection write retains non-transmission evidence until storage recovers", function()
    local env = fixture()
    local task, intent = env:queuePurchase()
    env.now = intent.quote.expires_at + 1
    local original = env.store.putPurchase
    env.store.putPurchase = function() error("Synthetic journal write failure") end
    check(env.raw:start(task) == false, "Expiration must prevent transmission even with unavailable journal storage")
    env.store.putPurchase = original
    check(#env.results == 1 and env.results[1].intent.state == "rejected" and env.results[1].intent.persistence_pending,
        "The caller must retain the observed local rejection")
    check(env.store:getPurchase(env.intent_id).state == "submitting", "The previous committed intent must still prevent reuse")
    local allowed, err = env.service:authorizeSubmission(env.intent_id)
    check(not allowed and err.kind == "persistence_pending" and err.transmitted == false, "Held evidence must block later dispatch")
    local reconciled
    env.app:reconcilePurchase(env.intent_id, function(value) reconciled = value end)
    env.ui:drain()
    check(reconciled and reconciled.state == "rejected" and not reconciled.persistence_pending,
        "Recovery must save the known result without server reconciliation")
    check((env.raw.started.purchase_submit or 0) == 0 and env.raw:find("reconcile_purchase") == nil,
        "Storage recovery must never send the rejected purchase")
    local saved = env:reopenIntent()
    check(saved.state == "rejected" and saved.error.transmitted == false, "Recovered non-transmission evidence must survive reopening")
end)

test("Dispatch uses the durable quote and refuses unavailable or uncommitted journal state", function()
    local env = fixture()
    local _, intent = env:queuePurchase()
    intent.quote.expires_at = env.now + 10000
    env.now = env.now + 121
    local allowed, err = env.service:authorizeSubmission(env.intent_id)
    check(not allowed and err.kind == "quote_expired", "A caller copy must not extend the persisted confirmation")
    env.store:transaction(function()
        allowed, err = env.service:authorizeSubmission(env.intent_id)
        check(not allowed and err.kind == "nested_transaction" and err.transmitted == false, "An open transaction cannot authorize dispatch")
    end)
    local original = env.store.getPurchase
    env.store.getPurchase = function() error("Synthetic journal read failure") end
    allowed, err = env.service:authorizeSubmission(env.intent_id)
    env.store.getPurchase = original
    check(not allowed and err.kind == "storage" and err.transmitted == false and err.definitive,
        "A journal read failure must fail closed before transmission")
end)

test("An unreadable journal still returns a held non-transmitted result to the caller", function()
    local env = fixture()
    local task = env:queuePurchase()
    local original = env.store.getPurchase
    env.store.getPurchase = function() error("Synthetic persistent journal read failure") end
    check(env.raw:start(task) == false, "Unavailable durable state must prevent transmission")
    env.store.getPurchase = original
    check(#env.results == 1 and env.results[1].intent.state == "rejected" and env.results[1].intent.persistence_pending,
        "A second storage failure must not swallow the caller's completion")
    check(env.results[1].intent.transaction_evidence == "not_transmitted" and env.store:getPurchase(env.intent_id).state == "submitting",
        "The held result must retain local non-transmission while the old journal remains committed")
    local recovered
    env.app:reconcilePurchase(env.intent_id, function(value) recovered = value end)
    env.ui:drain()
    check(recovered and recovered.state == "rejected" and recovered.error.transmitted == false,
        "Storage recovery must persist the held local result")
    check((env.raw.started.purchase_submit or 0) == 0 and env.raw:find("reconcile_purchase") == nil,
        "Recovery of a refused dispatch must not make another business request")
end)

for _, state in ipairs({ "outcome_unknown", "access_confirmed" }) do
    test("Refusing a stale dispatch preserves the earlier " .. state .. " range outcome", function()
        local env = fixture()
        local task = env:queuePurchase({ kind = "batch", batch_limit = 1, start_ord = 1, offer_index = 1, order = 1 })
        check(env.store:getPurchase(env.intent_id).quote.range_proof ~= nil, "The range must come from production Fetch/Range/Quote")
        local outcome = assert(env.service:completeSubmission(env.intent_id, nil, { kind = "timeout", transmitted = true }))
        if state == "access_confirmed" then
            outcome = assert(env.service:completeReconciliation(env.intent_id, env:detail(true)))
        end
        check(outcome.state == state and outcome.range_outcome_pending == true,
            "The earlier attempt must retain an unresolved range transaction")
        local before = env.store:getPurchase(env.intent_id)
        check(env.raw:start(task) == false, "A stale queued dispatch must be refused")
        local saved = env.store:getPurchase(env.intent_id)
        check(Value.encode(saved) == Value.encode(before), "A local refusal must not rewrite evidence from the earlier attempt")
        check(#env.results == 1 and env.results[1].intent.state == state and env.results[1].error.kind == "duplicate_submission",
            "The caller must receive the retained outcome and refusal separately")
        check(saved.range_outcome_pending and #env.service:listPending() == 1 and (env.raw.started.purchase_submit or 0) == 0,
            "The earlier range must stay held without another transmission")
        saved = env:reopenIntent()
        check(saved.state == state and saved.range_outcome_pending, "The preserved range hold must survive reopening SQLite")
    end)
end

test("Refusing a duplicate dispatch saves a held unknown outcome without negating it", function()
    local env = fixture()
    local task = env:queuePurchase({ kind = "batch", batch_limit = 1, start_ord = 1, offer_index = 1, order = 1 })
    local original = env.store.putPurchase
    env.store.putPurchase = function() error("Synthetic lost outcome persistence") end
    local outcome = assert(env.service:completeSubmission(env.intent_id, nil, { kind = "timeout", transmitted = true }))
    env.store.putPurchase = original
    check(outcome.state == "outcome_unknown" and outcome.persistence_pending and outcome.range_outcome_pending,
        "The earlier transmitted outcome must remain held in memory")
    check(env.raw:start(task) == false, "Held evidence must refuse another dispatch")
    local saved = env.store:getPurchase(env.intent_id)
    check(saved.state == "outcome_unknown" and saved.range_outcome_pending and not saved.persistence_pending,
        "The refusal may save the earlier result but cannot turn it into a rejection")
    check(env.service.unpersisted_results[env.intent_id] == nil and #env.results == 1
        and env.results[1].intent.state == "outcome_unknown" and (env.raw.started.purchase_submit or 0) == 0,
        "Recovered held state must remain visible without a new purchase")
end)

test("The synchronous service also checks expiry after its intent is committed", function()
    local env = fixture()
    env.service.client = {
        purchaseInfo = function() return env:quoteResponse().info end,
        comicDetail = function() return env:detail() end,
        buyEpisode = function() error("An expired synchronous purchase must not transmit") end,
    }
    local quote = assert(env.service:quote("10", nil, "coin"))
    local original = env.service.prepareSubmission
    env.service.prepareSubmission = function(self, ...)
        local intent, payload = original(self, ...)
        if intent then env.now = intent.quote.expires_at + 1 end
        return intent, payload
    end
    local intent, err = env.service:submit(quote, { confirmed = true })
    check(intent and intent.state == "rejected" and err.kind == "quote_expired" and err.transmitted == false,
        "Synchronous dispatch must share the durable expiry boundary")
end)

local passed = network_attempts == 0
for _, result in ipairs(tests) do passed = passed and result.passed end
Files.write(output .. "/purchase-dispatch-result.json", json.encode({ passed = passed, tests = tests, assertions = assertions,
    real_network_requests = network_attempts, real_purchases = 0, synthetic_credentials_only = true,
    network_namespace_isolated = true }, { pretty = true }))
os.exit(passed and 0 or 1)
