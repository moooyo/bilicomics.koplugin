-- Construct and exercise actual KOReader widgets in an isolated remote runtime.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local root, plugin = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local gettext = require("gettext")
gettext.current_lang = "zh_CN"
local UIManager = require("ui/uimanager")
local json = require("rapidjson")
local Screens = require("bilicomics/ui/screens")
local Model = require("bilicomics/ui/model")
local Widgets = require("bilicomics/ui/widgets")
local _ = require("bilicomics/ui/i18n")
local output = { runtime = "KOReader v2026.07.1", assertions = {}, screens = {} }
local function check(name, condition, detail)
    output.assertions[#output.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
local controller = { calls = {}, settings = {}, waiting = {}, purchases = {}, comics = {}, episodes = {}, wallet = { remain_gold = 80, remain_coupon = 2 } }
for index = 1, 10 do
    controller.comics[index] = { id = tostring(index), title = "Synthetic comic " .. index, authors = { "Test Author" },
        current_episode_id = "2", latest_episode_title = "Latest chapter 17", finished = index % 2 == 0,
        has_update = index % 2 == 1, reading_position = { page = 4 } }
end
for index = 1, 17 do
    controller.episodes[index] = { id = tostring(index), comic_id = "1", order = index,
        title = "Chapter " .. index, access = index <= 3 and "free" or index <= 7 and "owned" or "locked",
        read = index == 1, downloaded = index == 3, cached_pages = index == 2 and 3 or 0, total_pages = 12 }
end
controller.episodes[7].access, controller.episodes[7].offline_allowed = "temporary", false
controller.jobs = {
    { id = "one", kind = "episode_download", comic_id = "1", episode_id = "2", revision = "synthetic", state = "running", completed = 3, total = 12 },
    { id = "two", kind = "episode_download", comic_id = "1", episode_id = "3", state = "complete", completed = 12, total = 12 },
}
function controller:getAccount() return { id = "test", account_key = self.account_key or "bili_test", name = "Synthetic test account", session_valid = true } end
function controller:getLibrary() return self.comics end
function controller:getComic(id) return self.comics[tonumber(id)] end
function controller:getEpisodes() return self.episodes end
function controller:getDownloads() return self.jobs end
function controller:getWallet() return self.wallet end
function controller:getPendingPurchases() return self.purchases end
function controller:getSetting(key, default) local value = self.settings[key]; if value == nil then return default end; return value end
function controller:setSetting(key, value) self.settings[key] = value end
function controller:getStorageSummary() return { automatic_bytes = 2048000, pinned_bytes = 10485760 } end
function controller:clearAutomaticCache() self.calls.cache = true; return true end
function controller:enqueue(method, args, callback)
    self.calls[#self.calls + 1] = { method = method, args = args }
    self.waiting[#self.waiting + 1] = { method = method, callback = callback }
end
function controller:refreshLibrary(kind, cb) self:enqueue("refreshLibrary", { kind }, cb) end
function controller:refreshComic(id, cb) self:enqueue("refreshComic", { id }, cb) end
function controller:lookupComicID(value, cb) self:enqueue("lookupComicID", { value }, cb) end
function controller:resolveReadingEpisode(id, cb) self:enqueue("resolveReadingEpisode", { id }, cb) end
function controller:isFavoritePending(id) return self.follow_pending and self.follow_pending[tostring(id)] == true end
function controller:setFavorite(id, favorite, cb)
    self.follow_pending = self.follow_pending or {}; self.follow_pending[tostring(id)] = true
    self:enqueue("setFavorite", { id, favorite }, function(value, err)
        self.follow_pending[tostring(id)] = nil
        if value and value.accepted then self.comics[tonumber(id)].favorite = favorite end
        cb(value, err)
    end)
end
function controller:getDiagnostics(cb) self:enqueue("getDiagnostics", {}, cb) end
function controller:search(query, cb) self:enqueue("search", { query }, cb) end
function controller:readEpisode(comic_id, episode_id, cb) self:enqueue("readEpisode", { comic_id, episode_id }, cb) end
function controller:downloadEpisodes(comic_id, ids, cb) self:enqueue("downloadEpisodes", { comic_id, ids }, cb) end
function controller:removeDownload(id, cb) self:enqueue("removeDownload", { id }, cb) end
function controller:refreshWallet(cb) self:enqueue("refreshWallet", {}, cb) end
function controller:importSession(value, cb) self:enqueue("importSession", { value }, cb) end
function controller:quotePurchase(id, scope, payment, cb) self:enqueue("quotePurchase", { id, scope, payment }, cb) end
function controller:purchase(quote, purpose, cb) self:enqueue("purchase", { quote, purpose }, cb) end
function controller:reconcilePurchase(id, cb) self:enqueue("reconcilePurchase", { id }, cb) end
function controller:pauseJob(id) self.jobs[1].state = "paused"; self.calls.pause = id end
function controller:resumeJob(id) self.jobs[1].state = "running"; self.calls.resume = id end
function controller:cancelJob(id) self.jobs[1].state = "canceled"; self.calls.cancel = id end
local function finish(value, error)
    local waiting = assert(table.remove(controller.waiting, 1), "No pending callback")
    waiting.callback(value, error)
end
local screens = Screens.new{ controller = controller }
local ImageWidget = require("ui/widget/imagewidget")
local oversized_header = require("bilicomics/storage/image_header").read(root .. "/oversized-cover.png")
check("oversized_cover_fixture_is_a_real_six_megapixel_png", oversized_header.format == "png" and oversized_header.width * oversized_header.height == 6000000)
local image_new, image_constructed = ImageWidget.new, 0
ImageWidget.new = function(...)
    image_constructed = image_constructed + 1
    return image_new(...)
end
local oversized_cover = Widgets.cover({ title = "Oversized synthetic cover", cover_path = root .. "/oversized-cover.png" }, 80, 120)
oversized_cover:getSize()
ImageWidget.new = image_new
check("oversized_cached_cover_never_reaches_image_widget", image_constructed == 0)
local function press(message)
    for _index, row in ipairs(screens.focus) do
        for _index, button in ipairs(row) do
            if button.text == _(message) and button.callback and button.enabled ~= false then button.callback(); return end
        end
    end
    error("Button not found: " .. message)
end
local function dialog_button(message)
    for _index, row in ipairs(screens.dialog.buttons) do
        for _index, button in ipairs(row) do
            if button.text == _(message) then return button end
        end
    end
    error("Dialog button not found: " .. message)
end
local function dialog_press(message)
    local button = dialog_button(message)
    assert(button.enabled ~= false, "Button disabled"); button.callback()
end
local function capture(name)
    local widget = assert(screens.widget)
    local size = widget.content:getSize()
    check(name .. "_fits_screen", size.w <= Device.screen:getWidth() and size.h <= Device.screen:getHeight(), size)
    UIManager:forceRePaint()
    if screens.dialog and screens.dialog.movable then
        local modal_size = screens.dialog.movable:getSize()
        check(name .. "_dialog_fits_screen", modal_size.w <= Device.screen:getWidth() and modal_size.h <= Device.screen:getHeight(), modal_size)
    end
    Device.screen.bb:writePNG(root .. "/" .. name .. ".png")
    output.screens[#output.screens + 1] = name .. ".png"
end

screens:showLibrary()
capture("continue")
check("continue_has_prominent_resume", screens.pages > 1)
press("Resume reading")
check("reading_uses_async_controller", controller.waiting[1].method == "readEpisode")
finish(nil, { kind = "network" })
check("network_failure_is_actionable", screens.dialog.title:find(_("Connection failed"), 1, true) ~= nil)
check("async_error_dialog_stays_above_refreshed_screen", UIManager:getTopmostVisibleWidget() == screens.dialog)
screens:_closeDialog()
screens:showLibrary("favorites")
capture("following")
controller.episodes[2].read = "complete"
controller.episodes[3].access, controller.episodes[3].downloaded = "locked", false
screens:refresh(); press("Read next")
check("following_card_has_direct_read_action", controller.waiting[1].method == "resolveReadingEpisode")
finish({ comic = controller.comics[1], episode = controller.episodes[3] })
check("locked_next_chapter_enters_quote_instead_of_read_or_purchase", controller.waiting[1].method == "quotePurchase")
finish(nil, { kind = "capability" }); screens:_closeDialog()
controller.episodes[2].read = false
controller.episodes[3].access, controller.episodes[3].downloaded = "free", true
press("All")
check("following_filter_changes", screens.filter == "updated")
screens:showComic("1")
finish(true)
capture("chapters")
press("Follow")
check("follow_click_waits_for_server_confirmation", controller.comics[1].favorite ~= true and controller:isFavoritePending("1"))
local follow_disabled = false
for _index, row in ipairs(screens.focus) do for _index, button in ipairs(row) do
    if button.text == _("Updating follow…") then follow_disabled = button.enabled == false end
end end
check("pending_follow_button_prevents_repeat_clicks", follow_disabled)
capture("follow-pending")
finish({ accepted = true })
check("server_confirmation_updates_follow_action", controller.comics[1].favorite == true and not controller:isFavoritePending("1"))
press("Unfollow")
finish(nil, { kind = "network" })
check("failed_unfollow_keeps_confirmed_state", controller.comics[1].favorite == true)
screens:_closeDialog()
check("chapter_three_axes", Model.reading(controller.episodes[3]) == _("Unread")
    and Model.entitlement(controller.episodes[3]) == _("Free") and Model.storage(controller.episodes[3]) == _("Downloaded"))
press("Select downloads")
press("Select downloadable")
check("locked_and_online_only_chapters_never_selected", screens.selected["6"] and not screens.selected["7"] and not screens.selected["8"] and not screens.selected["17"])
capture("download-selection")
press(string.format(_("Download selected (%d)"), 6))
check("selection_dispatches_exact_ids", #controller.calls[#controller.calls].args[2] == 6)
finish(true)
capture("downloads")
press("Pause")
check("pause_calls_controller", controller.calls.pause == "one")
press("Resume")
check("resume_calls_controller", controller.calls.resume == "one")
controller.jobs[1].state, controller.jobs[1].error = "failed", { kind = "authentication" }
screens:refresh()
press("Failure details")
check("download_failure_exposes_login_recovery", screens.dialog.title:find(_("Sign in required"), 1, true) ~= nil)
screens:_closeDialog()
controller.jobs[1].state, controller.jobs[1].error = "running", nil
screens:refresh()
press("Remove download")
check("remove_download_requires_confirmation", #controller.waiting == 0 and screens.dialog.ok_callback ~= nil)
screens.dialog.ok_callback()
check("remove_download_uses_async_controller", controller.waiting[1].method == "removeDownload")
check("partial_download_can_be_removed", controller.calls[#controller.calls].args[1] == "one")
finish(true)
screens:_closeDialog()
screens:showAccount()
capture("account")
controller.purchases = { { id = "layout-pending", state = "outcome_unknown" } }
screens:refresh(); capture("account-pending")
controller.purchases = {}; screens:refresh()
press("Reader defaults")
dialog_press("[ ] " .. _("Long strip"))
dialog_press("[ ] " .. _("Right to left"))
check("reader_default_controls_persist_exact_enums", controller.settings.reading_mode == "strip" and controller.settings.reading_direction == "rtl")
capture("reader-defaults")
dialog_press("Close")
press("Local diagnostics")
check("diagnostics_uses_async_controller", controller.waiting[1].method == "getDiagnostics")
local diagnostics = { plugin_version = "0.1.0-dev", koreader_version = "v2026.07.1",
    platform = { os = "Linux", arch = "x64", target = "linux-x86_64" }, local_session = "stored", credential_storage = "account_storage",
    capabilities = { request_signing = true, response_decoding = true, image_index = true, image_tokens = false, encrypted_images = true } }
finish(diagnostics)
check("diagnostics_explains_local_verification_boundary", screens.dialog.text:find(_("These local checks do not verify the Bilibili service, account access, image retrieval or purchases."), 1, true) ~= nil)
capture("local-diagnostics")
screens:_closeDialog()
press("Local diagnostics"); screens:_closeDialog(); finish(diagnostics)
check("closed_diagnostic_request_does_not_reopen_dialog", screens.dialog == nil)
press(string.format(_("Preload next images: %d"), 3))
check("prefetch_setting_persists", controller.settings.prefetch_pages == 5)
press("Replace session")
check("session_input_is_private", screens.dialog._input_widget.is_password_type == true)
screens.dialog._input_widget:setText("synthetic-secret")
check("session_render_masks_characters", screens.dialog._input_widget.text_widget.text ~= "synthetic-secret")
screens:_closeDialog()
screens:showSearch()
capture("search")
press("Open by comic ID")
screens.dialog._input_widget:setText("mc1")
capture("comic-id-input")
dialog_press("Open comic")
check("id_lookup_is_explicit_and_separate_from_title_search", controller.waiting[1].method == "lookupComicID" and controller.calls[#controller.calls].args[1] == "mc1")
finish({ comic = controller.comics[1], episodes = controller.episodes })
check("id_lookup_opens_returned_details_without_second_refresh", screens.route == "comic" and screens.comic_id == "1" and #controller.waiting == 0)
screens:showSearch()
press("Open by comic ID"); screens.dialog._input_widget:setText("mc1"); dialog_press("Open comic")
press("Open by comic ID"); screens.dialog._input_widget:setText("mc2"); dialog_press("Open comic")
finish({ comic = controller.comics[1], episodes = controller.episodes })
check("older_id_response_does_not_override_latest_query", screens.route == "search")
finish({ comic = controller.comics[2], episodes = controller.episodes })
check("latest_id_response_opens_requested_comic", screens.route == "comic" and screens.comic_id == "2")
screens:showComic("1")
screens:_purchaseFor(controller.comics[1], controller.episodes[8])
check("quote_is_async", controller.waiting[1].method == "quotePurchase")
local quote = { id = "quote", episode_id = "8", comic_id = "1", episode_ids = { "8" },
    scope = { kind = "single" }, payment = { method = "coin" }, method = "coin", amount = 20, balance = 80,
    can_afford = true, fingerprint = "quote-test", expected_access = { ["8"] = { access = "owned" } },
    scopes = { { kind = "single" }, { kind = "batch", batch_limit = 3 } },
    payments = { { method = "coin", available = true }, { method = "coupon", available = true } } }
finish(quote)
capture("purchase")
dialog_press(string.format(_("Batch %s"), "3"))
check("batch_selection_requests_a_new_server_quote", controller.calls[#controller.calls].args[2].kind == "batch"
    and controller.calls[#controller.calls].args[2].batch_limit == 3)
local batch_quote = {}
for key, value in pairs(quote) do batch_quote[key] = value end
batch_quote.episode_ids, batch_quote.scope, batch_quote.amount = { "8", "9", "10" }, { kind = "batch", batch_limit = 3 }, 51
batch_quote.expected_access = { ["8"] = { access = "owned" }, ["9"] = { access = "owned" }, ["10"] = { access = "owned" } }
finish(batch_quote)
check("batch_uses_returned_total", screens.purchase_state.quote.amount == 51 and #screens.purchase_state.quote.episode_ids == 3)
capture("purchase-batch")
check("quote_shows_permanent_access", screens.dialog.title:find(_("Permanent ownership"), 1, true) ~= nil)
screens:_quote(nil, nil)
check("quote_refresh_preserves_selected_scope", controller.calls[#controller.calls].args[2].kind == "batch")
finish(batch_quote)
dialog_press("Single chapter")
finish(quote)
dialog_press(string.format(_("Confirm purchase · %s %s"), "20", _("coins")))
check("purchase_is_async", controller.waiting[1].method == "purchase")
check("read_purchase_passes_explicit_read_purpose", controller.calls[#controller.calls].args[2] == "read")
local frozen = true
for _index, row in ipairs(screens.dialog.buttons) do for _index, button in ipairs(row) do
    if button.enabled ~= false then frozen = false end
end end
check("purchase_freezes_scope_payment_and_submission", frozen)
local intent = { id = "intent", state = "outcome_unknown", episode_ids = { "8" }, comic_id = "1", quote = quote,
    purpose = "read", transaction_evidence = "none" }
controller.purchases = { intent }
finish(intent)
capture("purchase-unknown")
local no_buy = true
for _index, row in ipairs(screens.dialog.buttons) do for _index, button in ipairs(row) do
    if button.text:find(_("Confirm purchase · %s %s"):match("^(.-)%%"), 1, true) then no_buy = false end
end end
check("unknown_result_has_no_repeat_purchase", no_buy)
screens:_closeDialog()
screens:_purchaseFor(controller.comics[1], controller.episodes[8])
check("reopened_purchase_preserves_pending_intent", screens.purchase_state.intent.id == "intent" and #controller.waiting == 0)
dialog_press("Refresh result")
check("pending_action_reconciles", controller.waiting[1].method == "reconcilePurchase")
intent.state = "access_confirmed"; controller.purchases = {}
finish(intent)
capture("purchase-confirmed")
check("entitlement_only_result_does_not_claim_confirmed_payment", screens.dialog.title:find(_("Chapter access confirmed"), 1, true)
    and not screens.dialog.title:find(_("Purchase confirmed"), 1, true))
intent.quote, intent.episode_ids = batch_quote, { "9", "8", "10" }
screens:_purchaseDialog(); dialog_press("Read chapter")
check("read_continuation_uses_the_original_selected_chapter", controller.calls[#controller.calls].method == "readEpisode"
    and controller.calls[#controller.calls].args[2] == "8")
finish(nil, { kind = "network" })
screens:_closeDialog()
screens:_purchaseFor(controller.comics[1], controller.episodes[9])
quote.can_afford, quote.balance = false, 5
finish(quote)
capture("purchase-low-balance")
check("low_balance_has_refresh_without_purchase", screens.dialog.title:find(_("Insufficient balance"), 1, true) ~= nil)
screens:_closeDialog()
screens:_purchaseFor(controller.comics[1], controller.episodes[10])
screens:_closeDialog()
finish(quote)
check("dismissed_quote_does_not_reopen", screens.dialog == nil)

screens:showComic("1"); screens.descending = true; screens:refresh()
capture("locked-download-action")
press("Buy then download")
local download_episode_id = controller.calls[#controller.calls].args[1]
check("locked_download_entry_quotes_only_the_selected_single_chapter", screens.purchase_state.purpose == "download"
    and controller.calls[#controller.calls].method == "quotePurchase" and controller.calls[#controller.calls].args[2].kind == "single")
local download_quote = {}
for key, value in pairs(quote) do download_quote[key] = value end
download_quote.id, download_quote.episode_id, download_quote.episode_ids = "download-quote", download_episode_id, { download_episode_id }
download_quote.fingerprint, download_quote.can_afford, download_quote.balance = "download-coin", true, 80
download_quote.expected_access = { [download_episode_id] = { access = "owned" } }
finish(download_quote)
check("download_purpose_is_visible_before_payment_confirmation", screens.dialog.title:find(_("Next action: download this chapter"), 1, true) ~= nil)
local offers_batch = false
for _index, row in ipairs(screens.dialog.buttons) do for _index, button in ipairs(row) do
    if button.text == string.format(_("Batch %s"), "3") then offers_batch = true end
end end
check("single_download_entry_never_offers_a_batch_purchase", not offers_batch)
capture("purchase-download")
local obsolete_confirmation = dialog_button(string.format(_("Confirm purchase · %s %s"), "20", _("coins"))).callback
dialog_press("[ ] " .. _("coupons"))
local before_obsolete_confirmation = #controller.calls
obsolete_confirmation()
check("changing_payment_invalidates_the_previous_confirmation_button", #controller.calls == before_obsolete_confirmation
    and controller.waiting[1].method == "quotePurchase")
local coupon_quote = {}
for key, value in pairs(download_quote) do coupon_quote[key] = value end
coupon_quote.payment, coupon_quote.method, coupon_quote.amount, coupon_quote.balance = { method = "coupon" }, "coupon", 1, 2
coupon_quote.fingerprint = "download-coupon"
finish(coupon_quote)
dialog_press(string.format(_("Confirm purchase · %s %s"), "1", _("coupons")))
check("explicit_download_purchase_freezes_and_passes_its_purpose", controller.calls[#controller.calls].args[2] == "download")
local download_intent = { id = "download-intent", state = "outcome_unknown", episode_ids = { download_episode_id }, comic_id = "1",
    quote = coupon_quote, purpose = "download", transaction_evidence = "none" }
controller.purchases = { download_intent }
finish(download_intent)
check("unknown_download_result_has_no_automatic_acquisition", #controller.waiting == 0)
screens:_closeDialog()
screens:_pendingList(controller.purchases)
dialog_press(string.format(_("Refresh purchase %s"), download_intent.id))
check("pending_list_restores_the_durable_download_purpose", screens.purchase_state.purpose == "download")
screens:_closeDialog()
screens:_purchaseFor(controller.comics[1], controller.episodes[tonumber(download_episode_id)], "read")
check("read_entry_cannot_replace_an_existing_download_intent", screens.purchase_state.purpose == "download" and #controller.waiting == 0)
dialog_press("Refresh result")
download_intent.state = "access_confirmed"; controller.purchases = {}
finish(download_intent)
capture("download-access-confirmed")
check("confirmed_download_waits_for_explicit_continuation", #controller.waiting == 0
    and dialog_button("Download chapter") and screens.dialog.title:find(_("Chapter access confirmed"), 1, true))
local continue_download = dialog_button("Download chapter").callback
continue_download()
local after_download_click = #controller.calls
continue_download()
check("download_continuation_queues_only_its_original_chapter_once", #controller.calls == after_download_click
    and controller.calls[#controller.calls].method == "downloadEpisodes" and #controller.calls[#controller.calls].args[2] == 1
    and controller.calls[#controller.calls].args[2][1] == download_episode_id)
finish(nil, { kind = "network" })
check("download_failure_keeps_confirmed_access_and_has_no_new_quote", screens.purchase_state.intent.state == "access_confirmed"
    and screens.purchase_state.error == nil and dialog_button("Retry download") and #controller.waiting == 0)
capture("download-continuation-retry")
dialog_press("Retry download"); finish(true)
check("successful_continuation_opens_downloads", screens.route == "downloads")
local before_stale_continuation = #controller.calls
continue_download()
check("navigation_retires_the_old_continuation_button", #controller.calls == before_stale_continuation)

download_intent.state = "outcome_unknown"; controller.purchases = { download_intent }
screens:_purchaseFor(controller.comics[1], controller.episodes[tonumber(download_episode_id)])
dialog_press("Refresh result")
screens:showLibrary()
local before_closed_result = #controller.calls
download_intent.state, download_intent.transaction_evidence = "access_confirmed", "server_accepted"; controller.purchases = {}
finish(download_intent)
check("closed_result_callback_neither_reopens_nor_downloads", screens.dialog == nil and screens.route == "continue" and #controller.calls == before_closed_result)
screens:_purchaseFor(controller.comics[1], controller.episodes[tonumber(download_episode_id)], "download")
finish(download_quote)
local account_confirmation = dialog_button(string.format(_("Confirm purchase · %s %s"), "20", _("coins"))).callback
controller.account_key = "bili_other"
local before_changed_account = #controller.calls
account_confirmation()
check("account_switch_retires_a_displayed_purchase_confirmation", #controller.calls == before_changed_account)
controller.account_key = nil
screens:_closeDialog()
screens:_purchaseFor(controller.comics[1], controller.episodes[tonumber(download_episode_id)], "download")
finish(download_quote)
dialog_press(string.format(_("Confirm purchase · %s %s"), "20", _("coins")))
finish(download_intent)
check("server_accepted_evidence_can_display_confirmed_purchase", screens.dialog.title:find(_("Purchase confirmed"), 1, true) ~= nil)
local account_continuation = dialog_button("Download chapter").callback
controller.account_key = "bili_other"
before_changed_account = #controller.calls
account_continuation()
check("account_switch_retires_a_displayed_download_continuation", #controller.calls == before_changed_account)
controller.account_key = nil
screens:_closeDialog()
screens:showLibrary()
press("Refresh library")
screens:close()
finish(true)
check("stale_callback_does_not_reopen_closed_ui", screens.widget == nil and screens.route == nil)
local file = assert(io.open(root .. "/result.json", "wb"))
file:write(json.encode(output, { pretty = true })); file:close()
print(json.encode(output, { pretty = true }))
