-- Focused native ordinal-range wording with synthetic quotes and no network access.
require("setupkoenv")
local output_dir, plugin = assert(arg[1]), assert(arg[2])
local ffi = require("ffi")
require("ffi/posix_h")
if not pcall(function() return ffi.C.readlink end) then
    ffi.cdef[[long readlink(const char *path, char *buffer, unsigned long size);]]
end
local parent_namespace = assert(os.getenv("BILI_UI_PARENT_NETNS"), "The parent network namespace is required")
local namespace_buffer = ffi.new("char[256]")
local namespace_length = tonumber(ffi.C.readlink("/proc/self/ns/net", namespace_buffer, 256))
assert(namespace_length and namespace_length > 0 and namespace_length < 256, "Cannot read the current network namespace")
assert(parent_namespace ~= "" and ffi.string(namespace_buffer, namespace_length) ~= parent_namespace,
    "A separate network namespace is required")
local routes = assert(io.open("/proc/net/route", "rb"))
local route_count = 0
for line in routes:lines() do if line:match("%S") and not line:match("^Iface%s") then route_count = route_count + 1 end end
assert(routes:close()); assert(route_count == 0, "The isolated namespace must have no network routes")

G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local prohibited_modules = { "bilicomics/controller", "bilicomics/runtime", "bilicomics/protocol/client",
    "bilicomics/protocol/transport", "bilicomics/protocol/session", "bilicomics/purchase/service",
    "bilicomics/purchase/quote_fetch", "bilicomics/purchase/quote", "bilicomics/purchase/candidate",
    "bilicomics/purchase/selection", "bilicomics/purchase/range" }
for _module_index, name in ipairs(prohibited_modules) do
    assert(package.loaded[name] == nil, "A production business module was already loaded")
    package.preload[name] = function() error("Production business modules are forbidden in this synthetic UI spec") end
