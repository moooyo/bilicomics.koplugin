-- Exercise real request construction and strict live-scope decisions without networking.
require("setupkoenv")
local source, output, reading_guard_path = assert(arg[1]), assert(arg[2]), arg[3]
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local JSON = require("rapidjson")
local Scope = assert(loadfile(source .. "/spec/integration/live_acceptance_scope.lua"))()
local Transport = require("bilicomics/protocol/transport")
Transport.request = function() error("Real transport is forbidden in these checks") end
local checks = {}
local function check(name, value)
    checks[#checks + 1] = { name = name, passed = value == true }
    assert(value, name)
end
local function copy(value)
    local result = {}
    for key, item in pairs(value) do result[key] = type(item) == "table" and copy(item) or item end
    return result
end
local buvid = { url = "https://manga.bilibili.com/ductape/buvid", method = "GET",
    headers = { ["user-agent"] = "synthetic", accept = "application/json", referer = "https://manga.bilibili.com/" } }
for _, phase in ipairs({ "login", "restart", "reading" }) do
    check("exact_anonymous_site_context_" .. phase, Scope.transportCategory(buvid, phase) == "site_context")
end
for _, phase in ipairs({ "offline", "rehearse", "unknown" }) do
    check("no_site_context_" .. phase, Scope.transportCategory(buvid, phase) == nil)
end
for name, mutate in pairs({
    cookie = function(value) value.headers.cookie = "SESSDATA=synthetic" end,
    authorization = function(value) value.headers.authorization = "synthetic" end,
    duplicate_header = function(value) value.headers.Referer = value.headers.referer end,
    body = function(value) value.body = "" end,
    query = function(value) value.url = value.url .. "?x=1" end,
    output = function(value) value.output_path = "/tmp/synthetic" end,
    fragment = function(value) value.url = value.url .. "#x" end,
    userinfo = function(value) value.url = "https://user@manga.bilibili.com/ductape/buvid" end,
    suffix_host = function(value) value.url = "https://manga.bilibili.com.example/ductape/buvid" end,
    explicit_port = function(value) value.url = "https://manga.bilibili.com:443/ductape/buvid" end,
    encoded_path = function(value) value.url = "https://manga.bilibili.com/ductape/%62uvid" end,
    newline = function(value) value.headers.accept = "application/json\r\nx-test: x" end,
    wrong_referer = function(value) value.headers.referer = "https://www.bilibili.com/" end,
    post = function(value) value.method = "POST" end,
}) do
    local request = copy(buvid); mutate(request)
    check("reject_site_context_" .. name, Scope.transportCategory(request, "login") == nil)
end
local requests = {}
local fake = { request = function(_, request)
    requests[#requests + 1] = request
    return { status = 503, body = "{}", headers = {}, transmitted = true }
end }
local session = { cookies = { SESSDATA = "synthetic", bili_jct = "synthetic-csrf", DedeUserID = "42" } }
local Auth = require("bilicomics/protocol/auth")
local auth = Auth.new{ transport = fake, session = session }
auth:generateQR()
check("production_qr_generation_request", Scope.transportCategory(requests[#requests], "login") == "qr_generate")
auth:pollQR("synthetic_key")
check("production_qr_poll_request", Scope.transportCategory(requests[#requests], "login") == "qr_poll")
auth:cookieInfo()
local info_request = copy(requests[#requests])
check("production_cookie_info_request", Scope.transportCategory(info_request, "restart") == "cookie_info")
local malformed_info = copy(info_request); malformed_info.url = malformed_info.url .. "&csrf=other"
check("duplicate_cookie_info_csrf_rejected", Scope.transportCategory(malformed_info, "restart") == nil)
local Client = require("bilicomics/protocol/client")
local client = Client.new{ transport = fake, session = session }
client:validateSession()
check("production_identity_request", Scope.transportCategory(requests[#requests], "reading") == "identity_check")
client:listFavorites({ page_num = 2, page_size = 50 })
local favorite_request = copy(requests[#requests])
check("production_favorites_page_request", Scope.transportCategory(favorite_request, "login") == "library_favorites")
client:listHistory({ page_num = 1, page_size = 50 })
check("production_history_request", Scope.transportCategory(requests[#requests], "login") == "library_history")
for _, field in ipairs({ "page_num", "page_size", "type", "order", "source" }) do
    local request = copy(favorite_request)
    local body = assert(JSON.decode(request.body)); body[field] = field == "page_num" and 201 or -1
    request.body = JSON.encode(body)
    check("reject_library_" .. field, Scope.transportCategory(request, "login") == nil)
end
for _, path in ipairs({ "/x/passport-login/web/cookie/refresh", "/x/passport-login/web/confirm/refresh" }) do
    local request = copy(info_request)
    request.url, request.method, request.body = "https://passport.bilibili.com" .. path, "POST", "csrf=synthetic&refresh_token=synthetic"
    for _, phase in ipairs({ "login", "restart", "reading" }) do
        check("rotation_transport_denied_" .. path .. "_" .. phase, Scope.transportCategory(request, phase) == nil)
    end
end
check("refresh_challenge_denied", Scope.transportCategory({
    url = "https://www.bilibili.com/correspond/1/" .. string.rep("a", 256), method = "GET", headers = info_request.headers }, "restart") == nil)
local known = { refresh = false, timestamp = 1000 }
check("no_refresh_maintenance_admitted", Scope.submissionName({ kind = "auth", method = "refreshSession",
    arguments = { { info = known } } }, "restart", known) == "refreshSession")
for name, info in pairs({ required = { refresh = true, timestamp = 1000 }, unbound = {},
    wrong_timestamp = { refresh = false, timestamp = 999 } }) do
    check("rotation_submission_denied_" .. name, Scope.submissionName({ kind = "auth", method = "refreshSession",
        arguments = { { info = info } } }, "restart", known) == nil)
end
check("confirmation_submission_denied", Scope.submissionName({ kind = "auth", method = "confirmRefresh" }, "restart", known) == nil)
check("site_context_submission_admitted", Scope.submissionName({ kind = "auth", method = "ensureSiteContext" }, "reading") == "ensureSiteContext")
check("offline_auth_submission_denied", Scope.submissionName({ kind = "auth", method = "ensureSiteContext" }, "offline") == nil)
check("offline_library_submission_denied", Scope.submissionName({ kind = "library", library = "favorites" }, "offline") == nil)
check("unknown_auth_submission_denied", Scope.submissionName({ kind = "auth", method = "unexpected" }, "login") == nil)
check("refresh_true_defers", Scope.rotationDeferred({ refresh = true }) == true)
check("refresh_false_does_not_defer", Scope.rotationDeferred(known) == false)
local cover = { url = "https://i0.hdslb.com/bfs/manga/synthetic.jpg@480w.jpg", method = "GET",
    headers = { ["user-agent"] = "synthetic" }, output_path = "/tmp/private/synthetic.part", max_bytes = 4194304 }
local approved = { [cover.url] = cover.output_path }
check("declared_cover_admitted", Scope.coverAllowed(cover, approved))
local changed = copy(cover); changed.headers.cookie = "SESSDATA=synthetic"
check("cover_cookie_denied", not Scope.coverAllowed(changed, approved))
changed = copy(cover); changed.output_path = "/tmp/unapproved.part"
check("cover_destination_denied", not Scope.coverAllowed(changed, approved))
changed = copy(cover); changed.url = changed.url .. "?new=1"
check("cover_address_denied", not Scope.coverAllowed(changed, approved))
for _, address in ipairs({
    "https://passport.bilibili.com/x/passport-login/web/cookie/refresh",
    "https://passport.bilibili.com/x/passport-login/web/confirm/refresh",
    "https://www.bilibili.com/correspond/1/" .. string.rep("a", 256),
    "https://www.bilibili.com/%63orrespond/1/" .. string.rep("a", 256),
}) do
    changed = copy(cover); changed.url = address
    check("credential_route_cannot_be_a_declared_cover_" .. address,
        not Scope.coverAllowed(changed, { [address] = changed.output_path }))
end
if reading_guard_path then
    local Files = require("bilicomics/storage/files")
    local work = output .. ".guard"
    Files.mkdir(work)
    local selection = { comic_id = "1", episode_id = "2", approved_source_paths = { "a", "b", "c", "d", "e", "f" },
        approved_cover_url = "https://i0.hdslb.com/bfs/manga/synthetic.jpg" }
    local factory = assert(loadfile(reading_guard_path))()
    local guard = factory(selection, { phase = "online", work = work, private_root = work, auth_scope = Scope })
    for name, request in pairs({ site_context = buvid, cookie_info = info_request, library = favorite_request }) do
        local permitted, category = guard:before(request)
        check("reading_guard_admits_" .. name, permitted == true and category == "metadata")
        guard:after(request, { status = 200 }, nil)
    end
    local rendered_cover = copy(cover); rendered_cover.output_path = work .. "/visible.part"
    check("reading_guard_declares_visible_cover", guard:approveCover(rendered_cover.url, rendered_cover.output_path))
    local permitted, category = guard:before(rendered_cover)
    check("reading_guard_admits_declared_cover", permitted == true and category == "cover_image")
    guard:after(rendered_cover, { status = 200 }, nil)
    local offline = factory(selection, { phase = "offline", work = work, private_root = work, auth_scope = Scope })
    check("offline_guard_rejects_site_context", offline:before(buvid) == nil)
    check("offline_guard_rejects_cookie_info", offline:before(info_request) == nil)
    check("offline_guard_rejects_library", offline:before(favorite_request) == nil)
    check("offline_guard_rejects_cover", offline:before(rendered_cover) == nil)
end
local result = { passed = true, scope = "Synthetic construction with production Auth/Client and no real transport",
    real_network_requests = 0, checks = checks, assertions = #checks, constructed_requests = #requests }
local handle = assert(io.open(output, "wb")); handle:write(JSON.encode(result)); assert(handle:close())
print(JSON.encode({ passed = true, assertions = #checks, real_network_requests = 0 }))
