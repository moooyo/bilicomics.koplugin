local Selection = require("bilicomics/purchase/selection")
local Value = require("bilicomics/purchase/value")

local Candidate = {}
local MAX_OFFERS = 512
local MAX_DISCOUNTS = 512
local MAX_PRICE_KEYS = 1024
local MAX_INTEGER = 2147483647
local MAX_SAFE_INTEGER = 9007199254740991

local function reject(kind, message)
    return nil, Value.error(kind, message)
end

local function number(value)
    if type(value) ~= "number" and type(value) ~= "string" then return nil end
    if type(value) == "string" and #value > 64 then return nil end
    local result = tonumber(value)
    if not result or result ~= result or math.abs(result) == math.huge then return nil end
    return result
end

local function amount(value)
    local result = number(value)
    if not result or result < 0 then return nil end
    return result
end

local function integer(value, minimum)
    local result = number(value)
    if not result or result < minimum or result > MAX_INTEGER or result % 1 ~= 0 then return nil end
    return result
end

local function explicitBoolean(value)
    if value == true or value == 1 then return true end
    if value == false or value == 0 then return false end
    return nil
end

local function denseArray(value, maximum)
    if type(value) ~= "table" then return nil end
    local length, count = #value, 0
    if length > maximum then return nil end
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > length or key % 1 ~= 0 then return nil end
        count = count + 1
        if count > maximum then return nil end
    end
    if count ~= length then return nil end
    return length
end

local function expiry(value)
    if type(value) == "string" then
        if #value > 0 and #value <= 128 and not value:find("[%c]") then return value end
    elseif type(value) == "number" then
        return number(value)
    end
    return nil
end

local function sameSelection(selection, context, current)
    if type(context) ~= "table" or type(context.selection) ~= "table" then return false end
    if context.episode_id == nil or context.comic_id == nil
        or tostring(context.episode_id) ~= tostring(current.id)
        or tostring(context.comic_id) ~= tostring(current.comic_id) then return false end
    local matched = Selection.normalize(context.selection.scope, context.selection.payment)
    return matched ~= nil and Value.encode(matched) == Value.encode(selection)
end

