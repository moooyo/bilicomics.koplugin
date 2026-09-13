local Selection = require("bilicomics/purchase/selection")
local Value = require("bilicomics/purchase/value")

local Range = {
    CONTRACT = "bilibili_pc_ordinal_range_v1",
    PROVENANCE = "primary_sdk_ordinal_contract_and_quote_catalog_consistency",
}

local MAX_EPISODES, MAX_OFFERS = 20000, 512
local MAX_INTEGER, MAX_AMOUNT = 2147483647, 9007199254740991
local ZERO_DATE = "0000-00-00 00:00:00"

local function reject(code, message)
    return nil, Value.error("range_unverified", message, {code = code})
end

local function number(value)
    return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function integer(value, minimum, maximum)
    return number(value) and value >= minimum and value <= maximum and value % 1 == 0
end

local function amount(value)
    return number(value) and value >= 0 and value <= MAX_AMOUNT
end

local function id(value)
    if integer(value, 1, 999999999999999) then return string.format("%.0f", value) end
    if type(value) == "string" and #value <= 15 and value:match("^[1-9]%d*$") then return value end
end

local function dense(values, maximum)
    if type(values) ~= "table" or #values > maximum then return nil end
    local count = 0
    for key in pairs(values) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #values then return nil end
        count = count + 1
    end
    return count == #values and count or nil
end

local function noExpiry(value)
    return value == nil or value == "" or value == 0 or value == ZERO_DATE
end

local function eligibility(raw)
    if raw.unavailable ~= nil and type(raw.unavailable) ~= "boolean"
        or raw.is_available ~= nil and type(raw.is_available) ~= "boolean"
        or raw.status ~= nil and not number(raw.status)
        or raw.is_purchased ~= nil and type(raw.is_purchased) ~= "boolean" then return "unknown" end
    if raw.unavailable == true or raw.is_available == false or raw.status == 501 then return "unavailable" end
    if type(raw.is_in_free) ~= "boolean" or raw.is_in_free
        or not noExpiry(raw.unlock_expire_at) or not noExpiry(raw.expires_at)
        or raw.unlock_type == 2 or raw.unlock_type == 3 then return "temporary_or_unknown" end
    if raw.is_locked then
        if raw.pay_mode ~= 1 or raw.unlock_type ~= 0 or raw.is_purchased == true then return "unknown" end
        return "locked"
    end
    if raw.pay_mode == 0 and raw.unlock_type == 0 and raw.is_purchased ~= true then return "free" end
    if raw.pay_mode == 1 and raw.unlock_type == 1 and raw.is_purchased ~= false then return "owned" end
    return "unknown"
end

local offer_fields = {"batch_limit", "amount", "usable", "original_gold", "pay_gold",
    "discount_type", "discount", "discount_batch_gold"}
local quote_discount_fields = {"discount_type", "discount", "ep_discount_type", "ep_discount",
    "discount_ep_gold", "discount_remain_gold"}

local function offers(values)
    local count = dense(values, MAX_OFFERS)
    if not count or count == 0 then return nil end
    local result = {}
    for index, raw in ipairs(values) do
        if type(raw) ~= "table" or not integer(raw.batch_limit, 0, MAX_INTEGER)
            or not integer(raw.amount, 0, MAX_INTEGER) or type(raw.usable) ~= "boolean"
            or not amount(raw.original_gold) or not amount(raw.pay_gold) then return nil end
        local copy = {}
        for _, key in ipairs(offer_fields) do
            local value = raw[key]
            if key == "discount_type" or key == "discount" or key == "discount_batch_gold" then
                if value ~= nil and not number(value) then return nil end
            end
            copy[key] = value
        end
        result[index] = copy
    end
    return result
end

