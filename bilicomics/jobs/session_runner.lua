local Util = require("bilicomics/util")

local SessionRunner = {}
local read_methods = { listFavorites = true, listHistory = true, search = true, comicDetail = true,
    imageIndex = true, wallet = true, purchaseInfo = true, validateSession = true,
    getRechargeConfig = true, rechargeHistory = true }
local read_kinds = { library = true, quote = true, reconcile_purchase = true, download_page = true,
    download_cover = true, source_index = true, verify_source_page = true }
local mutations = { purchase_submit = true, set_favorite = true, recharge = true }
local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end
local function sameCredentials(first, second)
    return first == second or first and second and first:sameCredentials(second)
end

SessionRunner.__index = function(self, key)
    if SessionRunner[key] then return SessionRunner[key] end
    local raw = rawget(self, "_runner")
    local value = raw and raw[key]
    if type(value) == "function" then return function(_, ...) return value(raw, ...) end end
    return value
end
SessionRunner.__newindex = function(self, key, value)
    local raw = rawget(self, "_runner")
    if key:sub(1, 1) ~= "_" and raw and raw[key] ~= nil then raw[key] = value
    else rawset(self, key, value) end
end

local function bypass(request)
    return request.kind == "auth" or request.kind == "diagnostics"
        or (request.kind == "client" and request.method == "validateSession")
end

local function replayable(request)
    return read_kinds[request.kind] or request.kind == "client" and read_methods[request.method]
end

local function changedError(err)
    local result = copy(err)
    result.kind, result.retryable = "session_changed", false
    result.message = "The session was renewed. Check the operation result before trying again."
    return result
end

function SessionRunner.new(options)
    return setmetatable({ _runner = assert(options.runner), _manager = assert(options.manager),
        _get_session = assert(options.get_session), _is_current = options.is_current or function() return true end,
        _tasks = {}, _stopped = false, _suspended = false }, SessionRunner)
end

function SessionRunner:_finish(task, value, err)
    if task.done then return end
    task.done = true
    self._tasks[task.id] = nil
    Util.callback(task.callback, value, err)
end

function SessionRunner:_current(task)
    return not task.done and not self._stopped and self._is_current()
end

function SessionRunner:_maintain(task, force, callback)
    local completed = false
    local identifier = self._manager:ensure(function(session, err)
        completed = true
        task.waiter_id = nil
        if task.done then return end
        callback(session, err)
    end, force)
    if not completed and not task.done then task.waiter_id = identifier end
end

function SessionRunner:_result(task, value, err, session_update)
    task.raw_id = nil
    if task.done then return end
    if err and err.kind == "session_refresh" and err.code == "session_maintenance" and err.transmitted == false
        and not task.cancel_requested and self:_current(task) then
        self:_prepare(task)
        return
    end
    if session_update and self:_current(task) then
        local _, storage_error = self._manager:adoptResponse(session_update, task.started_session)
        if not value then err = err or storage_error end
    end
    if value or not err or err.kind ~= "authentication" or task.cancel_requested
        or not self:_current(task) then
        self:_finish(task, value, err)
        return
    end
    if not sameCredentials(task.started_session, self._get_session()) then
        if replayable(task.request) and not task.replayed then
            task.replayed = true
            self:_prepare(task)
        else self:_finish(task, value, changedError(err)) end
        return
    end
    local current = self._get_session()
    if not current or not current.refresh_token or current.refresh_blocked and not self._manager.active then
        self:_finish(task, value, err)
        return
    end
    if task.replayed and not self._manager.active and not current.confirmation_blocked then
        self:_finish(task, value, err)
        return
    end
    if mutations[task.request.kind] then task.observed = { value = value, error = err } end
    self:_maintain(task, true, function(_, maintenance_error)
        if maintenance_error then
            if maintenance_error.kind == "authentication" then self:_finish(task, value, err)
            else
                local result = copy(maintenance_error)
                if mutations[task.request.kind] then
                    result = copy(err)
                    result.kind, result.message = maintenance_error.kind, maintenance_error.message
                    result.maintenance_kind = maintenance_error.kind
                end
                self:_finish(task, value, result)
            end
        elseif replayable(task.request) and not task.replayed then
            task.replayed = true
            self:_dispatch(task)
        else self:_finish(task, value, changedError(err)) end
    end)
end

