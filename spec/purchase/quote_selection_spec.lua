-- Fake-response quote contracts only; never load a real Client, transport, or submission service.
local root, output = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local ffi = require("ffi")
local json = require("rapidjson")
local report = { passed = false, assertions = 0, groups = {}, fake_calls = 0,
    buy_episode_calls = 0, forbidden_module_attempts = 0,
    transport_safety = "Real Client and transport module loading is blocked; no request-level transport counter is installed",
    scope = "Synthetic quote selection and advisory construction; no submission or account activity" }
ffi.cdef[[long readlink(const char *path, char *buf, unsigned long size);]]
local namespace = ffi.new("char[128]")
local namespace_size = ffi.C.readlink("/proc/self/ns/net", namespace, 128)
assert(namespace_size > 0 and ffi.string(namespace, namespace_size) ~= assert(os.getenv("BILI_QUOTE_PARENT_NETNS")),
    "A distinct network namespace is required")
report.network_namespace_isolated = true

for _, name in ipairs({ "bilicomics/protocol/client", "bilicomics/protocol/transport",
    "bilicomics/protocol/session", "bilicomics/purchase/service", "bilicomics/jobs/worker",
    "socket.http", "socket.https", "ssl" }) do
    package.preload[name] = function()
        report.forbidden_module_attempts = report.forbidden_module_attempts + 1
        error("Real account, network and submission modules are forbidden", 0)
    end
end
local Selection = require("bilicomics/purchase/selection")
local Fetch = require("bilicomics/purchase/quote_fetch")
local Candidate = require("bilicomics/purchase/candidate")
local Quote = require("bilicomics/purchase/quote")
local Value = require("bilicomics/purchase/value")
local Model = require("bilicomics/ui/model")

local function check(condition, message)
    report.assertions = report.assertions + 1
    assert(condition, message or "Contract assertion failed")
end
local function same(left, right)
    check(Value.encode(left) == Value.encode(right), "Unexpected structured value")
end
local function rejected(value, err, kind)
    check(value == nil and type(err) == "table" and err.kind == kind, "Unexpected rejection kind")
end
local function has(values, wanted)
    for _, value in ipairs(values or {}) do if value == wanted then return true end end
    return false
