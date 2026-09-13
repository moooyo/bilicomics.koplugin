-- Product-scope integration using real controller/catalog/storage and delayed worker results.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local Controller = require("bilicomics/controller")
local ComicID = require("bilicomics/catalog/comic_id")
local Session = require("bilicomics/protocol/session")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local checks = {}
local function check(name, condition)
    checks[#checks + 1] = { name = name, passed = not not condition }
    assert(condition, name)
end
local ui = { queue = {} }
function ui:nextTick(fn) self.queue[#self.queue + 1] = fn end
function ui:scheduleIn() end
function ui:unschedule() end
function ui:show() end
function ui:close() end
function ui:drain()
    local maximum = 1000
    while #self.queue > 0 do maximum = maximum - 1; assert(maximum > 0); table.remove(self.queue, 1)() end
end
local runners = {}
local function runnerFactory()
    local runner = { tasks = {}, count = 0, canceled = {} }
    function runner:submit(request, options, callback)
        self.count = self.count + 1
        local identifier = "worker-" .. self.count
        self.tasks[identifier] = { id = identifier, request = request, options = options, callback = callback }
        return identifier
    end
    function runner:find(kind, method)
        for _, task in pairs(self.tasks) do if task.request.kind == kind and (not method or task.request.method == method) then return task end end
        error("No pending worker: " .. kind .. "/" .. tostring(method))
    end
    function runner:finish(task, value, err)
        self.tasks[task.id] = nil; task.callback(value, err); ui:drain()
    end
    function runner:cancel(identifier)
        local task = self.tasks[identifier]
        if task then self.tasks[identifier] = nil; self.canceled[identifier] = true; task.callback(nil, { kind = "canceled" }) end
    end
    function runner:close()
        self.closed = true
        local ids = {}; for identifier in pairs(self.tasks) do ids[#ids + 1] = identifier end
        for _, identifier in ipairs(ids) do self:cancel(identifier) end
    end
    function runner:promote() end
    function runner:resume() self.suspended = false end
    function runner:suspend() self.suspended = true end
    runners[#runners + 1] = runner
    return runner
end
local network = { connected = true }
function network:isConnected() return self.connected end
local app = Controller.new{ root = output .. "/data", ui_manager = ui, runner_factory = runnerFactory, network = network }
local function import(account_id)
    local session = assert(Session.parse("SESSDATA=synthetic-feature-session; DedeUserID=" .. account_id .. "; buvid3=synthetic-feature-device"))
    assert(session:withIdentity({ id = account_id, name = "Synthetic feature account" }))
    local complete
    app:importSession("SESSDATA=synthetic-feature-session; DedeUserID=" .. account_id, function(value, err) assert(value, err and err.kind); complete = value end)
    app.runner:finish(app.runner:find("client", "validateSession"), { session = session:serialize() })
    assert(complete)
end
import("42")
for input, expected in pairs({ ["1"] = "1", ["mc123"] = "123", [" MC000123 "] = "123", ["999999999999999"] = "999999999999999" }) do
    check("explicit_id_accepts_" .. input:gsub("%s", "_"), ComicID.parse(input) == expected)
end
local invalid_inputs = { "", "0", "mc0", "000", "-1", "+1", "1.5", "1e4", "mc 123", "Title 123",
    "https://example.invalid/mc123", "1234567890123456", string.rep(" ", 41) }
local before_invalid = app.runner.count
for index, input in ipairs(invalid_inputs) do
    local error
    app:lookupComicID(input, function(_value, err) error = err end); ui:drain()
    check("invalid_id_rejected_" .. index, ComicID.parse(input) == nil and error.kind == "invalid_comic_id")
end
check("invalid_ids_do_not_dispatch_workers", app.runner.count == before_invalid)
local lookup
app:lookupComicID("MC000123", function(value, err) assert(value, err and err.kind); lookup = value end)
local lookup_task = app.runner:find("client", "comicDetail")
check("explicit_lookup_uses_real_comic_detail_contract", lookup_task.request.arguments[1] == "123" and lookup == nil)
app.runner:finish(lookup_task, { comic = { id = "123", title = "Numeric lookup", favorite = false }, episodes = {} })
check("lookup_persists_exact_returned_comic", lookup.comic.id == "123" and app:getComic("123").title == "Numeric lookup")
local reading_target
app:resolveReadingEpisode("123", function(value, err) assert(value, err and err.kind); reading_target = value end)
check("following_read_fetches_unknown_catalog_asynchronously", app.runner:find("client", "comicDetail") ~= nil and reading_target == nil)
app.runner:finish(app.runner:find("client", "comicDetail"), { comic = { id = "123", title = "Numeric lookup" }, episodes = {
    { id = "100", comic_id = "123", order = 1, title = "First", access = "free" },
    { id = "102", comic_id = "123", order = 2, title = "Second", access = "owned" },
    { id = "101", comic_id = "123", order = 1.5, title = "Special", access = "locked" },
} })
check("new_comic_read_starts_at_first_ordered_chapter", reading_target.episode.id == "100")
app.account.store:upsertComic{ id = "123", current_episode_id = "100", last_episode_id = "100" }
app.account.store:upsertEpisodes("123", { { id = "100", order = 1, read = "complete" } })
local before_next = app.runner.count
app:resolveReadingEpisode("123", function(value) reading_target = value end); ui:drain()
check("finished_chapter_selects_fractional_next_without_skipping_lock", reading_target.episode.id == "101"
    and reading_target.episode.access == "locked" and app.runner.count == before_next)
app.account.store:upsertEpisodes("123", { { id = "100", order = 1, read = "reading" } })
app:resolveReadingEpisode("123", function(value) reading_target = value end); ui:drain()
check("unfinished_current_chapter_is_resumed", reading_target.episode.id == "100")
app:search("1984", function() end)
local search_task = app.runner:find("client", "search")
check("ordinary_numeric_title_stays_a_title_search", search_task.request.arguments[1] == "1984")
app.runner:finish(search_task, { { id = "9", title = "1984" } })

app:refreshLibrary("favorites", function() end)
local old_list = app.runner:find("library")
local changed
app:setFavorite("123", true, function(value, err) assert(value, err and err.kind); changed = value end)
local follow = app.runner:find("set_favorite")
check("follow_uses_explicit_nonpreemptible_worker", follow.request.comic_id == "123" and follow.request.favorite == true
    and follow.options.cancelable == false and app.account.read_requests[follow.id] == nil)
check("pending_follow_does_not_optimistically_change_library", app:isFavoritePending("123") and app:getComic("123").favorite == false)
local duplicate_error, before_duplicate = nil, app.runner.count
app:setFavorite("123", false, function(_value, err) duplicate_error = err end); ui:drain()
check("duplicate_follow_click_cannot_submit_another_request", duplicate_error.kind == "busy" and app.runner.count == before_duplicate)
app.runner:finish(follow, { accepted = true, comic_id = "123", favorite = true })
check("confirmed_follow_updates_favorite_and_clears_pending", changed.favorite == true and app:getComic("123").favorite == true and not app:isFavoritePending("123"))
app.runner:finish(old_list, {})
check("older_library_response_cannot_undo_confirmed_follow", app:getComic("123").favorite == true)
local failed_change
app:setFavorite("123", false, function(_value, err) failed_change = err end)
local failed_task = app.runner:find("set_favorite")
local before_failure = app.runner.count
app.runner:finish(failed_task, nil, { kind = "timeout" })
check("failed_unfollow_preserves_confirmed_favorite_without_retry", app:getComic("123").favorite == true
    and failed_change.kind == "timeout" and app.runner.count == before_failure)
app:setFavorite("123", false, function(_value, err) failed_change = err end)
app.runner:finish(app.runner:find("set_favorite"), {})
check("missing_server_acknowledgment_is_not_success", failed_change.kind == "protocol" and app:getComic("123").favorite == true)
app:setFavorite("123", false, function(value) changed = value end)
app.runner:finish(app.runner:find("set_favorite"), { accepted = true, comic_id = "123", favorite = false })
check("confirmed_unfollow_updates_only_membership", changed.favorite == false and app:getComic("123").title == "Numeric lookup" and #app:getLibrary("favorites") == 0)

check("reader_defaults_start_as_auto_ltr", app:getSetting("reading_mode") == "auto" and app:getSetting("reading_direction") == "ltr")
assert(app:setSetting("reading_mode", "strip")); assert(app:setSetting("reading_direction", "rtl"))
check("reader_service_reads_updated_defaults_through_getter", app.account.reader_services.settings:get("reading_mode", "auto") == "strip"
    and app.account.reader_services.settings:get("reading_direction", "ltr") == "rtl")
local saved, invalid_setting = app:setSetting("reading_mode", "unsupported")
check("unsupported_reader_enum_does_not_replace_saved_preference", not saved and invalid_setting.kind == "invalid_request" and app:getSetting("reading_mode") == "strip")

app:setFavorite("123", true, function(value) changed = value end)
local authorized_follow = app.runner:find("set_favorite")
app:refreshWallet(function() end)
app.runner:finish(app.runner:find("client", "wallet"), nil, { kind = "authentication" })
check("unrelated_auth_failure_does_not_cancel_authorized_follow", app.runner.tasks[authorized_follow.id] == authorized_follow and not app.runner.canceled[authorized_follow.id])
app.runner:finish(authorized_follow, { accepted = true, comic_id = "123", favorite = true })
check("inflight_follow_ack_survives_auth_failure_without_revalidating_session", changed.favorite == true and app.account.session_valid == false)
local diagnostics
app:getDiagnostics(function(value, err) assert(value, err and err.kind); diagnostics = value end)
local diagnostic_task = app.diagnostics_runner:find("diagnostics")
check("diagnostics_has_no_session_and_works_when_session_is_invalid", diagnostic_task.request.session == nil and app.account.session_valid == false)
app.diagnostics_runner:finish(diagnostic_task, { plugin_version = "0.1.0-dev", koreader_version = "v2026.07.1",
    platform = { os = "Linux", arch = "x64", target = "linux-x86_64", secret = "SESSDATA=diagnostic-secret" },
    capabilities = { request_signing = true, encrypted_images = false, image_tokens = "https://example.invalid/private", secret = true },
    raw = { Cookie = "SESSDATA=diagnostic-secret", url = "https://example.invalid/private" }, authenticated_integration = true, network_checked = true })
local encoded = json.encode(diagnostics)
check("diagnostics_returns_only_safe_typed_fields", not encoded:find("diagnostic%-secret") and not encoded:find("https://", 1, true)
    and diagnostics.raw == nil and diagnostics.capabilities.secret == nil and diagnostics.capabilities.image_tokens == nil)
check("local_capabilities_never_claim_live_server_verification", diagnostics.server_checked == false and diagnostics.local_session == "invalid"
    and diagnostics.capabilities.request_signing == true and diagnostics.authenticated_integration == nil)
app:getDiagnostics(function(value) diagnostics = value end)
app.diagnostics_runner:finish(app.diagnostics_runner:find("diagnostics"), { plugin_version = "https://example.invalid/private", koreader_version = "v1.0-session-token",
    platform = { os = "SESSDATA=diagnostic-secret", arch = "https://example.invalid/private" }, capabilities = {} })
check("diagnostic_strings_reject_urls_and_credential_markers", diagnostics.plugin_version == "unknown" and diagnostics.koreader_version == "unknown"
    and diagnostics.platform.os == "unknown" and diagnostics.platform.arch == "unknown")
app.settings:set("reading_mode", "https://example.invalid/private")
app.settings:set("reading_direction", "SESSDATA=diagnostic-secret")
app:getDiagnostics(function(value) diagnostics = value end)
app.diagnostics_runner:finish(app.diagnostics_runner:find("diagnostics"), { capabilities = {} })
encoded = json.encode(diagnostics)
check("diagnostic_reader_defaults_normalize_untrusted_disk_settings", diagnostics.reader_defaults.reading_mode == "auto"
    and diagnostics.reader_defaults.reading_direction == "ltr" and not encoded:find("diagnostic%-secret")
    and not encoded:find("https://", 1, true))
assert(app:setSetting("reading_mode", "strip")); assert(app:setSetting("reading_direction", "rtl"))
app:suspend(); network.connected = false; app:resume()
app:getDiagnostics(function(value) diagnostics = value end)
check("offline_resume_allows_local_diagnostics_without_resuming_network_queue", app.runner.suspended == true
    and app.diagnostics_runner ~= app.runner and app.diagnostics_runner.suspended == false and app.diagnostics_runner:find("diagnostics").request.session == nil)
app.diagnostics_runner:finish(app.diagnostics_runner:find("diagnostics"), { plugin_version = "0.1.0-dev", capabilities = {} })
network.connected = true; app:resume()

import("42")
app:setFavorite("123", false, function() error("An obsolete account callback must not reach the UI") end)
local stale_follow, old_account = app.runner:find("set_favorite"), app.account
import("43")
stale_follow.callback({ accepted = true, comic_id = "123", favorite = false }); ui:drain()
check("old_account_follow_result_cannot_modify_new_account", app.account.key == "bili_43" and app:getComic("123") == nil and old_account.store.connection == nil)
app:close(); ui:drain()
Files.write(output .. "/product-features-result.json", json.encode({ assertions = checks, count = #checks,
    scope = "Production controller/catalog/SQLite; explicitly controlled asynchronous worker results" }, { pretty = true }))
print(json.encode({ assertions = checks, count = #checks }, { pretty = true }))
