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
    current.transport_requests = current.transport_requests or {}
    current.transport_requests[#current.transport_requests + 1] = request
    if current.response_for then return current.response_for(request) end
    local body = current.response_body or '{"code":0,"data":{}}'
    return { status = 200, body = body, bytes = #body, transmitted = false }
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

local recommendations_url = "https://manga.bilibili.com/index.pageContext.json"
local function recommendationsRequest()
    return { url = recommendations_url, method = "GET", max_bytes = 4194304,
        headers = { accept = "application/json", referer = "https://manga.bilibili.com/", ["user-agent"] = "Synthetic" } }
end
allowed("anonymous_recommendations_exact_route", recommendationsRequest())
allowed("anonymous_recommendations_without_optional_headers", { url = recommendations_url, method = "GET" })
test("production_client_recommendations_isolates_synthetic_session", true, false, function()
    current.response_body = '{"pageId":"/pages/index","data":{"recommendation":{"comics":[]}}}'
    local before = original_transport_calls
    local value, err = client:recommendations()
    check("real Client recommendations pass through the guard", value and not err and value.source == "official_homepage"
        and value.personalized == false and #value.items == 0 and original_transport_calls == before + 1)
    check("the request is the exact anonymous GET", last_request.url == recommendations_url
        and last_request.method == "GET" and last_request.body == nil and last_request.output_path == nil)
    local anonymous = true
    for key in pairs(last_request.headers or {}) do
        key = tostring(key):lower()
        anonymous = anonymous and key ~= "cookie" and key ~= "authorization" and key ~= "proxy-authorization"
    end
    check("synthetic Client credentials never enter recommendation headers", anonymous)
end)
for _, method in ipairs({ "POST", "PUT", "PATCH", "DELETE", "HEAD", "get" }) do
    local request = recommendationsRequest(); request.method = method
    blocked("recommendations_rejects_method_" .. method, request)
end
for _, body in ipairs({ "", "{}", false, 0 }) do
    local request = recommendationsRequest(); request.body = body
    blocked("recommendations_rejects_body_" .. (#report.tests + 1), request)
end
for _, name in ipairs({ "Cookie", "cookie", "cOoKiE", "Authorization", "authorization", "aUtHoRiZaTiOn",
    "Proxy-Authorization", "x-api-key", "Host", "content-type" }) do
    local request = recommendationsRequest(); request.headers[name] = "synthetic"
    blocked("recommendations_rejects_header_" .. name, request)
end
for _, headers in ipairs({ { accept = "application/json\r\nCookie: synthetic" }, { accept = false },
    { accept = "application/json", Accept = "application/json" }, false, "accept: application/json" }) do
    local request = recommendationsRequest(); request.headers = headers
    blocked("recommendations_rejects_malformed_headers_" .. (#report.tests + 1), request)
end
for _, url in ipairs({ recommendations_url .. "?", recommendations_url .. "?device=pc", recommendations_url .. "/",
    recommendations_url .. "#fragment", "http://manga.bilibili.com/index.pageContext.json",
    "https://manga.bilibili.com:443/index.pageContext.json", "https://manga.bilibili.com.evil.invalid/index.pageContext.json",
    "https://manga.bilibili.com/other.pageContext.json", "https://manga.bilibili.com/%69ndex.pageContext.json",
    "https://manga.bilibili.com/a/../index.pageContext.json" }) do
    local request = recommendationsRequest(); request.url = url
    blocked("recommendations_rejects_route_variant_" .. (#report.tests + 1), request)
end
local recommendations_output = recommendationsRequest(); recommendations_output.output_path = output .. "/recommendations.json"
blocked("recommendations_rejects_output_file", recommendations_output)
for _, limit in ipairs({ 0, -1, 1.5, 4194305, "4194304", false }) do
    local request = recommendationsRequest(); request.max_bytes = limit
    blocked("recommendations_rejects_invalid_limit_" .. (#report.tests + 1), request)
end

local category_m2 = "error:BiliComics local reader has no browser fingerprint environment_1789171200000"
local category_sn = "1E74C20E5720FBF3BB351965D7A9DFC1"
local category_buvid_url = "https://manga.bilibili.com/ductape/buvid"
local category_test_start = #report.tests
local function categoryRequest(kind)
    local headers = { accept = "application/json, text/plain, */*", referer = "https://manga.bilibili.com/",
        ["user-agent"] = "Synthetic" }
    if kind == "buvid" then return { url = category_buvid_url, method = "GET", headers = headers, max_bytes = 1048576 } end
    headers.origin, headers["content-type"] = "https://manga.bilibili.com", "application/json;charset=UTF-8"
    local request = rpc("comic.v1.Comic/" .. (kind == "labels" and "AllLabel" or "ClassPage"), {})
    request.headers, request.max_bytes = headers, 8388608
    if kind == "page" then
        request.url = request.url .. "&ultra_sign=synthetic-sign"
        headers.cookie, headers["x-bili-data-sn"] = "buvid3=synthetic-server-issued", category_sn
        request.body = assert(JSON.encode({ style_id = 101, area_id = -1, is_finish = -1, is_free = -1,
            special_tag = 0, order = 0, page_num = 1, page_size = 18, m2 = category_m2 }))
    end
    return request
end
local function categoryBodyRequest(changes, missing)
    local request = categoryRequest("page")
    local body = assert(JSON.decode(request.body))
    for key, value in pairs(changes or {}) do body[key] = value end
    if missing then body[missing] = nil end
    request.body = assert(JSON.encode(body))
    return request
end
allowed("category_labels_exact_anonymous_route", categoryRequest("labels"))
allowed("category_buvid_exact_anonymous_route", categoryRequest("buvid"))
for _, sort in ipairs({ 0, 1, 3 }) do
    for _, page in ipairs({ 1, 5 }) do
        allowed("category_page_bounded_sort_" .. sort .. "_page_" .. page, categoryBodyRequest({ order = sort, page_num = page }))
    end
end
allowed("category_page_maximum_identifier", categoryBodyRequest({ style_id = 999999999999999 }))
local escaped_signature = categoryRequest("page")
escaped_signature.url = escaped_signature.url:gsub("synthetic%-sign", "synthetic%%2B%%2F%%3Dsignature")
allowed("category_page_percent_escaped_signature", escaped_signature)
local mixed_headers = categoryRequest("page")
mixed_headers.headers.Cookie, mixed_headers.headers.cookie = mixed_headers.headers.cookie, nil
mixed_headers.headers["X-Bili-Data-Sn"], mixed_headers.headers["x-bili-data-sn"] = category_sn, nil
allowed("category_page_single_case_insensitive_headers", mixed_headers)
for _, kind in ipairs({ "labels", "buvid", "page" }) do
    for _, method in ipairs({ "PUT", "DELETE", "PATCH", "HEAD", "post", kind == "buvid" and "POST" or "GET" }) do
        local request = categoryRequest(kind); request.method = method
        blocked("category_" .. kind .. "_rejects_method_" .. method, request)
    end
    for _, header in ipairs({ "Authorization", "Proxy-Authorization", "x-api-key", "x-xsrf-token", "SESSDATA", "bili_jct",
        "Host", "Content-Length", "Transfer-Encoding" }) do
        local request = categoryRequest(kind); request.headers[header] = "synthetic"
        blocked("category_" .. kind .. "_rejects_header_" .. header, request)
    end
    for _, headers in ipairs({ false, "accept: application/json", { [1] = "synthetic" },
        { referer = "https://manga.bilibili.com/", accept = "application/json\r\nCookie: synthetic" },
        { referer = "https://manga.bilibili.com/", accept = false } }) do
        local request = categoryRequest(kind); request.headers = headers
        blocked("category_" .. kind .. "_rejects_malformed_headers_" .. (#report.tests + 1), request)
    end
    local duplicate_header = categoryRequest(kind); duplicate_header.headers.Accept = duplicate_header.headers.accept
    blocked("category_" .. kind .. "_rejects_duplicate_header", duplicate_header)
    for _, origin in ipairs({ "https://manga.bilibili.com.evil.invalid/", "https://www.bilibili.com/" }) do
        local request = categoryRequest(kind); request.headers.referer = origin
        blocked("category_" .. kind .. "_rejects_foreign_referer_" .. (#report.tests + 1), request)
    end
    for _, limit in ipairs({ false, 0, -1, 0.5, "8388608", 8388609 }) do
        local request = categoryRequest(kind); request.max_bytes = limit
        blocked("category_" .. kind .. "_rejects_invalid_limit_" .. (#report.tests + 1), request)
    end
    for _, destination in ipairs({ false, output .. "/category.json" }) do
        local request = categoryRequest(kind); request.output_path = destination
        blocked("category_" .. kind .. "_rejects_output_" .. (#report.tests + 1), request)
    end
    local valid_url = categoryRequest(kind).url
    for _, url in ipairs({ valid_url .. "&csrf=synthetic", valid_url .. "#fragment", valid_url:gsub("^https:", "http:"),
        valid_url:gsub("manga%.bilibili%.com", "manga.bilibili.com.evil.invalid"),
        valid_url:gsub("manga%.bilibili%.com", "manga.bilibili.com:443"),
        valid_url:gsub("/comic%.v1%.Comic/", "/comic.v1.Comic/../comic.v1.Comic/"),
        (valid_url:gsub("/ductape/", "/ductape/../ductape/")) }) do
        if url ~= valid_url then
            local request = categoryRequest(kind); request.url = url
            blocked("category_" .. kind .. "_rejects_route_variant_" .. (#report.tests + 1), request)
        end
    end
end
for _, kind in ipairs({ "labels", "buvid" }) do
    for _, cookie in ipairs({ "buvid3=synthetic", "SESSDATA=synthetic", "bili_jct=synthetic" }) do
        local request = categoryRequest(kind); request.headers.Cookie = cookie
        blocked("category_" .. kind .. "_rejects_every_cookie_" .. (#report.tests + 1), request)
    end
end
for _, body in ipairs({ "", " {}", "{ }", "[]", "null", '{"csrf":"synthetic"}', false, 0 }) do
    local request = categoryRequest("labels"); request.body = body
    blocked("category_labels_rejects_nonempty_or_noncanonical_body_" .. (#report.tests + 1), request)
end
local no_labels_body = categoryRequest("labels"); no_labels_body.body = nil
blocked("category_labels_requires_empty_object_body", no_labels_body)
for _, body in ipairs({ "", "{}", false, 0 }) do
    local request = categoryRequest("buvid"); request.body = body
    blocked("category_buvid_rejects_any_body_" .. (#report.tests + 1), request)
end
for _, suffix in ipairs({ "?", "?device=pc", "?buvid3=synthetic", "/", "?csrf=synthetic" }) do
    local request = categoryRequest("buvid"); request.url = request.url .. suffix
    blocked("category_buvid_rejects_route_suffix_" .. (#report.tests + 1), request)
end
for _, kind in ipairs({ "labels", "page" }) do
    local request = categoryRequest(kind); request.headers.origin = "https://www.bilibili.com"
    blocked("category_" .. kind .. "_rejects_foreign_origin", request)
    request = categoryRequest(kind); request.headers["content-type"] = "application/x-www-form-urlencoded"
    blocked("category_" .. kind .. "_rejects_form_content_type", request)
end
for _, cookie in ipairs({ "", "buvid3=", "BUVID3=synthetic", "SESSDATA=synthetic", "bili_jct=synthetic",
    "buvid4=synthetic", "buvid3=synthetic; SESSDATA=synthetic", "buvid3=synthetic; bili_jct=synthetic",
    "buvid3=synthetic; buvid3=duplicate", "buvid3=synthetic,other", "buvid3=synthetic value",
    "buvid3=\"synthetic\"", "buvid3=synthetic\\other", "buvid3=synthetic\r\nAuthorization: synthetic",
    "buvid3=" .. string.rep("a", 257) }) do
    local request = categoryRequest("page"); request.headers.cookie = cookie
    blocked("category_page_rejects_cookie_" .. (#report.tests + 1), request)
end
local no_cookie = categoryRequest("page"); no_cookie.headers.cookie = nil
blocked("category_page_requires_anonymous_buvid_cookie", no_cookie)
local duplicate_cookie = categoryRequest("page"); duplicate_cookie.headers.Cookie = duplicate_cookie.headers.cookie
blocked("category_page_rejects_duplicate_cookie_header", duplicate_cookie)
local duplicate_sn = categoryRequest("page"); duplicate_sn.headers["X-Bili-Data-Sn"] = category_sn
blocked("category_page_rejects_duplicate_data_sn_header", duplicate_sn)
for _, serial in ipairs({ "", "synthetic", category_sn:lower(), false }) do
    local request = categoryRequest("page"); request.headers["x-bili-data-sn"] = serial
    blocked("category_page_rejects_invalid_data_sn_" .. (#report.tests + 1), request)
end
local no_sn = categoryRequest("page"); no_sn.headers["x-bili-data-sn"] = nil
blocked("category_page_requires_data_sn", no_sn)
for _, suffix in ipairs({ "", "&ultra_sign=", "&ultra_sign=synthetic&ultra_sign=duplicate", "&%75ltra_sign=synthetic",
    "&ultra_sign=%", "&ultra_sign=%GG", "&ultra_sign=%0D%0A", "&ultra_sign=synthetic&cpx=1",
    "&ultra_sign=synthetic&m1=synthetic", "&ultra_sign=synthetic&getEpisodeDiscounts", "&ultra_sign=synthetic&device=pc",
    "&ultra_sign=synthetic&", "&&ultra_sign=synthetic", "&ultra_sign=" .. string.rep("a", 8193) }) do
    local request = categoryRequest("page"); request.url = base .. "comic.v1.Comic/ClassPage" .. query .. suffix
    blocked("category_page_rejects_signature_query_" .. (#report.tests + 1), request)
end
for _, kind in ipairs({ "labels", "page" }) do
    local request = categoryRequest(kind); request.url = request.url:gsub("device=pc", "device=mobile")
    blocked("category_" .. kind .. "_requires_exact_device", request)
    request = categoryRequest(kind); request.url = request.url:gsub("nov=27", "nov=28")
    blocked("category_" .. kind .. "_requires_pinned_version", request)
end
for _, change in ipairs({ { style_id = 0 }, { style_id = -1 }, { style_id = 1.5 }, { style_id = "101" },
    { style_id = 1000000000000000 }, { area_id = 0 }, { is_finish = 0 }, { is_free = 0 }, { special_tag = 1 },
    { order = -1 }, { order = 2 }, { order = "0" }, { page_num = 0 }, { page_num = 6 }, { page_num = 1.5 },
    { page_num = "1" }, { page_size = 1 }, { page_size = 100 }, { page_size = "18" },
    { m2 = "" }, { m2 = "synthetic" }, { m2 = category_m2 .. "_extra" }, { m2 = category_m2 .. "\n" },
    { m2 = false }, { m2 = {} }, { m2 = "error:BiliComics local reader has no browser fingerprint environment_" .. string.rep("1", 32769) },
    { buy_method = 3 }, { pay_amount = 0 }, { csrf = "synthetic" }, { comic_id = 101 } }) do
    blocked("category_page_rejects_body_mutation_" .. (#report.tests + 1), categoryBodyRequest(change))
end
for _, key in ipairs({ "style_id", "area_id", "is_finish", "is_free", "special_tag", "order", "page_num", "page_size", "m2" }) do
    blocked("category_page_requires_body_" .. key, categoryBodyRequest(nil, key))
end
for _, body in ipairs({ "[]", "null", "{}", "{", false, 0 }) do
    local request = categoryRequest("page"); request.body = body
    blocked("category_page_rejects_malformed_body_" .. (#report.tests + 1), request)
end
for _, extra in ipairs({ '"style_id":0,', '"style_id":101,', '"\\u0073tyle_id":101,' }) do
    local request = categoryRequest("page"); request.body = "{" .. extra .. request.body:sub(2)
    blocked("category_page_rejects_duplicate_or_escaped_body_key_" .. (#report.tests + 1), request)
end
local duplicate_suffix = categoryRequest("page")
duplicate_suffix.body = duplicate_suffix.body:sub(1, -2) .. ',"style_id":0}'
blocked("category_page_rejects_duplicate_body_key_at_end", duplicate_suffix)
local escaped_key = categoryRequest("page"); escaped_key.body = escaped_key.body:gsub('"style_id"', '"\\u0073tyle_id"')
blocked("category_page_rejects_escaped_body_key", escaped_key)
for _, position in ipairs({ "prefix", "middle", "suffix" }) do
    local request = categoryRequest("page")
    if position == "prefix" then request.body = "{," .. request.body:sub(2)
    elseif position == "suffix" then request.body = request.body:sub(1, -2) .. ",}"
    else request.body = request.body:gsub(",", ",,", 1) end
    blocked("category_page_rejects_extra_separator_" .. position, request)
end
for _, key in ipairs({ "SESSDATA", "bili_jct", "authorization", "buy_method", "pay_amount" }) do
    local request = categoryRequest("page"); request.body = request.body:sub(1, -2) .. ',"' .. key .. '":0}'
    blocked("category_page_rejects_credential_or_write_body_" .. key, request)
end
local function syntheticCategoryResponse(body, headers)
    body = type(body) == "string" and body or assert(JSON.encode(body))
    return { status = 200, body = body, bytes = #body, headers = headers or {}, transmitted = false }
end
test("production_client_category_metadata_isolates_synthetic_session", true, false, function()
    local before, parent_session = original_transport_calls, client.session
    current.response_for = function(request)
        check("metadata uses only its exact official route", request.url == base .. "comic.v1.Comic/AllLabel" .. query
            and request.body == "{}" and request.headers.cookie == nil and request.headers.authorization == nil)
        return syntheticCategoryResponse({ code = 0, data = { styles = { { id = 101, name = "Synthetic category" } },
            orders = { { id = 0, name = "Popular" }, { id = 1, name = "Updated" }, { id = 3, name = "New" } } } },
            { ["set-cookie"] = "SESSDATA=synthetic-response-cookie; Path=/" })
    end
    local value, err = client:bookstoreCategories()
    check("real Client metadata passes through the guard once", value and not err and value.source == "official_categories"
        and #value.items == 1 and value.items[1].id == "101" and #value.orders == 3 and original_transport_calls == before + 1)
    check("metadata never captures a response account cookie", client.session == parent_session
        and client.session.cookies.SESSDATA == "synthetic-not-an-account" and not client._session_changed)
end)
local function categoryClient()
    local Native = require("bilicomics/protocol/native_backend")
    return Client.new{ transport = transport, clock = function() return 1789171200 end,
        session = { cookies = { SESSDATA = "synthetic-parent-account", bili_jct = "synthetic-parent-csrf",
            buvid3 = "synthetic-parent-buvid", ["XSRF-TOKEN"] = "synthetic-parent-xsrf" } },
        crypto = {
            prepareCatalog = function(_, context)
                current.category_preparation = Native.prepareCatalog({}, context)
                return current.category_preparation
            end,
            signRequest = function(_, context)
                current.category_signed_context = context
                return { ultra_sign = "synthetic+/=signature", data_sn = category_sn }
            end,
        } }
end
local function categoryProductionResponse(request)
    current.category_device_count = current.category_device_count or 0
    if request.url == category_buvid_url then
        current.category_device_count = current.category_device_count + 1
        current.category_current_device = "synthetic-device-" .. current.category_device_count
        check("each device request has no body or credentials", request.method == "GET" and request.body == nil
            and request.headers.cookie == nil and request.headers.authorization == nil)
        return syntheticCategoryResponse({}, { ["set-cookie"] = {
            "buvid3=" .. current.category_current_device .. "; Path=/; HttpOnly",
            "SESSDATA=synthetic-unrelated-device-cookie; Path=/",
            "bili_jct=synthetic-unrelated-device-csrf; Path=/",
        } })
    end
    check("real Client signs the exact category route", request.url == base .. "comic.v1.Comic/ClassPage" .. query
        .. "&ultra_sign=synthetic%2B%2F%3Dsignature" and request.headers["x-bili-data-sn"] == category_sn)
    check("only the current server-issued synthetic buvid enters the page", request.headers.cookie == "buvid3=" .. current.category_current_device
        and request.headers["x-xsrf-token"] == nil and request.headers.authorization == nil)
    local signed = current.category_signed_context
    check("guard forwards the exact signed body and device context", signed and signed.body == request.body
        and signed.buvid == current.category_current_device and signed.endpoint == "ClassPage")
    local body = assert(JSON.decode(request.body))
    check("the real native catalog preparation is preserved in the signed body", body.m2 == current.category_preparation.m2
        and body.m2 == category_m2 and current.category_preparation.challenge_status == "environment_error_reported")
    return syntheticCategoryResponse({ code = 0, data = { { type = 0, season_id = 9101, title = "Synthetic comic",
        vertical_cover = "https://i0.hdslb.com/bfs/manga/synthetic.jpg", is_finish = 0, author = { "Synthetic author" } } } },
        { ["set-cookie"] = "SESSDATA=synthetic-unrelated-page-cookie; Path=/" })
end
for _, sort in ipairs({ 0, 1, 3 }) do
    test("production_client_category_pages_isolate_session_sort_" .. sort, true, false, function()
        local category_client, before = categoryClient(), original_transport_calls
        local parent_session = category_client.session
        current.response_for = categoryProductionResponse
        for _, page in ipairs({ 1, 5 }) do
            local value, err = category_client:bookstoreCategoryPage({ kind = "category", category_id = "101", sort = sort }, page)
            check("real Client category page crosses the guard and normalizes comics", value and not err and value.source == "official_category"
                and value.personalized == false and value.page == page and value.page_size == 18 and #value.items == 1
                and value.items[1].id == "9101" and value.query.kind == "category" and value.query.category_id == "101" and value.query.sort == sort)
            local body = assert(JSON.decode(last_request.body))
            check("the selected page and sort remain within the admitted body", body.page_num == page and body.order == sort and body.style_id == 101)
        end
        check("every category page obtains one fresh anonymous device", current.category_device_count == 2 and original_transport_calls == before + 4)
        check("category reads never replace or mutate the synthetic parent session", category_client.session == parent_session
            and parent_session.cookies.SESSDATA == "synthetic-parent-account" and parent_session.cookies.bili_jct == "synthetic-parent-csrf"
            and parent_session.cookies.buvid3 == "synthetic-parent-buvid" and not category_client._session_changed)
    end)
end
test("production_client_category_never_inspects_parent_session", true, false, function()
    local category_client = categoryClient()
    category_client.session = setmetatable({}, { __index = function() error("Category reads must not inspect a parent session") end })
    current.response_for = categoryProductionResponse
    local value, err = category_client:bookstoreCategoryPage({ category_id = 101 })
    check("category defaults produce a complete canonical query without touching the parent session", value and not err
        and value.query.kind == "category" and value.query.category_id == "101" and value.query.sort == 0 and value.page == 1)
end)
report.category_contract = { case_count = #report.tests - category_test_start, source = "official_categories",
    exact_public_metadata_route = true, exact_anonymous_buvid_route = true, isolated_signed_page_route = true,
    actual_native_m2_shape_only = true, single_anonymous_buvid_cookie_only = true,
    signed_body_forwarded_unchanged = true, native_catalog_preparation = true, synthetic_signing_adapter = true,
    real_client_constructs_category_requests = true, fresh_server_device_for_each_page = true,
    parent_session_not_inspected_or_mutated = true, server_issued_buvid_provenance_is_production_client_responsibility = true }

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
local auth_origin = { referer = "https://www.bilibili.com/", origin = "https://www.bilibili.com" }
local function authRequest(path, body, host, credentials)
    local headers = {}; for key, value in pairs(auth_origin) do headers[key] = value end
    if credentials then headers.cookie = "SESSDATA=synthetic; bili_jct=synthetic" end
    if body then headers["content-type"] = "application/x-www-form-urlencoded" end
    return { url = "https://" .. (host or "passport.bilibili.com") .. path,
        method = body and "POST" or "GET", body = body, headers = headers, max_bytes = 262144 }
end
local auth_generate = "/x/passport-login/web/qrcode/generate?source=main_web&go_url=https%3A%2F%2Fmanga.bilibili.com%2F"
local auth_poll = "/x/passport-login/web/qrcode/poll?qrcode_key=synthetic_key&source=main_web"
local auth_info = "/x/passport-login/web/cookie/info?csrf=synthetic"
local auth_refresh = "/x/passport-login/web/cookie/refresh"
local auth_confirm = "/x/passport-login/web/confirm/refresh"
local refresh_body = "csrf=synthetic&refresh_csrf=synthetic&source=main_web&refresh_token=synthetic"
local confirm_body = "csrf=synthetic&refresh_token=synthetic"
allowed("auth_qr_generate", authRequest(auth_generate))
allowed("auth_qr_poll", authRequest(auth_poll))
allowed("auth_cookie_info", authRequest(auth_info, nil, nil, true))
allowed("auth_correspondence", authRequest("/correspond/1/" .. string.rep("a", 256), nil, "www.bilibili.com", true))
allowed("auth_refresh", authRequest(auth_refresh, refresh_body, nil, true))
allowed("auth_confirm", authRequest(auth_confirm, confirm_body, nil, true))
for _, path in ipairs({ auth_generate .. "&source=main_web", auth_generate .. "&pay_amount=0",
    auth_poll .. "&refresh_token=synthetic", auth_poll:gsub("synthetic_key", "bad%%0Akey"),
    auth_info .. "&csrf=duplicate", "/x/passport-login/web/logout", "/x/passport-login/web/cookie/refresh/extra" }) do
    blocked("auth_rejects_path_or_query_" .. (#report.tests + 1), authRequest(path))
end
for _, body in ipairs({ refresh_body .. "&buy_method=3", refresh_body .. "&csrf=duplicate",
    refresh_body:gsub("source=main_web", "source=other"), refresh_body:gsub("refresh_token=synthetic", "refresh_token="),
    refresh_body:gsub("refresh_token=synthetic", "refresh_token=bad%%0Avalue"),
    refresh_body:gsub("refresh_token=synthetic", "refresh_token=bad%%GG"),
    "csrf=synthetic&refresh_token=synthetic", "{}" }) do
    blocked("auth_rejects_refresh_form_" .. (#report.tests + 1), authRequest(auth_refresh, body, nil, true))
end
blocked("auth_info_requires_cookies", authRequest(auth_info))
blocked("auth_generate_rejects_cookies", authRequest(auth_generate, nil, nil, true))
blocked("auth_refresh_requires_cookies", authRequest(auth_refresh, refresh_body))
blocked("auth_confirm_rejects_extra_fields", authRequest(auth_confirm, confirm_body .. "&source=main_web", nil, true))
blocked("auth_challenge_rejects_short_hex", authRequest("/correspond/1/abcd", nil, "www.bilibili.com", true))
blocked("auth_challenge_rejects_query", authRequest("/correspond/1/" .. string.rep("a", 256) .. "?csrf=x", nil, "www.bilibili.com", true))
local invalid_auth = authRequest(auth_refresh, refresh_body, nil, true)
invalid_auth.headers.origin = "https://unrelated.invalid"
blocked("auth_rejects_foreign_origin", invalid_auth)
invalid_auth = authRequest(auth_refresh, refresh_body, nil, true); invalid_auth.output_path = output .. "/auth.json"
blocked("auth_rejects_output_file", invalid_auth)
invalid_auth = authRequest(auth_refresh, refresh_body, nil, true); invalid_auth.headers.authorization = "synthetic"
blocked("auth_rejects_unexpected_header", invalid_auth)
invalid_auth = authRequest(auth_refresh, refresh_body, nil, true); invalid_auth.method = "GET"
blocked("auth_rejects_wrong_method", invalid_auth)
for _, method in ipairs({ "generateQR", "pollQR", "cookieInfo", "refreshSession", "confirmRefresh" }) do
    test("runner_admits_auth_" .. method, false, true, function()
        local before = original_runner_calls
        check("approved authentication job reaches the original", runner:submit({ kind = "auth", method = method }, {}, function() end) ~= nil
            and original_runner_calls == before + 1)
    end)
end
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

for _, method in ipairs({ "validateSession", "listFavorites", "listHistory", "recommendations", "bookstoreCategories", "bookstoreCategoryPage", "search", "comicDetail", "imageIndex", "imageTokens",
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
    { kind = "auth", method = "logout" }, { kind = "auth", method = "buyEpisode" }, { kind = "auth" },
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
