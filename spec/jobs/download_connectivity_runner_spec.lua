-- Run only in the isolated official KOReader runtime on test-env.
-- Real Runner scheduling and fork/IPC are exercised with local synthetic work.
require("setupkoenv")
local source, work, result_path = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path

local ffi = require("ffi")
require("ffi/posix_h")
local ffiutil = require("ffi/util")
local socket = require("socket")
local lfs = require("libs/libkoreader-lfs")
local Files = require("bilicomics/storage/files")
local Runner = require("bilicomics/jobs/runner")
local json = require("rapidjson")
local unpack = unpack or table.unpack
assert(ffi.os == "Linux", "This focused fork suite requires Linux")

local parent_pid = tonumber(ffi.C.getpid())
local report = { passed = false, tests = {}, assertions = {}, counts = {} }
local active_context, contexts, allow_more_cases = nil, {}, true
local original_fork = ffiutil.runInSubProcess
local original_worker_loaded = package.loaded["bilicomics/jobs/worker"]

local function pack(...)
    return { n = select("#", ...), ... }
end

local function check(context, name, condition)
    local label = context.name .. ": " .. name
    report.assertions[#report.assertions + 1] = { name = label, passed = not not condition }
    assert(condition, label)
end

local function write(path, value)
    Files.atomicWrite(path, json.encode(value), work)
end

local function read(path)
    return assert(json.decode(Files.read(path, 65536)))
end

-- Observe the original fork helper without replacing its child or IPC behavior.
ffiutil.runInSubProcess = function(...)
    local values = pack(original_fork(...))
    if tonumber(ffi.C.getpid()) == parent_pid then
        local pid = tonumber(values[1])
        if pid and pid > 0 then
            assert(active_context, "A real fork occurred outside a test case")
            active_context.forks[#active_context.forks + 1] = pid
        end
    end
    return unpack(values, 1, values.n)
end

local function scheduler()
    local ui = { pending = {}, held = 0, prevented = 0, allowed = 0, minimum = 0, ticks = 0 }
    function ui:scheduleIn(delay, callback)
        self.pending[callback] = socket.gettime() + delay
    end
    function ui:unschedule(callback)
        self.pending[callback] = nil
    end
    function ui:preventStandby()
        self.held, self.prevented = self.held + 1, self.prevented + 1
    end
    function ui:allowStandby()
        self.held, self.allowed = self.held - 1, self.allowed + 1
        self.minimum = math.min(self.minimum, self.held)
    end
    function ui:step()
        local callback, due
        for candidate, time in pairs(self.pending) do
            if not due or time < due then callback, due = candidate, time end
        end
        if callback and due <= socket.gettime() then
            self.pending[callback] = nil
            self.ticks = self.ticks + 1
            callback()
        else
            socket.sleep(0.002)
        end
    end
    return ui
end

local function await(context, predicate, name, timeout)
    local deadline = socket.gettime() + (timeout or 5)
    while not predicate() do
        assert(socket.gettime() < deadline, context.name .. ": timeout waiting for " .. name)
        context.ui:step()
    end
end

local function settle(context, seconds)
    local deadline = socket.gettime() + (seconds or 0.35)
    while socket.gettime() < deadline do context.ui:step() end
end

local function callback(context, name, after)
    local result = { count = 0 }
    context.callbacks[name] = result
    return function(value, err)
        result.count, result.value, result.error = result.count + 1, value, err
        if after then after(value, err) end
    end, result
end

local function guard(context, name, throws)
    context.guards[name] = { calls = 0, parent_only = true }
    return function()
        local state = context.guards[name]
        state.calls = state.calls + 1
        state.parent_only = state.parent_only and tonumber(ffi.C.getpid()) == parent_pid
        if throws then error("Synthetic before-start guard failure") end
        if not context.connected then
            return false, { kind = "network", code = "offline_before_start", retryable = true,
                transmitted = false, message = "The synthetic connection is offline before fork." }
        end
        return true
    end
end

local function workerCount(context, label)
    local count = 0
    for name in lfs.dir(context.root) do
        if name:match("^worker%-%d+%.json$") then
            local observed = read(context.root .. "/" .. name)
            if not label or observed.label == label then count = count + 1 end
        end
    end
    return count
end

local function workerStarted(context, label)
    return workerCount(context, label) > 0
end

local function release(context, gate)
    Files.write(context.root .. "/" .. gate, "released\n")
end

local function newContext(name, retry_delay)
    local context = { name = name, root = work .. "/" .. name, connected = true,
        forks = {}, guards = {}, callbacks = {}, runners = {}, ui = scheduler() }
    assert(lfs.symlinkattributes(context.root) == nil, "Each test requires a fresh directory")
    Files.mkdir(context.root)
    contexts[#contexts + 1] = context
    active_context = context
    local function worker(request)
        local pid = tonumber(ffi.C.getpid())
        assert(pid ~= parent_pid, "Synthetic work must run in a real child")
        write(context.root .. "/worker-" .. pid .. ".json", {
            label = request.label, pid = pid, parent_pid = tonumber(ffi.C.getppid()),
        })
        if request.gate then
            local deadline = socket.gettime() + 8
            while lfs.attributes(context.root .. "/" .. request.gate, "mode") ~= "file" do
                assert(socket.gettime() < deadline, "The local synthetic gate timed out")
                socket.sleep(0.005)
            end
        end
        if request.retryable_error then
            return nil, { kind = "network", code = "synthetic_worker_failure", retryable = true,
                transmitted = false, message = "A synthetic retryable read failure." }
        end
        return { label = request.label, pid = pid }
    end
    context.runner = Runner.new{ ui = context.ui, worker = worker, clock = socket.gettime,
        max_workers = 1, resource_limits = { image = 1 }, interval = 0.002,
        retry_delay = retry_delay or 0.08 }
    context.runners[1] = context.runner
    return context
end

local function request(context, label, options, mode, after)
    local done, result = callback(context, label, after)
    local payload = { kind = "download_page", label = label }
    for key, value in pairs(mode or {}) do payload[key] = value end
    local id = context.runner:submit(payload, options or { resource = "image" }, done)
    return id, result
end

local function checkOfflineResult(context, result)
    check(context, "the refused read receives exactly one callback", result.count == 1)
    check(context, "the callback preserves the guard error", result.value == nil and result.error
        and result.error.kind == "network" and result.error.code == "offline_before_start"
        and result.error.transmitted == false)
end

local function cleanup(context)
    local closed = true
    for _, runner in ipairs(context.runners) do
        local ok = pcall(runner.close, runner)
        closed = closed and ok and runner.stopped and next(runner.tasks) == nil and #runner.queue == 0
    end
    local reaped_by_runner, all_terminal, forced = true, true, 0
    for _, pid in ipairs(context.forks) do
        local status = ffi.new("int[1]")
        -- Linux WNOHANG is 1 and ECHILD is 10. ECHILD proves the Runner has
        -- already reaped this child, rather than merely leaving a zombie.
        local result = tonumber(ffi.C.waitpid(pid, status, 1))
        local child_error = ffi.errno()
        if result ~= -1 or child_error ~= 10 then reaped_by_runner = false end
        if result == 0 then
            forced = forced + 1
            ffi.C.kill(pid, 9)
            local deadline = socket.gettime() + 2
            repeat
                result = tonumber(ffi.C.waitpid(pid, status, 1))
                if result ~= 0 then break end
                socket.sleep(0.002)
            until socket.gettime() >= deadline
            if result == 0 then all_terminal = false end
        elseif result == -1 and child_error ~= 10 then
            all_terminal = false
        end
    end
    context.cleanup = { runners_closed = closed, children_reaped_by_runner = reaped_by_runner,
        all_children_terminal = all_terminal, forced_cleanup = forced }
    if not all_terminal then allow_more_cases = false end
    check(context, "every real Runner closes with no queued or active task", closed)
    check(context, "every child was reaped by the real Runner", reaped_by_runner and all_terminal and forced == 0)
    check(context, "standby holds balance once per actual fork", context.ui.held == 0
        and context.ui.prevented == context.ui.allowed and context.ui.prevented == #context.forks
        and context.ui.minimum == 0)
    check(context, "no Runner timer survives close", next(context.ui.pending) == nil)
    for name, observed in pairs(context.guards) do
        check(context, "guard " .. name .. " executes only in the parent", observed.parent_only)
    end
    for name in lfs.dir(context.root) do
        if name:match("^worker%-%d+%.json$") then
            local observed = read(context.root .. "/" .. name)
            check(context, "worker audit proves a real child", observed.pid ~= parent_pid and observed.parent_pid == parent_pid)
        end
    end
end

local function test(name, operation, retry_delay)
    if not allow_more_cases then
        report.tests[#report.tests + 1] = { name = name, passed = false, error = "Previous child cleanup was incomplete" }
        return
    end
    local context
    local ok, failure = pcall(function()
        context = newContext(name, retry_delay)
        operation(context)
    end)
    if context then
        local cleaned, cleanup_error = pcall(cleanup, context)
        if not cleaned then ok, failure = false, cleanup_error end
    end
    local result = { name = name, passed = ok }
    if not ok then result.error = tostring(failure) end
    if context then
        result.counts = { forks = #context.forks, worker_executions = workerCount(context),
            standby_prevented = context.ui.prevented, standby_allowed = context.ui.allowed }
        result.guards, result.cleanup = context.guards, context.cleanup
    end
    report.tests[#report.tests + 1] = result
    active_context = nil
end

local setup_ok, setup_error = pcall(function()
    Files.mkdir(work)

    test("queued_read_goes_offline_before_capacity_is_free", function(context)
        local runner = context.runner
        local _, first = request(context, "blocker", { priority = 10, resource = "image" }, { gate = "release-blocker" })
        await(context, function() return workerStarted(context, "blocker") end, "the blocking child")
        local id, second = request(context, "queued", { priority = 40, resource = "image", before_start = guard(context, "queued") })
        check(context, "the second read is queued without running its guard", #runner.queue == 1
            and runner.queue[1].id == id and context.guards.queued.calls == 0 and #context.forks == 1)
        context.connected = false
        release(context, "release-blocker")
        await(context, function() return first.count == 1 and second.count == 1 end, "the queued preflight decision")
        settle(context)
        check(context, "the already-started read still completes", first.value and not first.error)
        checkOfflineResult(context, second)
        check(context, "offline queue release performs no second fork", #context.forks == 1
            and workerCount(context, "queued") == 0 and context.guards.queued.calls == 1
            and next(runner.tasks) == nil and #runner.queue == 0)
    end)

    test("retry_backoff_rechecks_connectivity_before_fork", function(context)
        local runner = context.runner
        local id, result = request(context, "retry", { resource = "image", before_start = guard(context, "retry") },
            { retryable_error = true })
        await(context, function()
            return #runner.queue == 1 and runner.queue[1].id == id and runner.queue[1].retries == 1
                and next(runner.tasks) == nil
        end, "a real failed child entering retry backoff")
        check(context, "the first attempt failed before any final callback", result.count == 0
            and context.guards.retry.calls == 1 and #context.forks == 1
            and type(runner.queue[1].not_before) == "number")
        context.connected = false
        await(context, function() return result.count == 1 end, "the retry guard refusing a second fork")
        settle(context, 0.65)
        checkOfflineResult(context, result)
        check(context, "the backoff executes the guard again but never another child", context.guards.retry.calls == 2
            and #context.forks == 1 and workerCount(context, "retry") == 1
            and next(runner.tasks) == nil and #runner.queue == 0)
    end, 0.2)

    test("preempted_replay_rechecks_connectivity", function(context)
        local runner = context.runner
        local low_id, low = request(context, "low", { priority = 50, resource = "image", before_start = guard(context, "low") },
            { gate = "release-low" })
        await(context, function() return workerStarted(context, "low") end, "the low-priority real child")
        local _, urgent = request(context, "urgent", { priority = 0, resource = "image" }, { gate = "release-urgent" })
        check(context, "the low-priority task is genuinely preempted", runner.tasks[low_id]
            and runner.tasks[low_id].cancel_kind == "preempt")
        await(context, function() return workerStarted(context, "urgent") end, "the urgent child taking capacity")
        check(context, "the preempted task waits for replay without a callback", low.count == 0
            and #runner.queue == 1 and runner.queue[1].id == low_id and #context.forks == 2
            and context.guards.low.calls == 1)
        context.connected = false
        release(context, "release-urgent")
        await(context, function() return low.count == 1 and urgent.count == 1 end, "the replay guard rejecting offline work")
        settle(context)
        check(context, "the urgent task completes through its original child", urgent.value and not urgent.error)
        checkOfflineResult(context, low)
        check(context, "preemption replay performs no third fork", #context.forks == 2
            and workerCount(context, "low") == 1 and workerCount(context, "urgent") == 1
            and context.guards.low.calls == 2 and #runner.queue == 0 and next(runner.tasks) == nil)
    end)

    test("guard_exception_completes_once_without_fork", function(context)
        local _, result = request(context, "throwing", { resource = "image", before_start = guard(context, "throwing", true) },
            { retryable_error = true })
        settle(context)
        check(context, "a throwing guard produces one nontransmitted failure", result.count == 1 and result.value == nil
            and result.error and result.error.kind == "canceled" and result.error.transmitted == false)
        check(context, "the throwing guard never retries or forks", context.guards.throwing.calls == 1
            and #context.forks == 0 and workerCount(context) == 0)
    end)

    test("retryable_guard_denial_is_not_an_automatic_retry", function(context)
        context.connected = false
        local _, result = request(context, "denied", { resource = "image", before_start = guard(context, "denied") })
        settle(context)
        checkOfflineResult(context, result)
        check(context, "even a retryable guard error ends without a fork", context.guards.denied.calls == 1
            and #context.forks == 0 and workerCount(context) == 0)
    end)

    test("unguarded_read_keeps_existing_behavior", function(context)
        context.connected = false
        local _, result = request(context, "ordinary", { resource = "image" })
        await(context, function() return result.count == 1 end, "the unguarded synthetic read")
        settle(context, 0.05)
        check(context, "a read without a guard still executes normally", result.value and not result.error
            and result.value.label == "ordinary" and result.value.pid == context.forks[1]
            and #context.forks == 1 and workerCount(context, "ordinary") == 1 and next(context.guards) == nil)
    end)

    test("canceling_queued_read_never_restarts_its_guard", function(context)
        local runner = context.runner
        local _, first = request(context, "blocker", { priority = 10, resource = "image" }, { gate = "release-blocker" })
        await(context, function() return workerStarted(context, "blocker") end, "the original blocking child")
        local id, result = request(context, "canceled", { priority = 40, resource = "image", before_start = guard(context, "canceled") })
        check(context, "the queued read has not reached its guard", context.guards.canceled.calls == 0 and #runner.queue == 1)
        check(context, "cancel removes the queued task once", runner:cancel(id) and not runner:cancel(id))
        context.connected = false
        release(context, "release-blocker")
        await(context, function() return first.count == 1 end, "the original read completing")
        context.connected = true
        runner:resume()
        settle(context)
        check(context, "the canceled queued read receives one cancellation", result.count == 1 and result.value == nil
            and result.error and result.error.kind == "canceled" and result.error.transmitted == false)
        check(context, "reconnection does not run its guard or child", context.guards.canceled.calls == 0
            and #context.forks == 1 and workerCount(context, "canceled") == 0
            and #runner.queue == 0 and next(runner.tasks) == nil)
    end)

    test("guard_callback_suspend_stops_the_current_pump", function(context)
        local runner = context.runner
        context.connected = false
        runner:suspend()
        local _, first = request(context, "refused", { priority = 0, resource = "image", before_start = guard(context, "refused") },
            nil, function() runner:suspend() end)
        local second_id, second = request(context, "later", { priority = 10, resource = "image" })
        check(context, "both tasks start queued while suspended", #runner.queue == 2 and #context.forks == 0)
        runner:resume()
        settle(context, 0.05)
        checkOfflineResult(context, first)
        check(context, "callback suspension preserves the second task without a fork", runner.suspended
            and #runner.queue == 1 and runner.queue[1].id == second_id and second.count == 0 and #context.forks == 0)
        runner:resume()
        await(context, function() return second.count == 1 end, "the second explicit resume")
        check(context, "only the second explicit resume starts the remaining task", second.value and not second.error
            and #context.forks == 1 and workerCount(context, "later") == 1 and context.guards.refused.calls == 1)
    end)

    test("guard_callback_close_ends_the_current_pump", function(context)
        local runner = context.runner
        context.connected = false
        runner:suspend()
        local _, first = request(context, "refused", { priority = 0, resource = "image", before_start = guard(context, "refused") },
            nil, function() runner:close() end)
        local _, second = request(context, "later", { priority = 10, resource = "image" })
        runner:resume()
        runner:resume()
        settle(context)
        checkOfflineResult(context, first)
        check(context, "callback close cancels the remaining queued task once", runner.stopped and second.count == 1
            and second.value == nil and second.error and second.error.kind == "closed")
        check(context, "closed-pump reentry never forks or restarts the guard", #context.forks == 0
            and context.guards.refused.calls == 1 and #runner.queue == 0 and next(runner.tasks) == nil)
    end)
end)

-- Ensure an unexpected setup failure cannot bypass real Runner cleanup.
for _, context in ipairs(contexts) do
    if not context.cleanup then pcall(cleanup, context) end
end
ffiutil.runInSubProcess = original_fork
if not setup_ok then report.setup_error = tostring(setup_error) end
report.passed = setup_ok and #report.tests == 9
report.counts.tests, report.counts.assertions, report.counts.failed_tests = #report.tests, #report.assertions, 0
report.counts.real_forks, report.counts.standby_prevented, report.counts.standby_allowed = 0, 0, 0
for _, item in ipairs(report.tests) do
    if not item.passed then report.passed = false; report.counts.failed_tests = report.counts.failed_tests + 1 end
    if item.counts then
        report.counts.real_forks = report.counts.real_forks + item.counts.forks
        report.counts.standby_prevented = report.counts.standby_prevented + item.counts.standby_prevented
        report.counts.standby_allowed = report.counts.standby_allowed + item.counts.standby_allowed
    end
end
report.production_worker_not_loaded = package.loaded["bilicomics/jobs/worker"] == original_worker_loaded
report.passed = report.passed and report.production_worker_not_loaded
Files.write(result_path, json.encode(report, { pretty = true }))
print(json.encode({ passed = report.passed, tests = report.counts.tests, assertions = report.counts.assertions,
    failed_tests = report.counts.failed_tests, real_forks = report.counts.real_forks }))
if not report.passed then os.exit(1) end
