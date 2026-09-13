-- Explicitly authorized single-chapter live read; execute only on remote test-env.
require("setupkoenv")
local source, work, phase = assert(arg[1]), assert(arg[2]), assert(arg[3])
assert(phase == "online" or phase == "offline")
if phase == "online" then assert(os.getenv("BILI_LIVE_AUTHORIZED") == "1", "Explicit live authorization is required") end
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local json = require("rapidjson")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")
local Files = require("bilicomics/storage/files")
local driver_root = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local Scope = assert(loadfile(driver_root .. "/live_acceptance_scope.lua"))()
local private = work .. "/private"
Files.mkdir(private)
local report = { checks = {}, counts = {}, dimensions = {} }
report.checks.all_network_requests_pass_readonly_guard = true
local parent_pid = tonumber(ffi.C.getpid())
local app, screens, Runtime, UIManager, reader, keeper
local stopped, closed_at, stage = false, nil, "setup"
local runners, submitted, prefetched = {}, {}, {}
local forbidden_attempts, starts_after_close, worker_starts = 0, 0, 0
local image_submission_attempts = 0
local submission_observation = {}
local initialized, opened_events = {}, {}
local session_copy, state
local checked_info
local maintenance_counts, library_counts = {}, {}
local visible_cover_urls = {}
local image_timing = { starts = 0, peak_processes = 0 }
require("ffi/posix_h")
local timespec = ffi.new("struct timespec")
function image_timing.now()
    if ffi.C.clock_gettime(ffi.C.CLOCK_MONOTONIC, timespec) ~= 0 then return nil end
    return tonumber(timespec.tv_sec) + tonumber(timespec.tv_nsec) / 1000000000
end
local function packed(...) return { n = select("#", ...), ... } end

local function check(name, condition)
    report.checks[name] = not not condition
    assert(condition, name)
end
local function write(path, value)
    Files.atomicWrite(path, json.encode(value))
end
local function read(path, maximum)
    return assert(json.decode(Files.read(path, maximum or 4 * 1024 * 1024)))
