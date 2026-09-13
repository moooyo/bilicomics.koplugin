-- Run only on test-env in an isolated network namespace with synthetic free chapters.
-- Application, storage, native reader and worker layers remain production code.
require("setupkoenv")
local source, work, case = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local lfs = require("libs/libkoreader-lfs")
local disabled = {}
for name in lfs.dir("plugins") do local key = name:match("^(.*)%.koplugin$"); if key then disabled[key] = true end end
G_reader_settings:saveSetting("plugins_disabled", disabled)
G_reader_settings:saveSetting("color_rendering", false)
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local Files = require("bilicomics/storage/files")
local Codec = require("bilicomics/storage/codec")
local SourceRefresh = require("bilicomics/storage/source_refresh")
local JSON = require("bilicomics/protocol/json")
local json = require("rapidjson")
local ffi = require("ffi")
local socket = require("socket")
local Controller = require("bilicomics/controller")
local Runner = require("bilicomics/jobs/runner")
local Transport = require("bilicomics/protocol/transport")
local Provider = require("bilicomics/reader/document")
local provider_init = Provider.init
function Provider:init()
    provider_init(self)
    self._observed_native_decodes = 0
    local backend = self._document
    local open = backend.openPage
    backend.openPage = function(owner, index)
        local native = open(owner, index)
        self._observed_native_decodes = self._observed_native_decodes + 1
        return native
    end
end
local parent_pid = tonumber(ffi.C.getpid())
local report = { case = case, assertions = {}, starts = {}, submitted = {}, passed = false,
    scope = "Production Controller, coordinator, SQLite, PageStore, replacement publication, default Worker, Client, fork/IPC and native ReaderUI; synthetic free transport only" }
local app, account, descriptor, descriptor_path, before, old_revision
local response, response_error, completed, callbacks, pulse = nil, nil, false, 0, 0
local runners, process_records = {}, {}
local old_pin_promoted = false
local guarded = { cancel = true, suspend = true, account_close = true, account_switch = true, stale_index = true, stale_basis = true,
    mutual_exclusion = true, unpinned_cancel = true, unpinned_success = true }
local function write(path, value) Files.write(path, json.encode(value, { pretty = true })) end
local function check(name, condition)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition }
    assert(condition, name)
end
local function same(a, b) return Codec.canonical(a) == Codec.canonical(b) end
local function await(predicate, label, timeout)
    local deadline = socket.gettime() + (timeout or 15)
    while not predicate() do assert(socket.gettime() < deadline, "Timed out: " .. label); coroutine.yield() end
end
local function settle()
    local until_time = socket.gettime() + 0.12
    await(function() return socket.gettime() > until_time end, "UI callbacks settle")
end
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
local function idle()
    for _, runner in ipairs(runners) do if next(runner.tasks) or #runner.queue > 0 then return false end end
    return true
end
local function fixture(index) return Files.read(work .. "/fixture-" .. index .. ".png", 65536) end
local function page(index, revision) return assert(account.store:getPage("101/" .. (revision or old_revision) .. "/" .. index)) end
local function paths()
    local result = {}
    for i = 1, (case == "topology" and 4 or 3) do result[i] = "/synthetic/source-" .. i end
    return result
end
local function normalizedRevision()
    local parts = {}
    for i, path in ipairs(paths()) do parts[i] = require("ffi/sha2").sha256(path) .. ":40:80" end
    return require("ffi/sha2").sha256(table.concat(parts, "\n"))
end
local function nativePositions(path)
    local positions = require("docsettings"):open(path):readSetting("page_positions", {})
    local encoded = {}
    for key, value in pairs(positions) do encoded[type(key) .. ":" .. tostring(key)] = value end
    return encoded
end
local function snapshot()
    return { pages = account.store:listPages("101", old_revision), descriptor = Files.read(descriptor_path, 4194304),
        anchor = account.store:getAnchor("101", old_revision), pinned = account.store:isPinned("101", old_revision),
        ready_path = page(1).path, ready_digest = Files.digest(page(1).path),
        ready_identity = SourceRefresh.fileIdentity(page(1).path, account.pages.pages_root),
        native_positions = nativePositions(descriptor_path) }
