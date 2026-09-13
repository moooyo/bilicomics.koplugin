-- Replay captured read responses through pure quote construction without sending requests.
local source, captures, output = assert(arg[1]), assert(arg[2]), assert(arg[3])
require("setupkoenv")
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
for _, name in ipairs({ "bilicomics/protocol/client", "bilicomics/protocol/transport", "bilicomics/jobs/worker",
    "bilicomics/purchase/service", "socket.http", "ssl" }) do
    package.preload[name] = function() error("Network and submission modules are forbidden in this replay") end
end
local JSON = require("bilicomics/protocol/json")
local Fetch = require("bilicomics/purchase/quote_fetch")
local Quote = require("bilicomics/purchase/quote")
local function read(name)
    local file = assert(io.open(captures .. "/" .. name, "rb"))
    local text = file:read(8 * 1024 * 1024 + 1); file:close()
    assert(text and #text <= 8 * 1024 * 1024)
    return assert(JSON.decode(text))
end
local function copy(value) return assert(JSON.decode(assert(JSON.encode(value)))) end
local selected = read("selection-private.json")
local detail = read("catalog-normalized-private.json")
local basic, single = read("basic-normalized-private.json"), read("single-normalized-private.json")
local batch_positive, batch_remaining = read("batch-1-normalized-private.json"), read("batch-2-normalized-private.json")
local checks, calls = {}, 0
local function check(name, value)
    checks[#checks + 1] = { name = name, passed = not not value }
    assert(value, name)
end
local client = {}
function client:purchaseInfo(episode_id, scope)
    calls = calls + 1
    assert(tostring(episode_id) == tostring(selected.episode_id))
    if not scope then return copy(basic) end
    assert(scope.order == 1)
    if scope.buy_type == 1 then assert(scope.batch_limit == nil); return copy(single) end
    assert(scope.buy_type == 2)
    return copy(scope.batch_limit == 0 and batch_remaining or batch_positive)
end
function client:comicDetail(comic_id)
    calls = calls + 1
    assert(tostring(comic_id) == tostring(selected.comic_id))
    return copy(detail)
end
function client:buyEpisode() error("Submission is forbidden in captured-response replay") end
local function build(scope, payment, label)
    local collected, fetch_error = Fetch.run(client, { episode_id = tostring(selected.episode_id),
        comic_id = tostring(selected.comic_id), scope = scope, payment = payment })
    check(label .. " captured reads are accepted", collected ~= nil and fetch_error == nil)
    check(label .. " does not invent exact-scope proof", collected.context.exact_scope_verified == nil)
    local vector = collected.context.original_values
    check(label .. " price vector preserves every offer", type(vector) == "table" and #vector == 2 + #basic.batch_buy)
    check(label .. " vector keeps episode and season positions", vector[1] == basic.ep_original_gold and vector[2] == basic.original_gold)
    for index, offer in ipairs(basic.batch_buy) do
        check(label .. " original offer position " .. index, vector[index + 2] == offer.original_gold)
    end
    return Quote.build{ info = collected.info, episodes = collected.detail.episodes, context = collected.context,
        episode_id = tostring(selected.episode_id), account_key = "captured-account", scope = scope, payment = payment,
        id = "captured-" .. label, now = 1, max_age = 60 }
end
local function main()
    local coin, coin_error = build({ kind = "single", order = 1 }, { method = "coin" }, "single coin")
    check("single coin has no adapter error", coin ~= nil and coin_error == nil)
    check("single coin is a confirmable quote", coin.submittable == true and type(coin.fingerprint) == "string")
    check("single quote preserves the one requested chapter", #coin.episode_ids == 1 and coin.episode_ids[1] == tostring(selected.episode_id))
    check("single amount uses the equal present server amounts", coin.amount == basic.ep_original_gold and coin.amount == basic.pay_gold)
    check("usable balance is preserved", coin.balance == basic.remain_gold)
    check("affordability matches the captured response", coin.can_afford == (basic.remain_gold >= coin.amount))
    check("single construction uses only the intended currency method", coin.payload.buy_method == 3 and coin.payload.ep_id == tostring(selected.episode_id))
    local coupon, coupon_error = build({ kind = "single", order = 1 }, { method = "coupon" }, "single coupon")
    if basic.allow_coupon ~= true and basic.allow_coupon ~= 1 then
        check("ineligible coupon payment is refused", coupon == nil and coupon_error and coupon_error.kind == "ineligible_coupon")
    elseif type(basic.recommend_coupon_ids) == "table" and #basic.recommend_coupon_ids == basic.ep_pay_coupons and #basic.recommend_coupon_ids > 0 then
        check("eligible recommended coupon IDs form the quote", coupon ~= nil and coupon_error == nil and coupon.submittable == true)
    else
        check("missing eligible coupon identities are refused", coupon == nil and coupon_error ~= nil)
    end
    for index, offer in ipairs(basic.batch_buy) do
        if (offer.usable == true or offer.usable == 1) and (index == 1 or offer.batch_limit == 0) then
            local value, err = build({ kind = "batch", batch_limit = offer.batch_limit, offer_index = index, order = 1 },
                { method = "coin" }, offer.batch_limit == 0 and "remaining batch" or "positive batch")
            check("observed batch offer is retained as advisory", value ~= nil and err == nil and value.submittable == false)
            check("unproved batch exposes no submission payload", value.payload == nil and value.fingerprint == nil and value.episode_ids == nil)
        end
    end
end
local ok, failure = pcall(main)
local report = { passed = ok, checks = checks, captured_client_calls = calls, captured_response_replay = true,
    network_modules_blocked = true, actual_purchase_executed = false, real_payment_verified = false,
    scope = "Pure Fetch/Quote construction with private captured read responses; no Client, transport, worker or submission service execution" }
local file = assert(io.open(output, "wb")); file:write(assert(JSON.encode(report))); file:close()
print(JSON.encode({ passed = ok, checks = #checks, captured_client_calls = calls }))
if not ok then error(type(failure) == "string" and failure or "Captured quote replay failed") end
