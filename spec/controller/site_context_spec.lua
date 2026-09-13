-- Deterministic site-context lifecycle checks with synthetic credentials and controlled workers.
require("setupkoenv")
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local Session = require("bilicomics/protocol/session")
local SessionManager = require("bilicomics/session_manager")
local SessionRunner = require("bilicomics/jobs/session_runner")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local checks = {}

local function check(name, condition)
    checks[#checks + 1] = { name = name, passed = not not condition }
    assert(condition, name)
end

local function clone(value)
    return Session.new(json.decode(json.encode(value:serialize())))
end

local function equal(first, second)
    if type(first) ~= type(second) then return false end
    if type(first) ~= "table" then return first == second end
    for key, value in pairs(first) do if not equal(value, second[key]) then return false end end
    for key in pairs(second) do if first[key] == nil then return false end end
    return true
end

local function withoutDevice(value)
    local fields = clone(value):serialize()
    fields.cookies.buvid3, fields.cookie_domains.buvid3 = nil, nil
    return fields
end

local function session(suffix, options)
    options = options or {}
    local value = Session.new({
        cookies = { SESSDATA = "synthetic-" .. suffix, bili_jct = "csrf-" .. suffix,
            DedeUserID = options.identity or "42", b_lsid = "existing-lsid", buvid4 = "existing-buvid4" },
        cookie_domains = { SESSDATA = "bilibili.com", bili_jct = "bilibili.com", b_lsid = "manga.bilibili.com" },
        refresh_token = options.renewable and "refresh-" .. suffix or nil,
        pending_refresh_token = options.pending and "refresh-previous" or nil,
        refresh_blocked = options.refresh_blocked, confirmation_blocked = options.confirmation_blocked,
        credential_generation = 7, imported_at = 90, refresh_checked_at = 80,
        last_refreshed_at = 70, cookie_expires_at = 30000,
    })
    assert(value:withIdentity({ id = options.identity or "42", name = "Synthetic account" }, 100))
    if options.device then
        value.cookies.buvid3, value.cookie_domains.buvid3 = "synthetic-existing-device", "manga.bilibili.com"
    end
    return value
end

local function deviceResult(value)
    local candidate = clone(value)
    candidate.cookies.buvid3, candidate.cookie_domains.buvid3 = "synthetic-restored-device", "manga.bilibili.com"
    return candidate
end

local function fixture(initial)
    local env = { current = initial or session("old"), saved = {}, save_attempts = 0,
        now = 1000, live = true, generation = 1 }
    local generation = env.generation
    local raw = { tasks = {}, count = 0, canceled = {}, order = {}, submitted = {} }
    function raw:submit(request, options, callback)
        self.count = self.count + 1
        local identifier = "site-raw-" .. self.count
        local task = { id = identifier, request = request, options = options or {}, callback = callback }
        self.tasks[identifier], self.submitted[#self.submitted + 1] = task, task
        self.order[#self.order + 1] = identifier
        return identifier
    end
    function raw:find(kind, method)
        for _, identifier in ipairs(self.order) do
            local task = self.tasks[identifier]
            if task and task.request.kind == kind and (not method or task.request.method == method) then return task end
        end
    end
    function raw:submittedCount(kind, method)
        local count = 0
        for _, task in ipairs(self.submitted) do
            if task.request.kind == kind and (not method or task.request.method == method) then count = count + 1 end
        end
        return count
    end
    function raw:start(task)
        assert(task, "A controlled worker is required")
        if task.started then return true end
        local allowed, err = true
        if task.options.before_start then allowed, err = task.options.before_start() end
        if allowed ~= true then self.tasks[task.id] = nil; task.callback(nil, err); return false end
        task.started = true
        return true
    end
    function raw:finish(task, value, err, update)
        if not self:start(task) then return end
        self.tasks[task.id] = nil
        task.callback(value, err, update)
    end
    function raw:cancel(identifier)
        local task = self.tasks[identifier]
        if not task then return false end
        self.canceled[identifier], self.tasks[identifier] = true, nil
        task.callback(nil, { kind = "canceled", transmitted = task.started == true })
        return true
    end
    function raw:promote(identifier, priority)
        if self.tasks[identifier] then self.tasks[identifier].options.priority = priority end
    end
    function raw:suspend() self.suspended = true end
    function raw:resume() self.suspended = false end
    function raw:close()
        self.closed = true
        local pending = {}
        for _, task in pairs(self.tasks) do pending[#pending + 1] = task end
        for _, task in ipairs(pending) do self:cancel(task.id) end
    end
    env.raw = raw
    local function current() return env.live and env.generation == generation end
    env.manager = SessionManager.new{ runner = raw, get_session = function() return env.current end,
        clock = function() return env.now end, is_current = current,
        save_session = function(value)
            env.save_attempts = env.save_attempts + 1
            if env.on_save then env.on_save(value) end
            if env.reject_save and env.reject_save(value) then return nil, { kind = "storage", transmitted = false } end
            env.current = clone(value)
            env.saved[#env.saved + 1] = env.current:serialize()
            return true
        end }
    env.runner = SessionRunner.new{ runner = raw, manager = env.manager,
        get_session = function() return env.current end, is_current = current }
    function env:initialize(candidate)
        self.raw:finish(self.raw:find("auth", "ensureSiteContext"), (candidate or deviceResult(self.current)):serialize())
    end
    function env:info(refresh)
        self.raw:finish(self.raw:find("auth", "cookieInfo"), { refresh = refresh, timestamp = self.now * 1000 })
    end
    function env:refreshed(suffix)
        local value = clone(self.current)
        value.refresh_blocked, value.refresh_checked_at = false, self.now
        if suffix then
            value.cookies.SESSDATA, value.cookies.bili_jct = "synthetic-" .. suffix, "csrf-" .. suffix
            value.pending_refresh_token, value.refresh_token = self.current.refresh_token, "refresh-" .. suffix
            value.last_refreshed_at = self.now
            value.credential_generation = value.credential_generation + 1
        end
        self.raw:finish(self.raw:find("auth", "refreshSession"), value:serialize())
    end
    function env:confirm() self.raw:finish(self.raw:find("auth", "confirmRefresh"), true) end
    return env
end

local modes = {
    { name = "static", options = {} },
    { name = "interval", options = { renewable = true }, recent = true },
    { name = "refresh_blocked", options = { renewable = true, refresh_blocked = true } },
    { name = "confirmation_blocked", options = { renewable = true, pending = true, confirmation_blocked = true } },
}

for _, mode in ipairs(modes) do
    local initial = session(mode.name, mode.options)
    local env = fixture(initial)
    if mode.recent then env.manager.last_checked_at = env.now end
    local checked_at = env.manager.last_checked_at
    check(mode.name .. "_construction_does_not_start_network", env.raw.count == 0 and #env.saved == 0)
    env.runner:submit({ kind = "library" }, {}, function() end)
    local initialization = env.raw:find("auth", "ensureSiteContext")
    check(mode.name .. "_missing_device_blocks_business", initialization ~= nil
        and env.raw:find("library") == nil and env.manager.state == "initializing_site"
        and equal(initialization.request.session, initial:serialize()))
    env:initialize()
    local business = env.raw:find("library")
    check(mode.name .. "_restoration_is_saved_before_dispatch", #env.saved == 1 and business ~= nil
        and business.request.session.cookies.buvid3 == "synthetic-restored-device"
        and env.raw:submittedCount("auth") == 1 and env.manager.last_checked_at == checked_at)
    check(mode.name .. "_restoration_preserves_credentials_and_markers",
        equal(withoutDevice(initial), withoutDevice(env.current)) and initial:sameCredentials(env.current)
        and env.current.credential_generation == 7)
    if mode.options.confirmation_blocked then
        check("restored_blocked_confirmation_stays_uncertain", env.manager.state == "confirmation_unknown"
            and env.current.pending_refresh_token == "refresh-previous" and env.current.confirmation_blocked)
    end

    initial = deviceResult(initial)
    env = fixture(initial)
    if mode.recent then env.manager.last_checked_at = env.now end
    env.runner:submit({ kind = "library" }, {}, function() end)
    check(mode.name .. "_existing_device_uses_no_initialization", env.raw.count == 1
        and env.raw:find("library") ~= nil and env.raw:submittedCount("auth", "ensureSiteContext") == 0
        and #env.saved == 0)
end

for _, marker in ipairs({ "refresh_blocked", "confirmation_blocked" }) do
    local options = { renewable = true, pending = marker == "confirmation_blocked" }
    options[marker] = true
    local env, result = fixture(session(marker, options))
    env.manager:ensure(function(_, err) result = err end, true)
    check(marker .. "_forced_recovery_keeps_original_block", result ~= nil
        and result.kind == (marker == "refresh_blocked" and "refresh_unknown" or "confirmation_unknown")
        and env.raw.count == 0 and #env.saved == 0)
end

local env = fixture()
local completed = 0
env.runner:submit({ kind = "library" }, {}, function() completed = completed + 1 end)
env.runner:submit({ kind = "client", method = "wallet" }, {}, function() completed = completed + 1 end)
env.runner:submit({ kind = "purchase_submit" }, {}, function() completed = completed + 1 end)
check("concurrent_business_waits_for_one_initialization", env.raw.count == 1 and completed == 0
    and env.raw:find("library") == nil and env.raw:find("client") == nil and env.raw:find("purchase_submit") == nil)
local checked_save = false
env.on_save = function()
    local allowed = env.manager:canDispatch()
    checked_save = allowed == false and completed == 0 and env.raw:find("library") == nil
        and env.raw:find("client") == nil and env.raw:find("purchase_submit") == nil
end
env:initialize()
check("durable_save_precedes_every_waiting_dispatch", checked_save and #env.saved == 1
    and env.raw:submittedCount("auth", "ensureSiteContext") == 1 and env.raw:find("library") ~= nil
    and env.raw:find("client", "wallet") ~= nil and env.raw:find("purchase_submit") ~= nil)
env.raw:finish(env.raw:find("library"), {})
env.raw:finish(env.raw:find("client", "wallet"), {})
env.raw:finish(env.raw:find("purchase_submit"), { accepted = true })
check("shared_initialization_completes_each_business_once", completed == 3)

env = fixture()
local storage_error
env.reject_save = function() return true end
env.runner:submit({ kind = "library" }, {}, function(_, err) storage_error = err end)
env:initialize()
check("failed_device_save_retains_candidate_without_dispatch", storage_error.kind == "storage"
    and storage_error.transmitted == false and env.current.cookies.buvid3 == nil
    and env.manager.candidate ~= nil and env.raw:find("library") == nil and env.save_attempts == 1)
env.reject_save = nil
env.runner:submit({ kind = "library" }, {}, function() end)
check("device_save_retry_never_repeats_initialization", env.save_attempts == 2 and #env.saved == 1
    and env.manager.candidate == nil and env.raw:submittedCount("auth", "ensureSiteContext") == 1
    and env.raw:find("library") ~= nil and env.manager.last_checked_at == nil)

env = fixture(session("renewable", { renewable = true }))
env.runner:submit({ kind = "library" }, {}, function() end)
check("renewable_missing_device_keeps_original_status_check", env.raw:find("auth", "cookieInfo") ~= nil
    and env.raw:find("auth", "ensureSiteContext") == nil)
env:info(false)
check("unchanged_session_validation_precedes_device_initialization", env.raw:find("auth", "refreshSession") ~= nil
    and env.raw:find("auth", "ensureSiteContext") == nil)
env:refreshed()
check("checked_session_is_saved_before_device_initialization", #env.saved == 1
    and env.raw:find("auth", "ensureSiteContext") ~= nil and env.raw:find("library") == nil
    and env.manager.last_checked_at == env.now)
env.reject_save = function(value) return value.cookies.buvid3 ~= nil end
env:initialize()
env.reject_save = nil
env.runner:submit({ kind = "library" }, {}, function() end)
check("site_save_retry_keeps_completed_maintenance_without_repeating_requests",
    env.raw:submittedCount("auth", "cookieInfo") == 1 and env.raw:submittedCount("auth", "refreshSession") == 1
    and env.raw:submittedCount("auth", "ensureSiteContext") == 1 and env.raw:find("library") ~= nil)
env.raw:finish(env.raw:find("library"), nil, { kind = "authentication", code = -101 })
check("device_restoration_does_not_replace_later_forced_maintenance", env.raw:find("auth", "cookieInfo") ~= nil
    and env.raw:find("library") == nil)

env = fixture(session("rotating", { renewable = true }))
env.runner:submit({ kind = "library" }, {}, function() end)
env:info(true)
check("renewal_marker_is_saved_before_rotation_without_device_read", env.current.refresh_blocked
    and #env.saved == 1 and env.raw:find("auth", "ensureSiteContext") == nil)
env:refreshed("rotated")
check("fresh_credentials_are_durable_before_confirmation_and_device_read", #env.saved == 3
    and env.current.cookies.SESSDATA == "synthetic-rotated" and env.current.pending_refresh_token == "refresh-rotating"
    and env.current.confirmation_blocked and env.raw:find("auth", "confirmRefresh") ~= nil
    and env.raw:find("auth", "ensureSiteContext") == nil)
env:confirm()
local renewed = clone(env.current)
check("confirmation_cleanup_precedes_device_initialization", #env.saved == 4
    and env.current.pending_refresh_token == nil and env.current.confirmation_blocked == false
    and env.raw:find("auth", "ensureSiteContext") ~= nil and env.raw:find("library") == nil)
env:initialize()
check("device_initialization_preserves_completed_renewal", #env.saved == 5
    and equal(withoutDevice(renewed), withoutDevice(env.current)) and env.raw:find("library") ~= nil
    and env.raw:submittedCount("auth", "confirmRefresh") == 1)

env = fixture(session("pending", { renewable = true, pending = true }))
env.runner:submit({ kind = "library" }, {}, function() end)
check("durable_pending_confirmation_starts_before_missing_device_recovery",
    env.raw:find("auth", "confirmRefresh") ~= nil and env.raw:find("auth", "ensureSiteContext") == nil
    and env.raw:find("auth", "cookieInfo") == nil)
env.raw:finish(env.raw:find("auth", "confirmRefresh"), nil, { kind = "network", transmitted = true })
local uncertain = clone(env.current)
env.reject_save = function(value) return value.cookies.buvid3 ~= nil end
env:initialize()
env.reject_save = nil
env.runner:submit({ kind = "library" }, {}, function() end)
check("uncertain_confirmation_survives_device_storage_retry", equal(withoutDevice(uncertain), withoutDevice(env.current))
    and env.manager.state == "confirmation_unknown" and env.raw:submittedCount("auth", "confirmRefresh") == 1
    and env.raw:submittedCount("auth", "ensureSiteContext") == 1 and env.raw:find("library") ~= nil)

env = fixture()
local canceled_first, second_completions = nil, 0
local first_id = env.runner:submit({ kind = "library" }, {}, function(_, err) canceled_first = err end)
local second_id = env.runner:submit({ kind = "client", method = "wallet" }, {}, function() second_completions = second_completions + 1 end)
local initialization = env.raw:find("auth", "ensureSiteContext")
env.runner:cancel(first_id)
check("canceling_one_site_waiter_preserves_shared_initialization", canceled_first.kind == "canceled"
    and env.raw.tasks[initialization.id] ~= nil and not env.raw.canceled[initialization.id])
env:initialize()
check("remaining_site_waiter_dispatches_without_canceled_business", env.raw:find("library") == nil
    and env.raw:find("client", "wallet") ~= nil and #env.saved == 1)
env.raw:finish(env.raw:find("client", "wallet"), {})
check("remaining_site_waiter_completes_once", second_completions == 1)

env = fixture()
local canceled_count = 0
first_id = env.runner:submit({ kind = "library" }, {}, function() canceled_count = canceled_count + 1 end)
second_id = env.runner:submit({ kind = "client", method = "wallet" }, {}, function() canceled_count = canceled_count + 1 end)
initialization = env.raw:find("auth", "ensureSiteContext")
local late = deviceResult(env.current):serialize()
env.raw:start(initialization)
env.runner:cancel(first_id)
env.runner:cancel(second_id)
initialization.callback(late)
check("last_site_waiter_cancellation_discards_late_result", canceled_count == 2
    and env.raw.canceled[initialization.id] and #env.saved == 0 and env.manager.active == nil
    and env.current.cookies.buvid3 == nil and env.raw:find("library") == nil and env.raw:find("client") == nil)
env.runner:submit({ kind = "library" }, {}, function() end)
check("canceled_site_initialization_can_be_retried", env.raw:submittedCount("auth", "ensureSiteContext") == 2)
env:initialize()
check("retried_site_initialization_publishes_once", #env.saved == 1 and env.raw:find("library") ~= nil)

for _, action in ipairs({ "suspend", "close", "account_generation" }) do
    env = fixture()
    local completions, result = 0
    env.runner:submit({ kind = "library" }, {}, function(_, err) completions, result = completions + 1, err end)
    initialization = env.raw:find("auth", "ensureSiteContext")
    late = deviceResult(env.current):serialize()
    env.raw:start(initialization)
    if action == "account_generation" then env.generation = env.generation + 1; env.runner:close()
    else env.runner[action](env.runner) end
    initialization.callback(late)
    check(action .. "_prevents_late_site_publication", completions == 1 and result ~= nil
        and #env.saved == 0 and env.current.cookies.buvid3 == nil and env.raw.canceled[initialization.id]
        and env.raw:find("library") == nil)
    if action == "suspend" then
        env.runner:resume()
        env.runner:submit({ kind = "library" }, {}, function() end)
        env:initialize()
        check("resumed_site_initialization_uses_a_new_epoch", #env.saved == 1
            and env.raw:submittedCount("auth", "ensureSiteContext") == 2 and env.raw:find("library") ~= nil)
    end
end

env = fixture()
env.runner:suspend()
local suspended_error
env.runner:submit({ kind = "library" }, {}, function(_, err) suspended_error = err end)
check("suspended_static_session_cannot_start_device_initialization", suspended_error.kind == "canceled"
    and env.raw.count == 0 and #env.saved == 0)

for _, started in ipairs({ false, true }) do
    env = fixture()
    env.runner:submit({ kind = "library" }, {}, function() end)
    initialization = env.raw:find("auth", "ensureSiteContext")
    late = deviceResult(env.current):serialize()
    if started then env.raw:start(initialization) end
    env.current = session("replacement", { device = true })
    env.current.credential_generation = 8
    env.raw:finish(initialization, late)
    local business = env.raw:find("library")
    check((started and "inflight" or "queued") .. "_site_result_cannot_overwrite_replaced_session",
        #env.saved == 0 and env.current.cookies.SESSDATA == "synthetic-replacement"
        and env.current.credential_generation == 8 and business ~= nil
        and business.request.session.cookies.SESSDATA == "synthetic-replacement")
end

for _, kind in ipairs({ "network", "protocol", "authentication" }) do
    env = fixture()
    local result
    env.runner:submit({ kind = "purchase_submit" }, {}, function(_, err) result = err end)
    env.raw:finish(env.raw:find("auth", "ensureSiteContext"), nil,
        { kind = kind, code = -101, transmitted = true, definitive = false })
    check(kind .. "_device_failure_preserves_untransmitted_business", result ~= nil
        and result.kind == (kind == "authentication" and "session_refresh" or kind)
        and result.transmitted == false and result.definitive == true and #env.saved == 0
        and env.raw:find("purchase_submit") == nil and env.manager.candidate == nil)
    env.runner:submit({ kind = "library" }, {}, function() end)
    check(kind .. "_device_failure_allows_explicit_retry", env.raw:submittedCount("auth", "ensureSiteContext") == 2)
end

local mutations = {
    { "session_cookie", function(value) value.cookies.SESSDATA = "synthetic-other" end },
    { "csrf_cookie", function(value) value.cookies.bili_jct = "csrf-other" end },
    { "account_cookie", function(value) value.cookies.DedeUserID = "84" end },
    { "auxiliary_cookie", function(value) value.cookies.b_lsid = "other-lsid" end },
    { "other_device_cookie", function(value) value.cookies.buvid4 = "other-buvid4" end },
    { "credential_domain", function(value) value.cookie_domains.SESSDATA = "manga.bilibili.com" end },
    { "identity", function(value) value.identity = { id = "84", name = "Other account" } end },
    { "identity_name", function(value) value.identity.name = "Unexpected name" end },
    { "account_key", function(value) value.account_key = "bili_84" end },
    { "validation_time", function(value) value.validated_at = value.validated_at + 1 end },
    { "import_time", function(value) value.imported_at = value.imported_at + 1 end },
    { "refresh_token", function(value) value.refresh_token = "refresh-other" end },
    { "pending_token", function(value) value.pending_refresh_token = nil end },
    { "refresh_check_time", function(value) value.refresh_checked_at = value.refresh_checked_at + 1 end },
    { "last_refresh_time", function(value) value.last_refreshed_at = value.last_refreshed_at + 1 end },
    { "cookie_expiry", function(value) value.cookie_expires_at = value.cookie_expires_at + 1 end },
    { "credential_generation", function(value) value.credential_generation = value.credential_generation + 1 end },
    { "refresh_marker", function(value) value.refresh_blocked = false end },
    { "confirmation_marker", function(value) value.confirmation_blocked = false end },
    { "missing_device", function(value) value.cookies.buvid3 = nil end },
    { "unusable_device_domain", function(value) value.cookie_domains.buvid3 = "passport.bilibili.com" end },
}
for _, mutation in ipairs(mutations) do
    env = fixture(session("protected", { renewable = true, pending = true,
        refresh_blocked = true, confirmation_blocked = true }))
    local original, result = clone(env.current)
    env.runner:submit({ kind = "library" }, {}, function(_, err) result = err end)
    local candidate = deviceResult(env.current)
    mutation[2](candidate)
    env:initialize(candidate)
    check("device_candidate_rejects_changed_" .. mutation[1], result ~= nil and result.kind == "account_mismatch"
        and #env.saved == 0 and env.manager.candidate == nil and env.raw:find("library") == nil
        and equal(original:serialize(), env.current:serialize()))
end

-- A force waiter must not mistake auxiliary-cookie recovery for an authentication check.
env = fixture(session("joining-force", { renewable = true }))
env.manager.last_checked_at = env.now
local ordinary_completed, forced_completed = false, false
env.manager:ensure(function() ordinary_completed = true end)
env.manager:ensure(function(_, err) forced_completed = err or true end, true)
env:initialize()
check("forced_waiter_joining_site_initialization_still_checks_authentication",
    forced_completed == false and env.raw:find("auth", "cookieInfo") ~= nil
    and env.raw:submittedCount("auth", "ensureSiteContext") == 1)
env:info(false)
env:refreshed()
check("joined_forced_maintenance_completes_after_authentication_check", ordinary_completed and forced_completed == true
    and env.raw:submittedCount("auth", "cookieInfo") == 1 and env.raw:submittedCount("auth", "ensureSiteContext") == 1)

env = fixture(session("saved-force", { renewable = true }))
env.manager.last_checked_at = env.now
env.reject_save = function(value) return value.cookies.buvid3 ~= nil end
env.manager:ensure(function() end)
env:initialize()
env.reject_save = nil
forced_completed = false
env.manager:ensure(function(_, err) forced_completed = err or true end, true)
check("forced_device_candidate_save_retry_does_not_skip_authentication",
    forced_completed == false and env.manager.candidate == nil and env.raw:find("auth", "cookieInfo") ~= nil
    and env.raw:submittedCount("auth", "ensureSiteContext") == 1)
env:info(false)
env:refreshed()
check("forced_candidate_retry_reuses_saved_device_and_finishes_maintenance", forced_completed == true
    and env.raw:submittedCount("auth", "cookieInfo") == 1 and env.raw:submittedCount("auth", "ensureSiteContext") == 1)

env = fixture(session("repeated-storage", { renewable = true }))
env.manager.last_checked_at = env.now
env.reject_save = function(value) return value.cookies.buvid3 ~= nil end
env.manager:ensure(function() end)
env:initialize()
local forced_storage_error
env.manager:ensure(function(_, err) forced_storage_error = err end, true)
check("failed_forced_candidate_save_keeps_pending_authentication_requirement",
    forced_storage_error ~= nil and forced_storage_error.kind == "storage" and env.save_attempts == 2
    and env.current.cookies.buvid3 == nil and env.raw:submittedCount("auth", "ensureSiteContext") == 1
    and env.raw:find("auth", "cookieInfo") == nil)
env.reject_save = nil
ordinary_completed = false
env.manager:ensure(function(_, err) ordinary_completed = err or true end)
check("ordinary_retry_after_forced_storage_failure_still_checks_authentication",
    ordinary_completed == false and env.manager.candidate == nil and env.raw:find("auth", "cookieInfo") ~= nil
    and env.raw:submittedCount("auth", "ensureSiteContext") == 1)
env:info(false)
env:refreshed()
check("repeated_storage_failure_recovery_completes_with_one_device_read", ordinary_completed == true
    and env.raw:submittedCount("auth", "cookieInfo") == 1 and env.raw:submittedCount("auth", "ensureSiteContext") == 1)

Files.write(output .. "/site-context-manager-result.json", json.encode({ count = #checks, assertions = checks,
    real_network = false, real_credentials = false }, { pretty = true }))
print(json.encode({ passed = true, count = #checks }))
