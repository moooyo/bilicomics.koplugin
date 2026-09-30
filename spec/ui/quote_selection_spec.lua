-- Native quote-selection UI coverage with synthetic callbacks only.
-- The runner must create a network namespace before launching this file.
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
local current_namespace = ffi.string(namespace_buffer, namespace_length)
assert(parent_namespace ~= "" and current_namespace ~= parent_namespace, "A separate network namespace is required")
local routes = assert(io.open("/proc/net/route", "rb"))
local route_count = 0
for line in routes:lines() do
    if line:match("%S") and not line:match("^Iface%s") then route_count = route_count + 1 end
end
assert(routes:close())
assert(route_count == 0, "The isolated namespace must have no network routes")

G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local prohibited_modules = { "bilicomics/controller", "bilicomics/runtime", "bilicomics/protocol/client",
    "bilicomics/protocol/transport", "bilicomics/protocol/session", "bilicomics/purchase/service",
    "bilicomics/purchase/quote_fetch", "bilicomics/purchase/quote", "bilicomics/purchase/candidate",
    "bilicomics/purchase/selection" }
for _module_index, name in ipairs(prohibited_modules) do
    assert(package.loaded[name] == nil, "A production business module was already loaded")
    package.preload[name] = function() error("Production business modules are forbidden in this synthetic UI spec") end
