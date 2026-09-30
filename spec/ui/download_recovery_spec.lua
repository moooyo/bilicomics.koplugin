-- Exercise native download recovery widgets with an allowlisted fake controller.
-- This file never loads the production controller or sends business requests.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local output_dir, plugin = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
for _module_index, name in ipairs({ "bilicomics/controller", "bilicomics/runtime", "bilicomics/protocol/client",
    "bilicomics/protocol/transport", "bilicomics/purchase/service" }) do
    assert(package.loaded[name] == nil, "A production business module was already loaded")
    package.preload[name] = function() error("Production business modules are forbidden in this UI spec") end
end
require("gettext").current_lang = "zh_CN"
local UIManager = require("ui/uimanager")
local json = require("rapidjson")
local Screens = require("bilicomics/ui/screens")
local Model = require("bilicomics/ui/model")
local _ = require("bilicomics/ui/i18n")

local report = { spec = "native-download-recovery", runtime = "KOReader v2026.07.1",
    width = Device.screen:getWidth(), height = Device.screen:getHeight(),
    injected_controller = true, network_requests = 0, assertions = {}, screens = {} }
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
local function contains(text, fragment)
    return type(text) == "string" and text:find(fragment, 1, true) ~= nil
end
local function hasChinese(text)
    return type(text) == "string" and text:find("[\228-\233][\128-\191][\128-\191]") ~= nil
end
local markers = { "https://unsafe.invalid", "/private/source.bin", "SDK_SECRET", "raw-token-value" }
local function safeText(text)
    for _marker_index, marker in ipairs(markers) do if contains(text, marker) then return false end end
    return true
end
local function rawError(kind, status)
    return { kind = kind, status = status,
        message = "SDK_SECRET https://unsafe.invalid/image?token=raw-token-value /private/source.bin",
        path = "/private/source.bin", url = "https://unsafe.invalid/image?token=raw-token-value",
        sdk = "SDK_SECRET", raw = { token = "raw-token-value" } }
end

local allowed = { getDownloads = true, getComic = true, getEpisode = true, getEpisodes = true,
    getStorageSummary = true, getAccount = true, resumeJob = true, pauseJob = true,
    cancelJob = true, removeDownload = true, refreshDownloadSources = true, cancelSourceRefresh = true }
local controller = { jobs = {}, calls = {}, waiting = {}, forbidden = {}, generation = 1,
    account_key = "bili_ui_fixture_a", account = { key = "bili_ui_fixture_a" },
    comic = { id = "10", title = "Synthetic recovery comic" },
    episode = { id = "20", comic_id = "10", title = "Synthetic chapter", access = "owned" } }
