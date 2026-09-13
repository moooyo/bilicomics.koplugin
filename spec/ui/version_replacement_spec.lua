-- Exercise version replacement with native widgets and an allowlisted fake controller.
-- No production business module or network operation is available to this spec.
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
local report = { spec = "native-version-replacement", runtime = "KOReader v2026.07.1",
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
local function safeText(text)
    for _marker_index, marker in ipairs({ "https://unsafe.invalid", "/private/old-page.bin", "SDK_SECRET", "raw-token-value" }) do
        if contains(text, marker) then return false end
    end
    return true
end
local function rawError(kind)
    return { kind = kind, message = "SDK_SECRET https://unsafe.invalid/?token=raw-token-value /private/old-page.bin",
        path = "/private/old-page.bin", url = "https://unsafe.invalid/?token=raw-token-value" }
end

local allowed = { getDownloads = true, getComic = true, getEpisode = true, getEpisodes = true,
    getStorageSummary = true, getAccount = true, resumeJob = true, pauseJob = true, cancelJob = true,
    removeDownload = true, readDownload = true, refreshDownloadSources = true, cancelSourceRefresh = true,
    replaceDownloadVersion = true, cancelVersionReplacement = true }
local controller = { jobs = {}, calls = {}, waiting = {}, forbidden = {}, generation = 1,
    account_key = "bili_version_fixture_a", account = { key = "bili_version_fixture_a" },
    comic = { id = "10", title = "Synthetic versioned comic" },
    episode = { id = "20", comic_id = "10", title = "Synthetic chapter", access = "owned" } }
local function record(method, job_id)
    assert(allowed[method], "Unexpected controller operation")
    controller.calls[#controller.calls + 1] = { method = method, job_id = job_id }
end
local function currentJob(job_id)
    for _job_index, job in ipairs(controller.jobs) do if job.id == job_id then return job end end
end
local function enqueue(method, job_id, callback)
    record(method, job_id)
    controller.waiting[#controller.waiting + 1] = { method = method, job_id = job_id, callback = callback }
end
function controller:getDownloads() record("getDownloads"); return self.jobs end
function controller:getComic() record("getComic"); return self.comic end
function controller:getEpisode() record("getEpisode"); return self.episode end
function controller:getEpisodes() record("getEpisodes"); return { self.episode } end
function controller:getAccount()
    record("getAccount")
    return { id = "ui_fixture", account_key = self.account_key, session_valid = true }
end
function controller:getStorageSummary()
    record("getStorageSummary"); return { automatic_bytes = 1048576, pinned_bytes = 4194304 }
end
function controller:resumeJob(job_id)
    record("resumeJob", job_id)
    local job = assert(currentJob(job_id)); job.state, job.error = "running", nil; return true
end
function controller:pauseJob(job_id)
    record("pauseJob", job_id); assert(currentJob(job_id)).state = "paused"; return true
end
function controller:cancelJob(job_id)
    record("cancelJob", job_id); assert(currentJob(job_id)).state = "canceled"; return true
end
function controller:replaceDownloadVersion(job_id, callback)
    local job = assert(currentJob(job_id))
    assert(not job.payload.source_refresh and not job.payload.version_replacement, "Preparation operations must be exclusive")
    assert(not job.payload.replaced_by and not job.payload.removed, "A retired version cannot be replaced again")
    job.payload.version_replacement = { id = "replacement-fixture", stage = "index" }
    enqueue("replaceDownloadVersion", job_id, callback)
end
function controller:cancelVersionReplacement(job_id)
    record("cancelVersionReplacement", job_id)
    local job = currentJob(job_id)
    if job then job.payload.version_replacement = nil; job.state = "paused" end
    return true
end
function controller:refreshDownloadSources(job_id, callback)
    local job = assert(currentJob(job_id))
    assert(not job.payload.version_replacement and not job.payload.source_refresh, "Preparation operations must be exclusive")
    job.payload.source_refresh = { stage = "index", checked = 0, total = 3 }
    enqueue("refreshDownloadSources", job_id, callback)
end
function controller:cancelSourceRefresh(job_id)
    record("cancelSourceRefresh", job_id)
    local job = currentJob(job_id)
    if job then job.payload.source_refresh = nil; job.state = "paused" end
    return true
end
function controller:readDownload(job_id, callback)
    assert(currentJob(job_id), "Reading requires an exact retained job")
    enqueue("readDownload", job_id, callback)
end
function controller:removeDownload(job_id, callback)
    assert(currentJob(job_id), "Removal requires an exact retained job")
    enqueue("removeDownload", job_id, callback)
end
setmetatable(controller, { __index = function(_controller, key)
    controller.forbidden[#controller.forbidden + 1] = tostring(key)
    error("Controller member is outside the version replacement allowlist: " .. tostring(key))
end })

local screens = Screens.new{ controller = controller }
local function callCount(method)
    local count = 0
    for _call_index, call in ipairs(controller.calls) do if call.method == method then count = count + 1 end end
    return count
end
local function pending(method)
    for _request_index, request in ipairs(controller.waiting) do if request.method == method then return request end end
end
local function finish(method, value, err)
    for index, request in ipairs(controller.waiting) do
        if request.method == method then
            table.remove(controller.waiting, index); request.callback(value, err); return request
        end
    end
    error("No fake callback is waiting for " .. method)
end
local function findButton(widget, text, seen)
    if type(widget) ~= "table" then return end
    seen = seen or {}; if seen[widget] then return end; seen[widget] = true
    if widget.text == text and type(widget.callback) == "function" then return widget end
    for _child_index, child in ipairs(widget) do
        local found = findButton(child, text, seen); if found then return found end
    end
end
local function screenRow(message)
    for _row_index, row in ipairs(screens.focus or {}) do
        for _button_index, button in ipairs(row) do if button.text == _(message) then return row end end
    end
end
local function rowButton(row, message)
    for _button_index, button in ipairs(row or {}) do if button.text == _(message) then return button end end
end
local function screenButton(message) return rowButton(screenRow(message), message) end
local function pressButton(button)
    assert(button and button.callback and button.enabled ~= false, "The requested native button is unavailable")
    button.callback()
end
local function press(message) pressButton(screenButton(message)) end
local function dialogShown() return screens.dialog ~= nil and UIManager:isWidgetShown(screens.dialog) end
local function pressDialog(message)
    assert(dialogShown(), "No native dialog is open")
    pressButton(findButton(screens.dialog, _(message)))
end
local function confirm()
    local dialog = assert(screens.dialog)
    assert(dialogShown() and type(dialog.ok_callback) == "function", "Expected a native ConfirmBox")
    pressButton(findButton(dialog, dialog.ok_text))
end
local function cancelConfirm()
    local dialog = assert(screens.dialog)
    assert(dialogShown() and type(dialog.ok_callback) == "function", "Expected a native ConfirmBox")
    pressButton(findButton(dialog, dialog.cancel_text))
end
local function visibleText(widget, result, seen)
    result, seen = result or {}, seen or {}
    if type(widget) ~= "table" or seen[widget] then return table.concat(result, "\n") end
    seen[widget] = true
    if type(widget.text) == "string" then result[#result + 1] = widget.text end
    if type(widget.title) == "string" then result[#result + 1] = widget.title end
    for _child_index, child in ipairs(widget) do visibleText(child, result, seen) end
    return table.concat(result, "\n")
end
local action_labels = {}
for _action_index, message in ipairs({ "Resume", "Pause", "Cancel download", "Remove download", "Read offline",
    "Read retained version", "Failure details", "Recovery options", "Refresh image sources", "Cancel verification",
    "Redownload as new version", "Cancel preparation" }) do action_labels[_(message)] = true end
local function capture(name)
    local size = assert(screens.widget).content:getSize()
    check(name .. "_content_fits", size.w <= report.width and size.h <= report.height, { width = size.w, height = size.h })
    local row_number = 0
    for _row_index, row in ipairs(screens.focus or {}) do
        local has_action = false
        for _button_index, button in ipairs(row) do if action_labels[button.text] then has_action = true end end
        if has_action then
            row_number = row_number + 1
            check(name .. "_action_row_" .. row_number .. "_fits_four_buttons", #row <= 4, #row)
        end
    end
    UIManager:forceRePaint()
    check(name .. "_screen_text_is_safe", safeText(visibleText(screens.widget)))
    if dialogShown() then
        local dialog = screens.dialog
        local box = dialog.movable and dialog.movable:getSize() or dialog:getSize()
        check(name .. "_dialog_fits", box.w <= report.width and box.h <= report.height, { width = box.w, height = box.h })
        check(name .. "_dialog_is_topmost", UIManager:getTopmostVisibleWidget() == dialog)
        check(name .. "_dialog_text_is_safe", safeText(visibleText(dialog)))
    end
    Device.screen.bb:writePNG(output_dir .. "/" .. name .. ".png")
    report.screens[#report.screens + 1] = name .. ".png"
end
local function makeJob(id, state, revision, completed)
    return { id = id, kind = "episode_download", comic_id = "10", episode_id = "20", state = state,
        revision = revision, completed = completed or 3, total = 12,
        payload = { comic_title = controller.comic.title, title = "Synthetic chapter" } }
end
local function reset(state, err)
    screens:close()
    assert(#controller.waiting == 0, "A previous fake operation has not finished")
    local job = makeJob("01-old-version", state or "failed", "revision-old", 3)
    job.error = err
    controller.jobs = { job }; screens:showDownloads(); return job
end
local function openRecovery()
    local button = screenButton("Recovery options") or screenButton("Failure details") or screenButton("Download recovery")
    pressButton(button)
    check("recovery_dialog_has_expected_title", contains(screens.dialog.title, _("Download recovery")))
end
local replacement_confirmation_message = "Download this chapter as a separate new version? All images will be downloaded, requiring additional space and network data. The new version starts from the beginning. This version's cache and reading position stay in a separate older-version row, where you can read or remove them. No purchase is made."
local function openReplacementConfirmation()
    openRecovery(); pressDialog("Redownload as new version")
    check("replacement_confirmation_is_explicit_and_localized", screens.dialog.ok_text == _("Redownload as new version")
        and hasChinese(screens.dialog.text) and safeText(screens.dialog.text))
    check("replacement_confirmation_explains_version_separation", screens.dialog.text == _(replacement_confirmation_message))
end
local function changeAccount(suffix)
    controller.generation = controller.generation + 1
    controller.account_key = "bili_version_fixture_" .. suffix
    controller.account = { key = controller.account_key }
    controller.comic = { id = "10", title = "Replacement account comic " .. suffix }
end

local function run()
    local old_job = reset("failed", rawError("unknown_history"))
    local replacements = callCount("replaceDownloadVersion")
    openRecovery()
    check("recovery_keeps_source_refresh_alongside_new_version", findButton(screens.dialog, _("Refresh image sources")) ~= nil
        and findButton(screens.dialog, _("Redownload as new version")) ~= nil)
    capture("recovery-options")
    pressDialog("Redownload as new version")
    check("opening_replacement_confirmation_does_not_submit", callCount("replaceDownloadVersion") == replacements)
    capture("replacement-confirmation")
    cancelConfirm()
    check("canceling_confirmation_preserves_old_download", not dialogShown() and callCount("replaceDownloadVersion") == replacements
        and old_job.revision == "revision-old" and old_job.completed == 3 and not old_job.payload.version_replacement)

    openReplacementConfirmation()
    local original_confirmation = screens.dialog
    confirm()
    check("confirmation_submits_the_exact_old_job_once", callCount("replaceDownloadVersion") == replacements + 1
        and pending("replaceDownloadVersion").job_id == old_job.id)
    original_confirmation.ok_callback()
    check("stale_confirmation_cannot_submit_twice", callCount("replaceDownloadVersion") == replacements + 1)
    check("preparation_has_explicit_progress_and_cancel", contains(visibleText(screens.widget), _("Preparing new version…"))
        and screenButton("Cancel preparation") ~= nil and screenButton("Resume") == nil)
    check("preparation_excludes_source_refresh_and_replacement", screenButton("Refresh image sources") == nil
        and screenButton("Redownload as new version") == nil and screenButton("Failure details") == nil
        and screenButton("Recovery options") == nil)
    capture("preparing-new-version")
    local canceled = callCount("cancelVersionReplacement")
    press("Cancel preparation")
    check("cancel_preparation_uses_exact_job", callCount("cancelVersionReplacement") == canceled + 1
        and not old_job.payload.version_replacement)
    finish("replaceDownloadVersion", { id = "late-uncommitted-job" })
    check("late_success_after_cancel_does_not_reopen_or_create_a_row", not dialogShown() and #controller.jobs == 1
        and controller.jobs[1].id == old_job.id and screens.route == "downloads")
    capture("preparation-canceled")

    old_job = reset("paused")
    openReplacementConfirmation(); confirm()
    local new_job = makeJob("02-new-version", "queued", "revision-new", 0)
    new_job.payload.replaces_job_id = old_job.id
    old_job.payload.version_replacement, old_job.payload.replaced_by = nil, new_job.id
    old_job.state = "canceled"
    controller.jobs = { old_job, new_job }
    finish("replaceDownloadVersion", new_job)
    check("successful_preparation_keeps_two_distinct_jobs", #controller.jobs == 2 and old_job.revision == "revision-old"
        and old_job.completed == 3 and new_job.completed == 0 and new_job.payload.replaces_job_id == old_job.id)
    check("old_version_has_a_retained_status", contains(visibleText(screens.widget), _("Older version retained")))
    local retained_row = assert(screenRow("Read retained version"), "Missing retained-version action row")
    check("old_version_only_exposes_read_and_remove", #retained_row == 2 and rowButton(retained_row, "Remove download") ~= nil
        and rowButton(retained_row, "Resume") == nil and rowButton(retained_row, "Refresh image sources") == nil
        and rowButton(retained_row, "Redownload as new version") == nil)
    capture("old-and-new-versions")
    press("All downloads")
    check("active_filter_excludes_retained_old_version", screenButton("Read retained version") == nil
        and screenButton("Pause") ~= nil)
    press("In progress")
    check("complete_filter_excludes_retained_old_version", screenButton("Read retained version") == nil)
    press("Ready offline")
    retained_row = assert(screenRow("Read retained version"))
    pressButton(rowButton(retained_row, "Read retained version"))
    check("retained_read_uses_old_job_identity", pending("readDownload").job_id == old_job.id)
    finish("readDownload", { job_id = old_job.id })
    check("successful_retained_read_closes_business_screen", screens.route == nil)
    screens:showDownloads()
    retained_row = assert(screenRow("Read retained version"))
    local removed = callCount("removeDownload")
    pressButton(rowButton(retained_row, "Remove download")); cancelConfirm()
    check("canceling_old_version_removal_keeps_both_rows", callCount("removeDownload") == removed and #controller.jobs == 2)
    retained_row = assert(screenRow("Read retained version"))
    pressButton(rowButton(retained_row, "Remove download")); confirm()
    check("retained_remove_uses_old_job_identity", pending("removeDownload").job_id == old_job.id)
    controller.jobs = { new_job }; finish("removeDownload", true)
    check("removing_old_version_does_not_remove_new_download", #controller.jobs == 1 and controller.jobs[1].id == new_job.id)
    capture("new-version-queue")

    local complete_job = reset("complete")
    complete_job.id, complete_job.completed = "complete-current-version", 12
    screens:refresh(); press("Read offline")
    check("complete_download_also_reads_by_exact_job", pending("readDownload").job_id == complete_job.id)
    finish("readDownload", { job_id = complete_job.id })

    for _state_index, state in ipairs({ "paused", "failed", "canceled" }) do
        old_job = reset(state)
        openRecovery()
        check(state .. "_retained_partial_job_offers_new_version", findButton(screens.dialog, _("Redownload as new version")) ~= nil)
        capture(state .. "-recovery")
        screens:_closeDialog()
    end

    for _case_index, case in ipairs({ { name = "missing_revision" }, { name = "removed", removed = true } }) do
        old_job = reset("failed", rawError("content_changed"))
        if case.removed then old_job.payload.removed = true else old_job.revision = nil end
        screens:refresh()
        if screenButton("Failure details") or screenButton("Recovery options") then
            openRecovery()
            check(case.name .. "_cannot_start_new_version", findButton(screens.dialog, _("Redownload as new version")) == nil)
        else check(case.name .. "_cannot_start_new_version", screenButton("Redownload as new version") == nil) end
        screens:_closeDialog()
    end

    for _kind_index, kind in ipairs({ "unknown_history", "content_changed", "unverified_position" }) do
        old_job = reset("failed", rawError(kind))
        openRecovery(); pressDialog("Refresh image sources"); confirm()
        check(kind .. "_source_refresh_remains_available", pending("refreshDownloadSources").job_id == old_job.id
            and screenButton("Cancel verification") ~= nil)
        check(kind .. "_source_refresh_excludes_preparation", screenButton("Cancel preparation") == nil
            and screenButton("Redownload as new version") == nil)
        if kind == "unknown_history" then capture("source-verification-controls") end
        old_job.payload.source_refresh, old_job.state, old_job.error = nil, "failed", rawError(kind)
        finish("refreshDownloadSources", nil, old_job.error)
        local heading, message = Model.error(old_job.error)
        check(kind .. "_feedback_opens_direct_new_version_recovery", dialogShown()
            and contains(screens.dialog.title, _("Download recovery")) and contains(screens.dialog.title, heading)
            and contains(screens.dialog.title, message) and findButton(screens.dialog, _("Redownload as new version")) ~= nil)
        capture("source-error-" .. kind)
        pressDialog("Redownload as new version"); cancelConfirm()
    end

    old_job = reset("paused")
    openRecovery(); pressDialog("Refresh image sources"); confirm()
    local source_canceled = callCount("cancelSourceRefresh")
    press("Cancel verification")
    finish("refreshDownloadSources", nil, rawError("source_refresh_interrupted"))
    check("existing_source_cancel_remains_effective", callCount("cancelSourceRefresh") == source_canceled + 1
        and not old_job.payload.source_refresh and not dialogShown())

    old_job = reset("paused")
    openReplacementConfirmation()
    replacements = callCount("replaceDownloadVersion")
    old_job.payload.source_refresh = { stage = "index", checked = 0, total = 3 }
    confirm()
    check("replacement_confirmation_rechecks_source_refresh_exclusion", callCount("replaceDownloadVersion") == replacements
        and old_job.payload.version_replacement == nil)
    old_job.payload.source_refresh = nil
    screens:_closeDialog()
    old_job = reset("paused")
    openRecovery(); pressDialog("Refresh image sources")
    local source_requests = callCount("refreshDownloadSources")
    old_job.payload.version_replacement = { id = "external-preparation", stage = "index" }
    confirm()
    check("source_confirmation_rechecks_replacement_exclusion", callCount("refreshDownloadSources") == source_requests
        and old_job.payload.source_refresh == nil)
    old_job.payload.version_replacement = nil
    screens:_closeDialog()

    old_job = reset("paused")
    openReplacementConfirmation()
    replacements = callCount("replaceDownloadVersion")
    changeAccount("b"); confirm()
    check("account_change_invalidates_unsubmitted_confirmation", callCount("replaceDownloadVersion") == replacements)
    screens:_closeDialog()
    old_job = reset("paused")
    openReplacementConfirmation(); confirm()
    changeAccount("c")
    old_job.payload.version_replacement = nil
    old_job.payload.comic_title = controller.comic.title
    screens:refresh()
    finish("replaceDownloadVersion", nil, rawError("stale_source_refresh"))
    check("old_account_feedback_cannot_replace_current_ui", not dialogShown() and screens.route == "downloads"
        and contains(visibleText(screens.widget), controller.comic.title))
    capture("stale-account-feedback")

    old_job = reset("paused")
    openReplacementConfirmation(); confirm()
    screens:close()
    finish("replaceDownloadVersion", nil, rawError("source_refresh_interrupted"))
    check("closed_screen_ignores_old_preparation_feedback", screens.route == nil and screens.widget == nil and screens.dialog == nil)
    local generic_heading, generic_message = Model.error({ kind = "unclassified_fixture" })
    for _kind_index, kind in ipairs({ "version_replaced", "source_unavailable", "version_replacement_interrupted" }) do
        local heading, message, action = Model.error(rawError(kind))
        local other_heading, other_message, other_action = Model.error({ kind = kind,
            message = "Different raw SDK failure", path = "/another/private/file.bin" })
        check(kind .. "_has_a_specific_fixed_message", heading == other_heading and message == other_message
            and action == other_action and (heading ~= generic_heading or message ~= generic_message))
        check(kind .. "_is_safe_chinese", hasChinese(heading) and hasChinese(message)
            and safeText(heading .. "\n" .. message))
    end
    check("all_controller_operations_are_allowlisted", #controller.forbidden == 0)
    check("all_fake_callbacks_are_accounted_for", #controller.waiting == 0)
    report.controller_operations = {}
    for _call_index, call in ipairs(controller.calls) do
        report.controller_operations[call.method] = (report.controller_operations[call.method] or 0) + 1
    end
end

local ok, failure = pcall(run)
report.passed, report.error, report.count = ok, not ok and tostring(failure) or nil, #report.assertions
pcall(screens.close, screens)
local file = assert(io.open(output_dir .. "/version-replacement-result.json", "wb"))
assert(file:write(json.encode(report, { pretty = true }))); assert(file:close())
print(json.encode(report, { pretty = true }))
if not ok then error(failure) end