end
require("gettext").current_lang = "zh_CN"
local UIManager = require("ui/uimanager")
local json = require("rapidjson")
local Screens = require("bilicomics/ui/screens")
local _ = require("bilicomics/ui/i18n")
local report = { spec = "native-synthetic-quote-selection", source = "spec/ui/quote_selection_spec.lua",
    runtime = "KOReader v2026.07.1", width = Device.screen:getWidth(), height = Device.screen:getHeight(),
    synthetic_only = true, purchase_submissions_fake = true, actual_purchase_executed = false,
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
local function contains(text, fragment)
    return type(text) == "string" and text:find(fragment, 1, true) ~= nil
end
local function safeText(text)
    for _marker_index, marker in ipairs({ "SDK_SECRET", "https://unsafe.invalid", "/private/quote.bin", "raw-token-value" }) do
        if contains(text, marker) then return false end
    end
    return true
end
local coin = { method = "coin", discount = { kind = "none" } }
local coupon = { method = "coupon", coupon_ids = { "0000000017", "0098000000000000123" } }
local single = { kind = "single", order = 1 }
local offers, discounts = {}, {}
for index = 1, 7 do
    offers[index] = { scope = { kind = "batch", offer_index = 100 + index, batch_limit = index + 2,
        start_ord = index + 0.25, order = 1 }, amount = index + 2, original_amount = 3030 + index,
        display_amount = 2020 + index, available = index ~= 4 }
    discounts[index] = { payment = { method = "coin", discount = { kind = "discount_card", id = string.format("card-%03d", index) } },
        available = index ~= 3, display_amount = 4040 + index }
end
local controller = { generation = 1, account_key = "bili_synthetic_ui", calls = {}, waiting = {}, forbidden = {},
    sequence = 0, comic = { id = "10", title = "Synthetic quote comic", authors = { "UI fixture" } }, episodes = {} }
for index = 20, 31 do
    controller.episodes[#controller.episodes + 1] = { id = tostring(index), comic_id = "10", order = index - 19,
        title = "Synthetic chapter " .. index, access = "locked" }
end
local allowed = { getAccount = true, getComic = true, getEpisodes = true, getPendingPurchases = true, getWallet = true,
    quotePurchase = true, refreshWallet = true, purchase = true, reconcilePurchase = true }
local function record(method, args)
    assert(allowed[method], "Unexpected synthetic controller operation")
    local call = { method = method, args = copy(args or {}) }
    controller.calls[#controller.calls + 1] = call
    return call
end
local function enqueue(method, args, callback)
    local call = record(method, args)
    controller.sequence = controller.sequence + 1
    local request = { id = controller.sequence, method = method, args = copy(call.args), callback = callback }
    controller.waiting[#controller.waiting + 1] = request
    return request
end
function controller:getAccount()
    record("getAccount"); return { id = "synthetic_ui", account_key = self.account_key, session_valid = true }
end
function controller:getComic() record("getComic"); return copy(self.comic) end
function controller:getEpisodes() record("getEpisodes"); return copy(self.episodes) end
function controller:getPendingPurchases() record("getPendingPurchases"); return {} end
function controller:getWallet() record("getWallet"); return {} end
function controller:cancelPendingRead() end
function controller:quotePurchase(episode_id, scope, payment, callback)
    enqueue("quotePurchase", { episode_id, scope, payment }, callback)
end
function controller:refreshWallet(callback) enqueue("refreshWallet", {}, callback) end
function controller:purchase(quote, purpose, callback) enqueue("purchase", { quote, purpose }, callback) end
function controller:reconcilePurchase(intent_id, callback) enqueue("reconcilePurchase", { intent_id }, callback) end
setmetatable(controller, { __index = function(_controller, key)
    if key == "requestCover" or key == "isFavoritePending" or key == "getBookshelfSyncState" or key == "getDownloads" then return nil end
    controller.forbidden[#controller.forbidden + 1] = tostring(key)
    error("Controller member is outside the synthetic UI allowlist: " .. tostring(key))
end })
local function callCount(method)
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
            local delivered = copy(value)
            waiting.callback(delivered, copy(err))
            return delivered
        end
    end
    error("The synthetic callback was already delivered")
end
local function fixture(request, candidate, overrides)
    assert(request.method == "quotePurchase")
    local scope, payment = copy(request.args[2]), copy(request.args[3])
    local ids, access = {}, {}
    for offset = 0, (scope.kind == "batch" and scope.batch_limit or 1) - 1 do
        local id = tostring(tonumber(request.args[1]) + offset)
        ids[#ids + 1], access[id] = id, { access = "owned" }
    end
    local result = { id = "synthetic-quote-" .. request.id, episode_id = request.args[1], comic_id = "10",
        submittable = not candidate, scope = scope, payment = payment, method = payment.method,
        amount = payment.method == "coupon" and 2 or 45, balance = 100, can_afford = true,
        fingerprint = "synthetic-fingerprint-" .. request.id, episode_ids = ids, expected_access = access,
        scopes = { copy(single), copy(offers[1].scope) },
        payments = { copy(coin), copy(coupon) }, batch_offers = copy(offers), discount_options = copy(discounts) }
    if candidate then
        -- Misleading legacy fields deliberately cannot override the advisory flag.
        result.amount, result.fingerprint = 90901, "synthetic-advisory-fingerprint"
        result.amounts = { original = 303.75, display = 101.25, submission = 202.5, free_gold = 4.5 }
        result.blockers = { "scope_unverified", "amount_unverified", "discount_unverified",
            "SDK_SECRET https://unsafe.invalid/?token=raw-token-value /private/quote.bin" }
    end
    for key, value in pairs(overrides or {}) do result[key] = copy(value) end
    return result
end

local screens = Screens.new{ controller = controller }
screens:_ensureRouteViews()
local function nativeButtons(widget, result, seen)
    result, seen = result or {}, seen or {}
    if type(widget) ~= "table" or seen[widget] then return result end
    seen[widget] = true
    if type(widget.text) == "string" and type(widget.callback) == "function" then result[#result + 1] = widget end
    for _child_index, child in ipairs(widget) do nativeButtons(child, result, seen) end
    for _, field in ipairs({ "content", "layout", "body", "footer" }) do nativeButtons(widget[field], result, seen) end
    return result
end
local function findButton(widget, text)
    for _button_index, button in ipairs(nativeButtons(widget)) do if button.text == text then return button end end
end
local function pressButton(button)
    assert(button and button.enabled ~= false and button.callback, "The requested native button is unavailable")
    button.callback()
end
local function pressScreen(text)
    for _row_index, row in ipairs(screens.focus or {}) do
        for _button_index, button in ipairs(row) do if button.text == text then pressButton(button); return end end
    end
    -- Purchase behavior is independent of the chapter row's composed visual label.
    for _, episode in ipairs(controller.episodes) do
        if episode.title == text then screens:_purchaseFor(controller.comic, episode); return end
    end
    error("No screen button matches the requested synthetic chapter")
end
local function pressDialog(message)
    assert(screens.dialog and UIManager:getTopmostVisibleWidget() == screens.dialog, "The main dialog must be topmost")
    local button = findButton(screens.dialog, _(message))
    if not button and message == "Close" then button = findButton(screens.dialog, _("Cancel")) end
    if not button and (message == "Choose range" or message == "Choose payment") then
        screens:_purchaseChoices(message == "Choose range" and "scope" or "payment")
        return
    end
    while not button and screens.dialog.page and screens.dialog.page < screens.dialog.pages do
        screens.dialog:onNextPage()
        button = findButton(screens.dialog, _(message))
    end
    pressButton(button)
end
local function closeDetails()
    if screens.scope_dialog then UIManager:close(screens.scope_dialog); screens.scope_dialog = nil end
end
local function shownText(widget, result, seen)
    result, seen = result or {}, seen or {}
    if type(widget) ~= "table" or seen[widget] then return table.concat(result, "\n") end
    seen[widget] = true
    if type(widget.text) == "string" then result[#result + 1] = widget.text end
    if type(widget.title) == "string" then result[#result + 1] = widget.title end
    if type(widget.purchase_text) == "string" then result[#result + 1] = widget.purchase_text end
    for _child_index, child in ipairs(widget) do shownText(child, result, seen) end
    return table.concat(result, "\n")
end
local function capture(name)
    local size = assert(screens.widget).content:getSize()
    check(name .. "_screen_fits", size.w <= report.width and size.h <= report.height)
    UIManager:forceRePaint()
    local top = screens.scope_dialog and UIManager:isWidgetShown(screens.scope_dialog) and screens.scope_dialog or screens.dialog
    if top and UIManager:isWidgetShown(top) then
        local box = top.movable and top.movable:getSize() or top:getSize()
        check(name .. "_dialog_fits", box.w <= report.width and box.h <= report.height, { width = box.w, height = box.h })
        check(name .. "_dialog_is_topmost", UIManager:getTopmostVisibleWidget() == top)
        check(name .. "_display_is_safe", safeText(shownText(top)))
    end
    Device.screen.bb:writePNG(output_dir .. "/" .. name .. ".png")
    report.screens[#report.screens + 1] = name .. ".png"
end
local function reset()
    screens:close()
    assert(#controller.waiting == 0, "A previous synthetic callback remains pending")
    screens.loaded["comic:10"] = true
    screens:showComic("10")
end
local function openQuote(candidate, overrides)
    reset(); pressScreen("Synthetic chapter 20")
    local request = pending("quotePurchase")
    local result = finish(request, fixture(request, candidate, overrides))
    return result
end
local function finishQuote(candidate, overrides)
    local request = pending("quotePurchase")
    return finish(request, fixture(request, candidate, overrides)), request
end
local confirm_prefix = assert(_("Confirm purchase · %s %s"):match("^(.-)%%"))
local function confirmButtons()
    local result = {}
    for _button_index, button in ipairs(nativeButtons(screens.dialog)) do
        if button.text:sub(1, #confirm_prefix) == confirm_prefix then result[#result + 1] = button end
    end
    return result
end
local function optionButtons()
    local result = {}
    for _button_index, button in ipairs(nativeButtons(screens.dialog)) do
        if button.text:sub(1, 4) == "● " or button.text:sub(1, 4) == "○ " then result[#result + 1] = button end
    end
    return result
end
local function firstChoicePage()
    while true do
        local previous = findButton(screens.dialog, _("Previous"))
        if not previous or previous.enabled == false then return end
        pressButton(previous)
    end
end
local function walkChoices(which, prefix, expected_entries)
    pressDialog(which == "scope" and "Choose range" or "Choose payment")
    firstChoicePage()
    local labels, selected, pages, disabled = {}, 0, 0, 0
    while true do
        pages = pages + 1
        local buttons = optionButtons()
        check(prefix .. "_page_" .. pages .. "_has_visible_options", #buttons >= 1, #buttons)
        for _button_index, button in ipairs(buttons) do
            labels[button.text:sub(5)] = true
            if button.text:sub(1, 4) == "● " then selected = selected + 1 end
            if button.enabled == false then
                disabled = disabled + 1
                local before = callCount("quotePurchase")
                button.callback()
                check(prefix .. "_disabled_option_does_not_requote_" .. pages, callCount("quotePurchase") == before)
            end
        end
        capture(prefix .. "-page-" .. pages)
        local next_button = assert(findButton(screens.dialog, _("Next")))
        if next_button.enabled == false then break end
        pressButton(next_button)
    end
    local count = 0; for _label in pairs(labels) do count = count + 1 end
    check(prefix .. "_all_options_are_reachable", count == expected_entries and pages >= 1)
    check(prefix .. "_only_one_complete_selection_is_marked", selected == 1)
    check(prefix .. "_unavailable_options_are_disabled", disabled > 0)
    pressDialog("Back to quote")
    return labels
end
local function choose(which, label, detail)
    pressDialog(which == "scope" and "Choose range" or "Choose payment")
    firstChoicePage()
    while true do
        for _button_index, button in ipairs(optionButtons()) do
            local heading = button.text:sub(5):match("^[^\n]+")
            if heading == label and (not detail or contains(button.text, detail)) then
                pressButton(button); return pending("quotePurchase")
            end
        end
        local next_button = assert(findButton(screens.dialog, _("Next")))
        assert(next_button.enabled ~= false, "The requested synthetic option is absent")
        pressButton(next_button)
    end
end
local function chooseOrder(message)
    pressDialog("Choose payment")
    local priority_prefix = assert(_("Offer priority: %s"):match("^(.-)%%"))
    local priority
    for _button_index, button in ipairs(nativeButtons(screens.dialog)) do
        if button.text:sub(1, #priority_prefix) == priority_prefix then priority = button end
    end
    pressButton(assert(priority, "Payment options must expose their offer priority"))
    for _button_index, button in ipairs(optionButtons()) do
        if button.text:sub(5) == _(message) then pressButton(button); return pending("quotePurchase") end
    end
    error("The requested order control is absent")
end
local function checkCandidate(name, quote)
    check(name .. "_has_no_confirmation_button", #confirmButtons() == 0)
    check(name .. "_has_no_exact_scope_action", findButton(screens.dialog, _("Review exact chapters")) == nil)
    local text = shownText(screens.dialog)
    check(name .. "_does_not_claim_exact_scope_or_ownership", not contains(text, _("Permanent ownership"))
        and not contains(text, _("Chapter reading access")) and not contains(text, "90901"))
    check(name .. "_keeps_unverified_amounts_in_details", not contains(text, "101.25") and not contains(text, "202.5")
        and contains(text, _("The final charge or chapter access is not verified. This offer cannot be submitted.")))
    check(name .. "_main_dialog_does_not_expand_option_lists", #nativeButtons(screens.dialog) <= 8
        and not contains(text, string.format(_("Batch offer %d"), 7))
        and not contains(text, string.format(_("Coin discount option %d"), 7)))
    capture(name)
    pressDialog("Offer details")
    local details = assert(screens.scope_dialog).text
    check(name .. "_keeps_amount_observations_separate", contains(details, string.format(_("Platform original price: %s"), "303.75"))
        and contains(details, string.format(_("Platform display reference: %s"), "101.25"))
        and contains(details, string.format(_("Settlement reference (not confirmed charge): %s"), "202.5"))
        and contains(details, string.format(_("Free-coin deduction reference: %s"), "4.5")) and not contains(details, tostring(quote.amount)))
    check(name .. "_blockers_use_fixed_safe_messages", safeText(details) and contains(details, _("Chapter range is not verified."))
        and contains(details, _("Additional verification is required.")))
    capture(name .. "-details"); closeDetails()
end

local function run()
    local quote = openQuote(true)
    local first_quote_call
    for _call_index, call in ipairs(controller.calls) do
        if call.method == "quotePurchase" then first_quote_call = call; break end
    end
    check("initial_quote_uses_normalized_complete_selection", first_quote_call ~= nil
        and first_quote_call.args[1] == "20" and equal(first_quote_call.args[2], single) and equal(first_quote_call.args[3], coin))
    checkCandidate("single-candidate", quote)
    walkChoices("scope", "range-options", 8)
    walkChoices("payment", "payment-options", 9)
    local request = choose("scope", string.format(_("Requested batch: %s chapters"), tostring(offers[6].scope.batch_limit)))
    check("scope_choice_preserves_full_payment_and_selector", equal(request.args[2], offers[6].scope) and equal(request.args[3], coin))
    check("scope_selection_does_not_include_server_amounts", request.args[2].amount == nil and request.args[2].display_amount == nil
        and request.args[2].original_amount == nil and request.args[2].available == nil)
    quote = finish(request, fixture(request, true))
    checkCandidate("batch-candidate", quote)
    request = choose("payment", string.format(_("Coins · %s"), _("Discount coupon")), string.format(_("Asset: %s"), "card-007"))
    check("payment_choice_preserves_full_scope_and_discount_identity", equal(request.args[2], offers[6].scope)
        and equal(request.args[3], discounts[7].payment) and request.args[3].display_amount == nil and request.args[3].available == nil)
    finish(request, fixture(request, true))
    local batch_scope, selected_payment = copy(screens.purchase_state.scope), copy(screens.purchase_state.payment)
    request = chooseOrder("Expiry first")
    batch_scope.order = 2
    check("batch_expiry_order_requotes_the_same_selection", equal(request.args[2], batch_scope) and equal(request.args[3], selected_payment))
    finish(request, fixture(request, true))
    request = chooseOrder("Discount first"); batch_scope.order = 1
    check("batch_discount_order_requotes_the_same_selection", equal(request.args[2], batch_scope) and equal(request.args[3], selected_payment))
    finish(request, fixture(request, true))
    request = choose("scope", _("Single chapter"))
    check("returning_to_single_keeps_discount_selection", equal(request.args[2], single) and equal(request.args[3], selected_payment))
    finish(request, fixture(request, true))
    request = chooseOrder("Expiry first")
    check("single_expiry_order_requotes_without_losing_payment", equal(request.args[2], { kind = "single", order = 2 })
        and equal(request.args[3], selected_payment))
    finish(request, fixture(request, true))
    request = chooseOrder("Discount first")
    check("single_discount_order_requotes_without_losing_payment", equal(request.args[2], single) and equal(request.args[3], selected_payment))
    finish(request, fixture(request, true))

    request = choose("payment", _("Reading coupons"))
    quote = finish(request, fixture(request, false))
    check("coupon_choice_preserves_the_scope", equal(request.args[2], single) and equal(request.args[3], coupon))
    local snapshot_ids = copy(quote.payment.coupon_ids)
    screens.purchase_state.payment.coupon_ids = { "999999" }
    pressDialog("Review exact chapters")
    local detail_text = screens.scope_dialog.text
    check("coupon_details_use_the_quoted_snapshot", contains(detail_text, _("Coupon IDs (identification only):"))
        and contains(detail_text, "\n" .. snapshot_ids[1] .. "\n") and contains(detail_text, snapshot_ids[2])
        and not contains(detail_text, "999999"))
    check("coupon_identifiers_keep_leading_zeroes", snapshot_ids[1] == "0000000017" and snapshot_ids[2] == "0098000000000000123")
    capture("coupon-snapshot-details"); closeDetails()
    screens.purchase_state.payment = copy(quote.payment)
    check("coupon_details_do_not_submit", callCount("purchase") == 0)

    quote = openQuote(false)
    local stale_confirm = assert(confirmButtons()[1])
    pressDialog("Choose range")
    stale_confirm.callback()
    check("covered_confirmation_cannot_submit", callCount("purchase") == 0)
    local stale_option = assert(optionButtons()[2])
    local quote_count = callCount("quotePurchase")
    pressDialog("Back to quote"); stale_option.callback()
    check("closed_selection_dialog_cannot_requote", callCount("quotePurchase") == quote_count)
    request = choose("scope", string.format(_("Requested batch: %s chapters"), tostring(offers[2].scope.batch_limit)))
    stale_confirm.callback()
    check("old_confirmation_is_inert_during_requote", callCount("purchase") == 0)
    finish(request, fixture(request, true)); stale_confirm.callback()
    check("old_confirmation_cannot_submit_an_advisory_quote", callCount("purchase") == 0 and #confirmButtons() == 0)

    reset(); pressScreen("Synthetic chapter 20")
    local older_request = pending("quotePurchase")
    pressDialog("Close"); pressScreen("Synthetic chapter 21")
    local newer_request
    for _request_index, waiting in ipairs(controller.waiting) do if waiting ~= older_request then newer_request = waiting end end
    local newer_quote = finish(assert(newer_request), fixture(newer_request, true))
    finish(older_request, fixture(older_request, false))
    check("older_quote_callback_cannot_replace_a_new_selection", screens.purchase_state.quote == newer_quote
        and screens.purchase_state.episode.id == "21" and #confirmButtons() == 0)

    quote = openQuote(false)
    request = choose("scope", string.format(_("Requested batch: %s chapters"), tostring(offers[6].scope.batch_limit)))
    quote = finish(request, fixture(request, false, { can_afford = false, balance = 1 }))
    local before_scope, before_payment = copy(screens.purchase_state.scope), copy(screens.purchase_state.payment)
    check("insufficient_balance_retains_the_complete_selection", screens.purchase_state.quote.can_afford == false
        and findButton(screens.dialog, _("Refresh balance")) ~= nil and #confirmButtons() == 0
        and equal(before_scope, offers[6].scope))
    capture("insufficient-balance")
    pressDialog("Refresh balance")
    finish(pending("refreshWallet"), { remain_gold = 100 })
    request = pending("quotePurchase")
    check("balance_refresh_requotes_without_resetting_selection", equal(request.args[2], before_scope) and equal(request.args[3], before_payment))
    finish(request, fixture(request, false, { can_afford = false, balance = 1 }))
    pressDialog("Refresh balance")
    local old_balance = pending("refreshWallet")
    request = choose("payment", string.format(_("Coins · %s"), _("Discount coupon")), string.format(_("Asset: %s"), "card-005"))
    local replacement_quote = finish(request, fixture(request, true))
    quote_count = callCount("quotePurchase")
    finish(old_balance, { remain_gold = 100 })
    check("stale_balance_callback_does_not_restore_old_selection", callCount("quotePurchase") == quote_count
        and screens.purchase_state.quote == replacement_quote and equal(screens.purchase_state.payment, discounts[5].payment))

    quote = openQuote(false)
    pressDialog("Choose payment")
    local account_option = assert(optionButtons()[1])
    quote_count = callCount("quotePurchase")
    controller.generation = controller.generation + 1
    account_option.callback()
    check("account_generation_invalidates_selection_dialog", callCount("quotePurchase") == quote_count)
    reset(); pressScreen("Synthetic chapter 20")
    request = pending("quotePurchase")
    local pending_dialog = screens.dialog
    controller.generation = controller.generation + 1
    finish(request, fixture(request, false))
    check("same_account_new_generation_ignores_quote_feedback", screens.dialog == pending_dialog and screens.purchase_state.quote == nil)

    local legacy_scope = { kind = "batch", batch_limit = 3, start_ord = 1.5, order = 1 }
    quote = openQuote(false, { batch_offers = {}, discount_options = {}, scopes = { copy(single), legacy_scope } })
    request = choose("scope", string.format(_("Requested batch: %s chapters"), "3"))
    check("legacy_supported_scope_remains_selectable", equal(request.args[2], legacy_scope) and equal(request.args[3], coin))
    finish(request, fixture(request, true))

    quote = openQuote(false)
    check("all_preview_scenarios_submit_nothing", callCount("purchase") == 0)
    local submit = assert(confirmButtons()[1])
    check("final_confirmation_uses_the_exact_server_amount", submit.text == string.format(_("Confirm purchase · %s %s"), "45", _("coins")))
    capture("synthetic-single-confirmation")
    pressButton(submit)
    local submission = pending("purchase")
    check("explicit_confirmation_dispatches_one_fake_submission", callCount("purchase") == 1
        and equal(submission.args[1], quote) and submission.args[2] == "read")
    submit.callback()
    check("duplicate_confirmation_cannot_dispatch_again", callCount("purchase") == 1)
    local frozen = true
    for _button_index, button in ipairs(nativeButtons(screens.dialog)) do if button.enabled ~= false then frozen = false end end
    check("submission_freezes_all_visible_controls", frozen)
    local saved_amount = submission.args[1].amount
    quote.amount = 777777
    check("fake_controller_records_are_deep_snapshots", submission.args[1].amount == saved_amount)
    finish(submission, { id = "synthetic-intent", state = "accepted", comic_id = "10", episode_ids = { "20" },
        quote = copy(submission.args[1]), purpose = "read", transaction_evidence = "server_accepted" })
    submit.callback()
    check("finished_confirmation_remains_single_submission", callCount("purchase") == 1 and #confirmButtons() == 0)
    capture("synthetic-submission-result")
    check("all_callbacks_were_synthetic_and_accounted_for", #controller.waiting == 0 and #controller.forbidden == 0)
    for _module_index, name in ipairs(prohibited_modules) do
        check("production_module_stays_unloaded_" .. _module_index, package.loaded[name] == nil)
    end
end

local ok, failure = pcall(run)
report.passed, report.error, report.count = ok, not ok and tostring(failure) or nil, #report.assertions
report.fake_purchase_submission_count = callCount("purchase")
report.counts = {}
for _call_index, call in ipairs(controller.calls) do report.counts[call.method] = (report.counts[call.method] or 0) + 1 end
pcall(screens.close, screens)
local file = assert(io.open(output_dir .. "/quote-selection-result.json", "wb"))
assert(file:write(json.encode(report, { pretty = true }))); assert(file:close())
print(json.encode(report, { pretty = true }))
if not ok then error(failure) end
