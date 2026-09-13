-- Exercise real POSIX children and pipes only on the remote test-env host.
require("setupkoenv")
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. package.path
local Runner = require("bilicomics/jobs/runner")
local ffiutil = require("ffi/util")
local ffi = require("ffi")
local socket = require("socket")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local Files = require("bilicomics/storage/files")
local tests, active = {}, {}
local function check(condition, message) assert(condition, message) end
local function ui()
    local state = { events = {}, held = 0, acquired = 0, released = 0, ticks = 0 }
    function state:scheduleIn(delay, callback)
        self.events[#self.events + 1] = { due = socket.gettime() + delay, callback = callback }
    end
    function state:unschedule(callback)
        for index = #self.events, 1, -1 do
            if self.events[index].callback == callback then table.remove(self.events, index) end
        end
    end
    function state:preventStandby() self.held, self.acquired = self.held + 1, self.acquired + 1 end
    function state:allowStandby()
        self.held, self.released = self.held - 1, self.released + 1
        check(self.held >= 0, "Standby release cannot underflow")
    end
    function state:step()
        table.sort(self.events, function(a, b) return a.due < b.due end)
        if self.events[1] and self.events[1].due <= socket.gettime() then
            self.ticks = self.ticks + 1
            table.remove(self.events, 1).callback()
        else socket.sleep(0.002) end
    end
    function state:untilTrue(predicate, timeout)
        local deadline = socket.gettime() + (timeout or 3)
        while not predicate() and socket.gettime() < deadline do self:step() end
        check(predicate(), "The real subprocess did not reach the expected state before its deadline")
    end
    function state:runFor(duration)
        local deadline = socket.gettime() + duration
        while socket.gettime() < deadline do self:step() end
    end
    return state
end
local function make(options)
    options = options or {}
    options.ui, options.interval = options.ui or ui(), 0.003
    local runner = Runner.new(options)
    active[#active + 1] = runner
    return runner, options.ui
end
local function callbacks()
    local calls = {}
    return calls, function(value, err) calls[#calls + 1] = { value = value, error = err } end
end
local function reaped(pid)
    local status = ffi.new("int[1]")
    local result = tonumber(ffi.C.waitpid(pid, status, ffi.C.WNOHANG))
    check(result == -1 and ffi.errno() == 10, "Runner must reap its own child before reporting completion")
end
local function fdCount()
    local count = 0
    for name in lfs.dir("/proc/self/fd") do if name ~= "." and name ~= ".." then count = count + 1 end end
    return count
end
local function attempt(path)
    local record = Files.exists(path) and json.decode(Files.read(path)) or { count = 0, pids = {}, times = {} }
    record.count = record.count + 1
    record.pids[#record.pids + 1] = tonumber(ffi.C.getpid())
    record.times[#record.times + 1] = socket.gettime()
    Files.write(path, json.encode(record))
    return record.count
end
local function attempts(path) return json.decode(Files.read(path)) end
local function reapedAttempts(path) for _, pid in ipairs(attempts(path).pids) do reaped(pid) end end
local function backoff(runner, screen, id)
    screen:untilTrue(function() return not runner.tasks[id] and #runner.queue > 0 end)
    check(screen.held == 0, "Backoff must release worker standby ownership")
end
local function test(name, fn)
    local before = fdCount()
    local ok, failure = xpcall(fn, debug.traceback)
    for _, runner in ipairs(active) do
        local close_ok, close_error = pcall(runner.close, runner)
        if not close_ok then ok, failure = false, tostring(failure or "") .. tostring(close_error) end
        if runner.ui.held ~= 0 or runner.ui.acquired ~= runner.ui.released then
            ok, failure = false, tostring(failure or "") .. " Unbalanced standby ownership"
        end
    end
    active = {}
    if fdCount() ~= before then ok, failure = false, tostring(failure or "") .. " Pipe file descriptors leaked" end
    tests[#tests + 1] = { name = name, passed = ok, error = ok and nil or failure }
    print((ok and "PASS " or "FAIL ") .. name)
end

test("Responses larger than kernel pipe capacity are drained without deadlock", function()
    local size = 1024 * 1024
    local runner, screen = make({ max_payload = 2 * size, worker = function() return { payload = string.rep("q", size) } end })
    local calls, done = callbacks()
    local id = runner:submit({}, {}, done)
    local pid, fd = runner.tasks[id].pid, runner.tasks[id].fd
    local capacity = tonumber(ffi.C.fcntl(fd, 1032))
    check(capacity > 0 and size > capacity, "Fixture must exceed the actual pipe capacity")
    screen:untilTrue(function() return #calls == 1 end, 5)
    check(not calls[1].error and #calls[1].value.payload == size and calls[1].value.payload == string.rep("q", size),
        "The complete multi-write frame must arrive unchanged")
    reaped(pid)
end)

test("Active cancellation reaps the child and invokes its callback exactly once", function()
    local marker = output .. "/cancel.started"
    local runner, screen = make({ worker = function() Files.write(marker, "ready"); socket.sleep(0.5); return true end })
    local calls, done = callbacks()
    local id = runner:submit({}, {}, done)
    local pid = runner.tasks[id].pid
    screen:untilTrue(function() return Files.exists(marker) end)
    check(runner:cancel(id), "Active cancellation must be acknowledged")
    screen:untilTrue(function() return #calls == 1 end)
    check(calls[1].error.kind == "canceled" and calls[1].error.transmitted == true,
        "Canceled active work must report uncertainty about transmission")
    check(not runner:cancel(id), "A completed task cannot be canceled twice")
    reaped(pid)
end)

test("Canceling queued work never forks or reports transmission", function()
    local runner, screen = make({ worker = function() return true end })
    runner:suspend()
    local calls, done = callbacks()
    local id = runner:submit({}, {}, done)
    check(not runner.tasks[id] and #runner.queue == 1, "Suspended submissions remain queued")
    check(runner:cancel(id) and #calls == 1 and calls[1].error.transmitted == false,
        "Queued cancellation must report a request that never transmitted")
    check(screen.acquired == 0 and #screen.events == 0, "Queued cancellation needs neither child nor standby ownership")
end)

test("Timeouts kill and reap real workers with balanced standby ownership", function()
    local runner, screen = make({ worker = function() socket.sleep(0.4); return true end })
    local calls, done = callbacks()
    local id = runner:submit({}, { timeout = 0.04 }, done)
    local pid = runner.tasks[id].pid
    screen:untilTrue(function() return #calls == 1 end)
    check(calls[1].error.kind == "timeout" and calls[1].error.retryable == true, "Cancelable timeout must be retryable")
    check(screen.held == 0, "Timed-out work must release standby ownership")
    reaped(pid)
end)

test("Visible image preempts and later restarts prefetch without a spurious callback", function()
    local marker = output .. "/prefetch.started"
    local runner, screen = make({ max_workers = 1, worker = function(request)
        if request.name == "prefetch" then Files.write(marker, "ready"); socket.sleep(0.08) end
        return request.name
    end })
    local order, calls = {}, {}
    local low = runner:submit({ name = "prefetch" }, { priority = 40, resource = "image" }, function(value, err)
        calls.prefetch = { value = value, error = err }; order[#order + 1] = "prefetch"
    end)
    local original_pid = runner.tasks[low].pid
    screen:untilTrue(function() return Files.exists(marker) end)
    runner:submit({ name = "visible" }, { priority = 0, resource = "image" }, function(value, err)
        calls.visible = { value = value, error = err }; order[#order + 1] = "visible"
    end)
    screen:untilTrue(function() return #order == 2 end)
    check(order[1] == "visible" and order[2] == "prefetch", "Visible work must finish before the restarted prefetch")
    check(not calls.prefetch.error and calls.prefetch.value == "prefetch" and not calls.visible.error,
        "Preemption is internal and must not appear as user cancellation")
    check(screen.acquired == 3 and screen.released == 3, "Every fork attempt must own exactly one standby hold")
    reaped(original_pid)
end)

test("Noncancelable purchase work is never preempted by a visible request", function()
    local runner, screen = make({ max_workers = 1, worker = function(request) socket.sleep(0.03); return request.name end })
    local order = {}
    local id = runner:submit({ name = "purchase" }, { priority = 40, cancelable = false }, function(value) order[#order + 1] = value end)
    runner:submit({ name = "visible" }, { priority = 0 }, function(value) order[#order + 1] = value end)
    check(not runner.tasks[id].cancel_kind, "Purchase execution must retain its process")
    screen:untilTrue(function() return #order == 2 end)
    check(order[1] == "purchase" and order[2] == "visible", "Purchase must finish before queued visible work")
end)

test("Resource limits allow metadata beside one image and queue a second image", function()
    local runner, screen = make({ max_workers = 2, worker = function() socket.sleep(0.04); return true end })
    local calls, done = callbacks()
    local image1 = runner:submit({}, { resource = "image" }, done)
    local image2 = runner:submit({}, { resource = "image" }, done)
    local metadata = runner:submit({}, { resource = "metadata" }, done)
    check(runner.tasks[image1] and runner.tasks[metadata] and not runner.tasks[image2] and #runner.queue == 1,
        "Image limit must not unnecessarily serialize metadata")
    screen:untilTrue(function() return #calls == 3 end)
    check(screen.acquired == 3 and screen.released == 3, "Queued resource task must eventually complete")
end)

test("Suspension requeues prefetch and stops polling until resume", function()
    local marker = output .. "/suspend.started"
    local runner, screen = make({ worker = function() Files.write(marker, "ready"); socket.sleep(0.08); return true end })
    local calls, done = callbacks()
    runner:submit({}, {}, done)
    screen:untilTrue(function() return Files.exists(marker) end)
    runner:suspend()
    screen:untilTrue(function() return not next(runner.tasks) end)
    check(#runner.queue == 1 and #calls == 0, "Suspended work must retain its request without a cancellation callback")
    check(not runner.scheduled and #screen.events == 0 and screen.held == 0,
        "A suspended queue cannot schedule polling ticks or retain a standby hold")
    runner:resume()
    screen:untilTrue(function() return #calls == 1 end)
    check(calls[1].value == true and not calls[1].error, "Resume must execute the retained request")
end)

test("Oversized responses fail explicitly and worker crashes leave no child or pipe", function()
    local runner, screen = make({ max_payload = 1024, worker = function(request)
        if request.crash then ffi.C._exit(0) end
        return string.rep("x", 4096)
    end })
    local calls, done = callbacks()
    local first = runner:submit({}, {}, done)
    local first_pid = runner.tasks[first].pid
    screen:untilTrue(function() return #calls == 1 end)
    check(calls[1].error.kind == "worker_limit", "Payload limit must be reported explicitly")
    reaped(first_pid)
    local second = runner:submit({ crash = true }, {}, done)
    local second_pid = runner.tasks[second].pid
    screen:untilTrue(function() return #calls == 2 end)
    check(calls[2].error.kind == "worker", "Exit without a frame must report failure")
    reaped(second_pid)
end)

test("Immediate close terminates a child before its process group exists", function()
    ffiutil.addRunInSubProcessAfterForkFunc("bilicomics-runner-race", function() socket.sleep(0.2) end)
    local runner, screen = make({ worker = function() socket.sleep(0.5); return true end })
    local calls, done = callbacks()
    local id = runner:submit({}, {}, done)
    local pid = runner.tasks[id].pid
    local start = socket.gettime()
    runner:close()
    local elapsed = socket.gettime() - start
    ffiutil.removeRunInSubProcessAfterForkFunc("bilicomics-runner-race")
    check(elapsed < 0.15, "Close blocked for " .. elapsed .. " seconds before process-group creation")
    check(#calls == 1 and calls[1].error.kind == "canceled" and screen.held == 0, "Close must notify once and release ownership")
    reaped(pid)
end)

test("Read network retries back off without polling and deliver one final successful response", function()
    local path = output .. "/retry-success.json"
    local runner, screen = make({ retry_delay = 0.04, worker = function()
        local count = attempt(path)
        if count < 3 then return nil, { kind = "network", message = "Synthetic transient failure", retryable = true } end
        return "recovered"
    end })
    local calls, done = callbacks()
    local id = runner:submit({ kind = "client", method = "comicDetail" }, {}, done)
    backoff(runner, screen, id)
    local ticks = screen.ticks
    screen:runFor(0.015)
    check(screen.ticks == ticks and attempts(path).count == 1 and #calls == 0,
        "An idle backoff must schedule its deadline without repeated polling or premature callbacks")
    screen:untilTrue(function() return #calls == 1 end)
    local record = attempts(path)
    check(record.count == 3 and calls[1].value == "recovered" and not calls[1].error,
        "Two transient failures must produce one final successful response")
    check(record.times[2] - record.times[1] >= 0.035 and record.times[3] - record.times[2] >= 0.075,
        "The two retries must honor the increasing delay")
    check(screen.acquired == 3 and screen.released == 3, "Every retry attempt must release its standby hold")
    reapedAttempts(path)
end)

test("Permanent transient failure stops after three executions even when a caller requests more", function()
    local path = output .. "/retry-exhausted.json"
    local runner, screen = make({ retry_delay = 0.02, worker = function()
        attempt(path)
        return nil, { kind = "http", status = 503, message = "Synthetic unavailable service", retryable = true }
    end })
    local calls, done = callbacks()
    runner:submit({ kind = "library" }, { retry_attempts = 99 }, done)
    screen:untilTrue(function() return #calls == 1 end)
    screen:runFor(0.08)
    check(attempts(path).count == 3 and #calls == 1 and calls[1].error.status == 503,
        "An exhausted read must settle once after at most three error attempts")
    check(not next(runner.tasks) and #runner.queue == 0, "Exhausted retries must not retain background work")
    reapedAttempts(path)
end)

test("HTTP 429 and image 5xx errors retry while authentication and forbidden errors do not", function()
    local cases = {
        { kind = "http", status = 429, request = { kind = "quote" }, count = 2 },
        { kind = "image_http", status = 502, request = { kind = "download_cover" }, count = 2 },
        { kind = "authentication", request = { kind = "client", method = "wallet" }, count = 1 },
        { kind = "http", status = 403, request = { kind = "library" }, count = 1 },
        { kind = "image_http", status = 403, request = { kind = "download_page" }, count = 1 },
        { kind = "network", request = { kind = "client", method = "buyEpisode" }, count = 1 },
    }
    for index, case in ipairs(cases) do
        local path = output .. "/retry-classification-" .. index .. ".json"
        local runner, screen = make({ retry_delay = 0.02, worker = function()
            if attempt(path) == 1 then return nil, { kind = case.kind, status = case.status, retryable = true } end
            return true
        end })
        local calls, done = callbacks()
        runner:submit(case.request, {}, done)
        screen:untilTrue(function() return #calls == 1 end)
        check(attempts(path).count == case.count, "Unexpected retry classification for case " .. index)
        check((case.count == 2 and calls[1].value == true) or (case.count == 1 and calls[1].error.kind == case.kind),
            "The final outcome must correspond to the actual classification")
        reapedAttempts(path)
    end
end)

test("Expired page tokens retry only page acquisition and native timeouts can recover", function()
    for index, kind in ipairs({ "download_page", "download_cover" }) do
        local path = output .. "/retry-token-" .. index .. ".json"
        local runner, screen = make({ retry_delay = 0.02, worker = function()
            if attempt(path) == 1 then return nil, { kind = "token_expired", retryable = true } end
            return true
        end })
        local calls, done = callbacks()
        runner:submit({ kind = kind }, {}, done)
        screen:untilTrue(function() return #calls == 1 end)
        check(attempts(path).count == (kind == "download_page" and 2 or 1), "Token retries must be confined to chapter images")
        reapedAttempts(path)
    end
    local path = output .. "/retry-native-timeout.json"
    local runner, screen = make({ retry_delay = 0.02, worker = function()
        if attempt(path) < 3 then socket.sleep(0.15) end
        return true
    end })
    local calls, done = callbacks()
    runner:submit({ kind = "reconcile_purchase" }, { timeout = 0.035 }, done)
    screen:untilTrue(function() return #calls == 1 end)
    check(attempts(path).count == 3 and calls[1].value == true and not calls[1].error,
        "Killed read timeouts may retry without publishing intermediate failures")
    reapedAttempts(path)
end)

test("A retryable purchase response still executes its submission exactly once", function()
    local path = output .. "/purchase-no-retry.json"
    local runner, screen = make({ retry_delay = 0.02, worker = function()
        attempt(path)
        return nil, { kind = "network", retryable = true, transmitted = true }
    end })
    local calls, done = callbacks()
    runner:submit({ kind = "purchase_submit" }, {}, done)
    screen:untilTrue(function() return #calls == 1 end)
    screen:runFor(0.09)
    check(attempts(path).count == 1 and #calls == 1 and calls[1].error.transmitted == true,
        "The retryable flag must never authorize resending a purchase")
    reapedAttempts(path)
end)

test("Purchase submissions cannot be preempted or restarted by suspend even with default options", function()
    local path = output .. "/purchase-no-preempt.json"
    local runner, screen = make({ max_workers = 1, worker = function(request)
        if request.kind == "purchase_submit" then attempt(path); socket.sleep(0.09); return "purchase" end
        return "visible"
    end })
    local calls, done = callbacks()
    local id = runner:submit({ kind = "purchase_submit" }, { priority = 40 }, done)
    screen:untilTrue(function() return Files.exists(path) end)
    runner:submit({ kind = "client", method = "comicDetail" }, { priority = 0 }, done)
    runner:suspend()
    screen:runFor(0.03)
    check(runner.tasks[id] and not runner.tasks[id].cancel_kind, "Purchase must stay in its original process during suspension")
    runner:resume()
    screen:untilTrue(function() return #calls == 2 end)
    check(attempts(path).count == 1 and calls[1].value == "purchase" and calls[2].value == "visible",
        "Queued visible work must wait for the single purchase execution")
    reapedAttempts(path)
end)

test("Favorite mutations retain their original child across suspension and urgent reads", function()
    local path = output .. "/favorite-no-preempt.json"
    local runner, screen = make({ max_workers = 1, worker = function(request)
        if request.kind == "set_favorite" then
            attempt(path); socket.sleep(0.09)
            return { accepted = true, comic_id = request.comic_id, favorite = request.favorite }
        end
        return "visible"
    end })
    local calls, done = callbacks()
    local id = runner:submit({ kind = "set_favorite", comic_id = "81", favorite = true }, { priority = 40 }, done)
    local original_pid = runner.tasks[id].pid
    screen:untilTrue(function() return Files.exists(path) end)
    runner:submit({ kind = "client", method = "comicDetail" }, { priority = 0 }, done)
    runner:suspend()
    screen:runFor(0.025)
    check(runner.tasks[id] and runner.tasks[id].pid == original_pid and not runner.tasks[id].cancel_kind
        and attempts(path).count == 1, "A favorite mutation cannot be killed or resent by default lifecycle behavior")
    runner:resume()
    screen:untilTrue(function() return #calls == 2 end)
    check(attempts(path).count == 1 and calls[1].value.accepted == true and calls[1].value.comic_id == "81"
        and calls[1].value.favorite == true and calls[2].value == "visible",
        "The single favorite mutation must finish before the queued visible read")
    check(screen.acquired == 2 and screen.released == 2, "Lifecycle handling must not create a hidden favorite attempt")
    reapedAttempts(path)
end)

test("Favorite mutation timeouts and retryable transport errors never cause automatic resubmission", function()
    for _, mode in ipairs({ "timeout", "network" }) do
        local path = output .. "/favorite-no-retry-" .. mode .. ".json"
        local runner, screen = make({ retry_delay = 0.02, worker = function()
            attempt(path)
            if mode == "timeout" then socket.sleep(0.15); return { accepted = true } end
            return nil, { kind = "network", retryable = true, transmitted = true }
        end })
        local calls, done = callbacks()
        runner:submit({ kind = "set_favorite", comic_id = "81", favorite = false },
            { timeout = 0.04, retry_attempts = 99 }, done)
        screen:untilTrue(function() return #calls == 1 end)
        screen:runFor(0.09)
        check(attempts(path).count == 1 and #calls == 1 and calls[1].value == nil and calls[1].error.kind == mode,
            "A favorite mutation's uncertain " .. mode .. " outcome cannot become confirmation or another attempt")
        check(calls[1].error.transmitted == true and not next(runner.tasks) and #runner.queue == 0,
            "A failed mutation must preserve transmission uncertainty and release background ownership")
        reapedAttempts(path)
    end
end)

test("Canceling or closing during retry backoff settles once without spawning another child", function()
    for _, action in ipairs({ "cancel", "close" }) do
        local path = output .. "/retry-backoff-" .. action .. ".json"
        local runner, screen = make({ retry_delay = 0.07, worker = function()
            attempt(path); return nil, { kind = "network", retryable = true }
        end })
        local calls, done = callbacks()
        local id = runner:submit({ kind = "client", method = "search" }, {}, done)
        backoff(runner, screen, id)
        if action == "cancel" then runner:cancel(id) else runner:close() end
        screen:runFor(0.12)
        check(#calls == 1 and attempts(path).count == 1 and screen.held == 0,
            "Backoff " .. action .. " must not restart work or invoke duplicate callbacks")
        check(calls[1].error.kind == (action == "cancel" and "canceled" or "closed"), "Backoff termination must retain its cause")
        reapedAttempts(path)
    end
end)

test("Suspending retry backoff preserves the request without a worker or recurring polling", function()
    local path = output .. "/retry-backoff-suspend.json"
    local runner, screen = make({ retry_delay = 0.05, worker = function()
        if attempt(path) == 1 then return nil, { kind = "network", retryable = true } end
        return true
    end })
    local calls, done = callbacks()
    local id = runner:submit({ kind = "client", method = "search" }, {}, done)
    backoff(runner, screen, id)
    runner:suspend()
    local ticks = screen.ticks
    screen:runFor(0.12)
    check(attempts(path).count == 1 and #calls == 0 and screen.held == 0 and #screen.events == 0,
        "Suspended retry cannot fork, notify, retain standby, or keep scheduling")
    check(screen.ticks - ticks <= 1, "Suspension may drain one scheduled event but cannot busy-poll")
    runner:resume()
    screen:untilTrue(function() return #calls == 1 end)
    check(attempts(path).count == 2 and calls[1].value == true, "Resuming an elapsed backoff must execute the retained request")
    reapedAttempts(path)
end)

test("New urgent work wakes the runner before an existing retry deadline", function()
    local path = output .. "/retry-urgent.json"
    local runner, screen = make({ retry_delay = 0.2, max_workers = 1, worker = function(request)
        if request.name == "retry" and attempt(path) == 1 then return nil, { kind = "network", retryable = true } end
        return request.name
    end })
    local calls, done = callbacks()
    local id = runner:submit({ kind = "download_page", name = "retry" }, { priority = 40, resource = "image" }, done)
    backoff(runner, screen, id)
    local started = socket.gettime()
    runner:submit({ kind = "download_page", name = "urgent" }, { priority = 0, resource = "image" }, done)
    screen:untilTrue(function() return #calls > 0 end)
    check(calls[1].value == "urgent" and socket.gettime() - started < 0.12 and attempts(path).count == 1,
        "The new visible page must not wait for a future retry timer")
    screen:untilTrue(function() return #calls == 2 end)
    check(calls[2].value == "retry" and attempts(path).count == 2, "Earlier urgent work must not lose the delayed request")
    reapedAttempts(path)
end)

test("A future high-priority retry cannot preempt currently useful lower-priority work", function()
    local path = output .. "/retry-future-preempt.json"
    local runner, screen = make({ retry_delay = 0.2, max_workers = 1, worker = function(request)
        if request.name == "retry" then
            if attempt(path) == 1 then return nil, { kind = "network", retryable = true } end
        else socket.sleep(0.04) end
        return request.name
    end })
    local calls, done = callbacks()
    local id = runner:submit({ kind = "download_page", name = "retry" }, { priority = 0, resource = "image" }, done)
    backoff(runner, screen, id)
    local useful = runner:submit({ kind = "download_page", name = "useful" }, { priority = 40, resource = "image" }, done)
    local useful_pid = runner.tasks[useful].pid
    screen:untilTrue(function() return #calls > 0 end)
    check(calls[1].value == "useful" and screen.acquired == 2 and attempts(path).count == 1,
        "A not-yet-due retry cannot consume or preempt the free resource slot")
    reaped(useful_pid)
    screen:untilTrue(function() return #calls == 2 end)
    check(calls[2].value == "retry", "The high-priority retry must remain queued until due")
    reapedAttempts(path)
end)

local passed = true
for _, item in ipairs(tests) do passed = passed and item.passed end
Files.write(output .. "/runner-result.json", json.encode({ tests = tests, passed = passed }, { pretty = true }))
assert(passed, "One or more runner contract tests failed")
