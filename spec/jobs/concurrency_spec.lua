-- Run only in the isolated official KOReader runtime on test-env.
-- Real child processes produce synthetic images; no external service is used.
require("setupkoenv")
local source, work, fixture_path, result_path, suite = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4]), assert(arg[5])
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(require("datastorage"):getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local ffi = require("ffi")
require("ffi/posix_h")
local ffiutil = require("ffi/util")
local socket = require("socket")
local lfs = require("libs/libkoreader-lfs")
local json = require("rapidjson")
local Runner = require("bilicomics/jobs/runner")
local Service = require("bilicomics/jobs/download_service")
local SessionRunner = require("bilicomics/jobs/session_runner")
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Settings = require("bilicomics/settings")
local Budget = require("bilicomics/jobs/storage_budget")
local Files = require("bilicomics/storage/files")
local unpack = unpack or table.unpack
assert(ffi.os == "Linux", "The real fork suite requires Linux")
local parent_pid, bytes = tonumber(ffi.C.getpid()), Files.read(fixture_path, 65536)
local original_fork, original_done, original_available = ffiutil.runInSubProcess, ffiutil.isSubProcessDone, Budget.available
local contexts, pid_context, current_case, sequence, allow_more_cases = {}, {}, "setup", 0, true
local report = { passed = false, suite = suite, tests = {}, assertions = {}, traces = {},
    scope = "Real Runner forks, pipes, SQLite and PageStore with synthetic images and accounts; no network or monetary operations" }

local function check(name, condition)
    local label = current_case .. ": " .. name
    report.assertions[#report.assertions + 1] = { name = label, passed = not not condition }
    assert(condition, label)
end
local function pack(...) return { n = select("#", ...), ... } end
local function write(path, value) Files.atomicWrite(path, json.encode(value), work) end
local function read(path) return assert(json.decode(Files.read(path, 65536))) end
local function scheduler()
    local ui = { pending = {}, deferred = {}, held = 0, acquired = 0, released = 0, minimum = 0 }
    function ui:scheduleIn(delay, callback) self.pending[callback] = socket.gettime() + delay end
    function ui:unschedule(callback) self.pending[callback] = nil end
    function ui:nextTick(callback) self.deferred[#self.deferred + 1] = callback end
    function ui:preventStandby() self.held, self.acquired = self.held + 1, self.acquired + 1 end
    function ui:allowStandby()
        self.held, self.released = self.held - 1, self.released + 1
        self.minimum = math.min(self.minimum, self.held)
    end
    function ui:step()
        if #self.deferred > 0 then table.remove(self.deferred, 1)(); return end
        local callback, due
        for candidate, time in pairs(self.pending) do
            if not due or time < due then callback, due = candidate, time end
        end
        if callback and due <= socket.gettime() then self.pending[callback] = nil; callback()
        else socket.sleep(0.002) end
    end
    return ui
end
local function await(c, predicate, name, timeout)
    local deadline = socket.gettime() + (timeout or 4)
    while not predicate() do
        assert(socket.gettime() < deadline, current_case .. ": timeout waiting for " .. name)
        c.ui:step()
    end
end
local function settle(c, duration)
    local deadline = socket.gettime() + (duration or 0.025)
    while socket.gettime() < deadline do c.ui:step() end
end
local function release(c, gate) Files.write(c.root .. "/" .. gate, "released\n") end
local function traces(c, label)
    local result = {}
    for name in lfs.dir(c.root) do
        if name:match("^start%-%d+%.json$") then
            local item = read(c.root .. "/" .. name)
            if not label or item.label == label then
                local ending, terminal = c.root .. "/end-" .. item.pid .. ".json", c.root .. "/reaped-" .. item.pid .. ".json"
                if Files.exists(ending) then item.ended_at = read(ending).time end
                if Files.exists(terminal) then item.reaped_at = read(terminal).time end
                result[#result + 1] = item
            end
        end
    end
    table.sort(result, function(a, b) return a.time < b.time end)
    return result
end
local function started(c, label) return #traces(c, label) end
local function overlap(c, predicate, until_reaped)
    local events, records = {}, traces(c)
    for _, item in ipairs(records) do
        if not predicate or predicate(item) then
            local ending = assert(until_reaped and item.reaped_at or item.ended_at or item.reaped_at,
                "Every observed child needs an end or reap record")
            events[#events + 1] = { time = item.time, change = 1 }
            events[#events + 1] = { time = ending, change = -1 }
        end
    end
    table.sort(events, function(a, b) return a.time == b.time and a.change < b.change or a.time < b.time end)
    local active, maximum = 0, 0
    for _, event in ipairs(events) do active = active + event.change; maximum = math.max(maximum, active) end
    return maximum
end

-- These observers preserve the official helper's fork, pipe and wait behavior.
ffiutil.runInSubProcess = function(...)
    local values = pack(original_fork(...))
    if tonumber(ffi.C.getpid()) == parent_pid then
        local pid = tonumber(values[1])
        if pid and pid > 0 then
            local c = assert(contexts[#contexts], "A fork needs an active context")
            c.forks[#c.forks + 1], pid_context[pid] = pid, c
        end
    end
    return unpack(values, 1, values.n)
end
ffiutil.isSubProcessDone = function(pid, ...)
    local values = pack(original_done(pid, ...))
    local c = pid_context[tonumber(pid)]
    if values[1] and c and tonumber(ffi.C.getpid()) == parent_pid and not c.reaped[tonumber(pid)] then
        c.reaped[tonumber(pid)] = true
        write(c.root .. "/reaped-" .. pid .. ".json", { time = socket.gettime(), pid = tonumber(pid) })
    end
    return unpack(values, 1, values.n)
end

local function context(concurrency, options)
    options = options or {}; sequence = sequence + 1
    local c = { root = work .. "/case-" .. sequence, ui = scheduler(), forks = {}, reaped = {}, callbacks = {},
        controls = {}, services = {}, stores = {}, ready = {}, commits = {}, external_roots = {},
        commit_depth = 0, max_commit_depth = 0, initial_concurrency = concurrency or 1 }
    Files.mkdir(c.root); contexts[#contexts + 1] = c
    local function worker(request)
        local pid = tonumber(ffi.C.getpid())
        assert(pid ~= parent_pid, "Synthetic work must execute in a real child")
        local label = request.label or request.source_path
        local control = c.controls[label] or {}
        local started_at = socket.gettime()
        write(c.root .. "/start-" .. pid .. ".json", { pid = pid, parent_pid = tonumber(ffi.C.getppid()),
            time = started_at, label = label, index = request.index, kind = request.kind, resource = request.audit_resource or "image" })
        if request.temporary_path and request.max_bytes then
            local allowed, err = Budget.check(Files.parent(request.temporary_path), request.minimum_free_bytes, request.max_bytes)
            if not allowed then return nil, err end
        end
        local gate = request.gate or control.gate
        if gate then
            local deadline = socket.gettime() + 6
            while not Files.exists(c.root .. "/" .. gate) do
                assert(socket.gettime() < deadline, "The synthetic worker gate timed out")
                socket.sleep(0.003)
            end
        end
        socket.sleep(request.delay or control.delay or 0.06)
        local failure = request.failure or control.failure
        if control.retry_once then
            local marker = c.root .. "/retry-" .. Files.component(label)
            if not Files.exists(marker) then
                Files.write(marker, "attempted\n")
                failure = { kind = "network", retryable = true, message = "Synthetic transient read failure" }
            end
        end
        local result = { label = label, pid = pid }
        if request.temporary_path and not failure then
            Files.write(request.temporary_path, bytes)
            result = { temporary_path = request.temporary_path, checksum = Files.digest(request.temporary_path),
                width = 40, height = 80, format = "png",
                geometry = { source_width = 40, source_height = 80, exif_orientation = 1 } }
        end
        write(c.root .. "/end-" .. pid .. ".json", { pid = pid, time = socket.gettime(), label = label, failed = failure ~= nil })
        if failure then return nil, failure end
        return result
    end
    local runner_options = { ui = c.ui, worker = worker, clock = socket.gettime, interval = 0.002, retry_delay = 0.1 }
    if concurrency then runner_options.image_concurrency = concurrency end
    for key, value in pairs(options) do runner_options[key] = value end
    c.runner = Runner.new(runner_options)
    return c
end
local function submit(c, label, options, fields)
    local request = { kind = "download_page", label = label }
    for key, value in pairs(fields or {}) do request[key] = value end
    local result = { count = 0 }; c.callbacks[label] = result
    local id = c.runner:submit(request, options or { resource = "image", priority = 40 }, function(value, err)
        result.count, result.value, result.error, result.time = result.count + 1, value, err, socket.gettime()
    end)
    result.id = id
    return result
end
local function successful(c, labels)
    for _, label in ipairs(labels) do
        local item = c.callbacks[label]
        check(label .. " settles exactly once successfully", item.count == 1 and item.value ~= nil and not item.error)
    end
end
local function complete(c, labels)
    await(c, function()
        for _, label in ipairs(labels) do if c.callbacks[label].count ~= 1 then return false end end
        return true
    end, "all callbacks")
    settle(c); successful(c, labels)
end

local function seed(c, count, options)
    options = options or {}
    local account = options.account or "synthetic-concurrency-a"
    local root = c.root .. "/" .. account
    local store = Store.open{ root = root, account_key = account, wal = false }
    local pages = PageStore.new{ root = root, account_key = account, store = store }
    c.stores[#c.stores + 1] = store
    local descriptor = { schema_version = 1, account_key = account, comic_id = "comic", episode_id = "episode",
        revision = "R1", pages = {} }
    for index = 1, count do descriptor.pages[index] = { id = "image-" .. index, index = index, width = 40, height = 80 } end
    store:upsertComic{ id = "comic", title = "Synthetic concurrency comic" }
    store:upsertEpisodes("comic", { { id = "episode", title = "Synthetic concurrency chapter", order = 1, access = "free",
        extra = { current_revision = "R1" } } })
    local descriptor_path = pages:ensureDescriptor(descriptor)
    for index = 1, count do
        store:updatePage("episode/R1/" .. index, { extra = { source_path = account .. "-page-" .. index, source_generation = 0 } })
    end
    local settings = options.settings or { value = options.concurrency or c.runner:getImageConcurrency() }
    if not settings.get then
        function settings:get(key)
            if key == "download_concurrency" then return self.value end
            if key == "minimum_free_bytes" then return 0 end
            if key == "cache_limit_bytes" then return 256 * 1024 * 1024 end
        end
    end
    local original_commit = pages.commitPage
    function pages:commitPage(commit_context, result)
        c.commit_depth = c.commit_depth + 1; c.max_commit_depth = math.max(c.max_commit_depth, c.commit_depth)
        local observation = { account = account, index = commit_context.index,
            parent_only = tonumber(ffi.C.getpid()) == parent_pid, stages = {} }
        c.commits[#c.commits + 1] = observation
        self.fault_hook = function(stage, journal)
            local saved = store:getPage(journal.page.key)
            observation.stages[#observation.stages + 1] = { stage = stage, temporary = Files.exists(journal.temporary_path),
                destination = Files.exists(journal.page.path), state = saved.state, journals = #store:listCommits() }
        end
        local values = pack(pcall(original_commit, self, commit_context, result))
        self.fault_hook = nil; c.commit_depth = c.commit_depth - 1
        if not values[1] then error(values[2], 0) end
        return unpack(values, 2, values.n)
    end
    local value = { store = store, pages = pages, descriptor = descriptor, descriptor_path = descriptor_path,
        identity = Files.read(descriptor_path), settings = settings, account = account, ready = 0 }
    value.service = Service.new{ store = store, pages = pages, runner = options.runner or c.runner, settings = settings,
        account_key = account, ui = c.ui, session = function() return { synthetic = true, account_key = account } end,
        prepare = function(_, _, done) done({ descriptor = descriptor, path = descriptor_path }) end,
        page_ready = function(page)
            value.ready = value.ready + 1
            c.ready[#c.ready + 1] = { key = page.key, pid = tonumber(ffi.C.getpid()), account = account }
        end }
    c.services[#c.services + 1] = value.service
    function value:label(index) return self.account .. "-page-" .. index end
    return value
end
local function validateChapter(c, v, count)
    check("the immutable descriptor is unchanged", Files.read(v.descriptor_path) == v.identity)
    check("every page is atomically committed and complete", v.pages:isComplete("episode", "R1") and #v.store:listCommits() == 0)
    local expected = Files.digest(fixture_path)
    for index = 1, count do
        local page = v.pages:getPage("episode", "R1", index)
        check("page " .. index .. " has verified content and one generation", page.state == "ready" and page.content_generation == 1
            and page.checksum == expected and Files.digest(page.path) == expected and Files.within(page.path, v.pages.pages_root))
        check("page " .. index .. " starts once", started(c, v:label(index)) == 1)
    end
    check("parent commits are serialized", c.max_commit_depth == 1)
    for _, commit in ipairs(c.commits) do
        check("commit " .. commit.index .. " is performed by the parent", commit.parent_only)
        local a, b, d = commit.stages[1], commit.stages[2], commit.stages[3]
        check("commit " .. commit.index .. " retains the atomic journal sequence", a and a.stage == "after_journal"
            and a.temporary and not a.destination and a.state == "missing" and a.journals == 1
            and b and b.stage == "after_rename" and not b.temporary and b.destination and b.state == "missing" and b.journals == 1
            and d and d.stage == "after_database" and not d.temporary and d.destination and d.state == "ready" and d.journals == 0)
    end
end
local function cleanup(c)
    local failures = {}
    local function attempt(label, operation)
        local ok, err = pcall(operation)
        if not ok then failures[#failures + 1] = label .. ": " .. tostring(err) end
    end
    for _, service in ipairs(c.services) do attempt("Service close", function() service:close() end) end
    attempt("Runner close", function() c.runner:close() end)
    local terminal, reaped = true, true
    for _, pid in ipairs(c.forks) do
        local status = ffi.new("int[1]")
        local result = tonumber(ffi.C.waitpid(pid, status, 1))
        local child_error = ffi.errno()
        reaped = reaped and result == -1 and child_error == 10
        if result == 0 then
            ffi.C.kill(pid, 9)
            local deadline = socket.gettime() + 1
            repeat result = tonumber(ffi.C.waitpid(pid, status, 1)); socket.sleep(0.002) until result ~= 0 or socket.gettime() > deadline
        end
        terminal = terminal and result ~= 0
        if result ~= 0 and not c.reaped[pid] then
            attempt("Forced reap audit", function()
                write(c.root .. "/reaped-" .. pid .. ".json", { time = socket.gettime(), pid = pid, cleanup_reaped = true })
            end)
        end
    end
    if not terminal then allow_more_cases = false end
    for _, store in ipairs(c.stores) do
        if store.connection then attempt("Store close", function() store:close() end) end
    end
    for _, root in ipairs(c.external_roots) do
        attempt("External fixture cleanup", function()
            for name in lfs.dir(root) do
                if name ~= "." and name ~= ".." then assert(os.remove(root .. "/" .. name)) end
            end
            assert(lfs.rmdir(root))
        end)
    end
    check("every cleanup stage succeeds: " .. table.concat(failures, "; "), #failures == 0)
    check("Runner closes without active work", next(c.runner.tasks) == nil and #c.runner.queue == 0)
    check("Runner has reaped every real child", reaped and terminal)
    check("standby ownership balances every fork", c.ui.held == 0 and c.ui.acquired == c.ui.released
        and c.ui.acquired == #c.forks and c.ui.minimum == 0)
    check("Runner close removes polling timers", next(c.ui.pending) == nil)
    local records = traces(c)
    for _, record in ipairs(records) do
        check("trace proves a real child", record.pid ~= parent_pid and record.parent_pid == parent_pid and record.reaped_at ~= nil)
    end
    report.traces[#report.traces + 1] = { case = current_case, path = c.root, records = records,
        forks = #c.forks, maximum_image_workers = overlap(c, function(item) return item.resource == "image" end),
        maximum_unreaped_image_workers = overlap(c, function(item) return item.resource == "image" end, true) }
    check("image slots remain owned until children are reaped", report.traces[#report.traces].maximum_unreaped_image_workers
        <= math.max(c.initial_concurrency, c.runner:getImageConcurrency()))
end
local function test(name, operation)
    current_case = name
    if not allow_more_cases then
        report.tests[#report.tests + 1] = { name = name, passed = false, error = "Previous child cleanup was incomplete" }
        return
    end
    local ok, failure = xpcall(operation, debug.traceback)
    for _, c in ipairs(contexts) do
        local cleaned, cleanup_error = xpcall(function() cleanup(c) end, debug.traceback)
        if not cleaned then ok, failure = false, tostring(failure or "") .. "\n" .. cleanup_error end
    end
    Budget.available = original_available
    contexts, pid_context = {}, {}
    report.tests[#report.tests + 1] = { name = name, passed = ok, error = not ok and tostring(failure) or nil }
    print((ok and "PASS " or "FAIL ") .. name)
end

if suite == "runner" then
    test("settings_and_runner_contracts", function()
        local c = context()
        check("unspecified Runner options retain legacy defaults", c.runner:getImageConcurrency() == 1
            and c.runner.resource_limits.image == 1 and c.runner.max_workers == 2)
        local path = c.root .. "/settings"
        local settings = Settings.open(path)
        check("the real Settings default is two", settings:get("download_concurrency") == 2)
        for _, value in ipairs({ 1, 2, 3, 4 }) do
            settings:set("download_concurrency", value)
            check("valid Settings values persist", Settings.open(path):get("download_concurrency") == value)
        end
        for _, invalid in ipairs({ 0, 5, 2.5, "2", false }) do
            local value, err = c.runner:setImageConcurrency(invalid)
            check("invalid Runner concurrency is rejected without changing capacity", value == nil and err ~= nil
                and c.runner:getImageConcurrency() == 1 and c.runner.max_workers == 2)
            settings.data:saveSetting("download_concurrency", invalid); settings:flush()
            check("corrupt persisted concurrency falls back to two", Settings.open(path):get("download_concurrency") == 2)
            settings:set("download_concurrency", 4)
        end
    end)
    for _, n in ipairs({ 1, 2, 4 }) do
        test("runner_real_overlap_" .. n, function()
            local c, labels = context(n), {}
            check("constructor sets image and total capacity", c.runner:getImageConcurrency() == n
                and c.runner.resource_limits.image == n and c.runner.max_workers == n + 1)
            for index = 1, 6 do
                local label = "image-" .. index; labels[#labels + 1] = label
                local kinds = { "download_page", "download_cover", "verify_source_page" }
                submit(c, label, nil, { gate = "release-images", kind = kinds[(index - 1) % #kinds + 1] })
            end
            await(c, function() return started(c) == n end, "the initial image workers")
            settle(c)
            check("exactly the requested image window starts", started(c) == n)
            submit(c, "metadata", { resource = "metadata", priority = 40 }, { audit_resource = "metadata", delay = 0.015 })
            await(c, function() return c.callbacks.metadata.count == 1 end, "metadata beside the full image window")
            check("metadata uses the additional total-worker slot", c.callbacks.metadata.value ~= nil and started(c) == n + 1)
            release(c, "release-images"); complete(c, labels)
            check("child timestamps prove the requested image overlap", overlap(c, function(item) return item.resource == "image" end) == n)
        end)
    end
    test("running_four_to_one_drains_without_cancellation", function()
        local c, labels = context(4), {}
        for index = 1, 6 do
            local label = "drain-" .. index; labels[#labels + 1] = label
            submit(c, label, nil, { gate = "release-" .. index, delay = 0.015 })
        end
        await(c, function() return started(c) == 4 end, "four initial children")
        check("lowering the limit succeeds", c.runner:setImageConcurrency(1) == 1)
        for index = 1, 3 do
            release(c, "release-" .. index)
            await(c, function() return c.callbacks["drain-" .. index].count == 1 end, "an existing child to finish")
            settle(c)
            check("lowering does not refill while an older worker remains", started(c) == 4 and started(c, "drain-5") == 0)
        end
        release(c, "release-4")
        await(c, function() return started(c, "drain-5") == 1 end, "the first serial replacement")
        settle(c); check("only one replacement runs", started(c, "drain-6") == 0)
        release(c, "release-5")
        await(c, function() return started(c, "drain-6") == 1 end, "the second serial replacement")
        release(c, "release-6"); complete(c, labels)
        for _, label in ipairs(labels) do
            local record = traces(c, label)
            check(label .. " was neither killed nor restarted", #record == 1 and record[1].ended_at ~= nil)
        end
        check("post-drain image work is serial", overlap(c, function(item) return item.label == "drain-5" or item.label == "drain-6" end) == 1)
    end)
    test("ordinary_priorities_do_not_preempt_during_downshift", function()
        local c, labels = context(4), {}
        for index = 1, 4 do
            local label = "ordinary-drain-" .. index; labels[#labels + 1] = label
            submit(c, label, { resource = "image", priority = 40 }, { gate = "release-ordinary-" .. index, delay = 0.015 })
        end
        await(c, function() return started(c) == 4 end, "four original download workers")
        for _, priority in ipairs({ 10, 20 }) do
            local label = "ordinary-priority-" .. priority; labels[#labels + 1] = label
            submit(c, label, { resource = "image", priority = priority }, { gate = "release-priority-" .. priority, delay = 0.015 })
        end
        check("the image limit drops to one", c.runner:setImageConcurrency(1) == 1)
        settle(c)
        check("ordinary queued priorities start no replacement or cancellation", started(c) == 4)
        for index = 1, 3 do
            release(c, "release-ordinary-" .. index)
            await(c, function() return c.callbacks["ordinary-drain-" .. index].count == 1 end, "an original download to drain")
            settle(c)
            check("ordinary work waits while an original child still owns the reduced slot", started(c) == 4)
        end
        release(c, "release-ordinary-4")
        await(c, function() return started(c, "ordinary-priority-10") == 1 end, "ordinary priority ten after the full drain")
        settle(c); check("ordinary priority twenty still waits for capacity", started(c, "ordinary-priority-20") == 0)
        release(c, "release-priority-10")
        await(c, function() return started(c, "ordinary-priority-20") == 1 end, "ordinary priority twenty after priority ten")
        release(c, "release-priority-20"); complete(c, labels)
        for _, label in ipairs(labels) do
            local records = traces(c, label)
            check(label .. " finishes its original real child without restart", #records == 1 and records[1].ended_at ~= nil)
        end
        check("ordinary queued tasks execute serially after the downshift", overlap(c, function(item)
            return item.label == "ordinary-priority-10" or item.label == "ordinary-priority-20"
        end, true) == 1)
    end)
    test("visible_page_preempts_background_and_restarts_once", function()
        local c = context(2)
        submit(c, "download", { resource = "image", priority = 40 }, { gate = "release-background" })
        submit(c, "prefetch", { resource = "image", priority = 20 }, { gate = "release-background" })
        await(c, function() return started(c) == 2 end, "two background children")
        submit(c, "visible", { resource = "image", priority = 0 }, { delay = 0.015 })
        await(c, function() return c.callbacks.visible.count == 1 and started(c, "download") == 2 end, "visible work and restarted download")
        check("visible work preempts the lowest priority without a user callback", c.callbacks.download.count == 0
            and started(c, "prefetch") == 1 and c.callbacks.visible.value ~= nil)
        check("the interrupted attempt never reports a synthetic work end", traces(c, "download")[1].ended_at == nil)
        release(c, "release-background"); complete(c, { "download", "prefetch", "visible" })
        check("preemption never exceeds the image capacity", overlap(c) <= 2)
    end)
    test("protected_work_survives_downshift_and_suspend", function()
        local c = context(2)
        submit(c, "mutation", { resource = "image", priority = 40 }, { kind = "set_favorite", gate = "release-protected" })
        submit(c, "noncancelable", { resource = "image", priority = 40, cancelable = false }, { gate = "release-protected" })
        await(c, function() return started(c) == 2 end, "protected children")
        submit(c, "visible", { resource = "image", priority = 0 }, { delay = 0.015 })
        c.runner:setImageConcurrency(1); c.runner:suspend(); release(c, "release-protected")
        complete(c, { "mutation", "noncancelable" })
        check("suspension keeps the visible request queued", c.callbacks.visible.count == 0 and started(c, "visible") == 0)
        for _, label in ipairs({ "mutation", "noncancelable" }) do
            check("protected work completes its original attempt", started(c, label) == 1 and traces(c, label)[1].ended_at ~= nil)
        end
        c.runner:resume(); complete(c, { "visible" })
    end)
    test("parent_storage_reservations_bound_four_workers", function()
        local c, labels = context(4), {}
        local parent_queries = 0
        Budget.available = function()
            if tonumber(ffi.C.getpid()) == parent_pid then parent_queries = parent_queries + 1 end
            return 250
        end
        for index = 1, 4 do
            local label = "budget-" .. index; labels[#labels + 1] = label
            submit(c, label, nil, { gate = "release-" .. index, delay = 0.01, minimum_free_bytes = 50, max_bytes = 100,
                temporary_path = c.root .. "/" .. label .. ".part" })
        end
        await(c, function() return started(c) == 2 end, "two budgeted workers")
        settle(c)
        check("temporary reservations queue requests instead of failing them", started(c) == 2 and c.callbacks["budget-3"].count == 0
            and c.callbacks["budget-4"].count == 0 and parent_queries > 0)
        release(c, "release-1")
        await(c, function() return started(c, "budget-3") == 1 end, "reservation reuse after reap")
        check("one released reservation starts one waiting child", started(c, "budget-4") == 0)
        release(c, "release-2"); release(c, "release-3"); release(c, "release-4")
        complete(c, labels)
        check("real work overlap respects the aggregate storage reservation", overlap(c) == 2 and overlap(c, nil, true) <= 2)
        local impossible = submit(c, "impossible", nil, { minimum_free_bytes = 50, max_bytes = 201,
            temporary_path = c.root .. "/impossible.part" })
        await(c, function() return impossible.count == 1 end, "permanent low-space rejection")
        check("an individually oversized write fails before fork", impossible.error and impossible.error.kind == "low_space"
            and impossible.value == nil and started(c, "impossible") == 0)
    end)
    test("retry_and_preemption_reacquire_storage_reservations", function()
        local c = context(2)
        Budget.available = function() return 150 end
        c.controls.retry = { retry_once = true, delay = 0.015 }
        local function fields(label, gate)
            return { minimum_free_bytes = 50, max_bytes = 100, temporary_path = c.root .. "/" .. label .. ".part", gate = gate }
        end
        submit(c, "retry", nil, fields("retry"))
        submit(c, "neighbor", nil, fields("neighbor"))
        complete(c, { "retry", "neighbor" })
        check("the retry releases its reservation during backoff", started(c, "retry") == 2 and started(c, "neighbor") == 1
            and overlap(c) == 1 and overlap(c, nil, true) == 1)
        submit(c, "background", { resource = "image", priority = 40 }, fields("background", "release-preempted"))
        await(c, function() return started(c, "background") == 1 end, "budgeted background worker")
        submit(c, "urgent", { resource = "image", priority = 0 }, fields("urgent"))
        await(c, function() return c.callbacks.urgent.count == 1 and started(c, "background") == 2 end, "preemption reservation reuse")
        check("preemption has no duplicate or early callback", c.callbacks.background.count == 0)
        release(c, "release-preempted"); complete(c, { "background", "urgent" })
        check("preemption also respects aggregate reservations", overlap(c) == 1 and overlap(c, nil, true) == 1)
    end)
    test("reservations_follow_the_filesystem_across_directories", function()
        local c, labels = context(4), {}
        local other = "/dev/shm/bilicomics-concurrency-" .. parent_pid .. "-" .. sequence
        assert(not lfs.attributes(other), "The second filesystem fixture must be fresh")
        Files.mkdir(other); c.external_roots[#c.external_roots + 1] = other
        check("the fixture uses two different real filesystems", lfs.attributes(c.root).dev ~= lfs.attributes(other).dev)
        local first, second = c.root .. "/directory-one", c.root .. "/directory-two"
        Files.mkdir(first); Files.mkdir(second)
        Budget.available = function() return 250 end
        local roots = { first, second, first, other, other }
        local reservations = { 100, 150, 100, 100, 150 }
        for index, root in ipairs(roots) do
            local label = "filesystem-" .. index; labels[#labels + 1] = label
            submit(c, label, nil, { gate = "release-filesystems", delay = 0.015, minimum_free_bytes = 0, max_bytes = reservations[index],
                temporary_path = root .. "/" .. label .. ".part" })
        end
        await(c, function() return started(c) == 4 end, "two workers on each filesystem")
        settle(c)
        check("same-filesystem directories share one budget", started(c, "filesystem-1") == 1
            and started(c, "filesystem-2") == 1 and started(c, "filesystem-3") == 0)
        check("a blocked filesystem does not starve a different one", started(c, "filesystem-4") == 1 and started(c, "filesystem-5") == 1)
        release(c, "release-filesystems"); complete(c, labels)
        check("separate filesystem budgets allow four real simultaneous workers", overlap(c) == 4)
        check("same-filesystem reservations remain capped at two", overlap(c, function(item)
            return item.label == "filesystem-1" or item.label == "filesystem-2" or item.label == "filesystem-3"
        end, true) == 2)
    end)
    test("cancel_and_timeout_release_reservations_after_reap", function()
        local c = context(4)
        Budget.available = function() return 150 end
        local function fields(label, gate)
            return { minimum_free_bytes = 50, max_bytes = 100, temporary_path = c.root .. "/" .. label .. ".part", gate = gate }
        end
        local canceled = submit(c, "cancel-budget", nil, fields("cancel-budget", "never-release-cancel"))
        await(c, function() return started(c, "cancel-budget") == 1 end, "the cancelable reservation")
        check("cancel is accepted", c.runner:cancel(canceled.id))
        submit(c, "after-cancel", nil, fields("after-cancel"))
        check("a canceling child retains its reservation until reap", started(c, "after-cancel") == 0 and #c.forks == 1)
        complete(c, { "after-cancel" })
        check("canceled work settles once", canceled.count == 1 and canceled.error and canceled.error.kind == "canceled")
        local timeout = submit(c, "timeout-budget", { resource = "image", priority = 40, timeout = 0.025, retry_attempts = 1 },
            fields("timeout-budget", "never-release-timeout"))
        submit(c, "after-timeout", nil, fields("after-timeout"))
        complete(c, { "after-timeout" })
        check("timed-out work settles once and frees its reservation", timeout.count == 1 and timeout.error and timeout.error.kind == "timeout")
        check("cancellation and timeout never overbook actual storage work", overlap(c) == 1 and overlap(c, nil, true) == 1)
    end)
end

if suite == "service" then
    test("legacy_settings_without_concurrency_keep_one_page_window", function()
        local c = context(4)
        local settings = { get = function(_, key)
            if key == "minimum_free_bytes" then return 0 end
            if key == "cache_limit_bytes" then return 256 * 1024 * 1024 end
        end }
        local v = seed(c, 3, { settings = settings })
        for index = 1, 3 do c.controls[v:label(index)] = { gate = "release-legacy" } end
        local job = assert(v.service:enqueue("comic", "episode"))
        await(c, function() return started(c) == 1 end, "the compatible single-page window")
        settle(c); check("missing concurrency settings retain one in-flight page", started(c) == 1)
        release(c, "release-legacy")
        await(c, function() return v.store:getJob(job.id).state == "complete" end, "the compatible chapter")
        check("legacy settings remain actually serial", overlap(c) == 1)
        validateChapter(c, v, 3)
    end)
    for _, n in ipairs({ 1, 2, 4 }) do
        test("single_chapter_real_parallel_download_" .. n, function()
            local c = context(n)
            local v = seed(c, 7)
            for index = 1, 7 do c.controls[v:label(index)] = { gate = "release-chapter" } end
            local job = assert(v.service:enqueue("comic", "episode"))
            await(c, function() return started(c) == n end, "the chapter image window")
            settle(c)
            check("one explicit chapter fills its image window", started(c) == n and v.store:getJob(job.id).state == "running")
            release(c, "release-chapter")
            await(c, function() return v.store:getJob(job.id).state == "complete" end, "the complete chapter")
            settle(c)
            check("actual page workers overlap at the selected concurrency", overlap(c) == n)
            check("completion counts each committed page once", v.ready == 7 and v.store:getJob(job.id).completed == 7)
            validateChapter(c, v, 7)
        end)
    end
    test("live_increase_refills_the_current_chapter", function()
        local c = context(1)
        local v = seed(c, 5)
        for index = 1, 5 do c.controls[v:label(index)] = { gate = "release-increase" } end
        local job = assert(v.service:enqueue("comic", "episode"))
        await(c, function() return started(c) == 1 end, "the first page")
        v.settings.value = 3
        check("Runner accepts the live increase", c.runner:setImageConcurrency(3) == 3)
        v.service:refreshConcurrency(); v.service:refreshConcurrency()
        await(c, function() return started(c) == 3 end, "the current job to fill the larger window")
        check("refill happens before any prior page finishes", v.ready == 0 and v.store:getJob(job.id).completed == 0)
        release(c, "release-increase")
        await(c, function() return v.store:getJob(job.id).state == "complete" end, "the increased chapter")
        check("the existing chapter reaches three actual workers", overlap(c) == 3)
        validateChapter(c, v, 5)
    end)
    test("out_of_order_settlement_refills_distinct_pages", function()
        local c = context(4)
        local v = seed(c, 7)
        for index = 1, 7 do c.controls[v:label(index)] = { gate = "release-page-" .. index, delay = 0.015 } end
        local job = assert(v.service:enqueue("comic", "episode"))
        await(c, function() return started(c) == 4 end, "four initial pages")
        release(c, "release-page-3")
        await(c, function() return started(c, v:label(5)) == 1 end, "page five after page three")
        check("out-of-order completion counts only ready pages", v.store:getJob(job.id).completed == 1 and started(c) == 5)
        release(c, "release-page-1")
        await(c, function() return started(c, v:label(6)) == 1 end, "page six after page one")
        v.service:refreshConcurrency(); v.service:refreshConcurrency(); settle(c)
        check("repeated refresh does not duplicate a page or exceed the window", started(c) == 6 and v.store:getJob(job.id).completed == 2)
        for index = 1, 7 do release(c, "release-page-" .. index) end
        await(c, function() return v.store:getJob(job.id).state == "complete" end, "all distinct pages")
        validateChapter(c, v, 7)
    end)
    test("live_chapter_downshift_stops_new_page_starts", function()
        local c = context(4)
        local v = seed(c, 6)
        for index = 1, 6 do c.controls[v:label(index)] = { gate = "release-downshift-" .. index, delay = 0.015 } end
        local job = assert(v.service:enqueue("comic", "episode"))
        await(c, function() return started(c) == 4 end, "four chapter workers")
        v.settings.value = 1; c.runner:setImageConcurrency(1); v.service:refreshConcurrency()
        for index = 1, 3 do
            release(c, "release-downshift-" .. index)
            await(c, function() return v.ready == index end, "one original page commit")
            settle(c)
            check("the reduced chapter does not refill before draining", started(c) == 4)
        end
        release(c, "release-downshift-4")
        await(c, function() return started(c, v:label(5)) == 1 end, "the serial fifth page")
        settle(c); check("the sixth page still waits", started(c, v:label(6)) == 0)
        release(c, "release-downshift-5")
        await(c, function() return started(c, v:label(6)) == 1 end, "the serial sixth page")
        release(c, "release-downshift-6")
        await(c, function() return v.store:getJob(job.id).state == "complete" end, "the downshifted chapter")
        validateChapter(c, v, 6)
    end)
    test("visible_owner_promotes_one_page_and_pause_preserves_reader", function()
        local c = context(4)
        local v = seed(c, 6)
        for index = 1, 6 do c.controls[v:label(index)] = { gate = "release-shared" } end
        local callbacks = { first = 0, second = 0 }
        local first = v.service:requestPage(v.descriptor, 1, { reader_generation = 41, prefetch = true }, function(page, err)
            callbacks.first, callbacks.first_page, callbacks.first_error = callbacks.first + 1, page, err
        end)
        local job = assert(v.service:enqueue("comic", "episode"))
        await(c, function() return started(c) == 4 end, "the shared download window")
        local same = v.service:requestPage(v.descriptor, 1, { reader_generation = 42 }, function(page, err)
            callbacks.second, callbacks.second_page, callbacks.second_error = callbacks.second + 1, page, err
        end)
        check("visible ownership promotes the same acquisition", same == first and c.runner.tasks[first].priority == 0
            and started(c, v:label(1)) == 1)
        v.service:releaseReader(41)
        check("another reader and the job retain the same worker", not c.runner.tasks[first].cancel_kind)
        check("pause is accepted", v.service:pause(job.id))
        settle(c)
        check("pause removes job owners and preserves the remaining reader", v.store:getJob(job.id).state == "paused"
            and c.runner.tasks[first] and not c.runner.tasks[first].cancel_kind)
        for _, request in pairs(v.service.requests) do
            check("the paused job owns no remaining acquisition", not request.owners["job:" .. job.id])
        end
        release(c, "release-shared")
        await(c, function() return callbacks.second == 1 end, "the shared reader page")
        settle(c)
        check("shared callbacks settle once with the same committed image", callbacks.first == 1 and callbacks.second == 1
            and callbacks.first_page.path == callbacks.second_page.path and not callbacks.first_error and not callbacks.second_error)
        check("pause does not resume or complete the chapter", v.store:getJob(job.id).state == "paused" and v.ready == 1 and started(c) == 4)
        for index = 2, 4 do
            check("unowned page " .. index .. " is canceled before writing", traces(c, v:label(index))[1].ended_at == nil
                and v.store:getPage("episode/R1/" .. index).state == "missing")
        end
    end)
    test("one_page_failure_retires_other_job_owners", function()
        local c = context(4)
        local v = seed(c, 6)
        for index = 1, 6 do c.controls[v:label(index)] = { gate = "release-failure" } end
        c.controls[v:label(2)] = { gate = "fail-page", delay = 0.01,
            failure = { kind = "image_invalid", retryable = false, message = "Synthetic invalid image" } }
        local reader = { count = 0 }
        v.service:requestPage(v.descriptor, 1, { reader_generation = 77 }, function(page, err)
            reader.count, reader.page, reader.error = reader.count + 1, page, err
        end)
        local job = assert(v.service:enqueue("comic", "episode"))
        await(c, function() return started(c) == 4 end, "the failing chapter window")
        release(c, "fail-page")
        await(c, function() return v.store:getJob(job.id).state == "failed" end, "the failed job")
        settle(c)
        for _, request in pairs(v.service.requests) do check("failure retires every job owner", not request.owners["job:" .. job.id]) end
        release(c, "release-failure")
        await(c, function() return reader.count == 1 end, "the unaffected reader")
        settle(c)
        check("the shared reader still commits successfully", reader.page and not reader.error and v.ready == 1)
        check("failure preserves the terminal job and starts no later pages", v.store:getJob(job.id).state == "failed" and started(c) == 4)
        for index = 3, 4 do check("exclusive sibling work is canceled", traces(c, v:label(index))[1].ended_at == nil) end
    end)
    test("failure_counts_ready_pages_before_deferred_refill", function()
        local c = context(2)
        local v = seed(c, 4)
        c.controls[v:label(1)] = { gate = "release-counted-success", delay = 0.015 }
        c.controls[v:label(2)] = { gate = "release-counted-failure", delay = 0.015,
            failure = { kind = "image_invalid", retryable = false, message = "Synthetic invalid sibling image" } }
        local job = assert(v.service:enqueue("comic", "episode"))
        await(c, function() return started(c) == 2 end, "the successful and failing page workers")
        local original_defer, delayed = v.service._defer, {}
        v.service._defer = function(_, callback) delayed[#delayed + 1] = callback end
        release(c, "release-counted-success")
        await(c, function() return v.ready == 1 end, "the real successful page commit")
        check("the successful page is committed before deferred progress runs", #delayed == 1
            and v.store:getJob(job.id).completed == 0 and v.store:getPage("episode/R1/1").state == "ready" and started(c) == 2)
        release(c, "release-counted-failure")
        await(c, function() return v.store:getJob(job.id).state == "failed" end, "the sibling failure")
        local actual_ready = 0
        for index = 1, 4 do
            if v.pages:getPage("episode", "R1", index).state == "ready" then actual_ready = actual_ready + 1 end
        end
        check("failure persists the count of real ready pages", actual_ready == 1 and v.store:getJob(job.id).completed == actual_ready)
        v.service._defer = original_defer
        for _, callback in ipairs(delayed) do original_defer(v.service, callback) end
        settle(c, 0.06)
        check("delayed refill cannot restart the stopped job", v.store:getJob(job.id).state == "failed"
            and v.store:getJob(job.id).completed == 1 and started(c) == 2 and v.ready == 1 and #c.commits == 1)
        check("the successful page and descriptor remain verified", Files.digest(v.store:getPage("episode/R1/1").path) == Files.digest(fixture_path)
            and Files.read(v.descriptor_path) == v.identity and #v.store:listCommits() == 0)
    end)
    test("immediate_resume_ignores_old_parallel_cancellation_callbacks", function()
        local c = context(4)
        local v = seed(c, 6)
        for index = 1, 6 do c.controls[v:label(index)] = { gate = "release-resumed" } end
        local reader = { count = 0 }
        v.service:requestPage(v.descriptor, 1, { reader_generation = 81 }, function(page, err)
            reader.count, reader.page, reader.error = reader.count + 1, page, err
        end)
        local job = assert(v.service:enqueue("comic", "episode"))
        await(c, function() return started(c) == 4 end, "the initial parallel attempt")
        v.service:pause(job.id)
        check("immediate resume is accepted", v.service:resume(job.id))
        await(c, function() return started(c) == 7 end, "fresh attempts after old children are reaped")
        check("old cancellations do not fail or complete the resumed job", v.store:getJob(job.id).state == "running"
            and v.store:getJob(job.id).completed == 0 and started(c, v:label(1)) == 1)
        release(c, "release-resumed")
        await(c, function() return v.store:getJob(job.id).state == "complete" end, "the resumed chapter")
        settle(c)
        check("the surviving shared reader settles once", reader.count == 1 and reader.page and not reader.error)
        check("only the six current pages are committed", v.ready == 6 and #c.commits == 6
            and v.pages:isComplete("episode", "R1") and v.store:getJob(job.id).completed == 6)
        for index = 1, 6 do check("resumed page generations do not double advance", v.store:getPage("episode/R1/" .. index).content_generation == 1) end
        check("resumption preserves the descriptor", Files.read(v.descriptor_path) == v.identity)
    end)
    test("source_generation_change_retires_only_the_stale_page", function()
        local c = context(2)
        local v = seed(c, 2)
        c.controls[v:label(1)] = { gate = "release-stale" }
        c.controls[v:label(2)] = { gate = "release-current" }
        local old, fresh, neighbor = { count = 0 }, { count = 0 }, { count = 0 }
        local old_id = v.service:requestPage(v.descriptor, 1, { reader_generation = 91, prefetch = true }, function(page, err)
            old.count, old.page, old.error = old.count + 1, page, err
        end)
        v.service:requestPage(v.descriptor, 2, { reader_generation = 92 }, function(page, err)
            neighbor.count, neighbor.page, neighbor.error = neighbor.count + 1, page, err
        end)
        await(c, function() return started(c) == 2 end, "two source generations")
        local replacement = v:label(1) .. "-replacement"
        v.store:updatePage("episode/R1/1", { extra = { source_path = replacement, source_generation = 1 } })
        local new_id = v.service:requestPage(v.descriptor, 1, { reader_generation = 93 }, function(page, err)
            fresh.count, fresh.page, fresh.error = fresh.count + 1, page, err
        end)
        check("a new source generation receives a new acquisition", new_id ~= old_id)
        await(c, function() return fresh.count == 1 and old.count == 1 end, "new source commit and stale retirement")
        check("the old source settles as canceled and cannot commit", old.page == nil and old.error and old.error.kind == "canceled"
            and traces(c, v:label(1))[1].ended_at == nil)
        check("the replacement commits once in the parent", fresh.page and not fresh.error
            and fresh.page.extra.source_generation == 1 and fresh.page.content_generation == 1)
        check("the neighboring page retains its original worker", started(c, v:label(2)) == 1 and neighbor.count == 0)
        release(c, "release-current")
        await(c, function() return neighbor.count == 1 end, "the independent neighboring page")
        check("independent current pages remain valid", neighbor.page and not neighbor.error and v.pages:isComplete("episode", "R1")
            and Files.read(v.descriptor_path) == v.identity and #v.store:listCommits() == 0 and #c.commits == 2)
    end)
    test("session_wrapper_and_real_default_settings_keep_account_isolation", function()
        local c = context(2)
        local session = { serialize = function() return { synthetic = true } end }
        local manager = {}
        function manager:ensure(done) done(session) end
        function manager:canDispatch() return true end
        function manager:cancel() end
        function manager:suspend() end
        function manager:resume() end
        local wrapper = SessionRunner.new{ runner = c.runner, manager = manager, get_session = function() return session end }
        check("SessionRunner delegates live capacity access", wrapper:getImageConcurrency() == 2 and wrapper:setImageConcurrency(3) == 3)
        local settings = Settings.open(c.root .. "/real-settings")
        settings:set("minimum_free_bytes", 0)
        local a = seed(c, 3, { settings = settings, runner = wrapper })
        local b = seed(c, 3, { account = "synthetic-concurrency-b", settings = settings, runner = wrapper })
        wrapper:setImageConcurrency(settings:get("download_concurrency"))
        for index = 1, 3 do c.controls[a:label(index)] = { gate = "release-default" } end
        local job = assert(a.service:enqueue("comic", "episode"))
        await(c, function() return started(c) == 2 end, "the default two-page window")
        check("real default settings produce two simultaneous pages", a.ready == 0 and started(c) == 2)
        release(c, "release-default")
        await(c, function() return a.store:getJob(job.id).state == "complete" end, "the account chapter")
        validateChapter(c, a, 3)
        check("another synthetic account retains an untouched descriptor", Files.read(b.descriptor_path) == b.identity
            and #b.store:listJobs() == 0 and not b.pages:isComplete("episode", "R1"))
        for index = 1, 3 do check("cross-account page state is isolated", b.store:getPage("episode/R1/" .. index).state == "missing") end
    end)
end

ffiutil.runInSubProcess, ffiutil.isSubProcessDone, Budget.available = original_fork, original_done, original_available
local passed = #report.tests > 0
for _, result in ipairs(report.tests) do passed = passed and result.passed end
report.passed = passed
report.counts = { tests = #report.tests, assertions = #report.assertions, actual_forks = 0 }
for _, trace in ipairs(report.traces) do report.counts.actual_forks = report.counts.actual_forks + trace.forks end
Files.write(result_path, json.encode(report, { pretty = true }))
assert(passed, "One or more real concurrency acceptance cases failed")
