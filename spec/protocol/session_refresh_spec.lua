-- Verify private session formats, response cookies, and the real worker-pipe update channel.
require("setupkoenv")
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local Session = require("bilicomics/protocol/session")
local Codec = require("bilicomics/storage/codec")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local ffi = require("ffi")
local socket = require("socket")
local lfs = require("libs/libkoreader-lfs")
local Runner = require("bilicomics/jobs/runner")
local tests, active, assertion_count, injected_requests = {}, {}, 0, 0
local now = 1800000000
local function check(value, message)
    assertion_count = assertion_count + 1
    assert(value, message)
end
local function session()
    local value = assert(Session.parse("SESSDATA=synthetic-original; DedeUserID=42; bili_jct=synthetic-csrf; buvid3=synthetic-device"))
    assert(value:withIdentity({ id = "42", name = "Synthetic account" }, now))
    return value
end
local function test(name, callback)
    local before = assertion_count
    local ok, failure = xpcall(callback, debug.traceback)
    for _, runner in ipairs(active) do pcall(runner.close, runner) end
    active = {}
    tests[#tests + 1] = { name = name, passed = ok, assertions = assertion_count - before, error = ok and nil or failure }
    print((ok and "PASS " or "FAIL ") .. name)
end

test("Schema 1 credentials load and upgrade without inventing renewal capability", function()
    local fields = session():serialize()
    fields.schema_version = 1
    fields.cookie_domains, fields.credential_generation, fields.refresh_blocked, fields.confirmation_blocked = nil, nil, nil, nil
    local path = output .. "/legacy-session.dat"
    Files.write(path, json.encode(fields))
    local loaded = assert(Session.load(path))
    check(loaded.account_key == "bili_42" and loaded.cookies.SESSDATA == "synthetic-original", "Legacy identity and cookies must remain usable")
    check(loaded.refresh_token == nil and loaded.pending_refresh_token == nil and not loaded.confirmation_blocked and not loaded:summary().renewable,
        "Legacy imports must not claim automatic renewal without a refresh token")
    check(loaded:serialize().schema_version == 2 and loaded.credential_generation == 0, "Legacy sessions must serialize as schema 2")
end)

test("Schema 2 private persistence retains renewal state and mode 0600", function()
    local value = session()
    value.refresh_token, value.pending_refresh_token = "synthetic-current-refresh", "synthetic-previous-refresh"
    value.refresh_checked_at, value.last_refreshed_at, value.cookie_expires_at = now, now - 1, now + 3600
    value.credential_generation, value.refresh_blocked, value.confirmation_blocked = 7, true, true
    value.cookie_domains.SESSDATA = "bilibili.com"
    local path = output .. "/renewable-session.dat"
    check(value:save(path) == true, "Verified renewable credentials must save through the private session writer")
    local loaded = assert(Session.load(path))
    check(loaded.refresh_token == value.refresh_token and loaded.pending_refresh_token == value.pending_refresh_token,
        "Current and pending confirmation tokens must survive restart")
    check(loaded.refresh_checked_at == now and loaded.last_refreshed_at == now - 1 and loaded.cookie_expires_at == now + 3600,
        "Renewal timing metadata must survive restart")
    check(loaded.credential_generation == 7 and loaded.refresh_blocked and loaded.confirmation_blocked and loaded.cookie_domains.SESSDATA == "bilibili.com",
        "Generation, uncertain-refresh state and domain scope must survive restart")
    check(lfs.attributes(path).permissions == "rw-------", "Private credential files must be mode 0600")
end)

test("Uncertain confirmation survives restart and independently disables renewal capability", function()
    local value = session()
    value.refresh_token, value.pending_refresh_token = "synthetic-confirmation-current", "synthetic-confirmation-previous"
    check(value:summary().renewable == true, "A verified refresh token must initially expose renewal capability")
    value.confirmation_blocked = true
    check(value.refresh_blocked == false and value:summary().renewable == false,
        "Uncertain confirmation alone must suppress renewal capability")
    local path = output .. "/confirmation-blocked-session.dat"
    assert(value:save(path))
    local loaded = assert(Session.load(path))
    check(loaded.confirmation_blocked == true and loaded.pending_refresh_token == value.pending_refresh_token
        and loaded:summary().renewable == false, "The confirmation marker and pending token must remain durable together")
    local fields = value:serialize()
    fields.confirmation_blocked = "true"
    check(Session.new(fields).confirmation_blocked == false, "Only a boolean confirmation marker may enter private session state")
end)

test("Browser exports retain actual expiry while raw Cookie imports remain metadata-free", function()
    local value = assert(Session.parse(json.encode({ refresh_token = "synthetic-export-refresh", cookies = {
        { name = "SESSDATA", value = "synthetic-export", domain = ".bilibili.com", expirationDate = now + 600 },
        { name = "DedeUserID", value = "42", domain = ".bilibili.com" },
        { name = "bili_jct", value = "foreign-value", domain = ".example.com" },
    } })))
    check(value.refresh_token == "synthetic-export-refresh" and value.cookie_expires_at == now + 600,
        "Structured exports must retain provided renewal and expiry metadata")
    check(value.cookie_domains.SESSDATA == "bilibili.com" and value.cookies.bili_jct == nil, "Foreign export cookies must not enter the session")
    local netscape = assert(Session.parse("# Netscape HTTP Cookie File\n#HttpOnly_.bilibili.com\tTRUE\t/\tTRUE\t" .. (now + 600) .. "\tSESSDATA\tsynthetic-netscape"))
    check(netscape.cookie_expires_at == now + 600 and netscape.cookie_domains.SESSDATA == "bilibili.com", "Netscape expiry and domain must survive import")
    local raw = assert(Session.parse("SESSDATA=synthetic-raw; DedeUserID=42"))
    check(raw.cookie_expires_at == nil and raw.refresh_token == nil, "A Cookie request header cannot provide unrecorded expiry or refresh credentials")
end)

test("Invalid refresh metadata is discarded without changing valid session identity", function()
    local fields = session():serialize()
    fields.refresh_token, fields.pending_refresh_token = "bad\nrefresh", string.rep("x", 16385)
    fields.refresh_checked_at, fields.cookie_expires_at, fields.last_refreshed_at = -1, 1 / 0, 0 / 0
    fields.credential_generation = -2
    local value = Session.new(fields)
    check(value.refresh_token == nil and value.pending_refresh_token == nil, "Control-bearing and oversized refresh values must be discarded")
    check(value.refresh_checked_at == nil and value.cookie_expires_at == nil and value.last_refreshed_at == nil,
        "Invalid timestamps must not enter refresh scheduling")
    check(value.credential_generation == 0 and value.account_key == "bili_42", "Invalid generation metadata must normalize without losing identity")
end)

test("Repeated Set-Cookie headers merge without splitting an Expires date comma", function()
    local value = session()
    local ok, err, changed = value:applySetCookie({ ["Set-Cookie"] = {
        "SESSDATA=synthetic-rotated; Domain=.bilibili.com; Path=/; Expires=Wed, 09 Jun 2032 10:18:14 GMT; HttpOnly; Secure",
        "bili_jct=synthetic-next-csrf; Domain=.bilibili.com; Path=/; Max-Age=120",
    } }, "passport.bilibili.com", now)
    check(ok and err == nil and changed.SESSDATA and changed.bili_jct, "Repeated response fields must report every adopted cookie")
    check(value.cookies.SESSDATA == "synthetic-rotated" and value.cookies.bili_jct == "synthetic-next-csrf",
        "Repeated response fields must preserve complete values")
    check(value.cookie_expires_at == 1970389094, "The RFC HTTP date must retain its UTC instant despite the comma")
    check(value:cookieHeader("api.bilibili.com"):find("synthetic-rotated", 1, true) ~= nil,
        "A parent-domain refreshed session must be sent to the identity origin")
end)

test("LuaSocket comma-joined cookies honor later values and Max-Age precedence", function()
    local value = session()
    local ok = value:applySetCookie({ ["set-cookie"] =
        "SESSDATA=synthetic-first; Domain=.bilibili.com; Expires=Wed, 09 Jun 2032 10:18:14 GMT, " ..
        "bili_jct=synthetic-joined-csrf; Domain=.bilibili.com, " ..
        "SESSDATA=synthetic-last; Domain=.bilibili.com; Max-Age=90; Expires=Thu, 01 Jan 1970 00:00:01 GMT" },
        "passport.bilibili.com", now)
    check(ok and value.cookies.SESSDATA == "synthetic-last" and value.cookies.bili_jct == "synthetic-joined-csrf",
        "Joined fields must retain the final same-name cookie and other fields")
    check(value.cookie_expires_at == now + 90, "Max-Age must override Expires in the same response cookie")
end)

test("Cookie response origins and domain scopes cannot cross unrelated hosts", function()
    local value = session()
    local original = value.cookies.SESSDATA
    local ok, err = value:applySetCookie({ ["Set-Cookie"] = "SESSDATA=foreign; Domain=.bilibili.com" }, "example.com", now)
    check(not ok and err.kind == "invalid_session" and value.cookies.SESSDATA == original,
        "An unrelated response origin must not mutate the session")
    assert(value:applySetCookie({ ["Set-Cookie"] = {
        "SESSDATA=wrong-sibling; Domain=api.bilibili.com; Path=/",
        "bili_jct=wrong-parent; Domain=example.com; Path=/",
    } }, "passport.bilibili.com", now))
    check(value.cookies.SESSDATA == original and value.cookies.bili_jct == "synthetic-csrf",
        "A passport response cannot overwrite cookies scoped to a sibling or unrelated domain")
    assert(value:applySetCookie({ ["Set-Cookie"] = "buvid3=synthetic-host-only; Path=/" }, "passport.bilibili.com", now))
    check(value:cookieHeader("passport.bilibili.com"):find("synthetic-host-only", 1, true) ~= nil
        and not value:cookieHeader("manga.bilibili.com"):find("synthetic-host-only", 1, true),
        "A host-scoped response cookie must stay on its origin")
    check(value:cookieHeader("example.com") == nil and value:cookieHeader("bilibili.com.example.com") == nil,
        "Session headers must never be provided to an unrelated or deceptive host")
    assert(value:applySetCookie({ ["Set-Cookie"] = "XSRF-TOKEN=synthetic-xsrf; Domain=.bilibili.com; Path=/" }, "manga.bilibili.com", now))
    check(value:cookieHeader("manga.bilibili.com"):find("XSRF-TOKEN=synthetic-xsrf", 1, true)
        and not value:cookieHeader("passport.bilibili.com"):find("XSRF-TOKEN", 1, true), "The manga XSRF cookie must remain manga-only")
end)

test("Deletion cookies remove credentials and stale expiry metadata", function()
    for _, suffix in ipairs({ "Max-Age=0", "Max-Age=-1", "Expires=Thu, 01 Jan 1970 00:00:01 GMT" }) do
        local value = session(); value.cookie_expires_at = now + 600
        local ok, err, changed = value:applySetCookie({ ["Set-Cookie"] = "SESSDATA=deleted; Domain=.bilibili.com; " .. suffix }, "passport.bilibili.com", now)
        check(ok and not err and changed.SESSDATA and value.cookies.SESSDATA == nil and value.cookie_expires_at == nil,
            "Explicit deletion must remove both the cookie and its old deadline")
    end
    local value = session()
    assert(value:applySetCookie({ ["Set-Cookie"] = "bili_jct=; Domain=.bilibili.com; Path=/" }, "passport.bilibili.com", now))
    check(value.cookies.bili_jct == nil and value.cookies.SESSDATA ~= nil, "An empty deletion must remove only its named cookie")
end)

test("Invalid cookie batches reject atomically without partial rotation", function()
    for _, invalid in ipairs({
        "bili_jct=bad value; Domain=.bilibili.com; Path=/",
        "bili_jct=synthetic-next; Domain=.bilibili.com; Max-Age=1.5",
        "bili_jct=synthetic-next\r\nInjected: true",
    }) do
        local value = session()
        value.cookie_expires_at = now + 500
        local ok, err = value:applySetCookie({ ["Set-Cookie"] = {
            "SESSDATA=synthetic-new; Domain=.bilibili.com; Max-Age=600", invalid,
        } }, "passport.bilibili.com", now)
        check(not ok and err.kind == "invalid_session", "A malformed allowed response cookie must reject its batch")
        check(value.cookies.SESSDATA == "synthetic-original" and value.cookies.bili_jct == "synthetic-csrf"
            and value.cookie_expires_at == now + 500, "No prior cookie in a rejected batch may be committed")
    end
end)

test("Unsupported cookie names and nonroot paths do not poison account cookies", function()
    local value = session()
    local ok, _, changed = value:applySetCookie({ ["Set-Cookie"] = {
        "SESSDATA=wrong-path; Domain=.bilibili.com; Path=/unrelated",
        "unknown_cookie=synthetic-ignored; Domain=.bilibili.com; Path=/",
    } }, "passport.bilibili.com", now)
    check(ok and next(changed) == nil and value.cookies.SESSDATA == "synthetic-original" and value.cookies.unknown_cookie == nil,
        "Irrelevant cookies must not replace account authentication")
end)

test("Renewal secrets never enter account summaries or ordinary Codec records", function()
    local value = session()
    value.refresh_token, value.pending_refresh_token = "synthetic-secret-current", "synthetic-secret-previous"
    local summary = Codec.encode(value:summary())
    for _, marker in ipairs({ "synthetic-original", "synthetic-csrf", "synthetic-secret-current", "synthetic-secret-previous" }) do
        check(not summary:find(marker, 1, true), "Public summaries must omit each credential value")
    end
    for _, key in ipairs({ "cookies", "refresh_token", "pending_refresh_token", "refresh_csrf", "qrcode_key", "longtoken", "ReFrEsH_ToKeN" }) do
        local ok = pcall(Codec.encode, { harmless = { [key] = "synthetic-private-value" } })
        check(not ok, "Ordinary nested records must reject credential field " .. key)
    end
    check(not pcall(Codec.encode, value:serialize()), "Whole private sessions must never be accepted as ordinary records")
end)

test("Credential comparison ignores auxiliary cookie rotation but detects authentication changes", function()
    local original = session()
    original.refresh_token = "synthetic-refresh-stable"
    local auxiliary = Session.new(original:serialize())
    auxiliary.cookies.buvid3, auxiliary.cookies.b_lsid = "synthetic-device-new", "synthetic-visit-new"
    auxiliary.cookie_expires_at, auxiliary.refresh_checked_at = now + 600, now
    check(original:sameCredentials(auxiliary), "Auxiliary response cookies and timestamps must not create a new authentication generation")
    for _, field in ipairs({ "SESSDATA", "bili_jct", "refresh_token", "account_key" }) do
        local changed = Session.new(original:serialize())
        if field == "SESSDATA" or field == "bili_jct" then changed.cookies[field] = "synthetic-new-authentication"
        else changed[field] = "synthetic-new-authentication" end
        check(not original:sameCredentials(changed), "Credential comparison must notice a changed " .. field)
    end
end)

local RealClient = require("bilicomics/protocol/client")
local function responseClient(response)
    local requests = {}
    local client = RealClient.new{ session = session():serialize(), crypto = {}, clock = function() return now end,
        transport = { request = function(_, request)
            injected_requests = injected_requests + 1
            requests[#requests + 1] = request
            return response
        end } }
    return client, requests
end
test("Malformed optional Set-Cookie cannot erase successful purchase or favorite receipts", function()
    for _, endpoint in ipairs({ "BuyEpisode", "AddFavorite", "DeleteFavorite" }) do
        for _, body in ipairs({ '{"code":0,"data":{"accepted":true,"receipt":"synthetic-receipt"}}', '{"code":0}' }) do
            local client, requests = responseClient({ status = 200, transmitted = true, body = body,
                headers = { ["Set-Cookie"] = "SESSDATA=bad value; Domain=.bilibili.com; Path=/" } })
            local value, err = client:_post(endpoint == "BuyEpisode" and "comic.v1.Comic" or "bookshelf.v1.Bookshelf",
                endpoint, { synthetic = true }, { auth = true })
            check(value and value.accepted == true and err == nil, "A received " .. endpoint .. " acknowledgment must remain authoritative")
            check(#requests == 1 and requests[1].method == "POST", "A malformed optional cookie cannot resubmit a mutation")
            check(client.session.cookies.SESSDATA == "synthetic-original" and not client._session_changed,
                "Rejected optional response cookies must leave the previous private session intact")
        end
    end
end)

test("Business and authentication errors retain precedence over malformed response cookies", function()
    for _, response in ipairs({
        { status = 200, body = '{"code":-101,"data":{}}', expected = "authentication", code = -101 },
        { status = 200, body = '{"code":99,"data":{}}', expected = "purchase_unknown", code = 99 },
        { status = 200, body = '{"code":2,"data":{}}', expected = "purchase_rejected", code = 2 },
        { status = 200, body = '{"code":99,"data":{}}', expected = "business", code = 99, endpoint = "AddFavorite" },
        { status = 401, body = "Unauthorized", expected = "authentication" },
        { status = 403, body = "Forbidden", expected = "http" },
    }) do
        response.headers = { ["Set-Cookie"] = "SESSDATA=bad value; Domain=.bilibili.com; Path=/" }
        response.transmitted = true
        local client, requests = responseClient(response)
        local value, err = client:_post(response.endpoint and "bookshelf.v1.Bookshelf" or "comic.v1.Comic",
            response.endpoint or "BuyEpisode", { synthetic = true }, { auth = true })
        check(value == nil and err.kind == response.expected and (not response.code or err.code == response.code),
            "The original endpoint error must not be obscured by an optional cookie parsing error")
        check(#requests == 1 and client.session.cookies.SESSDATA == "synthetic-original", "Error handling must neither replay nor partially adopt malformed credentials")
    end
end)

local real_client = package.loaded["bilicomics/protocol/client"]
package.loaded["bilicomics/protocol/client"] = { new = function(options)
    local client = { session = Session.new(options.session) }
    function client:wallet(mode)
        if mode ~= "unchanged" then
            self.session.cookies.SESSDATA = "synthetic-pipe-rotated"
            self.session.cookie_expires_at = now + 600
            self._session_changed = mode == "truthy" and "yes" or true
        end
        if mode == "retryable" then return nil, { kind = "network", retryable = true } end
        return { remain_gold = 1, child_pid = tonumber(ffi.C.getpid()) }
    end
    return client
end }
package.loaded["bilicomics/jobs/worker"] = nil
local Worker = require("bilicomics/jobs/worker")
package.loaded["bilicomics/protocol/client"] = real_client
local function pipeFixture()
    local ui = { events = {}, held = 0 }
    function ui:scheduleIn(delay, callback) self.events[#self.events + 1] = { at = socket.gettime() + delay, callback = callback } end
    function ui:unschedule(callback)
        for index = #self.events, 1, -1 do if self.events[index].callback == callback then table.remove(self.events, index) end end
    end
    function ui:preventStandby() self.held = self.held + 1 end
    function ui:allowStandby() self.held = self.held - 1 end
    function ui:untilTrue(predicate)
        local deadline = socket.gettime() + 5
        while not predicate() and socket.gettime() < deadline do
            table.sort(self.events, function(a, b) return a.at < b.at end)
            if self.events[1] and self.events[1].at <= socket.gettime() then table.remove(self.events, 1).callback()
            else socket.sleep(0.002) end
        end
        assert(predicate(), "The private worker pipe did not complete before its deadline")
    end
    local runner = Runner.new{ ui = ui, interval = 0.003, worker = Worker.execute }
    active[#active + 1] = runner
    return runner, ui
end

test("Production Worker and real POSIX Runner carry updated cookies only in the private third result", function()
    local runner, ui = pipeFixture()
    local original = session()
    original.refresh_token = "synthetic-pipe-refresh"
    local calls = {}
    local identifier = runner:submit({ kind = "client", method = "wallet", arguments = { "changed" }, session = original:serialize() }, {},
        function(value, err, update) calls[#calls + 1] = { value = value, error = err, update = update } end)
    local child_pid = runner.tasks[identifier].pid
    ui:untilTrue(function() return #calls == 1 end)
    check(calls[1].value.child_pid == child_pid and child_pid ~= tonumber(ffi.C.getpid()), "The worker must execute in a real isolated child process")
    check(not calls[1].error and calls[1].update.cookies.SESSDATA == "synthetic-pipe-rotated"
        and calls[1].update.refresh_token == "synthetic-pipe-refresh", "The private third response must retain updated and existing credentials")
    check(not Codec.encode(calls[1].value):find("synthetic-pipe", 1, true) and calls[1].value.session_update == nil,
        "Business results must remain safe for ordinary persistence")
    check(original.cookies.SESSDATA == "synthetic-original" and ui.held == 0 and next(runner.tasks) == nil,
        "Forked session updates must not mutate the parent's source or leak worker holds")
    local status = ffi.new("int[1]")
    check(tonumber(ffi.C.waitpid(child_pid, status, ffi.C.WNOHANG)) == -1 and ffi.errno() == 10,
        "The real worker must be reaped before completion is delivered")
end)

test("Only a boolean changed marker permits a private worker update", function()
    for _, mode in ipairs({ "unchanged", "truthy" }) do
        local runner, ui = pipeFixture()
        local done, result, failure, update
        runner:submit({ kind = "client", method = "wallet", arguments = { mode }, session = session():serialize() }, {},
            function(value, err, changed) done, result, failure, update = true, value, err, changed end)
        ui:untilTrue(function() return done end)
        check(result and not failure and update == nil, "An absent or nonboolean change marker must not emit a private session snapshot")
    end
end)

test("A retryable failure with a private cookie update is returned before any raw retry", function()
    local runner, ui = pipeFixture()
    local done, result, failure, update
    local identifier = runner:submit({ kind = "client", method = "wallet", arguments = { "retryable" }, session = session():serialize() }, {},
        function(value, err, changed) done, result, failure, update = true, value, err, changed end)
    local task = runner.tasks[identifier]
    ui:untilTrue(function() return done end)
    check(result == nil and failure.kind == "network" and update.cookies.SESSDATA == "synthetic-pipe-rotated",
        "A private update must survive a retryable business failure")
    check(task.attempt == 1 and task.retries == 0 and #runner.queue == 0, "The raw Runner must not replay stale credentials before their update is adopted")
end)

local passed = true
for _, result in ipairs(tests) do passed = passed and result.passed end
local report = { passed = passed, groups = #tests, assertions = assertion_count, tests = tests,
    scope = "Production Session, Codec and Client with injected transport; private files; production Worker/Runner POSIX pipe with a synthetic Client",
    synthetic_credentials_only = true, real_worker_pipe = true, real_network_requests = 0,
    real_purchase_requests = 0, injected_transport_requests = injected_requests }
Files.write(output .. "/session-refresh-result.json", json.encode(report, { pretty = true }))
print(json.encode(report, { pretty = true }))
if not passed then os.exit(1) end