end
local function preserved()
    local expected = Codec.copy(before)
    if old_pin_promoted then expected.pinned = true end
    check("old page records, ready bytes and identity, descriptor, native positions, anchor and pin survive", same(snapshot(), expected))
end
local function noPublication()
    preserved()
    check("no new local descriptor or download job is published", #account.store:listDescriptors() == 1
        and #account.store:listJobs() == 2)
    check("the catalog still selects the retained revision", account.store:getEpisode("101").extra.current_revision == old_revision)
    local job = account.store:getJob("retained-download")
    check("the old job remains paused without replacement marker", job.state == "paused"
        and not (job.payload or {}).version_replacement and not (job.payload or {}).replaced_by)
    check("no pending commit remains", #account.store:listCommits() == 0)
    check("terminal preparation releases the operation and temporary eviction lease", not account.downloads:isReplacingVersion("101")
        and not (account.pages.version_replacement_locks or {})["101/" .. old_revision])
end

local wire_sequence = 0
Transport.request = function(_, wire)
    assert(tonumber(ffi.C.getpid()) ~= parent_pid, "Transport escaped the default forked worker")
    local route = wire.url:match("^https://manga%.bilibili%.com/twirp/comic%.v1%.Comic/(%w+)%?")
    local endpoint, index
    if wire.url == "https://api.bilibili.com/x/web-interface/nav" then
        assert(wire.method == "GET"); endpoint = "nav"
    elseif route then
        assert(wire.method == "POST")
        local body = assert(JSON.decode(wire.body)); endpoint = route
        if route == "ComicDetail" then assert(body.comic_id == 81)
        elseif route == "GetImageIndex" then assert(body.ep_id == 101)
        elseif route == "ImageToken" then
            local supplied = assert(JSON.decode(body.urls))
            assert(#supplied == 1 and type(body.m1) == "string")
            index = tonumber(supplied[1]:match("^/synthetic/source%-([1234])$"))
            if case == "binding" then index = index or tonumber(supplied[1]:match("^/synthetic/old%-([123])$")) end
            assert(index, "An unapproved source reached token acquisition")
        else error("Only the explicit read API allowlist is permitted") end
    else
        index = tonumber(wire.url:match("^https://i0%.hdslb%.com/version%-([1234])%.png%?token=synthetic&code=DanmakuInfo$"))
        assert(index and wire.method == "GET" and type(wire.output_path) == "string", "Unapproved transport operation")
        assert(Files.within(wire.output_path, work), "Image output escaped the fresh work directory")
        for name in pairs(wire.headers or {}) do assert(name:lower() ~= "cookie" and name:lower() ~= "authorization") end
        endpoint = "CDN"
    end
    wire_sequence = wire_sequence + 1
    write(work .. "/audit/" .. ffi.C.getpid() .. "-" .. wire_sequence .. ".json", {
        child_pid = tonumber(ffi.C.getpid()), endpoint = endpoint, index = index })
    if endpoint == "nav" then
        if Files.exists(work .. "/switch-account") then
            return { status = 200, body = '{"code":0,"data":{"isLogin":true,"mid":84,"uname":"Second synthetic local account"}}' }
        end
        return { status = 200, body = '{"code":0,"data":{"isLogin":true,"mid":42,"uname":"Synthetic free chapter"}}' }
    elseif endpoint == "ComicDetail" then
        local episodes = case == "fresh_access" and {} or { { id = 101, comic_id = 81, ord = 1,
            title = "Synthetic free chapter", pay_mode = 0, is_locked = false, unlock_type = 0 } }
        return { status = 200, body = assert(JSON.encode({ code = 0, data = { id = 81,
            title = "Synthetic version replacement", ep_list = episodes } })) }
    elseif endpoint == "GetImageIndex" then
        if guarded[case] then
            write(work .. "/blocked.json", { pid = tonumber(ffi.C.getpid()) })
            local deadline = socket.gettime() + 25
            while not Files.exists(work .. "/release") do
                assert(socket.gettime() < deadline, "The bounded index gate was not released"); socket.sleep(0.01)
            end
        end
        if case == "fresh_index" then return { status = 200, body = '{"code":0,"data":{"images":[]}}' } end
        local images = {}
        for i, path in ipairs(paths()) do images[i] = { path = path, x = 40, y = 80 } end
        return { status = 200, body = assert(JSON.encode({ code = 0, data = { images = images } })) }
    elseif endpoint == "ImageToken" then
        return { status = 200, body = '{"code":0,"data":[{"complete_url":"https://i0.hdslb.com/version-'
            .. index .. '.png?token=synthetic","hit_encrpyt":false}]}' }
    end
    Files.write(wire.output_path, fixture(index))
    return { status = 200, headers = { ["content-type"] = "image/png" } }
end

local function runnerFactory(options)
    options.max_workers = 1
    local runner = Runner.new(options); runners[#runners + 1] = runner
    local submit, start = runner.submit, runner._start
    runner.submit = function(self, request, settings, callback)
        assert(request.kind == "source_index" or request.kind == "download_page"
            or (request.kind == "client" and (request.method == "validateSession" or case == "unbound" and request.method == "imageIndex")),
            "An unapproved worker kind was dispatched")
        report.submitted[#report.submitted + 1] = { kind = request.kind, method = request.method,
            index = request.index, source_path = request.source_path }
        return submit(self, request, settings, function(value, err)
            if request.kind == "source_index" and value then report.normalized_revision = value.index.revision end
            if callback then callback(value, err) end
        end)
    end
    runner._start = function(self, task)
        start(self, task); recordProcess(task.pid)
        report.starts[#report.starts + 1] = { kind = task.request.kind, index = task.request.index,
            attempt = task.attempt, pid = task.pid, task_id = task.id }
    end
    return runner
end
local function controller(root)
    local value = Controller.new{ root = root, ui_manager = UIManager, runner_factory = runnerFactory,
        network = { isConnected = function() return true end } }
    value.settings:set("prefetch", false); value.settings:set("reading_mode", "page")
    value.settings:set("next_episode_pages", 0)
    return value
end
local function seed()
    app = controller(work .. "/plugin")
    app:importSession("SESSDATA=synthetic-only; DedeUserID=42; bili_jct=synthetic-csrf", function(value, err)
        response, response_error, completed = value, err, true
    end)
    await(function() return completed end, "synthetic session validation")
    check("session validation uses a real read-only child", response and not response_error)
    account = app.account
    account.store:upsertComic{ id = "81", title = "Synthetic version replacement" }
    old_revision = case == "same_identity" and normalizedRevision() or "R1"
    account.store:upsertEpisodes("81", { { id = "101", title = "Synthetic free chapter", order = 1, access = "free",
        extra = case == "unbound" and {} or { current_revision = old_revision, local_revision = old_revision,
            progress_source = "local", local_finished_at = 1234 } } })
    if case == "unbound" then return end
    descriptor = { schema_version = 1, account_key = account.key, comic_id = "81", episode_id = "101", revision = old_revision, pages = {} }
    for i = 1, 3 do descriptor.pages[i] = { id = case == "same_identity" and require("ffi/sha2").sha256(paths()[i])
        or "old-page-" .. i, index = i, width = 40, height = 80 } end
    descriptor_path = account.pages:ensureDescriptor(descriptor)
    for i = 1, 3 do
        local record = page(i)
        record.extra.source_path = case == "same_identity" and paths()[i] or "/synthetic/old-" .. i
        if i == 3 and case == "success" then record.extra.source_path = nil end
        record.extra.content_history_version = nil
        account.store:putPage(record)
    end
    local temporary = account.pages.temporary_root .. "/seed.part"
    Files.write(temporary, fixture(4))
    account.pages:commitPage({ account_key = account.key, episode_id = "101", revision = old_revision, index = 1,
        id = page(1).id, expected_content_generation = 0, expected_source_generation = 0 },
        { temporary_path = temporary, checksum = Files.digest(temporary), width = 40, height = 80, format = "png",
            geometry = { source_width = 40, source_height = 80, exif_orientation = 1 } })
    account.pages:pinEpisode("101", old_revision, true)
    account.catalog:updatePosition(descriptor, { schema_version = 1, page_id = descriptor.pages[1].id, index = 1,
        x = 0, y = 0.125, source = { x = 0, y = 0.125 }, rotation = 0, mode = "page", zoom_mode = "pagewidth",
        zoom_ratio = 1, geometry_generation = page(1).geometry_generation, finished = true })
    for _, job_id in ipairs({ "retained-download", "duplicate-download" }) do
        account.store:putJob{ id = job_id, kind = "episode_download", state = "paused", comic_id = "81",
            episode_id = "101", revision = old_revision, run_generation = 4, completed = 1, total = 3, payload = {} }
    end
    local native = require("docsettings"):open(descriptor_path)
    native:saveSetting("page_positions", { [3] = 0.33 }); native:flush()
    if case == "unpinned_cancel" or case == "unpinned_success" or case == "database_failure" then
        account.pages:pinEpisode("101", old_revision, false)
    end
    check("fixture has unknown legacy missing history and retained native progress", page(3).extra.content_history_version == nil
        and nativePositions(descriptor_path)["number:3"] == 0.33)
    before = snapshot()
end
local function waitComplete(job_id)
    await(function()
        local job = account.store:getJob(job_id)
        assert(job.state ~= "failed", "Download failed: " .. tostring(job.error and job.error.kind))
        return job.state == "complete"
    end, "automatic missing-page download")
    await(idle, "all download children finish")
end
local function readExact(job_id, expected, direct)
    local ReaderUI = require("apps/reader/readerui")
    -- Clear only this isolated reader's render cache to observe a real decode on every open.
    local render_cache = require("document/doccache")
    render_cache:clear(); render_cache:clearDiskCache()
    local path = select(2, account.store:getDescriptor("101", expected))
    local opened, failure
    if direct then
        ReaderUI:showReader(path, Provider, nil, true, function(reader)
            local integration, err = app:attachReader(reader)
            opened, failure = integration, err
        end)
    else app:readDownload(job_id, function(value, err) opened, failure = value, err end) end
    await(function() return opened or failure end, "native exact-version open")
    check("native exact-version open succeeds " .. expected, opened and not failure)
    local reader = ReaderUI.instance
    check("ReaderUI uses the exact persisted descriptor " .. expected, reader and reader.document.file == path
        and reader.document.descriptor.revision == expected and reader.bilicomics_integration ~= nil)
    settle()
    reader.paging:onGotoPage(1)
    reader:paintTo(Device.screen.bb, 0, 0)
    check("native reader renders the cached first page " .. expected, next(reader.document._render_errors) == nil
        and reader.document._observed_native_decodes > 0)
    return reader
end
local function readAndRemove(newjob, newdescriptor)
    local new_revision = newdescriptor.revision
    local starts = #report.starts
    local root = app.root
    app:close(); app = controller(root); account = app.account
    local prepare, prepare_calls = app.prepareEpisode, 0
    app.prepareEpisode = function(self, ...) prepare_calls = prepare_calls + 1; return prepare(self, ...) end
    check("Controller reconstruction preserves both exact descriptors", account.store:getDescriptor("101", old_revision)
        and account.store:getDescriptor("101", new_revision))
    local episode_before = Codec.copy(account.store:getEpisode("101"))
    local comic_before = Codec.copy(account.store:getComic("81"))
    app.network.isConnected = function() return false end
    local old_reader = readExact("retained-download", old_revision)
    app.network.isConnected = function() return true end
    old_reader.document:requestPage(3, true)
    local callback_done, callback_error
    account.downloads:requestPage(descriptor, 3, {}, function(_, err) callback_done, callback_error = true, err end)
    await(function() return callback_done end, "retired missing page rejection")
    check("retired missing page reports cache-only status", callback_error and callback_error.kind == "version_replaced")
    local anchor = Codec.copy(before.anchor); anchor.y = 0.6; anchor.finished = true
    app:_readerEvent("position", { descriptor = descriptor, anchor = anchor, reader_generation = old_reader.bilicomics_integration.generation })
    check("reading the retained version changes only its own anchor", same(account.store:getEpisode("101"), episode_before)
        and same(account.store:getComic("81"), comic_before) and account.store:getAnchor("101", old_revision).y == 0.6)
    old_reader:onClose(); settle()
    local direct_reader = readExact("retained-download", old_revision, true)
    direct_reader.document:requestPage(3, true); direct_reader:onClose(); settle()
    check("native direct reopen and retired missing pages dispatch no workers or global preparation", #report.starts == starts
        and prepare_calls == 0 and idle())
    app.network.isConnected = function() return false end
    local new_reader = readExact(newjob.id, new_revision)
    local captured = require("bilicomics/reader/anchors").capture(new_reader)
    check("new native position belongs only to the new descriptor", captured and captured.page_id == newdescriptor.pages[1].id
        and captured.index == 1 and captured.finished ~= true)
    new_reader:onClose(); settle()
    local new_anchor = Codec.copy(account.store:getAnchor("101", new_revision)); new_anchor.finished = true
    account.catalog:updatePosition(newdescriptor, new_anchor)
    check("new version progress is reported independently", account.catalog:getEpisodes("81")[1].read == "complete"
        and account.store:getEpisode("101").extra.current_revision == new_revision)
    local new_page = page(1, new_revision)
    local new_identity = SourceRefresh.fileIdentity(new_page.path, account.pages.pages_root)
    local removed, err
    app:removeDownload("duplicate-download", function(value, failure) removed, err = value, failure end)
    check("old version removal succeeds", removed and not err)
    check("removing either old row retires every duplicate row", account.store:getJob("retained-download").payload.removed
        and account.store:getJob("duplicate-download").payload.removed)
    check("old removal preserves new image file, pin and anchor", account.store:isPinned("101", new_revision)
        and Files.exists(new_page.path) and SourceRefresh.sameFileIdentity(new_identity,
            SourceRefresh.fileIdentity(new_page.path, account.pages.pages_root)) and account.store:getAnchor("101", new_revision).finished)
    check("old removal retains the old descriptor and anchor but removes its image and pin", Files.exists(descriptor_path)
        and account.store:getAnchor("101", old_revision) and not account.store:isPinned("101", old_revision)
        and page(1).state == "missing" and not Files.exists(before.ready_path))
    removed, err = nil, nil
    app:removeDownload(newjob.id, function(value, failure) removed, err = value, failure end)
    check("new version can be removed independently", removed and not err and account.store:getJob(newjob.id).payload.removed
        and not account.store:isPinned("101", new_revision) and not Files.exists(new_page.path))
    check("removal never acquires remote content", #report.starts == starts and idle())
end

local function workflow()
    ffi.cdef[[long readlink(const char *path, char *buf, unsigned long bufsiz);]]
    local buffer = ffi.new("char[128]")
    local length = ffi.C.readlink("/proc/self/ns/net", buffer, 128)
    check("the scenario runs in a distinct network namespace", length > 0
        and ffi.string(buffer, length) ~= assert(os.getenv("BILI_PARENT_NETNS")))
    seed()
    if case == "unbound" then
        local prepare, calls = app.prepareEpisode, 0
        app.prepareEpisode = function(self, ...) calls = calls + 1; return prepare(self, ...) end
        local jobs, failure
        app:downloadEpisodes("81", { "101" }, function(value, err) jobs, failure = value, err end)
        check("first unbound enqueue succeeds", jobs and #jobs == 1 and not failure)
        waitComplete(jobs[1].id)
        check("the first unbound job uses real preparation and binds its fetched index", calls == 1
            and account.store:getJob(jobs[1].id).revision == normalizedRevision()
            and account.pages:isComplete("101", normalizedRevision()))
        return
    elseif case == "binding" then
        local other = Codec.copy(descriptor); other.revision = "catalog-other"
        account.pages:ensureDescriptor(other)
        local episode = account.store:getEpisode("101"); episode.extra.current_revision = other.revision
        account.store:upsertEpisodes("81", { episode })
        local prepare, calls = app.prepareEpisode, 0
        app.prepareEpisode = function(self, ...) calls = calls + 1; return prepare(self, ...) end
        check("an ordinary bound job resumes", app:resumeJob("retained-download"))
        waitComplete("retained-download")
        check("bound resume uses its own descriptor without catalog preparation", calls == 0
            and account.store:getJob("retained-download").revision == old_revision
            and account.pages:isComplete("101", old_revision) and not account.pages:isComplete("101", other.revision))
        return
    elseif case == "interrupted" then
        local job = account.store:getJob("retained-download")
        job.payload.version_replacement = { id = "interrupted-fixture", stage = "index" }; account.store:putJob(job)
        local starts, root = #report.starts, app.root
        app:close(); app = controller(root); account = app.account
        noPublication()
        check("recovery explicitly clears an interrupted marker without replay", account.store:getJob(job.id).error.kind == "version_replacement_interrupted"
            and #report.starts == starts and idle())
        return
    end
    local injected, original_resume = 0, account.downloads.resume
    if case == "database_failure" then
        local put = account.store.putJob
        account.store.putJob = function(self, job)
            if injected == 0 and (job.payload or {}).replaces_job_id then
                injected = injected + 1; self.connection:exec("PRAGMA query_only=ON")
                local ok, failure = pcall(put, self, job)
                self.connection:exec("PRAGMA query_only=OFF")
                assert(not ok, "Real SQLite must reject the new job write"); error(failure, 0)
            end
            return put(self, job)
        end
    elseif case == "resume_throw" then
        account.downloads.resume = function(self, job_id)
            if job_id ~= "retained-download" and job_id ~= "duplicate-download" then
                injected = injected + 1; error("Synthetic post-publication resume failure")
            end
            return original_resume(self, job_id)
        end
    end
    response, response_error, completed, callbacks = nil, nil, false, 0
    app:replaceDownloadVersion("retained-download", function(value, err)
        callbacks = callbacks + 1; response, response_error, completed = value, err, true
    end)
    if guarded[case] then
        await(function() return Files.exists(work .. "/blocked.json") end, "real index child blocks")
        local starts = #report.starts
        local marker = account.store:getJob("retained-download").payload.version_replacement
        check("index preparation has a durable visible marker and responsive UI", marker and marker.stage == "index"
            and type(marker.id) == "string" and pulse > 3)
        if case == "unpinned_cancel" or case == "unpinned_success" then
            local cleared, err = app:clearAutomaticCache()
            check("un-pinned retained images have a temporary lease while the fresh index waits", cleared and not err
                and cleared.removed_pages == 0 and cleared.protected_over_limit and page(1).state == "ready"
                and not account.store:isPinned("101", old_revision)
                and (account.pages.version_replacement_locks or {})["101/" .. old_revision] ~= nil)
            if case == "unpinned_cancel" then app:cancelVersionReplacement("retained-download")
            else Files.write(work .. "/release", "released") end
        elseif case == "cancel" then
            check("explicit cancellation terminates the active replacement", app:cancelVersionReplacement("retained-download"))
            check("second cancellation has no effect", not app:cancelVersionReplacement("retained-download"))
        elseif case == "suspend" then app:suspend()
        elseif case == "account_close" then
            local root = app.root; app:close(); app = controller(root); account = app.account
        elseif case == "account_switch" then
            local old_key, old_session = account.key, account.session
            local switched, switch_error
            Files.write(work .. "/switch-account", "second synthetic account")
            app:importSession("SESSDATA=synthetic-only-second; DedeUserID=84; bili_jct=synthetic-csrf-second", function(value, err)
                switched, switch_error = value, err
            end)
            await(function() return switched or switch_error end, "second synthetic session validation")
            check("public synthetic account switch succeeds without publishing into the new store", switched and not switch_error
                and app.account.key ~= old_key and #app.account.store:listJobs() == 0 and #app.account.store:listDescriptors() == 0)
            app:_closeAccount(); app:_openAccount(old_key, old_session); account = app.account
        elseif case == "stale_index" then
            local job = account.store:getJob("retained-download"); job.run_generation = job.run_generation + 1
            account.store:putJob(job); Files.write(work .. "/release", "released")
        elseif case == "stale_basis" then
            local anchor = account.store:getAnchor("101", old_revision); anchor.y = 0.5
            account.store:putAnchor("101", old_revision, anchor); before = snapshot()
            Files.write(work .. "/release", "released")
        elseif case == "mutual_exclusion" then
            local conflict, conflict_error
            app:refreshDownloadSources("duplicate-download", function(value, err) conflict, conflict_error = value, err end)
            await(function() return conflict_error ~= nil end, "source-refresh conflict")
            check("source refresh cannot run during replacement", not conflict and conflict_error.kind == "busy" and #report.starts == starts)
            app:cancelVersionReplacement("retained-download")
        end
        if case ~= "unpinned_success" then
            await(idle, "the canceled or completed index child is reaped")
            if case == "suspend" then
                Files.write(work .. "/release", "released"); app:resume(); settle()
                check("resume does not replay canceled index preparation", #report.starts == starts and idle())
            end
            noPublication()
            local expected = case == "stale_basis" and "stale_version_replacement" or "canceled"
            check("the cancellation callback respects lifetime and runs once", callbacks == 1 and not response
                and response_error and response_error.kind == expected)
            if case == "unpinned_cancel" then
                local cleared = app:clearAutomaticCache()
                check("cancellation restores automatic eviction without adding a pin", cleared.removed_pages == 1
                    and page(1).state == "missing" and not account.store:isPinned("101", old_revision))
            end
            return
        end
    end
    await(function() return completed end, "replacement publication")
    check("replacement completes exactly one callback", callbacks == 1)
    if case == "fresh_access" or case == "fresh_index" or case == "database_failure" then
        await(idle, "failed worker settles"); noPublication()
        local expected = ({ fresh_access = "entitlement", fresh_index = "protocol", database_failure = "storage" })[case]
        check("fresh access, index or database failure is reported precisely", not response and response_error and response_error.kind == expected)
        if case == "database_failure" then check("the failure came from the real SQLite new-job write", injected == 1) end
        check("failed preparation submits no image worker", #report.starts == 2)
        return
    end
    check("a fresh independent snapshot is published", response and response.job and response.descriptor
        and response.job.id ~= "retained-download" and response.descriptor.revision ~= old_revision
        and response.path ~= descriptor_path)
    local newjob, newdescriptor = response.job, response.descriptor
    local new_revision = newdescriptor.revision
    old_pin_promoted = case == "unpinned_success"
    preserved()
    check("publication releases its temporary eviction lease", not account.downloads:isReplacingVersion("101")
        and not (account.pages.version_replacement_locks or {})["101/" .. old_revision])
    check("both retained duplicate jobs are retired toward the new job", account.store:getJob("retained-download").state == "canceled"
        and account.store:getJob("duplicate-download").state == "canceled"
        and account.store:getJob("retained-download").payload.replaced_by == newjob.id
        and account.store:getJob("duplicate-download").payload.replaced_by == newjob.id)
    check("the new job links its selected predecessor and owns its own pin", newjob.payload.replaces_job_id == "retained-download"
        and account.store:isPinned("101", old_revision) and account.store:isPinned("101", new_revision))
    local extra = account.store:getEpisode("101").extra
    check("catalog identity and local progress reset to the new snapshot", extra.current_revision == new_revision
        and extra.local_revision == new_revision and extra.source_replacement_revision == new_revision
        and extra.progress_source == "local" and not extra.local_finished_at
        and account.store:getEpisode("101").read == false and account.catalog:getEpisodes("81")[1].read == false)
    check("no old anchor or native page positions are copied to the new version", account.store:getAnchor("101", new_revision) == nil
        and next(nativePositions(response.path)) == nil)
    check("retired jobs cannot resume acquisition", app:resumeJob("retained-download") == false)
    if case == "same_identity" then
        check("Client normalizes exactly the old opaque revision while local publication stays independent", report.normalized_revision == old_revision)
    end
    if case == "topology" then check("the new independent descriptor accepts changed page count", #newdescriptor.pages == 4) end
    if case == "resume_throw" then
        await(idle, "post-publication failure settles")
        check("post-publication resume exception returns value and error", injected == 1 and response_error and response_error.kind == "storage"
            and account.store:getJob(newjob.id).state == "paused" and #report.starts == 2)
        account.downloads.resume = original_resume
        check("the new job can be retried after resume failure", app:resumeJob(newjob.id))
    else check("publication resumes without an error", not response_error) end
    waitComplete(newjob.id)
    if case == "unpinned_success" then
        local cleared = app:clearAutomaticCache()
        check("successful publication pins old and new snapshots against automatic eviction", cleared.removed_pages == 0
            and account.store:isPinned("101", old_revision) and account.store:isPinned("101", new_revision))
    end
    check("all new pages are acquired even where old cached bytes exist", account.pages:isComplete("101", new_revision)
        and page(1, new_revision).path ~= before.ready_path and Files.digest(page(1, new_revision).path) == Files.digest(work .. "/fixture-1.png")
        and Files.digest(page(1, new_revision).path) ~= before.ready_digest)
    local downloads = 0
    for _, item in ipairs(report.submitted) do if item.kind == "download_page" then downloads = downloads + 1 end end
    check("only fresh source index and every new image are dispatched", downloads == #newdescriptor.pages and #report.starts == downloads + 2)
    preserved()
    if case == "success" then readAndRemove(newjob, newdescriptor) end
end

Files.mkdir(work .. "/audit")
local task, stopped = coroutine.create(workflow), false
local function poll()
    pulse = pulse + 1
    local ok, err = coroutine.resume(task)
    if not ok or coroutine.status(task) == "dead" then
        report.passed, report.error = ok, not ok and tostring(err) or nil
        if app then
            local closed, failure = pcall(app.close, app); report.close_succeeded = closed
            if not closed then report.passed, report.error = false, tostring(failure) end
        end
        report.all_children_reaped, report.all_worker_pids_terminal = idle(), true
        if not report.all_children_reaped then report.passed = false end
        for _, item in ipairs(report.starts) do
            if not item.pid or item.pid == parent_pid then report.passed = false end
            if item.pid and ffi.C.kill(item.pid, 0) == 0 then report.all_worker_pids_terminal, report.passed = false, false end
        end
        report.ui_ticks, report.worker_starts = pulse, #report.starts
        write(work .. "/results.json", report); stopped = true; UIManager:quit(); return
    end
    UIManager:scheduleIn(0.01, poll)
end
UIManager:show(require("ui/widget/infomessage"):new{ text = "Synthetic version replacement workflow" })
UIManager:scheduleIn(0.01, poll)
local ok, failure = xpcall(function() UIManager:run() end, debug.traceback)
if not ok or not stopped then
    if app then pcall(app.close, app) end
    report.passed, report.error = false, tostring(failure or "Unexpected UI termination")
    write(work .. "/results.json", report)
end
print(json.encode({ case = case, passed = report.passed, checks = #report.assertions, error = report.error }))
if not report.passed then os.exit(1) end
