local Session = require("bilicomics/protocol/session")
local SiteContext = require("bilicomics/protocol/site_context")
local Util = require("bilicomics/util")

local SessionManager = {}
SessionManager.__index = SessionManager

local function renewable(session)
    return session and type(session.refresh_token) == "string" and session.refresh_token ~= ""
        and session.refresh_blocked ~= true and session.confirmation_blocked ~= true
end

local function failure(kind, message)
    return Util.error(kind, message, { transmitted = false })
end

function SessionManager.new(options)
    options = options or {}
    local self = setmetatable({ runner = assert(options.runner), get_session = assert(options.get_session),
        save_session = assert(options.save_session), clock = options.clock or os.time,
        is_current = options.is_current or function() return true end, on_state = options.on_state,
        interval = options.interval or 6 * 60 * 60, waiters = {}, sequence = 0, epoch = 0,
        state = "ready", stopped = false, suspended = false }, SessionManager)
    if self.get_session() and self.get_session().confirmation_blocked then self.state = "confirmation_unknown" end
    return self
end

function SessionManager:_state(state, err)
    self.state, self.last_error = state, err
    if self.on_state then pcall(self.on_state, state, err) end
end

function SessionManager:_live(active)
    return self.active == active and active.epoch == self.epoch and not self.stopped
        and not self.suspended and self.is_current()
end

function SessionManager:_finish(active, session, err)
    if self.active ~= active then return end
    self.active = nil
    local state = err and "error" or session and session.confirmation_blocked and "confirmation_unknown" or "ready"
    self:_state(state, err or state == "confirmation_unknown" and self.confirmation_error or nil)
    local waiters = self.waiters
    self.waiters = {}
    for _, callback in pairs(waiters) do Util.callback(callback, session, err) end
end

function SessionManager:_ready(active, session)
    if not self:_live(active) then return end
    if SiteContext.hasDevice(session) and active.site_only and active.force_check and renewable(session) then
        active.site_only, active.force_check = nil, nil
        self:_check(active)
        return
    end
    if not SiteContext.needed(session) then self:_finish(active, session); return end
    self:_state("initializing_site")
    self:_auth(active, "ensureSiteContext", session, function(fields, err)
        if not fields then self:_finish(active, nil, err or failure("site_context", "The manga site could not be initialized.")); return end
        local candidate = Session.new(fields.session or fields)
        if not SiteContext.preservesSession(active.source, candidate) then
            self:_finish(active, nil, failure("account_mismatch", "Site initialization did not preserve the current account."))
            return
        end
        self:_persist(active, { session = candidate, source = active.source, checked = false,
            site_only = active.site_only, force_check = active.force_check })
    end)
end

function SessionManager:_returnReady(identifier, callback, session)
    if not SiteContext.needed(session) then Util.callback(callback, session); return end
    if self.suspended then
        Util.callback(callback, nil, failure("canceled", "Session maintenance is suspended."))
        return
    end
    self.waiters[identifier] = callback or function() end
    local active = { epoch = self.epoch, source = session, site_only = true }
    self.active = active
    self:_ready(active, session)
end

function SessionManager:_auth(active, method, session, callback, arguments)
    if not self:_live(active) then return end
    local completed = false
    local identifier = self.runner:submit({ kind = "auth", method = method, session = session:serialize(), arguments = arguments }, {
        priority = 0, timeout = 90, cancelable = true, retry_attempts = 1,
        before_start = function()
            if not self:_live(active) or self.get_session() ~= active.source then
                return false, failure("canceled", "The account changed before session maintenance started.")
            end
            return true
        end,
    }, function(value, err)
        completed = true
        if not self:_live(active) then return end
        active.task_id = nil
        if self.get_session() ~= active.source then
            self.candidate = nil
            self:_finish(active, self.get_session())
            return
        end
        callback(value, err)
    end)
    if not completed and self:_live(active) then active.task_id = identifier end
end

