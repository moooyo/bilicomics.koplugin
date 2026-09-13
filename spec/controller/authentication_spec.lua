-- Real controller/download/storage services with explicitly controlled async workers.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local Controller = require("bilicomics/controller")
local Files = require("bilicomics/storage/files")
local Session = require("bilicomics/protocol/session")
local Util = require("bilicomics/util")
local json = require("rapidjson")
local assertions = {}
local function check(name, passed)
    assertions[#assertions + 1] = { name = name, passed = not not passed }
    assert(passed, name)
end
local ui = { queue = {} }
function ui:nextTick(fn) self.queue[#self.queue + 1] = fn end
function ui:scheduleIn() end
function ui:unschedule() end
function ui:show() end
function ui:close() end
function ui:drain()
    local limit = 1000
    while #self.queue > 0 do limit = limit - 1; assert(limit > 0); table.remove(self.queue, 1)() end
end
local runners = {}
local function makeRunner()
    local runner = { pending = {}, all = {}, count = 0, canceled = {} }
    function runner:submit(request, options, callback)
        self.count = self.count + 1
        local id = options.id or "task-" .. self.count
        local task = { id = id, request = request, options = options, callback = callback }
        self.pending[id], self.all[id] = task, task
        return id
    end
    function runner:find(kind, method)
        for _, task in pairs(self.pending) do
            if task.request.kind == kind and (not method or task.request.method == method) then return task end
        end
        error("No pending request: " .. kind .. "/" .. tostring(method))
    end
    function runner:finish(task, value, err)
        assert(self.pending[task.id] == task)
        self.pending[task.id] = nil
        task.callback(value, err); ui:drain()
    end
    function runner:cancel(id)
        local task = self.pending[id]
        if task then
            self.pending[id], self.canceled[id] = nil, true
            task.callback(nil, { kind = "canceled", transmitted = false })
        end
    end
    function runner:promote() end
    function runner:suspend() self.suspended = true end
    function runner:resume() self.suspended = false end
    function runner:close()
        local copy = {}; for id in pairs(self.pending) do copy[#copy + 1] = id end
        for _, id in ipairs(copy) do self:cancel(id) end
        self.closed = true
    end
    runners[#runners + 1] = runner
    return runner
end
local network = { isConnected = function() return true end }
local root = output .. "/auth-data"
local controller = Controller.new{ root = root, ui_manager = ui, network = network, runner_factory = makeRunner }
local function imported(mid, suffix)
    local session = assert(Session.parse("SESSDATA=synthetic-" .. suffix .. "; DedeUserID=" .. mid .. "; buvid3=synthetic-authentication-device"))
    assert(session:withIdentity({ id = mid, name = "Synthetic account" }))
    return { session = session:serialize(), summary = session:summary() }
end
local function import(mid, suffix)
    local received
    controller:importSession("SESSDATA=synthetic-" .. suffix .. "; DedeUserID=" .. mid,
        function(value, err) assert(value, err and err.kind); received = value end)
    controller.runner:finish(controller.runner:find("client", "validateSession"), imported(mid, suffix))
    assert(received)
end
import("42", "initial")
local account, runner = controller.account, controller.runner
account.store:upsertComic{ id = "1", title = "Synthetic auth recovery comic" }
local episodes = {
    { id = "10", comic_id = "1", order = 1, title = "Free", access = "free", extra = { current_revision = "r1" } },
    { id = "11", comic_id = "1", order = 2, title = "Owned", access = "owned", extra = { current_revision = "r1" } },
    { id = "12", comic_id = "1", order = 3, title = "Locked", access = "locked" },
    { id = "15", comic_id = "1", order = 4, title = "Budget", access = "free", extra = { current_revision = "r1" } },
}
account.store:upsertEpisodes("1", episodes)
local descriptors = {}
for _, episode in ipairs({ "10", "11", "15" }) do
    local descriptor = { schema_version = 1, account_key = account.key, comic_id = "1", episode_id = episode,
        revision = "r1", pages = { { id = episode .. "-1", index = 1, width = 20, height = 40 }, { id = episode .. "-2", index = 2, width = 20, height = 40 } } }
    account.pages:ensureDescriptor(descriptor)
    for index = 1, 2 do account.store:updatePage(episode .. "/r1/" .. index, { extra = { source_path = "/synthetic/" .. episode .. "/" .. index } }) end
    descriptors[episode] = descriptor
    if episode ~= "15" then
        local temporary = account.pages.temporary_root .. "/cached-" .. episode .. ".part"
        Files.write(temporary, Files.read(output .. "/fixture.png"))
        account.pages:commitPage({ episode_id = episode, revision = "r1", index = 1, expected_content_generation = 0 },
            { temporary_path = temporary, format = "png", width = 20, height = 40, checksum = Files.digest(temporary) })
    end
end
local function quoteData()
    return { info = { ep_id = "12", comic_id = "1", ep_original_gold = 20, pay_gold = 20, remain_gold = 100, allow_coupon = false },
        detail = { comic = { id = "1", title = "Synthetic auth recovery comic" }, episodes = Util.copy(episodes) } }
end
local quote, purchase_result, purchase_error
controller:quotePurchase("12", nil, nil, function(value) quote = assert(value) end)
runner:finish(runner:find("quote"), quoteData())
check("authentication_scenario_uses_a_submittable_current_quote", quote.submittable == true and quote.amount == 20)
controller:purchase(quote, function(value, err) purchase_result, purchase_error = value, err end)
runner:finish(runner:find("quote"), quoteData())
local purchase_task = runner:find("purchase_submit")
local jobs
controller:downloadEpisodes("1", { "10", "11" }, function(value) jobs = assert(value) end); ui:drain()
check("real_download_service_started_both_chapters", #jobs == 2 and getmetatable(account.downloads) == require("bilicomics/jobs/download_service"))
local image_tasks = {}
for _, task in pairs(runner.pending) do
    if task.request.kind == "download_page" then
        image_tasks[#image_tasks + 1] = task
        Files.write(task.request.temporary_path, "synthetic partial image")
    end
end
check("two_readonly_image_tasks_are_live", #image_tasks == 2)
local wallet_error
controller:refreshWallet(function(_value, err) wallet_error = err end)
local metadata_task = runner:find("client", "wallet")
local comic = account.store:getComic("1"); comic.cover_url = "https://i0.hdslb.com/synthetic-auth-cover.png"; account.store:upsertComic(comic)
controller:requestCover("1")
local cover_task = runner:find("download_cover")
Files.write(cover_task.request.temporary_path, "synthetic partial cover")
controller:importSession("SESSDATA=synthetic-candidate; DedeUserID=43", function() end)
local candidate_task = runner:find("client", "validateSession")
runner:finish(image_tasks[1], nil, { kind = "authentication", message = "Synthetic expired session" })
check("image_authentication_failure_invalidates_active_account", account.session_valid == false and account.authentication_invalidated)
check("known_invalid_session_marker_is_durable", account.store:getSetting("session_invalidated") == true)
check("all_network_downloads_pause_with_authentication_reason", account.store:getJob(jobs[1].id).state == "paused"
    and account.store:getJob(jobs[2].id).state == "paused" and account.store:getJob(jobs[2].id).error.kind == "authentication")
check("other_image_and_cover_tasks_are_canceled", runner.canceled[image_tasks[2].id] and runner.canceled[cover_task.id])
check("retired_image_and_cover_temporary_files_are_removed", not Files.exists(image_tasks[1].request.temporary_path)
    and not Files.exists(image_tasks[2].request.temporary_path) and not Files.exists(cover_task.request.temporary_path))
check("metadata_reads_are_retired_without_new_account_data", runner.canceled[metadata_task.id] and wallet_error.kind == "authentication")
check("submitted_purchase_is_not_canceled", runner.pending[purchase_task.id] == purchase_task and not runner.canceled[purchase_task.id])
check("explicit_new_session_validation_is_not_canceled", runner.pending[candidate_task.id] == candidate_task and not runner.canceled[candidate_task.id])
local before_requests = runner.count
local denied
controller:refreshWallet(function(_value, err) denied = err end)
controller:refreshComic("1", function() end)
controller:_requestReaderPage(account, descriptors["10"], 2, { prefetch = true })
controller:_preloadNext({ descriptor = descriptors["10"], reader_generation = 1 })
account.downloads:requestPage(descriptors["11"], 2, { retry = true }, function() end)
local resumed, resume_error = controller:resumeJob(jobs[1].id)
controller:resume(); ui:drain()
check("invalid_session_blocks_future_reads_downloads_and_prefetch", runner.count == before_requests and denied.kind == "authentication"
    and not resumed and resume_error.kind == "authentication")
check("ordinary_resume_does_not_restore_invalid_session", account.session_valid == false and account.store:getJob(jobs[1].id).state == "paused")
local cached_free, cached_owned
account.downloads:requestPage(descriptors["10"], 1, {}, function(value) cached_free = value end)
account.downloads:requestPage(descriptors["11"], 1, {}, function(value) cached_owned = value end); ui:drain()
check("ready_free_and_owned_pages_remain_available_offline", cached_free and cached_owned and cached_free.state == "ready" and cached_owned.state == "ready"
    and controller:authorizeDescriptor(descriptors["10"]) and controller:authorizeDescriptor(descriptors["11"]))
runner:finish(purchase_task, { accepted = true })
check("known_purchase_response_is_persisted_after_session_failure", purchase_result and purchase_result.state == "accepted"
    and purchase_error.kind == "authentication" and account.store:getPurchase(purchase_task.request.intent_id).state == "accepted")
check("accepted_purchase_waits_for_authentication_without_rebuy", runner.count == before_requests)
local old_account, old_image_callback, old_metadata_callback, old_cover_callback = account, image_tasks[2].callback, metadata_task.callback, cover_task.callback
controller:close(); ui:drain()
controller = Controller.new{ root = root, ui_manager = ui, network = network, runner_factory = makeRunner }
ui:drain()
check("restart_does_not_reenable_known_invalid_private_session", controller.account.session ~= nil and controller.account.session_valid == false)
local restarted_count = controller.runner.count
controller:refreshWallet(function() end); controller:resume(); ui:drain()
check("restart_and_resume_do_not_send_old_session", controller.runner.count == restarted_count)
import("42", "replacement")
account, runner = controller.account, controller.runner
check("validated_replacement_creates_a_fresh_download_service", account ~= old_account and account.session_valid
    and account.downloads ~= old_account.downloads and account.store:getSetting("session_invalidated") == false)
old_image_callback(nil, { kind = "authentication" }); old_metadata_callback(nil, { kind = "authentication" }); ui:drain()
check("late_old_account_authentication_cannot_invalidate_new_account", account.session_valid == true and not account.authentication_invalidated)
controller:requestCover("1")
local replacement_cover = runner:find("download_cover")
Files.write(replacement_cover.request.temporary_path, "synthetic live replacement")
-- The canceled worker has already delivered its terminal callback and cleaned its file.
check("canceled_cover_is_cleaned_before_replacement", old_account.raw_runner.closed
    and replacement_cover.request.temporary_path ~= cover_task.request.temporary_path
    and not Files.exists(cover_task.request.temporary_path))
old_cover_callback(nil, { kind = "canceled" }); ui:drain()
check("duplicate_old_cover_callback_preserves_replacement_path", not Files.exists(cover_task.request.temporary_path)
    and Files.read(replacement_cover.request.temporary_path) == "synthetic live replacement")
runner:finish(replacement_cover, nil, { kind = "network" })
check("failed_current_cover_cleans_its_assigned_path", not Files.exists(replacement_cover.request.temporary_path))
local enough_space = account.downloads._ensureSpace
local space_checks = 0
account.downloads._ensureSpace = function()
    space_checks = space_checks + 1
    return nil, { kind = "low_space", retryable = false, message = "Synthetic capacity failure" }
end
account.downloads:requestPage(descriptors["15"], 1, {}, function() end); ui:drain()
account.downloads:requestPage(descriptors["15"], 1, {}, function() end); ui:drain()
check("capacity_preflight_failure_is_cached_between_native_hints", space_checks == 1)
account.downloads:requestPage(descriptors["15"], 1, { retry = true }, function() end); ui:drain()
check("explicit_retry_rechecks_capacity", space_checks == 2)
account.downloads:requestPage(descriptors["10"], 1, {}, function(value) assert(value) end); ui:drain()
check("cache_hits_precede_capacity_checks", space_checks == 2)
account.downloads._ensureSpace = enough_space
local resumed_after_import = controller:resumeJob(jobs[1].id); ui:drain()
check("explicit_resume_works_after_verified_session_import", resumed_after_import and runner:find("download_page") ~= nil)
local resumed_image = runner:find("download_page")
controller:refreshWallet(function() end)
runner:finish(runner:find("client", "wallet"), nil, { kind = "authentication" })
check("metadata_authentication_failure_also_pauses_image_acquisition", account.session_valid == false
    and account.store:getJob(jobs[1].id).state == "paused" and runner.canceled[resumed_image.id])
controller:close(); ui:drain()
Files.write(output .. "/authentication-result.json", json.encode({ count = #assertions, assertions = assertions,
    scope = "Production Controller, DownloadService, SQLite and PageStore; controlled asynchronous worker results" }, { pretty = true }))
print(json.encode({ count = #assertions, assertions = assertions }, { pretty = true }))
