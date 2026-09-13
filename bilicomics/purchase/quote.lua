local Value = require("bilicomics/purchase/value")
local Selection = require("bilicomics/purchase/selection")
local Candidate = require("bilicomics/purchase/candidate")
local Range = require("bilicomics/purchase/range")
local Quote = {}

local function reject(message, kind)
    return nil, Value.error(kind or "capability", message)
end

local function isTrue(value) return value == true or value == 1 end

local function snapshot(episode)
    if not episode then return nil end
    return {access = episode.access or "unknown", expires_at = episode.expires_at}
end

function Quote.fingerprint(quote)
    return "purchase-v1:" .. Value.encode({
        account_key = quote.account_key,
        episode_id = quote.episode_id, comic_id = quote.comic_id,
        episode_ids = quote.episode_ids, scope = quote.scope,
        payment = quote.payment, method = quote.method, amount = quote.amount,
        balance = quote.balance, can_afford = quote.can_afford,
        before_access = quote.before_access, expected_access = quote.expected_access,
        payload = quote.payload, server_offer = quote.server_offer,
        selection = quote.selection, amounts = quote.amounts, asset_snapshot = quote.asset_snapshot,
        range_proof = quote.range_proof,
        submittable = quote.submittable,
    })
end

local function advisory(args, comic_id, selection, metadata, blockers)
    local scope = metadata.selected_offer and metadata.selected_offer.scope or selection.scope
    return { schema_version = 1, id = args.id, account_key = args.account_key,
        comic_id = comic_id, episode_id = Value.id(args.episode_id),
        scope = Value.copy(scope), payment = Value.copy(selection.payment), method = selection.payment.method,
        selection = { scope = Value.copy(scope), payment = Value.copy(selection.payment) },
        submittable = false, blockers = blockers or metadata.blockers, amounts = metadata.amounts,
        asset_snapshot = metadata.asset_snapshot, batch_offers = metadata.batch_offers,
        discount_options = metadata.discount_options, scopes = {{kind = "single", order = selection.scope.order}},
        payments = {{method = "coin", available = true}, {method = "coupon", available = isTrue(args.info.allow_coupon)
            and selection.scope.kind == "single"}},
        created_at = args.now, expires_at = args.now + args.max_age }
end