function SessionRunner:_dispatch(task)
    if not self:_current(task) then
        self:_finish(task, nil, Util.error("closed", "The account is no longer active.", { transmitted = false }))
        return
    end
    local options = copy(task.options)
    local before_start = options.before_start
    options.before_start = function()
        if not self:_current(task) then
            return false, Util.error("canceled", "The account is no longer active.", { transmitted = false })
        end
        local available, unavailable_error = self._manager:canDispatch()
        if not available then return false, unavailable_error end
        if before_start then
            local allowed, err = before_start()
            if allowed ~= true then return false, err end
        end
        task.started_session = self._get_session()
        task.request.session = task.started_session and task.started_session:serialize() or nil
        task.dispatch_started = true
        return true
    end
    -- Controlled runners may not execute before_start, so populate their request as well.
    task.started_session = self._get_session()
    task.request.session = task.started_session and task.started_session:serialize() or nil
    local completed = false
    local function done(value, err, session_update)
        completed = true
        self:_result(task, value, err, session_update)
    end
    local identifier
    if replayable(task.request) or task.request.kind == "recharge" then
        -- A submission exception inside a maintenance callback must still settle a read waiter.
        -- Recharge dispatch exceptions also settle the durable intent without replay.
        local ok
        ok, identifier = pcall(self._runner.submit, self._runner, task.request, options, done)
        if not ok then
            if not completed and not task.done then
                self:_finish(task, nil, Util.error("worker", "The background operation could not be scheduled.",
                    { transmitted = task.dispatch_started == true,
                        definitive = task.request.kind == "recharge" and not task.dispatch_started or nil, retryable = false }))
            end
            return
        end
    else identifier = self._runner:submit(task.request, options, done) end
    if not completed and not task.done then task.raw_id = identifier end
end

function SessionRunner:_prepare(task)
    self:_maintain(task, false, function(_, err)
        if err then
            err = copy(err)
            err.transmitted, err.definitive = false, true
            if err.kind == "authentication" then
                err.kind = "session_refresh"
                err.message = "Session maintenance could not verify the account. Try again or sign in again."
            end
            self:_finish(task, nil, err)
        else self:_dispatch(task) end
    end)
end

function SessionRunner:submit(request, options, callback)
    if bypass(request) then return self._runner:submit(request, options, callback) end
    if self._stopped then
        Util.callback(callback, nil, Util.error("closed", "The background service is closed.", { transmitted = false }))
        return nil
    end
    options = options or {}
    local identifier = options.id or Util.id("session-worker")
    assert(not self._tasks[identifier], "Duplicate session worker task")
    local task = { id = identifier, request = copy(request), options = copy(options), callback = callback }
    self._tasks[identifier] = task
    local session = self._get_session()
    if self._suspended and session and session.refresh_token then task.waiting_resume = true
    else self:_prepare(task) end
    return identifier
end

function SessionRunner:cancel(identifier)
    local task = self._tasks[identifier]
    if not task then return self._runner:cancel(identifier) end
    task.cancel_requested = true
    if task.raw_id then return self._runner:cancel(task.raw_id) end
    if task.waiter_id then self._manager:cancel(task.waiter_id); task.waiter_id = nil end
    if task.observed then self:_finish(task, task.observed.value, task.observed.error); return true end
    self:_finish(task, nil, Util.error("canceled", "The operation was canceled.", { transmitted = false }))
    return true
end

function SessionRunner:promote(identifier, priority)
    local task = self._tasks[identifier]
    if not task then return self._runner:promote(identifier, priority) end
    task.options.priority = math.min(task.options.priority or 40, priority)
    if task.raw_id then self._runner:promote(task.raw_id, priority) end
end

function SessionRunner:suspend()
    self._suspended = true
    self._manager:suspend()
    self._runner:suspend()
end

function SessionRunner:resume()
    if self._stopped then return end
    self._suspended = false
    self._manager:resume()
    local waiting = {}
    for _, task in pairs(self._tasks) do
        if task.waiting_resume then task.waiting_resume = nil; waiting[#waiting + 1] = task end
    end
    for _, task in ipairs(waiting) do self:_prepare(task) end
    self._runner:resume()
end

function SessionRunner:close()
    self._stopped = true
    self._manager:close()
    self._runner:close()
    local pending = {}
    for _, task in pairs(self._tasks) do pending[#pending + 1] = task end
    for _, task in ipairs(pending) do
        if task.observed then self:_finish(task, task.observed.value, task.observed.error)
        else self:_finish(task, nil, Util.error("closed", "The background service is closed.", { transmitted = false })) end
    end
end

return SessionRunner
