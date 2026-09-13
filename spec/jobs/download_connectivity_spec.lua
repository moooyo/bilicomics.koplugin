-- Focused remote-only connectivity checks with real services, SQLite and page files.
-- Worker completions are controlled; the separate Runner spec exercises real forks.
require("setupkoenv")
local source, output, fixture_path, result_path = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local Service = require("bilicomics/jobs/download_service")
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Controller = require("bilicomics/controller")
local Session = require("bilicomics/protocol/session")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local contexts, controllers, sequence = {}, {}, 0
local report = { tests = {}, assertions = {}, passed = false,
    scope = "Real DownloadService/Controller/SQLite/PageStore; controlled asynchronous image results, synthetic accounts, no network or monetary operations" }
local current_case = "setup"
local bytes = Files.read(fixture_path, 65536)
local function check(name, value)
    local label = current_case .. ": " .. name
    report.assertions[#report.assertions + 1] = { name = label, passed = not not value }
    assert(value, label)
end
local function scheduler()
    local ui = { queue = {} }
    function ui:nextTick(fn) self.queue[#self.queue + 1] = fn end
    function ui:scheduleIn() end
    function ui:unschedule() end
    function ui:show() end
    function ui:close() end
    function ui:flush()
        local limit = 100
        while #self.queue > 0 do
            limit = limit - 1; assert(limit > 0, "Deferred work must settle")
            table.remove(self.queue, 1)()
        end
    end
    return ui
end
local function runner()
    local value = { submitted = {}, pending = {}, canceled = {} }
    function value:submit(request, options, callback)
        assert(request.kind == "download_page" or request.kind == "client" and request.method == "imageIndex",
            "Only reading acquisition requests are allowed")
        local task = { id = options.id or "synthetic-" .. (#self.submitted + 1), request = request, options = options, callback = callback }
        self.submitted[#self.submitted + 1], self.pending[task.id] = task, task
        return task.id
    end
    function value:finish(task, result, err)
        assert(self.pending[task.id] == task)
        self.pending[task.id] = nil; task.callback(result, err)
    end
    function value:cancel(id)
        local task = self.pending[id]
        self.canceled[id], self.pending[id] = true, nil
        if task then task.callback(nil, { kind = "canceled" }) end
        return true
    end
    function value:promote() end
    function value:suspend() self.suspended = true end
    function value:resume() self.suspended = false end
    function value:close()
        local ids = {}; for id in pairs(self.pending) do ids[#ids + 1] = id end
        for _, id in ipairs(ids) do self:cancel(id) end
        self.closed = true
    end
    return value
end
local function image(context, temporary)
    Files.write(temporary, bytes)
    return { temporary_path = temporary, checksum = Files.digest(temporary), width = 40, height = 80, format = "png",
        geometry = { source_width = 40, source_height = 80, exif_orientation = 1 } }
end
local function descriptor(context)
    context.descriptor = { schema_version = 1, account_key = "synthetic-connectivity", comic_id = "81", episode_id = "101", revision = "R1",
        pages = { { id = "one", index = 1, width = 40, height = 80 }, { id = "two", index = 2, width = 40, height = 80 } } }
    context.path = context.pages:ensureDescriptor(context.descriptor)
    for i = 1, 2 do
        local record = context.store:getPage("101/R1/" .. i)
        record.extra.source_path = "/synthetic/" .. i; context.store:putPage(record)
    end
    return { descriptor = context.descriptor, path = context.path }
end
local function seed(options)
    options = options or {}; sequence = sequence + 1
    local context = { root = output .. "/case-" .. sequence, connected = options.connected ~= false, authenticated = options.authenticated ~= false,
        preparations = 0, predicate_calls = 0, ui = scheduler(), runner = runner() }
    context.store = Store.open{ root = context.root, account_key = "synthetic-connectivity", wal = false }
    context.pages = PageStore.new{ root = context.root, account_key = "synthetic-connectivity", store = context.store }
    context.store:upsertComic{ id = "81", title = "Synthetic connectivity" }
    context.store:upsertEpisodes("81", { { id = "101", title = "Synthetic chapter", order = 1, access = "free",
        extra = options.descriptor == false and {} or { current_revision = "R1" } } })
    if options.descriptor ~= false then descriptor(context) end
    for i = 1, options.ready or 0 do
        local record = context.store:getPage("101/R1/" .. i)
        context.pages:commitPage({ account_key = "synthetic-connectivity", episode_id = "101", revision = "R1", index = i,
            id = record.id, expected_content_generation = record.content_generation },
            image(context, context.pages.temporary_root .. "/seed-" .. i .. ".part"))
    end
    context.service = Service.new{ store = context.store, pages = context.pages, runner = context.runner, account_key = "synthetic-connectivity",
        ui = context.ui, session = function() return context.authenticated and { synthetic = true } or nil end,
        authentication_valid = function() return context.authenticated end,
        network_available = function()
            context.predicate_calls = context.predicate_calls + 1
            if context.throw_predicate then error("Synthetic connectivity callback failure") end
            return context.connected
        end,
        prepare = function(_, _, done)
            context.preparations = context.preparations + 1; context.prepared = done
        end }
    contexts[#contexts + 1] = context
    return context
end
local function paused(context, id, kind)
    local job = context.store:getJob(id)
    check("job remains durable and paused with an explicit reason", job.state == "paused" and job.error and job.error.kind == (kind or "network"))
    return job
end
local function job(context)
    context.store:putJob{ id = "partial", kind = "episode_download", state = "paused", comic_id = "81", episode_id = "101",
        revision = "R1", run_generation = 4, total = 2, completed = 0, payload = {} }
    return "partial"
end
local function run(name, fn)
    current_case = name
    local ok, err = xpcall(fn, debug.traceback)
    for _, app in ipairs(controllers) do if not app.closed then pcall(app.close, app) end end
    for _, context in ipairs(contexts) do
        if context.store.connection then context.service:close(); context.runner:close(); context.store:close() end
    end
    contexts, controllers = {}, {}
    report.tests[#report.tests + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    print((ok and "PASS " or "FAIL ") .. name)
end

run("offline_enqueue_without_descriptor", function()
    local c = seed{ connected = false, descriptor = false }
    local created = assert(c.service:enqueue("81", "101")); c.ui:flush(); paused(c, created.id)
    check("no index preparation or worker is dispatched", c.preparations == 0 and #c.runner.submitted == 0)
    check("no placeholder revision is invented", #c.store:listDescriptors() == 0 and #c.store:listJobs() == 1)
end)
run("partial_resume_offline_preserves_cached_page", function()
    local c = seed{ connected = false, ready = 1 }; local id = job(c)
    local path = c.store:getPage("101/R1/1").path
    local accepted, err = c.service:resume(id); c.ui:flush()
    check("resume returns the connectivity failure", accepted == false and err.kind == "network")
    check("network pause advances the job generation", paused(c, id).run_generation == 5)
    check("the ready file stays usable with zero acquisition", Files.digest(path) == Files.digest(fixture_path)
        and #c.runner.submitted == 0 and c.preparations == 0)
end)
run("ready_page_precedes_session_and_network_checks", function()
    local c = seed{ connected = false, authenticated = false, ready = 1 }
    c.throw_predicate = true
    local calls = 0
    c.service:requestPage(c.descriptor, 1, {}, function(value, err) calls = calls + 1; check("cached page is returned", value and not err) end)
    check("cache callback remains asynchronous", calls == 0); c.ui:flush()
    check("ready cache bypasses all network work", calls == 1 and c.predicate_calls == 0 and #c.runner.submitted == 0)
end)
run("complete_cache_can_pin_and_complete_without_session", function()
    local c = seed{ connected = false, authenticated = false, ready = 2 }; local id = job(c)
    check("local resume is accepted", c.service:resume(id)); c.ui:flush()
    local current = c.store:getJob(id)
    check("the complete local chapter is pinned and complete", current.state == "complete" and current.completed == 2
        and c.store:isPinned("101", "R1"))
    check("complete local work never prepares or dispatches", c.preparations == 0 and #c.runner.submitted == 0)
end)
run("throwing_connection_predicate_fails_closed", function()
    local c = seed(); c.throw_predicate = true
    local id = job(c); local accepted, err = c.service:resume(id)
    check("predicate failure becomes a paused network error", accepted == false and err.kind == "network"); paused(c, id)
    local calls = 0
    c.service:requestPage(c.descriptor, 1, {}, function(value, failure)
        calls = calls + 1; check("missing page rejects failed predicate", not value and failure.kind == "network")
    end)
    c.ui:flush()
    check("predicate exception starts no worker and returns once", #c.runner.submitted == 0 and calls == 1)
end)
run("disconnect_after_async_preparation", function()
    local c = seed{ descriptor = false }
    local created = assert(c.service:enqueue("81", "101"))
    check("one index preparation is pending", c.preparations == 1 and c.prepared ~= nil)
    local prepared = descriptor(c); c.connected = false; c.prepared(prepared); c.ui:flush()
    paused(c, created.id)
    check("no image worker starts after preparation returns offline", #c.runner.submitted == 0)
end)
for _, kind in ipairs({ "network", "timeout" }) do
    run("preparation_" .. kind .. "_pauses", function()
        local c = seed{ descriptor = false }; local created = assert(c.service:enqueue("81", "101"))
        c.prepared(nil, { kind = kind, retryable = true }); c.ui:flush(); paused(c, created.id, kind)
        check("failed preparation dispatches no image", #c.runner.submitted == 0)
    end)
end
run("disconnect_between_page_commits", function()
    local c = seed(); local created = assert(c.service:enqueue("81", "101")); c.ui:flush()
    check("only the first page is in flight", #c.runner.submitted == 1)
    local task = c.runner.submitted[1]; c.connected = false
    c.runner:finish(task, image(c, task.request.temporary_path)); c.ui:flush(); paused(c, created.id)
    check("arriving valid bytes commit but no next page starts", c.store:getPage("101/R1/1").state == "ready"
        and c.store:getPage("101/R1/2").state == "missing" and #c.runner.submitted == 1)
end)
for _, kind in ipairs({ "network", "timeout" }) do
    run("image_" .. kind .. "_pauses", function()
        local c = seed(); local created = assert(c.service:enqueue("81", "101")); c.ui:flush()
        c.runner:finish(c.runner.submitted[1], nil, { kind = kind, retryable = true }); c.ui:flush(); paused(c, created.id, kind)
        check("terminal acquisition failure does not advance", #c.runner.submitted == 1 and c.store:getJob(created.id).completed == 0)
    end)
end
run("cancellation_rejects_late_preparation", function()
    local c = seed{ descriptor = false }; local created = assert(c.service:enqueue("81", "101"))
    c.service:pause(created.id, true); local generation = c.store:getJob(created.id).run_generation
    c.connected = false; c.prepared(descriptor(c)); c.ui:flush()
    check("the late callback cannot undo cancellation", c.store:getJob(created.id).state == "canceled"
        and c.store:getJob(created.id).run_generation == generation and #c.runner.submitted == 0)
end)
run("service_close_rejects_late_preparation", function()
    local c = seed{ descriptor = false }; local created = assert(c.service:enqueue("81", "101"))
    c.service:close(); local generation = c.store:getJob(created.id).run_generation
    c.prepared(descriptor(c)); c.ui:flush()
    check("closed lifetime does not publish running state or images", c.store:getJob(created.id).state == "paused"
        and c.store:getJob(created.id).run_generation == generation and #c.runner.submitted == 0)
end)
run("explicit_resume_after_reconnect_reuses_job", function()
    local c = seed{ connected = false }; local id = job(c)
    c.service:resume(id); c.connected = true; c.ui:flush()
    check("connectivity alone does not add polling or automatic work", #c.runner.submitted == 0)
    check("the explicit retry can resume", c.service:resume(id)); c.ui:flush()
    for i = 1, 2 do local task = c.runner.submitted[i]; c.runner:finish(task, image(c, task.request.temporary_path)); c.ui:flush() end
    check("the original durable job completes", #c.store:listJobs() == 1 and c.store:getJob(id).state == "complete"
        and #c.runner.submitted == 2 and c.store:isPinned("101", "R1"))
end)
run("page_before_start_guard_rechecks_connection", function()
    local c = seed(); local created = assert(c.service:enqueue("81", "101")); c.ui:flush()
    local task = c.runner.submitted[1]
    check("page task carries a parent-side guard", type(task.options.before_start) == "function" and task.options.before_start() == true)
    c.connected = false; local allowed, err = task.options.before_start()
    check("the queued task becomes unavailable", allowed ~= true and err.kind == "network")
    c.runner:finish(task, nil, err); c.ui:flush(); paused(c, created.id)
    check("guard rejection never advances to another image", #c.runner.submitted == 1)
end)
run("controller_injects_account_lifecycle_and_index_guards", function()
    sequence = sequence + 1
    local ui, connected, throws = scheduler(), true, false
    local app = Controller.new{ root = output .. "/controller-" .. sequence, ui_manager = ui,
        network = { isConnected = function() if throws then error("Synthetic connectivity exception") end; return connected end },
        runner_factory = function() return runner() end }
    controllers[#controllers + 1] = app
    local initial = app.account.downloads
    check("production account service receives the connection callback", type(initial.network_available) == "function" and initial:_networkAllowed())
    app.suspended = true; check("suspended app rejects acquisition", not initial:_networkAllowed()); app.suspended = false
    connected = false; check("offline app rejects acquisition", not initial:_networkAllowed()); connected = true
    throws = true; check("device connectivity exception fails closed", not initial:_networkAllowed()); throws = false
    local generation = app.generation; app.generation = generation + 1
    check("obsolete account generation rejects acquisition", not initial:_networkAllowed()); app.generation = generation
    app:_closeAccount()
    local session = assert(Session.parse("SESSDATA=synthetic-only; DedeUserID=42; buvid3=synthetic-connectivity-device"))
    assert(session:withIdentity{ id = "42", name = "Synthetic account" })
    app:_openAccount("bili_42", session, true)
    check("old account closure stays invalid after replacement", not initial:_networkAllowed() and app.account.downloads:_networkAllowed())
    app.account.store:upsertComic{ id = "81", title = "Synthetic comic" }
    app.account.store:upsertEpisodes("81", { { id = "101", order = 1, title = "Synthetic chapter", access = "free" } })
    local callbacks = 0
    app:prepareEpisode("81", "101", function() callbacks = callbacks + 1 end)
    local old_runner, task = app.runner, app.runner.submitted[1]
    check("production index preparation carries its own start guard", task and task.request.method == "imageIndex"
        and type(task.options.before_start) == "function" and task.options.before_start() == true)
    connected = false; local allowed, err = task.options.before_start()
    check("queued index work is blocked after disconnection", allowed ~= true and err.kind == "network"); connected = true
    app:_closeAccount(); app:_openAccount("anonymous", nil)
    check("old index start guard rejects the new account", task.options.before_start() ~= true)
    task.callback({ revision = "late", images = { { id = "one", path = "/synthetic/late", width = 40, height = 80 } } })
    ui:flush()
    check("late old-account metadata cannot enter the new store", callbacks == 0 and #app.account.store:listDescriptors() == 0 and old_runner.closed)
end)

report.passed = #report.tests > 0
for _, item in ipairs(report.tests) do report.passed = report.passed and item.passed end
report.counts = { cases = #report.tests, assertions = #report.assertions }
Files.write(result_path, json.encode(report, { pretty = true }))
print(json.encode({ passed = report.passed, counts = report.counts }))
if not report.passed then os.exit(1) end