function SessionManager:_persist(active, candidate)
    if not self:_live(active) then return end
    if candidate.site_only then
        active.site_only = true
        active.force_check = active.force_check or candidate.force_check
        candidate.force_check = active.force_check
    end
    if self.get_session() ~= candidate.source then
        self.candidate = nil
        self:_finish(active, self.get_session())
        return
    end
    self.candidate = candidate
    local ok, saved, err = pcall(self.save_session, candidate.session)
    if not ok or saved ~= true then
        self:_finish(active, nil, type(err) == "table" and err
            or failure("storage", "The renewed session could not be saved safely."))
        return
    end
    self.candidate = nil
    active.source = self.get_session()
    if not active.source or active.source.account_key ~= candidate.session.account_key then
        self:_finish(active, nil, failure("account_mismatch", "The saved session account changed unexpectedly."))
        return
    end
    if candidate.terminal_error then
        self:_finish(active, nil, candidate.terminal_error)
    elseif candidate.blocked_error then
        self:_finish(active, nil, candidate.blocked_error)
    elseif active.source.pending_refresh_token then
        if active.source.confirmation_blocked then self:_ready(active, active.source)
        else self:_confirm(active) end
    else
        if candidate.checked ~= false then self.last_checked_at = self.clock() end
        self:_ready(active, active.source)
    end
end

function SessionManager:adoptResponse(fields, expected_session)
    if self.stopped or self.suspended or not self.is_current() or self.active or self.candidate
        or self.get_session() ~= expected_session then return true end
    local updated = Session.new(fields)
    if not expected_session or updated.account_key ~= expected_session.account_key
        or not updated.identity or not expected_session.identity
        or tostring(updated.identity.id) ~= tostring(expected_session.identity.id)
        or not updated.cookies.SESSDATA or not updated.validated_at then
        return nil, failure("account_mismatch", "The response session did not match the current account.")
    end
    local ok, saved, err = pcall(self.save_session, updated)
    if not ok or saved ~= true then
        err = type(err) == "table" and err or failure("storage", "The updated session could not be saved safely.")
        self.candidate = { session = updated, source = expected_session, checked = false }
        self:_state("error", err)
        return nil, err
    end
    return true
end

function SessionManager:_confirm(active)
    if active.source.confirmation_blocked then self:_ready(active, active.source); return end
    local marked = Session.new(active.source:serialize())
    marked.confirmation_blocked = true
    local ok, saved, save_error = pcall(self.save_session, marked)
    if not ok or saved ~= true then
        self:_finish(active, nil, type(save_error) == "table" and save_error
            or failure("storage", "The session confirmation marker could not be saved safely."))
        return
    end
    active.source = self.get_session()
    self:_state("pending_confirmation")
    self:_auth(active, "confirmRefresh", active.source, function(value, err)
        if not value then
            self.confirmation_error = err or failure("confirmation_unknown", "The renewed session confirmation is uncertain.")
            self:_ready(active, active.source)
            return
        end
        local cleaned = Session.new(active.source:serialize())
        cleaned.pending_refresh_token, cleaned.confirmation_blocked = nil, false
        self:_persist(active, { session = cleaned, source = active.source })
    end)
end

function SessionManager:_refresh(active, info)
    local input = info.session and Session.new(info.session) or active.source
    if input.account_key ~= active.source.account_key or not input.identity or not active.source.identity
        or tostring(input.identity.id) ~= tostring(active.source.identity.id) then
        self:_finish(active, nil, failure("account_mismatch", "The session check returned a different account."))
        return
    end
    if info.refresh then
        -- This marker must survive process death after a potentially transmitted refresh POST.
        local marked = Session.new(input:serialize())
        marked.refresh_blocked = true
        local ok, saved, err = pcall(self.save_session, marked)
        if not ok or saved ~= true then
            self:_finish(active, nil, type(err) == "table" and err
                or failure("storage", "The session renewal marker could not be saved safely."))
            return
        end
        active.source, active.marked = self.get_session(), true
        input = active.source
    end
    self:_state(info.refresh and "refreshing" or "checking")
    self:_auth(active, "refreshSession", input, function(value, err)
        if not value then
            if active.marked and err and (err.refresh_attempted == false or err.kind == "refresh_rejected") then
                local cleared = Session.new(active.source:serialize())
                cleared.refresh_blocked = false
                self:_persist(active, { session = cleared, source = active.source, checked = false, terminal_error = err })
            else
                self:_finish(active, nil, err or failure("session_refresh", "The session could not be checked."))
            end
            return
        end
        local refreshed = Session.new(value.session or value)
        if not refreshed.account_key or refreshed.account_key ~= active.source.account_key
            or not refreshed.identity or not active.source.identity
            or tostring(refreshed.identity.id) ~= tostring(active.source.identity.id)
            or not refreshed.validated_at or not refreshed.cookies.SESSDATA then
            self:_finish(active, nil, failure("account_mismatch", "Session renewal did not verify the current account."))
            return
        end
        refreshed.refresh_blocked = false
        self:_persist(active, { session = refreshed, source = active.source })
    end, { { info = info } })
