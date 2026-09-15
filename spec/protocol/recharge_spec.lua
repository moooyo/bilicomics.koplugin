-- Exercise recharge parsing and request boundaries with synthetic transport only.
require("setupkoenv")
local root, output = assert(arg[1]), assert(arg[2])
package.path = root .. "/?.lua;" .. package.path

local Client = require("bilicomics/protocol/client")
local Errors = require("bilicomics/protocol/errors")
local JSON = require("bilicomics/protocol/json")
local Recharge = require("bilicomics/protocol/recharge")
local Session = require("bilicomics/protocol/session")
local report = { scope = "Synthetic recharge protocol; no real account, order, or payment", assertions = {},
    synthetic_only = true, actual_order_created = false, actual_payment_executed = false }

local function test(name, operation)
    local ok, error = pcall(operation)
    report.assertions[#report.assertions + 1] = { name = name, passed = ok, error = not ok and tostring(error) or nil }
    assert(ok, name .. ": " .. tostring(error))
end

local function configuration()
    return { pay_amount_ranges = {
        { pay_amount = 6, gold_amount = 600, first_bonus_amount = 12, first_coupon_amount = 2,
            bonus_coupon_amount = 1, bonus_gold_amount = 3, break_ice_coupon_amount = 0,
            first_txt = "Synthetic first reward", activity_txt = "Synthetic event", gold_set_amount = 0, free_gold_set_amount = 0 },
        { pay_amount = 6.5, gold_amount = 650 },
        { pay_amount = 25, gold_amount = 2500 },
    }, show_text = "Synthetic recharge terms", first_pay_send_type = 2, act_send_type = 1, bonus_reason = "Synthetic bonus" }
end

local function response(data)
    return { status = 200, transmitted = true, headers = {}, body = assert(JSON.encode({ code = 0, data = data })) }
end

local function fixture(responses)
    local transport = { responses = responses or {}, requests = {} }
    function transport:request(request)
        assert(request.url:match("^https://manga%.bilibili%.com/twirp/"), "Unexpected synthetic destination")
        self.requests[#self.requests + 1] = request
        local item = assert(table.remove(self.responses, 1), "No synthetic response is available")
        if item.failure then return nil, item.failure end
        return item
    end
    local session = assert(Session.parse("SESSDATA=synthetic-recharge-session; DedeUserID=42"))
    return Client.new{ transport = transport, session = session, clock = function() return 1800000000 end }, transport
end

local function payResponse(url, order_id)
    return response({ pay_params = '{"orderId":' .. (order_id or "18446744073709551615")
        .. ',"codeUrl":' .. assert(JSON.encode(url or "https://pay.bilibili.com/pay-v2/cashier/qrpay?payToken=SYNTHETIC_ONLY")) .. '}' })
end

local ok, failure = xpcall(function()
    test("official configuration preserves currency units and benefit semantics", function()
        local config = assert(Recharge.normalizeConfig(configuration(), 1800000000))
        assert(config.options[1].amount_cents == 600 and config.options[1].amount_yuan == "6.00")
        assert(config.options[1].coin_amount == 600 and config.options[1].first_bonus_gold == 12)
        assert(config.options[2].amount_cents == 650 and config.options[2].coin_amount == 650)
        assert(config.custom_amount.allowed == false and config.custom_amount.reason == "not_advertised")
        assert(config.channels[1] == "wechat" and config.channels[2] == "alipay")
        assert(#config.options[1].fingerprint == 64 and #config.fingerprint == 64)
    end)

    test("manual yuan input is exact and limited to authoritative options", function()
        local config = assert(Recharge.normalizeConfig(configuration(), 1800000000))
        assert(Recharge.parseAmount(" 6.00 ", config) == 600)
        assert(Recharge.parseAmount("6.5", config) == 650)
        assert(Recharge.parseAmount("25", config) == 2500)
        for _index, value in ipairs({ "", "0", "-6", "+6", "6e0", "6,00", "6.001", "6.01", "99999999999999999999" }) do
            local amount, err = Recharge.parseAmount(value, config)
            assert(amount == nil and err.kind == "invalid_recharge_amount" and err.transmitted == false)
        end
        assert(not Recharge.validateAmount(600.5, config))
    end)

    test("malformed and ambiguous configuration is rejected", function()
        local data = configuration(); data.pay_amount_ranges[2].pay_amount = 6
        assert(not Recharge.normalizeConfig(data, 1))
        data = configuration(); data.pay_amount_ranges[1].pay_amount = 6.001
        assert(not Recharge.normalizeConfig(data, 1))
        data = configuration(); data.pay_amount_ranges[1].gold_amount = -1
        assert(not Recharge.normalizeConfig(data, 1))
        assert(not Recharge.normalizeConfig({ pay_amount_ranges = { untrusted = true } }, 1))
        assert(Recharge.normalizeConfig({ pay_amount_ranges = {} }, 1).custom_amount.allowed == false)
    end)

    test("option fingerprints bind benefits and text without binding retrieval time", function()
        local before = assert(Recharge.normalizeConfig(configuration(), 1))
        local later = assert(Recharge.normalizeConfig(configuration(), 2))
        assert(before.options[1].fingerprint == later.options[1].fingerprint)
        local data = configuration(); data.pay_amount_ranges[1].bonus_gold_amount = 4
        assert(before.options[1].fingerprint ~= Recharge.normalizeConfig(data, 1).options[1].fingerprint)
        data = configuration(); data.show_text = "Changed terms"
        assert(before.options[1].fingerprint ~= Recharge.normalizeConfig(data, 1).options[1].fingerprint)
    end)

    test("raw decimal identifiers survive JSON without touching strings or amounts", function()
        local envelope = assert(Recharge.decodeEnvelope('{"code":0,"data":[{"id":18446744073709551615,"pay_amount":600,"activity":"text id: 999"}]}'))
        assert(envelope.code == 0 and envelope.data[1].id == "18446744073709551615")
        assert(envelope.data[1].pay_amount == 600 and envelope.data[1].activity == "text id: 999")
        assert(not Recharge.decodeEnvelope('{"orderId":1,"order\\u0049d":2}'))
        assert(not Recharge.decodeEnvelope('{"id":1e20}'))
        assert(not Recharge.orderID(9007199254740992))
    end)

    test("both payment apps use one official QR order with an exact large identifier", function()
        local config = assert(Recharge.normalizeConfig(configuration(), 1))
        local client, transport = fixture({ response(configuration()), payResponse() })
        local order = assert(client:createRechargeOrder(600, config.options[1].fingerprint))
        assert(order.order_id == "18446744073709551615" and order.qr_validated == true)
        assert(order.amount_cents == 600 and order.amount_source == "submitted_request" and order.expires_at == nil)
        assert(#transport.requests == 2)
        assert(transport.requests[1].url:find("/twirp/pay.v1.Pay/GetPayConfig?", 1, true))
        assert(transport.requests[1].body == "{}")
        assert(transport.requests[2].url:find("/twirp/pay.v1.Pay/CreateOrder?", 1, true))
        local body = assert(JSON.decode(transport.requests[2].body))
        assert(body.pay_type == "qr" and body.pay_amount == 600)
        assert(body.channel == nil and body.pay_channel == nil and body.product_id == nil)
    end)

    test("changed terms or removed amounts stop before creating an order", function()
        local config = assert(Recharge.normalizeConfig(configuration(), 1))
        local data = configuration(); data.pay_amount_ranges[1].gold_amount = 599
        local client, transport = fixture({ response(data) })
        local value, err = client:createRechargeOrder(600, config.options[1].fingerprint)
        assert(value == nil and err.kind == "recharge_config_changed" and err.transmitted == false and err.definitive == true)
        assert(#transport.requests == 1)
        client, transport = fixture({ response(configuration()) })
        value, err = client:createRechargeOrder(601)
        assert(value == nil and err.kind == "recharge_config_changed" and #transport.requests == 1)
    end)

    test("order creation never retries uncertain transport results", function()
        local client, transport = fixture({ response(configuration()), { failure = Errors.new("timeout", "Synthetic loss", { transmitted = true }) } })
        local value, err = client:createRechargeOrder(600)
        assert(value == nil and err.kind == "recharge_order_unknown" and err.transmitted == true and err.definitive == false)
        assert(#transport.requests == 2)
        client, transport = fixture({ { failure = Errors.new("timeout", "Synthetic config loss", { transmitted = true }) } })
        value, err = client:createRechargeOrder(600)
        assert(value == nil and err.transmitted == false and err.phase == "recharge_config" and #transport.requests == 1)
        client, transport = fixture({ response(configuration()),
            { failure = Errors.new("network", "Synthetic TLS failure", { transmitted = false }) } })
        value, err = client:createRechargeOrder(600)
        assert(value == nil and err.transmitted == false and err.definitive == true
            and err.phase == "recharge_create" and #transport.requests == 2)
    end)

    test("untrusted QR URLs retain the order ID but do not expose a payment code", function()
        for _index, url in ipairs({ "http://pay.bilibili.com/a", "https://pay.bilibili.com.evil.invalid/a",
            "https://pay.bilibili.com@evil.invalid/a", "https://pay.bilibili.com:444/a", "weixin://wxpay/example",
            "https://manga.bilibili.com/a", "https://pay.bilibili.com/evil\\path" }) do
            local raw = payResponse(url)
            local data = assert(JSON.decode(raw.body)).data
            local value, err = Recharge.normalizeOrder(data, 600, 1)
            assert(value == nil and err.kind == "recharge_order_unknown" and err.order_id == "18446744073709551615")
        end
    end)

    test("a received QR receipt survives optional cookie persistence errors", function()
        local client, transport = fixture({ response(configuration()), payResponse() })
        local captures = 0
        function client:_captureCookies()
            captures = captures + 1
            if captures == 2 then return nil, Errors.new("session", "Synthetic cookie error") end
            return true
        end
        assert(client:createRechargeOrder(600).qr_validated and #transport.requests == 2)
    end)

    test("history preserves exact IDs and does not invent currency units or status", function()
        local raw = '{"code":0,"data":[{"id":18446744073709551615,"pay_amount":600,"product_amount":600,"ctime":"2026-09-15 10:00:00","pay_channel":"alipay","pay_channel_name":"Alipay","free_gold":12}]}'
        local client, transport = fixture({ { status = 200, headers = {}, transmitted = true, body = raw } })
        local history = assert(client:rechargeHistory({ page_num = 1, page_size = 2, order_year = 2026, order_month = 9 }))
        assert(history.records[1].order_id == "18446744073709551615")
        assert(history.records[1].raw_pay_amount == 600 and history.records[1].amount_cents == nil and history.records[1].status == nil)
        assert(history.records[1].product_amount == 600 and history.records[1].deduction_card_amount == 12)
        local body = assert(JSON.decode(transport.requests[1].body))
        assert(body.page_num == 1 and body.page_size == 2 and body.order_year == 2026 and body.order_month == 9)
        assert(not client:rechargeHistory({ order_id = "123" }))
        assert(#transport.requests == 1)
    end)

    test("malformed history identifiers and list wrappers are rejected", function()
        local options = assert(Recharge.historyOptions({}, 1800000000))
        assert(options.order_year ~= 2019)
        assert(not Recharge.normalizeHistory({ { id = "1" }, { id = "1" } }, options))
        assert(not Recharge.normalizeHistory({ { id = 9007199254740992 } }, options))
        assert(not Recharge.normalizeHistory({ list = {} }, options))
    end)
end, debug.traceback)

report.passed, report.error, report.count = ok, not ok and tostring(failure) or nil, #report.assertions
local file = assert(io.open(output .. "/recharge-result.json", "wb"))
file:write(assert(JSON.encode(report))); file:close()
print(assert(JSON.encode(report)))
if not ok then os.exit(1) end
