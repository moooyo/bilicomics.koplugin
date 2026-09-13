local root = assert(arg[1], "Pass the plugin root")
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local Service = require("bilicomics/purchase/service")
local Value = require("bilicomics/purchase/value")

local passed = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    passed = passed + 1
    print("PASS " .. name)
end
local function equal(actual, expected)
    assert(Value.encode(actual) == Value.encode(expected), "Unexpected value: " .. Value.encode(actual))
end
local function errorKind(value, err, kind)
    assert(value == nil, "An error was expected")
    assert(err and err.kind == kind, "Unexpected error: " .. Value.encode(err))
end

local function fixture()
    local store = {account_key = "account-a", purchases = {}, settings = {}, episodes = {
        {id = "10", comic_id = "1", title = "First", order = 1, access = "locked"},
        {id = "11", comic_id = "1", title = "Special", order = 1.5, access = "locked"},
        {id = "12", comic_id = "1", title = "Second", order = 2, access = "locked"},
    }}
    function store:getEpisode(id)
        for _, episode in ipairs(self.episodes) do if episode.id == tostring(id) then return Value.copy(episode) end end
    end
    function store:listEpisodes() return Value.copy(self.episodes) end
    function store:getSetting(key, default) return self.settings[key] or default end
    function store:putSetting(key, value) self.settings[key] = value end
    function store:getPurchase(id) return Value.copy(self.purchases[id]) end
    function store:putPurchase(intent)
        if self.fail_writes then error("Simulated disk failure") end
        self.purchases[intent.id] = Value.copy(intent)
    end
    function store:listPurchases(states)
        local allowed = {}
        for _, state in ipairs(states or {}) do allowed[state] = true end
        local result = {}
        for _, intent in pairs(self.purchases) do
            if not states or allowed[intent.state] then result[#result + 1] = Value.copy(intent) end
        end
        return result
    end
    function store:transaction(fn)
        local before, settings = Value.copy(self.purchases), Value.copy(self.settings)
        local ok, value = pcall(fn)
        if not ok then self.purchases, self.settings = before, settings; error(value, 0) end
        return value
    end
    local client = {calls = 0, buy_calls = 0, info = {
        ep_id = "10", comic_id = "1", ep_original_gold = 30, pay_gold = 30, remain_gold = 100,
        allow_coupon = true, ep_pay_coupons = 1, remain_coupon = 2, recommend_coupon_ids = {"501"},
        batch_buy = {{batch_limit = 3, amount = 3, pay_gold = 27, original_gold = 90,
            final_pay_amount = 81, usable = true, exact_scope_verified = true,
            start_ord = 1, episode_ids = {"10", "11", "12"}}},
    }}
    function client:purchaseInfo(id)
        if BILI_NONSPENDING_EVIDENCE then
            BILI_NONSPENDING_EVIDENCE.synthetic_read_calls = BILI_NONSPENDING_EVIDENCE.synthetic_read_calls + 1
        end
        self.calls = self.calls + 1
        if self.quote_error then return nil, self.quote_error end
        local info = Value.copy(self.info)
        info.ep_id = tostring(id)
        return info
    end
    function client:comicDetail()
        if BILI_NONSPENDING_EVIDENCE then
            BILI_NONSPENDING_EVIDENCE.synthetic_read_calls = BILI_NONSPENDING_EVIDENCE.synthetic_read_calls + 1
        end
        self.calls = self.calls + 1
        if self.detail_error then return nil, self.detail_error end
        return {comic = {id = "1"}, episodes = Value.copy(store.episodes)}
    end
    function client:buyEpisode(payload)
        if BILI_NONSPENDING_EVIDENCE then
            BILI_NONSPENDING_EVIDENCE.synthetic_submit_calls = BILI_NONSPENDING_EVIDENCE.synthetic_submit_calls + 1
        end
        self.calls, self.buy_calls = self.calls + 1, self.buy_calls + 1
        self.last_payload = Value.copy(payload)
        if self.on_buy then return self.on_buy(payload) end
        return {accepted = true}
    end
    local state = {now = 1000, ids = 0}
    local options = {store = store, client = client, clock = function() return state.now end,
        id_factory = function(kind) state.ids = state.ids + 1; return kind .. "-" .. state.ids end}
    local service = Service.new(options)
    local function quote(scope, payment, id)
        local result, err = service:quote(id or "10", scope, payment)
        assert(result, err and err.kind)
        return result
    end
    return service, store, client, state, quote, options
end

test("single coin uses the server amount and safe payload", function()
    local service, _, _, _, quote = fixture()
    local q = quote()
    equal(q.payload, {buy_method = 3, ep_id = "10", pay_amount = 30})
    equal(q.episode_ids, {"10"})
    equal(q.expected_access, {["10"] = {access = "owned"}})
    local intent, payload = service:prepareSubmission(q, {confirmed = true, purpose = "read"}, quote())
    equal(intent.state, "submitting")
    equal(payload, q.payload)
end)

test("single coupon passes the selected array without coin fallback", function()
    local _, _, _, _, quote = fixture()
    local q = quote(nil, "coupon")
    equal(q.payload, {buy_method = 2, ep_id = "10", coupon_ids = {"501"}})
    assert(q.payload.coupon_id == nil and q.payload.pay_amount == nil)
end)

test("ineligible coupon is rejected", function()
    local service = fixture()
    local q, err = service:quote("10", nil, {method = "coupon", coupon_ids = {"999"}})
    errorKind(q, err, "ineligible_coupon")
end)

test("batch offer fields cannot bypass the missing exact-scope proof", function()
    local service, store, client, _, quote = fixture()
    local q = quote({kind = "batch", batch_limit = 3, start_ord = 1})
    assert(q.submittable == false and q.payload == nil and q.episode_ids == nil and q.fingerprint == nil)
    assert(q.scope.batch_limit == 3 and q.scope.start_ord == 1 and q.scope.offer_index == 1)
    local value, err = service:submit(q, {confirmed = true})
    errorKind(value, err, "quote_unverified")
    equal(client.buy_calls, 0)
    equal(#store:listPurchases(), 0)
end)

test("unverified batch set is never inferred from catalog", function()
    local service, _, client = fixture()
    client.info.batch_buy[1].episode_ids = nil
    local q, err = service:quote("10", {kind = "batch", batch_limit = 3, start_ord = 1})
    assert(q and not err and q.submittable == false and q.episode_ids == nil and q.payload == nil)
    local value
    value, err = service:submit(q, {confirmed = true})
    errorKind(value, err, "quote_unverified")
    equal(client.buy_calls, 0)
end)

test("batch pay_gold is not assumed to be final payable total", function()
    local service, _, client = fixture()
    client.info.batch_buy[1].final_pay_amount = nil
    local q, err = service:quote("10", {kind = "batch", batch_limit = 3, start_ord = 1})
    assert(q and not err and q.submittable == false and q.amount == nil and q.payload == nil)
    local value
    value, err = service:submit(q, {confirmed = true})
    errorKind(value, err, "quote_unverified")
    equal(client.buy_calls, 0)
end)

test("unsupported wildcard keys and arbitrary chapter sets are rejected", function()
    local service = fixture()
    local q, err = service:quote("10", {kind = "batch", limit = 0})
    errorKind(q, err, "invalid_scope")
    q, err = service:quote("10", {kind = "single", episode_ids = {"10", "12"}})
    errorKind(q, err, "invalid_scope")
end)

test("batch coupon purchases are not emulated", function()
    local service = fixture()
    local q, err = service:quote("10", {kind = "batch", batch_limit = 3, start_ord = 1}, "coupon")
    errorKind(q, err, "invalid_payment")
end)

test("explicit confirmation is required without any network call", function()
    local service, _, client, _, quote = fixture()
    local q, before = quote(), client.calls
    before = client.calls
    local result, err = service:submit(q, {purpose = "download"})
    errorKind(result, err, "confirmation_required")
    equal(client.calls, before)
end)

test("insufficient balance preserves quote but sends no purchase", function()
    local service, _, client, _, quote = fixture()
    client.info.remain_gold = 10
    local q = quote()
    assert(q.can_afford == false)
    local result, err = service:submit(q, {confirmed = true})
    errorKind(result, err, "insufficient_balance")
    equal(client.buy_calls, 0)
end)

test("changed amount requires fresh confirmation", function()
    local service, _, client, _, quote = fixture()
    local q = quote()
    client.info.ep_original_gold, client.info.pay_gold = 31, 31
    local result, err = service:submit(q, {confirmed = true})
    errorKind(result, err, "quote_changed")
    equal(err.quote.amount, 31)
    equal(client.buy_calls, 0)
end)

test("unverified fresh price blocks the previous confirmation", function()
    local service, store, client, _, quote = fixture()
    local q = quote()
    client.info.pay_gold = 31
    local result, err = service:submit(q, {confirmed = true})
    errorKind(result, err, "quote_unverified")
    equal(client.buy_calls, 0)
    equal(#store:listPurchases(), 0)
end)

test("tampered payment payload is rejected", function()
    local service, _, client, _, quote = fixture()
    local q = quote()
    q.payload.auto_pay_gold_status = 1
    local result, err = service:submit(q, {confirmed = true})
    errorKind(result, err, "invalid_quote")
    equal(client.buy_calls, 0)
end)

test("expired quote is not submitted", function()
    local service, _, client, state, quote = fixture()
    local q = quote()
    state.now = 2000
    local result, err = service:submit(q, {confirmed = true})
    errorKind(result, err, "quote_expired")
    equal(client.buy_calls, 0)
end)

test("journal exists before the network can transmit", function()
    local service, store, client, _, quote = fixture()
    client.on_buy = function()
        local pending = store:listPurchases({"submitting"})
        equal(#pending, 1)
        equal(pending[1].attempts, 1)
        return nil, {kind = "timeout", transmitted = true}
    end
    local intent, err = service:submit(quote(), {confirmed = true})
    equal(intent.state, "outcome_unknown")
    equal(err.kind, "outcome_unknown")
end)

test("failed journal prevents network transmission", function()
    local service, store, client, _, quote = fixture()
    local q = quote()
    store.fail_writes = true
    local intent, err = service:submit(q, {confirmed = true})
    errorKind(intent, err, "storage")
    equal(client.buy_calls, 0)
end)

test("duplicate confirmation is rejected durably", function()
    local service, _, client, _, quote = fixture()
    local q = quote()
    local first = assert(service:prepareSubmission(q, {confirmed = true}, quote()))
    local result, err = service:prepareSubmission(q, {confirmed = true}, quote())
    errorKind(result, err, "duplicate_submission")
    equal(err.intent_id, first.id)
    equal(client.buy_calls, 0)
end)

test("account only has one active submission", function()
    local service, _, _, _, quote = fixture()
    assert(service:prepareSubmission(quote(), {confirmed = true}, quote()))
    local q = quote(nil, nil, "11")
    local result, err = service:prepareSubmission(q, {confirmed = true}, quote(nil, nil, "11"))
    errorKind(result, err, "purchase_busy")
end)

test("restart marks interrupted submission unknown without replay", function()
    local service, _, client, _, quote, options = fixture()
    assert(service:prepareSubmission(quote(), {confirmed = true}, quote()))
    local restarted = Service.new(options)
    local before = client.calls
    local pending = assert(restarted:recover())
    equal(#pending, 1)
    equal(pending[1].state, "outcome_unknown")
    equal(client.calls, before)
    equal(client.buy_calls, 0)
    local result, err = restarted:prepareSubmission(quote(), {confirmed = true}, quote())
    errorKind(result, err, "outcome_unknown")
end)

test("definitive rejection needs a new explicit quote", function()
    local service, _, client, _, quote = fixture()
    client.on_buy = function() return nil, {kind = "purchase_rejected", definitive = true, code = 2} end
    local q = quote()
    local intent, err = service:submit(q, {confirmed = true})
    equal(intent.state, "rejected")
    equal(err.code, 2)
    local result, duplicate_error = service:prepareSubmission(q, {confirmed = true}, quote())
    errorKind(result, duplicate_error, "duplicate_submission")
    equal(client.buy_calls, 1)
end)

test("pretransmission failure cannot consume and is never auto retried", function()
    local service, _, client, _, quote = fixture()
    client.on_buy = function() return nil, {kind = "capability", transmitted = false} end
    local intent = assert(service:submit(quote(), {confirmed = true}))
    equal(intent.state, "rejected")
    equal(intent.transaction_evidence, "not_transmitted")
    equal(client.buy_calls, 1)
end)

test("unclassified exception is unknown and private data is absent", function()
    local service, store, client, _, quote = fixture()
    client.on_buy = function() error("SESSDATA=private-cookie-value") end
    local intent = assert(service:submit(quote(), {confirmed = true}))
    equal(intent.state, "outcome_unknown")
    assert(not Value.encode(store.purchases):find("private%-cookie"))
    equal(client.buy_calls, 1)
end)

test("accepted remains accepted when entitlement refresh fails", function()
    local service, _, client, _, quote = fixture()
    client.on_buy = function() client.detail_error = {kind = "connectivity"}; return {accepted = true} end
    local intent, err = service:submit(quote(), {confirmed = true})
    equal(intent.state, "accepted")
    equal(intent.transaction_evidence, "server_accepted")
    assert(err and intent.reconciliation_error)
end)

test("temporary access and wallet changes do not prove ownership", function()
    local service, store, _, _, quote = fixture()
    local intent = assert(service:prepareSubmission(quote(), {confirmed = true}, quote()))
    intent = assert(service:completeSubmission(intent.id, nil, {kind = "timeout"}))
    store.episodes[1].access, store.episodes[1].expires_at = "temporary", 5000
    intent = assert(service:completeReconciliation(intent.id, store.episodes, {remain_gold = 70}))
    equal(intent.state, "outcome_unknown")
    equal(intent.confirmed_episode_ids, {})
    equal(intent.unresolved_episode_ids, {"10"})
end)

test("access confirmation does not fabricate a payment receipt", function()
    local service, store, client, _, quote = fixture()
    client.on_buy = function() store.episodes[1].access = "owned"; return nil, {kind = "timeout"} end
    local intent = assert(service:submit(quote(), {confirmed = true}))
    intent = assert(service:reconcile(intent.id))
    equal(intent.state, "access_confirmed")
    equal(intent.transaction_evidence, "none")
    equal(intent.access_confirmation_source, "episode_entitlements")
    equal(client.buy_calls, 1)
end)

test("historical accepted multi-episode journal preserves unresolved overlap", function()
    local service, store, client, _, quote = fixture()
    -- This is a retained historical journal fixture, not a newly authorized batch.
    -- No current quote, exact-scope proof or payable batch payload is fabricated.
    local intent = {
        id = "historical-accepted-fixture", account_key = "account-a", comic_id = "1",
        state = "accepted", episode_ids = {"10", "11", "12"}, purpose = "download",
        expected_access = {["10"] = {access = "owned"}, ["11"] = {access = "owned"}, ["12"] = {access = "owned"}},
        before_access = {["10"] = {access = "locked"}, ["11"] = {access = "locked"}, ["12"] = {access = "locked"}},
        quote = {id = "historical-quote-fixture"}, confirmed_episode_ids = {},
        unresolved_episode_ids = {"10", "11", "12"}, transaction_evidence = "server_accepted",
        attempts = 1, created_at = 1000, updated_at = 1000, fixture_origin = "historical accepted journal",
    }
    store:putPurchase(intent)
    store.episodes[1].access = "owned"
    intent = assert(service:completeReconciliation(intent.id, store.episodes))
    equal(intent.state, "accepted")
    equal(intent.confirmed_episode_ids, {"10"})
    equal(intent.unresolved_episode_ids, {"11", "12"})
    local q = quote(nil, nil, "11")
    local result, err = service:prepareSubmission(q, {confirmed = true}, quote(nil, nil, "11"))
    errorKind(result, err, "outcome_unknown")
    store.episodes[2].access, store.episodes[3].access = "owned", "owned"
    intent = assert(service:completeReconciliation(intent.id, store.episodes))
    equal(intent.state, "access_confirmed")
    equal(intent.unresolved_episode_ids, {})
    equal(intent.purpose, "download")
    equal(intent.fixture_origin, "historical accepted journal")
    equal(client.buy_calls, 0)
end)

test("stale failure callback does not overwrite accepted state", function()
    local service, _, _, _, quote = fixture()
    local intent = assert(service:prepareSubmission(quote(), {confirmed = true}, quote()))
    assert(service:completeSubmission(intent.id, {accepted = true}))
    intent = assert(service:completeSubmission(intent.id, nil, {kind = "timeout"}))
    equal(intent.state, "accepted")
end)

test("cross account callback cannot touch another purchase", function()
    local service, store, _, _, quote = fixture()
    local intent = assert(service:prepareSubmission(quote(), {confirmed = true}, quote()))
    local other = Service.new({store = store, account_key = "account-b"})
    local result, err = other:completeSubmission(intent.id, {accepted = true})
    errorKind(result, err, "account_mismatch")
    equal(store:getPurchase(intent.id).state, "submitting")
end)

test("original quote cannot serve as its own refreshed quote", function()
    local service, _, _, _, quote = fixture()
    local q = quote()
    local intent, err = service:prepareSubmission(q, {confirmed = true}, q)
    errorKind(intent, err, "quote_refresh_required")
end)

test("an unclassified purchase rejection remains uncertain", function()
    local service, _, client, _, quote = fixture()
    client.on_buy = function() return nil, {kind = "purchase_rejected", code = 99} end
    local intent = assert(service:submit(quote(), {confirmed = true}))
    equal(intent.state, "outcome_unknown")
    equal(client.buy_calls, 1)
end)

test("accepted write failure survives a delayed failure callback", function()
    local service, store, _, _, quote = fixture()
    local intent = assert(service:prepareSubmission(quote(), {confirmed = true}, quote()))
    store.fail_writes = true
    local accepted, err = service:completeSubmission(intent.id, {accepted = true})
    equal(accepted.state, "accepted")
    equal(err.kind, "storage")
    assert(accepted.persistence_pending)
    equal(store:getPurchase(intent.id).state, "submitting")
    equal(service:listPending()[1].state, "accepted")
    store.fail_writes = false
    accepted = assert(service:completeSubmission(intent.id, nil, {kind = "timeout"}))
    equal(accepted.state, "accepted")
    equal(store:getPurchase(intent.id).state, "accepted")
    assert(not accepted.persistence_pending)
end)

test("rejected write failure can be flushed without network", function()
    local service, store, client, _, quote = fixture()
    local intent = assert(service:prepareSubmission(quote(), {confirmed = true}, quote()))
    store.fail_writes = true
    local rejected = assert(service:completeSubmission(intent.id, nil, {kind = "purchase_rejected", definitive = true, code = 2}))
    assert(rejected.persistence_pending and rejected.state == "rejected")
    store.fail_writes = false
    local before = client.calls
    rejected = assert(service:reconcile(intent.id))
    equal(store:getPurchase(intent.id).state, "rejected")
    equal(client.calls, before)
    assert(not rejected.persistence_pending)
end)

test("confirmed access write failure can be flushed without network", function()
    local service, store, client, _, quote = fixture()
    local intent = assert(service:prepareSubmission(quote(), {confirmed = true}, quote()))
    assert(service:completeSubmission(intent.id, {accepted = true}))
    store.episodes[1].access = "owned"
    store.fail_writes = true
    local confirmed = assert(service:completeReconciliation(intent.id, store.episodes))
    assert(confirmed.persistence_pending and confirmed.state == "access_confirmed")
    store.fail_writes = false
    local before = client.calls
    confirmed = assert(service:reconcile(intent.id))
    equal(store:getPurchase(intent.id).state, "access_confirmed")
    equal(client.calls, before)
    assert(not confirmed.persistence_pending)
end)

test("explicit permanent ownership with zero expiry is confirmed", function()
    local service, store, _, _, quote = fixture()
    local intent = assert(service:prepareSubmission(quote(), {confirmed = true}, quote()))
    assert(service:completeSubmission(intent.id, {accepted = true}))
    store.episodes[1].access, store.episodes[1].expires_at = "owned", 0
    intent = assert(service:completeReconciliation(intent.id, store.episodes))
    equal(intent.state, "access_confirmed")
end)

print("Purchase state machine: " .. passed .. " cases passed; no live purchases or remote account calls.")