function Quote.build(args)
    local info, episode_id = args.info, Value.id(args.episode_id)
    if type(info) ~= "table" or not episode_id then return reject("A valid episode quote is required.", "invalid_quote") end
    if info.ep_id and Value.id(info.ep_id) ~= episode_id then return reject("The quote refers to a different episode.", "invalid_quote") end
    local selection, selection_error = Selection.normalize(args.scope, args.payment)
    if not selection then return nil, selection_error end
    if args.context ~= nil then
        local context_selection = type(args.context) == "table" and args.context.selection
        local normalized_context = type(context_selection) == "table"
            and Selection.normalize(context_selection.scope, context_selection.payment)
        if not normalized_context or Value.encode(normalized_context) ~= Value.encode(selection) then
            return reject("The quote response does not match the requested selection.", "invalid_selection")
        end
    end
    local scope, payment = selection.scope, selection.payment

    local catalog = {}
    for _, episode in ipairs(args.episodes or {}) do
        if Value.id(episode.id) then
            if catalog[tostring(episode.id)] then return reject("The catalog contains duplicate episode identities.", "invalid_quote") end
            catalog[tostring(episode.id)] = episode
        end
    end
    local current = catalog[episode_id]
    local comic_id = Value.id(info.comic_id) or (current and Value.id(current.comic_id))
    if not comic_id or not current or (current.comic_id and Value.id(current.comic_id) ~= comic_id) then
        return reject("Current comic and episode access information is required.", "access_unknown")
    end
    if args.context and (Value.id(args.context.episode_id) ~= episode_id or Value.id(args.context.comic_id) ~= comic_id) then
        return reject("The quote context belongs to another comic or chapter.", "invalid_selection")
    end

    if current.access == "free" or current.access == "owned" then return reject("The selected chapter is already permanently readable.", "already_readable") end
    if current.access == "unknown" or not current.access then return reject("Current chapter access is unknown.", "access_unknown") end
    if current.access == "unavailable" then return reject("The selected chapter is unavailable.", "unavailable") end
    local metadata, metadata_error = Candidate.describe(info, current, selection, args.context)
    if not metadata then return nil, metadata_error end
    local scopes, offer, ids, amount = {{kind = "single", order = scope.order}}, nil, {episode_id}, nil
    local range_proof
    if scope.kind == "batch" then
        -- Recompute from the original response, not from a caller's proof flag.
        local resolved = type(args.context) == "table" and Range.resolve({info = info,
            range_info = args.context.range_info, raw_detail = args.raw_detail,
            episode_id = episode_id, comic_id = comic_id, selection = selection})
        if not resolved or not Range.matches(resolved, args.context.range_proof) then
            return advisory(args, comic_id, selection, metadata)
        end
        range_proof, scope = resolved, Value.copy(resolved.scope)
        offer, ids, amount = resolved.server_offer, Value.copy(resolved.episode_ids), resolved.amount
        scopes[#scopes + 1] = Value.copy(scope)
        local blockers = {}
        for _, blocker in ipairs(metadata.blockers or {}) do
            if blocker ~= "scope_unverified" then blockers[#blockers + 1] = blocker end
        end
        metadata.blockers = blockers
    end
    if scope.kind == "batch" and payment.method ~= "coin" then return reject("Batch coupon payment is not supported.", "invalid_payment") end

    local before, expected = {}, {}
    local requested_found = false
    for _, id in ipairs(ids) do
        local episode = catalog[id]
        if not episode or Value.id(episode.comic_id) ~= comic_id then return reject("The exact batch chapter set cannot be verified.", "access_unknown") end
        if id == episode_id then requested_found = true end
        before[id], expected[id] = snapshot(episode), {access = "owned"}
        if episode.access == "free" or episode.access == "owned" then return reject("The selection already includes permanently readable chapters.", "already_readable") end
        if episode.access == "unknown" or not episode.access then return reject("Current chapter access is unknown.", "access_unknown") end
        if episode.access == "unavailable" then return reject("A selected chapter is unavailable.", "unavailable") end
        if scope.kind == "batch" and episode.access ~= "locked" then
            return reject("The normalized chapter access contradicts the original range evidence.", "access_unknown")
        end
    end
    if not requested_found then return reject("The batch does not include the selected episode.", "invalid_quote") end

    local payload, balance, coupon_ids = {}, nil, nil
    local coupons_allowed = isTrue(info.allow_coupon)
    if payment.method == "coin" then
        local selected_discount = payment.discount or {kind = "none"}
        if selected_discount.kind ~= "none" then
            return advisory(args, comic_id, selection, metadata)
        end
        if not amount then
            local original, displayed = Value.amount(info.ep_original_gold), Value.amount(info.pay_gold)
            if original == nil or displayed == nil or original ~= displayed then
                return advisory(args, comic_id, selection, metadata, {"amount_unverified"})
            end
            amount = original
        end
        balance = Value.amount(info.remain_gold)
        if amount == nil or balance == nil then return advisory(args, comic_id, selection, metadata, {"asset_unverified"}) end
        if payment.coupon_ids then return reject("Coin payment must not carry reading coupons.", "invalid_payment") end
        payload.buy_method = 3
        if amount > 0 then payload.pay_amount = amount end
    else
        if not coupons_allowed then return reject("Reading coupons are not eligible for this episode.", "ineligible_coupon") end
        amount, balance = Value.amount(info.ep_pay_coupons), Value.amount(info.remain_coupon)
        if not amount or amount < 1 or amount % 1 ~= 0 or balance == nil then return reject("The coupon requirement is not verified.") end
        coupon_ids = Value.ids(payment.coupon_ids or info.recommend_coupon_ids)
        local eligible = Value.ids(info.eligible_coupon_ids or info.recommend_coupon_ids)
        if not coupon_ids or not eligible or #coupon_ids ~= amount then return reject("The required eligible reading coupons are missing.", "ineligible_coupon") end
        local eligible_set = {}
        for _, id in ipairs(eligible) do eligible_set[id] = true end
        for _, id in ipairs(coupon_ids) do
            if not eligible_set[id] then return reject("A selected reading coupon is not eligible.", "ineligible_coupon") end
        end
        payload.buy_method, payload.coupon_ids = 2, Value.copy(coupon_ids)
    end
    if scope.kind == "single" then
        scope, payload.ep_id = {kind = "single", order = scope.order}, episode_id
    else
        payload.comic_id, payload.with_ord_scope = comic_id, true
        payload.start_ord, payload.limit = scope.start_ord, scope.batch_limit
    end
    local quote = {
        schema_version = 1, account_key = args.account_key,
        id = args.id, episode_id = episode_id, comic_id = comic_id,
        episode_ids = ids, scope = Value.copy(scope),
        method = payment.method, payment = Value.copy(payment),
        amount = amount, balance = balance, can_afford = balance >= amount,
        before_access = before, expected_access = expected, payload = payload,
        created_at = args.now, expires_at = args.now + args.max_age,
        scopes = scopes,
        payments = {{method = "coin", available = true}, {method = "coupon", available = coupons_allowed and scope.kind == "single"}},
        server_offer = offer and Value.copy(offer) or nil,
        range_proof = range_proof,
        submittable = true, amounts = metadata.amounts, asset_snapshot = metadata.asset_snapshot,
        batch_offers = metadata.batch_offers, discount_options = metadata.discount_options,
    }
    quote.payment.coupon_ids = coupon_ids
    quote.selection = {scope = Value.copy(scope), payment = Value.copy(quote.payment)}
    quote.fingerprint = Quote.fingerprint(quote)
    return quote
end

return Quote