local function quoteTotals(info, comic_id, episode_id, anchor_price, whole_count, whole_price, after_count, after_price)
    if type(info) ~= "table" or id(info.comic_id) ~= comic_id
        or info.ep_id ~= nil and id(info.ep_id) ~= episode_id or info.is_locked ~= true then return nil end
    if not integer(info.remain_lock_ep_num, 0, MAX_INTEGER) or info.remain_lock_ep_num ~= whole_count
        or not integer(info.after_lock_ep_num, 1, MAX_INTEGER) or info.after_lock_ep_num ~= after_count then return nil end
    local expected = {ep_original_gold = anchor_price, pay_gold = anchor_price,
        original_gold = whole_price, remain_lock_ep_gold = whole_price, after_lock_ep_gold = after_price}
    for key, value in pairs(expected) do
        if not amount(info[key]) or info[key] ~= value then return nil end
    end
    expected.remain_lock_ep_num, expected.after_lock_ep_num = whole_count, after_count
    for _, key in ipairs(quote_discount_fields) do
        if info[key] ~= nil and not number(info[key]) then return nil end
        expected[key] = info[key]
    end
    return expected
end

local function digest(header, rows)
    local ok, result = pcall(function()
        local hash = require("ffi/sha2").sha256()
        hash(Value.encode(header))
        for _, row in ipairs(rows) do hash(Value.encode(row)) end
        return hash()
    end)
    if not ok or type(result) ~= "string" or #result ~= 64 or result:find("[^0-9a-f]") then return nil end
    return "sha256:" .. result
end

