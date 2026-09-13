-- Synthetic ordinal-range contracts only. Real account and submission modules are forbidden.
local root, output = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local ffi = require("ffi")
local json = require("rapidjson")
local report = {
    passed = false, assertions = 0, groups = {}, rejection_cases = {}, fake_calls = 0,
    buy_episode_calls = 0, forbidden_module_attempts = 0,
    scope = "Synthetic Range, fake quote collector, and pure Quote construction only",
    real_transaction_verified = false, actual_entitlement_verified = false,
}
ffi.cdef[[long readlink(const char *path, char *buf, unsigned long size);]]
local namespace = ffi.new("char[128]")
local namespace_size = ffi.C.readlink("/proc/self/ns/net", namespace, 128)
assert(namespace_size > 0
    and ffi.string(namespace, namespace_size) ~= assert(os.getenv("BILI_ORDINAL_PARENT_NETNS")),
    "A distinct network namespace is required")
report.network_namespace_isolated = true

local original_require = require
local forbidden = {
    ["bilicomics/protocol/client"] = true, ["bilicomics/protocol/transport"] = true,
    ["bilicomics/protocol/session"] = true, ["bilicomics/purchase/service"] = true,
    ["bilicomics/jobs/worker"] = true,
}
_G.require = function(name)
    if forbidden[name] or name:match("^socket") or name:match("^ssl") then
        report.forbidden_module_attempts = report.forbidden_module_attempts + 1
        error("Real account, network, and submission modules are forbidden", 0)
    end
    return original_require(name)
end
local Range = require("bilicomics/purchase/range")
local Selection = require("bilicomics/purchase/selection")
local Fetch = require("bilicomics/purchase/quote_fetch")
local Candidate = require("bilicomics/purchase/candidate")
local Quote = require("bilicomics/purchase/quote")
local Value = require("bilicomics/purchase/value")

local function check(condition, message)
    report.assertions = report.assertions + 1
    assert(condition, message or "Contract assertion failed")
end
local function same(left, right, message)
    check(Value.encode(left) == Value.encode(right), message or "Unexpected structured value")
end
local function test(name, fn)
    local ok, failure = pcall(fn)
    report.groups[#report.groups + 1] = {name = name, passed = ok,
        failure = not ok and tostring(failure) or nil}
    print((ok and "PASS " or "FAIL ") .. name .. (not ok and (": " .. tostring(failure)) or ""))
end
local function denied(value, err)
    check(value == nil and type(err) == "table" and type(err.kind) == "string",
        "Invalid evidence must return a structured rejection")
end
local function notSubmittable(value, err)
    if value == nil then return denied(value, err) end
    check(value.submittable == false, "Unproved terms must remain advisory")
    for _, key in ipairs({"payload", "episode_ids", "amount", "fingerprint", "expected_access"}) do
        check(value[key] == nil, "An advisory object must not expose executable terms: " .. key)
    end
end
local function coin()
    return {method = "coin", discount = {kind = "none"}}
end
local function rawRow(id, ord, locked, pay_mode, unlock_type, price)
    return {id = id, ord = ord, is_locked = locked, pay_mode = pay_mode,
        unlock_type = unlock_type, pay_gold = price, is_in_free = false,
        unlock_expire_at = "0000-00-00 00:00:00"}
