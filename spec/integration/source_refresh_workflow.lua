-- Run only on test-env inside an isolated network namespace.
-- The transport supplies synthetic responses; every application and worker layer is production code.
require("setupkoenv")
local source, work, case = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local Files = require("bilicomics/storage/files")
local Codec = require("bilicomics/storage/codec")
local SourceRefresh = require("bilicomics/storage/source_refresh")
local JSON = require("bilicomics/protocol/json")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local ffi = require("ffi")
local socket = require("socket")
local Controller = require("bilicomics/controller")
local Runner = require("bilicomics/jobs/runner")
local Transport = require("bilicomics/protocol/transport")
local parent_pid = tonumber(ffi.C.getpid())
local report = { case = case, assertions = {}, starts = {}, submitted = {}, passed = false,
    scope = "Production Controller, DownloadService, coordinator, SQLite, PageStore, SourceRefresh, default Worker, Client and real fork/IPC; synthetic transport only" }
local app, account, descriptor, descriptor_path, before, response, response_error, completed
local runners, pulse, refresh_callbacks = {}, 0, 0
local function write(path, value)
    Files.write(path, json.encode(value, { pretty = true }))
end
local process_records = {}
local function recordProcess(pid)
    if not pid then return end
    local file = io.open("/proc/" .. pid .. "/stat", "rb")
    if not file then return end
    local stat = file:read("*a"); file:close()
    local fields = {}
    for field in assert(stat:match("^%d+ %b() (.+)")):gmatch("%S+") do fields[#fields + 1] = field end
    process_records[#process_records + 1] = { pid = pid, start_time = fields[20] }
    write(work .. "/process-records.json", process_records)
end
recordProcess(parent_pid)
local function check(name, condition)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition }
    assert(condition, name)
end
local function same(a, b) return Codec.canonical(a) == Codec.canonical(b) end
local function await(predicate, label, timeout)
    local until_time = socket.gettime() + (timeout or 12)
    while not predicate() do
        assert(socket.gettime() < until_time, "Timed out: " .. label)
        coroutine.yield()
    end
end
local function page(index) return assert(account.store:getPage("101/R1/" .. index)) end
local function candidateCount()
    local n = 0
    Files.walk(account.pages.temporary_root, function() n = n + 1 end)
    return n
end
local function idle()
    for _, runner in ipairs(runners) do if next(runner.tasks) or #runner.queue > 0 then return false end end
    return true
end
local function nativePositions()
    local positions = require("docsettings"):open(descriptor_path):readSetting("page_positions", {})
    local encoded = {}
    for key, value in pairs(positions) do encoded[type(key) .. ":" .. tostring(key)] = value end
    return encoded
end
local function snapshot()
    return { pages = account.store:listAllPages(), descriptor = Files.read(descriptor_path, 4194304),
        descriptors = account.store:listDescriptors(), anchor = account.store:getAnchor("101", "R1"),
        pinned = account.store:isPinned("101", "R1"),
        ready_digest = Files.digest(page(1).path), ready_path = page(1).path,
        ready_identity = assert(SourceRefresh.fileIdentity(page(1).path, account.pages.pages_root)),
        native_positions = nativePositions() }
end
local function oldSnapshotPreserved()
    check("old content, page mappings, descriptor, anchor and pin remain unchanged", same(snapshot(), before))
    check("the authoritative revision remains R1", account.store:getEpisode("101").extra.current_revision == "R1")
    check("no candidate remains", candidateCount() == 0)
    check("no commit journal remains", #account.store:listCommits() == 0)
    check("no source refresh payload remains", not (account.store:getJob("retained-download").payload or {}).source_refresh)
    check("the partial download remains paused", account.store:getJob("retained-download").state == "paused")
end
local function fixture(index, changed)
    return Files.read(work .. "/fixture-" .. (changed and 4 or index) .. ".png", 65536)
end
local guarded_cases = { cancel = true, suspend = true, account_close = true, preempt = true, unpinned_inflight = true }
local wire_sequence = 0
Transport.request = function(_, wire)
    assert(tonumber(ffi.C.getpid()) ~= parent_pid, "Protocol work escaped the real child process")
    local route = wire.url:match("^https://manga%.bilibili%.com/twirp/comic%.v1%.Comic/(%w+)%?")
    local endpoint, index
    if wire.url == "https://api.bilibili.com/x/web-interface/nav" then
        assert(wire.method == "GET")
        endpoint = "nav"
    elseif route then
        assert(wire.method == "POST")
        local body = assert(JSON.decode(wire.body))
        endpoint = route
        if route == "ComicDetail" then assert(body.comic_id == 81)
        elseif route == "GetImageIndex" then assert(body.ep_id == 101)
        elseif route == "ImageToken" then
            local paths = assert(JSON.decode(body.urls))
            assert(#paths == 1 and type(body.m1) == "string")
            index = tonumber(paths[1]:match("^/synthetic/new%-([123])$"))
            assert(index, "An old or unapproved source path reached ImageToken")
        else error("Only the approved read APIs are permitted") end
    else
        index = tonumber(wire.url:match("^https://i0%.hdslb%.com/synthetic%-([123])%.png%?token=synthetic&code=DanmakuInfo$"))
        assert(index and wire.method == "GET" and type(wire.output_path) == "string", "Unapproved transport operation")
        assert(Files.within(wire.output_path, work), "Output escaped the isolated test root")
        for name in pairs(wire.headers or {}) do
            assert(name:lower() ~= "cookie" and name:lower() ~= "authorization")
        end
        endpoint = "CDN"
    end
    wire_sequence = wire_sequence + 1
    write(work .. "/audit/" .. ffi.C.getpid() .. "-" .. wire_sequence .. ".json", {
        child_pid = tonumber(ffi.C.getpid()), parent_pid = parent_pid, endpoint = endpoint, index = index })
    if endpoint == "nav" then
        return { status = 200, body = '{"code":0,"data":{"isLogin":true,"mid":42,"uname":"Synthetic source refresh"}}' }
    elseif endpoint == "ComicDetail" then
        return { status = 200, body = '{"code":0,"data":{"id":81,"title":"Synthetic source refresh","ep_list":[{"id":101,"comic_id":81,"ord":1,"title":"Synthetic chapter","pay_mode":0,"is_locked":false,"unlock_type":0}]}}' }
    elseif endpoint == "GetImageIndex" then
        local images = {}
        for i = 1, 3 do images[i] = { path = "/synthetic/new-" .. i, x = 40, y = (case == "topology" and i == 2) and 81 or 80 } end
        return { status = 200, body = assert(JSON.encode({ code = 0, data = { images = images } })) }
    elseif endpoint == "ImageToken" then
        return { status = 200, body = '{"code":0,"data":[{"complete_url":"https://i0.hdslb.com/synthetic-'
            .. index .. '.png?token=synthetic","hit_encrpyt":false}]}' }
    end
    if guarded_cases[case] and index == 1 and not Files.exists(work .. "/release") then
        -- Leave a genuine partial file for cancellation and preemption to clean/replay.
        Files.write(wire.output_path, fixture(index):sub(1, 23))
        write(work .. "/blocked.json", { pid = tonumber(ffi.C.getpid()), partial_bytes = 23 })
        local deadline = socket.gettime() + 20
        while not Files.exists(work .. "/release") do
            assert(socket.gettime() < deadline, "The synthetic transport gate was not released")
            socket.sleep(0.01)
        end
    end
    Files.write(wire.output_path, fixture(index, case == "changed_bytes" and index == 2))
    return { status = 200, headers = { ["content-type"] = "image/png" } }
end

local function runnerFactory(options)
    options.max_workers = 1
    local runner = Runner.new(options)
    runners[#runners + 1] = runner
    local submit, start = runner.submit, runner._start
    runner.submit = function(self, request, settings, callback)
        assert(request.kind == "source_index" or request.kind == "verify_source_page" or request.kind == "download_page"
            or (request.kind == "client" and request.method == "validateSession"), "Unapproved worker kind")
        report.submitted[#report.submitted + 1] = { kind = request.kind, index = request.index,
            reference = request.reference ~= nil, source_path = request.source_path }
        return submit(self, request, settings, function(value, err)
            if request.kind == "source_index" and value then
                local index = value.index
                local rotated = index.revision ~= "R1" and #index.images == 3
                for i, image in ipairs(index.images) do
                    rotated = rotated and image.id ~= "original-" .. i and image.path == "/synthetic/new-" .. i
                end
                report.normalized_index_rotates_all_identifiers = not not rotated
            end
            if callback then callback(value, err) end
        end)
    end
    runner._start = function(self, task)
        start(self, task)
        recordProcess(task.pid)
        report.starts[#report.starts + 1] = { kind = task.request.kind, index = task.request.index,
            attempt = task.attempt, pid = task.pid, task_id = task.id }
    end
    return runner
end

local function seed()
    app = Controller.new{ root = work .. "/plugin", ui_manager = UIManager, runner_factory = runnerFactory,
        network = { isConnected = function() return true end } }
    app:importSession("SESSDATA=synthetic-only; DedeUserID=42; bili_jct=synthetic-csrf", function(value, err)
        response, response_error, completed = value, err, true
    end)
    await(function() return completed end, "synthetic session validation")
    check("the real session import completes through a nav worker", response and not response_error)
    account = app.account
    account.store:upsertComic{ id = "81", title = "Synthetic source refresh" }
    account.store:upsertEpisodes("81", { { id = "101", title = "Synthetic chapter", order = 1,
        access = "free", extra = { current_revision = "R1" } } })
    descriptor = { schema_version = 1, account_key = account.key, comic_id = "81", episode_id = "101", revision = "R1", pages = {} }
    for i = 1, 3 do descriptor.pages[i] = { id = "original-" .. i, index = i, width = 40, height = 80 } end
    descriptor_path = account.pages:ensureDescriptor(descriptor)
    for i = 1, 3 do
        local record = page(i)
        record.extra.source_path = "/synthetic/old-" .. i
        account.store:putPage(record)
    end
    for i = 1, 2 do
        local temporary = account.pages.temporary_root .. "/seed-" .. i .. ".part"
        Files.write(temporary, fixture(i))
        local record = page(i)
        account.pages:commitPage({ account_key = account.key, episode_id = "101", revision = "R1", index = i,
            id = record.id, expected_content_generation = record.content_generation, expected_source_generation = 0 },
            { temporary_path = temporary, checksum = Files.digest(temporary), width = 40, height = 80, format = "png",
                geometry = { source_width = 40, source_height = 80, exif_orientation = 1 } })
    end
    account.pages:_evict(page(2))
    account.pages:pinEpisode("101", "R1", true)
    account.store:putAnchor("101", "R1", { schema_version = 1, page_id = "original-1", index = 1, x = 0, y = 0.125,
        source = { x = 0, y = 0.125 }, rotation = 0, mode = "continuous", zoom_mode = "pagewidth", zoom_ratio = 1,
        geometry_generation = page(1).geometry_generation })
    account.store:putJob{ id = "retained-download", kind = "episode_download", state = "paused", comic_id = "81",
        episode_id = "101", revision = "R1", run_generation = 4, completed = 1, total = 3, payload = {} }
    check("A is ready while B is evicted with a retained digest", page(1).state == "ready" and page(2).state == "missing"
        and page(2).extra.last_committed_checksum == Files.digest(work .. "/fixture-2.png"))
    check("C has positive never-downloaded history", page(3).extra.content_history_version == 1
        and page(3).extra.last_committed_checksum == nil)
    if case == "unpinned_preflight" or case == "unpinned_inflight" then account.pages:pinEpisode("101", "R1", false) end
    if case == "legacy_unknown" or case == "unpinned_preflight" then
        local record = page(3); record.extra.content_history_version = nil; account.store:putPage(record)
    elseif case == "native_positions" then
        local settings = require("docsettings"):open(descriptor_path)
        settings:saveSetting("page_positions", { [3] = 0.3 }); settings:flush()
    end
    before = snapshot()
end

local function workflow()
    seed()
    if case == "interrupted" then
        local job = account.store:getJob("retained-download")
        job.payload.source_refresh = { id = "interrupted-marker", stage = "verifying", checked = 1, total = 2 }
        account.store:putJob(job)
        local temporary = account.pages.temporary_root .. "/source-proof-interrupted.part"
        Files.write(temporary, fixture(1):sub(1, 23))
        local root = app.root
        app:close()
        app = Controller.new{ root = root, ui_manager = UIManager, runner_factory = runnerFactory,
            network = { isConnected = function() return true end } }
        account = app.account
        check("recovery records an interrupted refresh explicitly", account.store:getJob("retained-download").error.kind == "source_refresh_interrupted")
        oldSnapshotPreserved()
        check("recovery starts no source or image worker", #report.submitted == 1)
        return
    end
    local injected_failures = 0
    if case == "final_update_failure" then
        local update = account.downloads._update
        account.downloads._update = function(self, job)
            if injected_failures == 0 and job.id == "retained-download" and not (job.payload or {}).source_refresh
                and page(1).extra.source_generation == 1 then
                injected_failures = injected_failures + 1
                account.store.connection:exec("PRAGMA query_only=ON")
                local ok, failure = pcall(update, self, job)
                account.store.connection:exec("PRAGMA query_only=OFF")
                assert(not ok, "The real SQLite write should fail in query-only mode")
                error(failure, 0)
            end
            return update(self, job)
        end
    elseif case == "resume_throw" then
        account.downloads.resume = function()
            injected_failures = injected_failures + 1
            error("Synthetic post-adoption resume failure")
        end
    end
    response, response_error, completed = nil, nil, false
    app:refreshDownloadSources("retained-download", function(value, err)
        refresh_callbacks = refresh_callbacks + 1
        response, response_error, completed = value, err, true
    end)
    if guarded_cases[case] then
        await(function() return Files.exists(work .. "/blocked.json") end, "a real proof child blocks at CDN")
        check("proof leaves a real candidate while the UI keeps ticking", candidateCount() == 1 and pulse > 3)
        local initial_starts = #report.starts
        if case == "unpinned_inflight" then
            local eviction = account.pages:evictToLimit(0)
            check("an unpinned proof has a transient eviction lease", not account.store:isPinned("101", "R1")
                and account.pages.source_refresh_locks["101/R1"] ~= nil and eviction.removed_pages == 0
                and eviction.protected_over_limit and page(1).state == "ready")
            app:cancelSourceRefresh("retained-download")
        elseif case == "cancel" then
            check("explicit cancellation finds the active operation", app:cancelSourceRefresh("retained-download"))
            check("repeated cancellation is inert", not app:cancelSourceRefresh("retained-download"))
        elseif case == "suspend" then
            app:suspend()
        elseif case == "account_close" then
            local root = app.root
            app:close()
            app = Controller.new{ root = root, ui_manager = UIManager, runner_factory = runnerFactory,
                network = { isConnected = function() return true end } }
            account = app.account
        elseif case == "preempt" then
            local urgent_done
            app.runner:submit({ kind = "client", method = "validateSession", session = account.session:serialize() },
                { priority = 0, resource = "image" }, function(value, err) urgent_done = value and not err end)
            await(function() return urgent_done end, "a higher priority safe task preempts the proof")
            check("the urgent safe worker finishes before proof publication", not completed and page(1).extra.source_generation == nil)
            Files.write(work .. "/release", "released")
        end
        if case ~= "preempt" then
            await(function()
                for _, runner in ipairs(runners) do if next(runner.tasks) then return false end end
                return true
            end, "canceled children are reaped")
            check("cancellation does not leave tasks queued for replay", idle())
            if case == "suspend" then
                Files.write(work .. "/release", "released")
                app:resume()
                local until_time = socket.gettime() + 0.2
                await(function() return socket.gettime() > until_time end, "a resumed UI settles")
                check("resume never replays the canceled source proof", #report.starts == initial_starts)
            end
            oldSnapshotPreserved()
            check("cancellation never publishes source mappings", not response)
            check("the public completion respects account lifetime", case == "account_close" and refresh_callbacks == 0
                or case ~= "account_close" and refresh_callbacks == 1 and response_error and response_error.kind == "canceled")
            if case == "unpinned_inflight" then
                check("cancel releases its eviction lease without adding a pin", not account.pages.source_refresh_locks["101/R1"]
                    and not account.store:isPinned("101", "R1"))
                local eviction = account.pages:evictToLimit(0)
                check("automatic eviction works again after cancellation", eviction.removed_pages == 1 and page(1).state == "missing")
            end
            return
        end
    end
    await(function() return completed end, "refresh completion")
    check("the refresh callback runs exactly once", refresh_callbacks == 1)
    if case == "final_update_failure" or case == "resume_throw" then
        await(idle, "terminal failure children settle")
        check("the targeted storage fault is reported once", injected_failures == 1 and response_error and response_error.kind == "storage")
        check("post-adoption identity and content are preserved", page(1).extra.source_generation == 1
            and Files.read(descriptor_path, 4194304) == before.descriptor and same(account.store:getAnchor("101", "R1"), before.anchor)
            and Files.digest(page(1).path) == before.ready_digest and account.store:getEpisode("101").extra.current_revision == "R1")
        check("terminal failures release the operation and eviction lease", not account.downloads:isRefreshingSources("101", "R1")
            and not account.pages.source_refresh_locks["101/R1"] and candidateCount() == 0)
        check("a terminal failure never auto-downloads missing pages", page(2).state == "missing" and page(3).state == "missing"
            and account.store:getJob("retained-download").state == "paused")
        if case == "final_update_failure" then
            check("failed terminal persistence suppresses automatic resume", response == nil)
            check("the failed write leaves its recoverable persisted marker", account.store:getJob("retained-download").payload.source_refresh ~= nil)
            account.downloads:recover()
            check("recovery clears the failed completion marker", not account.store:getJob("retained-download").payload.source_refresh)
        else
            check("resume failure preserves the adopted summary", response and response.verified_pages == 2)
            check("the adopted operation has no unfinished marker", not account.store:getJob("retained-download").payload.source_refresh)
        end
        return
    end
    if case == "success" or case == "preempt" then
        check("refresh publishes after exactly the two historical proofs", response and not response_error and response.verified_pages == 2)
        check("the real Client normalized a new index with rotated paths and IDs", report.normalized_index_rotates_all_identifiers)
        await(function()
            local job = account.store:getJob("retained-download")
            assert(job.state ~= "failed", "Automatic resume failed: " .. tostring(job.error and job.error.kind))
            return job.state == "complete"
        end, "automatic missing-page download")
        check("all three pages are complete and pinned", account.pages:isComplete("101", "R1") and account.store:isPinned("101", "R1"))
        check("the descriptor bytes, path and sole version are preserved", Files.read(descriptor_path, 4194304) == before.descriptor
            and same(account.store:listDescriptors(), before.descriptors) and #account.store:listDescriptors() == 1)
        check("anchor and the ready reference file are preserved", same(account.store:getAnchor("101", "R1"), before.anchor)
            and page(1).path == before.ready_path and Files.digest(page(1).path) == before.ready_digest
            and SourceRefresh.sameFileIdentity(SourceRefresh.fileIdentity(page(1).path, account.pages.pages_root), before.ready_identity))
        check("current_revision remains the immutable R1", account.store:getEpisode("101").extra.current_revision == "R1")
        local proofs, downloads = {}, {}
        for _, item in ipairs(report.submitted) do
            if item.kind == "verify_source_page" then proofs[#proofs + 1] = item
            elseif item.kind == "download_page" then downloads[#downloads + 1] = item end
        end
        check("only A and historical B are verified", #proofs == 2 and proofs[1].index == 1 and proofs[1].reference
            and proofs[2].index == 2 and not proofs[2].reference)
        check("only missing B and C download using fresh paths", #downloads == 2 and downloads[1].index == 2
            and downloads[1].source_path == "/synthetic/new-2" and downloads[2].index == 3 and downloads[2].source_path == "/synthetic/new-3")
        for i = 1, 3 do
            check("source epoch advances once while immutable page ID stays stable " .. i,
                page(i).extra.source_generation == 1 and page(i).id == "original-" .. i
                and page(i).extra.source_path == "/synthetic/new-" .. i and Files.digest(page(i).path) == Files.digest(work .. "/fixture-" .. i .. ".png"))
        end
        check("all proof candidates and marker are removed", candidateCount() == 0
            and not account.store:getJob("retained-download").payload.source_refresh)
        if case == "preempt" then
            local attempts = {}
            for _, item in ipairs(report.starts) do
                if item.kind == "verify_source_page" and item.index == 1 then attempts[#attempts + 1] = item end
            end
            check("the same proof task replays its partial in a different real child", #attempts == 2
                and attempts[1].task_id == attempts[2].task_id and attempts[1].pid ~= attempts[2].pid
                and attempts[2].attempt == 2)
        end
    else
        local expected = ({ changed_bytes = "content_changed", topology = "content_changed", legacy_unknown = "unknown_history",
            native_positions = "unverified_position", unpinned_preflight = "unknown_history" })[case]
        check("the rejected refresh reports its precise error", not response and response_error and response_error.kind == expected)
        await(idle, "failed operation workers finish")
        oldSnapshotPreserved()
        local expected_proofs = case == "changed_bytes" and 2 or 0
        local n = 0
        for _, item in ipairs(report.submitted) do if item.kind == "verify_source_page" then n = n + 1 end end
        check("only the necessary proof workers ran", n == expected_proofs)
    end
end

Files.mkdir(work .. "/audit")
local task = coroutine.create(workflow)
local stopped = false
local function poll()
    pulse = pulse + 1
    local ok, err = coroutine.resume(task)
    if not ok or coroutine.status(task) == "dead" then
        report.passed, report.error = ok, not ok and tostring(err) or nil
        if app then
            local closed, close_error = pcall(app.close, app)
            report.close_succeeded = closed
            if not closed then report.passed, report.error = false, tostring(close_error) end
        end
        report.all_children_reaped = idle()
        if not report.all_children_reaped then report.passed = false end
        report.all_worker_pids_terminal = true
        for _, item in ipairs(report.starts) do
            if not item.pid or item.pid == parent_pid then report.passed = false end
            if item.pid and ffi.C.kill(item.pid, 0) == 0 then report.all_worker_pids_terminal, report.passed = false, false end
        end
        report.ui_ticks, report.worker_starts = pulse, #report.starts
        write(work .. "/results.json", report)
        stopped = true
        UIManager:quit()
        return
    end
    UIManager:scheduleIn(0.01, poll)
end
UIManager:show(require("ui/widget/infomessage"):new{ text = "Synthetic source refresh workflow" })
UIManager:scheduleIn(0.01, poll)
local ok, failure = xpcall(function() UIManager:run() end, debug.traceback)
if not ok or not stopped then
    if app then pcall(app.close, app) end
    report.passed, report.error = false, tostring(failure or "Unexpected UI loop termination")
    write(work .. "/results.json", report)
end
print(json.encode({ case = case, passed = report.passed, checks = #report.assertions, error = report.error }))
if not report.passed then os.exit(1) end
