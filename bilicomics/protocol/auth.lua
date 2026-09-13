local Errors = require("bilicomics/protocol/errors")
local JSON = require("bilicomics/protocol/json")
local Session = require("bilicomics/protocol/session")
local Transport = require("bilicomics/protocol/transport")

local Auth = {}
Auth.__index = Auth

local PASSPORT = "passport.bilibili.com"
local API = "api.bilibili.com"
local WWW = "www.bilibili.com"
local AUTH_HOSTS = { [PASSPORT] = true, [API] = true, [WWW] = true }
local SOURCE = "main_web"

local function escape(value)
    return tostring(value):gsub("[^%w%-_%.~]", function(char) return string.format("%%%02X", char:byte()) end)
end

local function form(fields)
    local parts = {}
    for _, pair in ipairs(fields) do parts[#parts + 1] = pair[1] .. "=" .. escape(pair[2]) end
    return table.concat(parts, "&")
end

local function opaque(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= (maximum or 4096)
        and not value:find("[%c%s]")
end

local function integer(value)
    value = tonumber(value)
    if not value or value ~= value or value < 1 or value > 9007199254740991 or value % 1 ~= 0 then return nil end
    return value
end

local function failure(kind, message, fields)
    local err = Errors.new(kind, message, fields)
    err.retryable = false
    return nil, err
end

local function unknown(response)
    return failure("refresh_unknown", "The service may have refreshed the session, but its result could not be verified.", {
        transmitted = response and response.transmitted ~= false, definitive = false,
    })
end

function Auth.new(opts)
    opts = opts or {}
    return setmetatable({
        session = opts.session and Session.new(opts.session),
        transport = opts.transport or Transport.new(opts.transport_options),
        clock = opts.clock or os.time,
        crypto = opts.crypto,
    }, Auth)
end

-- All authentication requests use this separate host allowlist. Redirects are not followed.
function Auth:_request(host, path, opts)
    opts = opts or {}
    if not AUTH_HOSTS[host] or type(path) ~= "string" or path:sub(1, 1) ~= "/"
        or path:sub(1, 2) == "//" or path:find("[%c]") then
        return failure("invalid_request", "The authentication endpoint is not supported.", { transmitted = false })
    end
    local headers = {
        ["user-agent"] = "Mozilla/5.0 (X11; Linux) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36",
        accept = opts.html and "text/html" or "application/json, text/plain, */*",
        referer = "https://www.bilibili.com/", origin = "https://www.bilibili.com",
    }
    if opts.session then headers.cookie = opts.session:cookieHeader(host) end
    if opts.body then headers["content-type"] = "application/x-www-form-urlencoded" end
    local response, err = self.transport:request({
        url = "https://" .. host .. path, method = opts.body and "POST" or "GET",
        headers = headers, body = opts.body, max_bytes = opts.html and 1024 * 1024 or 256 * 1024,
    })
    if not response then
        if opts.refresh and (not err or err.transmitted ~= false) then return unknown(err) end
        return failure(err and err.kind or "network", "The authentication request did not complete.", {
            transmitted = err and err.transmitted, status = err and err.status,
        })
    end
    if type(response.status) ~= "number" or response.status < 200 or response.status >= 300 then
        if opts.refresh and (type(response.status) ~= "number" or response.status >= 500) then return unknown(response) end
        return failure(response.status == 401 and "authentication" or "http",
            "The authentication service returned an unsuccessful HTTP response.", {
                status = response.status, transmitted = response.transmitted,
            })
    end
    return response
end

function Auth:_json(host, path, opts)
    local response, err = self:_request(host, path, opts)
    if not response then return nil, err end
    local envelope = JSON.decode(response.body)
    if not envelope or tonumber(envelope.code) == nil then
        if opts and opts.refresh then return unknown(response) end
        return failure("protocol", "The authentication service returned an invalid response.")
    end
    local code = tonumber(envelope.code)
    if code ~= 0 then
        local kind = (code == -101 or code == 401) and "authentication" or "business"
        if code == -111 then kind = "request_authentication" end
        if opts and opts.refresh then kind = "refresh_rejected" end
        return failure(kind, "The authentication service rejected the request.", {
            code = code, transmitted = response.transmitted, definitive = true,
        })
    end
    if type(envelope.data) ~= "table" and not (opts and opts.empty) then
        if opts and opts.refresh then return unknown(response) end
        return failure("protocol", "The authentication response contains no usable data.")
    end
    return envelope.data or {}, nil, response
end

function Auth:_requireSession()
    if not self.session or not self.session.cookies.SESSDATA or not self.session.cookies.bili_jct then
        return failure("authentication", "A web session and its CSRF cookie are required.", { transmitted = false })
    end
    return self.session
end

function Auth:_validate(session, expected_account)
    local data, err, response = self:_json(API, "/x/web-interface/nav", { session = session })
    if not data then return nil, err end
    if data.isLogin ~= true then
        return failure("authentication", "The service did not confirm a logged-in account.")
    end
    local candidate = Session.new(session:serialize())
    local applied
    applied, err = candidate:applySetCookie(response.headers, API, self.clock())
    if not applied then return nil, err end
    if not candidate.cookies.SESSDATA or not candidate.cookies.bili_jct then
        return failure("authentication", "The service removed the required session cookies.")
    end
    local confirmed
    confirmed, err = candidate:withIdentity(data, self.clock())
    if not confirmed then return nil, err end
    if expected_account and confirmed.account_key ~= expected_account then
        return failure("account_mismatch", "The refreshed session belongs to a different account.")
    end
    return confirmed
end

function Auth:generateQR()
    local data, err = self:_json(PASSPORT, "/x/passport-login/web/qrcode/generate?" .. form({
        { "source", SOURCE }, { "go_url", "https://manga.bilibili.com/" },
    }))
    if not data then return nil, err end
    if not opaque(data.qrcode_key, 128) or not data.qrcode_key:match("^[%w_-]+$")
        or type(data.url) ~= "string" or #data.url > 8192 or data.url:find("[%c%s]")
        or not data.url:match("^https://account%.bilibili%.com/") then
        return failure("protocol", "The service returned an invalid login QR code.")
    end
    -- Current official responses expose no lifetime. Server poll status owns expiry.
    return { url = data.url, key = data.qrcode_key }
end

function Auth:pollQR(key)
    if not opaque(key, 128) or not key:match("^[%w_-]+$") then
        return failure("invalid_request", "A login QR code identifier is required.", { transmitted = false })
    end
    local data, err, response = self:_json(PASSPORT, "/x/passport-login/web/qrcode/poll?" .. form({
        { "qrcode_key", key }, { "source", SOURCE },
    }))
    if not data then return nil, err end
    local statuses = { [86101] = "waiting", [86090] = "scanned", [86038] = "expired" }
    local status = statuses[tonumber(data.code)]
    if status then return { status = status } end
    if tonumber(data.code) ~= 0 then
        return failure("authentication", "The service did not confirm this login QR code.", { code = tonumber(data.code) })
    end
    if not opaque(data.refresh_token) then
        return failure("protocol", "The confirmed login contains no renewal credential.")
    end
    local candidate = Session.new({ imported_at = self.clock(), refresh_token = data.refresh_token })
    local applied, apply_err, changes = candidate:applySetCookie(response.headers, PASSPORT, self.clock())
    if not applied then return nil, apply_err end
    if not changes or not changes.SESSDATA or not changes.bili_jct
        or not candidate.cookies.SESSDATA or not candidate.cookies.bili_jct then
        return failure("protocol", "The confirmed login did not deliver its required session cookies.")
    end
    local validated
    validated, err = self:_validate(candidate)
    if not validated then return nil, err end
    self.session = validated
    return { status = "confirmed", session = validated:serialize() }
end

function Auth:cookieInfo()
    local session, err = self:_requireSession()
    if not session then return nil, err end
    local data, response
    data, err, response = self:_json(PASSPORT, "/x/passport-login/web/cookie/info?" .. form({
        { "csrf", session.cookies.bili_jct },
    }), { session = session })
    if not data then return nil, err end
    local timestamp = integer(data.timestamp)
    if type(data.refresh) ~= "boolean" or not timestamp then
        return failure("protocol", "The service returned an invalid session renewal status.")
    end
    local candidate = Session.new(session:serialize())
    local applied, changes
    applied, err, changes = candidate:applySetCookie(response.headers, PASSPORT, self.clock())
    if not applied then return nil, err end
    if changes.SESSDATA or changes.bili_jct or changes.DedeUserID then
        candidate, err = self:_validate(candidate, session.account_key)
        if not candidate then return nil, err end
    end
    candidate.refresh_checked_at = self.clock()
    self.session = candidate
    return { refresh = data.refresh, timestamp = timestamp, session = candidate:serialize() }
end

local function refreshCSRF(body)
    if type(body) ~= "string" then return nil end
    for attributes, content in body:gmatch("<div%s+([^>]+)>(.-)</div%s*>") do
        attributes = " " .. attributes
        if attributes:match('%sid%s*=%s*"1%-name"') or attributes:match("%sid%s*=%s*'1%-name'") then
            local value = content:match("^%s*([%w_-]+)%s*$")
            if value and #value <= 512 then return value end
        end
    end
end

function Auth:_refreshSession(opts, attempt)
    opts = opts or {}
    local session, err = self:_requireSession()
    if not session then return nil, err end
    if session.pending_refresh_token then
        return failure("refresh_pending", "Save and confirm the previous renewal before refreshing again.", { transmitted = false })
    end
    if not opaque(session.refresh_token) then
        return failure("refresh_unavailable", "This session has no renewal credential. Sign in with a QR code to enable renewal.", { transmitted = false })
    end
    if not session.account_key then
        return failure("authentication", "Validate the account before renewing its session.", { transmitted = false })
    end
    local info = opts.info
    if not info then info, err = self:cookieInfo() end
    if not info then return nil, err end
    session = self.session
    if type(info.refresh) ~= "boolean" or not integer(info.timestamp) then
        return failure("invalid_request", "A verified session renewal status is required.", { transmitted = false })
    end
    if not info.refresh then
        local current
        current, err = self:_validate(session, session.account_key)
        if not current then return nil, err end
        current.refresh_checked_at = self.clock()
        current.refresh_blocked = false
        self.session = current
        return current:serialize()
    end
    local crypto = self.crypto
    if not crypto then crypto = require("bilicomics/protocol/auth_crypto").new() end
    local path
    path, err = crypto:correspondPath(info.timestamp)
    if not path then return nil, err end
    if type(path) ~= "string" or not path:match("^%x+$") or #path > 1024 then
        return failure("protocol", "The renewal challenge could not be generated.", { transmitted = false })
    end
    local response
    response, err = self:_request(WWW, "/correspond/1/" .. path, { html = true, session = session })
    if not response then return nil, err end
    local refresh_csrf = refreshCSRF(response.body)
    if not refresh_csrf then
        return failure("protocol", "The renewal challenge response is invalid.")
    end
    local data
    attempt.started = true
    data, err, response = self:_json(PASSPORT, "/x/passport-login/web/cookie/refresh", {
        session = session, refresh = true,
        body = form({ { "csrf", session.cookies.bili_jct }, { "refresh_csrf", refresh_csrf },
            { "source", SOURCE }, { "refresh_token", session.refresh_token } }),
    })
    if not data then return nil, err end
    if not opaque(data.refresh_token) or data.refresh_token == session.refresh_token then return unknown(response) end
    local candidate = Session.new(session:serialize())
    local applied, _, changes = candidate:applySetCookie(response.headers, PASSPORT, self.clock())
    if not applied then return unknown(response) end
    if not changes or not changes.SESSDATA or not changes.bili_jct
        or not candidate.cookies.SESSDATA or not candidate.cookies.bili_jct then return unknown(response) end
    candidate.pending_refresh_token, candidate.refresh_token = session.refresh_token, data.refresh_token
    candidate.refresh_checked_at, candidate.last_refreshed_at = self.clock(), self.clock()
    candidate.refresh_blocked = false
    local validated
    validated, err = self:_validate(candidate, session.account_key)
    if not validated then
        if err and err.kind == "account_mismatch" then return nil, err end
        return unknown(response)
    end
    self.session = validated
    return validated:serialize()
end

function Auth:refreshSession(opts)
    local attempt = { started = false }
    local session, err = self:_refreshSession(opts, attempt)
    if err then err.refresh_attempted = attempt.started and err.transmitted ~= false end
    return session, err
end

-- The caller must durably save the returned refreshed session before invoking this method.
function Auth:confirmRefresh()
    local session, err = self:_requireSession()
    if not session then return nil, err end
    if not opaque(session.pending_refresh_token) then
        return failure("invalid_request", "A durably saved renewal transaction is required.", { transmitted = false })
    end
    local data
    data, err = self:_json(PASSPORT, "/x/passport-login/web/confirm/refresh", {
        session = session, empty = true,
        body = form({ { "csrf", session.cookies.bili_jct }, { "refresh_token", session.pending_refresh_token } }),
    })
    if not data then return nil, err end
    return true
end

return Auth
