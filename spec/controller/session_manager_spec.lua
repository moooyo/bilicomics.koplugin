-- Deterministic lifecycle checks with synthetic credentials and controlled asynchronous workers.
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
local function session(suffix, renewable)
    local refresh_token
    if renewable ~= false then refresh_token = "refresh-" .. suffix end
    local value = Session.new({ cookies = { SESSDATA = "synthetic-" .. suffix, bili_jct = "csrf-" .. suffix,
        DedeUserID = "42", buvid3 = "synthetic-existing-device" },
        refresh_token = refresh_token })
    assert(value:withIdentity({ id = "42", name = "Synthetic account" }, 100))
    return value
end
local function fixture(initial)
    local env = { current = initial or session("old"), saved = {}, now = 1000, live = true }
    local raw = { tasks = {}, count = 0, canceled = {}, order = {} }
    function raw:submit(request, options, callback)
        self.count = self.count + 1
        local id = "raw-" .. self.count
        self.tasks[id] = { id = id, request = request, options = options or {}, callback = callback }
        self.order[#self.order + 1] = id
        return id
    end
    function raw:find(kind, method)
        for _, id in ipairs(self.order) do
            local task = self.tasks[id]
            if task and task.request.kind == kind and (not method or task.request.method == method) then return task end
        end
    end
    function raw:start(task)
        if task.started then return true end
        local allowed, err = true
        if task.options.before_start then allowed, err = task.options.before_start() end
        if not allowed then self.tasks[task.id] = nil; task.callback(nil, err); return false end
        task.started = true
        return true
    end
    function raw:finish(task, value, err, update)
        assert(task, "A controlled worker is required")
        if not self:start(task) then return end
        self.tasks[task.id] = nil
        task.callback(value, err, update)
    end
    function raw:cancel(id)
        local task = self.tasks[id]
        if not task then return false end
        self.canceled[id] = true
        self.tasks[id] = nil
        task.callback(nil, { kind = "canceled", transmitted = task.started == true })
        return true
    end
    function raw:promote(id, priority) if self.tasks[id] then self.tasks[id].options.priority = priority end end
    function raw:suspend() self.suspended = true end
    function raw:resume() self.suspended = false end
    function raw:close()
        self.closed = true
        local pending = {}
        for _, task in pairs(self.tasks) do pending[#pending + 1] = task end
        for _, task in ipairs(pending) do self:cancel(task.id) end
    end
    env.raw = raw
    env.manager = SessionManager.new{ runner = raw, get_session = function() return env.current end,
        is_current = function() return env.live end, clock = function() return env.now end,
        save_session = function(value)
            if env.reject_save and env.reject_save(value) then return nil, { kind = "storage", transmitted = false } end
            env.current = Session.new(value:serialize())
            env.saved[#env.saved + 1] = env.current:serialize()
            return true
        end }
    env.runner = SessionRunner.new{ runner = raw, manager = env.manager, get_session = function() return env.current end,
        is_current = function() return env.live end }
    function env:info(refresh)
        self.raw:finish(self.raw:find("auth", "cookieInfo"), { refresh = refresh, timestamp = self.now * 1000 })
    end
    function env:refreshed(suffix)
        local value = suffix and session(suffix) or Session.new(self.current:serialize())
        value.refresh_blocked = false
        if suffix then value.pending_refresh_token = self.current.refresh_token; value.last_refreshed_at = self.now end
        value.refresh_checked_at = self.now
        self.raw:finish(self.raw:find("auth", "refreshSession"), value:serialize())
    end
    function env:confirm() self.raw:finish(self.raw:find("auth", "confirmRefresh"), true) end
    return env
end

local env = fixture()
local outcomes = {}
env.runner:submit({ kind = "client", method = "wallet" }, {}, function(value, err) outcomes.wallet = value or err end)
env.runner:submit({ kind = "library" }, { priority = 20 }, function(value, err) outcomes.library = value or err end)
check("startup_maintenance_is_single_flight", env.raw.count == 1 and env.raw:find("auth", "cookieInfo") ~= nil)
env:info(false)
check("no_refresh_does_not_mark_credentials_blocked", #env.saved == 0
    and env.raw:find("auth", "refreshSession").request.arguments[1].info.refresh == false)
env:refreshed()
check("successful_check_releases_all_waiters", env.raw:find("client", "wallet") and env.raw:find("library") and #env.saved == 1)
env.raw:finish(env.raw:find("client", "wallet"), { balance = 10 })
env.raw:finish(env.raw:find("library"), {})
check("business_results_reach_original_callbacks", outcomes.wallet.balance == 10 and type(outcomes.library) == "table")
local count = env.raw.count
env.runner:submit({ kind = "client", method = "wallet" }, {}, function() end)
check("checks_are_throttled_for_six_hours", env.raw.count == count + 1 and not env.raw:find("auth"))
env.now = env.now + 6 * 60 * 60
env.runner:submit({ kind = "library" }, {}, function() end)
check("check_runs_again_after_interval", env.raw:find("auth", "cookieInfo") ~= nil)

env = fixture()
env.runner:submit({ kind = "download_page", session = env.current:serialize() }, { priority = 10 }, function() end)
env:info(true)
check("refresh_marker_is_durable_before_rotation", env.current.refresh_blocked == true and #env.saved == 1
    and env.raw:find("auth", "refreshSession") ~= nil)
env:refreshed("fresh")
check("fresh_credentials_are_saved_before_confirm", #env.saved == 3 and env.current.refresh_token == "refresh-fresh"
    and env.current.pending_refresh_token == "refresh-old" and env.raw:find("auth", "confirmRefresh") ~= nil
    and env.current.confirmation_blocked == true and env.raw:find("download_page") == nil)
env:confirm()
check("confirmation_is_cleared_durably_before_business_dispatch", #env.saved == 4 and env.current.pending_refresh_token == nil
    and env.current.confirmation_blocked == false
    and env.raw:find("download_page").request.session.cookies.SESSDATA == "synthetic-fresh")

env = fixture()
local storage_error
env.reject_save = function(value) return value.refresh_token == "refresh-fresh" end
env.runner:submit({ kind = "library" }, {}, function(_, err) storage_error = err end)
env:info(true); env:refreshed("fresh")
check("save_failure_never_confirms_or_uses_old_credentials", storage_error.kind == "storage"
    and not env.raw:find("auth", "confirmRefresh") and not env.raw:find("library") and env.manager.candidate ~= nil)
count = env.raw.count
env.reject_save = nil
env.runner:submit({ kind = "library" }, {}, function() end)
check("failed_fresh_save_retries_without_rotating_again", env.raw.count == count + 1
    and env.raw:find("auth", "confirmRefresh") and env.current.refresh_token == "refresh-fresh")
env:confirm()
check("recovered_storage_unblocks_waiters", env.raw:find("library") ~= nil)

env = fixture()
env.reject_save = function() return true end
env.runner:submit({ kind = "library" }, {}, function() end)
env:info(true)
check("marker_save_failure_prevents_refresh_post", not env.raw:find("auth", "refreshSession") and not env.current.refresh_blocked)

env = fixture()
env.runner:submit({ kind = "library" }, {}, function() end)
env:info(true)
local rotating = env.raw:find("auth", "refreshSession")
env.raw:start(rotating)
env.raw:finish(rotating, nil, { kind = "refresh_unknown", transmitted = true, refresh_attempted = true })
check("ambiguous_refresh_keeps_durable_block_marker", env.current.refresh_blocked == true)
count = env.raw.count
env.runner:submit({ kind = "library" }, {}, function() end)
check("blocked_refresh_token_is_not_automatically_reused", env.raw.count == count + 1 and env.raw:find("library") ~= nil)

env = fixture()
env.runner:submit({ kind = "library" }, {}, function() end)
env:info(true)
env.raw:finish(env.raw:find("auth", "refreshSession"), nil, { kind = "network", refresh_attempted = false })
check("definite_pre_post_failure_clears_marker", env.current.refresh_blocked == false and #env.saved == 2)

env = fixture()
env.manager.last_checked_at = env.now
local recovered
env.runner:submit({ kind = "client", method = "wallet" }, {}, function(value, err) recovered = value or err end)
local first_read = env.raw:find("client", "wallet")
env.raw:start(first_read)
env.raw:finish(first_read, nil, { kind = "authentication", code = -101 })
check("authentication_failure_forces_maintenance", env.raw:find("auth", "cookieInfo") ~= nil and recovered == nil)
env:info(true); env:refreshed("renewed"); env:confirm()
local replay = env.raw:find("client", "wallet")
check("read_replays_with_new_credentials", replay and replay.request.session.cookies.SESSDATA == "synthetic-renewed")
env.raw:finish(replay, nil, { kind = "authentication", code = -101 })
check("authentication_replay_is_bounded", recovered.kind == "authentication" and not env.raw:find("auth"))

for _, kind in ipairs({ "purchase_submit", "set_favorite" }) do
    env = fixture()
    env.manager.last_checked_at = env.now
    local mutation_error
    env.runner:submit({ kind = kind }, { cancelable = false }, function(_, err) mutation_error = err end)
    env.raw:finish(env.raw:find(kind), nil, { kind = "authentication", code = -101, transmitted = true, definitive = true })
    env:info(true); env:refreshed("renewed"); env:confirm()
    check(kind .. "_never_replays_after_renewal", not env.raw:find(kind) and mutation_error.kind == "session_changed"
        and mutation_error.code == -101 and mutation_error.transmitted and mutation_error.definitive)
end

env = fixture()
env.manager.last_checked_at = env.now
local late_error
env.runner:submit({ kind = "purchase_submit" }, {}, function(_, err) late_error = err end)
local old_mutation = env.raw:find("purchase_submit")
env.raw:start(old_mutation)
env.current = session("external")
env.raw:finish(old_mutation, nil, { kind = "authentication", transmitted = true })
check("old_mutation_authentication_cannot_invalidate_new_session", late_error.kind == "session_changed" and not env.raw:find("auth"))

env = fixture()
local canceled
local first_id = env.runner:submit({ kind = "library" }, {}, function(_, err) canceled = err end)
local second_id = env.runner:submit({ kind = "client", method = "wallet" }, {}, function() end)
local checking = env.raw:find("auth", "cookieInfo")
env.runner:cancel(first_id)
check("canceling_one_waiter_preserves_shared_maintenance", canceled.kind == "canceled" and env.raw.tasks[checking.id] ~= nil)
env.runner:cancel(second_id)
checking.callback({ refresh = true, timestamp = env.now * 1000 })
check("canceling_last_waiter_prevents_late_mutation", env.raw.canceled[checking.id] and #env.saved == 0)

env = fixture()
env.runner:submit({ kind = "library" }, {}, function() end)
env:info(true)
rotating = env.raw:find("auth", "refreshSession")
env.raw:start(rotating)
env.runner:suspend()
local saved_before_late = #env.saved
rotating.callback(session("late"):serialize())
check("suspend_cancels_maintenance_and_ignores_late_credentials", env.raw.canceled[rotating.id]
    and #env.saved == saved_before_late and env.current.refresh_blocked == true)
env.runner:resume()
env.runner:close()
check("close_reaps_the_underlying_runner", env.raw.closed and env.manager.stopped)

env = fixture()
env.manager.last_checked_at = env.now
local rejected
env.runner:submit({ kind = "purchase_submit" }, { before_start = function() return false, { kind = "confirmation_required" } end },
    function(_, err) rejected = err end)
env.raw:start(env.raw:find("purchase_submit"))
check("business_before_start_guard_is_preserved", rejected.kind == "confirmation_required")

env = fixture()
env.manager.last_checked_at = env.now
env.runner:submit({ kind = "library", session = env.current:serialize() }, {}, function() end)
local queued = env.raw:find("library")
env.current = session("latest")
env.raw:start(queued)
check("queued_requests_use_session_at_actual_start", queued.request.session.cookies.SESSDATA == "synthetic-latest")

env = fixture()
env.manager.last_checked_at = env.now
local accepted, update_error
env.runner:submit({ kind = "purchase_submit" }, {}, function(value, err) accepted, update_error = value, err end)
env.reject_save = function() return true end
env.raw:finish(env.raw:find("purchase_submit"), { accepted = true }, nil, session("response"):serialize())
check("cookie_storage_failure_preserves_accepted_mutation", accepted.accepted and update_error == nil
    and env.manager.candidate ~= nil and env.manager.last_error.kind == "storage")

env = fixture()
env.current = session("imported", false)
local static_error
env.runner:submit({ kind = "library" }, {}, function(_, err) static_error = err end)
env.raw:finish(env.raw:find("library"), nil, { kind = "authentication" })
check("static_cookie_import_preserves_authentication_failure_behavior", static_error.kind == "authentication" and env.raw.count == 1)

env = fixture()
local undispatched
env.runner:submit({ kind = "purchase_submit" }, {}, function(_, err) undispatched = err end)
env:info(true)
env.raw:finish(env.raw:find("auth", "refreshSession"), nil,
    { kind = "refresh_unknown", transmitted = true, definitive = false, refresh_attempted = true })
check("pre_dispatch_auth_post_never_counts_as_purchase_transmission", undispatched.transmitted == false
    and undispatched.definitive == true and env.raw:find("purchase_submit") == nil)

env = fixture()
env.manager.last_checked_at = env.now
local canceled_mutation
local mutation_id = env.runner:submit({ kind = "purchase_submit" }, {}, function(_, err) canceled_mutation = err end)
env.raw:finish(env.raw:find("purchase_submit"), nil, { kind = "authentication", code = -101, transmitted = true })
env.runner:cancel(mutation_id)
check("cancel_during_maintenance_preserves_observed_purchase_evidence", canceled_mutation.kind == "authentication"
    and canceled_mutation.transmitted == true and canceled_mutation.code == -101)

env = fixture()
env.manager.last_checked_at = env.now
env.runner:submit({ kind = "client", method = "wallet" }, {}, function() end)
local auxiliary_update = Session.new(env.current:serialize())
auxiliary_update.cookies.buvid3 = "synthetic-device-cookie"
env.raw:finish(env.raw:find("client", "wallet"), nil, { kind = "authentication", code = -101 }, auxiliary_update:serialize())
check("auxiliary_cookie_update_does_not_skip_forced_renewal", env.raw:find("auth", "cookieInfo") ~= nil
    and env.raw:find("client", "wallet") == nil)

env = fixture()
env.current = session("pending")
env.current.pending_refresh_token = "refresh-before-restart"
env.runner:submit({ kind = "library" }, {}, function() end)
check("restart_confirms_durable_pending_session_before_new_check", env.raw:find("auth", "confirmRefresh") ~= nil
    and env.raw:find("auth", "cookieInfo") == nil)
env:confirm()
check("restart_clears_pending_before_business", env.current.pending_refresh_token == nil and env.raw:find("library") ~= nil)

env = fixture()
env.runner:submit({ kind = "library" }, {}, function() end)
env:info(true)
env.runner:submit({ kind = "client", method = "wallet" }, {}, function() end)
check("requests_join_rotation_after_block_marker_is_saved", not env.raw:find("library")
    and not env.raw:find("client", "wallet") and env.raw.count == 2)
env:refreshed("pending-save")
env.reject_save = function(value) return value.pending_refresh_token == nil end
env:confirm()
check("confirmation_cleanup_save_failure_blocks_business", env.manager.candidate ~= nil
    and env.current.pending_refresh_token ~= nil and not env.raw:find("library"))
env.reject_save = nil
count = env.raw.count
env.runner:submit({ kind = "library" }, {}, function() end)
check("confirmation_cleanup_retries_storage_without_reconfirming", env.current.pending_refresh_token == nil
    and not env.raw:find("auth") and env.raw.count == count + 1)

env = fixture()
env.manager.last_checked_at = env.now
env.runner:submit({ kind = "client", method = "wallet" }, {}, function() end)
local stale_read = env.raw:find("client", "wallet")
env.raw:start(stale_read)
env.current = session("already-renewed")
env.raw:finish(stale_read, nil, { kind = "authentication" })
check("stale_read_replays_without_a_second_rotation", env.raw:find("auth") == nil
    and env.raw:find("client", "wallet").request.session.cookies.SESSDATA == "synthetic-already-renewed")

env = fixture()
env.runner:submit({ kind = "library" }, {}, function() end)
local checked_session = Session.new(env.current:serialize())
checked_session.cookies.bili_jct = "csrf-from-info"
env.raw:finish(env.raw:find("auth", "cookieInfo"), { refresh = false, timestamp = env.now * 1000,
    session = checked_session:serialize() })
check("renewal_consumes_cookies_updated_by_cookie_info", env.raw:find("auth", "refreshSession").request.session.cookies.bili_jct == "csrf-from-info")

for _, kind in ipairs({ "download_page", "purchase_submit", "set_favorite" }) do
    env = fixture()
    env.manager.last_checked_at = env.now
    local completions = 0
    env.runner:submit({ kind = "client", method = "wallet" }, {}, function() end)
    local triggering = env.raw:find("client", "wallet")
    env.raw:start(triggering)
    env.runner:submit({ kind = kind }, {}, function() completions = completions + 1 end)
    queued = env.raw:find(kind)
    env.raw:finish(triggering, nil, { kind = "authentication" })
    env.raw:start(queued)
    check(kind .. "_queued_start_waits_for_in_progress_maintenance", completions == 0 and not env.raw.tasks[queued.id]
        and env.raw:find("auth", "cookieInfo") ~= nil)
    env:info(true); env:refreshed("queued-fresh"); env:confirm()
    local resumed = env.raw:find(kind)
    check(kind .. "_queued_wait_dispatches_once_after_maintenance", resumed ~= nil
        and resumed.request.session.cookies.SESSDATA == "synthetic-queued-fresh")
    env.raw:finish(resumed, { accepted = true })
    check(kind .. "_queued_wait_completes_callback_once", completions == 1)
end

env = fixture()
env.manager.last_checked_at = env.now
local concurrent_result
env.runner:submit({ kind = "client", method = "wallet" }, {}, function() end)
env.runner:submit({ kind = "library" }, {}, function(value, err) concurrent_result = value or err end)
local concurrent_first, concurrent_second = env.raw:find("client", "wallet"), env.raw:find("library")
env.raw:start(concurrent_first); env.raw:start(concurrent_second)
env.raw:finish(concurrent_first, nil, { kind = "authentication" })
env:info(true)
env.raw:finish(concurrent_second, nil, { kind = "authentication" })
env.runner:submit({ kind = "download_page" }, {}, function() end)
check("parallel_authentication_joins_rotation_despite_durable_block_marker", concurrent_result == nil
    and env.raw:find("auth", "refreshSession") ~= nil and not env.raw:find("download_page") and env.raw.count == 4)
env:refreshed("concurrent"); env:confirm()
check("parallel_authentication_releases_reads_with_one_rotation", env.raw:find("library") ~= nil
    and env.raw:find("client", "wallet") ~= nil and env.raw:find("download_page") ~= nil and not env.raw:find("auth"))

env = fixture()
env.runner:submit({ kind = "library" }, {}, function() end)
env:info(true); env:refreshed("unconfirmed")
local confirming = env.raw:find("auth", "confirmRefresh")
env.raw:start(confirming)
local durable_pending = env.current:serialize()
check("confirmation_attempt_marker_is_saved_before_post", durable_pending.confirmation_blocked == true
    and durable_pending.pending_refresh_token == "refresh-old")
env.runner:close()
local restarted = fixture(Session.new(durable_pending))
check("restart_reports_uncertain_confirmation_without_claiming_success", restarted.manager.state == "confirmation_unknown")
local readable
restarted.runner:submit({ kind = "library" }, {}, function(value, err) readable = value or err end)
restarted.raw:finish(restarted.raw:find("library"), { { id = "1" } })
check("lost_confirmation_response_survives_restart_without_repeating_post", restarted.raw.count == 1
    and not restarted.raw:find("auth") and restarted.current.pending_refresh_token == "refresh-old"
    and readable[1].id == "1" and restarted.manager.state == "confirmation_unknown")
local recovery_error
restarted.runner:submit({ kind = "client", method = "wallet" }, {}, function(_, err) recovery_error = err end)
restarted.raw:finish(restarted.raw:find("client", "wallet"), nil, { kind = "authentication" })
check("uncertain_confirmation_auth_failure_requests_new_login_without_rotation", recovery_error.kind == "confirmation_unknown"
    and not restarted.raw:find("auth") and restarted.current.refresh_token == "refresh-unconfirmed")

for _, kind in ipairs({ "network", "business", "authentication" }) do
    env = fixture()
    env.runner:submit({ kind = "library" }, {}, function() end)
    env:info(true); env:refreshed("confirmation-rejected")
    env.raw:finish(env.raw:find("auth", "confirmRefresh"), nil, { kind = kind, transmitted = true, code = -400 })
    check(kind .. "_confirmation_failure_preserves_saved_cookie_reading", env.current.confirmation_blocked == true
        and env.current.pending_refresh_token == "refresh-old" and env.manager.state == "confirmation_unknown"
        and env.raw:find("library") ~= nil)
    count = env.raw.count
    env.runner:submit({ kind = "client", method = "wallet" }, {}, function() end)
    check(kind .. "_confirmation_failure_does_not_repeat_confirm_or_refresh", env.raw.count == count + 1
        and env.raw:find("auth") == nil)
end

env = fixture(Session.new(durable_pending))
env.runner:submit({ kind = "library" }, {}, function() end)
local pending_update = Session.new(env.current:serialize())
pending_update.cookies.buvid3 = "updated-device-cookie"
env.reject_save = function() return true end
env.raw:finish(env.raw:find("library"), { { id = "2" } }, nil, pending_update:serialize())
check("uncertain_confirmation_cookie_update_failure_retains_retry_candidate", env.manager.candidate ~= nil)
env.reject_save = nil
env.runner:submit({ kind = "library" }, {}, function() end)
check("uncertain_confirmation_candidate_save_retry_never_repeats_confirmation", env.manager.candidate == nil
    and env.current.cookies.buvid3 == "updated-device-cookie" and env.current.confirmation_blocked
    and not env.raw:find("auth") and env.raw:find("library") ~= nil)

env = fixture()
env.runner:submit({ kind = "library" }, {}, function() end)
env:info(true); env:refreshed("confirmed-cleanup")
env.reject_save = function(value) return value.pending_refresh_token == nil end
env:confirm()
check("successful_confirmation_cleanup_failure_keeps_both_markers_durable", env.manager.candidate ~= nil
    and env.current.confirmation_blocked and env.current.pending_refresh_token == "refresh-old")
count = env.raw.count
env.reject_save = nil
env.runner:submit({ kind = "library" }, {}, function() end)
check("successful_confirmation_cleanup_retries_only_storage", env.raw.count == count + 1
    and env.current.confirmation_blocked == false and env.current.pending_refresh_token == nil
    and not env.raw:find("auth") and env.manager.state == "ready")

env = fixture()
env.manager.last_checked_at = env.now
local uncertain_replay_error
env.runner:submit({ kind = "client", method = "wallet" }, {}, function(_, err) uncertain_replay_error = err end)
env.raw:finish(env.raw:find("client", "wallet"), nil, { kind = "authentication" })
env:info(true); env:refreshed("replay-unconfirmed")
env.raw:finish(env.raw:find("auth", "confirmRefresh"), nil, { kind = "network", transmitted = true })
check("auth_failure_waiting_for_uncertain_confirmation_requires_new_login", uncertain_replay_error.kind == "confirmation_unknown"
    and not env.raw:find("auth") and not env.raw:find("client", "wallet") and env.manager.state == "confirmation_unknown")

env = fixture()
env.reject_save = function(value) return value.confirmation_blocked == true end
env.runner:submit({ kind = "library" }, {}, function() end)
env:info(true); env:refreshed("confirm-marker-storage")
check("confirmation_marker_save_failure_prevents_confirmation_post", not env.raw:find("auth", "confirmRefresh")
    and env.current.pending_refresh_token == "refresh-old" and env.current.confirmation_blocked == false)
env.reject_save = nil
count = env.raw.count
env.runner:submit({ kind = "library" }, {}, function() end)
check("confirmation_marker_save_retry_does_not_rotate_again", env.raw.count == count + 1
    and env.raw:find("auth", "confirmRefresh") ~= nil and env.current.confirmation_blocked == true
    and env.raw:find("auth", "refreshSession") == nil)

for _, kind in ipairs({ "client", "purchase_submit" }) do
    env = fixture(Session.new(durable_pending))
    local candidate_recovery_error
    env.runner:submit({ kind = "library" }, {}, function() end)
    env.runner:submit({ kind = kind, method = "wallet" }, {}, function(_, err) candidate_recovery_error = err end)
    local awaiting_authentication = env.raw:find(kind, kind == "client" and "wallet" or nil)
    env.raw:start(awaiting_authentication)
    local candidate_update = Session.new(env.current:serialize())
    candidate_update.cookies.buvid3 = "candidate-device-cookie"
    env.reject_save = function() return true end
    env.raw:finish(env.raw:find("library"), {}, nil, candidate_update:serialize())
    env.reject_save = nil
    env.raw:finish(awaiting_authentication, nil, { kind = "authentication", transmitted = true })
    check(kind .. "_forced_candidate_save_preserves_confirmation_unknown", env.manager.candidate == nil
        and candidate_recovery_error.kind == "confirmation_unknown" and not env.raw:find(kind)
        and not env.raw:find("auth") and env.raw.count == 2)
end

Files.write(output .. "/session-manager-result.json", json.encode({ count = #checks, assertions = checks,
    real_network = false, real_credentials = false }, { pretty = true }))
print(json.encode({ passed = true, count = #checks }))
