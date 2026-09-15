local Errors = require("bilicomics/protocol/errors")
local JSON = require("bilicomics/protocol/json")

local Recharge = {}
local MAX_INTEGER = 9007199254740991
-- Bound cash arithmetic independently of the server's advertised denominations.
local MAX_AMOUNT_CENTS = 2147483647
local IDENTIFIERS = { id = true, order_id = true, orderId = true }

local function invalid(message)
    return nil, Errors.new("invalid_recharge_amount", message, { transmitted = false, definitive = true })
end

local function protocol(message)
    return nil, Errors.new("protocol", message)
end

local function integer(value, minimum, maximum)
    if type(value) ~= "number" or value ~= value or value % 1 ~= 0
        or value < (minimum or 0) or value > (maximum or MAX_INTEGER) then return nil end
    return value
end

local function text(value, maximum)
    if type(value) ~= "string" or #value > (maximum or 512) or value:find("[%z\1-\8\11\12\14-\31\127]") then return nil end
    return value
end

local function array(value, maximum)
    if type(value) ~= "table" or #value > maximum then return nil end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then return nil end
        count = count + 1
    end
    return count == #value and value or nil
end

function Recharge.orderID(value)
    if type(value) == "number" then
        if not integer(value, 1) then return nil end
        value = string.format("%.0f", value)
    end
    if type(value) ~= "string" or #value > 128 or not value:match("^[1-9]%d*$") then return nil end
    return value
end

