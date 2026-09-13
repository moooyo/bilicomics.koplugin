local Value = require("bilicomics/purchase/value")

local Selection = {}
local MAX_INTEGER = 2147483647
local MAX_ID_BYTES = 256
local MAX_COUPON_IDS = 1024
local MAX_SAFE_NUMBER_ID = 9007199254740991

local function reject(kind, message)
    return nil, Value.error(kind, message)
end

local function containsUnknown(value, allowed)
    for key in pairs(value) do
        if type(key) ~= "string" or not allowed[key] then return true end
    end
    return false
end

local function finiteNumber(value)
    if type(value) ~= "number" and type(value) ~= "string" then return nil end
    if type(value) == "string" and #value > 64 then return nil end
    local number = tonumber(value)
    if not number or number ~= number or math.abs(number) == math.huge then return nil end
    return number
end

local function boundedInteger(value, minimum)
    local number = finiteNumber(value)
    if not number or number < minimum or number > MAX_INTEGER or number % 1 ~= 0 then return nil end
    return number
end

local function assetID(value)
    local kind = type(value)
    if kind == "number" then
        if value ~= value or value < 0 or value > MAX_SAFE_NUMBER_ID or value % 1 ~= 0 then return nil end
        value = string.format("%.0f", value)
    elseif kind ~= "string" then
        return nil
    end
    if #value == 0 or #value > MAX_ID_BYTES or value:find("[%c]") then return nil end
    return value
end

local function couponIDs(values)
    if type(values) ~= "table" then return nil end
    local length = #values
    if length < 1 or length > MAX_COUPON_IDS then return nil end
    local key_count = 0
    for key in pairs(values) do
        if type(key) ~= "number" or key < 1 or key > length or key % 1 ~= 0 then return nil end
        key_count = key_count + 1
    end
    if key_count ~= length then return nil end
    local result, seen = {}, {}
    for index = 1, length do
        local id = assetID(values[index])
        if not id or seen[id] then return nil end
        result[index], seen[id] = id, true
    end
    return result
end

local function normalizeScope(scope)
    if scope == nil then scope = {} end
    if type(scope) == "string" then scope = {kind = scope} end
    if type(scope) ~= "table" then return reject("invalid_scope", "Select a supported purchase scope.") end
    if containsUnknown(scope, {kind = true, batch_limit = true, start_ord = true, order = true, offer_index = true}) then
        return reject("invalid_scope", "The purchase scope contains an unsupported field.")
    end
    local kind = scope.kind
    if kind == nil then kind = "single" end
    if kind ~= "single" and kind ~= "batch" then return reject("invalid_scope", "Only single and batch selections are supported.") end
    local order = scope.order == nil and 1 or finiteNumber(scope.order)
    if order ~= 1 and order ~= 2 then return reject("invalid_scope", "Select a supported discount sort order.") end
    local result = {kind = kind, order = order}
    if kind == "single" then
        if scope.batch_limit ~= nil or scope.start_ord ~= nil or scope.offer_index ~= nil then
            return reject("invalid_scope", "A single-episode selection cannot contain batch range fields.")
        end
        return result
    end
    local limit = boundedInteger(scope.batch_limit, 0)
    if limit == nil then return reject("invalid_scope", "Select a nonnegative bounded batch limit.") end
    result.batch_limit = limit
    if scope.start_ord ~= nil then
        local start = finiteNumber(scope.start_ord)
        if start == nil then return reject("invalid_scope", "The anchor episode ordinal must be finite.") end
        result.start_ord = start
    end
    if scope.offer_index ~= nil then
        local index = boundedInteger(scope.offer_index, 1)
        if index == nil then return reject("invalid_scope", "The original offer index must be a positive bounded integer.") end
        result.offer_index = index
    end
    return result
end

local function normalizePayment(payment)
    if payment == nil then payment = {} end
    if type(payment) == "string" then payment = {method = payment} end
    if type(payment) ~= "table" then return reject("invalid_payment", "Select coin or reading-coupon payment.") end
    if containsUnknown(payment, {method = true, coupon_ids = true, discount = true}) then
        return reject("invalid_payment", "Payment selection cannot supply prices, eligibility, or additional asset amounts.")
    end
    local method = payment.method
    if method == nil then method = "coin" end
    if method ~= "coin" and method ~= "coupon" then return reject("invalid_payment", "Select coin or reading-coupon payment.") end
    local result = {method = method}
    if method == "coupon" then
        if payment.discount ~= nil then return reject("invalid_payment", "Reading coupons cannot carry a coin-discount selection.") end
        if payment.coupon_ids ~= nil then
            result.coupon_ids = couponIDs(payment.coupon_ids)
            if not result.coupon_ids then return reject("invalid_payment", "Reading-coupon IDs must be a nonempty bounded array of distinct IDs.") end
        end
        return result
    end
    if payment.coupon_ids ~= nil then return reject("invalid_payment", "Coin payment cannot select reading coupons.") end
    local discount = payment.discount
    if discount == nil then discount = {kind = "none"} end
    if type(discount) ~= "table" or containsUnknown(discount, {kind = true, id = true}) then
        return reject("invalid_payment", "A discount selection may contain only its kind and identity.")
    end
    local kind = discount.kind
    if kind ~= "none" and kind ~= "discount_card" and kind ~= "activity" and kind ~= "free_gold_card" then
        return reject("invalid_payment", "The selected discount kind is unsupported.")
    end
    if kind == "none" and discount.id ~= nil then
        return reject("invalid_payment", "A no-discount selection must not contain an asset identity.")
    end
    local normalized = {kind = kind}
    if discount.id ~= nil then
        normalized.id = assetID(discount.id)
        if not normalized.id then return reject("invalid_payment", "The selected discount identity is invalid.") end
    elseif kind ~= "none" then
        return reject("invalid_payment", "An explicit identity is required for the selected discount.")
    end
    result.discount = normalized
    return result
end

-- This validates user selection only. It neither creates a quote nor establishes
-- asset eligibility, prices, server scope, or permission to submit a purchase.
function Selection.normalize(scope, payment)
    local normalized_scope, err = normalizeScope(scope)
    if not normalized_scope then return nil, err end
    local normalized_payment
    normalized_payment, err = normalizePayment(payment)
    if not normalized_payment then return nil, err end
    if normalized_scope.kind == "batch" and normalized_payment.method ~= "coin" then
        return reject("invalid_payment", "Batch reading-coupon payment is unsupported.")
    end
    return {scope = normalized_scope, payment = normalized_payment}
end

-- The original offer index belongs to local price association, not the wire
-- request. A zero batch limit is a read-only query and never submission proof.
function Selection.requestScope(scope)
    local normalized, err = normalizeScope(scope)
    if not normalized then return nil, err end
    return {
        kind = normalized.kind,
        buy_type = normalized.kind == "batch" and 2 or 1,
        batch_limit = normalized.batch_limit,
        start_ord = normalized.start_ord,
        order = normalized.order,
    }
end

return Selection