end
local function test(name, fn)
    local ok, failure = pcall(fn)
    report.groups[#report.groups + 1] = { name = name, passed = ok, failure = not ok and tostring(failure) or nil }
    print((ok and "PASS " or "FAIL ") .. name .. (not ok and (": " .. tostring(failure)) or ""))
end
local function advisory(quote)
    check(quote and quote.submittable == false, "A candidate must remain non-submittable")
    for _, key in ipairs({ "payload", "episode_ids", "amount", "balance", "can_afford", "expected_access", "fingerprint" }) do
        check(quote[key] == nil, "A candidate must not expose submission terms")
    end
end

local function fixture()
    return {
        info = { ep_id = "10", comic_id = "1", ep_original_gold = 100, original_gold = 1000,
            pay_gold = 100, remain_gold = 500, allow_coupon = true, ep_pay_coupons = 2, remain_coupon = 3,
            recommend_coupon_ids = { "coupon-a", "coupon-b" }, eligible_coupon_ids = { "coupon-a", "coupon-b", "coupon-c" },
            batch_buy = {
                { batch_limit = 10, amount = 10, usable = false, original_gold = 200, pay_gold = 180 },
                { batch_limit = 20, amount = 20, usable = true, original_gold = 300, pay_gold = 270 },
                { batch_limit = 30, amount = 36, usable = true, original_gold = 400, pay_gold = 360 },
            } },
        detail = { comic = { id = "1" }, episodes = {
            { id = "10", comic_id = "1", order = 12.5, access = "locked" },
            { id = "11", comic_id = "1", order = 13, access = "locked" },
        } },
        range = { ep_id = "10", comic_id = "1", pay_gold = 7, ep_original_gold = 9999,
            batch_buy = { { batch_limit = 99, usable = true, amount = 99, original_gold = 9999 } },
            optional_discount_list = {
                { discount_type = 1, discount_info = { id = "card-a", is_usable = true, amount = 1, discount = 90, discount_limit = 0 } },
                { discount_type = 0, discount_act_info = { id = "act-a", is_usable = true, saved_gold = 25 } },
                { discount_type = 2, free_gold_card = { card_id = "credit-a", is_usable = true,
                    prime_gold_count = 40, total = 800, expired_total = 300 } },
            } },
        calculated = { ["100"] = 90, ["1000"] = 900, ["200"] = 180, ["300"] = 270, ["400"] = 360 },
        free_gold = { is_ban = false }, calls = {},
    }
end
local function batch()
    return { kind = "batch", batch_limit = 30, start_ord = 12.5, order = 2, offer_index = 3 }
end
local function payment(kind, id)
    return { method = "coin", discount = { kind = kind or "none", id = id } }
end
local function fakeClient(f)
    local function record(method, arguments)
        report.fake_calls = report.fake_calls + 1
        f.calls[#f.calls + 1] = { method = method, arguments = Value.copy(arguments) }
    end
    return {
        purchaseInfo = function(_, id, scope)
            record("purchaseInfo", { id = id, scope = scope })
            if f.on_info then f.on_info(scope) end
            return Value.copy(scope and f.range or f.info)
        end,
        comicDetail = function(_, id) record("comicDetail", { id = id }); return Value.copy(f.detail) end,
        discountPrice = function(_, id, values)
            record("discountPrice", { id = id, values = values }); return Value.copy(f.calculated)
        end,
        freeGoldCardInfo = function(_, comic, episode, scope)
            record("freeGoldCardInfo", { comic = comic, episode = episode, scope = scope }); return Value.copy(f.free_gold)
        end,
        buyEpisode = function()
            report.buy_episode_calls = report.buy_episode_calls + 1
            error("BuyEpisode is forbidden even on the fake Client", 0)
        end,
    }
end
local function fetch(f, scope, selected_payment)
    return Fetch.run(fakeClient(f), { comic_id = "1", episode_id = "10", scope = scope, payment = selected_payment })
end
local function context(f, scope, selected_payment)
    return { comic_id = "1", episode_id = "10", selection = assert(Selection.normalize(scope, selected_payment)),
        range_info = Value.copy(f.range), original_values = {100, 1000, 200, 300, 400},
        calculated_prices = Value.copy(f.calculated), free_gold_card_info = Value.copy(f.free_gold) }
end
local function build(f, scope, selected_payment, ctx)
    return Quote.build{ info = f.info, episodes = f.detail.episodes, episode_id = "10", scope = scope,
        payment = selected_payment, context = ctx, id = "synthetic-quote", account_key = "synthetic-account",
        now = 100, max_age = 120 }
end

test("selection preserves scope and discount identity without mutable aliases", function()
    local scope = { kind = "batch", batch_limit = "30", start_ord = "12.5", order = "2", offer_index = "3" }
    local pay = payment("discount_card", 123)
    local selected = assert(Selection.normalize(scope, pay))
    same(selected.scope, batch())
    check(selected.payment.discount.id == "123")
    scope.order, pay.discount.id = 1, 456
    check(selected.scope.order == 2 and selected.payment.discount.id == "123")
    local wire = assert(Selection.requestScope(selected.scope))
    same(wire, { kind = "batch", buy_type = 2, batch_limit = 30, start_ord = 12.5, order = 2 })
    check(wire.offer_index == nil)
    wire.order = 1; check(selected.scope.order == 2)
end)

test("zero range and fractional ordinals stay query-only selections", function()
    local selected = assert(Selection.normalize({ kind = "batch", batch_limit = 0, start_ord = -1.5 }))
    check(selected.scope.batch_limit == 0 and selected.scope.start_ord == -1.5 and selected.scope.order == 1)
    same(assert(Selection.normalize()), { scope = { kind = "single", order = 1 }, payment = payment() })
end)

test("malformed and injected selection terms are rejected before fake reads", function()
    local cases = {
        { { kind = "single", offer_index = 1 }, nil, "invalid_scope" },
        { { kind = "batch", batch_limit = -1 }, nil, "invalid_scope" },
        { { kind = "batch", batch_limit = 1.5 }, nil, "invalid_scope" },
        { { kind = "batch", batch_limit = 1, start_ord = math.huge }, nil, "invalid_scope" },
        { { kind = "single", order = 3 }, nil, "invalid_scope" },
        { { kind = "single", exact_scope_verified = true }, nil, "invalid_scope" },
        { { kind = "batch", batch_limit = 1 }, { method = "coupon" }, "invalid_payment" },
        { nil, { method = "coin", pay_amount = 1 }, "invalid_payment" },
        { nil, payment("discount_card"), "invalid_payment" },
        { nil, payment("none", "unexpected"), "invalid_payment" },
        { nil, payment("activity", 9007199254740992), "invalid_payment" },
        { nil, { method = "coupon", coupon_ids = {1, "1"} }, "invalid_payment" },
        { nil, { method = "coupon", coupon_ids = {[1] = "a", [3] = "b"} }, "invalid_payment" },
        { nil, { method = "coupon", coupon_ids = {"line\nbreak"} }, "invalid_payment" },
    }
    for _, item in ipairs(cases) do
        local f = fixture()
        local value, err = fetch(f, item[1], item[2])
        rejected(value, err, item[3]); check(#f.calls == 0)
    end
end)

test("opaque coupon IDs and their order survive independent copies", function()
    local input = { method = "coupon", coupon_ids = {1, "01", "9007199254740993"} }
    local selected = assert(Selection.normalize(nil, input))
    same(selected.payment.coupon_ids, {"1", "01", "9007199254740993"})
    input.coupon_ids[1] = "changed"; check(selected.payment.coupon_ids[1] == "1")
    selected.payment.coupon_ids[2] = "changed"; check(input.coupon_ids[2] == "01")
end)

test("basic and scoped reads keep full original offer and price-vector association", function()
    local f, scope, pay = fixture(), batch(), payment("discount_card", "card-a")
    local result = assert(fetch(f, scope, pay))
    same({f.calls[1].method, f.calls[2].method, f.calls[3].method, f.calls[4].method},
        {"purchaseInfo", "comicDetail", "purchaseInfo", "discountPrice"})
    check(f.calls[1].arguments.scope == nil)
    same(f.calls[3].arguments.scope, {kind = "batch", buy_type = 2, batch_limit = 30, start_ord = 12.5, order = 2})
    same(f.calls[4].arguments.values, {100, 1000, 200, 300, 400})
    check(result.info.pay_gold == 100 and result.context.range_info.pay_gold == 7)
    check(result.info.batch_buy[1].usable == false and #result.info.batch_buy == 3)
    local metadata = assert(Candidate.describe(result.info, result.detail.episodes[1], result.context.selection, result.context))
    check(metadata.selected_offer.offer_index == 3 and metadata.selected_offer.price_vector_index == 5)
    check(metadata.amounts.original == 400 and metadata.amounts.display == 360 and metadata.amounts.submission == 360)
    check(result.context.exact_scope_verified == nil)
    advisory(assert(build(f, scope, pay, result.context)))
end)

test("fetch captures input selection before a fake response mutates its caller", function()
    local f, scope, pay = fixture(), batch(), payment("discount_card", "card-a")
    f.on_info = function(wire)
        if not wire then scope.order, scope.offer_index, pay.discount.id = 1, 2, "changed" end
    end
    local result = assert(fetch(f, scope, pay))
    check(result.context.selection.scope.order == 2 and result.context.selection.scope.offer_index == 3)
    check(result.context.selection.payment.discount.id == "card-a")
    check(f.calls[3].arguments.scope.order == 2 and f.calls[4].arguments.id == "card-a")
end)

test("identity failures stop at the affected fake read", function()
    local cases = {
        { function(f) f.info.ep_id = "99" end, "invalid_quote", 1 },
        { function(f) f.info.comic_id = "99" end, "invalid_quote", 1 },
        { function(f) f.detail.comic.id = "99" end, "invalid_quote", 2 },
        { function(f) f.detail.episodes[1].comic_id = "99" end, "invalid_quote", 2 },
        { function(f) f.detail.episodes[#f.detail.episodes + 1] = Value.copy(f.detail.episodes[1]) end, "invalid_quote", 2 },
        { function(f) f.detail.episodes[1].id = "99" end, "access_unknown", 2 },
        { function(f) f.range.ep_id = "99" end, "invalid_quote", 3 },
        { function(f) f.range.comic_id = "99" end, "invalid_quote", 3 },
    }
    for _, item in ipairs(cases) do
        local f = fixture(); item[1](f)
        local value, err = fetch(f)
        rejected(value, err, item[2]); check(#f.calls == item[3])
    end
end)

test("changed or ambiguous batch offers stop before a scoped read", function()
    local f = fixture(); f.detail.episodes[1].order = 13
    local value, err = fetch(f, batch()); rejected(value, err, "selection_changed"); check(#f.calls == 2)
    f = fixture(); f.info.batch_buy[3].usable = false
    value, err = fetch(f, batch()); rejected(value, err, "selection_changed"); check(#f.calls == 2)
    f = fixture(); f.info.batch_buy[2].batch_limit = 30
    local scope = batch(); scope.offer_index = nil
    value, err = fetch(f, scope); rejected(value, err, "selection_changed"); check(#f.calls == 2)
    f = fixture(); f.info.batch_buy.extra = {}
    value, err = fetch(f, batch()); rejected(value, err, "invalid_quote"); check(#f.calls == 2)
end)

test("missing original-price evidence never shifts the vector or becomes zero", function()
    for _, index in ipairs({1, 2, 3}) do
        local f, scope, pay = fixture(), batch(), payment("discount_card", "card-a")
        f.info.batch_buy[index].original_gold = nil
        local result = assert(fetch(f, scope, pay))
        check(result.context.original_values == nil and result.context.calculated_prices == nil and #f.calls == 3)
        local metadata = assert(Candidate.describe(result.info, f.detail.episodes[1], result.context.selection, result.context))
        check(metadata.amounts.submission == nil and has(metadata.blockers, "amount_unverified"))
    end
end)

test("calculated prices use the exact original amount key", function()
    local f, scope, pay = fixture(), batch(), payment("discount_card", "card-a")
    for _, prices in ipairs({ {["4e2"] = 12}, {["400.0"] = 12}, {["0400"] = 12}, {["399"] = 12} }) do
        local ctx = context(f, scope, pay); ctx.calculated_prices = prices
        local metadata = assert(Candidate.describe(f.info, f.detail.episodes[1], ctx.selection, ctx))
        check(metadata.amounts.submission == nil and has(metadata.blockers, "amount_unverified"))
    end
    for _, prices in ipairs({ {[400] = 12}, {["400"] = 12}, {[400] = 12, ["400"] = 12}, {["400"] = 0} }) do
        local ctx = context(f, scope, pay); ctx.calculated_prices = prices
        local metadata = assert(Candidate.describe(f.info, f.detail.episodes[1], ctx.selection, ctx))
        check(metadata.amounts.submission == (prices[400] or prices["400"]))
    end
    local ctx = context(f, scope, pay); ctx.calculated_prices = {[400] = 12, ["400"] = 13}
    local value, err = Candidate.describe(f.info, f.detail.episodes[1], ctx.selection, ctx)
    rejected(value, err, "selection_changed")
    ctx = context(f, scope, pay); ctx.original_values[3] = 201
    local metadata = assert(Candidate.describe(f.info, f.detail.episodes[1], ctx.selection, ctx))
    check(metadata.amounts.submission == nil)
end)

test("free-gold query uses reported count and does not infer single scope", function()
    local f, scope, pay = fixture(), batch(), payment("free_gold_card", "credit-a")
    local result = assert(fetch(f, scope, pay))
    check(#f.calls == 4 and f.calls[4].method == "freeGoldCardInfo")
    same(f.calls[4].arguments.scope, {buy_type = 2, batch_limit = 36})
    check(result.context.free_gold_card_info.is_ban == false)
    f = fixture(); result = assert(fetch(f, nil, pay)); check(#f.calls == 3 and result.context.free_gold_card_info == nil)
    for _, count in ipairs({0, -1, 1.5}) do
        f = fixture(); f.info.batch_buy[3].amount = count
        result = assert(fetch(f, scope, pay)); check(#f.calls == 3 and result.context.free_gold_card_info == nil)
    end
end)

test("ordinary, activity and coupon selections request no auxiliary assets", function()
    for _, pay in ipairs({ payment(), payment("activity", "act-a"), {method = "coupon"} }) do
        local f = fixture(); assert(fetch(f, nil, pay)); check(#f.calls == 3)
    end
end)

test("missing methods and fake Client errors remain non-disclosing failures", function()
    local value, err = Fetch.run({}, {episode_id = "10"})
    rejected(value, err, "capability")
    value, err = Fetch.run({purchaseInfo = function() error("FAKE_PRIVATE_SENTINEL") end}, {episode_id = "10"})
    rejected(value, err, "protocol"); check(not err.message:find("FAKE_PRIVATE_SENTINEL", 1, true))
end)

test("extra discount amounts remain advisory and separately observed", function()
    for _, item in ipairs({ {"discount_card", "card-a", 90}, {"activity", "act-a", 75}, {"free_gold_card", "credit-a", 100} }) do
        local f, pay = fixture(), payment(item[1], item[2])
        local ctx = context(f, nil, pay)
        local q = assert(build(f, nil, pay, ctx))
        advisory(q); check(q.amounts.original == 100 and q.amounts.submission == item[3])
        check(q.asset_snapshot.kind == item[1] and q.asset_snapshot.id == item[2])
        if item[1] == "free_gold_card" then check(q.amounts.free_gold == 40 and q.amounts.free_gold ~= 800) end
    end
end)

test("free-gold totals cannot replace missing scoped credit", function()
    local f, pay = fixture(), payment("free_gold_card", "credit-a")
    f.range.optional_discount_list[3].free_gold_card.prime_gold_count = nil
    local q = assert(build(f, nil, pay, context(f, nil, pay)))
    advisory(q); check(q.amounts.free_gold == nil and has(q.blockers, "amount_unverified"))
    f = fixture(); f.free_gold.is_ban = true
    q = assert(build(f, nil, pay, context(f, nil, pay)))
    advisory(q); check(q.asset_snapshot.is_ban == true and has(q.blockers, "asset_unavailable"))
end)

test("duplicate or disappeared scoped identities are rejected", function()
    local f, pay = fixture(), payment("discount_card", "card-a")
    f.range.optional_discount_list[#f.range.optional_discount_list + 1] = Value.copy(f.range.optional_discount_list[1])
    local value, err = build(f, nil, pay, context(f, nil, pay)); rejected(value, err, "selection_changed")
    f = fixture(); f.range.optional_discount_list = {}
    value, err = build(f, nil, pay, context(f, nil, pay)); rejected(value, err, "selection_changed")
    f = fixture(); f.range.optional_discount_list = nil
    local q = assert(build(f, nil, pay, context(f, nil, pay))); advisory(q); check(q.asset_snapshot == nil)
end)

test("context scope and identity changes cannot construct a usable quote", function()
    local cases = {
        function(ctx) ctx.selection.scope.order = 2 end,
        function(ctx) ctx.selection.payment.discount.id = "changed" end,
        function(ctx) ctx.comic_id = "different" end,
        function(ctx) ctx.episode_id = "different" end,
    }
    for _, mutate in ipairs(cases) do
        local f, pay = fixture(), payment("discount_card", "card-a")
        local ctx = context(f, nil, pay); mutate(ctx)
        local value, err = build(f, nil, pay, ctx); rejected(value, err, "invalid_selection")
    end
    local f, scope = fixture(), batch()
    local ctx = context(f, scope); ctx.selection.scope.offer_index = 2
    local value, err = build(f, scope, nil, ctx); rejected(value, err, "invalid_selection")
end)

test("unknown exact batch membership never creates a payable quote", function()
    local f, scope = fixture(), batch()
    f.info.batch_buy[3].exact_scope_verified = true
    f.info.batch_buy[3].episode_ids = {"10", "11"}
    f.info.batch_buy[3].start_ord = 12.5
    f.info.batch_buy[3].final_pay_amount = 360
    advisory(assert(build(f, scope, nil, context(f, scope))))
    advisory(assert(build(f, scope)))
    f.info.batch_buy[3].batch_limit = 0; scope.batch_limit = 0
    local q = assert(build(f, scope, nil, context(f, scope)))
    advisory(q); check(q.scope.batch_limit == 0 and q.scope.offer_index == 3)
end)

test("single coin construction requires matching present prices and balance", function()
    local f = fixture()
    local q = assert(build(f, nil, nil, context(f)))
    check(q.submittable == true and q.amount == 100 and q.balance == 500 and q.can_afford == true)
    same(q.payload, {buy_method = 3, ep_id = "10", pay_amount = 100})
    for _, key in ipairs({"ep_original_gold", "pay_gold", "remain_gold"}) do
        f = fixture(); f.info[key] = nil
        advisory(assert(build(f, nil, nil, context(f))))
    end
    f = fixture(); f.info.pay_gold = 90
    advisory(assert(build(f, nil, nil, context(f))))
    f = fixture(); f.info.ep_original_gold, f.info.pay_gold, f.info.remain_gold = 0, 0, 0
    q = assert(build(f, nil, nil, context(f)))
    check(q.submittable == true and q.amount == 0 and q.balance == 0 and q.payload.pay_amount == nil)
end)

test("fingerprints bind normalized order, amounts and coupon selection", function()
    local f = fixture()
    local first = assert(build(f, nil, nil, context(f)))
    local scope = {kind = "single", order = 2}
    local changed = assert(build(f, scope, nil, context(f, scope)))
    check(first.fingerprint ~= changed.fingerprint)
    f.info.remain_gold = 499
    changed = assert(build(f, nil, nil, context(f))); check(first.fingerprint ~= changed.fingerprint)
    f = fixture()
    local pay = {method = "coupon", coupon_ids = {"coupon-a", "coupon-b"}}
    first = assert(build(f, nil, pay, context(f, nil, pay)))
    pay.coupon_ids[2] = "coupon-c"
    changed = assert(build(f, nil, pay, context(f, nil, pay))); check(first.fingerprint ~= changed.fingerprint)
    same(first.payment.coupon_ids, {"coupon-a", "coupon-b"})
end)

test("coupon construction and display do not depend on coin metadata", function()
    local f, pay = fixture(), {method = "coupon", coupon_ids = {"coupon-b", "coupon-a"}}
    f.info.batch_buy, f.range.optional_discount_list = "not-a-coin-array", "not-a-coin-array"
    local q = assert(build(f, nil, pay, context(f, nil, pay)))
    check(q.submittable == true and q.method == "coupon" and q.amount == 2)
    same(q.payload, {buy_method = 2, ep_id = "10", coupon_ids = {"coupon-b", "coupon-a"}})
    local ids = assert(Model.couponIdentifiers(q))
    same(ids, {"coupon-b", "coupon-a"})
    ids[1] = "changed"; check(q.payment.coupon_ids[1] == "coupon-b")
    q.payment.coupon_ids[2] = "changed"; check(ids[2] == "coupon-a")
    q.submittable = false; check(Model.couponIdentifiers(q) == nil)
end)

test("coupon display rejects malformed arrays without using an alternate payload", function()
    local cases = { {}, {1}, {""}, {"line\nbreak"}, {[1] = "a", [3] = "b"}, {"a", extra = "b"}, {string.rep("x", 257)} }
    for _, ids in ipairs(cases) do
        check(Model.couponIdentifiers({submittable = true, payment = {method = "coupon", coupon_ids = ids},
            payload = {coupon_ids = {"must-not-be-used"}}}) == nil)
    end
    check(Model.couponIdentifiers({submittable = true, payment = payment(), payload = {coupon_ids = {"unused"}}}) == nil)
    local f, pay = fixture(), {method = "coupon", coupon_ids = {"coupon-a", "not-eligible"}}
    local value, err = build(f, nil, pay, context(f, nil, pay)); rejected(value, err, "ineligible_coupon")
end)

test("no real transport, account or submission module was accessed", function()
    check(report.forbidden_module_attempts == 0 and report.buy_episode_calls == 0)
    check(package.loaded["bilicomics/protocol/client"] == nil and package.loaded["bilicomics/protocol/transport"] == nil)
    check(package.loaded["bilicomics/purchase/service"] == nil and package.loaded["bilicomics/protocol/session"] == nil)
end)

report.passed = true
for _, group in ipairs(report.groups) do if not group.passed then report.passed = false end end
local file = assert(io.open(output, "wb")); file:write(json.encode(report)); file:close()
os.exit(report.passed and 0 or 1)
