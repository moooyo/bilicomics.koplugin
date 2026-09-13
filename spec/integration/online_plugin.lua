-- Cross-layer integration with real native UI, fork/IPC and storage.
-- Only protocol responses and connectivity are synthetic; never run locally.
require("setupkoenv")
local plugin_root, fixture, output, phase = assert(arg[1]), assert(arg[2]), assert(arg[3]), arg[4] or "online"
package.path = plugin_root .. "/?.lua;" .. plugin_root .. "/?/init.lua;" .. package.path
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local lfs = require("libs/libkoreader-lfs")
local disabled = {}
for entry in lfs.dir("plugins") do
    local name = entry:match("^(.*)%.koplugin$")
    if name then disabled[name] = true end
end
G_reader_settings:saveSetting("plugins_disabled", disabled)
G_reader_settings:saveSetting("color_rendering", false)
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local ReaderUI = require("apps/reader/readerui")
local Files = require("bilicomics/storage/files")
local Header = require("bilicomics/storage/image_header")
local json = require("rapidjson")
local socket = require("socket")
local ffi = require("ffi")
local parent_pid = tonumber(ffi.C.getpid())
local report = { phase = phase, assertions = {}, submitted = {},
    scope = "Real main/Runtime/Controller/ReaderUI/Runner fork and PageStore; synthetic protocol; no Bilibili requests",
    runtime = require("version"):getCurrentRevision() }
local function write(name, value)
    local file = assert(io.open(output .. "/" .. name, "wb"))
    file:write(json.encode(value, { pretty = true })); file:close()
end
local function read(name)
    local file = assert(io.open(output .. "/" .. name, "rb"))
    local value = json.decode(file:read("*a")); file:close(); return value
end
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
Files.mkdir(output .. "/worker-audit")
local connected = phase == "online"
local network = require("ui/network/manager")
network.isConnected = function() return connected end
local function fixtureWorker(request)
    local child_pid = tonumber(ffi.C.getpid())
    assert(child_pid ~= parent_pid, "The fixture worker must run in a real child process")
    local audit = { pid = child_pid, parent_pid = parent_pid, kind = request.kind,
        method = request.method, source_path = request.source_path, index = request.index, started_at = socket.gettime() }
    local audit_name = "worker-audit/" .. child_pid .. ".json"
    write(audit_name, audit)
    assert(phase == "online", "Offline reading dispatched a worker")
    local value
    if request.kind == "client" and request.method == "validateSession" then
        local session = assert(require("bilicomics/protocol/session").new(request.session):withIdentity(
            { id = "4242", name = "Synthetic integration account", isLogin = true }))
        value = { session = session:serialize(), summary = session:summary() }
    elseif request.kind == "client" and request.method == "comicDetail" then
        value = { comic = { id = "42", title = "Synthetic online integration", latest_episode_id = "4203" }, episodes = {
            { id = "4201", comic_id = "42", order = 1, title = "Free online chapter", access = "free" },
            { id = "4202", comic_id = "42", order = 2, title = "Already owned chapter", access = "owned" },
            { id = "4203", comic_id = "42", order = 3, title = "Locked chapter", access = "locked" },
        } }
    elseif request.kind == "client" and request.method == "imageIndex" then
        local episode = tostring(request.arguments[1])
        assert(episode == "4201" or episode == "4202", "Locked content reached image acquisition")
        value = { revision = "online_v1", images = {} }
        for index = 1, episode == "4201" and 6 or 2 do
            value.images[index] = { id = episode .. "-" .. index, width = 600, height = 2400,
                path = "fixture/" .. episode .. "/" .. index }
        end
        socket.sleep(0.03)
    elseif request.kind == "download_page" then
        local episode, index = request.source_path:match("^fixture/(%d+)/(%d+)$")
        assert(episode and episode ~= "4203", "Unknown image fixture")
        if request.source_path == "fixture/4201/1" and not lfs.attributes(output .. "/allow-images", "mode") then
            write("first-image-blocked.json", { pid = child_pid, blocked_at = socket.gettime() })
        end
        while not lfs.attributes(output .. "/allow-images", "mode") do socket.sleep(0.02) end
        socket.sleep(tonumber(index) <= 2 and 0.12 or 0.45)
        Files.write(request.temporary_path, Files.read(fixture, 8 * 1024 * 1024))
        local header = Header.read(request.temporary_path)
        value = { temporary_path = request.temporary_path, checksum = Files.digest(request.temporary_path),
            width = header.width, height = header.height, format = header.format,
            geometry = { source_width = header.width, source_height = header.height, exif_orientation = 1 } }
    else
        error("Unexpected protocol operation: " .. tostring(request.kind) .. ":" .. tostring(request.method))
    end
    audit.completed_at = socket.gettime(); write(audit_name, audit)
    return value