end
local function fixture(zero)
    local ascending = {
        rawRow(101, 1, true, 1, 0, 7),
        rawRow(102, 2, false, 0, 0, 0),
        rawRow(103, 2.5, true, 1, 0, 11),
        rawRow(104, 3, false, 1, 1, 13),
        rawRow(105, 4, true, 1, 0, 17),
        rawRow(106, 4.5, false, 0, 0, 0),
        rawRow(107, 5, true, 1, 0, 23),
        rawRow(108, 6, true, 1, 0, 31),
    }
    local detail = {comic = {id = "1"}, episodes = {}, extra = {id = 1, ep_list = {}}}
    for index, raw in ipairs(ascending) do
        detail.extra.ep_list[#ascending - index + 1] = Value.copy(raw)
        detail.episodes[index] = {id = tostring(raw.id), comic_id = "1", order = raw.ord,
            access = raw.is_locked and "locked" or raw.pay_mode == 0 and "free" or "owned",
            pay_gold = raw.pay_gold, extra = Value.copy(raw)}
    end
    local info = {
        comic_id = 1, is_locked = true, ep_original_gold = 11, pay_gold = 11,
        original_gold = 89, remain_lock_ep_num = 5, remain_lock_ep_gold = 89,
        after_lock_ep_num = 4, after_lock_ep_gold = 82,
        ep_discount_type = 0, ep_discount = 0, discount_type = 0, discount = 0,
        remain_gold = 1000, allow_coupon = true, ep_pay_coupons = 1, remain_coupon = 2,
        recommend_coupon_ids = {"synthetic-coupon-a"},
        eligible_coupon_ids = {"synthetic-coupon-a", "synthetic-coupon-b"},
        optional_discount_list = {},
        batch_buy = {
            {batch_limit = 20, amount = 4, usable = false, original_gold = 82,
                pay_gold = 82, discount_type = 0, discount = 0, discount_batch_gold = 0},
            {batch_limit = 2, amount = 2, usable = true, original_gold = 28,
                pay_gold = 28, discount_type = 0, discount = 0, discount_batch_gold = 0},
            {batch_limit = 0, amount = 4, usable = true, original_gold = 82,
                pay_gold = 82, discount_type = 0, discount = 0, discount_batch_gold = 0},
        },
    }
    local scope = {kind = "batch", batch_limit = zero and 0 or 2,
        start_ord = 2.5, offer_index = zero and 3 or 2, order = 1}
    return {info = info, range = Value.copy(info), detail = detail, calls = {},
        selection = assert(Selection.normalize(scope, coin()))}
end
local function row(f, id)
    for _, raw in ipairs(f.detail.extra.ep_list) do if raw.id == id then return raw end end
    error("The synthetic row is absent")
end
local function episode(f, id)
    for _, value in ipairs(f.detail.episodes) do if value.id == tostring(id) then return value end end
    error("The synthetic normalized episode is absent")
end
local function resolve(f)
    return Range.resolve{info = f.info, range_info = f.range, raw_detail = f.detail,
        episode_id = f.episode_id or "103", comic_id = f.comic_id or "1", selection = f.selection}
end
local function context(f, proof)
    return {episode_id = f.episode_id or "103", comic_id = f.comic_id or "1", selection = Value.copy(f.selection),
        range_info = Value.copy(f.range), original_values = {11, 89, 82, 28, 82},
        range_proof = Value.copy(proof)}
end
local function build(f, ctx)
    return Quote.build{info = f.info, episodes = f.detail.episodes, raw_detail = f.detail,
        episode_id = f.episode_id or "103", scope = f.selection.scope, payment = f.selection.payment,
        context = ctx, id = "synthetic-ordinal-quote", account_key = "synthetic-account",
        now = 100, max_age = 120}
end
local function fakeClient(f)
    local function record(method, args)
        report.fake_calls = report.fake_calls + 1
        f.calls[#f.calls + 1] = {method = method, args = Value.copy(args)}
    end
    return {
        purchaseInfo = function(_, id, scope)
            record("purchaseInfo", {id = id, scope = scope})
            return Value.copy(scope and f.range or f.info)
        end,
        comicDetail = function(_, id)
            record("comicDetail", {id = id})
            return Value.copy(f.detail)
        end,
        buyEpisode = function()
            report.buy_episode_calls = report.buy_episode_calls + 1
            error("BuyEpisode is forbidden even on the fake client", 0)
        end,
    }
end
local function fetch(f)
    return Fetch.run(fakeClient(f), {episode_id = f.episode_id or "103", comic_id = f.comic_id or "1",
        scope = f.selection.scope, payment = f.selection.payment})
end
local function mutateBoth(f, fn)
    fn(f.info)
    fn(f.range)
end

test("positive ranges include the fractional anchor and skip interleaved owned chapters", function()
    local f = fixture()
    local before = Value.encode(f)
    local proof = assert(resolve(f))
    same(proof.episode_ids, {"103", "105"})
    same(proof.scope, f.selection.scope)
    check(proof.amount == 28 and proof.scope.batch_limit == 2)
    check(proof.contract == "bilibili_pc_ordinal_range_v1")
    check(proof.provenance == "primary_sdk_ordinal_contract_and_quote_catalog_consistency")
    check(type(proof.basis_digest) == "string" and #proof.basis_digest > 0)
    check(type(proof.server_offer) == "table")
    check(Value.encode(f) == before, "Resolution must not mutate its input evidence")
    same(assert(resolve(f)), proof, "Identical evidence must produce a repeatable proof")
    proof.episode_ids[1] = "changed"
    check(assert(resolve(f)).episode_ids[1] == "103", "Proof arrays must not alias source state")
end)

test("explicit zero offers resolve the inclusive remaining tail and retain zero on the wire", function()
    local f = fixture(true)
    local proof = assert(resolve(f))
    same(proof.episode_ids, {"103", "105", "107", "108"})
    check(proof.amount == 82 and proof.scope.batch_limit == 0 and proof.scope.offer_index == 3)
    check(#proof.episode_ids == f.info.after_lock_ep_num and #proof.episode_ids ~= f.info.remain_lock_ep_num)
    local quote = assert(build(f, context(f, proof)))
    check(quote.submittable == true and quote.amount == 82)
    same(quote.episode_ids, proof.episode_ids)
    same(quote.payload, {buy_method = 3, comic_id = "1", with_ord_scope = true,
        start_ord = 2.5, limit = 0, pay_amount = 82})
    check(quote.payload.ep_id == nil and quote.payload.coupon_id == nil
        and quote.payload.free_gold_card_id == nil and quote.payload.auto_pay_gold_status == nil)
end)

test("the fake collector retains original offer positions and builds a matching range proof", function()
    for _, zero in ipairs({false, true}) do
        local f = fixture(zero)
        local collected = assert(fetch(f))
        same(collected.info.batch_buy, f.info.batch_buy)
        same(collected.context.original_values, {11, 89, 82, 28, 82})
        same(collected.context.range_proof, assert(resolve(f)))
        local scoped, basic, catalogs = 0, 0, 0
        for _, call in ipairs(f.calls) do
            if call.method == "purchaseInfo" and call.args.scope then
                scoped = scoped + 1
                check(call.args.scope.batch_limit == f.selection.scope.batch_limit)
                check(call.args.scope.order == 1 and call.args.scope.buy_type == 2)
                check(call.args.scope.offer_index == nil)
            elseif call.method == "purchaseInfo" then basic = basic + 1
            elseif call.method == "comicDetail" then catalogs = catalogs + 1
            else error("Unexpected fake collector method") end
        end
        check(scoped >= 1 and basic >= 1 and catalogs >= 1)
        local quote = assert(Quote.build{info = collected.info, episodes = collected.detail.episodes,
            raw_detail = collected.detail, episode_id = "103", scope = f.selection.scope,
            payment = f.selection.payment, context = collected.context,
            id = "synthetic-collected-quote", account_key = "synthetic-account", now = 100, max_age = 120})
        check(quote.submittable == true)
        same(quote.episode_ids, zero and {"103", "105", "107", "108"} or {"103", "105"})
    end
end)

test("strict catalog evidence rejects unknown, temporary, malformed, and unavailable states", function()
    local cases = {
        {"uppercase false lock flag", function(f) row(f, 108).is_locked = "FALSE" end},
        {"numeric lock flag", function(f) row(f, 108).is_locked = 1 end},
        {"missing lock flag", function(f) row(f, 108).is_locked = nil end},
        {"uppercase free flag", function(f) row(f, 108).is_in_free = "FALSE" end},
        {"missing free flag", function(f) row(f, 108).is_in_free = nil end},
        {"temporary free flag", function(f) row(f, 108).is_in_free = true end},
        {"temporary unlock type", function(f) row(f, 108).unlock_type = 2 end},
        {"unavailable pay mode", function(f) row(f, 108).pay_mode = 2 end},
        {"string pay mode", function(f) row(f, 108).pay_mode = "1" end},
        {"missing unlock type", function(f) row(f, 108).unlock_type = nil end},
        {"contradictory locked ownership", function(f) row(f, 108).unlock_type = 1 end},
        {"ambiguous unlocked paid access", function(f) row(f, 104).unlock_type = 0 end},
        {"nonzero expiry", function(f) row(f, 108).unlock_expire_at = 123 end},
        {"dated expiry", function(f) row(f, 108).unlock_expire_at = "2027-01-01 00:00:00" end},
        {"partial zero date", function(f) row(f, 108).unlock_expire_at = "0000-00-00" end},
        {"nonnumeric raw price", function(f) row(f, 108).pay_gold = "31" end},
        {"negative raw price", function(f) row(f, 108).pay_gold = -1 end},
        {"infinite raw price", function(f) row(f, 108).pay_gold = math.huge end},
        {"duplicate identity", function(f) row(f, 108).id = 107 end},
        {"duplicate ordinal", function(f) row(f, 108).ord = 5 end},
        {"infinite ordinal", function(f) row(f, 108).ord = math.huge end},
        {"missing ordinal", function(f) row(f, 108).ord = nil end},
        {"out of order original catalog", function(f)
            local rows = f.detail.extra.ep_list; rows[1], rows[2] = rows[2], rows[1]
        end},
        {"catalog array hole", function(f) f.detail.extra.ep_list[4] = nil end},
        {"catalog object key", function(f) f.detail.extra.ep_list.unexpected = {} end},
        {"missing original catalog", function(f) f.detail.extra.ep_list = nil end},
        {"raw comic identity mismatch", function(f) f.detail.extra.id = 2 end},
        {"normalized comic identity mismatch", function(f) f.detail.comic.id = "2" end},
        {"anchor is permanently owned", function(f)
            row(f, 103).is_locked, row(f, 103).unlock_type = false, 1
        end},
        {"anchor ordinal changed", function(f) f.selection.scope.start_ord = 2 end},
    }
    for _, item in ipairs(cases) do
        local f = fixture()
        item[2](f)
        local proof, err = resolve(f)
        denied(proof, err)
        report.rejection_cases[#report.rejection_cases + 1] = item[1]
    end
end)

test("only explicitly supported absent-expiry representations are accepted", function()
    for _, form in ipairs({"missing", "empty", "zero", "zero-date"}) do
        local f = fixture()
        for _, raw in ipairs(f.detail.extra.ep_list) do
            if form == "missing" then raw.unlock_expire_at = nil
            elseif form == "empty" then raw.unlock_expire_at = ""
            elseif form == "zero" then raw.unlock_expire_at = 0
            else raw.unlock_expire_at = "0000-00-00 00:00:00" end
        end
        same(assert(resolve(f)).episode_ids, {"103", "105"})
    end
end)

test("offer and quote aggregates cannot manufacture a payable range", function()
    local cases = {
        {"selected offer unusable", function(f) mutateBoth(f, function(i) i.batch_buy[2].usable = false end) end},
        {"truthy numeric usability", function(f) mutateBoth(f, function(i) i.batch_buy[2].usable = 1 end) end},
        {"positive amount differs from limit", function(f) mutateBoth(f, function(i) i.batch_buy[2].amount = 3 end) end},
        {"selected price mismatch", function(f) mutateBoth(f, function(i) i.batch_buy[2].pay_gold = 27 end) end},
        {"equal prices disagree with catalog", function(f) mutateBoth(f, function(i)
            i.batch_buy[2].original_gold, i.batch_buy[2].pay_gold = 29, 29
        end) end},
        {"missing selected original price", function(f) mutateBoth(f, function(i) i.batch_buy[2].original_gold = nil end) end},
        {"missing whole aggregate", function(f) mutateBoth(f, function(i) i.remain_lock_ep_num = nil end) end},
        {"incorrect whole amount", function(f) mutateBoth(f, function(i) i.original_gold = 82 end) end},
        {"incorrect whole price aggregate", function(f) mutateBoth(f, function(i) i.remain_lock_ep_gold = 82 end) end},
        {"incorrect tail count", function(f) mutateBoth(f, function(i) i.after_lock_ep_num = 3 end) end},
        {"incorrect tail price", function(f) mutateBoth(f, function(i) i.after_lock_ep_gold = 81 end) end},
        {"anchor original amount mismatch", function(f) mutateBoth(f, function(i) i.ep_original_gold = 12 end) end},
        {"anchor displayed amount mismatch", function(f) mutateBoth(f, function(i) i.pay_gold = 12 end) end},
        {"range selected amount changed", function(f) f.range.batch_buy[2].amount = 3 end},
        {"range whole aggregate changed", function(f) f.range.remain_lock_ep_gold = 90 end},
        {"range anchor identity mismatch", function(f) f.range.ep_id = 999 end},
        {"range comic identity mismatch", function(f) f.range.comic_id = 2 end},
        {"offer array hole", function(f) f.info.batch_buy[1] = nil end},
        {"offer array object key", function(f) f.info.batch_buy.unexpected = {} end},
        {"selected original position mismatch", function(f) f.selection.scope.offer_index = 1 end},
        {"unsupported extra asset", function(f)
            f.selection.payment.discount = {kind = "activity", id = "synthetic-activity"}
        end},
    }
    for _, item in ipairs(cases) do
        local f = fixture()
        item[2](f)
        local proof, err = resolve(f)
        denied(proof, err)
        report.rejection_cases[#report.rejection_cases + 1] = item[1]
    end
    local zero = fixture(true)
    mutateBoth(zero, function(i) i.batch_buy[3].amount = i.remain_lock_ep_num end)
    denied(resolve(zero))
    zero = fixture(true)
    mutateBoth(zero, function(i)
        i.batch_buy[3].original_gold, i.batch_buy[3].pay_gold = i.original_gold, i.original_gold
    end)
    denied(resolve(zero))
end)

test("unusable shortened positive offers never convert into a zero selection", function()
    local f = fixture()
    f.selection.scope.batch_limit, f.selection.scope.offer_index = 20, 1
    denied(resolve(f))
    local collected, err = fetch(f)
    if collected then
        check(collected.context.range_proof == nil)
        notSubmittable(build(f, collected.context))
    else denied(collected, err) end
    check(f.selection.scope.batch_limit == 20 and f.selection.scope.offer_index == 1)
    local direct_zero = fixture(true)
    check(assert(resolve(direct_zero)).scope.batch_limit == 0)
end)

test("legacy exact-scope booleans cannot replace a recomputable proof", function()
    local f = fixture()
    local offer = f.info.batch_buy[2]
    offer.exact_scope_verified, offer.episode_ids = true, {"103", "105"}
    offer.start_ord, offer.final_pay_amount = 2.5, 28
    f.range = Value.copy(f.info)
    local ctx = context(f)
    ctx.exact_scope_verified = true
    local quote = assert(build(f, ctx))
    notSubmittable(quote)
    ctx.range_proof = true
    notSubmittable(build(f, ctx))
end)

test("Quote independently checks every supplied proof against the current evidence", function()
    local mutations = {
        {"digest", function(p) p.basis_digest = p.basis_digest .. "changed" end},
        {"member identity", function(p) p.episode_ids[2] = "108" end},
        {"member order", function(p) p.episode_ids[1], p.episode_ids[2] = p.episode_ids[2], p.episode_ids[1] end},
        {"scope limit", function(p) p.scope.batch_limit = 0 end},
        {"scope anchor", function(p) p.scope.start_ord = 3 end},
        {"offer position", function(p) p.scope.offer_index = 3 end},
        {"amount", function(p) p.amount = 1 end},
        {"contract", function(p) p.contract = "invented_contract" end},
        {"provenance", function(p) p.provenance = "server_confirmed_episode_ids" end},
        {"server offer", function(p) p.server_offer.pay_gold = 1 end},
    }
    for _, item in ipairs(mutations) do
        local f = fixture()
        local proof = assert(resolve(f))
        item[2](proof)
        notSubmittable(build(f, context(f, proof)))
    end
    local f = fixture()
    local proof = assert(resolve(f))
    row(f, 108).unlock_expire_at = 1000
    notSubmittable(build(f, context(f, proof)))
    f = fixture()
    proof = assert(resolve(f))
    local ctx = context(f, proof)
    ctx.range_info.after_lock_ep_num = 99
    notSubmittable(build(f, ctx))
    f = fixture()
    proof = assert(resolve(f))
    episode(f, 105).access = "owned"
    notSubmittable(build(f, context(f, proof)))
end)

test("equal price and count do not hide a changed intended identity from the fingerprint", function()
    local first = fixture()
    local first_proof = assert(resolve(first))
    local first_quote = assert(build(first, context(first, first_proof)))
    check(first_quote.submittable == true and type(first_quote.fingerprint) == "string")
    local changed = fixture()
    row(changed, 105).id = 205
    local changed_episode = episode(changed, 105)
    changed_episode.id, changed_episode.extra.id = "205", 205
    local changed_proof = assert(resolve(changed))
    local changed_quote = assert(build(changed, context(changed, changed_proof)))
    check(changed_proof.amount == first_proof.amount and #changed_proof.episode_ids == #first_proof.episode_ids)
    same(changed_proof.episode_ids, {"103", "205"})
    check(changed_proof.basis_digest ~= first_proof.basis_digest)
    check(changed_quote.fingerprint ~= first_quote.fingerprint)
    notSubmittable(build(changed, context(changed, first_proof)))
    local copied = Value.copy(first_quote)
    check(Quote.fingerprint(copied) == first_quote.fingerprint)
end)

test("changes in required whole-catalog evidence invalidate the prior basis", function()
    local first = fixture()
    local proof = assert(resolve(first))
    local quote = assert(build(first, context(first, proof)))
    local changed = fixture()
    row(changed, 101).pay_gold = 8
    episode(changed, 101).pay_gold, episode(changed, 101).extra.pay_gold = 8, 8
    mutateBoth(changed, function(i) i.original_gold, i.remain_lock_ep_gold = 90, 90 end)
    local new_proof = assert(resolve(changed))
    same(new_proof.episode_ids, proof.episode_ids)
    check(new_proof.amount == proof.amount and new_proof.basis_digest ~= proof.basis_digest)
    local new_quote = assert(build(changed, context(changed, new_proof)))
    check(new_quote.fingerprint ~= quote.fingerprint)
    notSubmittable(build(changed, context(changed, proof)))
end)

test("raw discount fields must agree and participate in refreshed semantic fingerprints", function()
    local mismatched = fixture()
    mismatched.range.ep_discount = 1
    denied(resolve(mismatched))

    local first = fixture()
    local first_proof = assert(resolve(first))
    local first_quote = assert(build(first, context(first, first_proof)))
    local changed = fixture()
    mutateBoth(changed, function(i) i.ep_discount = 1 end)
    local changed_proof = assert(resolve(changed))
    local changed_quote = assert(build(changed, context(changed, changed_proof)))
    same(changed_proof.episode_ids, first_proof.episode_ids)
    check(changed_proof.amount == first_proof.amount)
    check(changed_proof.basis_digest ~= first_proof.basis_digest)
    check(changed_quote.fingerprint ~= first_quote.fingerprint)
end)

test("identical remaining members do not merge positive, zero, or other comic contracts", function()
    local zero = fixture(true)
    mutateBoth(zero, function(i)
        i.batch_buy[2].batch_limit, i.batch_buy[2].amount = 4, 4
        i.batch_buy[2].original_gold, i.batch_buy[2].pay_gold = 82, 82
    end)
    local zero_proof = assert(resolve(zero))
    local zero_quote = assert(build(zero, context(zero, zero_proof)))
    local positive = Value.copy(zero)
    positive.selection.scope.batch_limit, positive.selection.scope.offer_index = 4, 2
    local positive_proof = assert(resolve(positive))
    local positive_quote = assert(build(positive, context(positive, positive_proof)))
    same(positive_proof.episode_ids, zero_proof.episode_ids)
    check(positive_proof.amount == zero_proof.amount)
    check(positive_proof.basis_digest ~= zero_proof.basis_digest)
    check(positive_quote.payload.limit == 4 and zero_quote.payload.limit == 0)
    check(positive_quote.fingerprint ~= zero_quote.fingerprint)
    notSubmittable(build(positive, context(positive, zero_proof)))

    local other = Value.copy(zero)
    other.comic_id, other.info.comic_id, other.range.comic_id = "2", 2, 2
    other.detail.comic.id, other.detail.extra.id = "2", 2
    for _, current in ipairs(other.detail.episodes) do current.comic_id = "2" end
    local other_proof = assert(resolve(other))
    same(other_proof.episode_ids, zero_proof.episode_ids)
    check(other_proof.amount == zero_proof.amount and other_proof.basis_digest ~= zero_proof.basis_digest)
    local other_quote = assert(build(other, context(other, other_proof)))
    check(other_quote.payload.comic_id == "2" and other_quote.fingerprint ~= zero_quote.fingerprint)
    notSubmittable(build(other, context(other, zero_proof)))
end)

test("single coin and reading-coupon construction retain their separate contracts", function()
    local f = fixture()
    f.selection = assert(Selection.normalize(nil, coin()))
    local quote = assert(build(f, context(f)))
    check(quote.submittable == true and quote.amount == 11)
    same(quote.payload, {buy_method = 3, ep_id = "103", pay_amount = 11})
    f.selection = assert(Selection.normalize(nil, {method = "coupon", coupon_ids = {"synthetic-coupon-a"}}))
    quote = assert(build(f, context(f)))
    check(quote.submittable == true and quote.amount == 1)
    same(quote.payload, {buy_method = 2, ep_id = "103", coupon_ids = {"synthetic-coupon-a"}})
    f = fixture()
    local described = assert(Candidate.describe(f.info, episode(f, 103), f.selection, context(f)))
    check(#described.batch_offers == 3 and described.batch_offers[1].available == false)
    check(described.batch_offers[2].offer_index == 2 and described.batch_offers[2].price_vector_index == 4)
    check(described.batch_offers[3].scope.batch_limit == 0)
end)

test("no real account, transport, or purchase operation was accessed", function()
    check(report.forbidden_module_attempts == 0 and report.buy_episode_calls == 0)
    for name in pairs(forbidden) do check(package.loaded[name] == nil) end
end)

report.passed = true
for _, group in ipairs(report.groups) do if not group.passed then report.passed = false end end
local file = assert(io.open(output, "wb"))
file:write(json.encode(report))
file:close()
os.exit(report.passed and 0 or 1)