end
require("gettext").current_lang = "zh_CN"
local UIManager = require("ui/uimanager")
local json = require("rapidjson")
local Screens = require("bilicomics/ui/screens")
local Model = require("bilicomics/ui/model")
local _ = require("bilicomics/ui/i18n")
local report = { spec = "native-synthetic-ordinal-range", runtime = "KOReader v2026.07.1",
    width = Device.screen:getWidth(), height = Device.screen:getHeight(), synthetic_only = true,
    purchase_submissions_fake = true, actual_purchase_executed = false,
    network_namespace_isolated = true, no_network_routes = true, assertions = {}, screens = {} }
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
local function equal(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, item in pairs(left) do if not equal(item, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end
local function contains(text, part) return type(text) == "string" and text:find(part, 1, true) ~= nil end
local proof_markers = { "bilibili_pc_ordinal_range_v1", "primary_sdk_ordinal_contract_and_quote_catalog_consistency",
    "SYNTHETIC_PROOF_HASH", "SYNTHETIC_FINGERPRINT_HASH", "SDK_INTERNAL_PROOF" }
local function noProofText(text)
    for _marker_index, marker in ipairs(proof_markers) do if contains(text, marker) then return false end end
    return true
end
local single = { kind = "single", order = 1 }
local positive = { kind = "batch", batch_limit = 2, start_ord = 10.5, offer_index = 1, order = 1 }
local remaining = { kind = "batch", batch_limit = 0, start_ord = 10.5, offer_index = 2, order = 1 }
local coin = { method = "coin", discount = { kind = "none" } }
local controller = { generation = 1, sequence = 0, calls = {}, waiting = {}, forbidden = {}, pending_intents = {},
    comic = { id = "10", title = "Synthetic ordinal comic", authors = { "UI fixture" } }, episodes = {
        { id = "20", comic_id = "10", order = 10.5, title = "Synthetic anchor chapter", access = "locked" },
        { id = "21", comic_id = "10", order = 10.75, title = "Synthetic already-owned chapter", access = "owned" },
        { id = "22", comic_id = "10", order = 11, title = "Synthetic next expected chapter", access = "locked" },
        { id = "23", comic_id = "10", order = 11.5, title = "Synthetic final expected chapter", access = "locked" },
    } }
local allowed = { getAccount = true, getComic = true, getEpisodes = true, getPendingPurchases = true,
    quotePurchase = true, purchase = true }
local function record(method, args)
    assert(allowed[method], "Unexpected synthetic controller operation")
    controller.calls[#controller.calls + 1] = { method = method, args = copy(args or {}) }
end
local function enqueue(method, args, callback)
    record(method, args); controller.sequence = controller.sequence + 1
    local request = { id = controller.sequence, method = method, args = copy(args), callback = callback }
    controller.waiting[#controller.waiting + 1] = request
end
function controller:getAccount() record("getAccount"); return { id = "ordinal_fixture", account_key = "bili_ordinal_fixture" } end
function controller:getComic() record("getComic"); return copy(self.comic) end
function controller:getEpisodes() record("getEpisodes"); return copy(self.episodes) end
function controller:getPendingPurchases() record("getPendingPurchases"); return copy(self.pending_intents) end
function controller:quotePurchase(episode_id, scope, payment, callback)
    enqueue("quotePurchase", { episode_id, scope, payment }, callback)
end
function controller:purchase(quote, purpose, callback) enqueue("purchase", { quote, purpose }, callback) end
setmetatable(controller, { __index = function(_controller, key)
    if key == "requestCover" or key == "isFavoritePending" then return nil end
    controller.forbidden[#controller.forbidden + 1] = tostring(key)
    error("Controller member is outside the ordinal-range UI allowlist: " .. tostring(key))
end })
local function countCalls(method)
    local count = 0
    for _call_index, call in ipairs(controller.calls) do if call.method == method then count = count + 1 end end
    return count
end
local function pending(method)
    for _request_index, request in ipairs(controller.waiting) do if request.method == method then return request end end
    error("No synthetic callback is waiting for " .. method)
end
local function finish(request, value, err)
    for index, waiting in ipairs(controller.waiting) do
        if waiting == request then
            table.remove(controller.waiting, index)
            local delivered = copy(value); request.callback(delivered, copy(err)); return delivered
        end
    end
    error("The synthetic callback was already delivered")
end
local function makeQuote(request, amount, proof)
    local scope, payment = copy(request.args[2]), copy(request.args[3])
    local ids = scope.kind == "single" and { "20" } or scope.batch_limit == 0 and { "20", "22", "23" } or { "20", "22" }
    local access = {}; for _id_index, id in ipairs(ids) do access[id] = { access = "owned" } end
    return { id = "synthetic-ordinal-" .. request.id, episode_id = "20", comic_id = "10", submittable = true,
        scope = scope, payment = payment, method = "coin", amount = amount, balance = 500, can_afford = true,
        episode_ids = ids, expected_access = access, fingerprint = "SYNTHETIC_FINGERPRINT_HASH_" .. request.id,
        range_proof = proof and { contract = "bilibili_pc_ordinal_range_v1",
            provenance = "primary_sdk_ordinal_contract_and_quote_catalog_consistency", hash = "SYNTHETIC_PROOF_HASH" } or nil,
        extra = { proof = "SDK_INTERNAL_PROOF" },
        scopes = { copy(single), copy(positive), copy(remaining) }, payments = { copy(coin) },
        batch_offers = { { scope = copy(positive), amount = 2, available = true },
            { scope = copy(remaining), amount = 0, available = true } } }
end

local screens = Screens.new{ controller = controller }
local function buttons(widget, result, seen)
    result, seen = result or {}, seen or {}
    if type(widget) ~= "table" or seen[widget] then return result end
    seen[widget] = true
    if type(widget.text) == "string" and type(widget.callback) == "function" then result[#result + 1] = widget end
    for _child_index, child in ipairs(widget) do buttons(child, result, seen) end
    return result
end
local function findButton(widget, text)
    for _button_index, button in ipairs(buttons(widget)) do if button.text == text then return button end end
end
local function pressButton(button)
    assert(button and button.callback and button.enabled ~= false, "The requested native button is unavailable")
    button.callback()
end
local function pressDialog(message)
    assert(screens.dialog == UIManager:getTopmostVisibleWidget(), "The main dialog must be topmost")
    pressButton(findButton(screens.dialog, _(message)))
end
local function allText(widget, result, seen)
    result, seen = result or {}, seen or {}
    if type(widget) ~= "table" or seen[widget] then return table.concat(result, "\n") end
    seen[widget] = true
    if type(widget.text) == "string" then result[#result + 1] = widget.text end
    if type(widget.title) == "string" then result[#result + 1] = widget.title end
    for _child_index, child in ipairs(widget) do allText(child, result, seen) end
    return table.concat(result, "\n")
end
local function closeDetails()
    if screens.scope_dialog then UIManager:close(screens.scope_dialog); screens.scope_dialog = nil end
end
local function capture(name)
    local content = assert(screens.widget).content:getSize()
    check(name .. "_background_fits", content.w <= report.width and content.h <= report.height)
    UIManager:forceRePaint()
    local top = screens.scope_dialog and UIManager:isWidgetShown(screens.scope_dialog) and screens.scope_dialog or screens.dialog
    local box = top.movable and top.movable:getSize() or top:getSize()
    check(name .. "_dialog_fits", box.w <= report.width and box.h <= report.height, { width = box.w, height = box.h })
    check(name .. "_dialog_is_topmost", top == UIManager:getTopmostVisibleWidget())
    check(name .. "_does_not_expose_proof_or_hash", noProofText(allText(top)))
    Device.screen.bb:writePNG(output_dir .. "/" .. name .. ".png")
    report.screens[#report.screens + 1] = name .. ".png"
end
local function openSingle(amount)
    screens:close(); assert(#controller.waiting == 0, "A previous synthetic callback remains pending")
    screens.loaded["comic:10"] = true; screens:showComic("10")
    local button
    for _row_index, row in ipairs(screens.focus) do
        for _button_index, item in ipairs(row) do if item.text == "Synthetic anchor chapter" then button = item end end
    end
    pressButton(button)
    local request = pending("quotePurchase")
    return finish(request, makeQuote(request, amount, false))
end
local function chooseRange(scope)
    pressDialog("Choose range")
    while true do
        local previous = assert(findButton(screens.dialog, _("Previous")))
        if previous.enabled == false then break end
        pressButton(previous)
    end
    local label = scope.kind == "single" and _("Single chapter") or scope.batch_limit == 0
        and _("Remaining from this chapter") or string.format(_("Batch offer %d"), 1)
    while true do
        for _button_index, button in ipairs(buttons(screens.dialog)) do
            if button.text:match("^%[[x ]%] ") and button.text:sub(5) == label then
                if scope.batch_limit == 0 then
                    check("remaining_option_never_claims_zero_chapters", not contains(allText(screens.dialog),
                        string.format(_("Reported chapters: %s"), "0")))
                    capture("remaining-range-option")
                end
                pressButton(button)
                local request = pending("quotePurchase")
                check("range_choice_keeps_the_full_selector", equal(request.args[2], scope) and equal(request.args[3], coin))
                return request
            end
        end
        local next_button = assert(findButton(screens.dialog, _("Next")))
        assert(next_button.enabled ~= false, "The requested ordinal range is absent")
        pressButton(next_button)
    end
end
local function confirmation(amount)
    return findButton(screens.dialog, string.format(_("Confirm purchase · %s %s"), tostring(amount), _("coins")))
end
local caveat = "Catalog updates or purchases elsewhere may change the actual chapters. Details show the current expected list."
local function checkBatch(name, quote, expected_rule)
    local main_text = allText(screens.dialog)
    check(name .. "_shows_range_rule_and_separate_total", contains(main_text, expected_rule)
        and contains(main_text, string.format(_("Total: %s %s"), tostring(quote.amount), _("coins"))))
    check(name .. "_main_list_is_not_an_exact_membership_claim", contains(main_text, _(caveat))
        and not contains(main_text, "Synthetic next expected chapter")
        and not contains(main_text, "Synthetic final expected chapter")
        and findButton(screens.dialog, _("Review exact chapters")) == nil)
    capture(name)
    pressDialog("Review expected chapters")
    local details = assert(screens.scope_dialog)
    check(name .. "_uses_expected_list_wording", details.title == _("Expected purchase chapters")
        and contains(details.text, _("Current expected chapters:")) and contains(details.text, _(caveat)))
    check(name .. "_identifies_the_starting_chapter", contains(details.text,
        string.format(_("Starting chapter: %s"), "Synthetic anchor chapter")))
    check(name .. "_lists_current_expected_members_only", contains(details.text, "Synthetic anchor chapter")
        and contains(details.text, "Synthetic next expected chapter")
        and not contains(details.text, "Synthetic already-owned chapter")
        and (quote.scope.batch_limit ~= 0 or contains(details.text, "Synthetic final expected chapter")))
    capture(name .. "-details"); closeDetails()
end
local function run()
    local quote = openSingle(19)
    check("single_summary_and_exact_details_are_unchanged", contains(screens.dialog.title,
        string.format(_("%d chapters · %s %s"), 1, "19", _("coins")))
        and findButton(screens.dialog, _("Review exact chapters")) ~= nil
        and findButton(screens.dialog, _("Review expected chapters")) == nil)
    capture("single-unchanged")
    pressDialog("Review exact chapters")
    check("single_keeps_its_existing_detail_title", screens.scope_dialog.title == _("Purchase scope")
        and not contains(screens.scope_dialog.text, _("Current expected chapters:")))
    closeDetails()

    local request = chooseRange(positive)
    quote = finish(request, makeQuote(request, 37.5, true))
    checkBatch("positive-ordinal-range", quote, string.format(_("From this chapter: first %d locked chapters"), 2))
    request = chooseRange(remaining)
    quote = finish(request, makeQuote(request, 45, true))
    checkBatch("remaining-ordinal-range", quote, _("Remaining from this chapter"))
    check("zero_limit_is_not_a_zero_chapter_purchase", not contains(screens.dialog.title,
        string.format(_("%d chapters · %s %s"), 0, "45", _("coins"))))

    request = chooseRange(positive)
    quote = finish(request, makeQuote(request, 37.5, false))
    checkBatch("legacy-batch-without-proof", quote, _("Batch selection"))
    check("unproved_legacy_batch_does_not_claim_the_ordinal_contract", not contains(screens.dialog.title,
        string.format(_("From this chapter: first %d locked chapters"), 2)))

    for _field_index, field in ipairs({ "contract", "provenance" }) do
        request = chooseRange(positive)
        local mismatch = makeQuote(request, 37.5, true)
        mismatch.range_proof[field] = "SDK_INTERNAL_PROOF_MISMATCH"
        quote = finish(request, mismatch)
        check(field .. "_mismatch_keeps_expected_list_without_ordinal_claim", Model.ordinalRange(quote) == false
            and contains(screens.dialog.title, _("Batch selection"))
            and findButton(screens.dialog, _("Review expected chapters")) ~= nil
            and findButton(screens.dialog, _("Review exact chapters")) == nil
            and noProofText(allText(screens.dialog)))
    end
    request = chooseRange(positive)
    local candidate = makeQuote(request, 88, true)
    candidate.submittable = false
    quote = finish(request, candidate)
    local confirm_prefix = assert(_("Confirm purchase · %s %s"):match("^(.-)%%"))
    local has_confirmation = false
    for _button_index, button in ipairs(buttons(screens.dialog)) do
        if button.text:sub(1, #confirm_prefix) == confirm_prefix then has_confirmation = true end
    end
    check("correct_display_marker_cannot_promote_a_candidate", Model.ordinalRange(quote) == false
        and not has_confirmation and countCalls("purchase") == 0)

    request = chooseRange(single)
    quote = finish(request, makeQuote(request, 19, false))
    check("returning_to_single_restores_exact_wording", findButton(screens.dialog, _("Review exact chapters")) ~= nil
        and findButton(screens.dialog, _("Review expected chapters")) == nil and not contains(screens.dialog.title, _(caveat)))

    request = chooseRange(remaining)
    quote = finish(request, makeQuote(request, 45, true))
    local old_confirm = assert(confirmation(45))
    request = chooseRange(remaining)
    old_confirm.callback()
    check("refresh_does_not_reuse_the_old_confirmation", countCalls("purchase") == 0)
    local refreshed = finish(request, makeQuote(request, 64, true))
    old_confirm.callback()
    check("changed_price_requires_a_new_explicit_confirmation", countCalls("purchase") == 0
        and confirmation(45) == nil and confirmation(64) ~= nil
        and contains(screens.dialog.title, string.format(_("Total: %s %s"), "64", _("coins"))))
    capture("changed-price-needs-confirmation")
    local new_confirm = assert(confirmation(64))
    pressButton(new_confirm)
    local submission = pending("purchase")
    check("new_confirmation_sends_only_the_refreshed_synthetic_quote", countCalls("purchase") == 1
        and equal(submission.args[1], refreshed) and submission.args[1].amount == 64
        and submission.args[1].scope.batch_limit == 0 and submission.args[2] == "read")
    new_confirm.callback()
    check("duplicate_native_callback_cannot_submit_twice", countCalls("purchase") == 1)
    local unresolved = finish(submission, { id = "synthetic-ordinal-intent", state = "access_confirmed", purpose = "read", comic_id = "10",
        transaction_evidence = "server_accepted", range_outcome_pending = true,
        quote = copy(submission.args[1]), episode_ids = copy(submission.args[1].episode_ids) })
    local pending_message = "Reading access is confirmed, but the range purchase result is still unknown. Further purchases for this comic are paused."
    check("pending_range_outcome_takes_precedence_over_payment_evidence", contains(screens.dialog.title, _("Chapter access confirmed"))
        and not contains(screens.dialog.title, _("Purchase confirmed")) and contains(screens.dialog.title, _(pending_message))
        and findButton(screens.dialog, _("Read chapter")) ~= nil)
    capture("range-outcome-pending")
    controller.pending_intents = { copy(unresolved), { id = "synthetic-ordinary-intent", state = "outcome_unknown",
        purpose = "read", comic_id = "10", episode_ids = { "20" }, quote = copy(submission.args[1]) } }
    screens:_pendingList(controller:getPendingPurchases())
    local review_label = string.format(_("Review purchase %s"), unresolved.id)
    local review_button
    for _button_index, button in ipairs(buttons(screens.dialog)) do
        if contains(button.text, review_label) then review_button = button end
    end
    check("pending_list_distinguishes_the_unresolved_range", review_button ~= nil
        and contains(allText(screens.dialog), _("Range result pending; purchases paused"))
        and findButton(screens.dialog, string.format(_("Refresh purchase %s"), "synthetic-ordinary-intent")) ~= nil)
    capture("pending-purchase-list")
    local quote_calls = countCalls("quotePurchase")
    pressButton(review_button)
    check("reopened_range_keeps_pending_outcome_and_read_continuation", contains(screens.dialog.title, _("Chapter access confirmed"))
        and not contains(screens.dialog.title, _("Purchase confirmed")) and contains(screens.dialog.title, _(pending_message))
        and findButton(screens.dialog, _("Read chapter")) ~= nil and countCalls("quotePurchase") == quote_calls
        and countCalls("purchase") == 1)
    check("all_synthetic_callbacks_are_accounted_for", #controller.waiting == 0 and #controller.forbidden == 0)
    for _module_index, name in ipairs(prohibited_modules) do
        check("production_module_remains_unloaded_" .. _module_index, package.loaded[name] == nil)
    end
end

local ok, failure = pcall(run)
report.passed, report.error, report.count = ok, not ok and tostring(failure) or nil, #report.assertions
report.fake_purchase_submission_count = countCalls("purchase")
report.counts = {}; for _call_index, call in ipairs(controller.calls) do report.counts[call.method] = (report.counts[call.method] or 0) + 1 end
pcall(screens.close, screens)
local file = assert(io.open(output_dir .. "/ordinal-range-result.json", "wb"))
assert(file:write(json.encode(report, { pretty = true }))); assert(file:close())
print(json.encode(report, { pretty = true }))
if not ok then error(failure) end
