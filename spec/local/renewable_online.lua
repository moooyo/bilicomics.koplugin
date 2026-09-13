-- One bounded production favorites refresh; the observer never supplies or changes responses.
local Observer = {}
local function category(url)
    local path = type(url) == "string" and url:match("^https://[^/]+([^?]*)") or ""
    if path == "/x/passport-login/web/cookie/info" then return "cookie_info" end
    if path == "/x/web-interface/nav" then return "navigation" end
    if path == "/twirp/bookshelf.v1.Bookshelf/ListFavorite" then return "favorites" end
    if path == "/x/passport-login/web/cookie/refresh" then return "cookie_refresh" end
    if path == "/x/passport-login/web/confirm/refresh" then return "refresh_confirmation" end
    if path:match("^/correspond/1/") then return "correspondence" end
    if path:match("%.wasm$") then return "signing_asset" end
    if path:match("^/bfs/") then return "cover_or_asset" end
    return "other"
end
function Observer.install(profile)
    local Transport = require("bilicomics/protocol/transport")
    local JSON = require("bilicomics/protocol/json")
    local json = require("rapidjson")
    local guarded_request = Transport.request
    function Transport:request(request)
        local response, err = guarded_request(self, request)
        local name = category(request and request.url)
        local event = { category = name, response_received = response ~= nil,
            http_status = response and response.status, error_kind = err and err.kind }
        if name == "cookie_info" or name == "navigation" then
            local envelope = response and JSON.decode(response.body)
            event.business_code = envelope and tonumber(envelope.code)
            if envelope and type(envelope.data) == "table" then
                if name == "cookie_info" then event.refresh_required = envelope.data.refresh end
                if name == "navigation" then event.logged_in = envelope.data.isLogin == true end
            end
        end
        local file = assert(io.open(profile .. "/renewable-online-events.jsonl", "ab"))
        file:write(json.encode(event), "\n"); file:close()
        return response, err
    end
    return setmetatable({ profile = profile }, { __index = Observer })
end
function Observer:refreshOnce(app, done)
    assert(not self.started, "The native online acceptance action is one-shot")
    self.started = true
    local UIManager = require("ui/uimanager")
    local started = require("socket").gettime()
    local account = app.account
    assert(account.session and account.session_valid and account.session.refresh_token,
        "The online acceptance requires the current private renewable session")
    assert(account.session_manager.last_checked_at == nil, "The acceptance must observe the first online maintenance check")
    local before_workers = account.raw_runner.sequence or 0
    local callback_count = 0
    app:refreshLibrary("favorites", function(value, err)
        callback_count = callback_count + 1
        local function settle()
            local runner = account.raw_runner
            local idle = next(runner.tasks) == nil and #runner.queue == 0 and not account.session_manager.active
            if not idle and require("socket").gettime() - started < 60 then UIManager:scheduleIn(0.1, settle); return end
            local record = { callback_count = callback_count, callback_succeeded = value ~= nil,
                error_kind = err and err.kind, error_code = err and err.code,
                session_valid = account.session_valid == true, renewable_session = account.session.refresh_token ~= nil,
                session_manager_ready = account.session_manager.state == "ready",
                maintenance_checked = type(account.session_manager.last_checked_at) == "number",
                no_pending_rotation = account.session.pending_refresh_token == nil and not account.session.refresh_blocked,
                workers_settled = idle, worker_submissions = (runner.sequence or 0) - before_workers,
                same_active_account = app.account == account, production_runner = getmetatable(runner) == require("bilicomics/jobs/runner") }
            local file = assert(io.open(self.profile .. "/renewable-online-native.json", "wb"))
            file:write(require("rapidjson").encode(record), "\n"); file:close()
            done()
        end
        UIManager:nextTick(settle)
    end)
end
return Observer
