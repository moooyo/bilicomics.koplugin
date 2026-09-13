-- Run only through the private launcher after separate read-only quote approval.
-- This observer never builds a submittable quote or invokes PurchaseService.
local source, session_path, output = assert(arg[1]), assert(arg[2]), assert(arg[3])
assert(arg[4] == "approved-readonly-quote-observation", "Read-only quote approval is required")
assert(arg[5] == nil or arg[5] == "build-ordinal-proofs", "Unsupported observation mode")
require("setupkoenv")
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local Client = require("bilicomics/protocol/client")
local Session = require("bilicomics/protocol/session")
local Transport = require("bilicomics/protocol/transport")
local Errors = require("bilicomics/protocol/errors")
local JSON = require("bilicomics/protocol/json")
local rapidjson = require("rapidjson")
local Assets = require("bilicomics/protocol/assets")
local report = { schema_version = 1, probe = "readonly-quote-observation", completed = false,
    session_validated = false, requests = {}, observations = {}, blocked_requests = 0,
    limits = { business_requests = 7, quote_requests = 4, public_assets = 2, comics = 1, anchors = 1 },
    purchase_submitted = false, wallet_requested = false, image_requested = false,
    account_mutation_requested = false, quote_builder_executed = false, exact_scope_verified = false }
local active, business_count, asset_count, quote_count = nil, 0, 0, 0
local pinned, fetched = {}, {}
for name, asset in pairs(Assets.manifest) do pinned[asset.url] = { name = name, filename = asset.filename } end
local http = Transport.new{ timeout = 15, total_timeout = 40, max_json_bytes = 8 * 1024 * 1024 }
local query = "device=pc&platform=web&nov=27&a=810"
local guarded = {}

local function write(name, value)
    assert(name:match("^[a-z0-9%-]+%.json$"), "Invalid private capture name")
    local file = assert(io.open(output .. "/" .. name, "wb"), "Private capture is unavailable")
    assert(file:write(assert(JSON.encode(value))), "Private capture could not be written")
    assert(file:close(), "Private capture could not be closed")
end
local function errorShape(err)
    if type(err) ~= "table" then return { kind = "unclassified" } end
    return { kind = type(err.kind) == "string" and #err.kind <= 64 and err.kind:match("^[a-z_]+$") and err.kind or "unclassified",
        code = type(err.code) == "number" and err.code or nil, status = type(err.status) == "number" and err.status or nil }
end
local function block()
    report.blocked_requests = report.blocked_requests + 1
    return nil, Errors.new("observation_guard", "The request is outside this read-only observation.", { transmitted = false })
