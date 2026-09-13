-- Research-only Android APK probe using the unmodified production Runner.
local ffi = require("ffi")
require("ffi/posix_h")
local json = require("rapidjson")
local socket = require("socket")
local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage")
local android = require("android")
local lfs = require("libs/libkoreader-lfs")
local sha = require("ffi/sha2")
local source = debug.getinfo(1, "S").source
local plugin_root = assert(source:match("^@(.+)/main%.lua$"))
package.path = plugin_root .. "/?.lua;" .. package.path
local Runner = require("bilicomics/jobs/runner")
local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a"); file:close(); return value
end
local function write(path, value)
    local file = assert(io.open(path, "wb"))
    assert(file:write(value)); assert(file:close())
end
local input = json.decode(assert(read(plugin_root .. "/jobs-probe-input.json")))
local run_root = android.dir .. "/bili-jobs-probe-" .. assert(input.run_id)
assert(lfs.mkdir(run_root))
local report_path = DataStorage:getDataDir() .. "/bili-jobs-android-result.json"
local report = { phase = "waiting_for_ui", run_id = input.run_id, research_only = true,
    synthetic_workers_only = true, ordinary_apk_process = true, plugin_root = plugin_root,
    private_run_root = run_root, ffi_arch = ffi.arch, ffi_os = ffi.os,
    pid = tonumber(ffi.C.getpid()), uid = tonumber(ffi.C.getuid()),
    selinux_context = read("/proc/self/attr/current"), source_sha256 = {},
    loaded_runner_source = debug.getinfo(Runner.new, "S").source, assertions = {}, scenarios = {} }
for _, relative in ipairs({ "bilicomics/jobs/runner.lua", "bilicomics/util.lua", "bilicomics/storage/codec.lua" }) do
    report.source_sha256[relative] = sha.sha256(assert(read(plugin_root .. "/" .. relative)))
end
local function save()
    write(report_path .. ".pending", json.encode(report))
    assert(os.rename(report_path .. ".pending", report_path))
end
save()