-- This derives intended IDs under the official ordinal-range contract. It is
-- neither a server echo of IDs nor proof that a purchase has been processed.
function Range.resolve(args)
    if type(args) ~= "table" then return reject("input", "Range evidence is required.") end
    if type(args.info) ~= "table" or type(args.range_info) ~= "table" then
        return reject("input", "Both basic and scoped quote responses are required.")
    end
    local selection = type(args.selection) == "table"
        and Selection.normalize(args.selection.scope, args.selection.payment)
    if not selection or selection.scope.kind ~= "batch" or selection.payment.method ~= "coin"
        or selection.payment.discount.kind ~= "none" then
        return reject("payment", "Only an explicit standard currency range is supported.")
    end
    local comic_id, episode_id = id(args.comic_id), id(args.episode_id)
    local detail = args.raw_detail
    if not comic_id or not episode_id or type(detail) ~= "table" or type(detail.comic) ~= "table"
        or id(detail.comic.id) ~= comic_id or type(detail.extra) ~= "table"
        or id(detail.extra.id or detail.extra.comic_id) ~= comic_id then
        return reject("catalog", "A matching original catalog response is required.")
    end
    -- Only the inspected ComicDetail.ep_list source establishes original order.
    local raw_rows = detail.extra.ep_list
    local count = dense(raw_rows, MAX_EPISODES)
    if not count or count == 0 then return reject("catalog", "The complete original catalog is unavailable.") end
    local rows, identities, ordinals, anchor_index = {}, {}, {}, nil
    local whole_count, whole_price = 0, 0
    for index = count, 1, -1 do
        local raw = raw_rows[index]
        local episode = type(raw) == "table" and id(raw.id)
        if not episode or identities[episode] or not number(raw.ord) or ordinals[raw.ord]
            or type(raw.is_locked) ~= "boolean" or not amount(raw.pay_gold)
            or raw.comic_id ~= nil and id(raw.comic_id) ~= comic_id then
            return reject("catalog", "Catalog identities, ordering, states or prices are incomplete.")
        end
        if #rows > 0 and raw.ord <= rows[#rows].ordinal then
            return reject("order", "The original catalog order does not match the supported ordinal contract.")
        end
        identities[episode], ordinals[raw.ord] = true, true
        local row = {id = episode, ordinal = raw.ord, locked = raw.is_locked,
            price = raw.pay_gold, access = eligibility(raw)}
        rows[#rows + 1] = row
        if episode == episode_id then anchor_index = #rows end
        if row.locked then whole_count, whole_price = whole_count + 1, whole_price + row.price end
        if not amount(whole_price) then return reject("amount", "Catalog totals exceed the supported range.") end
    end
    if not anchor_index or rows[anchor_index].access ~= "locked" then
        return reject("anchor", "The anchor must be an explicitly locked ordinary paid chapter.")
    end
    local anchor = rows[anchor_index]
    if selection.scope.start_ord ~= nil and selection.scope.start_ord ~= anchor.ordinal then
        return reject("anchor", "The selected anchor ordinal changed.")
    end
    local after, after_price = {}, 0
    for index = anchor_index, #rows do
        local row = rows[index]
        if row.access ~= "locked" and row.access ~= "free" and row.access ~= "owned" then
            return reject("access", "The potential range contains temporary, unavailable or uncertain access.")
        end
        if row.locked then after[#after + 1], after_price = row, after_price + row.price end
        if not amount(after_price) then return reject("amount", "The remaining range total is unsupported.") end
    end
    local basic_offers, scoped_offers = offers(args.info and args.info.batch_buy), offers(args.range_info and args.range_info.batch_buy)
    if not basic_offers or not scoped_offers or Value.encode(basic_offers) ~= Value.encode(scoped_offers) then
        return reject("offers", "The original offers changed or are incomplete across the quote reads.")
    end
    local basic_totals = quoteTotals(args.info, comic_id, episode_id, anchor.price, whole_count, whole_price, #after, after_price)
    local scoped_totals = quoteTotals(args.range_info, comic_id, episode_id, anchor.price, whole_count, whole_price, #after, after_price)
    if not basic_totals or not scoped_totals or Value.encode(basic_totals) ~= Value.encode(scoped_totals) then
        return reject("totals", "The quote totals do not match the original catalog and anchor.")
    end
    local selected, selected_index
    for index, offer in ipairs(basic_offers) do
        if offer.batch_limit == selection.scope.batch_limit
            and (selection.scope.offer_index == nil or selection.scope.offer_index == index) then
            if selected then return reject("offer", "The original offer selection is ambiguous.") end
            selected, selected_index = offer, index
        end
    end
    if not selected or selected.usable ~= true or selected.amount < 1 then
        return reject("offer", "The selected original offer is not explicitly usable.")
    end
    local limit = selected.batch_limit
    local selected_count = limit == 0 and #after or limit
    if selected.amount ~= selected_count or selected_count > #after then
        return reject("scope", "The offer count does not match its intended ordinal range.")
    end
    local ids, selected_price = {}, 0
    for index = 1, selected_count do
        ids[index], selected_price = after[index].id, selected_price + after[index].price
    end
    if not amount(selected_price) or selected.original_gold ~= selected_price or selected.pay_gold ~= selected_price then
        return reject("amount", "The server offer and intended chapter prices do not agree.")
    end
    local scope = {kind = "batch", batch_limit = limit, start_ord = anchor.ordinal,
        offer_index = selected_index, order = selection.scope.order}
    local header = {contract = Range.CONTRACT, provenance = Range.PROVENANCE,
        comic_id = comic_id, episode_id = episode_id, scope = scope, payment = selection.payment,
        offers = basic_offers, totals = basic_totals, episode_ids = ids, amount = selected.original_gold,
        raw_source = "ComicDetail.ep_list", catalog_count = count}
    local basis_digest = digest(header, rows)
    if not basis_digest then return reject("digest", "The range evidence digest could not be produced.") end
    local server_offer = Value.copy(selected)
    server_offer.offer_index, server_offer.order = selected_index, scope.order
    return {schema_version = 1, contract = Range.CONTRACT, provenance = Range.PROVENANCE,
        server_confirmed_ids = false, basis_digest = basis_digest,
        comic_id = comic_id, anchor_episode_id = episode_id, anchor_ordinal = anchor.ordinal,
        episode_ids = ids, episode_count = #ids, scope = scope,
        amount = selected.original_gold, server_offer = server_offer}
end

function Range.matches(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    local ok, result = pcall(function() return Value.encode(left) == Value.encode(right) end)
    return ok and result
end

return Range
