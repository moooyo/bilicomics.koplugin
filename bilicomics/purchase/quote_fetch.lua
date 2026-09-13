-- Worker-side read collection; this module never submits or authorizes a purchase.
local Selection = require("bilicomics/purchase/selection")
local Value = require("bilicomics/purchase/value")
local Range = require("bilicomics/purchase/range")
local Fetch = {}

local function call(client, method, ...)
    if not client or type(client[method]) ~= "function" then
        return nil, Value.error("capability", "The selected quote information is unavailable.")
    end
    local ok, value, err = pcall(client[method], client, ...)
    if not ok then return nil, Value.error("protocol", "The quote information could not be retrieved.") end
    return value, err
end

local function dense(values)
    if type(values) ~= "table" or #values > 512 then return false end
    local count = 0
    for key in pairs(values) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #values then return false end
        count = count + 1
    end
    return count == #values
end

local function rawOffer(info, scope, episode)
    if scope.kind ~= "batch" then return nil end
    local offers = info.batch_buy or {}
    if not dense(offers) then return nil, Value.error("invalid_quote", "The batch offer list is malformed.") end
    if scope.start_ord ~= nil and tonumber(episode.order) ~= scope.start_ord then
        return nil, Value.error("selection_changed", "The selected chapter order changed. Choose the range again.")
    end
    local found
    for index, offer in ipairs(offers) do
        if type(offer) == "table" and (scope.offer_index == nil or scope.offer_index == index)
            and tonumber(offer.batch_limit) == scope.batch_limit and (offer.usable == true or offer.usable == 1) then
            if found then return nil, Value.error("selection_changed", "Choose an unambiguous original batch offer.") end
            found = offer
        end
    end
    if not found then return nil, Value.error("selection_changed", "The selected batch offer is no longer available.") end
    return found
end

local function originalValues(info)
    local episode, season = Value.amount(info.ep_original_gold), Value.amount(info.original_gold)
    local offers = info.batch_buy or {}
    if episode == nil or season == nil or not dense(offers) then return nil end
    local values = { episode, season }
    -- Keep every original position, including currently unusable offers.
    for _, offer in ipairs(offers) do
        local amount = type(offer) == "table" and Value.amount(offer.original_gold) or nil
        if amount == nil then return nil end
        values[#values + 1] = amount
    end
    return values
end

function Fetch.run(client, request)
    local selection, err = Selection.normalize(request.scope, request.payment)
    if not selection then return nil, err end
    local episode_id, comic_id = Value.id(request.episode_id), Value.id(request.comic_id)
    if not episode_id then return nil, Value.error("invalid_quote", "A quote needs an episode identity.") end
    local info
    info, err = call(client, "purchaseInfo", episode_id)
    if not info then return nil, err end
    if type(info) ~= "table" or info.ep_id and Value.id(info.ep_id) ~= episode_id
        or comic_id and info.comic_id and Value.id(info.comic_id) ~= comic_id then
        return nil, Value.error("invalid_quote", "The purchase information refers to a different chapter.")
    end
    comic_id = comic_id or Value.id(info.comic_id)
    if not comic_id then return nil, Value.error("access_unknown", "The comic identity is required for this quote.") end
    local detail
    detail, err = call(client, "comicDetail", comic_id)
    if not detail then return nil, err end
    if type(detail) ~= "table" or type(detail.comic) ~= "table" or Value.id(detail.comic.id) ~= comic_id then
        return nil, Value.error("invalid_quote", "The refreshed catalog belongs to another comic.")
    end
    local current
    for _, episode in ipairs(detail.episodes or {}) do
        if Value.id(episode.id) == episode_id then
            if current or Value.id(episode.comic_id) ~= comic_id then
                return nil, Value.error("invalid_quote", "The refreshed episode identity is ambiguous.")
            end
            current = episode
        end
    end
    if not current then return nil, Value.error("access_unknown", "The selected chapter is absent from the refreshed catalog.") end
    local offer, offer_error = rawOffer(info, selection.scope, current)
    if offer_error then return nil, offer_error end
    local wire_scope = assert(Selection.requestScope(selection.scope))
    local range
    range, err = call(client, "purchaseInfo", episode_id, wire_scope)
    if not range then return nil, err end
    if type(range) ~= "table" or range.ep_id and Value.id(range.ep_id) ~= episode_id
        or range.comic_id and Value.id(range.comic_id) ~= comic_id then
        return nil, Value.error("invalid_quote", "The range information refers to another chapter.")
    end
    local context = { episode_id = episode_id, comic_id = comic_id,
        selection = Value.copy(selection), range_info = range,
        original_values = originalValues(info) }
    local discount = selection.payment.discount or { kind = "none" }
    if selection.scope.kind == "batch" and selection.payment.method == "coin" and discount.kind == "none" then
        local proof, range_error = Range.resolve({info = info, range_info = range, raw_detail = detail,
            episode_id = episode_id, comic_id = comic_id, selection = selection})
        context.range_proof = proof
        if range_error then context.range_error = {kind = range_error.kind, code = range_error.code} end
    end
    if discount.kind == "discount_card" and context.original_values then
        context.calculated_prices, err = call(client, "discountPrice", discount.id, context.original_values)
        if not context.calculated_prices then return nil, err end
    elseif discount.kind == "free_gold_card" then
        -- The inspected batch path supplies offer.amount, not the offer's range limit.
        -- No single/full fallback count is inferred from SDK constructor defaults.
        local count = offer and tonumber(offer.amount)
        if count and count > 0 and count <= 2147483647 and count % 1 == 0 then
            context.free_gold_card_info, err = call(client, "freeGoldCardInfo", comic_id, episode_id,
                { buy_type = 2, batch_limit = count })
            if not context.free_gold_card_info then return nil, err end
        end
    end
    return { info = info, detail = detail, context = context }
end

return Fetch
