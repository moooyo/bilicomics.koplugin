-- Main-process controller integration with real SQLite and controlled async workers.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local Controller = require("bilicomics/controller")
local Session = require("bilicomics/protocol/session")
local Store = require("bilicomics/storage/store")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local Util = require("bilicomics/util")
local checks = {}
local function check(name, condition)
    checks[#checks + 1] = { name = name, passed = not not condition }
    assert(condition, name)
end
local ui = { queue = {}, timers = {} }
function ui:nextTick(callback) self.queue[#self.queue + 1] = callback end
function ui:scheduleIn(_delay, callback) self.timers[callback] = true end
function ui:unschedule(callback) self.timers[callback] = nil end
function ui:drain()
    local remaining = 1000
    while #self.queue > 0 do
        remaining = remaining - 1; assert(remaining > 0, "Unbounded deferred work")
        table.remove(self.queue, 1)()
    end
end
function ui:show(widget) self.dialog = widget end
function ui:close(widget) if self.dialog == widget then self.dialog = nil end end
local runners, log, controller = {}, {}
local function runnerFactory()
    local runner = { requests = {}, order = {}, sequence = 0 }
    function runner:submit(request, options, callback)
        assert(not self.closed, "Closed runner submitted work")
        self.sequence = self.sequence + 1
        local identifier = "request-" .. self.sequence
        self.requests[identifier] = { request = request, options = options, callback = callback }
        self.order[#self.order + 1] = identifier
        if request.kind == "purchase_submit" then
            local saved = controller.account.store:getPurchase(request.intent_id)
            check("purchase_is_durable_before_worker_dispatch", saved and saved.state == "submitting" and controller.account.store._depth == 0)
            check("purchase_worker_cannot_be_preempted", options.cancelable == false)
        end
        return identifier
    end
    function runner:next(kind)
        for _index, identifier in ipairs(self.order) do
            local pending = self.requests[identifier]
            if pending and (not kind or pending.request.kind == kind) then return pending, identifier end
        end
        error("No pending worker: " .. tostring(kind))
    end
    function runner:finish(kind, value, err)
        local pending, identifier = self:next(kind)
        self.requests[identifier] = nil
        pending.callback(value, err); ui:drain()
        return pending
    end
    function runner:cancel(identifier)
        local pending = self.requests[identifier]
        if pending then self.requests[identifier] = nil; pending.callback(nil, { kind = "canceled" }) end
    end
    function runner:promote() end
    function runner:suspend() self.suspended = true end
    function runner:resume() self.suspended = false end
    function runner:close()
        log[#log + 1] = "runner-closed"
        self.closed = true
        for identifier, pending in pairs(self.requests) do
            self.requests[identifier] = nil; pending.callback(nil, { kind = "closed" })
        end
    end
    runners[#runners + 1] = runner
    return runner
end
local captured_reader_open
local network = { connected = true }
function network:isConnected() return self.connected end
controller = Controller.new{ root = output .. "/data", ui_manager = ui, runner_factory = runnerFactory,
    network = network,
    reader_opener = function(path, provider, after_open) captured_reader_open = { path = path, provider = provider, callback = after_open } end }
ui:drain()
check("fresh_account_is_isolated_anonymous", controller.account.key == "anonymous")
local initial_requests = #controller.runner.order
controller:getLibrary("history"); controller:getEpisodes("1"); controller:getWallet(); controller:getStorageSummary()
check("local_getters_do_not_dispatch_network", #controller.runner.order == initial_requests)
check("cache_ui_limit_matches_runtime_limit", controller:getSetting("cache_limit_mb", 512) * 1048576 == controller.settings:get("cache_limit_bytes"))

local secret = "synthetic-session-value"
local function validated(mid)
    local session = assert(Session.parse("SESSDATA=" .. secret .. "; DedeUserID=" .. mid))
    assert(session:withIdentity({ id = mid, name = "Synthetic account " .. mid }))
    return { session = session:serialize(), summary = session:summary() }
end
local imported
controller:importSession("SESSDATA=" .. secret .. "; DedeUserID=42", function(value, err) assert(value, err and err.kind); imported = value end)
check("session_validation_is_async", imported == nil and controller.runner:next("client").request.method == "validateSession")
local anonymous_runner = controller.runner
anonymous_runner:finish("client", validated("42"))
check("account_switch_reaps_old_runner", anonymous_runner.closed and imported.account_key == "bili_42")
check("account_database_has_resolved_namespace", controller.account.store.root == output .. "/data/accounts/bili_42")
check("session_is_per_account", Files.exists(output .. "/data/accounts/bili_42/session.dat") and not Files.exists(output .. "/data/session.json"))
check("settings_do_not_contain_session_secret", not Files.read(output .. "/data/settings.lua"):find(secret, 1, true))
local rejected_session
controller:importSession("SESSDATA=rejected-candidate; DedeUserID=99", function(_value, err) rejected_session = err end)
controller.runner:finish("client", nil, { kind = "authentication" })
check("rejected_import_does_not_invalidate_active_session", rejected_session.kind == "authentication"
    and controller.account.key == "bili_42" and controller.account.session_valid)

local comic = { id = "1", title = "Synthetic comic", favorite = true, latest_order = 3 }
local episodes = {
    { id = "10", comic_id = "1", order = 1, title = "Free chapter", access = "free" },
    { id = "11", comic_id = "1", order = 2, title = "Paid chapter", access = "locked" },
    { id = "12", comic_id = "1", order = 3, title = "Next paid chapter", access = "locked" },
    { id = "13", comic_id = "1", order = 4, title = "Final paid chapter", access = "locked" },
}
local function detail() return { comic = Util.copy(comic), episodes = Util.copy(episodes) } end
controller:refreshLibrary("favorites", function(value) assert(#value == 1) end)
controller.runner:finish("library", { comic })
check("favorites_are_persisted", #controller:getLibrary("favorites") == 1)
controller:refreshComic("1", function(value) assert(#value.episodes == 4) end)
controller.runner:finish("client", detail())
check("catalog_and_episodes_are_persisted", #controller:getEpisodes("1") == 4)
local empty_error
controller:search(" ", function(_value, err) empty_error = err end); ui:drain()
check("empty_search_does_not_dispatch", empty_error.kind == "invalid_request")

local prepared
controller:prepareEpisode("1", "10", function(value, err) assert(value, err and err.kind); prepared = value end)
controller.runner:finish("client", { episode_id = "10", revision = "revision-1",
    images = { { id = "source-1", index = 1, path = "/synthetic/image.png", width = 20, height = 40 } } })
check("descriptor_is_immutable_and_excludes_source_urls", prepared.descriptor.pages[1].path == nil and not Files.read(prepared.path):find("synthetic/image", 1, true))
check("source_locator_is_account_page_metadata", controller.account.store:getPage("10/revision-1/1").extra.source_path == "/synthetic/image.png")
local mismatch = Util.copy(prepared.descriptor)
mismatch.pages[1].id = "another-page"
local descriptor_allowed, descriptor_error = controller:authorizeDescriptor(mismatch)
check("direct_descriptor_requires_exact_saved_identity", not descriptor_allowed and descriptor_error.kind == "invalid_descriptor")
local fixture = output .. "/fixture.png"
local temporary = controller.account.pages.temporary_root .. "/page.part"
Files.write(temporary, Files.read(fixture))
controller.account.pages:commitPage({ episode_id = "10", revision = "revision-1", index = 1, expected_content_generation = 0 },
    { temporary_path = temporary, width = 20, height = 40, format = "png", checksum = Files.digest(temporary) })
check("prepared_image_commits_through_real_page_store", controller.account.pages:isComplete("10", "revision-1"))
local stored_page = controller.account.store:getPage("10/revision-1/1")
stored_page.state, stored_page.path = "missing", nil
stored_page.extra.source_path = nil
controller.account.store:putPage(stored_page)
local recovered_index, recovery_error
local before_recovery_requests = #controller.runner.order
controller:prepareEpisode("1", "10", function(value, err) recovered_index, recovery_error = value, err end); ui:drain()
check("incomplete_descriptor_without_source_requires_explicit_recovery", recovered_index == nil
    and recovery_error.kind == "source_unavailable" and #controller.runner.order == before_recovery_requests)
local recovery_jobs
controller:downloadEpisodes("1", { "10" }, function(value) recovery_jobs = assert(value) end); ui:drain()
controller:refreshDownloadSources(recovery_jobs[1].id, function(value, err)
    assert(value, err and err.kind); recovered_index = value
end)
check("explicit_recovery_requests_fresh_index_and_access", controller.runner:next("source_index").request.episode_id == "10")
controller.runner:finish("source_index", { detail = detail(), index = { episode_id = "10", revision = "revision-1",
    images = { { id = "source-1", index = 1, path = "/synthetic/refreshed-image.png", width = 20, height = 40 } } } })
local source_proof = controller.runner:next("verify_source_page")
check("recovery_requires_historical_content_proof", source_proof.request.expected_checksum == stored_page.extra.last_committed_checksum
    and controller.account.store:getPage("10/revision-1/1").extra.source_path == nil)
Files.write(source_proof.request.temporary_path, Files.read(fixture))
controller.runner:finish("verify_source_page", { temporary_path = source_proof.request.temporary_path,
    checksum = Files.digest(source_proof.request.temporary_path) })
check("verified_recovery_restores_source_without_replacing_descriptor", recovered_index and recovered_index.revision == "revision-1"
    and controller.account.store:getPage("10/revision-1/1").extra.source_path == "/synthetic/refreshed-image.png"
    and Util.hash(controller.account.pages:readDescriptor(prepared.path)) == Util.hash(prepared.descriptor))
local recovery_download = controller.runner:next("download_page")
Files.write(recovery_download.request.temporary_path, Files.read(fixture))
controller.runner:finish("download_page", { temporary_path = recovery_download.request.temporary_path,
    width = 20, height = 40, format = "png", checksum = Files.digest(recovery_download.request.temporary_path) })
check("explicit_recovery_resumes_and_completes_retained_download", controller.account.pages:isComplete("10", "revision-1")
    and controller.account.store:getJob(recovery_jobs[1].id).state == "complete")

local restored_integration = package.loaded["bilicomics/reader/integration"]
package.loaded["bilicomics/reader/integration"] = { attach = function(reader)
    if reader.bilicomics_integration then return reader.bilicomics_integration end
    local account = controller.account
    account.pages:setActiveEpisode("10", "revision-1", true)
    local integration = { reader = reader, document = reader.document, generation = 101 }
    function integration:isCurrent() return not self.closed end
    function integration:saveAnchor() end
    function integration:requestVisible() end
    function integration:notifyPageReady() end
    function integration:close()
        if self.closed then return end
        self.closed = true; account.pages:setActiveEpisode("10", "revision-1", false)
        controller:_readerEvent("closed", { descriptor = prepared.descriptor, reader_generation = 101 })
    end
    reader.bilicomics_integration = integration
    return integration
end }
local session = controller.account.session
controller.account.session, controller.account.session_valid = nil, false
local worker_count, opened = #controller.runner.order, nil
controller:readEpisode("1", "10", function(value, err) assert(value, err and err.kind); opened = value end)
ui:drain()
local duplicate_open_error
controller:readEpisode("1", "10", function(_value, err) duplicate_open_error = err end)
ui:drain()
check("offline_open_does_not_refresh_network", #controller.runner.order == worker_count)
check("reader_ready_is_not_assumed_synchronously", opened == nil and captured_reader_open ~= nil)
check("concurrent_cached_open_is_rejected_without_lost_pin", duplicate_open_error.kind == "busy" and controller.account.pages.active["10/revision-1"] == 1)
local reader = { document = { provider = "bilicomics_document", file = prepared.path, descriptor = prepared.descriptor } }
captured_reader_open.callback(reader)
check("reader_callback_completes_after_attachment", opened and controller.account.pages.active["10/revision-1"] == 1)
controller.account.store:putJob{ id = "offline", kind = "episode_download", state = "complete", episode_id = "10", comic_id = "1", revision = "revision-1", total = 1, completed = 1 }
local removal_error
controller:removeDownload("offline", function(_value, err) removal_error = err end)
check("active_reader_prevents_download_removal", removal_error.kind == "active_content")
reader.bilicomics_integration:close()
local removed
controller:removeDownload("offline", function(value, err) assert(value, err and err.kind); removed = value end)
check("removing_download_preserves_descriptor_and_access", removed.removed_pages == 1 and controller.account.store:getEpisode("10").access == "free"
    and controller.account.store:getDescriptor("10", "revision-1") ~= nil and #controller:getDownloads() == 0)
controller.account.session, controller.account.session_valid = session, true
local timed_out
controller:readEpisode("1", "10", function(_value, err) timed_out = err end); ui:drain()
local late_open = captured_reader_open
controller.opening.timeout()
check("reader_timeout_releases_pending_active_guard", timed_out.kind == "reader" and controller.opening == nil and controller.account.pages.active["10/revision-1"] == 0)
local later_opened
controller:readEpisode("1", "10", function(value) later_opened = value end); ui:drain()
local new_opening = controller.opening
local stale_closed = false
late_open.callback({ document = reader.document, onClose = function() stale_closed = true end })
check("late_reader_cannot_claim_same_path_new_opening", stale_closed and later_opened == nil and controller.opening == new_opening)
captured_reader_open.callback({ document = reader.document })
controller.active_integration:close()
local transaction = controller.account.store.transaction
controller.account.store.transaction = function() error("Injected active acquisition failure") end
local pin_error
controller:readEpisode("1", "10", function(_value, err) pin_error = err end); ui:drain()
controller.account.store.transaction = transaction
check("failed_active_acquisition_does_not_leave_busy_or_pin", pin_error and pin_error.kind == "storage" and controller.opening == nil
    and controller.account.pages.active["10/revision-1"] == 0)
package.loaded["bilicomics/reader/integration"] = restored_integration
local partial_descriptor = { schema_version = 1, account_key = "bili_42", comic_id = "1", episode_id = "14", revision = "partial",
    pages = { { id = "partial-1", index = 1, width = 20, height = 40 }, { id = "partial-2", index = 2, width = 20, height = 40 } } }
controller.account.store:upsertEpisodes("1", { { id = "14", comic_id = "1", order = 5, title = "Partly cached chapter", access = "free",
    extra = { current_revision = "partial" } } })
controller.account.pages:ensureDescriptor(partial_descriptor)
temporary = controller.account.pages.temporary_root .. "/partial-one.part"
Files.write(temporary, Files.read(fixture))
controller.account.pages:commitPage({ episode_id = "14", revision = "partial", index = 1, expected_content_generation = 0 },
    { temporary_path = temporary, width = 20, height = 40, format = "png", checksum = Files.digest(temporary) })
controller.account.session, controller.account.session_valid = nil, false
local before_partial_workers = #controller.runner.order
controller:readEpisode("1", "14", function() end); ui:drain()
check("partial_offline_content_can_open_without_source_metadata", controller.opening and controller.opening.descriptor.episode_id == "14")
controller:_requestReaderPage(controller.account, partial_descriptor, 2, { prefetch = false }); ui:drain()
check("partial_offline_gap_does_not_start_network_worker", #controller.runner.order == before_partial_workers)
local partial_episode
for _index, candidate in ipairs(controller:getEpisodes("1")) do if candidate.id == "14" then partial_episode = candidate end end
check("partial_offline_content_is_not_marked_downloaded", partial_episode.cached_pages == 1 and partial_episode.total_pages == 2 and not partial_episode.downloaded)
controller:_releaseOpening({ kind = "canceled" })
controller.account.session, controller.account.session_valid = session, true
temporary = controller.account.pages.temporary_root .. "/partial-two.part"
Files.write(temporary, Files.read(fixture))
controller.account.pages:commitPage({ episode_id = "14", revision = "partial", index = 2, expected_content_generation = 0 },
    { temporary_path = temporary, width = 20, height = 40, format = "png", checksum = Files.digest(temporary) })
local temporary_episode = controller.account.store:getEpisode("14")
temporary_episode.access, temporary_episode.expires_at = "temporary", os.time() + 3600
controller.account.store:upsertEpisodes("1", { temporary_episode })
check("temporary_descriptor_requires_current_online_grant", controller:authorizeDescriptor(partial_descriptor) == nil)
controller:readEpisode("1", "14", function() end); ui:drain()
check("complete_temporary_cache_refreshes_online_entitlement", controller.runner:next("client").request.method == "comicDetail" and controller.opening == nil)
local temporary_detail = detail(); temporary_detail.episodes[#temporary_detail.episodes + 1] = temporary_episode
controller.runner:finish("client", temporary_detail)
check("verified_temporary_online_access_opens_complete_cache", controller.opening and controller:authorizeDescriptor(partial_descriptor) == true)
controller:_releaseOpening({ kind = "canceled" })
local end_anchor = { schema_version = 1, page_id = "source-1", index = 1, x = 0, y = 1 }
controller.account.store:putAnchor("10", "revision-1", end_anchor)
controller:_readerEvent("end_of_book", { descriptor = prepared.descriptor })
check("chapter_end_marks_local_progress_finished", controller.account.store:getAnchor("10", "revision-1").finished == true)
controller:_readerEvent("position", { descriptor = prepared.descriptor, anchor = Util.copy(end_anchor) })
check("later_native_anchor_keeps_finished_status", controller.account.store:getAnchor("10", "revision-1").finished == true)
local original_access = controller.account.store:getEpisode("10")
original_access.access, original_access.expires_at = "temporary", os.time() - 1
controller.account.store:upsertEpisodes("1", { original_access })
local allowed, denied = controller:authorizeDescriptor(prepared.descriptor)
check("direct_descriptor_open_rejects_expired_temporary_access", not allowed and denied.kind == "locked")
original_access.access, original_access.expires_at = "free", 0
controller.account.store:upsertEpisodes("1", { original_access })
controller:suspend(); network.connected = false
check("resume_waits_for_actual_connectivity", controller:resume() == false and controller.runner.suspended)
network.connected = true
check("network_connected_resumes_the_runner", controller:resume() == true and not controller.runner.suspended)

local function quote_result(episode_id)
    return { info = { ep_id = episode_id, comic_id = "1", ep_original_gold = 20, pay_gold = 20, remain_gold = 100, remain_coupon = 0,
        allow_coupon = false }, detail = detail() }
end
local quote
controller:quotePurchase("11", nil, nil, function(value, err) assert(value, err and err.kind); quote = value end)
controller.runner:finish("quote", quote_result("11"))
check("quote_build_is_local_after_worker_read", quote.submittable == true and quote.amount == 20
    and #controller.account.store:listPurchases() == 0)
local invalid_purposes_rejected, before_invalid_purpose = true, #controller.runner.order
for _index, purpose in ipairs({ "prefetch", "", false, {}, 42 }) do
    local rejected
    controller:purchase(quote, purpose, function(_value, err) rejected = err end); ui:drain()
    invalid_purposes_rejected = invalid_purposes_rejected and rejected and rejected.kind == "invalid_purpose"
end
check("invalid_purchase_purposes_are_rejected", invalid_purposes_rejected)
check("invalid_purpose_never_dispatches_quote_or_payment", #controller.runner.order == before_invalid_purpose
    and #controller.account.store:listPurchases() == 0)
local purchase_result
controller:purchase(quote, "download", function(value) purchase_result = value end)
check("confirmation_requires_fresh_quote_request", controller.runner:next("quote") and #controller.account.store:listPurchases() == 0)
controller.runner:finish("quote", quote_result("11"))
local durable_download = controller.account.store:getPurchase(controller.runner:next("purchase_submit").request.intent_id)
check("download_purpose_is_durable_before_submission", durable_download.purpose == "download"
    and durable_download.quote.scope.kind == "single" and #durable_download.episode_ids == 1)
controller.runner:finish("purchase_submit", nil, { kind = "timeout", transmitted = true })
check("uncertain_purchase_persists_without_retry", purchase_result.state == "outcome_unknown" and #controller:getPendingPurchases() == 1)
check("unknown_purchase_retains_original_download_purpose", controller:getPendingPurchases()[1].purpose == "download")
local purchase_count = 0
for _index, runner in ipairs(runners) do for _id, request in pairs(runner.requests) do
    if request.request.kind == "purchase_submit" then purchase_count = purchase_count + 1 end
end end
check("timeout_does_not_enqueue_another_buy", purchase_count == 0)
local reconciled
controller:reconcilePurchase(purchase_result.id, function(value) reconciled = value end)
controller.runner:finish("reconcile_purchase", { detail = detail(), wallet = { remain_gold = 80 } })
check("wallet_change_does_not_establish_access", reconciled.state == "outcome_unknown")
episodes[2].access = "owned"
controller:reconcilePurchase(purchase_result.id, function(value) reconciled = value end)
controller.runner:finish("reconcile_purchase", { detail = detail(), wallet_error = { kind = "network" } })
check("exact_entitlement_confirms_purchase_despite_wallet_failure", reconciled.state == "access_confirmed" and controller:getEpisode("11").access == "owned")
check("entitlement_only_confirmation_keeps_purpose_without_payment_receipt", reconciled.purpose == "download"
    and reconciled.transaction_evidence == "none" and #controller:getDownloads() == 0)
local download_jobs
controller:downloadEpisodes("1", { "11" }, function(value, err) assert(value, err and err.kind); download_jobs = value end)
ui:drain()
check("confirmed_download_requires_separate_explicit_enqueue", #download_jobs == 1 and download_jobs[1].episode_id == "11")
controller.runner:finish("client", { episode_id = "11", revision = "download-after-purchase",
    images = { { id = "purchase-image", index = 1, path = "/synthetic/paid-image.png", width = 20, height = 40 } } })
local download_request = controller.runner:next("download_page")
Files.write(download_request.request.temporary_path, Files.read(fixture))
controller.runner:finish("download_page", { temporary_path = download_request.request.temporary_path,
    width = 20, height = 40, format = "png", checksum = Files.digest(download_request.request.temporary_path) })
check("explicit_purchase_continuation_commits_a_real_offline_chapter", controller.account.store:getJob(download_jobs[1].id).state == "complete"
    and controller.account.pages:isComplete("11", "download-after-purchase") and controller.account.store:getPurchase(purchase_result.id).state == "access_confirmed")

controller:quotePurchase("12", nil, nil, function(value) quote = value end)
controller.runner:finish("quote", quote_result("12"))
local known_result
controller:purchase(quote, function(value) known_result = value end)
controller.runner:finish("quote", quote_result("12"))
check("legacy_purchase_callback_keeps_read_purpose", controller.account.store:getPurchase(controller.runner:next("purchase_submit").request.intent_id).purpose == "read")
local actual_transaction = controller.account.store.transaction
controller.account.store.transaction = function() error("Injected journal begin failure") end
controller.runner:finish("purchase_submit", { accepted = true })
controller.account.store.transaction = actual_transaction
check("known_response_survives_journal_begin_failure", known_result.state == "accepted" and known_result.persistence_pending
    and controller:getPendingPurchases()[1].persistence_pending)
controller:reconcilePurchase(known_result.id, function(value) reconciled = value end)
episodes[3].access = "owned"
controller.runner:finish("reconcile_purchase", { detail = detail(), wallet = { remain_gold = 60 } })
check("result_refresh_retries_persistence_without_rebuy", reconciled.state == "access_confirmed"
    and controller.account.pending_submission_results[known_result.id] == nil)
controller:quotePurchase("13", nil, nil, function(value) quote = value end)
controller.runner:finish("quote", quote_result("13"))
controller:purchase(quote, "download", function() end)
controller.runner:finish("quote", quote_result("13"))
local pending_id = controller.runner:next("purchase_submit").request.intent_id
local old_account, old_runner = controller.account, controller.runner
controller:refreshComic("1", function() error("Obsolete callback must not run") end)
local obsolete = controller.runner:next("client")
controller:importSession("SESSDATA=" .. secret .. "; DedeUserID=43", function(value) assert(value.account_key == "bili_43") end)
local validation
for identifier, pending in pairs(old_runner.requests) do
    if pending.request.method == "validateSession" then validation = pending; old_runner.requests[identifier] = nil; break end
end
assert(validation); validation.callback(validated("43")); ui:drain()
check("account_switch_closes_old_database_after_runner", old_runner.closed and old_account.store.connection == nil and controller.account.key == "bili_43")
obsolete.callback(detail()); ui:drain()
check("obsolete_account_callback_cannot_write_new_catalog", controller:getComic("1") == nil)
local reopened = Store.open{ root = old_account.root, account_key = old_account.key }
check("switch_recovers_interrupted_purchase_as_unknown", reopened:getPurchase(pending_id).state == "outcome_unknown")
check("account_reopen_preserves_durable_download_purpose", reopened:getPurchase(pending_id).purpose == "download")
reopened:close()
check("public_settings_keep_accounts_separate", controller.settings:get("active_account_key") == "bili_43"
    and Files.exists(output .. "/data/accounts/bili_42/session.dat") and Files.exists(output .. "/data/accounts/bili_43/session.dat"))
controller:close(); ui:drain()
check("controller_close_releases_account_and_runner", controller.closed and controller.account == nil)
local file = assert(io.open(output .. "/controller-result.json", "wb"))
file:write(json.encode({ assertions = checks, count = #checks }, { pretty = true })); file:close()
print(json.encode({ assertions = checks, count = #checks }, { pretty = true }))
