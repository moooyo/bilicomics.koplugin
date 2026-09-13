-- Remote-only guard verification with strict fake originals and no network/session input.
require("setupkoenv")
local source, guard_path, output, result_path = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local JSON = require("bilicomics/protocol/json")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local unpack = unpack or table.unpack
local deferred = {}
package.loaded["ui/uimanager"] = { nextTick = function(_, callback, ...)
    deferred[#deferred + 1] = { callback = callback, n = select("#", ...), ... }
end }
local Transport = require("bilicomics/protocol/transport")
local Client = require("bilicomics/protocol/client")
local Runner = require("bilicomics/jobs/runner")
local report = { passed = false, tests = {}, assertions = {}, transport_forwards = 0, runner_forwards = 0,
    real_network_requests = 0, actual_purchases = false, real_session_used = false, strict_fake_originals = true }
local current, original_transport_calls, original_runner_calls, last_request = nil, 0, 0, nil
local function check(name, condition)
    local label = current.name .. ": " .. name
    report.assertions[#report.assertions + 1] = { name = label, passed = not not condition }
    assert(condition, label)
end
function Transport:request(request)
    original_transport_calls = original_transport_calls + 1
    assert(current and current.allow_transport, "The guard forwarded a forbidden request to the strict fake")
    last_request = request
    return { status = 200, body = '{"code":0,"data":{}}', bytes = 20, transmitted = false }
end
function Runner:submit(request, options, callback)
    original_runner_calls = original_runner_calls + 1
    assert(current and current.allow_runner, "The guard forwarded a forbidden job to the strict fake")
    current.runner_request, current.runner_options, current.runner_callback = request, options, callback
    return "fake-task-" .. original_runner_calls
end
local function resourceURL(token)
    local function absolute(url) return url:sub(1, 2) == "//" and "https:" .. url or url end
    if token.complete_url then
        if token.complete_url:sub(1, 7) == "http://" then return "https://" .. token.complete_url:sub(8) end
        return absolute(token.complete_url) .. "&code=DanmakuInfo"
    end
    local url = absolute(token.url)
    if token.token then
        local encoded = token.token:gsub("[^%w%-_%.~]", function(char) return string.format("%%%02X", char:byte()) end)
        url = url .. (url:find("?", 1, true) and "&" or "?") .. "token=" .. encoded
    end
    return url
end
function Client:downloadImage(token, path)
    return self.transport:request{ url = resourceURL(token), method = "GET", output_path = path,
        headers = token.synthetic_headers or { referer = "https://manga.bilibili.com/", ["user-agent"] = "Synthetic" } }
end
local Guard = assert(loadfile(guard_path))()
assert(Guard.install(output))
local transport = Transport.new()
local client = Client.new{ transport = transport, session = { cookies = { SESSDATA = "synthetic-not-an-account" } } }
local runner = setmetatable({}, { __index = Runner })
local base = "https://manga.bilibili.com/twirp/"
local query = "?device=pc&platform=web&nov=27&a=810"
local function rpc(route, body, suffix)
    return { url = base .. route .. query .. (suffix or ""), method = "POST", body = assert(JSON.encode(body)) }
end
local function flush()
    while #deferred > 0 do
        local entry = table.remove(deferred, 1)
        entry.callback(unpack(entry, 1, entry.n))
    end
end
local function test(name, allowed_transport, allowed_runner, fn)
    current = { name = name, allow_transport = allowed_transport, allow_runner = allowed_runner }
    local before_transport, before_runner = original_transport_calls, original_runner_calls
    local ok, err = xpcall(fn, debug.traceback)
    if #deferred > 0 then
        local drained, drain_error = pcall(flush)
        if not drained then ok, err = false, drain_error end
    end
    report.tests[#report.tests + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil,
        transport_forward_count = original_transport_calls - before_transport,
        runner_forward_count = original_runner_calls - before_runner }
    print((ok and "PASS " or "FAIL ") .. name)
end
local function allowed(name, request)
    test(name, true, false, function()
        local before = original_transport_calls
        local value, err = transport:request(request)
        check("allowed request reaches the original exactly once and unchanged", value and not err
            and original_transport_calls == before + 1 and last_request == request)
    end)
end
local function blocked(name, request)
    test(name, false, false, function()
        local before = original_transport_calls
        local value, err = transport:request(request)
        check("forbidden request is denied without transmission", value == nil and err and err.kind == "verification_guard"
            and err.transmitted == false and err.retryable == false)
        check("the original transport is never called", original_transport_calls == before)
    end)
end

allowed("wallet_empty_object", rpc("user.v1.User/GetWallet", {}))
allowed("basic_episode_information", rpc("comic.v1.Comic/GetEpisodeBuyInfo", { ep_id = 101 }))
for _, kind in ipairs({ 1, 2, 3 }) do
    allowed("scoped_information_type_" .. kind, rpc("comic.v1.Comic/GetEpisodeBuyInfo",
        { ep_id = 101, buy_type = kind, batch_limit = 0, order = 2 }, "&getEpisodeDiscounts"))
end
allowed("single_scope_may_omit_limit", rpc("comic.v1.Comic/GetEpisodeBuyInfo", { ep_id = 101, buy_type = 1, order = 1 }, "&getEpisodeDiscounts"))
allowed("full_scope_may_omit_limit", rpc("comic.v1.Comic/GetEpisodeBuyInfo", { ep_id = 101, buy_type = 3, order = 1 }, "&getEpisodeDiscounts"))
allowed("discount_list_original_vector", rpc("comic.v1.Comic/GetDiscountList", { comic_id = 81, order = 1, original_values = { 0, 10.5, 30 } }))
allowed("discount_price_original_vector", rpc("comic.v1.Comic/CalDiscountPrice", { id = 301, original_values = { 0, 10.5, 30 } }))
allowed("free_gold_card_eligibility", rpc("comic.v1.Comic/GetComicFreeGoldCard", { comic_id = 81, ep_id = 101, buy_type = 2, batch_limit = 5 }))
allowed("free_gold_card_zero_remaining_scope", rpc("comic.v1.Comic/GetComicFreeGoldCard", { comic_id = 81, ep_id = 101, buy_type = 3, batch_limit = 0 }))
allowed("bounded_maximum_scope", rpc("comic.v1.Comic/GetEpisodeBuyInfo",
    { ep_id = 999999999999999, buy_type = 2, batch_limit = 2147483647, order = 1 }, "&getEpisodeDiscounts"))
local vector = {}; for index = 1, 514 do vector[index] = index - 1 end
allowed("maximum_original_vector", rpc("comic.v1.Comic/CalDiscountPrice", { id = 301, original_values = vector }))

for _, item in ipairs({
    { "wallet", function() return client:wallet() end },
    { "basic_info", function() return client:purchaseInfo("101") end },
    { "named_single_basic", function() return client:purchaseInfo("101", "single") end },
    { "scoped_single", function() return client:purchaseInfo("101", { buy_type = 1, order = 2 }) end },
    { "scoped_batch", function() return client:purchaseInfo("101", { kind = "batch", batch_limit = 0, start_ord = 1.5 }) end },
    { "discount_list", function() return client:discountList("81", 2, { 0, 10.5 }) end },
    { "discount_price", function() return client:discountPrice("301", { 0, 10.5 }) end },
    { "free_gold_card", function() return client:freeGoldCardInfo("81", "101", { buy_type = 2, batch_limit = 5 }) end },
}) do
    test("production_client_wire_" .. item[1], true, false, function()
        local before = original_transport_calls
        local value, err = item[2]()
        check("real Client produces an admitted wire request", value ~= nil and not err and original_transport_calls == before + 1)
        local body = assert(JSON.decode(last_request.body))
        check("local ordinal never leaks into read body", body.start_ord == nil)
    end)
end

local info = "comic.v1.Comic/GetEpisodeBuyInfo"
local scoped = { ep_id = 101, buy_type = 2, batch_limit = 5, order = 1 }
blocked("valued_discount_flag", rpc(info, scoped, "&getEpisodeDiscounts=1"))
blocked("duplicate_bare_discount_flag", rpc(info, scoped, "&getEpisodeDiscounts&getEpisodeDiscounts"))
blocked("flag_on_basic_info", rpc(info, { ep_id = 101 }, "&getEpisodeDiscounts"))
blocked("scoped_info_without_flag", rpc(info, scoped))
blocked("flag_on_wallet", rpc("user.v1.User/GetWallet", {}, "&getEpisodeDiscounts"))
blocked("flag_on_existing_read", rpc("comic.v1.Comic/ComicDetail", { comic_id = 81, m2 = "synthetic" }, "&getEpisodeDiscounts"))
blocked("duplicate_base_key", rpc(info, { ep_id = 101 }, "&device=pc"))
blocked("empty_query_piece", rpc(info, { ep_id = 101 }, "&&"))
blocked("signed_parameter_on_plain_quote_read", rpc(info, { ep_id = 101 }, "&ultra_sign=synthetic"))
blocked("query_challenge_on_wallet", rpc("user.v1.User/GetWallet", {}, "&m1=synthetic"))
for _, body in ipairs({ { ep_id = "101" }, { ep_id = 0 }, { ep_id = 1.5 }, { ep_id = 1000000000000000 },
    { ep_id = 101, buy_type = "2", batch_limit = 1, order = 1 }, { ep_id = 101, buy_type = 4, batch_limit = 1, order = 1 },
    { ep_id = 101, buy_type = 2, order = 1 }, { ep_id = 101, buy_type = 2, batch_limit = -1, order = 1 },
    { ep_id = 101, buy_type = 2, batch_limit = 0.5, order = 1 }, { ep_id = 101, buy_type = 2, batch_limit = 2147483648, order = 1 },
    { ep_id = 101, buy_type = 2, batch_limit = 1, order = 3 }, { ep_id = 101, buy_type = 2, batch_limit = 1, order = "1" },
    { ep_id = 101, buy_type = 2, batch_limit = 1, order = 1, start_ord = 2 },
    { ep_id = 101, buy_method = 3, pay_amount = 0 } }) do
    blocked("invalid_quote_body_" .. (#report.tests + 1), rpc(info, body, body.buy_type and "&getEpisodeDiscounts" or ""))
end
for _, values in ipairs({ {}, { 1 }, { 1, -2 }, { 1, "2" }, { 1, true }, { first = 1, second = 2 } }) do
    blocked("invalid_original_vector_" .. (#report.tests + 1), rpc("comic.v1.Comic/CalDiscountPrice", { id = 301, original_values = values }))
end
vector[515] = 515
blocked("too_many_original_values", rpc("comic.v1.Comic/CalDiscountPrice", { id = 301, original_values = vector }))
blocked("unknown_discount_order", rpc("comic.v1.Comic/GetDiscountList", { comic_id = 81, order = 0, original_values = { 0, 10 } }))
blocked("wrong_discount_id_field", rpc("comic.v1.Comic/CalDiscountPrice", { discount_id = 301, original_values = { 0, 10 } }))
blocked("wallet_cannot_accept_selection_fields", rpc("user.v1.User/GetWallet", { ep_id = 101 }))
blocked("card_scope_requires_count", rpc("comic.v1.Comic/GetComicFreeGoldCard", { comic_id = 81, ep_id = 101, buy_type = 2 }))
blocked("card_scope_cannot_include_asset_use", rpc("comic.v1.Comic/GetComicFreeGoldCard",
    { comic_id = 81, ep_id = 101, buy_type = 2, batch_limit = 5, free_gold_card_id = 301 }))
for _, body in ipairs({ "[]", "null", "{", '{"ep_id":101,"original_values":[0,1e999]}' }) do
    local request = rpc("user.v1.User/GetWallet", {}); request.body = body
    blocked("malformed_object_" .. (#report.tests + 1), request)
end
local misplaced = rpc("user.v1.User/GetWallet", {}); misplaced.output_path = output .. "/wallet.json"
blocked("rpc_cannot_write_an_output_file", misplaced)
local oversized = rpc("user.v1.User/GetWallet", {}); oversized.body = string.rep(" ", 262145)
blocked("oversized_rpc_body", oversized)
for _, method in ipairs({ "GET", "PUT", "DELETE" }) do
    local request = rpc("user.v1.User/GetWallet", {}); request.method = method
    blocked("wrong_wallet_method_" .. method, request)
end
for _, route in ipairs({ "comic.v1.Comic/BuyEpisode", "comic.v1.Comic/SetAutoBuy", "comic.v1.Comic/RentEpisode",
    "user.v1.User/Recharge", "bookshelf.v1.Bookshelf/AddHistory", "bookshelf.v1.Bookshelf/AddFavorite",
    "bookshelf.v1.Bookshelf/DeleteFavorite", "comic.v1.Comic/UnknownRead" }) do
    blocked("forbidden_route_" .. route:match("/([^/]+)$"), rpc(route, { ep_id = 101, pay_amount = 0, buy_method = 3 }))
end
blocked("buy_fields_cannot_enter_read_route", rpc("comic.v1.Comic/GetImageIndex", { ep_id = 101, m2 = "synthetic", buy_type = 2 }))
blocked("malformed_transport_request", false)
local bad_host = rpc("user.v1.User/GetWallet", {}); bad_host.url = bad_host.url:gsub("manga.bilibili.com", "manga.bilibili.com.evil.invalid", 1)
blocked("wrong_rpc_host", bad_host)

allowed("existing_nav_read", { url = "https://api.bilibili.com/x/web-interface/nav", method = "GET" })
allowed("existing_library_read", rpc("bookshelf.v1.Bookshelf/ListFavorite",
    { page_num = 1, page_size = 20, order = 1, wait_free = 0, time_limit_free = 0, type = 0, from = "web", source = "web" }))
allowed("existing_signed_index", rpc("comic.v1.Comic/GetImageIndex", { ep_id = 101, m2 = "synthetic" }, "&cpx=1&ultra_sign=synthetic"))
local asset = require("bilicomics/protocol/assets").manifest.signing.url
allowed("pinned_public_asset", { url = asset, method = "GET", output_path = output .. "/asset.part", headers = { accept = "application/wasm" } })
blocked("public_asset_rejects_cookie", { url = asset, method = "GET", headers = { Cookie = "synthetic" } })
blocked("public_asset_rejects_body", { url = asset, method = "GET", body = "{}" })
blocked("public_asset_rejects_external_output", { url = asset, method = "GET", output_path = "/tmp/unrelated.part" })
blocked("malformed_output_path", { url = asset, method = "GET", output_path = true })
local token = { complete_url = "https://i0.hdslb.com/bfs/manga/synthetic.png?token=synthetic" }
test("active_image_rules_remain_intact", true, false, function()
    local before = original_transport_calls
    local value, err = client:downloadImage(token, output .. "/page.part")
    check("active anonymous image reaches the original", value and not err and original_transport_calls == before + 1)
end)
blocked("completed_image_is_not_permanently_authorized", { url = resourceURL(token), method = "GET" })
test("active_image_rejects_credentials", false, false, function()
    local before = original_transport_calls
    local value, err = client:downloadImage({ complete_url = token.complete_url, synthetic_headers = { authorization = "synthetic" } }, output .. "/page.part")
    check("anonymous image header restriction remains enforced", not value and err.transmitted == false and original_transport_calls == before)
end)
for _, path in ipairs({ "/bfs/../twirp/user.v1.User/UnknownRead", "/bfs/%2e%2e/twirp/user.v1.User/UnknownRead",
    "/bfs/%2E%2E%2Ftwirp/user.v1.User/UnknownRead", "/bfs/%252e%252e/twirp/user.v1.User/UnknownRead",
    "/bfs/./synthetic.png", "/bfs/%5c..%5ctwirp/user.v1.User/UnknownRead" }) do
    test("active_image_rejects_path_escape_" .. (#report.tests + 1), false, false, function()
        local before = original_transport_calls
        local value, err = client:downloadImage({ url = "https://manga.bilibili.com" .. path }, output .. "/page.part")
        check("active image cannot escape the resource directory", not value and err.transmitted == false and original_transport_calls == before)
    end)
end
blocked("output_parent_segment_is_rejected", { url = asset, method = "GET", output_path = output .. "/.." })

for _, method in ipairs({ "validateSession", "listFavorites", "listHistory", "search", "comicDetail", "imageIndex", "imageTokens",
    "wallet", "purchaseInfo", "discountList", "discountPrice", "freeGoldCardInfo" }) do
    test("runner_admits_client_" .. method, false, true, function()
        local request, options, callback = { kind = "client", method = method }, {}, function() end
        local before = original_runner_calls
        local id = runner:submit(request, options, callback)
        check("read-only client job forwards unchanged", id and original_runner_calls == before + 1
            and current.runner_request == request and current.runner_options == options and current.runner_callback == callback)
    end)
end
for _, kind in ipairs({ "quote", "reconcile_purchase", "library", "download_page", "download_cover", "source_index", "verify_source_page", "diagnostics" }) do
    test("runner_admits_kind_" .. kind, false, true, function()
        local before = original_runner_calls
        check("approved read kind reaches the original", runner:submit({ kind = kind }, {}, function() end) ~= nil
            and original_runner_calls == before + 1)
    end)
end
for _, request in ipairs({ { kind = "purchase_submit" }, { kind = "set_favorite" }, { kind = "unknown" },
    { kind = "client", method = "buyEpisode" }, { kind = "client", method = "addHistory" },
    { kind = "client", method = "setFavorite" }, { kind = "client", method = "unknown" }, {} }) do
    test("runner_rejects_" .. tostring(request.kind) .. "_" .. tostring(request.method), false, false, function()
        local before, callbacks = original_runner_calls, 0
        local id, err = runner:submit(request, {}, function(value, failure)
            callbacks = callbacks + 1
            check("deferred denial is nontransmitted", value == nil and failure.kind == "verification_guard" and failure.transmitted == false)
        end)
        check("forbidden job is refused before original dispatch", id == nil and err.kind == "verification_guard"
            and err.transmitted == false and original_runner_calls == before and callbacks == 0)
        flush(); check("the refusal callback runs once", callbacks == 1)
    end)
end
report.passed = #report.tests > 0
for _, item in ipairs(report.tests) do report.passed = report.passed and item.passed end
report.transport_forwards, report.runner_forwards = original_transport_calls, original_runner_calls
report.counts = { cases = #report.tests, assertions = #report.assertions }
Files.write(result_path, json.encode(report, { pretty = true }))
print(json.encode({ passed = report.passed, counts = report.counts, transport_forwards = original_transport_calls, runner_forwards = original_runner_calls }))
if not report.passed then os.exit(1) end