local function addBlocker(metadata, blocker)
    for _, existing in ipairs(metadata.blockers) do if existing == blocker then return end end
    metadata.blockers[#metadata.blockers + 1] = blocker
end

local function describeOffers(info, current, selection)
    local raw = info.batch_buy
    if raw == nil then raw = {} end
    local length = denseArray(raw, MAX_OFFERS)
    if length == nil then return reject("invalid_quote", "The batch offers must be a bounded complete array.") end
    local result = {}
    local start = number(current.order)
    for index = 1, length do
        local offer = raw[index]
        if type(offer) ~= "table" then return reject("invalid_quote", "A batch offer has an invalid shape.") end
        local limit = integer(offer.batch_limit, 0)
        local count = integer(offer.amount, 0)
        local usable = explicitBoolean(offer.usable)
        local range_complete = limit ~= nil and start ~= nil
        result[index] = {
            scope = {kind = "batch", offer_index = index, batch_limit = limit,
                start_ord = start, order = selection.scope.order},
            offer_index = index,
            price_vector_index = index + 2,
            amount = count,
            original_amount = amount(offer.original_gold),
            display_amount = amount(offer.pay_gold),
            available = usable == true and range_complete and count ~= nil and count >= 1,
            is_usable = usable,
            range_complete = range_complete,
        }
    end
    return result
end

local function selectOffer(offers, current, selection)
    local scope = selection.scope
    if scope.kind ~= "batch" then return nil end
    local start = number(current.order)
    if start == nil or (scope.start_ord ~= nil and scope.start_ord ~= start) then
        return reject("selection_changed", "The anchor episode ordinal changed or is unavailable.")
    end
    if scope.offer_index ~= nil then
        local offer = offers[scope.offer_index]
        if not offer or offer.scope.batch_limit ~= scope.batch_limit or not offer.range_complete then
            return reject("selection_changed", "The selected original batch offer changed or disappeared.")
        end
        return offer
    end
    local selected
    for _, offer in ipairs(offers) do
        if offer.scope.batch_limit == scope.batch_limit and offer.range_complete then
            if selected then return reject("selection_changed", "The batch limit matches more than one original offer.") end
            selected = offer
        end
    end
    if not selected then return reject("selection_changed", "The selected batch offer is no longer present.") end
    return selected
end

local function discountIdentity(kind, raw_id)
    local selection = Selection.normalize(nil, {method = "coin", discount = {kind = kind, id = raw_id}})
    return selection and selection.payment.discount.id or nil
end

local function snapshot(kind, id, item, discount_type)
    local result = {
        kind = kind, id = id, discount_type = discount_type,
        is_usable = explicitBoolean(item.is_usable),
        expire_time = expiry(item.expire_time),
    }
    if kind == "discount_card" then
        result.amount = amount(item.amount)
        result.discount = amount(item.discount)
        result.discount_limit = amount(item.discount_limit)
    elseif kind == "activity" then
        result.discount = amount(item.discount)
        result.saved_gold = amount(item.saved_gold)
    elseif kind == "free_gold_card" then
        -- total and expired_total are not the scoped credit to be consumed.
        result.prime_gold_count = amount(item.prime_gold_count)
    end
    return result
end

local function describeDiscounts(context, context_matches)
    local options = {{kind = "none", payment = {method = "coin", discount = {kind = "none"}}, available = true}}
    local snapshots = {}
    if not context_matches or type(context.range_info) ~= "table" then return options, snapshots, false end
    local raw = context.range_info.optional_discount_list
    if raw == nil then return options, snapshots, false end
    local length = denseArray(raw, MAX_DISCOUNTS)
    if length == nil then return reject("invalid_quote", "The scoped discount options must be a bounded complete array.") end
    local banned = type(context.free_gold_card_info) == "table"
        and explicitBoolean(context.free_gold_card_info.is_ban) == true
    local seen = {}
    for index = 1, length do
        local option = raw[index]
        if type(option) ~= "table" then return reject("invalid_quote", "A scoped discount option has an invalid shape.") end
        local discount_type = number(option.discount_type)
        local kind, item, raw_id
        if discount_type == 0 then
            kind, item = "activity", option.discount_act_info
        elseif discount_type == 1 then
            kind, item = "discount_card", option.discount_info
        elseif discount_type == 2 then
            kind, item = "free_gold_card", option.free_gold_card
        end
        -- The implicit none option has no asset. Unknown types are not offered.
        if kind and type(item) == "table" then
            if kind == "free_gold_card" then raw_id = item.card_id else raw_id = item.id end
            local id = discountIdentity(kind, raw_id)
            if id then
                local key = kind .. ":" .. id
                if seen[key] then return reject("selection_changed", "The scoped response contains duplicate discount identities.") end
                seen[key] = true
                local asset = snapshot(kind, id, item, discount_type)
                local available = asset.is_usable == true
                if kind == "free_gold_card" and banned then available = false end
                local described = {
                    kind = kind, id = id,
                    payment = {method = "coin", discount = {kind = kind, id = id}},
                    available = available,
                    is_usable = asset.is_usable,
                    expire_time = asset.expire_time,
                }
                if kind == "free_gold_card" and banned then
                    asset.is_ban = true
                    described.unavailable_reason = "free_gold_card_banned"
                elseif not available then
                    described.unavailable_reason = "asset_not_usable"
                end
                options[#options + 1] = described
                snapshots[key] = {asset = asset, available = available}
            end
        end
    end
    return options, snapshots, true
end

local function vectorMatches(info, offers, context)
    local values = context.original_values
    local count = denseArray(values, MAX_OFFERS + 2)
    if count ~= #offers + 2 then return false end
    local episode_original, season_original = amount(info.ep_original_gold), amount(info.original_gold)
    if episode_original == nil or season_original == nil
        or amount(values[1]) ~= episode_original or amount(values[2]) ~= season_original then return false end
    for index, offer in ipairs(offers) do
        if offer.original_amount == nil or amount(values[index + 2]) ~= offer.original_amount then return false end
    end
    return true
end

local function canonicalAmountKey(original)
    if original % 1 == 0 and original <= MAX_SAFE_INTEGER then
        return string.format("%.0f", original)
    end
    local text = tostring(original)
    if original >= 0.000001 and original < 1e21 and text:match("^%d+%.%d+$")
        and tonumber(text) == original then return text end
    -- Do not guess a JavaScript property key when local numeric formatting is
    -- exponential, rounded, or outside the exact supported decimal range.
    return nil
end

local function calculatedAmount(prices, original)
    if type(prices) ~= "table" or original == nil then return nil end
    local count = 0
    for _ in pairs(prices) do
        count = count + 1
        if count > MAX_PRICE_KEYS then return reject("invalid_quote", "The calculated-price map exceeds its supported size.") end
    end
    -- JSON maps expose the original numeric amount's canonical string key;
    -- trusted in-process adapters may instead retain its numeric key. Alternate
    -- strings such as "1e2", "100.0", or padded keys do not stand in for "100".
    local key = canonicalAmountKey(original)
    local numeric_raw = rawget(prices, original)
    local string_raw
    if key then string_raw = rawget(prices, key) end
    local numeric_value, string_value = amount(numeric_raw), amount(string_raw)
    if numeric_raw ~= nil and string_raw ~= nil then
        if numeric_value == nil or string_value == nil or numeric_value ~= string_value then
            return reject("selection_changed", "The calculated-price map contains conflicting values for the original amount.")
        end
        return numeric_value
    end
    if numeric_raw ~= nil then return numeric_value end
    return string_value
end

function Candidate.describe(info, current_episode, selection, context)
    if type(info) ~= "table" or type(current_episode) ~= "table" or type(selection) ~= "table" then
        return reject("invalid_quote", "Purchase information, an anchor episode, and a selection are required.")
    end
    local normalized, err = Selection.normalize(selection.scope, selection.payment)
    if not normalized then return nil, err end
    if info.ep_id ~= nil and tostring(info.ep_id) ~= tostring(current_episode.id) then
        return reject("selection_changed", "The purchase information refers to a different anchor episode.")
    end
    if normalized.payment.method == "coupon" then
        -- Reading-coupon requirements are handled by the quote layer. Optional
        -- coin-discount metadata cannot invalidate a reading-coupon selection.
        return {batch_offers = {}, discount_options = {}, amounts = {}, blockers = {}}
    end
    local offers
    offers, err = describeOffers(info, current_episode, normalized)
    if not offers then return nil, err end
    local selected
    if normalized.scope.kind == "batch" then
        selected, err = selectOffer(offers, current_episode, normalized)
        if not selected then return nil, err end
    end
    local matched = sameSelection(normalized, context, current_episode)
    if matched and type(context.range_info) == "table" and context.range_info.ep_id ~= nil
        and tostring(context.range_info.ep_id) ~= tostring(current_episode.id) then matched = false end
    local options, snapshots, has_discount_list = describeDiscounts(context, matched)
    if not options then return nil, snapshots end
    local metadata = {
        batch_offers = offers, discount_options = options,
        selected_offer = selected, amounts = {}, blockers = {},
    }
    if selected then
        metadata.amounts.original, metadata.amounts.display = selected.original_amount, selected.display_amount
        addBlocker(metadata, "scope_unverified")
        if not selected.available then addBlocker(metadata, "offer_unavailable") end
    else
        metadata.amounts.original = amount(info.ep_original_gold)
        metadata.amounts.display = amount(info.pay_gold)
    end
    if normalized.payment.method ~= "coin" then return metadata end
    local discount = normalized.payment.discount
    local original = metadata.amounts.original
    if discount.kind == "none" then
        metadata.amounts.submission = original
        if original == nil or metadata.amounts.display == nil or original ~= metadata.amounts.display then
            addBlocker(metadata, "amount_unverified")
        end
        return metadata
    end

    -- Source-supported arithmetic does not establish live asset consumption.
    addBlocker(metadata, "asset_unverified")
    if not matched then addBlocker(metadata, "context_unverified") end
    local selected_asset = matched and snapshots[discount.kind .. ":" .. discount.id] or nil
    if matched and has_discount_list and not selected_asset then
        return reject("selection_changed", "The selected discount is not present in the matching scoped response.")
    end
    if selected_asset then
        metadata.asset_snapshot = selected_asset.asset
        if not selected_asset.available then addBlocker(metadata, "asset_unavailable") end
    end
    local asset = metadata.asset_snapshot
    if discount.kind == "free_gold_card" then
        metadata.amounts.submission = original
        metadata.amounts.free_gold = asset and asset.prime_gold_count or nil
        if original == nil or metadata.amounts.free_gold == nil then addBlocker(metadata, "amount_unverified") end
    elseif discount.kind == "activity" then
        local saved = asset and asset.saved_gold or nil
        if original ~= nil and saved ~= nil and saved <= original then
            metadata.amounts.submission = original - saved
        else
            addBlocker(metadata, "amount_unverified")
        end
    elseif discount.kind == "discount_card" then
        if matched and selected_asset and vectorMatches(info, offers, context) then
            metadata.amounts.submission, err = calculatedAmount(context.calculated_prices, original)
            if err then return nil, err end
        end
        if metadata.amounts.submission == nil then addBlocker(metadata, "amount_unverified") end
    end
    return metadata
end

return Candidate
