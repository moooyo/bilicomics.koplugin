local root = assert(arg[1], "Pass the plugin root")
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local Client = require("bilicomics/protocol/client")
local Service = require("bilicomics/purchase/service")
local Value = require("bilicomics/purchase/value")
local JSON = require("bilicomics/protocol/json")

local passed = 0
local function run(name, payment, scope, info_patch, response, expected)
    local episodes = {
        {id = "10", comic_id = "1", order = 1, access = "locked"},
        {id = "11", comic_id = "1", order = 1.5, access = "locked"},
    }
    local store = {account_key = "boundary-fixture", purchases = {}, settings = {}}
    function store:getEpisode() return Value.copy(episodes[1]) end
    function store:listEpisodes() return Value.copy(episodes) end
    function store:getSetting(key, default)
        if self.settings[key] == nil then return default end
        return Value.copy(self.settings[key])
    end
    function store:putSetting(key, value) self.settings[key] = Value.copy(value) end
    function store:transaction(fn)
        local purchases, settings = Value.copy(self.purchases), Value.copy(self.settings)
        local ok, result = pcall(fn)
        if not ok then self.purchases, self.settings = purchases, settings; error(result, 0) end
        return result
    end
    function store:getPurchase(id) return Value.copy(self.purchases[id]) end
    function store:putPurchase(value) self.purchases[value.id] = Value.copy(value) end
    function store:listPurchases() local output = {}; for _, value in pairs(self.purchases) do output[#output + 1] = Value.copy(value) end; return output end
    local requests, body = 0, nil
    local expected_body = { ep_id = 10, buy_method = payment == "coupon" and 2 or 3 }
    if payment == "coupon" then
        expected_body.coupon_ids = {"501"}
    else
        local amount = info_patch and info_patch.ep_original_gold or 30
        if amount > 0 then expected_body.pay_amount = amount end
    end
    local transport = {request = function(_, request)
        requests = requests + 1
        if BILI_NONSPENDING_EVIDENCE then
            BILI_NONSPENDING_EVIDENCE.fake_buy_route_calls = BILI_NONSPENDING_EVIDENCE.fake_buy_route_calls + 1
        end
        assert(request.method == "POST" and request.output_path == nil
            and request.url == "https://manga.bilibili.com/twirp/comic.v1.Comic/BuyEpisode?device=pc&platform=web&nov=27&a=810")
        assert(request.headers.cookie == "SESSDATA=synthetic-session" and requests == 1)
        body = assert(JSON.decode(request.body))
        for key in pairs(body) do
            assert(key == "ep_id" or key == "buy_method" or key == "pay_amount" or key == "coupon_ids")
        end
        assert(body.ep_id == 10 and (body.buy_method == 2 or body.buy_method == 3))
        assert(body.auto_pay_gold_status == nil and body.auto_pay_coupons_status == nil)
        assert(Value.encode(body) == Value.encode(expected_body), "The planned single-episode wire body changed")
        return response
    end}
    local client = Client.new({session = {cookies = {SESSDATA = "synthetic-session"}}, transport = transport, crypto = {}})
    local sequence = 0
    local service = Service.new({store = store, client = client, clock = function() return 1000 end,
        id_factory = function(kind) sequence = sequence + 1; return kind .. sequence end})
    local info = {ep_id = "10", comic_id = "1", ep_original_gold = 30, pay_gold = 30, remain_gold = 100,
        allow_coupon = true, ep_pay_coupons = 1, remain_coupon = 1, recommend_coupon_ids = {"501"},
        batch_buy = {{batch_limit = 2, amount = 2, usable = true, exact_scope_verified = true,
            start_ord = 1, final_pay_amount = 54, episode_ids = {"10", "11"}}}}
    for key, value in pairs(info_patch or {}) do info[key] = value end
    local q = assert(service:buildQuote("10", scope, payment, info, {episodes = episodes}))
    local fresh = assert(service:buildQuote("10", scope, payment, info, {episodes = episodes}))
    local intent, payload = service:prepareSubmission(q, {confirmed = true}, fresh)
    if expected == "advisory" then
        assert(q.submittable == false and q.payload == nil and q.fingerprint == nil)
        assert(intent == nil and payload.kind == "quote_unverified" and requests == 0)
        assert(#store:listPurchases() == 0)
        passed = passed + 1
        print("PASS " .. name)
        return nil, q
    end
    assert(intent, payload and payload.kind)
    local value, err = client:buyEpisode(payload)
    intent = assert(service:completeSubmission(intent.id, value, err))
    assert(requests == 1, "The memory-only transport must receive exactly one planned request")
    assert(intent.state == expected, "Unexpected transaction state: " .. intent.state)
    assert(not Value.encode(store.purchases):find("synthetic%-session"), "Credentials entered the journal")
    passed = passed + 1
    print("PASS " .. name)
    return body, intent
end

local success = {status = 200, body = '{"code":0,"data":{}}', transmitted = true}
local body = run("coin quote passes through the production client", "coin", nil, nil, success, "accepted")
assert(body.ep_id == 10 and body.pay_amount == 30 and body.buy_method == 3)
body = run("coupon quote passes without pay_amount", "coupon", nil, nil, success, "accepted")
assert(body.buy_method == 2 and body.pay_amount == nil and tostring(body.coupon_ids[1]) == "501")
body = run("quoted zero coin amount preserves official omission", "coin", nil, {ep_original_gold = 0, pay_gold = 0}, success, "accepted")
assert(body.pay_amount == nil)
run("batch metadata cannot reach even the fake BuyEpisode route", "coin",
    {kind = "batch", batch_limit = 2, start_ord = 1}, nil, success, "advisory")
for code = 1, 5 do
    run("known purchase rejection " .. code, "coin", nil, nil,
        {status = 200, body = '{"code":' .. code .. ',"data":{}}', transmitted = true}, "rejected")
end
run("unknown business result retains unresolved intent", "coin", nil, nil,
    {status = 200, body = '{"code":99,"data":{}}', transmitted = true}, "outcome_unknown")
run("malformed response retains unresolved intent", "coin", nil, nil,
    {status = 200, body = '{"code":', transmitted = true}, "outcome_unknown")
run("HTTP failure retains unresolved intent", "coin", nil, nil,
    {status = 500, body = "failure", transmitted = true}, "outcome_unknown")
print("Purchase production-client boundary: " .. passed .. " cases passed using a memory-only transport; no real HTTP or charges.")