end

-- Inject the documented Runner worker dependency only at the test boundary.
-- All scheduling, prioritization, process creation, IPC and completion are production code.
local Runner = require("bilicomics/jobs/runner")
local original_new = Runner.new
local runners = {}
Runner.new = function(options)
    options = options or {}; options.worker = fixtureWorker
    local runner = original_new(options)
    runners[#runners + 1] = runner
    local submit = runner.submit
    runner.submit = function(self, request, settings, callback)
        report.submitted[#report.submitted + 1] = { kind = request.kind, method = request.method,
            source_path = request.source_path, index = request.index, priority = settings and settings.priority,
            resource = settings and settings.resource }
        return submit(self, request, settings, callback)
    end
    return runner
end

local Plugin = assert(loadfile(plugin_root .. "/main.lua"))()
local menu_plugin
local plugin = Plugin:new{ ui = { menu = { registerToMainMenu = function(_, instance) menu_plugin = instance end } } }
check("actual_entry_initializes", menu_plugin == plugin and not plugin.initialization_error)
local Runtime = require("bilicomics/runtime")
local app, screens = Runtime.peek()
check("actual_runtime_controller_is_active", app and not app.closed and screens ~= nil)
screens:showLibrary("continue")
app:setSetting("minimum_free_bytes", 0)
app:setSetting("cache_limit_bytes", 128 * 1024 * 1024)
app:setSetting("prefetch_pages", 3)

local started, last_heartbeat = socket.gettime(), socket.gettime()
local beats, maximum_gap, stopped = 0, 0, false
local hold_window_active, hold_maximum_gap = false, 0
local function heartbeat()
    if stopped then return end
    local now = socket.gettime()
    maximum_gap = math.max(maximum_gap, now - last_heartbeat)
    if hold_window_active then hold_maximum_gap = math.max(hold_maximum_gap, now - last_heartbeat) end
    last_heartbeat, beats = now, beats + 1
    UIManager:scheduleIn(0.03, heartbeat)
end
UIManager:scheduleIn(0.03, heartbeat)
local stage, response, response_error, reader, descriptor_path, descriptor_bytes, position, online_pixel
local hold_started, hold_beats, download_jobs, closing_count, closed_at
local function callback(value, err) response, response_error = value, err end
local function readCallback(value, err)
    response, response_error = value, err
    -- Match Screens:_read's production completion behavior when calling the controller directly.
    if value then screens:close() end
end
local function request(next_stage, operation)
    stage, response, response_error = next_stage, nil, nil
    operation()
end
local function page(index, episode)
    return app.account.pages:getPage(episode or "4201", "online_v1", index)
end
local function finish()
    local purchases = 0
    for _, item in ipairs(report.submitted) do
        if item.kind == "purchase_submit" or item.kind == "quote" or item.method == "buyEpisode" then purchases = purchases + 1 end
    end
    check("reading_prefetch_and_download_never_purchase", purchases == 0)
    check("reading_and_download_create_no_purchase_journal", #app.account.store:listPurchases() == 0)
    if screens then screens:close() end
    Runtime.close()
    for index, runner in ipairs(runners) do
        check("runner_closed_and_children_reaped_" .. index, runner.stopped and next(runner.tasks) == nil and #runner.queue == 0)
    end
    report.heartbeat_count, report.maximum_heartbeat_gap = beats, maximum_gap
    stopped = true
    UIManager:quit()
end

if phase == "online" then
    request("login", function() app:importSession("SESSDATA=synthetic-integration-session; DedeUserID=4242; buvid3=synthetic-integration-device", callback) end)
else
    local expected = read("expected-offline.json")
    descriptor_path, descriptor_bytes, position, online_pixel = expected.path, expected.bytes, expected.anchor, expected.pixel
    check("fresh_process_has_no_session", app.account.session == nil and not app:getAccount().session_valid)
    check("free_and_owned_chapters_remain_pinned", app.account.store:isPinned("4201", "online_v1")
        and app.account.store:isPinned("4202", "online_v1"))
    request("offline_free", function() app:readEpisode("42", "4201", readCallback) end)
end

local function poll()
    assert(socket.gettime() - started < 25, "Online integration timed out in stage " .. tostring(stage))
    if response_error and stage ~= "locked" then error(stage .. ": " .. tostring(response_error.kind) .. ": " .. tostring(response_error.message)) end
    if stage == "login" and response then
        check("session_import_uses_real_controller_and_child", app.account.key == "bili_4242" and app.account.session_valid)
        request("detail", function() app:refreshComic("42", callback) end)
    elseif stage == "detail" and response then
        check("protocol_boundary_ingests_free_owned_and_locked", #app:getEpisodes("42") == 3)
        request("placeholder", function() app:readEpisode("42", "4201", readCallback) end)
    elseif stage == "placeholder" and response then
        reader = ReaderUI.instance
        if reader and reader.bilicomics_integration and Device.screen.bb:getPixel(300, 100):getR() == 235
            and Files.exists(output .. "/first-image-blocked.json") then
            descriptor_path = reader.document.file
            descriptor_bytes = Files.read(descriptor_path, 4 * 1024 * 1024)
            check("native_reader_opens_before_first_image", page(1).state ~= "ready" and reader.document:getPageCount() == 6)
            check("real_main_plugin_is_attached_to_reader", reader.bilicomics ~= nil)
            check("first_image_child_is_waiting_at_the_gate", read("first-image-blocked.json").pid ~= parent_pid)
            hold_started, hold_beats, stage = socket.gettime(), beats, "hold"
            hold_window_active, hold_maximum_gap = true, 0
        end
    elseif stage == "hold" and socket.gettime() - hold_started >= 0.4 then
        hold_window_active = false
        check("ui_processes_events_while_image_worker_is_blocked", beats - hold_beats >= 5 and page(1).state ~= "ready"
            and hold_maximum_gap < 0.25, { heartbeats = beats - hold_beats, maximum_gap = hold_maximum_gap })
        Files.write(output .. "/allow-images", "allow\n")
        stage = "arrival"
    elseif stage == "arrival" and page(1).state == "ready" and Device.screen.bb:getPixel(300, 100):getR() == 40 then
        check("committed_page_replaces_native_placeholder", reader == ReaderUI.instance and reader.document.file == descriptor_path)
        check("first_image_does_not_require_complete_chapter", not app.account.pages:isComplete("4201", "online_v1"))
        stage = "prefetch"
    elseif stage == "prefetch" and page(2).state == "ready" then
        local prefetched
        for _, item in ipairs(report.submitted) do
            if item.source_path == "fixture/4201/2" and item.priority == 20 then prefetched = true end
        end
        check("next_image_prefetch_completes_without_navigation", prefetched and reader.paging:getTopPage() == 1)
        closing_count = #report.submitted
        request("locked", function() app:downloadEpisodes("42", { "4203" }, callback) end)
    elseif stage == "locked" and response_error then
        check("locked_download_does_not_purchase_or_dispatch", response_error.kind == "entitlement" and #report.submitted == closing_count)
        request("download", function() app:downloadEpisodes("42", { "4201", "4202" }, callback) end)
    elseif stage == "download" and response then
        download_jobs = response
        check("explicit_download_enqueues_free_and_owned", #download_jobs == 2)
        stage = "close_while_downloading"
    elseif stage == "close_while_downloading" then
        local job = app.account.store:getJob(download_jobs[1].id)
        local protected_request
        for _, active_request in pairs(app.account.downloads.requests) do
            if active_request.owners["job:" .. job.id] then protected_request = true end
        end
        if job.state == "running" and protected_request and not app.account.pages:isComplete("4201", "online_v1") then
            check("download_keeps_original_descriptor_and_native_document", reader.document.file == descriptor_path
                and Files.read(descriptor_path, 4 * 1024 * 1024) == descriptor_bytes)
            reader.paging:onGotoViewRel(1)
            reader.bilicomics_integration:saveAnchor()
            position = app.account.store:getAnchor("4201", "online_v1")
            check("online_native_position_is_durable", position and position.y > 0)
            stage = "online_position"
        end
    elseif stage == "online_position" and Device.screen.bb:getPixel(300, 100):getR() == 100 then
            online_pixel = Device.screen.bb:getPixel(300, 100):getR()
            check("online_scrolled_position_is_visibly_rendered", reader.document:isPageReady(1))
            screens:showDownloads()
            reader:onClose()
            closed_at = socket.gettime()
            check("reader_close_preserves_explicit_task_and_runtime", not app.closed
                and app.account.store:getJob(download_jobs[1].id).state == "running" and ReaderUI.instance == nil)
            stage = "complete"
    elseif stage == "complete" then
        local complete = true
        for _, job in ipairs(download_jobs) do
            local current = app.account.store:getJob(job.id)
            if current.state == "failed" then error("Download failed: " .. json.encode(current.error)) end
            complete = complete and current.state == "complete"
        end
        if complete then
            check("downloads_finish_after_reader_closes", ReaderUI.instance == nil
                and app.account.pages:isComplete("4201", "online_v1") and app.account.pages:isComplete("4202", "online_v1"))
            check("finished_downloads_are_pinned", app.account.store:isPinned("4201", "online_v1")
                and app.account.store:isPinned("4202", "online_v1"))
            check("download_never_rewrites_descriptor", Files.read(descriptor_path, 4 * 1024 * 1024) == descriptor_bytes)
            local audit_count, started_after_close, completed_after_close = 0, 0, 0
            for name in lfs.dir(output .. "/worker-audit") do
                if name:match("%.json$") then
                    local audit = read("worker-audit/" .. name)
                    check("real_fork_pid_" .. name, audit.pid ~= parent_pid and audit.parent_pid == parent_pid)
                    if audit.kind == "download_page" then
                        if audit.started_at > closed_at then started_after_close = started_after_close + 1 end
                        if audit.completed_at and audit.completed_at > closed_at then completed_after_close = completed_after_close + 1 end
                    end
                    audit_count = audit_count + 1
                end
            end
            check("protocol_and_image_results_cross_real_child_boundary", audit_count >= 11)
            check("new_image_workers_start_and_finish_after_reader_close", started_after_close > 0 and completed_after_close > 0,
                { started = started_after_close, completed = completed_after_close })
            write("expected-offline.json", { path = descriptor_path, bytes = descriptor_bytes, anchor = position, pixel = online_pixel })
            local session_path = app.account.root .. "/session.dat"
            Files.assertRegular(session_path, app.account.root); assert(os.remove(session_path))
            app.account.session, app.account.session_valid, connected = nil, false, false
            finish(); return
        end
    elseif stage == "offline_free" and response then
        reader = ReaderUI.instance
        local anchor = require("bilicomics/reader/anchors").capture(reader)
        if anchor and math.abs(anchor.y - position.y) < 0.005 and reader.document:isPageReady(anchor.index)
            and Device.screen.bb:getPixel(300, 100):getR() == online_pixel then
            check("offline_reopen_uses_identical_descriptor", reader.document.file == descriptor_path
                and Files.read(descriptor_path, 4 * 1024 * 1024) == descriptor_bytes)
            check("offline_reopen_restores_online_source_position", anchor.page_id == position.page_id and anchor.y > 0)
            check("offline_free_renders_the_same_content_pixels", online_pixel == 100)
            check("no_session_offline_free_open_dispatches_zero_workers", #report.submitted == 0)
            screens:showDownloads(); reader:onClose()
            request("offline_owned", function() app:readEpisode("42", "4202", readCallback) end)
        end
    elseif stage == "offline_owned" and response then
        reader = ReaderUI.instance
        if reader.document:isPageReady(1) and Device.screen.bb:getPixel(300, 100):getR() == 40 then
            check("owned_chapter_reopens_offline", reader.document.descriptor.episode_id == "4202")
            check("offline_owned_renders_actual_image_pixels", true)
            check("all_offline_operations_dispatch_zero_workers", #report.submitted == 0)
            screens:showDownloads(); reader:onClose()
            finish(); return
        end
    end
    UIManager:scheduleIn(0.025, poll)
end
UIManager:scheduleIn(0.025, poll)
local ok, err = xpcall(function() UIManager:run() end, debug.traceback)
report.passed, report.error, report.final_stage = ok and stopped, not ok and err or nil, stage
if not ok then pcall(Runtime.close) end
write(phase .. "-results.json", report)
print(json.encode(report))
if not report.passed then os.exit(1) end