local function record(method, job_id)
    assert(allowed[method], "Unexpected controller operation")
    controller.calls[#controller.calls + 1] = { method = method, job_id = job_id }
end
local function currentJob(job_id)
    for _job_index, job in ipairs(controller.jobs) do if job.id == job_id then return job end end
end
function controller:getDownloads() record("getDownloads"); return self.jobs end
function controller:getComic() record("getComic"); return self.comic end
function controller:getEpisode() record("getEpisode"); return self.episode end
function controller:getEpisodes() record("getEpisodes"); return { self.episode } end
function controller:cancelPendingRead() end
function controller:getAccount()
    record("getAccount")
    return { id = "ui_fixture", account_key = self.account_key, session_valid = true }
end
function controller:getStorageSummary()
    record("getStorageSummary")
    return { automatic_bytes = 1048576, pinned_bytes = 2097152 }
end
function controller:resumeJob(job_id)
    record("resumeJob", job_id)
    local job = assert(currentJob(job_id))
    if self.resume_error then job.state, job.error = "failed", self.resume_error; return nil, self.resume_error end
    job.state, job.error = "running", nil
    return true
end
function controller:pauseJob(job_id)
    record("pauseJob", job_id); assert(currentJob(job_id)).state = "paused"; return true
end
function controller:cancelJob(job_id)
    record("cancelJob", job_id); assert(currentJob(job_id)).state = "canceled"; return true
end
function controller:refreshDownloadSources(job_id, callback)
    record("refreshDownloadSources", job_id)
    local job = assert(currentJob(job_id))
    assert(not job.payload.source_refresh, "An active verification must not be submitted twice")
    job.payload.source_refresh = { stage = "index", checked = 0, total = 4 }
    self.waiting[#self.waiting + 1] = { method = "refreshDownloadSources", job_id = job_id, callback = callback }
end
function controller:cancelSourceRefresh(job_id)
    record("cancelSourceRefresh", job_id)
    local job = currentJob(job_id)
    if job then job.payload.source_refresh = nil; job.state = "paused" end
    return true
end
function controller:removeDownload(job_id, callback)
    record("removeDownload", job_id)
    local job = assert(currentJob(job_id))
    check("removal_dispatch_has_no_active_verification", job.payload.source_refresh == nil)
    self.waiting[#self.waiting + 1] = { method = "removeDownload", job_id = job_id, callback = callback }
end
setmetatable(controller, { __index = function(_controller, key)
    if key == "replaceDownloadVersion" or key == "getBookshelfSyncState" then return nil end
    controller.forbidden[#controller.forbidden + 1] = tostring(key)
    error("Controller member is outside the download recovery allowlist: " .. tostring(key))
end })

local screens = Screens.new{ controller = controller }
local function callCount(method)
    local count = 0
    for _call_index, call in ipairs(controller.calls) do if call.method == method then count = count + 1 end end
    return count
end
local function finish(method, value, err)
    for index, request in ipairs(controller.waiting) do
        if request.method == method then
            table.remove(controller.waiting, index)
            request.callback(value, err)
            return request
        end
    end
    error("No fake callback is waiting for " .. method)
end
local function findButton(widget, text, seen)
    if type(widget) ~= "table" then return end
    seen = seen or {}
    if seen[widget] then return end
    seen[widget] = true
    if widget.text == text and type(widget.callback) == "function" then return widget end
    for _child_index, child in ipairs(widget) do
        local result = findButton(child, text, seen)
        if result then return result end
    end
end
local function screenButton(message)
    for _row_index, row in ipairs(screens.focus or {}) do
        for _button_index, button in ipairs(row) do if button.text == _(message)
            or button.text == _(message) .. " ›" then return button end end
    end
end
local function press(message)
    local button = assert(screenButton(message), "Missing screen button: " .. message)
    assert(button.enabled ~= false and button.callback, "The requested screen button is disabled")
    button.callback()
end
local function dialogShown()
    return screens.dialog ~= nil and UIManager:isWidgetShown(screens.dialog)
end
local function pressDialogText(text)
    local dialog = assert(screens.dialog, "No dialog is open")
    assert(UIManager:isWidgetShown(dialog), "The dialog is not in the native window stack")
    local button = assert(findButton(dialog, text), "Missing native dialog button")
    assert(button.enabled ~= false, "The requested dialog button is disabled")
    button.callback()
end
local function pressDialog(message) pressDialogText(_(message)) end
local function confirmationButton(dialog, column)
    local specs = assert(dialog.buttons and dialog.buttons[#dialog.buttons], "Expected confirmation actions")
    local spec = assert(specs[column], "The confirmation action is absent")
    local button = findButton(dialog, spec.text)
    while not button and dialog.page and dialog.page < dialog.pages do
        dialog:onNextPage(); button = findButton(dialog, spec.text)
    end
    return assert(button, "The native confirmation action is not reachable")
end
local function pressAction(message)
    if screenButton(message) then press(message); return end
    press("More actions")
    check("more_actions_opens_a_visible_native_menu", dialogShown())
    check("more_actions_distinguishes_stopping_from_removing", contains(screens.dialog.download_text,
        _("Stopping keeps saved images. Removing deletes this copy's saved images.")))
    pressDialog(message)
end
local function confirm()
    local dialog = assert(screens.dialog)
    local submit = confirmationButton(dialog, 2)
    pressDialogText(submit.text)
end
local function cancelConfirm()
    local dialog = assert(screens.dialog)
    local cancel = confirmationButton(dialog, 1)
    pressDialogText(cancel.text)
end
local function visibleText(widget, result, seen)
    result, seen = result or {}, seen or {}
    if type(widget) ~= "table" or seen[widget] then return table.concat(result, "\n") end
    seen[widget] = true
    if type(widget.text) == "string" then result[#result + 1] = widget.text end
    if type(widget.title) == "string" then result[#result + 1] = widget.title end
    if type(widget.download_text) == "string" then result[#result + 1] = widget.download_text end
    for _child_index, child in ipairs(widget) do visibleText(child, result, seen) end
    return table.concat(result, "\n")
end
local job_actions = {}
for _action_index, message in ipairs({ "Resume", "Pause", "Stop download; keep saved images", "Remove download", "Review recovery",
    "Open this copy", "Retry download", "Recovery options", "More actions", "Cancel verification" }) do job_actions[_(message)] = true end
local function capture(name)
    local widget = assert(screens.widget)
    local size = widget.content:getSize()
    check(name .. "_content_fits", size.w <= report.width and size.h <= report.height, { width = size.w, height = size.h })
    local rows = 0
    for _row_index, row in ipairs(screens.focus or {}) do
        local job_row = false
        for _button_index, button in ipairs(row) do if job_actions[button.text] then job_row = true end end
        if job_row then
            rows = rows + 1
            check(name .. "_job_row_" .. rows .. "_has_at_most_two_buttons", #row <= 2, #row)
        end
    end
    if screens.pages == 1 then check(name .. "_single_page_has_no_pager", screens.pagination == nil) end
    UIManager:forceRePaint()
    if dialogShown() then
        local dialog = screens.dialog
        local box = dialog.movable and dialog.movable:getSize() or dialog:getSize()
        check(name .. "_dialog_fits", box.w <= report.width and box.h <= report.height, { width = box.w, height = box.h })
        check(name .. "_dialog_is_topmost", UIManager:getTopmostVisibleWidget() == dialog)
        check(name .. "_dialog_text_is_safe", safeText(visibleText(dialog)))
    end
    check(name .. "_screen_text_is_safe", safeText(visibleText(widget)))
    Device.screen.bb:writePNG(output_dir .. "/" .. name .. ".png")
    report.screens[#report.screens + 1] = name .. ".png"
end
local function reset(state, err)
    screens:close()
    assert(#controller.waiting == 0, "A previous fake operation has not finished")
    controller.resume_error = false
    local job = { id = "job-recovery", kind = "episode_download", comic_id = "10", episode_id = "20",
        revision = "synthetic-revision", state = state, completed = 3, total = 12, error = err,
        payload = { comic_title = controller.comic.title, title = "Synthetic chapter" } }
    controller.jobs = { job }
    screens:showDownloads()
    return job
end
local function checkTarget(name, text, job)
    check(name .. "_identifies_the_comic", contains(text, job.payload.comic_title or controller.comic.title))
    check(name .. "_identifies_the_chapter", contains(text, job.payload.title or controller.episode.title))
    check(name .. "_identifies_the_exact_copy", contains(text, job.revision))
    check(name .. "_identifies_the_copy_status", contains(text, _("Current copy")))
end
local refresh_disclosures = {
    { "explicit_refresh_and_verification", "Refresh and verify this copy's image sources?" },
    { "network_cost_preserved_reading_and_verified_source_commit", "Saved images may be downloaded again, using network data. Saved content and reading position are preserved; new sources are applied only after verification succeeds." },
    { "closed_chapter_success_only_resume_and_no_purchase", "Close this chapter before proceeding. After verification succeeds, the download resumes. No purchase is made." },
}
local function checkRefreshConfirmation()
    local text = assert(screens.dialog).download_text
    check("refresh_confirmation_has_an_explicit_submit_action", screens.dialog.footer_buttons[2].text == _("Refresh image sources"))
    checkTarget("refresh_confirmation", text, assert(controller.jobs[1]))
    for _disclosure_index, disclosure in ipairs(refresh_disclosures) do
        check("refresh_confirmation_" .. disclosure[1], contains(text, _(disclosure[2])))
    end
    check("refresh_confirmation_is_localized", hasChinese(text) and safeText(text))
end
local function openRecovery()
    if screenButton("Review recovery") then press("Review recovery") else pressAction("Recovery options") end
    check("recovery_opens_a_visible_native_dialog", dialogShown())
    checkTarget("recovery", screens.dialog.download_text, assert(controller.jobs[1]))
    check("opening_a_partial_current_copy_discloses_network_use", contains(screens.dialog.download_text,
        _("Opening the current copy may fetch missing images using your sign-in and network connection.")))
end
local function openRefreshConfirmation()
    openRecovery(); pressDialog("Refresh image sources")
    checkRefreshConfirmation()
end
local function changeAccount(suffix)
    controller.generation = controller.generation + 1
    controller.account_key = "bili_ui_fixture_" .. suffix
    controller.account = { key = controller.account_key }
    controller.comic = { id = "10", title = "Replacement account comic " .. suffix }
end

local function run()
    local job = reset("failed", rawError("image_http", 400))
    local refresh_count = callCount("refreshDownloadSources")
    screens:refresh(); screens:refresh()
    check("http_400_does_not_automatically_refresh_sources", callCount("refreshDownloadSources") == refresh_count)
    capture("failed-download")
    openRecovery()
    check("recovery_has_explicit_refresh_action", findButton(screens.dialog, _("Refresh image sources")) ~= nil)
    capture("recovery-options")
    pressDialog("Refresh image sources")
    check("opening_confirmation_does_not_dispatch_refresh", callCount("refreshDownloadSources") == refresh_count)
    checkRefreshConfirmation()
    capture("refresh-confirmation")
    cancelConfirm()
    check("canceling_confirmation_has_no_side_effect", callCount("refreshDownloadSources") == refresh_count
        and job.payload.source_refresh == nil and not dialogShown())

    openRefreshConfirmation()
    local old_confirmation = screens.dialog
    local old_confirmation_callback = confirmationButton(old_confirmation, 2).callback
    confirm()
    check("confirmation_dispatches_one_exact_job", callCount("refreshDownloadSources") == refresh_count + 1
        and controller.waiting[1].job_id == job.id)
    old_confirmation_callback()
    check("repeated_confirmation_cannot_dispatch_twice", callCount("refreshDownloadSources") == refresh_count + 1)
    check("index_stage_replaces_resume_with_cancel", screenButton("Cancel verification") ~= nil
        and screenButton("Resume") == nil and contains(visibleText(screens.widget), _("Fetching image sources…")))
    capture("fetching-sources")
    job.payload.source_refresh = { stage = "verifying", checked = 1, total = 4 }
    screens:refresh()
    check("verification_stage_displays_historical_counts", contains(visibleText(screens.widget), _("Verifying saved images"))
        and contains(visibleText(screens.widget), string.format(_("Checked %d/%d images"), 1, 4)))
    capture("verifying-history")
    local cancel_count = callCount("cancelSourceRefresh")
    press("Cancel verification")
    check("cancel_verification_calls_only_the_cancel_operation", callCount("cancelSourceRefresh") == cancel_count + 1
        and job.payload.source_refresh == nil)
    finish("refreshDownloadSources", nil, rawError("source_refresh_interrupted"))
    check("late_completion_after_cancel_does_not_reopen_dialog", not dialogShown())
    capture("verification-canceled")

    job = reset("paused")
    check("paused_job_has_a_primary_resume_and_more_menu", screenButton("Resume") ~= nil and screenButton("More actions") ~= nil)
    capture("paused-download")
    openRefreshConfirmation(); confirm()
    job.payload.source_refresh, job.state, job.error = nil, "running", nil
    local resume_count = callCount("resumeJob")
    finish("refreshDownloadSources", job)
    check("successful_verification_uses_controller_result", screens.route == "downloads"
        and callCount("resumeJob") == resume_count and screenButton("Pause") ~= nil)
    capture("verification-complete")
    press("Pause")
    check("ordinary_pause_preserves_saved_images", job.state == "paused" and job.completed == 3)
    press("Resume"); pressAction("Stop download; keep saved images")
    check("ordinary_stop_keeps_saved_images", job.state == "canceled" and job.completed == 3
        and callCount("pauseJob") > 0 and callCount("cancelJob") > 0)

    job = reset("canceled")
    check("canceled_job_has_a_primary_resume_and_more_menu", screenButton("Resume") ~= nil and screenButton("More actions") ~= nil)
    capture("canceled-download")
    openRefreshConfirmation(); cancelConfirm()
    check("canceled_job_confirmation_cancel_preserves_state", job.state == "canceled")

    job = reset("paused")
    openRefreshConfirmation(); confirm()
    job.payload.source_refresh = { stage = "verifying", checked = 2, total = 4 }
    screens:refresh()
    cancel_count = callCount("cancelSourceRefresh")
    local remove_count = callCount("removeDownload")
    pressAction("Remove download")
    checkTarget("removal_confirmation", screens.dialog.download_text, job)
    check("removal_reports_saved_image_count", contains(screens.dialog.download_text, string.format(_("Saved (recorded): %d/%d"), 3, 12)))
    check("removal_explains_canceling_verification", contains(screens.dialog.download_text,
        _("Stop verification and remove this copy's saved images?")))
    check("removal_explains_exact_copy_scope_and_preserved_reading_and_access", contains(screens.dialog.download_text,
        _("Tasks using this same copy will stop. Other versions, reading positions, and purchase access are preserved. Offline reading of this copy will no longer be available.")))
    capture("remove-during-verification")
    cancelConfirm()
    check("canceling_remove_keeps_verification", callCount("cancelSourceRefresh") == cancel_count
        and callCount("removeDownload") == remove_count and job.payload.source_refresh ~= nil)
    pressAction("Remove download"); confirm()
    check("confirmed_remove_cancels_then_dispatches_removal", callCount("cancelSourceRefresh") == cancel_count + 1
        and callCount("removeDownload") == remove_count + 1)
    controller.jobs = {}
    finish("removeDownload", true)
    finish("refreshDownloadSources", nil, rawError("stale_source_refresh"))
    check("late_verification_cannot_restore_removed_job", #controller.jobs == 0 and not dialogShown())
    capture("removed-download")

    job = reset("paused")
    controller.resume_error = rawError("image_http", 400)
    refresh_count = callCount("refreshDownloadSources")
    resume_count = callCount("resumeJob")
    press("Resume")
    check("http_400_resume_does_not_turn_into_source_refresh", callCount("resumeJob") == resume_count + 1
        and callCount("refreshDownloadSources") == refresh_count and job.state == "failed")

    job = reset("paused")
    press("More actions")
    local stale_menu_action = assert(findButton(screens.dialog, _("Recovery options")))
    pressDialog("Close")
    stale_menu_action.callback()
    check("closed_more_menu_ignores_its_stale_action", not dialogShown() and callCount("refreshDownloadSources") == refresh_count)

    openRefreshConfirmation()
    local replacement_job = {}
    for key, value in pairs(job) do replacement_job[key] = value end
    replacement_job.revision = "replacement-revision"
    controller.jobs = { replacement_job }
    confirm()
    check("source_confirmation_rechecks_exact_revision", callCount("refreshDownloadSources") == refresh_count
        and not dialogShown() and contains(visibleText(screens.widget), replacement_job.revision))

    job = reset("paused")
    openRefreshConfirmation()
    controller.generation = controller.generation + 1
    confirm()
    check("generation_change_alone_invalidates_source_confirmation", callCount("refreshDownloadSources") == refresh_count)
    screens:_closeDialog()

    job = reset("paused")
    openRefreshConfirmation()
    refresh_count = callCount("refreshDownloadSources")
    changeAccount("b")
    confirm()
    check("account_change_invalidates_old_confirmation", callCount("refreshDownloadSources") == refresh_count)
    screens:_closeDialog()
    job = reset("paused")
    openRefreshConfirmation(); confirm()
    changeAccount("c")
    job.payload.source_refresh = nil
    job.payload.comic_title = controller.comic.title
    screens:refresh()
    finish("refreshDownloadSources", nil, rawError("stale_source_refresh"))
    check("old_account_feedback_cannot_replace_current_state", screens.route == "downloads"
        and contains(visibleText(screens.widget), controller.comic.title)
        and safeText(visibleText(screens.widget)) and not dialogShown())
    capture("stale-account-feedback")

    job = reset("paused")
    openRefreshConfirmation(); confirm()
    screens:close()
    finish("refreshDownloadSources", nil, rawError("source_refresh_interrupted"))
    check("closed_screen_ignores_delayed_verification_feedback", screens.route == nil and screens.widget == nil and screens.dialog == nil)

    reset("failed")
    check("failed_job_without_error_still_uses_recovery_options", screenButton("Review recovery") ~= nil
        and screenButton("Refresh image sources") == nil)
    openRefreshConfirmation(); cancelConfirm()

    local generic_heading, generic_message = Model.error({ kind = "unclassified_fixture" })
    for _case_index, case in ipairs({ { kind = "content_changed" }, { kind = "unknown_history" },
        { kind = "unverified_position" }, { kind = "reference_changed" }, { kind = "stale_source_refresh" },
        { kind = "source_refresh_interrupted" }, { kind = "busy", code = "chapter_active", name = "chapter_active" } }) do
        local name = case.name or case.kind
        local err = rawError(case.kind); err.code = case.code
        local heading, message, action = Model.error(err)
        local other_heading, other_message, other_action = Model.error({ kind = case.kind,
            code = case.code, message = "Different raw SDK failure" })
        check(name .. "_has_a_specific_fixed_message", heading == other_heading and message == other_message and action == other_action
            and (heading ~= generic_heading or message ~= generic_message))
        check(name .. "_is_safe_chinese", hasChinese(heading) and hasChinese(message) and safeText(heading .. "\n" .. message))
        reset("failed", err)
        openRecovery()
        check(name .. "_recovery_exposes_the_typed_error", contains(visibleText(screens.dialog), heading)
            and contains(visibleText(screens.dialog), message))
        capture("error-" .. name)
        screens:_closeDialog()
    end

    check("all_controller_operations_are_allowlisted", #controller.forbidden == 0)
    check("all_fake_callbacks_are_accounted_for", #controller.waiting == 0)
    report.controller_operations = {}
    for _call_index, call in ipairs(controller.calls) do
        report.controller_operations[call.method] = (report.controller_operations[call.method] or 0) + 1
    end
end

local ok, failure = pcall(run)
report.passed, report.error = ok, not ok and tostring(failure) or nil
report.count = #report.assertions
pcall(screens.close, screens)
local file = assert(io.open(output_dir .. "/download-recovery-result.json", "wb"))
file:write(json.encode(report, { pretty = true })); assert(file:close())
print(json.encode(report, { pretty = true }))
if not ok then error(failure) end