local Probe = { index = 0, finished = false, callbacks = {}, cases = {}, heartbeat_interval = 0.025 }
local function normalize(path) return path:gsub("/+", "/") end
local function expect(context, name, condition, detail)
    report.assertions[#report.assertions + 1] = { scenario = context.name, name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
local function decode(path)
    local bytes = read(path)
    if not bytes then return nil end
    local ok, value = pcall(json.decode, bytes)
    return ok and value or nil
end
local function worker(request)
    local count_path = request.root .. "/" .. request.name .. "-count.json"
    local record = decode(count_path) or { count = 0, pids = {} }
    record.count = record.count + 1
    record.pids[#record.pids + 1] = tonumber(ffi.C.getpid())
    write(count_path, json.encode(record))
    local evidence = { pid = tonumber(ffi.C.getpid()), uid = tonumber(ffi.C.getuid()), attempt = record.count }
    write(request.root .. "/" .. request.name .. "-started.json", json.encode(evidence))
    if request.name == "large" or request.name == "purchase" then
        local deadline = socket.gettime() + 4
        while not read(request.root .. "/" .. request.name .. "-release") do
            if socket.gettime() >= deadline then return nil, { kind = "synthetic_timeout", retryable = false } end
            socket.sleep(0.005)
        end
    elseif request.name == "cancel" or request.name == "timeout" or (request.name == "suspend" and record.count == 1) then
        socket.sleep(3)
    end
    if request.name == "large" then evidence.payload = string.rep("q", 1024 * 1024) end
    evidence.name = request.name
    return evidence
end
local function observedUI(context)
    local observed = { held = 0, acquired = 0, released = 0, scheduled = 0 }
    function observed:scheduleIn(delay, fn)
        self.scheduled = self.scheduled + 1
        UIManager:scheduleIn(delay, fn)
    end
    function observed:unschedule(fn) UIManager:unschedule(fn) end
    function observed:preventStandby()
        self.held, self.acquired = self.held + 1, self.acquired + 1
        UIManager:preventStandby()
    end
    function observed:allowStandby()
        self.held, self.released = self.held - 1, self.released + 1
        UIManager:allowStandby()
        assert(self.held >= 0, "Runner standby releases cannot underflow")
    end
    context.ui = observed
    return observed
end
function Probe:guard(context, fn)
    return function(...)
        if self.finished or self.current ~= context or context.closed then return end
        local ok, err = pcall(fn, ...)
        if not ok then self:finishCase(context, false, tostring(err)) end
    end
end
function Probe:later(context, delay, fn)
    local guarded = self:guard(context, fn)
    context.scheduled[#context.scheduled + 1] = guarded
    UIManager:scheduleIn(delay, guarded)
end
function Probe:waitFor(context, predicate, continuation)
    local poll
    poll = function()
        if predicate() then continuation(); return end
        assert(socket.gettime() < context.deadline, "Scenario exceeded its bounded deadline")
        self:later(context, 0.015, poll)
    end
    self:later(context, 0.015, poll)
end
function Probe:reaped(context, pid, label)
    local status = ffi.new("int[1]")
    local result = tonumber(ffi.C.waitpid(pid, status, ffi.C.WNOHANG))
    local errno = ffi.errno()
    expect(context, label .. " was already reaped by Runner", result == -1 and errno == 10,
        { pid = pid, waitpid = result, errno = errno })
end
function Probe:finishCase(context, passed, err)
    if context.closed then return end
    context.closed = true
    for _, fn in ipairs(context.scheduled) do UIManager:unschedule(fn) end
    local close_ok, close_error = pcall(context.runner.close, context.runner)
    context.maximum_gap = math.max(context.maximum_gap, socket.gettime() - context.last_heartbeat)
    local balanced = context.ui.held == 0 and context.ui.acquired == context.ui.released
    report.assertions[#report.assertions + 1] = { scenario = context.name,
        name = "All Runner standby ownership is balanced after cleanup", passed = balanced,
        detail = { held = context.ui.held, acquired = context.ui.acquired, released = context.ui.released } }
    local native_balanced = UIManager._prevent_standby_count == context.native_standby_baseline
    report.assertions[#report.assertions + 1] = { scenario = context.name,
        name = "Real UIManager standby count returns to its baseline", passed = native_balanced,
        detail = { before = context.native_standby_baseline, after = UIManager._prevent_standby_count } }
    local responsive = context.name ~= "large_pipe_and_ui_heartbeat" or context.maximum_gap < 0.25
    if context.name == "large_pipe_and_ui_heartbeat" then
        report.assertions[#report.assertions + 1] = { scenario = context.name,
            name = "Final response and cleanup retain the UI heartbeat bound", passed = responsive,
            detail = { maximum_gap = context.maximum_gap } }
    end
    report.scenarios[#report.scenarios + 1] = { name = context.name, passed = passed and close_ok and balanced and native_balanced and responsive,
        error = err or (not close_ok and tostring(close_error) or nil), elapsed_seconds = socket.gettime() - context.started,
        heartbeats = context.heartbeats, maximum_heartbeat_gap_seconds = context.maximum_gap,
        callbacks = context.callback_count, standby_acquired = context.ui.acquired,
        standby_released = context.ui.released, evidence = context.evidence }
    self.current = nil
    save()
    UIManager:scheduleIn(0.08, function() self:nextCase() end)
end
function Probe:nextCase()
    self.index = self.index + 1
    local definition = self.cases[self.index]
    if not definition then
        self.finished = true
        UIManager:unschedule(self.heartbeat)
        report.ok = true
        for _, item in ipairs(report.assertions) do report.ok = report.ok and item.passed end
        for _, item in ipairs(report.scenarios) do report.ok = report.ok and item.passed end
        report.phase = "complete"; save(); return
    end
    local now = socket.gettime()
    local context = { name = definition.name, started = now, deadline = now + 7, heartbeats = 0,
        last_heartbeat = now, maximum_gap = 0, scheduled = {}, callback_count = 0, evidence = {},
        native_standby_baseline = UIManager._prevent_standby_count }
    self.current = context
    context.runner = Runner.new({ ui = observedUI(context), worker = worker, interval = 0.01,
        max_workers = 1, max_payload = 2 * 1024 * 1024, retry_delay = 0.03 })
    report.phase = context.name; save()
    self:guard(context, function() definition.run(context) end)()
end
local function request(name, kind)
    return { kind = kind or "client", method = "comicDetail", name = name, root = run_root }
end
local function callback(context, handler)
    return Probe:guard(context, function(value, err)
        context.callback_count = context.callback_count + 1
        handler(value, err)
    end)
end
local function heartbeatGap(context)
    context.maximum_gap = math.max(context.maximum_gap, socket.gettime() - context.last_heartbeat)
    return context.maximum_gap
end
local function started(name) return decode(run_root .. "/" .. name .. "-started.json") end
local function counted(name) return decode(run_root .. "/" .. name .. "-count.json") end

Probe.cases = {
    { name = "large_pipe_and_ui_heartbeat", run = function(context)
        expect(context, "Probe runs in the ordinary Android application UID", report.uid >= 10000 and report.ffi_arch == "x86",
            { uid = report.uid, arch = report.ffi_arch, context = report.selinux_context })
        expect(context, "Runner is loaded from the staged unchanged production source",
            normalize(report.loaded_runner_source) == "@" .. normalize(plugin_root .. "/bilicomics/jobs/runner.lua"))
        for relative, digest in pairs(input.source_sha256) do
            expect(context, "Production source digest matches deployment: " .. relative, report.source_sha256[relative] == digest)
        end
        local id, child_pid, received
        id = context.runner:submit(request("large"), { timeout = 5, retry_attempts = 1 }, callback(context, function(value, err)
            expect(context, "Large response returns successfully", value and not err, err)
            expect(context, "The full 1 MiB payload is preserved", #value.payload == 1024 * 1024
                and value.payload == string.rep("q", 1024 * 1024))
            expect(context, "Large payload came from an actual app-UID child", value.pid == child_pid
                and value.pid ~= report.pid and value.uid == report.uid, { pid = value.pid, uid = value.uid })
            received = true
        end))
        local task = assert(context.runner.tasks[id])
        child_pid = tonumber(task.pid)
        local capacity = tonumber(ffi.C.fcntl(task.fd, 1032))
        context.evidence.pipe_capacity_bytes = capacity
        context.evidence.response_payload_bytes = 1024 * 1024
        expect(context, "Response is larger than the measured kernel pipe capacity", capacity > 0 and 1024 * 1024 > capacity)
        Probe:waitFor(context, function() return started("large") ~= nil end, function()
            local mark, initial_beats = socket.gettime(), context.heartbeats
            Probe:later(context, 0.35, function()
                local record = counted("large")
                expect(context, "The same real child remains blocked throughout the heartbeat window",
                    context.runner.tasks[id] and not received and record.count == 1 and not read(run_root .. "/large-release"))
                expect(context, "The real UI event loop continues while its worker is blocked",
                    context.heartbeats - initial_beats >= 6 and heartbeatGap(context) < 0.25,
                    { beats = context.heartbeats - initial_beats, interval = socket.gettime() - mark, maximum_gap = context.maximum_gap })
                write(run_root .. "/large-release", "release")
                Probe:waitFor(context, function() return received end, function()
                    expect(context, "Pipe drainage does not block the UI event loop", heartbeatGap(context) < 0.25,
                        { maximum_gap = context.maximum_gap })
                    Probe:reaped(context, child_pid, "Large-response child")
                    Probe:finishCase(context, true)
                end)
            end)
        end)
    end },
    { name = "cancel_and_reap", run = function(context)
        local settled
        local id = context.runner:submit(request("cancel"), { timeout = 4, retry_attempts = 1 }, callback(context, function(value, err)
            expect(context, "Canceled child reports one canceled outcome", not value and err and err.kind == "canceled", err)
            settled = true
        end))
        local pid = tonumber(context.runner.tasks[id].pid)
        Probe:waitFor(context, function() return started("cancel") ~= nil end, function()
            expect(context, "Started child accepts cancellation", context.runner:cancel(id))
            Probe:waitFor(context, function() return settled end, function()
                Probe:reaped(context, pid, "Canceled child")
                Probe:later(context, 0.08, function()
                    expect(context, "Cancellation callback is not duplicated", context.callback_count == 1)
                    Probe:finishCase(context, true)
                end)
            end)
        end)
    end },
    { name = "timeout_and_reap", run = function(context)
        local settled
        local id = context.runner:submit(request("timeout"), { timeout = 0.25, retry_attempts = 1 }, callback(context, function(value, err)
            expect(context, "Started slow child reports timeout", not value and err and err.kind == "timeout", err)
            settled = true
        end))
        local pid = tonumber(context.runner.tasks[id].pid)
        Probe:waitFor(context, function() return settled end, function()
            expect(context, "Timeout applies to a child that entered its worker", started("timeout") ~= nil and counted("timeout").count == 1)
            Probe:reaped(context, pid, "Timed-out child")
            expect(context, "Timeout settles once", context.callback_count == 1)
            Probe:finishCase(context, true)
        end)
    end },
    { name = "read_suspend_and_resume", run = function(context)
        local settled, final_pid
        local id = context.runner:submit(request("suspend"), { timeout = 4, retry_attempts = 1 }, callback(context, function(value, err)
            expect(context, "Resumed read returns the second actual attempt", value and not err and value.attempt == 2, err)
            settled, final_pid = true, value.pid
        end))
        local first_pid = tonumber(context.runner.tasks[id].pid)
        Probe:waitFor(context, function() return started("suspend") ~= nil end, function()
            context.runner:suspend()
            Probe:waitFor(context, function() return not next(context.runner.tasks) end, function()
                Probe:reaped(context, first_pid, "Suspended child")
                local schedules = context.ui.scheduled
                Probe:later(context, 0.18, function()
                    expect(context, "Suspended read retains only its queue entry", #context.runner.queue == 1
                        and context.callback_count == 0 and context.ui.held == 0 and counted("suspend").count == 1)
                    expect(context, "Suspended queue does not poll through UIManager", context.ui.scheduled == schedules and not context.runner.scheduled)
                    context.runner:resume()
                    Probe:waitFor(context, function() return settled end, function()
                        Probe:reaped(context, final_pid, "Resumed child")
                        expect(context, "Resume changes child PID and settles once", final_pid ~= first_pid and context.callback_count == 1)
                        Probe:finishCase(context, true)
                    end)
                end)
            end)
        end)
    end },
    { name = "purchase_suspend_does_not_resubmit", run = function(context)
        local order, pids = {}, {}
        local id = context.runner:submit(request("purchase", "purchase_submit"), { timeout = 5, priority = 40 }, callback(context, function(value, err)
            expect(context, "Synthetic purchase succeeds from its only attempt", value and not err and value.attempt == 1, err)
            order[#order + 1], pids[#pids + 1] = "purchase", value.pid
        end))
        local original_pid = tonumber(context.runner.tasks[id].pid)
        Probe:waitFor(context, function() return started("purchase") ~= nil end, function()
            context.runner:submit(request("urgent"), { priority = 0, retry_attempts = 1 }, callback(context, function(value, err)
                expect(context, "Urgent synthetic read eventually succeeds", value and not err, err)
                order[#order + 1], pids[#pids + 1] = "urgent", value.pid
            end))
            context.runner:suspend()
            Probe:later(context, 0.18, function()
                local task = context.runner.tasks[id]
                expect(context, "Purchase retains its original child across suspend and urgent work", task and tonumber(task.pid) == original_pid
                    and not task.cancel_kind and counted("purchase").count == 1 and context.callback_count == 0)
                context.runner:resume()
                write(run_root .. "/purchase-release", "release")
                Probe:waitFor(context, function() return #order == 2 end, function()
                    expect(context, "Purchase is never resent and completes before queued read", order[1] == "purchase"
                        and order[2] == "urgent" and counted("purchase").count == 1 and context.callback_count == 2)
                    for index, pid in ipairs(pids) do Probe:reaped(context, pid, "Purchase-order child " .. index) end
                    Probe:finishCase(context, true)
                end)
            end)
        end)
    end },
}
Probe.heartbeat = function()
    if Probe.finished then return end
    local context, now = Probe.current, socket.gettime()
    if context and not context.closed then
        context.maximum_gap = math.max(context.maximum_gap, now - context.last_heartbeat)
        context.last_heartbeat, context.heartbeats = now, context.heartbeats + 1
    end
    UIManager:scheduleIn(Probe.heartbeat_interval, Probe.heartbeat)
end
UIManager:scheduleIn(0.5, function()
    Probe.heartbeat()
    Probe:nextCase()
end)
return { disabled = true }