-- Quote identifier number tokens before RapidJSON sees them. A regular-expression
-- replacement could also match text inside pay_params or an escaped object key.
function Recharge.decodeEnvelope(source)
    if type(source) ~= "string" or #source > 262144 then return protocol("The recharge response exceeds the supported size.") end
    local output, stack, pending, offset = {}, {}, nil, 1
    while offset <= #source do
        local character = source:sub(offset, offset)
        if character == '"' then
            local start = offset
            offset = offset + 1
            local complete = false
            while offset <= #source do
                local current = source:sub(offset, offset)
                if current == "\\" then offset = offset + 2
                elseif current == '"' then offset = offset + 1; complete = true; break
                else offset = offset + 1 end
            end
            if not complete then return protocol("The recharge response contains an unfinished string.") end
            local literal = source:sub(start, offset - 1)
            output[#output + 1] = literal
            local next_offset = offset
            while source:sub(next_offset, next_offset):match("%s") do next_offset = next_offset + 1 end
            if source:sub(next_offset, next_offset) == ":" then
                local decoded = JSON.decode('{"key":' .. literal .. '}')
                if not decoded or type(decoded.key) ~= "string" then return protocol("The recharge response has an invalid object key.") end
                pending = decoded.key
                local object = stack[#stack]
                if IDENTIFIERS[pending] and object and object.kind == "object" then
                    if object.seen[pending] then return protocol("The recharge response repeats an order identifier.") end
                    object.seen[pending] = true
                end
            else pending = nil end
        elseif character == "{" or character == "[" then
            if #stack >= 32 then return protocol("The recharge response is nested too deeply.") end
            stack[#stack + 1] = { kind = character == "{" and "object" or "array", seen = {} }
            pending = nil; output[#output + 1] = character; offset = offset + 1
        elseif character == "}" or character == "]" then
            stack[#stack] = nil
            pending = nil; output[#output + 1] = character; offset = offset + 1
        elseif character:match("[%d%-]") then
            local start = offset
            repeat offset = offset + 1 until offset > #source or not source:sub(offset, offset):match("[%d%.eE%+%-]")
            local literal = source:sub(start, offset - 1)
            if IDENTIFIERS[pending] then
                if not Recharge.orderID(literal) then return protocol("An order identifier is not an exact positive decimal integer.") end
                output[#output + 1] = '"' .. literal .. '"'
            else output[#output + 1] = literal end
            pending = nil
        else
            output[#output + 1] = character
            if character ~= ":" and not character:match("%s") then pending = nil end
            offset = offset + 1
        end
    end
    return JSON.decode(table.concat(output))
end

function Recharge.formatAmount(amount_cents)
    if not integer(amount_cents, 0, MAX_AMOUNT_CENTS) then return nil end
    return string.format("%.0f.%02d", math.floor(amount_cents / 100), amount_cents % 100)
end

local function yuanToCents(value)
    if type(value) == "number" then
        if value ~= value or value <= 0 or value > MAX_AMOUNT_CENTS / 100 then return nil end
        local decimal = string.format("%.2f", value)
        if tonumber(decimal) ~= value then return nil end
        return yuanToCents(decimal)
    end
    if type(value) ~= "string" or #value > 32 then return nil end
    value = value:match("^%s*(.-)%s*$")
    local whole, fraction = value:match("^(%d+)%.(%d+)$")
    if not whole then whole, fraction = value:match("^(%d+)$"), "" end
    if not whole or #fraction > 2 then return nil end
    whole = whole:gsub("^0+", "")
    if whole == "" then whole = "0" end
    if #whole > 14 then return nil end
    local units = tonumber(whole)
    if not units or units > math.floor(MAX_AMOUNT_CENTS / 100) then return nil end
    local amount = units * 100 + tonumber(fraction .. string.rep("0", 2 - #fraction))
    return integer(amount, 1, MAX_AMOUNT_CENTS)
end

function Recharge.validateAmount(amount_cents, config)
    if not integer(amount_cents, 1, MAX_AMOUNT_CENTS) then return invalid("Enter a supported positive amount in whole cents.") end
    if type(config) ~= "table" or config.source ~= "official_pay_config" or not array(config.options, 128) then
        return invalid("Load the official recharge options before choosing an amount.")
    end
    for _index, option in ipairs(config.options) do
        if option.amount_cents == amount_cents then return amount_cents, option end
    end
    return invalid("Choose an amount offered by the current official recharge configuration.")
end

function Recharge.parseAmount(value, config)
    local amount = yuanToCents(value)
    if not amount then return invalid("Enter a decimal amount with no more than two fractional digits.") end
    return Recharge.validateAmount(amount, config)
end

function Recharge.optionFingerprint(option, config)
    if type(option) ~= "table" or type(config) ~= "table" then return nil end
    local basis = { "official_manga_recharge_option_v1" }
    local function fields(source, names)
        for _index, name in ipairs(names) do
            local value = source[name]
            basis[#basis + 1] = JSON.array({ name, type(value), value == nil and "" or value })
        end
    end
    fields(option, { "amount_cents", "coin_amount", "first_bonus_gold", "first_bonus_coupons",
        "activity_bonus_coupons", "activity_bonus_gold", "break_ice_coupons", "coupon_bundle_amount",
        "deduction_card_amount", "first_text", "activity_text" })
    fields(config, { "notice", "bonus_reason", "first_bonus_type", "activity_bonus_type" })
    local encoded = JSON.encode(JSON.array(basis))
    if not encoded then return nil end
    return require("ffi/sha2").sha256(encoded)
end

function Recharge.normalizeConfig(data, now)
    local ranges = type(data) == "table" and array(data.pay_amount_ranges, 128)
    if not ranges then return protocol("The service returned no complete recharge-option list.") end
    local options, seen = {}, {}
    for _index, item in ipairs(ranges) do
        if type(item) ~= "table" then return protocol("A recharge option is invalid.") end
        local amount, coins = yuanToCents(item.pay_amount), integer(item.gold_amount, 0)
        if not amount or coins == nil or seen[amount] then return protocol("The recharge amount or coin quantity is invalid or ambiguous.") end
        seen[amount] = true
        local option = { amount_cents = amount, amount_yuan = Recharge.formatAmount(amount), coin_amount = coins }
        local bonuses = {
            first_bonus_amount = "first_bonus_gold", first_coupon_amount = "first_bonus_coupons",
            bonus_coupon_amount = "activity_bonus_coupons", bonus_gold_amount = "activity_bonus_gold",
            break_ice_coupon_amount = "break_ice_coupons", gold_set_amount = "coupon_bundle_amount",
            free_gold_set_amount = "deduction_card_amount",
        }
        for raw, normalized in pairs(bonuses) do
            if item[raw] ~= nil then
                local bonus = integer(item[raw], 0)
                if bonus == nil then return protocol("A recharge benefit has an invalid quantity.") end
                option[normalized] = bonus
            end
        end
        option.first_text, option.activity_text = text(item.first_txt), text(item.activity_txt)
        if item.first_txt ~= nil and not option.first_text or item.activity_txt ~= nil and not option.activity_text then
            return protocol("The recharge option contains invalid benefit text.")
        end
        options[#options + 1] = option
    end
    local config = {
        schema_version = 1, source = "official_pay_config", options = options,
        custom_amount = { allowed = false, reason = "not_advertised" },
        channels = { "wechat", "alipay" }, channel_selection = "scan_app",
        notice = text(data.show_text, 2048), bonus_reason = text(data.bonus_reason),
        first_bonus_type = integer(data.first_pay_send_type, 0),
        activity_bonus_type = integer(data.act_send_type, 0), fetched_at = now,
    }
    if data.show_text ~= nil and not config.notice or data.bonus_reason ~= nil and not config.bonus_reason
        or data.first_pay_send_type ~= nil and config.first_bonus_type == nil
        or data.act_send_type ~= nil and config.activity_bonus_type == nil then
        return protocol("The recharge configuration contains invalid benefit terms.")
    end
    local fingerprints = {}
    for _index, option in ipairs(options) do
        option.fingerprint = Recharge.optionFingerprint(option, config)
        if not option.fingerprint then return protocol("The recharge option could not be fingerprinted.") end
        fingerprints[#fingerprints + 1] = option.fingerprint
    end
    config.fingerprint = require("ffi/sha2").sha256(assert(JSON.encode(JSON.array(fingerprints))))
    return config
end

local function trustedCodeURL(value)
    if not text(value, 8192) or value:find("[%s\\]") then return nil end
    local host = value:match("^https://([%w%.%-]+)/")
    if not host or host:lower() ~= "pay.bilibili.com" then return nil end
    return value
end

local function uncertain(message, order_id)
    return nil, Errors.new("recharge_order_unknown", message, {
        transmitted = true, definitive = false, order_id = order_id,
    })
end

function Recharge.normalizeOrder(data, amount_cents, now)
    if type(data) ~= "table" or type(data.pay_params) ~= "string" or #data.pay_params > 32768 then
        return uncertain("The recharge response has no usable payment parameters. Check the recharge history before creating another order.")
    end
    local parameters = Recharge.decodeEnvelope(data.pay_params)
    if not parameters then return uncertain("The recharge payment parameters could not be read exactly.") end
    local order_id = Recharge.orderID(parameters.orderId)
    if not order_id then return uncertain("The recharge response has no exact order identifier.") end
    local code_url = trustedCodeURL(parameters.codeUrl)
    if not code_url then return uncertain("The recharge response has no trusted official HTTPS payment code.", order_id) end
    return { order_id = order_id, code_url = code_url, qr_validated = true, amount_cents = amount_cents,
        amount_source = "submitted_request", observed_at = now, channels = { "wechat", "alipay" } }
end

function Recharge.historyOptions(opts, now)
    opts = opts or {}
    if type(opts) ~= "table" then return protocol("Recharge history options must be an object.") end
    local allowed = { page_num = true, page_size = true, order_year = true, order_month = true }
    for key in pairs(opts) do if not allowed[key] then return protocol("The recharge history request contains an unsupported field.") end end
    local current_year = tonumber(os.date("!%Y", now or os.time()))
    local result = { page_num = opts.page_num == nil and 1 or opts.page_num,
        page_size = opts.page_size == nil and 20 or opts.page_size,
        order_year = opts.order_year == nil and current_year or opts.order_year,
        order_month = opts.order_month == nil and 0 or opts.order_month }
    if not integer(result.page_num, 1, 100000) or not integer(result.page_size, 1, 100)
        or not integer(result.order_year, 1970, 9999) or not integer(result.order_month, 0, 12) then
        return protocol("The recharge history page or date is invalid.")
    end
    return result
end

function Recharge.normalizeHistory(data, options)
    if not array(data, 100) then return protocol("The recharge history response is not an order list.") end
    local records, seen = {}, {}
    for _index, item in ipairs(data) do
        local order_id = type(item) == "table" and Recharge.orderID(item.id)
        if not order_id or seen[order_id] then return protocol("The recharge history contains an invalid or repeated order identifier.") end
        seen[order_id] = true
        local record = { order_id = order_id, created_at = text(item.ctime, 128),
            pay_channel = text(item.pay_channel, 64), pay_channel_name = text(item.pay_channel_name, 128),
            activity = text(item.activity, 512) }
        for raw, normalized in pairs({ product_amount = "product_amount", extra_product_amount = "extra_product_amount",
            free_gold = "deduction_card_amount" }) do
            if item[raw] ~= nil then
                local amount = integer(item[raw], 0)
                if amount == nil then return protocol("A recharge-history benefit has an invalid quantity.") end
                record[normalized] = amount
            end
        end
        if item.pay_amount ~= nil then
            if type(item.pay_amount) ~= "number" or item.pay_amount ~= item.pay_amount
                or item.pay_amount < 0 or item.pay_amount > MAX_INTEGER then return protocol("A recharge-history payment amount is invalid.") end
            -- Its wire unit is not established by the observed history model.
            record.raw_pay_amount = item.pay_amount
        end
        records[#records + 1] = record
    end
    return { records = records, page_num = options.page_num, page_size = options.page_size,
        order_year = options.order_year, order_month = options.order_month }
end

function Recharge.getConfig(client)
    local data, err = client:_post("pay.v1.Pay", "GetPayConfig", {}, { auth = true })
    if not data then return nil, err end
    return Recharge.normalizeConfig(data, client.clock())
end

function Recharge.createOrder(client, amount_cents, expected_option_fingerprint)
    if not integer(amount_cents, 1, MAX_AMOUNT_CENTS) then return invalid("Enter a supported positive amount in whole cents.") end
    if expected_option_fingerprint ~= nil and (type(expected_option_fingerprint) ~= "string"
        or #expected_option_fingerprint ~= 64 or expected_option_fingerprint:find("[^0-9a-f]")) then
        return invalid("The confirmed recharge option has an invalid fingerprint.")
    end
    local config, err = Recharge.getConfig(client)
    if not config then
        local failure = Errors.new(err and err.kind or "protocol", err and err.message or "The recharge options could not be loaded.", err)
        failure.transmitted, failure.definitive, failure.phase = false, true, "recharge_config"
        return nil, failure
    end
    local amount, option = Recharge.validateAmount(amount_cents, config)
    if not amount or expected_option_fingerprint and option.fingerprint ~= expected_option_fingerprint then
        return nil, Errors.new("recharge_config_changed", "The recharge option changed. Review the new terms and confirm again.", {
            transmitted = false, definitive = true, config = config,
        })
    end
    local data
    data, err = client:_post("pay.v1.Pay", "CreateOrder", { pay_type = "qr", pay_amount = amount_cents }, { auth = true })
    if not data then
        if err and err.transmitted == false then
            local failure = Errors.new(err.kind, err.message, err)
            failure.transmitted, failure.definitive, failure.phase = false, true, "recharge_create"
            return nil, failure
        end
        return uncertain("The recharge order result is unknown. Check its history before creating another order.")
    end
    return Recharge.normalizeOrder(data, amount_cents, client.clock())
end

function Recharge.history(client, opts)
    local options, err = Recharge.historyOptions(opts, client.clock())
    if not options then err.transmitted = false; return nil, err end
    local data
    data, err = client:_post("user.v1.User", "GetPayOrders", options, { auth = true })
    if not data then return nil, err end
    return Recharge.normalizeHistory(data, options)
end

return Recharge