end

function SessionManager:_check(active)
    self:_state("checking")
    self:_auth(active, "cookieInfo", active.source, function(info, err)
        if not info or type(info.refresh) ~= "boolean" then
            self:_finish(active, nil, err or failure("session_refresh", "The session renewal status could not be checked."))
            return
        end
        self:_refresh(active, info)
    end)
end

function SessionManager:ensure(callback, force)
    if force then
        local downstream = callback
        callback = function(session, err)
            if not err and session and session.confirmation_blocked then
                err = failure("confirmation_unknown", "Sign in again to restore automatic session renewal after an uncertain confirmation.")
                session = nil
            elseif not err and session and session.refresh_blocked then
                err = failure("refresh_unknown", "Sign in again to restore automatic session renewal.")
                session = nil
            end
            Util.callback(downstream, session, err)
        end
    end
    self.sequence = self.sequence + 1
    local identifier = self.sequence
    if self.stopped or not self.is_current() then
        Util.callback(callback, nil, failure("closed", "The account session service is closed."))
        return identifier
    end
    if self.active then
        if force and self.active.site_only and renewable(self.get_session()) then self.active.force_check = true end
        self.waiters[identifier] = callback or function() end
        return identifier
    end
    local session = self.get_session()
    if not self.candidate and session and session.confirmation_blocked then
        local err = failure("confirmation_unknown", "Sign in again to restore automatic session renewal after an uncertain confirmation.")
        self:_state("confirmation_unknown", self.confirmation_error or err)
        if force then Util.callback(callback, nil, err)
        else self:_returnReady(identifier, callback, session) end
        return identifier
    end
    if not self.candidate and not (session and session.pending_refresh_token) and not renewable(session) then
        if force and session and session.refresh_blocked then
            Util.callback(callback, nil, failure("refresh_unknown", "Sign in again to restore automatic session renewal."))
        else self:_returnReady(identifier, callback, session) end
        return identifier
    end
    if self.suspended then
        Util.callback(callback, nil, failure("canceled", "Session maintenance is suspended."))
        return identifier
    end
    if not self.active and not self.candidate and not session.pending_refresh_token and not force
        and self.last_checked_at and self.clock() >= self.last_checked_at
        and self.clock() - self.last_checked_at < self.interval then
        self:_returnReady(identifier, callback, session)
        return identifier
    end
    self.waiters[identifier] = callback or function() end
    if self.active then return identifier end
    local active = { epoch = self.epoch, source = session,
        site_only = self.candidate and self.candidate.site_only,
        force_check = self.candidate and self.candidate.site_only and renewable(session)
            and (force or self.candidate.force_check) or nil }
    self.active = active
    if self.candidate then self:_persist(active, self.candidate)
    elseif session.pending_refresh_token then self:_confirm(active)
    else self:_check(active) end
    return identifier
end

function SessionManager:canDispatch()
    if self.stopped or self.suspended or not self.is_current() then
        return false, failure("canceled", "The account session service is unavailable.")
    end
    if self.candidate or self.active then
        return false, Util.error("session_refresh", "Session maintenance must complete before this request can start.",
            { code = "session_maintenance", transmitted = false })
    end
    return true
end

function SessionManager:cancel(identifier)
    if not self.waiters[identifier] then return false end
    self.waiters[identifier] = nil
    if not next(self.waiters) and self.active then
        local active = self.active
        self.active = nil
        self.epoch = self.epoch + 1
        if active.task_id then self.runner:cancel(active.task_id) end
        if self.get_session() and self.get_session().confirmation_blocked then self:_state("confirmation_unknown") end
    end
    return true
end

function SessionManager:_stop(state)
    self.epoch = self.epoch + 1
    local active, waiters = self.active, self.waiters
    self.active, self.waiters = nil, {}
    self:_state(state)
    if active and active.task_id then self.runner:cancel(active.task_id) end
    local err = failure(state == "closed" and "closed" or "canceled", "Session maintenance was stopped.")
    for _, callback in pairs(waiters) do Util.callback(callback, nil, err) end
end

function SessionManager:suspend()
    self.suspended = true
    self:_stop("suspended")
end

function SessionManager:resume()
    if self.stopped then return end
    self.suspended = false
    self.last_checked_at = nil
    self:_state(self.get_session() and self.get_session().confirmation_blocked and "confirmation_unknown" or "ready")
end

function SessionManager:close()
    self.stopped = true
    self:_stop("closed")
end

return SessionManager