end
local function childRecord(pid)
    local input = io.open("/proc/" .. tostring(pid) .. "/stat", "rb")
    if not input then return end
    local raw = input:read("*a"); input:close()
    local values = {}
    for value in (raw:match("^%d+ %(.+%) (.*)$") or ""):gmatch("%S+") do values[#values + 1] = value end
    local pgid, starttime = tonumber(values[3]), tonumber(values[20])
    if not pgid or not starttime then return end
    local path = os.getenv("BILI_CHILD_PID_FILE")
    if not path then return end
    assert(Files.within(path, private))
    local output = assert(io.open(path, "ab"))
    output:write(json.encode({ pid = pid, pgid = pgid, starttime = starttime }), "\n"); output:close()
end
local function guardedFailure(err)
    local omitted = type(err) == "table" and err.code == "approved_cover_omitted"
    write(private .. "/guard-failure-" .. tostring(ffi.C.getpid()) .. ".json", { rejected = not omitted, cover_omitted = omitted })
    return nil, err or { kind = "verification_guard", retryable = false, transmitted = false,
        message = "The read-only test guard rejected a request." }
end
local function removeSessionCopy()
    if not session_copy or not Files.exists(session_copy) then return true end
    Files.assertRegular(session_copy, private)
    assert(os.remove(session_copy))
    return not Files.exists(session_copy)
end
local function shutdown()
    if Runtime then pcall(Runtime.close) end
    local clean = pcall(removeSessionCopy)
    report.checks.test_session_copy_removed = clean and (not session_copy or not Files.exists(session_copy))
    local reaped = true
    for runner in pairs(runners) do reaped = reaped and runner.stopped and next(runner.tasks) == nil and #runner.queue == 0 end
    report.checks.worker_lifetimes_closed = reaped
    stopped = true
    if UIManager then UIManager:quit() end
end

local ok = xpcall(function()
    local selection
    if phase == "online" then
        selection = read(assert(arg[4]), 1024 * 1024)
    else
        state = read(private .. "/offline-state.json")
        selection = state.selection
    end
    check("one_bounded_complete_chapter_selected", type(selection) == "table"
        and tostring(selection.comic_id):match("^[1-9]%d*$") and tostring(selection.episode_id):match("^[1-9]%d*$")
        and type(selection.approved_source_paths) == "table" and #selection.approved_source_paths >= 6
        and #selection.approved_source_paths <= 64)
    local comic_id, episode_id = tostring(selection.comic_id), tostring(selection.episode_id)
    local total = #selection.approved_source_paths
    local selected_cover = require("bilicomics/cover_source").resolve(selection.approved_cover_url)
    if phase == "online" and selected_cover then visible_cover_urls[selected_cover.url] = true end
    local approved, approved_paths = {}, {}
    for index, path in ipairs(selection.approved_source_paths) do
        assert(type(path) == "string" and path ~= "" and not approved[path], "Approved source paths must be unique")
        approved[path] = index
        approved_paths[index] = path
    end
    if phase == "offline" then
        ffi.cdef[[long readlink(const char *path, char *buf, unsigned long bufsiz);]]
        local buffer = ffi.new("char[128]")
        local length = ffi.C.readlink("/proc/self/ns/net", buffer, 128)
        check("offline_network_namespace_isolated", length > 0
            and ffi.string(buffer, length) ~= assert(os.getenv("BILI_PARENT_NETNS")))
        local input = assert(io.open("/proc/net/route", "rb"))
        local routes = input:read(8192) or ""; input:close()
        check("offline_has_no_network_routes", not routes:match("\n[^\n]+\t[0-9A-F]+\t"))
    end

    local Transport = require("bilicomics/protocol/transport")
    local transport_request = Transport.request
    local guard
    if phase == "online" then
        local factory = assert(loadfile(assert(arg[5])))()
        guard = assert(factory(selection, { phase = phase, work = work, private_root = private, parent_pid = parent_pid,
            auth_scope = Scope }))
        assert(type(guard.before) == "function" and type(guard.after) == "function"
            and type(guard.updateIndex) == "function" and type(guard.approveTokens) == "function")
    end
    function Transport:request(request)
        if phase ~= "online" or tonumber(ffi.C.getpid()) == parent_pid then return guardedFailure() end
        local allowed, category = guard:before(request)
        if allowed ~= true then return guardedFailure(category) end
        if category ~= "metadata" and category ~= "page_image" and category ~= "cover_image" then return guardedFailure() end
        if request.output_path and not Files.within(request.output_path, private) then return guardedFailure() end
        if category == "page_image" and not Files.exists(private .. "/allow-images") then
            write(private .. "/first-image-blocked.json", { pid = tonumber(ffi.C.getpid()), parent_pid = parent_pid })
            local started = socket.gettime()
            while not Files.exists(private .. "/allow-images") do
                if socket.gettime() - started > 30 or Files.exists(os.getenv("BILI_STOP_FILE")) then return guardedFailure() end
                socket.sleep(0.02)
            end
        end
        local value, err = transport_request(self, request)
        local accepted, checked_error = guard:after(request, value, err)
        if accepted ~= true then return guardedFailure(checked_error) end
        return value, err
    end

    -- The selected chapter remains fixed while its per-request source paths may rotate.
    -- Observe the real worker result before production creates its immutable descriptor.
    local function observeIndex(value)
        check("live_index_episode_matches_selection", type(value) == "table" and tostring(value.episode_id) == episode_id)
        local images = value.images or value.pages
        check("live_index_keeps_complete_page_count", type(images) == "table" and #images == total)
        local paths, mapping = {}, {}
        for index = 1, total do
            local image = images[index]
            check("live_index_paths_are_ordered_and_unique", type(image) == "table" and image.index == index
                and type(image.path) == "string" and image.path ~= "" and #image.path <= 8192 and not mapping[image.path])
            paths[index], mapping[image.path] = image.path, index
        end
        local accepted = guard:updateIndex(value)
        check("guard_accepts_this_complete_live_index", accepted == true)
        approved_paths, approved = paths, mapping
        report.counts.live_index_observations = (report.counts.live_index_observations or 0) + 1
    end

    -- Installed before forking so each real Worker sees the same transparent observer.
    local Client = require("bilicomics/protocol/client")
    local client_image_tokens = Client.imageTokens
    local token_sequence = 0
    function Client:imageTokens(paths, options)
        local tokens, err = client_image_tokens(self, paths, options)
        if tokens then
            local checked, accepted, guard_error = pcall(function()
                assert(phase == "online" and tonumber(ffi.C.getpid()) ~= parent_pid)
                return guard:approveTokens(paths, tokens)
            end)
            if not checked or accepted ~= true then
                guardedFailure(guard_error)
                error("The real image-token result did not satisfy the reading scope")
            end
            token_sequence = token_sequence + 1
            write(private .. "/token-approved-" .. tostring(ffi.C.getpid()) .. "-" .. token_sequence .. ".json",
                { approved = true, count = #tokens })
        end
        return tokens, err
    end

    -- These wrappers observe the real Runner; its worker dependency is never replaced.
    -- Only completed calls write timing evidence. File I/O is outside the measured call interval,
    -- but holds the worker slot briefly before its original result returns to Runner.
    local Worker = require("bilicomics/jobs/worker")
    local worker_execute = Worker.execute
    function Worker.execute(request, ...)
        if type(request) ~= "table" or request.kind ~= "download_page" then return worker_execute(request, ...) end
        local pid = tonumber(ffi.C.getpid())
        local gate_known, gate_open = pcall(Files.exists, private .. "/allow-images")
        local started = image_timing.now()
        local values = packed(pcall(worker_execute, request, ...))
        local finished = image_timing.now()
        pcall(function()
            assert(started and finished and finished >= started)
            write(private .. "/image-worker-" .. pid .. "-" .. string.format("%.0f", started * 1000000) .. ".json", {
                schema = 1, pid = pid, started = started, finished = finished,
                gate_open_at_start = gate_known and gate_open == true,
                returned_normally = values[1] == true,
            })
        end)
        if not values[1] then error(values[2], 0) end
        return unpack(values, 2, values.n)
    end
    local Runner = require("bilicomics/jobs/runner")
    local runner_new, runner_submit, runner_start = Runner.new, Runner.submit, Runner._start
    Runner.new = function(options)
        assert(not options or options.worker == nil, "The default production worker is required")
        local runner = runner_new(options); runners[runner] = true; return runner
    end
    function Runner:submit(request, options, callback)
        local allowed = phase == "online"
        local scoped_method = Scope.submissionName(request, phase == "online" and "reading" or "offline", checked_info)
        if request.kind == "client" then
            allowed = allowed and (request.method == "validateSession"
                or request.method == "comicDetail" and tostring((request.arguments or {})[1]) == comic_id
                or request.method == "imageIndex" and tostring((request.arguments or {})[1]) == episode_id)
        elseif request.kind == "auth" then
            local count = (maintenance_counts[scoped_method or "invalid"] or 0) + 1
            allowed = allowed and scoped_method ~= nil and count <= 2
            maintenance_counts[scoped_method or "invalid"] = count
        elseif request.kind == "library" then
            local count = (library_counts[scoped_method or "invalid"] or 0) + 1
            allowed = allowed and scoped_method ~= nil and count <= 2
            library_counts[scoped_method or "invalid"] = count
        elseif request.kind == "download_cover" then
            allowed = allowed and app and visible_cover_urls[request.url]
                and Files.within(request.temporary_path, app.account.root .. "/covers")
                and request.max_bytes == 4 * 1024 * 1024
            if allowed then
                allowed = type(guard.approveCover) == "function" and guard:approveCover(request.url, request.temporary_path) == true
            end
        elseif request.kind == "download_page" then
            image_submission_attempts = image_submission_attempts + 1
            submission_observation = { source_approved = approved[request.source_path] ~= nil,
                index_matches_approved_order = approved[request.source_path] == request.index,
                index_is_number = type(request.index) == "number" }
            allowed = allowed and approved[request.source_path] == request.index
            if options and options.priority == 20 then prefetched[request.index] = true end
        else allowed = false end
        if not allowed then
            forbidden_attempts = forbidden_attempts + 1
            write(private .. "/submission-observation.json", submission_observation)
            error("An out-of-scope worker was requested")
        end
        submitted[#submitted + 1] = { image = request.kind == "download_page", index = request.index }
        local forwarded = callback
        if request.kind == "auth" and request.method == "cookieInfo" then
            forwarded = function(value, err, update)
                if value then
                    checked_info = { refresh = value.refresh, timestamp = value.timestamp }
                    if Scope.rotationDeferred(value) then
                        report.deferred = true
                        report.checks.no_deferred_credential_rotation_required = false
                        report.counts.credential_rotation_deferred = 1
                        write(private .. "/rotation-deferred.json", { deferred = true })
                        UIManager:nextTick(shutdown)
                        return
                    end
                end
                if callback then return callback(value, err, update) end
            end
        elseif request.kind == "client" and request.method == "imageIndex" then
            forwarded = function(value, err)
                if value then
                    local observed = pcall(observeIndex, value)
                    report.checks.live_index_observation_accepted = observed
                    if not observed then
                        write(private .. "/index-observation-failed.json", { rejected = true })
                        error("The real image index did not satisfy the selected chapter scope")
                    end
                end
                if callback then return callback(value, err) end
            end
        end
        return runner_submit(self, request, options, forwarded)
    end
    function Runner:_start(task)
        local values = packed(runner_start(self, task))
        if values[1] == true and task.pid then
            check("all_acquisition_runs_in_real_children", task.pid ~= parent_pid)
            worker_starts = worker_starts + 1
            if task.request.kind == "download_page" then
                image_timing.starts = image_timing.starts + 1
                local active = 0
                for _, current in pairs(self.tasks) do
                    if current.pid and current.request.kind == "download_page" then active = active + 1 end
                end
                image_timing.peak_processes = math.max(image_timing.peak_processes, active)
            end
            if closed_at and task.request.kind == "download_page" then starts_after_close = starts_after_close + 1 end
            childRecord(task.pid)
        end
        return unpack(values, 1, values.n)
    end

    G_defaults = require("luadefaults"):open()
    local DataStorage = require("datastorage")
    check("application_data_is_private_to_this_run", Files.within(DataStorage:getDataDir(), private))
    G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
    G_reader_settings:saveSetting("color_rendering", false)
    local disabled = {}
    for entry in lfs.dir("plugins") do
        local name = entry:match("^(.*)%.koplugin$")
        if name then disabled[name] = true end
    end
    G_reader_settings:saveSetting("plugins_disabled", disabled)
    local Device = require("device")
    require("document/canvascontext"):init(Device)
    UIManager = require("ui/uimanager")
    local ReaderUI = require("apps/reader/readerui")
    local Provider = require("bilicomics/reader/document")
    local Anchors = require("bilicomics/reader/anchors")
    local provider_init = Provider.init
    function Provider:init()
        provider_init(self)
        initialized[self] = true
        local policy = self._document.policy
        check("reader_budget_unchanged", policy.max_lossless_pixels == 4000000 and policy.max_jpeg_pixels == 32000000
            and policy.max_tile_bytes == 16777216 and policy.max_intermediate_pixels == 2000000)
        local original_open = self._document.openPage
        function self._document:openPage(index)
            local native = original_open(self, index)
            local draw = native.draw
            function native:draw(...)
                draw(self, ...)
                if self.owner.owner._live_draw then self.owner.owner._live_draw.decoded = true end
            end
            return native
        end
        local placeholder, draw = self._placeholder, self._draw
        function self:_placeholder(...)
            self._live_placeholder = true
            if self._live_draw then self._live_draw.placeholder = true end
            return placeholder(self, ...)
        end
        function self:_draw(...)
            local context = {}
            self._live_draw = context
            draw(self, ...)
            if context.decoded and not context.placeholder and next(self._render_errors) == nil
                and next(self._document.active) == nil then self._live_decoded = true end
            self._live_draw = nil
        end
    end
    keeper = require("ui/widget/container/widgetcontainer"):new{}
    UIManager:show(keeper)
    local Controller = require("bilicomics/controller")
    local request_cover = Controller.requestCover
    function Controller:requestCover(comic_id)
        local comic = self:getComic(comic_id)
        local cover = comic and require("bilicomics/cover_source").resolve(comic.cover_url)
        if phase == "online" and self == app and cover then visible_cover_urls[cover.url] = true end
        return request_cover(self, comic_id)
    end
    local Plugin = assert(loadfile(source .. "/main.lua"))()
    local registered
    local plugin = Plugin:new{ ui = { menu = { registerToMainMenu = function(_, value) registered = value end } } }
    check("production_main_initializes", registered == plugin and not plugin.initialization_error)
    Runtime = require("bilicomics/runtime")
    app, screens = Runtime.peek()
    check("production_controller_and_screens_available", app and not app.closed and screens ~= nil)
    app:setSetting("prefetch", true)
    app:setSetting("prefetch_pages", 3)
    app:setSetting("next_episode_pages", 0)
    app:setSetting("reading_mode", "strip")
    app:setSetting("reading_direction", "ltr")

    local function observeEvents()
        local handler = app.account.reader_services.onReaderEvent
        app.account.reader_services.onReaderEvent = function(name, event)
            if name == "opened" then opened_events[event.reader] = event.reader_generation end
            if name == "page_error" or name == "anchor_error" then report.checks.no_reader_errors = false end
            return handler(name, event)
        end
    end
    local started, beats, last_beat, gate_beat, gate_started, gate_maximum = socket.gettime(), 0, socket.gettime()
    local function heartbeat()
        if stopped then return end
        local now = socket.gettime()
        if stage == "gate" then gate_maximum = math.max(gate_maximum or 0, now - last_beat) end
        beats, last_beat = beats + 1, now
        UIManager:scheduleIn(0.03, heartbeat)
    end
    UIManager:scheduleIn(0.03, heartbeat)
    local response, response_error, descriptor, path, bytes, anchor, job, ready_at_close
    local function callback(value, err) response, response_error = value, err end
    local function readCallback(value, err)
        response, response_error = value, err
        if value then screens:close() end
    end
    local function request(next_stage, operation)
        stage, response, response_error = next_stage, nil, nil
        write(private .. "/progress.json", { stage = stage })
        operation()
    end
    local function page(index)
        return app.account.pages:getPage(episode_id, descriptor.revision, index)
    end
    local function readyCount()
        local count = 0
        for index = 1, total do if page(index).state == "ready" then count = count + 1 end end
        return count
    end
    local function verifyDescriptor()
        descriptor, path = app.account.catalog:getDescriptor(episode_id)
        check("server_index_is_the_complete_approved_chapter", descriptor and #descriptor.pages == total
            and descriptor.comic_id == comic_id and descriptor.episode_id == episode_id)
        for index, approved_path in ipairs(approved_paths) do
            check("all_index_paths_match_approved_order", page(index).extra.source_path == approved_path)
        end
        bytes = Files.read(path, 4 * 1024 * 1024)
    end
    local function verifyComplete()
        check("entire_chapter_complete", app.account.pages:isComplete(episode_id, descriptor.revision, true))
        check("entire_chapter_pinned", app.account.store:isPinned(episode_id, descriptor.revision))
        check("exactly_one_chapter_descriptor", #app.account.store:listDescriptors() == 1)
        check("descriptor_path_and_bytes_unchanged", reader == nil or reader.document.file == path)
        check("descriptor_bytes_unchanged", Files.read(path, 4 * 1024 * 1024) == bytes)
        local image_bytes = 0
        for index = 1, total do
            local current = page(index)
            local geometry = current.geometry or {}
            local pixels = (geometry.source_width or current.width) * (geometry.source_height or current.height)
            local jpeg = current.format == "jpg" or current.format == "jpeg"
            check("all_pages_within_existing_reader_limits", pixels <= (jpeg and 32000000 or 4000000))
            image_bytes = image_bytes + Files.size(current.path)
            report.dimensions[index] = { width = current.width, height = current.height,
                jpeg = jpeg, png = current.format == "png", webp = current.format == "webp" }
        end
        report.counts.completed_pages, report.counts.image_bytes = total, image_bytes
    end
    local function finish()
        check("no_out_of_scope_workers", forbidden_attempts == 0)
        report.counts.worker_submissions, report.counts.worker_starts = #submitted, worker_starts
        report.counts.heartbeat_count = beats
        report.counts.image_worker_starts = image_timing.starts
        report.counts.peak_image_processes = image_timing.peak_processes
        report.counts.configured_download_concurrency = app:getSetting("download_concurrency")
        report.counts.configured_image_resource_limit = app.account.raw_runner:getImageConcurrency()
        check("default_download_concurrency_is_two", report.counts.configured_download_concurrency == 2)
        check("image_resource_limit_is_two", report.counts.configured_image_resource_limit == 2)
        if image_timing.reader_closed then
            write(private .. "/image-timing-context.json", { schema = 1, reader_closed = image_timing.reader_closed })
        end
        for _, names in ipairs({ { "cookieInfo", "cookie_info" }, { "ensureSiteContext", "site_context" },
            { "refreshSession", "no_refresh_check" } }) do
            report.counts["maintenance_" .. names[2]] = maintenance_counts[names[1]] or 0
        end
        report.counts.favorites_sync_jobs = library_counts.library_favorites or 0
        report.counts.history_sync_jobs = library_counts.library_history or 0
        if phase == "online" then
            local count = tonumber(Files.read(work .. "/transport-count", 128))
            check("transport_request_count_is_bounded", count and count > 0 and count <= math.min(300, (total + 4) * 4))
            report.counts.transport_requests = count
            local approved_count, batches = 0, 0
            for name in lfs.dir(private) do
                if name:match("^token%-approved%-%d+%-%d+%.json$") then
                    local approval = read(private .. "/" .. name)
                    check("real_token_results_were_guard_approved", approval.approved == true and approval.count == 1)
                    approved_count, batches = approved_count + approval.count, batches + 1
                end
            end
            check("all_downloaded_pages_have_real_token_approval", approved_count >= total)
            report.counts.approved_image_tokens, report.counts.token_approval_batches = approved_count, batches
        else
            report.counts.transport_requests = 0
        end
        shutdown()
    end
    if phase == "online" then
        check("production_connectivity_available", app:_connected())
        check("fresh_account_storage", app.account.key == "anonymous" and #app.account.store:listDescriptors() == 0)
        screens:showLibrary("continue")
        request("login", function() app:importSession(Files.read(assert(arg[6]), 1024 * 1024), callback) end)
    else
        observeEvents()
        check("fresh_process_has_no_session", app.account.session == nil and not app.account.session_valid)
        verifyDescriptor()
        check("same_descriptor_as_online", path == state.path and bytes == state.bytes)
        anchor = state.anchor
        verifyComplete()
        request("offline_open", function() app:readEpisode(comic_id, episode_id, readCallback) end)
    end

    local reported_stage, last_observation, idle_opening_since
    local function openingObservation()
        local current = ReaderUI.instance
        local attached = current and current.bilicomics_integration
        local active = app.active_integration
        local runner = app.runner
        local account = app.account
        local downloads = account and account.downloads
        local pending = 0
        for _ in pairs(runner and runner.tasks or {}) do pending = pending + 1 end
        local page_state
        if current and current.document then
            local read_ok, local_page = pcall(current.document.getLocalPage, current.document, 1)
            if read_ok and local_page then page_state = local_page.state end
        end
        local requests, requests_without_task, failures = 0, 0, 0
        for _, item in pairs(downloads and downloads.requests or {}) do
            requests = requests + 1
            if not item.task_id then requests_without_task = requests_without_task + 1 end
        end
        for _ in pairs(downloads and downloads.failures or {}) do failures = failures + 1 end
        local value = {
            response_received = response ~= nil, reader_instance_exists = current ~= nil,
            integration_exists = attached ~= nil,
            opened_generation_matches = attached ~= nil and opened_events[current] == attached.generation,
            document_is_open = current ~= nil and current.document ~= nil and current.document.is_open == true,
            active_integration_exists = active ~= nil,
            active_integration_current = active ~= nil and active:isCurrent() == true,
            pending_tasks = pending, queued_tasks = runner and #runner.queue or 0,
            first_page_ready = page_state == "ready", first_page_missing = page_state == "missing",
            connected = app:_connected() == true, session_valid = account ~= nil and account.session_valid == true,
            controller_closed = app.closed == true, account_available = account ~= nil,
            controller_suspended = app.suspended == true, runner_suspended = runner ~= nil and runner.suspended == true,
            image_submission_attempts = image_submission_attempts, rejected_worker_attempts = forbidden_attempts,
            download_requests = requests, download_requests_without_task = requests_without_task,
            download_failures = failures, first_image_gate_exists = Files.exists(private .. "/first-image-blocked.json") == true,
        }
        for key, item in pairs(submission_observation) do value[key] = item end
        report.opening_observation = value
        write(private .. "/opening-observation.json", value)
        return value
    end
    local function poll()
        if reported_stage ~= stage then write(private .. "/progress.json", { stage = stage }); reported_stage = stage end
        local limit = tonumber(os.getenv("BILI_PHASE_TIMEOUT")) or 900
        check("phase_within_deadline", socket.gettime() - started < limit)
        if Files.exists(os.getenv("BILI_STOP_FILE")) then error("The operator stopped this private run") end
        for name in lfs.dir(private) do
            if name:match("^guard%-failure%-%d+%.json$") then
                local failure = read(private .. "/" .. name)
                check("all_network_requests_pass_readonly_guard", not failure.rejected)
            end
        end
        check("controller_callbacks_succeed", response_error == nil)
        check("no_reader_errors", report.checks.no_reader_errors ~= false)
        check("no_rejected_live_index", report.checks.live_index_observation_accepted ~= false)
        if stage == "opening" and (not last_observation or socket.gettime() - last_observation >= 1) then
            last_observation = socket.gettime()
            local observation = openingObservation()
            if observation.response_received and observation.pending_tasks == 0 and observation.queued_tasks == 0
                and not observation.first_image_gate_exists then
                idle_opening_since = idle_opening_since or socket.gettime()
            else idle_opening_since = nil end
            check("opening_has_forward_progress", not idle_opening_since or socket.gettime() - idle_opening_since < 15)
        end
        if forbidden_attempts > 0 then
            if stage == "opening" then openingObservation() end
            check("no_out_of_scope_workers", false)
        end
        if stage == "login" and response then
            check("real_session_import_validated", app.account.session ~= nil and app.account.session_valid)
            session_copy = assert(app.session_storage:path(app.account.key))
            check("session_copy_is_test_private", Files.within(session_copy, private))
            observeEvents()
            request("detail", function() app:refreshComic(comic_id, callback) end)
        elseif stage == "detail" and response then
            local episode = app.account.store:getEpisode(episode_id)
            check("selected_chapter_is_really_free", episode and episode.comic_id == comic_id and episode.access == "free")
            request("opening", function() app:readEpisode(comic_id, episode_id, readCallback) end)
        elseif stage == "opening" and response then
            reader = ReaderUI.instance
            if reader and reader.bilicomics_integration
                and opened_events[reader] == reader.bilicomics_integration.generation
                and Files.exists(private .. "/first-image-blocked.json") then
                verifyDescriptor()
                reader:paintTo(Device.screen.bb, 0, 0)
                check("reader_opens_before_first_image", initialized[reader.document] and page(1).state ~= "ready"
                    and reader.document._live_placeholder == true)
                check("real_main_attached_to_native_reader", reader.bilicomics ~= nil)
                local blocked = read(private .. "/first-image-blocked.json")
                check("real_image_child_waits_before_transport", blocked.pid ~= parent_pid and blocked.parent_pid == parent_pid)
                stage, gate_started, gate_beat, gate_maximum = "gate", socket.gettime(), beats, 0
            end
        elseif stage == "gate" and socket.gettime() - gate_started >= 0.4 then
            gate_maximum = math.max(gate_maximum, socket.gettime() - last_beat)
            check("ui_remains_responsive_before_image", beats - gate_beat >= 5 and gate_maximum < 0.5 and page(1).state ~= "ready")
            report.counts.gate_heartbeats = beats - gate_beat
            Files.write(private .. "/allow-images", "allowed\n")
            stage = "arrival"
        elseif stage == "arrival" and page(1).state == "ready" then
            reader:paintTo(Device.screen.bb, 0, 0)
            if reader.document._live_decoded then
                check("first_actual_image_replaces_placeholder", reader == ReaderUI.instance and reader.document.file == path
                    and next(reader.document._render_errors) == nil)
                check("reading_starts_before_chapter_completion", not app.account.pages:isComplete(episode_id, descriptor.revision))
                stage = "prefetch"
            end
        elseif stage == "prefetch" and page(2).state == "ready" then
            check("real_next_image_prefetch_without_navigation", prefetched[2] and reader.paging:getTopPage() == 1)
            request("download", function() app:downloadEpisodes(comic_id, { episode_id }, callback) end)
        elseif stage == "download" and response then
            check("one_explicit_chapter_download", #response == 1)
            job = response[1]
            stage = "close_reader"
        elseif stage == "close_reader" then
            local current = app.account.store:getJob(job.id)
            if current.state == "running" and not app.account.pages:isComplete(episode_id, descriptor.revision) then
                reader.paging:onGotoViewRel(1)
                reader:paintTo(Device.screen.bb, 0, 0)
                reader.bilicomics_integration:saveAnchor()
                anchor = app.account.store:getAnchor(episode_id, descriptor.revision)
                check("real_native_scroll_anchor_saved", anchor and (anchor.y > 0 or anchor.index > 1))
                ready_at_close = readyCount()
                reader:onClose()
                image_timing.reader_closed = image_timing.now()
                reader = nil
                closed_at = socket.gettime()
                check("reader_close_keeps_explicit_download", ReaderUI.instance == nil and not app.closed
                    and app.account.store:getJob(job.id).state == "running")
                stage = "complete"
            end
        elseif stage == "complete" then
            local current = app.account.store:getJob(job.id)
            check("explicit_download_not_failed_or_paused", current.state ~= "failed" and current.state ~= "paused")
            if current.state == "complete" then
                verifyComplete()
                check("remaining_pages_complete_after_reader_close", ReaderUI.instance == nil and ready_at_close < total)
                check("new_image_workers_start_after_close", starts_after_close > 0)
                report.counts.pages_completed_after_reader_close = total - ready_at_close
                report.counts.image_workers_started_after_close = starts_after_close
                local current_selection = {}
                for key, value in pairs(selection) do current_selection[key] = value end
                current_selection.approved_source_paths = approved_paths
                write(private .. "/offline-state.json", { selection = current_selection, path = path, bytes = bytes, anchor = anchor })
                check("session_copy_removed_before_restart", removeSessionCopy())
                finish(); return
            end
        elseif stage == "offline_open" and response then
            reader = ReaderUI.instance
            if reader and reader.bilicomics_integration
                and opened_events[reader] == reader.bilicomics_integration.generation then
                reader:paintTo(Device.screen.bb, 0, 0)
                local actual = Anchors.capture(reader)
                check("offline_same_descriptor", reader.document.file == path and Files.read(path, 4 * 1024 * 1024) == bytes)
                check("offline_native_anchor_restored", actual and actual.page_id == anchor.page_id
                    and math.abs(actual.x - anchor.x) < 0.005 and math.abs(actual.y - anchor.y) < 0.005)
                check("offline_real_native_pixels_rendered", reader.document._live_decoded and next(reader.document._render_errors) == nil)
                check("offline_dispatches_zero_workers", #submitted == 0 and worker_starts == 0)
                reader:onClose(); reader = nil
                finish(); return
            end
        end
        UIManager:scheduleIn(0.05, poll)
    end
    UIManager:scheduleIn(0.05, poll)
    UIManager:run()
    check("workflow_finished", stopped)
end, function(err)
    -- Raw exception detail remains in the private process log and is never exported.
    io.stderr:write(tostring(err), "\n")
    return false
end)
if not stopped then shutdown() end
report.passed = ok
for _, value in pairs(report.checks) do report.passed = report.passed and value end
write(work .. "/" .. phase .. "-results.json", report)
os.exit(report.passed and 0 or 1)