end
local function bodyMatches(body, expected, catalog)
    if type(body) ~= "table" then return false end
    if catalog and (type(body.m2) ~= "string" or #body.m2 == 0 or #body.m2 > 32768) then return false end
    for key, value in pairs(body) do
        if catalog and key == "m2" then
            if type(value) ~= "string" or #value == 0 or #value > 32768 then return false end
        elseif expected[key] ~= value then return false end
    end
    for key, value in pairs(expected) do if body[key] ~= value then return false end end
    return true
end
function guarded:request(request)
    local asset = pinned[request.url]
    local audit
    if asset then
        if not active or fetched[request.url] or asset_count >= 2 or request.method ~= "GET" or request.body then return block() end
        for key in pairs(request.headers or {}) do
            if key ~= "accept" and key ~= "referer" then return block() end
        end
        local prefix = output .. "/assets/" .. asset.filename .. ".part-"
        if type(request.output_path) ~= "string" or request.output_path:sub(1, #prefix) ~= prefix
            or not request.output_path:sub(#prefix + 1):match("^%d+$") then return block() end
        fetched[request.url], asset_count = true, asset_count + 1
        audit = { operation = "pinned_" .. asset.name, method = "GET" }
    else
        if not active or active.used or business_count >= 7 or request.method ~= active.method or request.output_path then return block() end
        local wanted = active.url
        if active.catalog then
            local suffix = type(request.url) == "string" and request.url:sub(#wanted + 1)
            if request.url:sub(1, #wanted) ~= wanted or not suffix or #suffix > 4096
                or not suffix:match("^&ultra_sign=[%w%%_.~%-]+$") then return block() end
        elseif request.url ~= wanted then return block() end
        if active.body then
            if not bodyMatches(request.body and JSON.decode(request.body), active.body, active.catalog) then return block() end
        elseif request.body then return block() end
        if active.quote and quote_count >= 4 then return block() end
        active.used, business_count = true, business_count + 1
        if active.quote then quote_count = quote_count + 1 end
        audit = { operation = active.label, method = active.method }
    end
    report.requests[#report.requests + 1] = audit
    local response, err = http:request(request)
    audit.status = response and response.status or nil
    if err then audit.error = errorShape(err) end
    if response and not asset then
        -- Wire envelopes can contain account data and image tokens; keep them private.
        write(active.label .. "-wire-private.json", { status = response.status, body = response.body })
    end
    return response, err
end

local function invoke(client, label, method, endpoint, body, arguments, options)
    assert(not active, "An observation is already active")
    options = options or {}
    local url = endpoint == "nav" and "https://api.bilibili.com/x/web-interface/nav"
        or "https://manga.bilibili.com/twirp/" .. endpoint .. "?" .. query
    if options.scoped then url = url .. "&getEpisodeDiscounts" end
    active = { label = label, method = endpoint == "nav" and "GET" or "POST", url = url,
        body = body, quote = options.quote, catalog = options.catalog, used = false }
    local ok, value, err = pcall(client[method], client, unpack(arguments or {}))
    local sent = active.used
    active = nil
    if not ok then
        write("client-error-private.json", { operation = label, error = value })
        error("The read-only client operation failed")
    end
    if not value then report.failure = { operation = label, error = errorShape(err) }; return nil end
    assert(sent, "The expected business request was not observed")
    write(label .. "-normalized-private.json", value)
    return value
end
local function dense(values, limit)
    if type(values) ~= "table" or #values > limit then return false end
    local count = 0
    for key in pairs(values) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #values then return false end
        count = count + 1
    end
    return count == #values
end
local function fieldTypes(value, keys)
    local result = {}
    for _, key in ipairs(keys) do
        local item
        if type(value) == "table" then item = value[key] end
        result[key] = rapidjson.null ~= nil and item == rapidjson.null and "null" or type(item)
    end
    return result
end
local function numeric(value)
    return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end
local function comparison(left, right)
    if not numeric(left) or not numeric(right) then return "unavailable" end
    return left == right and "equal" or left < right and "less" or "greater"
end
local price_keys = { "ep_original_gold", "pay_gold", "original_gold", "remain_lock_ep_gold", "remain_gold",
    "remain_coupon", "ep_pay_coupons", "recommend_coupon_ids", "allow_coupon", "is_locked", "remain_card",
    "optional_discount_list", "batch_buy", "discount_ep_gold", "discount_remain_gold", "episode_ids", "ep_ids", "ep_list" }
local offer_keys = { "batch_limit", "amount", "original_gold", "pay_gold", "discount_type", "discount", "discount_batch_gold", "usable" }
local nested_keys = { "id", "card_id", "is_usable", "type", "discount", "discount_limit", "expire_time", "amount",
    "discount_gold", "saved_gold", "total", "prime_gold_count" }
local function observation(info)
    local result = { decoded_wire_field_types = fieldTypes(info, price_keys), offers = {}, discounts = {},
        single_display_compared_to_original = comparison(info.pay_gold, info.ep_original_gold) }
    if dense(info.recommend_coupon_ids, 1024) then result.recommended_coupon_count = #info.recommend_coupon_ids end
    if dense(info.batch_buy, 512) then
        result.offer_count = #info.batch_buy
        for index, offer in ipairs(info.batch_buy) do
            result.offers[index] = { original_index = index, field_types = fieldTypes(offer, offer_keys),
                display_compared_to_original = type(offer) == "table" and comparison(offer.pay_gold, offer.original_gold) or "unavailable",
                limit_compared_to_amount = type(offer) == "table" and comparison(offer.batch_limit, offer.amount) or "unavailable" }
        end
    end
    if dense(info.optional_discount_list, 512) then
        result.discount_count = #info.optional_discount_list
        for index, entry in ipairs(info.optional_discount_list) do
            local item = { field_types = fieldTypes(entry, { "discount_type", "discount_info", "discount_act_info", "free_gold_card" }) }
            if type(entry) == "table" then
                for _, key in ipairs({ "discount_info", "discount_act_info", "free_gold_card" }) do
                    item[key] = fieldTypes(entry[key], nested_keys)
                end
            end
            result.discounts[index] = item
        end
    end
    return result
end
local function identifier(value)
    return type(value) == "string" and #value <= 15 and value:match("^[1-9]%d*$") and tonumber(value) or nil
end
local function wireIdentifier(value)
    if numeric(value) and value > 0 and value <= 999999999999999 and value % 1 == 0 then return value end
    return identifier(value)
end
local function main()
    local file = assert(io.open(session_path, "rb"), "The private session input is unavailable")
    local contents = file:read(131073); file:close()
    local session = assert(Session.parse(contents), "The private session input is invalid")
    contents = nil
    local client = Client.new{ session = session:serialize(), transport = guarded, asset_root = output .. "/assets" }
    local selected_comic, selected_episode, raw_catalog
    local envelope = client._envelope
    function client:_envelope(response, endpoint, context)
        local data, err = envelope(self, response, endpoint, context)
        if type(data) == "table" and active and endpoint == "GetEpisodeBuyInfo" then
            -- Observe decoded wire fields before normalization or injected fallback IDs.
            write(active.label .. "-decoded-private.json", data)
            local item = observation(data)
            item.identity_types = fieldTypes(data, { "ep_id", "comic_id" })
            if data.ep_id ~= nil then item.server_episode_matches = wireIdentifier(data.ep_id) == selected_episode end
            if data.comic_id ~= nil then item.server_comic_matches = wireIdentifier(data.comic_id) == selected_comic end
            report.observations[active.label] = item
            assert(item.server_episode_matches ~= false and item.server_comic_matches ~= false,
                "The decoded quote identity differs")
        elseif type(data) == "table" and endpoint == "ComicDetail" then
            raw_catalog = data
            write("catalog-decoded-private.json", data)
        end
        return data, err
    end
    if not invoke(client, "session", "validateSession", "nav") then return end
    report.session_validated = true
    local favorites = invoke(client, "favorites", "listFavorites", "bookshelf.v1.Bookshelf/ListFavorite",
        { page_num = 1, page_size = 20, order = 1, wait_free = 0, time_limit_free = 0, type = 0, from = "web", source = "web" },
        { { page_num = 1, page_size = 20, order = 1 } })
    if not favorites then return end
    local first = (favorites.items or favorites.comics or favorites)[1]
    local comic_id = type(first) == "table" and identifier(first.id)
    if not comic_id then report.stop_reason = "no_first_favorite"; return end
    selected_comic = comic_id
    local detail = invoke(client, "catalog", "comicDetail", "comic.v1.Comic/ComicDetail", { comic_id = comic_id }, { tostring(comic_id) }, { catalog = true })
    if not detail then return end
    assert(type(detail.comic) == "table" and identifier(detail.comic.id) == comic_id, "The catalog identity differs")
    local episode_id
    for _, episode in ipairs(detail.episodes or {}) do
        if episode.access == "locked" and identifier(episode.comic_id) == comic_id and identifier(episode.id) then
            episode_id = identifier(episode.id); break
        end
    end
    if not episode_id then report.stop_reason = "no_locked_chapter_in_first_favorite"; return end
    selected_episode = episode_id
    local matches, selected_raw = 0
    for _, episode in ipairs(raw_catalog and (raw_catalog.ep_list or raw_catalog.episodes) or {}) do
        if wireIdentifier(episode.id or episode.ep_id or episode.episode_id) == episode_id then
            matches, selected_raw = matches + 1, episode
        end
    end
    assert(matches == 1, "The selected catalog chapter is ambiguous")
    report.catalog = { anchor_unique = true, field_types = fieldTypes(selected_raw,
        { "id", "ep_id", "ord", "order", "is_locked", "is_in_free", "pay_mode", "unlock_type", "unlock_expire_at" }) }
    write("selection-private.json", { comic_id = comic_id, episode_id = episode_id })
    local captured_quotes = {}
    local function quote(label, scope)
        local body = { ep_id = episode_id }
        if scope then body.buy_type, body.batch_limit, body.order = scope.buy_type, scope.batch_limit, scope.order end
        local info = invoke(client, label, "purchaseInfo", "comic.v1.Comic/GetEpisodeBuyInfo", body,
            { tostring(episode_id), scope }, { quote = true, scoped = scope ~= nil })
        if not info then return end
        assert(identifier(info.ep_id) == episode_id and (info.comic_id == nil or identifier(info.comic_id) == comic_id), "The quote identity differs")
        assert(report.observations[label], "The decoded quote observation is unavailable")
        captured_quotes[label] = info
        return info
    end
    local basic = quote("basic")
    if not basic then return end
    if not quote("single", { kind = "single", buy_type = 1, order = 1 }) then return end
    local positive, remaining
    if dense(basic.batch_buy, 512) then
        for index, offer in ipairs(basic.batch_buy) do
            if type(offer) == "table" and (offer.usable == true or offer.usable == 1)
                and numeric(offer.batch_limit) and offer.batch_limit % 1 == 0 and offer.batch_limit >= 0
                and offer.batch_limit <= 2147483647 and numeric(offer.amount) and offer.amount > 0
                and offer.amount <= 2147483647 and offer.amount % 1 == 0 then
                if offer.batch_limit > 0 and not positive then positive = { index = index, limit = offer.batch_limit }
                elseif offer.batch_limit == 0 and not remaining then remaining = { index = index, limit = 0 } end
            end
        end
    end
    local selected = {}
    if positive then selected[#selected + 1] = { offer = positive, order = 1 } end
    if remaining then selected[#selected + 1] = { offer = remaining, order = 1 }
    elseif positive then selected[#selected + 1] = { offer = positive, order = 2 } end
    for index, selection in ipairs(selected) do
        local label = "batch-" .. index
        if not quote(label, { kind = "batch", buy_type = 2, batch_limit = selection.offer.limit, order = selection.order }) then return end
        report.observations[label].original_offer_index = selection.offer.index
        report.observations[label].sort_order = selection.order
        report.observations[label].remaining_offer_query = selection.offer.limit == 0
    end
    if arg[5] == "build-ordinal-proofs" then
        local Fetch = require("bilicomics/purchase/quote_fetch")
        local Quote = require("bilicomics/purchase/quote")
        report.range_construction, report.quote_builder_executed = {}, true
        for index, selected_offer in ipairs(selected) do
            local label = "batch-" .. index
            local scope = { kind = "batch", batch_limit = selected_offer.offer.limit,
                offer_index = selected_offer.offer.index, order = selected_offer.order }
            local payment, replay_calls = { method = "coin" }, 0
            local memo = {}
            function memo:purchaseInfo(requested_id, requested_scope)
                assert(tostring(requested_id) == tostring(episode_id), "The replay anchor differs")
                replay_calls = replay_calls + 1
                if not requested_scope then return basic end
                assert(requested_scope.buy_type == 2 and requested_scope.batch_limit == scope.batch_limit
                    and requested_scope.order == scope.order, "The replay scope differs")
                return captured_quotes[label]
            end
            function memo:comicDetail(requested_id)
                assert(tostring(requested_id) == tostring(comic_id), "The replay comic differs")
                replay_calls = replay_calls + 1
                return detail
            end
            local collected, collect_error = Fetch.run(memo, { comic_id = tostring(comic_id), episode_id = tostring(episode_id),
                scope = scope, payment = payment })
            local value, build_error
            if collected then
                value, build_error = Quote.build{ info = collected.info, raw_detail = collected.detail,
                    episodes = collected.detail.episodes, context = collected.context, episode_id = tostring(episode_id),
                    scope = scope, payment = payment, account_key = "observed-account", id = "observed-range-" .. index,
                    now = os.time(), max_age = 120 }
            end
            local item = { captured_read_calls = replay_calls, collector_returned = collected ~= nil,
                quote_returned = value ~= nil, submittable = value and value.submittable or false,
                error = (collect_error or build_error) and errorShape(collect_error or build_error) or nil,
                real_submit_executed = false }
            if collected and collected.context.range_error then item.range_error = collected.context.range_error end
            if value and value.range_proof then
                item.contract, item.provenance = value.range_proof.contract, value.range_proof.provenance
                item.server_confirmed_ids = value.range_proof.server_confirmed_ids
                item.episode_count = #value.episode_ids
                item.original_offer_index = value.scope.offer_index
                item.remaining = value.scope.batch_limit == 0
                item.payload_uses_server_amount = value.payload.pay_amount == basic.batch_buy[selected_offer.offer.index].original_gold
                item.payload_preserves_range_limit = value.payload.limit == scope.batch_limit
                item.fingerprint_available = type(value.fingerprint) == "string"
            end
            report.range_construction[label] = item
        end
    end
    report.completed = true
end
local ok, failure = xpcall(main, debug.traceback)
if not ok then
    write("observer-error-private.json", { traceback = failure })
    report.failure = { operation = "observer", error = { kind = "observation_failed" } }
end
report.business_requests, report.quote_requests, report.public_assets = business_count, quote_count, asset_count
write("observation-public.json", report)
print(JSON.encode({ completed = report.completed, business_requests = business_count, quote_requests = quote_count,
    blocked_requests = report.blocked_requests, purchase_submitted = false }))
os.exit(report.completed and 0 or 1)
