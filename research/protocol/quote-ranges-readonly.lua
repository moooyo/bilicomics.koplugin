-- Observe two privately selected anchors without requesting or consuming access.
local source, session_path, output = assert(arg[1]), assert(arg[2]), assert(arg[3])
assert(arg[4] == "approved-readonly-quote-observation", "Read-only scope approval is required")
local selection_path = assert(arg[5])
require("setupkoenv")
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local Client = require("bilicomics/protocol/client")
local Session = require("bilicomics/protocol/session")
local Transport = require("bilicomics/protocol/transport")
local JSON = require("bilicomics/protocol/json")
local Errors = require("bilicomics/protocol/errors")
local function read(path, limit)
    local file = assert(io.open(path, "rb"), "Private input is unavailable")
    local text = file:read(limit + 1); file:close()
    assert(text and #text <= limit, "Private input exceeds its limit")
    return text
end
local function write(name, value)
    assert(name:match("^[a-z0-9%-]+%.json$"), "Invalid observation filename")
    local file = assert(io.open(output .. "/" .. name, "wb"))
    assert(file:write(assert(JSON.encode(value)))); assert(file:close())
end
local function integer(value, minimum, maximum)
    return type(value) == "number" and value == value and value >= minimum and value <= maximum and value % 1 == 0
end
local function id(value)
    if integer(value, 1, 999999999999999) then return value end
    if type(value) == "string" and #value <= 15 and value:match("^[1-9]%d*$") then return tonumber(value) end
end
local function equalCounts(left, right)
    if not integer(left, 0, 2147483647) or not integer(right, 0, 2147483647) then return "unavailable" end
    return left == right
end
local report = { probe = "readonly-range-followup", completed = false, requests = {}, anchors = {},
    blocked_requests = 0, purchase_submitted = false, wallet_requested = false, exact_scope_verified = false }
local ticket, count = nil, 0
local base = "https://manga.bilibili.com/twirp/comic.v1.Comic/GetEpisodeBuyInfo?device=pc&platform=web&nov=27&a=810"
local http = Transport.new{ timeout = 15, total_timeout = 40, max_json_bytes = 8 * 1024 * 1024 }
local guarded = {}
function guarded:request(request)
    local body = request.body and JSON.decode(request.body)
    local allowed = ticket and not ticket.used and count < 4 and request.url == ticket.url
        and request.method == "POST" and request.output_path == nil and type(body) == "table"
    if allowed then
        for key, value in pairs(body) do if ticket.body[key] ~= value then allowed = false end end
        for key, value in pairs(ticket.body) do if body[key] ~= value then allowed = false end end
    end
    if not allowed then
        report.blocked_requests = report.blocked_requests + 1
        return nil, Errors.new("observation_guard", "The request is outside the selected read-only ranges.", { transmitted = false })
    end
    ticket.used, count = true, count + 1
    local entry = { operation = ticket.label, method = "POST" }
    report.requests[#report.requests + 1] = entry
    local response, err = http:request(request)
    entry.status = response and response.status or nil
    if err then entry.error_kind = err.kind end
    if response then write(ticket.label .. "-wire-private.json", { status = response.status, body = response.body }) end
    return response, err
end
local function main()
    local selection = assert(JSON.decode(read(selection_path, 65536)))
    assert(selection.schema_version == 1 and id(selection.comic_id), "The private comic identity is invalid")
    assert(type(selection.anchors) == "table" and #selection.anchors == 2, "Exactly two approved anchors are required")
    local seen = {}
    for _, anchor in ipairs(selection.anchors) do
        assert(type(anchor) == "table" and (anchor.label == "interior" or anchor.label == "tail")
            and not seen[anchor.label] and id(anchor.episode_id) and not seen[id(anchor.episode_id)]
            and integer(anchor.locked_inclusive_remaining_count, 1, 2147483647), "The private anchor selection is invalid")
        seen[anchor.label] = true
        seen[id(anchor.episode_id)] = true
    end
    local session = assert(Session.parse(read(session_path, 131072)))
    local client = Client.new{ session = session:serialize(), transport = guarded, asset_root = output .. "/assets" }
    local decode = client._envelope
    function client:_envelope(response, endpoint, context)
        local data, err = decode(self, response, endpoint, context)
        if data then
            assert(endpoint == "GetEpisodeBuyInfo" and ticket, "An unexpected response was decoded")
            write(ticket.label .. "-decoded-private.json", data)
            assert(data.ep_id == nil or id(data.ep_id) == ticket.body.ep_id, "The response episode identity differs")
            assert(id(data.comic_id) == id(selection.comic_id), "The response comic identity is missing or differs")
        end
        return data, err
    end
    local function query(anchor, scope)
        local body = { ep_id = id(anchor.episode_id) }
        if scope then body.buy_type, body.batch_limit, body.order = 2, scope.batch_limit, 1 end
        local label = anchor.label .. (scope and "-scoped" or "-basic")
        ticket = { label = label, body = body, url = base .. (scope and "&getEpisodeDiscounts" or ""), used = false }
        local value, err = client:purchaseInfo(tostring(body.ep_id), scope)
        assert(ticket.used, "The expected quote request was not observed")
        ticket = nil
        if not value then
            report.failure = { operation = label, error_kind = err and err.kind, code = err and err.code }
            error("The selected quote could not be observed")
        end
        write(label .. "-normalized-private.json", value)
        return value
    end
    for _, anchor in ipairs(selection.anchors) do
        local basic = query(anchor)
        local entry = { basic_read = true, after_count_type = type(basic.after_lock_ep_num),
            remaining_count_matches_catalog = equalCounts(basic.after_lock_ep_num, anchor.locked_inclusive_remaining_count),
            after_equals_whole_count = equalCounts(basic.after_lock_ep_num, basic.remain_lock_ep_num) }
        report.anchors[anchor.label] = entry
        local chosen, chosen_index
        for index, offer in ipairs(type(basic.batch_buy) == "table" and basic.batch_buy or {}) do
            if type(offer) == "table" and (offer.usable == true or offer.usable == 1)
                and integer(offer.batch_limit, 0, 2147483647) and integer(offer.amount, 1, 2147483647) then
                local matches = anchor.label == "interior" and offer.batch_limit == 0
                    or anchor.label == "tail" and offer.batch_limit > 0 and offer.amount < offer.batch_limit
                if matches and (not chosen or offer.batch_limit < chosen.batch_limit) then chosen, chosen_index = offer, index end
            end
        end
        if chosen then
            local scoped = query(anchor, { kind = "batch", buy_type = 2, batch_limit = chosen.batch_limit, order = 1 })
            entry.scoped_read, entry.original_offer_index = true, chosen_index
            entry.remaining_offer_query = chosen.batch_limit == 0
            entry.amount_matches_remaining_count = equalCounts(chosen.amount, basic.after_lock_ep_num)
            entry.after_count_stable = equalCounts(scoped.after_lock_ep_num, basic.after_lock_ep_num)
        else entry.scoped_read, entry.stop_reason = false, "no_usable_offer_matching_constraint" end
    end
    report.completed = true
end
local ok, failure = xpcall(main, debug.traceback)
if not ok then write("observer-error-private.json", { traceback = failure }) end
report.quote_requests = count
write("observation-public.json", report)
print(JSON.encode({ completed = report.completed, quote_requests = count, purchase_submitted = false }))
os.exit(report.completed and 0 or 1)
