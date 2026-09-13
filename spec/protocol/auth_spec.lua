local root, output = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path

local Auth = require("bilicomics/protocol/auth")
local Errors = require("bilicomics/protocol/errors")
local JSON = require("bilicomics/protocol/json")
local Session = require("bilicomics/protocol/session")
local passed = {}
local NOW = 1800000000

local function test(name, fn)
    local ok, err = pcall(fn)
    assert(ok, name .. ": " .. tostring(err))
    passed[#passed + 1] = name
    print("PASS " .. name)
end

local function response(data, headers, code)
    return { status = 200, transmitted = true, headers = headers or {},
        body = assert(JSON.encode({ code = code or 0, data = data })) }
end

local function cookies(mid)
    return { ["set-cookie"] = {
        "SESSDATA=new_session; Domain=.bilibili.com; Path=/; Secure; HttpOnly; Max-Age=15552000",
        "bili_jct=new_csrf; Domain=.bilibili.com; Path=/; Secure",
        "DedeUserID=" .. tostring(mid or 42) .. "; Domain=.bilibili.com; Path=/; Secure",
        "buvid3=synthetic-existing-device; Domain=.bilibili.com; Path=/; Secure",
    } }
end

local function nav(mid)
    return response({ isLogin = true, mid = mid or 42, uname = "Synthetic account" })
end

local function fixture(sequence, fields)
    local transport = { requests = {}, sequence = sequence or {} }
    function transport:request(request)
        self.requests[#self.requests + 1] = request
        local next_response = assert(self.sequence[#self.requests], "Unexpected network request")
        if type(next_response) == "function" then return next_response(request) end
        return next_response
    end
    fields = fields or {}
    local session = Session.new({ cookies = { SESSDATA = "old_session", bili_jct = "old_csrf", DedeUserID = "42" },
        identity = { id = "42", name = "Synthetic account" }, account_key = "bili_42", validated_at = NOW - 30,
        refresh_token = "old_token", credential_generation = 4 })
    for key, value in pairs(fields) do session[key] = value end
    local crypto = { calls = {} }
    function crypto:correspondPath(timestamp)
        self.calls[#self.calls + 1] = timestamp
        return string.rep("ab", 128)
    end
    return Auth.new({ session = session, transport = transport, crypto = crypto, clock = function() return NOW end }),
        transport, crypto, session
end

local function renewSequence(overrides)
    local list = {
        response({ refresh = true, timestamp = NOW * 1000 }),
        { status = 200, body = '<html><div class="token" id="1-name">synthetic_refresh_csrf</div></html>' },
        response({ refresh_token = "new_token" }, cookies()),
        nav(),
    }
    for key, value in pairs(overrides or {}) do list[key] = value end
    return list
end

test("QR generation stays anonymous and uses the official scan host", function()
    local auth, transport = fixture({ response({
        url = "https://account.bilibili.com/h5/account-h5/auth/scan-web?key=synthetic", qrcode_key = "synthetic_key",
    }) })
    local qr = assert(auth:generateQR())
    assert(qr.key == "synthetic_key" and qr.expires_at == nil)
    assert(transport.requests[1].headers.cookie == nil)
    assert(transport.requests[1].url:find("source=main_web", 1, true))
end)

test("QR generation rejects an unexpected credential destination", function()
    local auth = fixture({ response({ url = "https://example.com/scan", qrcode_key = "synthetic_key" }) })
    local value, err = auth:generateQR()
    assert(not value and err.kind == "protocol")
end)

test("QR polling maps every official pending and expiry status", function()
    local auth, transport = fixture({ response({ code = 86101 }), response({ code = 86090 }), response({ code = 86038 }) })
    assert(auth:pollQR("synthetic_key").status == "waiting")
    assert(auth:pollQR("synthetic_key").status == "scanned")
    assert(auth:pollQR("synthetic_key").status == "expired")
    for _, request in ipairs(transport.requests) do assert(request.headers.cookie == nil) end
end)

test("QR polling rejects malformed identifiers before transmission", function()
    local auth, transport = fixture()
    local value, err = auth:pollQR("key&csrf=injected")
    assert(not value and err.kind == "invalid_request" and #transport.requests == 0)
end)

test("a confirmed QR login must receive cookies and validate its identity", function()
    local auth, transport = fixture({ response({ code = 0, refresh_token = "qr_token" }, cookies()), nav() })
    local result = assert(auth:pollQR("synthetic_key"))
    assert(result.status == "confirmed" and result.session.account_key == "bili_42")
    assert(result.session.refresh_token == "qr_token" and result.session.cookies.SESSDATA == "new_session")
    assert(result.session.pending_refresh_token == nil and result.session.validated_at == NOW)
    assert(transport.requests[2].url == "https://api.bilibili.com/x/web-interface/nav")
    assert(transport.requests[2].headers.cookie:find("SESSDATA=new_session", 1, true))
end)

test("confirmed QR results do not silently reuse the previous account cookies", function()
    local auth, transport = fixture({ response({ code = 0, refresh_token = "qr_token" }) })
    local value, err = auth:pollQR("synthetic_key")
    assert(not value and err.kind == "protocol" and #transport.requests == 1)
    assert(auth.session.cookies.SESSDATA == "old_session")
end)

test("confirmed QR results reject missing renewal credentials", function()
    local auth, transport = fixture({ response({ code = 0 }, cookies()) })
    local value, err = auth:pollQR("synthetic_key")
    assert(not value and err.kind == "protocol" and #transport.requests == 1)
end)

test("QR identity mismatch never activates the candidate session", function()
    local auth = fixture({ response({ code = 0, refresh_token = "qr_token" }, cookies()), nav(43) })
    local value, err = auth:pollQR("synthetic_key")
    assert(not value and err.kind == "account_mismatch")
    assert(auth.session.cookies.SESSDATA == "old_session")
end)

test("identity validation retains refreshed cookies from nav", function()
    local headers = { ["set-cookie"] = {
        "SESSDATA=nav_session; Domain=.bilibili.com; Path=/; Secure; HttpOnly",
        "bili_jct=nav_csrf; Domain=.bilibili.com; Path=/; Secure",
    } }
    local auth = fixture({ response({ code = 0, refresh_token = "qr_token" }, cookies()),
        response({ isLogin = true, mid = 42 }, headers) })
    local result = assert(auth:pollQR("synthetic_key"))
    assert(result.session.cookies.SESSDATA == "nav_session" and result.session.cookies.bili_jct == "nav_csrf")
end)

test("identity validation refuses cookies removed by nav", function()
    local auth = fixture({ response({ code = 0, refresh_token = "qr_token" }, cookies()),
        response({ isLogin = true, mid = 42 }, { ["set-cookie"] = "SESSDATA=; Domain=.bilibili.com; Path=/; Max-Age=0" }) })
    local value, err = auth:pollQR("synthetic_key")
    assert(not value and err.kind == "authentication" and auth.session.cookies.SESSDATA == "old_session")
end)

test("renewal status persists its check time without exposing token in a URL", function()
    local auth, transport = fixture({ response({ refresh = true, timestamp = NOW * 1000 }) })
    local info = assert(auth:cookieInfo())
    assert(info.refresh == true and info.timestamp == NOW * 1000 and info.session.refresh_checked_at == NOW)
    assert(transport.requests[1].headers.cookie:find("SESSDATA=old_session", 1, true))
    assert(not transport.requests[1].url:find("old_token", 1, true))
end)

test("renewal status rejects ambiguous boolean and timestamp fields", function()
    local auth = fixture({ response({ refresh = 1, timestamp = NOW * 1000 }) })
    local value, err = auth:cookieInfo()
    assert(not value and err.kind == "protocol")
end)

test("renewal status validates and returns cookies rotated by the read response", function()
    local auth, transport = fixture({ response({ refresh = false, timestamp = NOW * 1000 }, cookies()), nav() })
    local info = assert(auth:cookieInfo())
    assert(info.session.cookies.SESSDATA == "new_session" and info.session.validated_at == NOW)
    assert(transport.requests[2].headers.cookie:find("SESSDATA=new_session", 1, true))
end)

test("renewal status cannot activate a rotated cookie for another account", function()
    local auth = fixture({ response({ refresh = false, timestamp = NOW * 1000 }, cookies(43)), nav(43) })
    local value, err = auth:cookieInfo()
    assert(not value and err.kind == "account_mismatch" and auth.session.cookies.SESSDATA == "old_session")
end)

test("request authentication rejection does not assert that the account expired", function()
    local auth = fixture({ response({}, {}, -111) })
    local value, err = auth:cookieInfo()
    assert(not value and err.kind == "request_authentication" and err.code == -111)
end)

test("an imported cookie without renewal credentials cannot claim automatic renewal", function()
    local auth, transport = fixture()
    auth.session.refresh_token = nil
    local value, err = auth:refreshSession()
    assert(not value and err.kind == "refresh_unavailable" and #transport.requests == 0)
end)

test("an already pending renewal must be confirmed before another refresh", function()
    local auth, transport = fixture({}, { pending_refresh_token = "pending_token" })
    local value, err = auth:refreshSession()
    assert(not value and err.kind == "refresh_pending" and #transport.requests == 0)
end)

test("no-renewal status validates the existing identity and never sends a refresh POST", function()
    local auth, transport, crypto = fixture({ response({ refresh = false, timestamp = NOW * 1000 }), nav() })
    local session = assert(auth:refreshSession())
    assert(session.refresh_checked_at == NOW and session.validated_at == NOW and session.refresh_token == "old_token")
    assert(session.pending_refresh_token == nil and #crypto.calls == 0 and #transport.requests == 2)
end)

test("a rejected unchanged-session check cannot replace the active identity", function()
    local auth = fixture({ response({ refresh = false, timestamp = NOW * 1000 }), nav(43) })
    auth.session.cookies.DedeUserID = nil
    local value, err = auth:refreshSession()
    assert(not value and err.kind == "account_mismatch" and err.refresh_attempted == false)
    assert(auth.session.account_key == "bili_42" and auth.session.identity.id == "42")
end)

test("successful checks and renewals clear only their completed crash marker", function()
    local auth = fixture({ response({ refresh = false, timestamp = NOW * 1000 }), nav() }, { refresh_blocked = true })
    assert(auth:refreshSession().refresh_blocked == false)
    auth = fixture(renewSequence(), { refresh_blocked = true })
    assert(auth:refreshSession().refresh_blocked == false)
end)

test("renewal returns a verified candidate with the old token pending durable confirmation", function()
    local auth, transport, crypto, original = fixture(renewSequence())
    local session = assert(auth:refreshSession())
    assert(session.refresh_token == "new_token" and session.pending_refresh_token == "old_token")
    assert(session.account_key == "bili_42" and session.validated_at == NOW and session.last_refreshed_at == NOW)
    assert(session.cookies.SESSDATA == "new_session" and original.cookies.SESSDATA == "old_session")
    assert(#transport.requests == 4 and crypto.calls[1] == NOW * 1000)
    assert(transport.requests[2].headers.cookie:find("SESSDATA=old_session", 1, true))
    local request = transport.requests[3]
    assert(request.method == "POST" and request.body == "csrf=old_csrf&refresh_csrf=synthetic_refresh_csrf&source=main_web&refresh_token=old_token")
    assert(request.headers["content-type"] == "application/x-www-form-urlencoded")
    assert(transport.requests[4].headers.cookie:find("SESSDATA=new_session", 1, true))
end)

test("a previous status result can avoid a duplicate status request", function()
    local sequence = renewSequence()
    table.remove(sequence, 1)
    local auth, transport = fixture(sequence)
    assert(auth:refreshSession({ info = { refresh = true, timestamp = NOW * 1000 } }))
    assert(#transport.requests == 3)
end)

test("invalid correspondence HTML cannot trigger a refresh POST", function()
    local auth, transport = fixture(renewSequence({ [2] = { status = 200,
        body = '<div id="1-name"><script>invalid</script></div>' } }))
    local value, err = auth:refreshSession()
    assert(not value and err.kind == "protocol" and #transport.requests == 2 and err.refresh_attempted == false)
end)

test("a refresh response without required Set-Cookie headers remains uncertain", function()
    local auth, transport = fixture(renewSequence({ [3] = response({ refresh_token = "new_token" }) }))
    local value, err = auth:refreshSession()
    assert(not value and err.kind == "refresh_unknown" and err.retryable == false and #transport.requests == 3)
    assert(err.refresh_attempted == true)
    assert(auth.session.cookies.SESSDATA == "old_session")
end)

test("a reused refresh token cannot be confirmed as a fresh credential", function()
    local auth, transport = fixture(renewSequence({ [3] = response({ refresh_token = "old_token" }, cookies()) }))
    local value, err = auth:refreshSession()
    assert(not value and err.kind == "refresh_unknown" and #transport.requests == 3)
end)

test("lost refresh responses are never replayed by the protocol module", function()
    local auth, transport = fixture(renewSequence({ [3] = function()
        return nil, Errors.new("timeout", "Synthetic response loss", { retryable = true, transmitted = true })
    end }))
    local value, err = auth:refreshSession()
    assert(not value and err.kind == "refresh_unknown" and err.retryable == false and #transport.requests == 3)
end)

test("a refresh connection failure before transmission is distinguishable from uncertainty", function()
    local auth, transport = fixture(renewSequence({ [3] = function()
        return nil, Errors.new("network", "Synthetic connect failure", { retryable = true, transmitted = false })
    end }))
    local value, err = auth:refreshSession()
    assert(not value and err.kind == "network" and err.transmitted == false and err.retryable == false)
    assert(err.refresh_attempted == false)
    assert(#transport.requests == 3)
end)

test("explicit business rejection is distinguishable from an unknown refresh outcome", function()
    local auth, transport = fixture(renewSequence({ [3] = response({}, {}, -101) }))
    local value, err = auth:refreshSession()
    assert(not value and err.kind == "refresh_rejected" and err.code == -101 and err.definitive == true)
    assert(err.refresh_attempted == true)
    assert(err.retryable == false and #transport.requests == 3)
end)

test("renewal rejects account replacement even when its new cookies match nav", function()
    local auth = fixture(renewSequence({ [3] = response({ refresh_token = "new_token" }, cookies(43)), [4] = nav(43) }))
    local value, err = auth:refreshSession()
    assert(not value and err.kind == "account_mismatch" and auth.session.account_key == "bili_42")
end)

test("loss of the candidate identity check preserves refresh uncertainty", function()
    local auth, transport = fixture(renewSequence({ [4] = function()
        return nil, Errors.new("timeout", "Synthetic nav failure", { transmitted = true })
    end }))
    local value, err = auth:refreshSession()
    assert(not value and err.kind == "refresh_unknown" and #transport.requests == 4)
end)

test("confirmation uses the newly saved cookie and the previous renewal token", function()
    local auth, transport = fixture({ response({}) }, { pending_refresh_token = "previous_token", refresh_token = "new_token" })
    auth.session.cookies.bili_jct, auth.session.cookies.SESSDATA = "new_csrf", "new_session"
    assert(auth:confirmRefresh())
    local request = transport.requests[1]
    assert(request.url == "https://passport.bilibili.com/x/passport-login/web/confirm/refresh")
    assert(request.body == "csrf=new_csrf&refresh_token=previous_token")
    assert(request.headers.cookie:find("SESSDATA=new_session", 1, true))
    assert(auth.session.pending_refresh_token == "previous_token")
end)

test("confirmation refuses a missing durable transaction and retains failed pending state", function()
    local auth, transport = fixture()
    local value, err = auth:confirmRefresh()
    assert(not value and err.kind == "invalid_request" and #transport.requests == 0)
    auth.session.pending_refresh_token = "previous_token"
    transport.sequence[1] = function()
        return nil, Errors.new("timeout", "Synthetic confirmation failure", { retryable = true, transmitted = true })
    end
    value, err = auth:confirmRefresh()
    assert(not value and err.retryable == false and auth.session.pending_refresh_token == "previous_token")
    assert(#transport.requests == 1)
end)

test("authentication requests cannot send credentials to CDN or unapproved domains", function()
    local auth, transport = fixture()
    for _, host in ipairs({ "i0.hdslb.com", "manga.bilibili.com", "passport.bilibili.com.example.com", "example.com" }) do
        local value, err = auth:_request(host, "/test", { session = auth.session })
        assert(not value and err.kind == "invalid_request")
    end
    assert(#transport.requests == 0)
end)

local file = assert(io.open(output .. "/auth-result.json", "wb"))
file:write(assert(JSON.encode({ passed = #passed, cases = passed })))
file:close()
