-- Verify QR and persisted-session site initialization with synthetic responses only.
require("setupkoenv")
local root, output = assert(arg[1]), assert(arg[2])
package.path = root .. "/?.lua;" .. package.path
local Auth = require("bilicomics/protocol/auth")
local Site = require("bilicomics/protocol/site_context")
local Session = require("bilicomics/protocol/session")
local JSON = require("bilicomics/protocol/json")
local Codec = require("bilicomics/storage/codec")
local Transport = require("bilicomics/protocol/transport")
local Worker = require("bilicomics/jobs/worker")
local NOW = 1800000000
local report = { passed = false, assertions = 0, cases = {}, fake_requests = 0,
    real_accounts_used = false, real_network_requests = 0 }

local function check(value, message)
    report.assertions = report.assertions + 1
    assert(value, message or "Site-context contract assertion failed")
end
local function test(name, callback)
    local ok, err = pcall(callback)
    report.cases[#report.cases + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    print((ok and "PASS " or "FAIL ") .. name .. (not ok and ": " .. tostring(err) or ""))
end
local function initial()
    return Session.new{ cookies = { SESSDATA = "synthetic-existing", bili_jct = "synthetic-csrf", DedeUserID = "42", buvid4 = "existing-v4" },
        cookie_domains = { SESSDATA = "bilibili.com" }, account_key = "bili_42", identity = { id = "42", name = "Synthetic account" },
        imported_at = NOW - 100, validated_at = NOW - 50, refresh_token = "synthetic-current-token",
        pending_refresh_token = "synthetic-previous-token", refresh_checked_at = NOW - 10, last_refreshed_at = NOW - 20,
        cookie_expires_at = NOW + 3600, credential_generation = 7, refresh_blocked = true, confirmation_blocked = true }
end
local function response(data, headers)
    return { status = 200, transmitted = true, body = assert(JSON.encode({ code = 0, data = data })), headers = headers or {} }
end
local function device(line)
    return { status = 200, transmitted = true, body = "{}", headers = { ["set-cookie"] = line or
        "buvid3=server-issued-device; Domain=.bilibili.com; Path=/; Max-Age=3600" } }
end
local function confirmation(extra)
    local cookies = { "SESSDATA=synthetic-qr-session; Domain=.bilibili.com; Path=/", "bili_jct=synthetic-qr-csrf; Domain=.bilibili.com; Path=/",
        "DedeUserID=42; Domain=.bilibili.com; Path=/" }
    if extra then cookies[#cookies + 1] = extra end
    return response({code=0,refresh_token="synthetic-qr-refresh"},{["set-cookie"]=cookies})
end
local function nav(headers, mid)
    return response({isLogin=true,mid=mid or 42,uname="Validated account"},headers)
end
local function fixture(sequence, session)
    local transport = { requests = {}, sequence = sequence or {} }
    function transport:request(request)
        report.fake_requests = report.fake_requests + 1
        self.requests[#self.requests + 1] = request
        if request.url == Site.url then
            check(request.method == "GET" and request.body == nil and request.headers.cookie == nil)
            check(request.headers.authorization == nil and request.headers["x-xsrf-token"] == nil and request.max_bytes == 65536)
            check(request.headers.referer == "https://manga.bilibili.com/")
        else
            check(request.method == "GET" and (request.url == "https://api.bilibili.com/x/web-interface/nav"
                or request.url:find("https://passport.bilibili.com/x/passport-login/web/qrcode/poll?",1,true)==1))
        end
        local item = assert(self.sequence[#self.requests], "Unexpected extra request")
        if item.failure then return nil, item.failure end
        return item
    end
    return Auth.new{session=session or initial(),transport=transport,clock=function() return NOW end},transport
end

test("Confirmed QR sessions receive their site cookie before nav and publication", function()
    local auth, transport = fixture({confirmation(),device(),nav()})
    local before = Codec.canonical(auth.session:serialize())
    local value = assert(auth:pollQR("synthetic-key"))
    check(value.status == "confirmed" and #transport.requests == 3)
    check(transport.requests[2].url == Site.url and transport.requests[3].url == "https://api.bilibili.com/x/web-interface/nav")
    check(transport.requests[3].headers.cookie:find("buvid3=server-issued-device",1,true) ~= nil)
    check(value.session.cookies.SESSDATA == "synthetic-qr-session" and value.session.cookies.bili_jct == "synthetic-qr-csrf")
    check(value.session.refresh_token == "synthetic-qr-refresh" and value.session.pending_refresh_token == nil)
    check(value.session.account_key == "bili_42" and value.session.identity.name == "Validated account" and value.session.validated_at == NOW)
    check(before ~= Codec.canonical(auth.session:serialize()) and Site.hasDevice(auth.session))
end)

test("Existing usable QR device cookies need no initialization request", function()
    local auth, transport = fixture({confirmation("buvid3=qr-existing-device; Domain=.bilibili.com; Path=/"),nav()})
    local value = assert(auth:pollQR("synthetic-key"))
    check(#transport.requests == 2 and value.session.cookies.buvid3 == "qr-existing-device")
end)

test("A sibling-scoped QR device cookie is replaced only in the candidate", function()
    local auth, transport = fixture({confirmation("buvid3=passport-only; Path=/"),device(),nav()})
    local original = auth.session
    local value = assert(auth:pollQR("synthetic-key"))
    check(#transport.requests == 3 and value.session.cookies.buvid3 == "server-issued-device")
    check(original.cookies.buvid3 == nil and value.session.cookie_domains.buvid3 == "bilibili.com")
end)

test("Site failures never publish incomplete QR sessions and a fresh retry can succeed", function()
    local auth, transport = fixture({confirmation(),{status=503,body="",headers={}},confirmation(),device(),nav()})
    local old = auth.session
    local value, err = auth:pollQR("synthetic-key")
    check(value == nil and err.kind == "http" and err.retryable and #transport.requests == 2)
    check(auth.session == old and old.cookies.buvid3 == nil and old.refresh_token == "synthetic-current-token")
    value = assert(auth:pollQR("synthetic-retry-key"))
    check(value.status == "confirmed" and #transport.requests == 5)
end)

test("Nav failure or device removal cannot publish an initialized but unverified candidate", function()
    for _, last in ipairs({ nav(nil,43), response({isLogin=false}), nav({["set-cookie"]="buvid3=; Domain=.bilibili.com; Path=/; Max-Age=0"}) }) do
        local auth = fixture({confirmation(),device(),last})
        local old = auth.session
        local value, err = auth:pollQR("synthetic-key")
        check(value == nil and err and auth.session == old and old.cookies.SESSDATA == "synthetic-existing")
    end
end)

test("Only valid manga-scoped nonexpired device Set-Cookie values are accepted", function()
    for _, value in ipairs({ "", "buvid3=", "buvid3=bad value; Path=/", "buvid3=bad\r\nvalue", "buvid3=" .. string.rep("x",257),
        "buvid3=device; Domain=example.com; Path=/", "buvid3=device; Domain=api.bilibili.com; Path=/",
        "buvid3=device; Path=/ductape", "buvid3=device; Path=/; Max-Age=0", "buvid3=device; Path=/; Expires=Thu, 01 Jan 1970 00:00:01 GMT",
        "buvid3=first; Path=/, buvid3=second; Path=/" }) do
        local cookie, err = Site.parse({["set-cookie"]=value},NOW)
        check(cookie == nil and err.kind == "protocol")
    end
    local cookie = assert(Site.parse({["Set-Cookie"]="buvid3=valid-device; Domain=.bilibili.com; Path=/; Expires=Wed, 09 Jun 2032 10:18:14 GMT"},NOW))
    check(cookie.value == "valid-device" and cookie.domain == "bilibili.com")
end)

test("Unrelated site cookies cannot replace authentication or renewal state", function()
    local session = initial()
    local auth, transport = fixture({device({"SESSDATA=malicious; Domain=.bilibili.com; Path=/", "bili_jct=malicious; Domain=.bilibili.com; Path=/",
        "DedeUserID=99; Domain=.bilibili.com; Path=/", "buvid3=server-issued-device; Domain=.bilibili.com; Path=/"})},session)
    local old = auth.session
    local value = assert(auth:ensureSiteContext())
    local repaired = Session.new(value)
    check(Site.preservesSession(old,repaired) and #transport.requests == 1 and old.cookies.buvid3 == nil)
    check(value.cookies.SESSDATA == "synthetic-existing" and value.cookies.bili_jct == "synthetic-csrf" and value.identity.id == "42")
    check(value.refresh_token == "synthetic-current-token" and value.pending_refresh_token == "synthetic-previous-token")
    check(value.credential_generation == 7 and value.refresh_blocked and value.confirmation_blocked and value.cookie_expires_at == NOW + 3600)
end)

test("Persisted contexts with a usable device cookie perform zero requests", function()
    local session = initial();session.cookies.buvid3="already-issued"
    local auth, transport = fixture({},session)
    local old = auth.session
    local value = assert(auth:ensureSiteContext())
    check(#transport.requests == 0 and Codec.canonical(value) == Codec.canonical(old:serialize()))
end)

test("Site recovery failures preserve every input field and remain retryable", function()
    local expected = {kind="timeout",retryable=true,transmitted=true}
    local auth, transport = fixture({{failure=expected},device()})
    local old = auth.session
    local value, err = auth:ensureSiteContext()
    check(value == nil and err == expected and auth.session == old and old.cookies.buvid3 == nil)
    value = assert(auth:ensureSiteContext())
    check(#transport.requests == 2 and Site.preservesSession(old,Session.new(value)))
end)

test("Unvalidated sessions cannot use persisted-account site recovery", function()
    local session = initial();session.validated_at=nil
    local auth, transport = fixture({},session)
    local value, err = auth:ensureSiteContext()
    check(value == nil and err.kind == "authentication" and #transport.requests == 0)
end)

test("The production worker exposes site recovery without a separate session-update result", function()
    local _, transport = fixture({device()})
    local original_new = Transport.new
    Transport.new = function() return transport end
    local ok, value, err, update = pcall(Worker.execute,{kind="auth",method="ensureSiteContext",arguments={},session=initial():serialize()})
    Transport.new = original_new
    check(ok and value and err == nil and update == nil and value.cookies.buvid3 == "server-issued-device")
    check(value.account_key == "bili_42" and value.refresh_token == "synthetic-current-token")
end)

report.passed = true
for _, case in ipairs(report.cases) do report.passed = report.passed and case.passed end
local file = assert(io.open(output .. "/site-context-protocol-result.json","wb"))
file:write(assert(JSON.encode(report)));file:close()
assert(report.passed,"Site initialization protocol checks failed")
