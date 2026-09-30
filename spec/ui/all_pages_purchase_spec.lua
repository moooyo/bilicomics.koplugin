-- Verify every purchase flow against native KOReader widgets with synthetic records.
return function(env)
local controller, copy, T, W, report = env.controller, env.copy, env.T, env.W, env.report
local UIManager, Device, scribe = env.UIManager, env.Device, env.scribe
local visit, button, activate, finish = env.visit, env.button, env.activate, env.finish
local closeDialog, pressDialog, check = env.closeDialog, env.pressDialog, env.check
local footer, neutralFocus, capture = env.footer, env.neutralFocus, env.capture
local screens = env.screens()
local function scenario(name, callback)
    env.scenario(name, function() screens = env.screens(); callback() end)
end
local function allButtons(widget)
    return visit(widget, function(item) return type(item.text) == "string" and type(item.callback) == "function"
        and type(item.getSize) == "function" end)
end
local function callCount(method)
    local count = 0
    for _, request in ipairs(controller.calls) do if request.method == method then count = count + 1 end end
    return count
end
local quote = { id = "synthetic-quote", episode_id = "13", comic_id = "1", episode_ids = { "13" },
    scope = { kind = "single", order = 1 }, payment = { method = "coin", discount = { kind = "none" } },
    method = "coin", amount = 30, balance = 280, can_afford = true, submittable = true,
    fingerprint = "synthetic-purchase-handoff", amounts = { display = 30, original = 30 },
    expected_access = { ["13"] = { access = "owned" } },
    batch_offers = {
        { scope = { kind = "batch", order = 1, offer_index = 1, start_ord = 13, batch_limit = 5 },
            amount = 5, original_amount = 150, display_amount = 140, available = true },
        { scope = { kind = "batch", order = 1, offer_index = 2, start_ord = 13, batch_limit = 0 },
            amount = 20, original_amount = 600, display_amount = 540, available = true } },
    payments = { { method = "coin", available = true }, { method = "coupon", available = true } } }
controller.wallet = { remain_gold = 280, remain_coupon = 2 }
local native_capture = capture
local function activeSurface() return screens.scope_dialog or screens.dialog end
local function paintedText(surface)
    local lines = {}
    for _, item in ipairs(visit(surface.body or surface, function() return true end)) do
        if type(item.text) == "string" then lines[#lines + 1] = item.text end
    end
    return table.concat(lines, "\n")
end
local function firstPage()
    local surface = activeSurface()
    while surface and surface.page and surface.page > 1 do
        local previous_page = surface.page
        surface:onPreviousPage(); UIManager:forceRePaint(); surface = activeSurface()
        assert(surface and surface.page == previous_page - 1, "The native purchase flow must move backward one page")
    end
    UIManager:forceRePaint()
    return surface
end
local function flowControl(message, optional)
    local surface = activeSurface()
    local control = surface and button(surface, message, true)
    while not control and surface and surface.page and surface.page < surface.pages do
        surface:onNextPage(); UIManager:forceRePaint(); surface = activeSurface()
        control = surface and button(surface, message, true)
    end
    if not optional then assert(control, "The native purchase action was not found: " .. message) end
    return control
end
capture = function(name, options)
    local surface = firstPage()
    local pages = surface and surface.pages or 1
    local before_purchase, before_quote, before_reconcile = callCount("purchase"), callCount("quotePurchase"), callCount("reconcilePurchase")
    local first_text = surface and paintedText(surface)
    native_capture(name, options)
    while surface and surface.page and surface.page < surface.pages do
        local previous_page = surface.page
        surface:onNextPage(); UIManager:forceRePaint(); surface = activeSurface()
        assert(surface and surface.page == previous_page + 1, "The native purchase flow must move forward one page")
        native_capture(name .. "-page-" .. surface.page, options)
    end
    surface = firstPage()
    if pages > 1 then
        native_capture(name .. "-back-to-first", options)
        check(name .. "_backward_roundtrip_restores_first_page_text", paintedText(surface) == first_text)
        check(name .. "_pagination_never_issues_business_requests", callCount("purchase") == before_purchase
            and callCount("quotePurchase") == before_quote and callCount("reconcilePurchase") == before_reconcile)
    end
end
local function start(value)
    screens:showComic("1")
    for _, request in ipairs(controller.waiting) do
        if request.method == "refreshComic" then finish("refreshComic", controller.comics[1]); break end
    end
    screens:_purchaseFor(controller.comics[1], controller.episodes[13])
    finish("quotePurchase", value or quote)
end
local function showIntent(name, values)
    start()
    local intent = { id = "synthetic-record-13", comic_id = "1", episode_ids = { "13" }, quote = copy(quote),
        state = "outcome_unknown", transaction_evidence = "none", created_at = os.time() - 60,
        purpose = "read", access_confirmed_at = os.time() }
    for key, value in pairs(values or {}) do intent[key] = copy(value) end
    screens.purchase_state.intent = intent
    screens:_purchaseDialog(); capture(name, { fullpage = true })
    return intent
end
local function visibleContent(surface)
    local lines = {}
    local original_page = surface == screens.dialog and (surface.page or 1)
    repeat
        for _, item in ipairs(visit(surface.body or surface, function() return true end)) do
            if type(item.text) == "string" then lines[#lines + 1] = item.text end
        end
        if not original_page or not screens.dialog.page or screens.dialog.page >= screens.dialog.pages then break end
        screens.dialog:onNextPage(); UIManager:forceRePaint(); surface = screens.dialog
    until false
    if original_page then
        while screens.dialog.page and screens.dialog.page > original_page do screens.dialog:onPreviousPage(); UIManager:forceRePaint() end
    end
    return table.concat(lines, "\n")
end
local function includes(surface, message)
    return visibleContent(surface):find(T(message), 1, true) ~= nil
end
local function countNativeControls(message)
    local count, original_page = 0, screens.dialog.page or 1
    repeat
        count = count + #visit(screens.dialog, function(item)
            return item.text == T(message) and type(item.callback) == "function"
        end)
        if not screens.dialog.page or screens.dialog.page >= screens.dialog.pages then break end
        screens.dialog:onNextPage(); UIManager:forceRePaint()
    until false
    while screens.dialog.page and screens.dialog.page > original_page do screens.dialog:onPreviousPage(); UIManager:forceRePaint() end
    return count
end
scenario("purchase_ready_and_coupon", function()
    start(); capture("purchase-E1-ready", { fullpage = true })
    check("E1_coupon_balance_is_visible", includes(screens.dialog, string.format(T("Available %s coupons · single chapter only"), 2)))
    check("E1_server_offer_original_is_visible", includes(screens.dialog, string.format(T("Original price %s"), 150)))
    check("E1_offer_amount_is_only_reference", includes(screens.dialog, T("Reference price")))
    check("E1_selected_range_has_no_redundant_original", not visibleContent(screens.dialog):find(string.format(T("Original price %s"), 30), 1, true))
    neutralFocus("E1", string.format(T("Confirm purchase · %s %s"), 30, T("coins")))
    if scribe then check("E1_page_count", screens.dialog.pages == 1, { pages = screens.dialog.pages }) end
    closeDialog()
    local coupon = copy(quote); coupon.method, coupon.payment, coupon.amount, coupon.balance = "coupon", { method = "coupon", coupon_ids = { "synthetic-coupon" } }, 1, 2
    start(coupon); capture("purchase-coupon", { fullpage = true })
    check("coupon_total_does_not_show_coin_original", not visibleContent(screens.dialog):find(string.format(T("Original price %s"), 30), 1, true))
    if scribe then check("coupon_stays_on_one_scribe_page", screens.dialog.pages == 1, { pages = screens.dialog.pages }) end
    check("coupon_method_appears_once", countNativeControls("Reading coupons") == 1)
    local before_purchase, before_quote = callCount("purchase"), callCount("quotePurchase")
    activate(flowControl("Reading coupons"))
    local coupon_request = env.pending("quotePurchase")
    check("coupon_roundtrip_preserves_selected_asset_ids", coupon_request.args[3].method == "coupon"
        and coupon_request.args[3].coupon_ids[1] == "synthetic-coupon")
    check("coupon_roundtrip_only_requests_a_new_quote", callCount("quotePurchase") == before_quote + 1
        and callCount("purchase") == before_purchase)
    finish("quotePurchase", coupon); capture("purchase-coupon-after-roundtrip-requote", { fullpage = true })
    closeDialog(); controller.wallet = { remain_gold = 280 }; start(); capture("purchase-missing-coupon-balance", { fullpage = true })
    check("missing_coupon_balance_is_explicit", includes(screens.dialog, T("Coupon balance unavailable · single chapter only")))
    check("coin_balance_does_not_become_coupons", not includes(screens.dialog, string.format(T("Available %s coupons · single chapter only"), 280)))
    controller.wallet = { remain_gold = 280, remain_coupon = 2 }
end)
scenario("purchase_low_balance", function()
    local low = copy(quote); low.scope, low.episode_ids, low.amount, low.balance, low.can_afford = copy(quote.batch_offers[2].scope), {}, 3132, 280, false
    for index = 13, 32 do low.episode_ids[#low.episode_ids + 1] = tostring(index); low.expected_access[tostring(index)] = { access = "owned" } end
    low.range_proof = { contract = "bilibili_pc_ordinal_range_v1", provenance = "primary_sdk_ordinal_contract_and_quote_catalog_consistency" }
    low.amounts = { original = 3480, display = 3132 }; low.payments[2].available = false
    low.batch_offers[2].display_amount, low.batch_offers[2].original_amount = 3132, 3480
    start(low); capture("purchase-E2-low-balance", { fullpage = true })
    check("E2_deficit_is_visible", visibleContent(screens.dialog):find("2,852", 1, true) ~= nil)
    check("E2_total_uses_thousands_separator", visibleContent(screens.dialog):find("3,132", 1, true) ~= nil)
    check("E2_missing_unselected_price_is_explicit", includes(screens.dialog, "Price unavailable"))
    check("E2_does_not_enable_confirmation", button(screens.dialog, string.format(T("Confirm purchase · %s %s"), "3,132", T("coins")), true) == nil)
    footer("E2", "Refresh balance", "Recharge coins ›")
    if scribe then check("E2_page_count", screens.dialog.pages == 1, { pages = screens.dialog.pages }) end
end)
scenario("purchase_submitting", function()
    start(); capture("purchase-before-submission-roundtrip", { fullpage = true })
    local confirm, before_purchase = button(screens.dialog, string.format(T("Confirm purchase · %s %s"), 30, T("coins"))), callCount("purchase")
    activate(confirm); confirm.callback()
    check("submission_after_roundtrip_sends_exactly_one_request", callCount("purchase") == before_purchase + 1)
    capture("purchase-E3-submitting", { fullpage = true })
    check("E3_header_has_no_controls", #allButtons(screens.dialog.header) == 0)
    check("E3_footer_is_disabled", screens.dialog.footer_buttons[1].enabled == false and screens.dialog.footer_buttons[2].enabled == false)
    check("E3_scope_is_frozen", includes(screens.dialog, T("Only this chapter")))
end)
scenario("purchase_pending", function()
    showIntent("purchase-E4-pending")
    check("E4_no_purchase_action", button(screens.dialog, string.format(T("Confirm purchase · %s %s"), 30, T("coins")), true) == nil)
    check("E4_terms_are_not_payment", includes(screens.dialog, T("Submitted terms are a reference, not proof of payment.")))
    local before = callCount("purchase")
    activate(button(screens.dialog, "Refresh result")); capture("purchase-checking-result", { fullpage = true })
    check("E4_refresh_does_not_purchase", callCount("purchase") == before)
end)
scenario("purchase_confirmed", function()
    showIntent("purchase-E5-confirmed", { state = "access_confirmed", transaction_evidence = "server_accepted", access_evidence = { ["13"] = { access = "owned" } } })
    local chapter_label = string.format(T("Chapter %s · %s"), 13, controller.episodes[13].title)
    check("E5_owned_access_has_permanent_copy", includes(screens.dialog, string.format(T("%s · permanently unlocked"), chapter_label)))
    check("E5_has_three_footer_actions", #screens.dialog.footer_buttons == 3)
    check("E5_payment_copy_is_quote_evidence", includes(screens.dialog, T("Confirmed quote")))
    closeDialog()
    showIntent("purchase-access-only", { state = "access_confirmed", transaction_evidence = "none" })
    check("access_only_has_no_purchase_confirmation", includes(screens.dialog, T("Chapter access confirmed")))
    check("access_only_does_not_claim_permanent_without_evidence", not includes(screens.dialog, string.format(T("%s · permanently unlocked"), chapter_label)))
    check("access_only_keeps_reference_disclaimer", includes(screens.dialog, T("Submitted terms are a reference, not proof of payment.")))
end)
scenario("purchase_recovery", function()
    showIntent("purchase-rejected", { state = "rejected", transaction_evidence = "server_rejected" })
    check("rejected_has_explicit_new_quote", button(screens.dialog, "Get new quote", true) ~= nil)
    closeDialog(); showIntent("purchase-persistence-pending", { state = "access_confirmed", persistence_pending = true })
    check("persistence_pending_does_not_offer_read", button(screens.dialog, "Read chapter", true) == nil)
    closeDialog(); showIntent("purchase-range-pending", { state = "access_confirmed", range_outcome_pending = true })
    check("range_pending_keeps_range_uncertainty", includes(screens.dialog, T("The range purchase result remains unverified. Reading access does not prove which chapters were purchased. Further purchases for this comic remain paused.")))
    closeDialog(); start(); screens.purchase_state.error = { kind = "quote_expired" }; screens:_purchaseDialog(); capture("purchase-quote-expired", { fullpage = true })
    check("expired_has_explicit_refresh", button(screens.dialog, "Refresh quote", true) ~= nil)
    closeDialog(); start(); screens.purchase_state.error = { kind = "quote_changed" }; screens:_purchaseDialog(); capture("purchase-quote-changed", { fullpage = true })
    check("changed_has_explicit_refresh", button(screens.dialog, "Refresh quote", true) ~= nil)
    closeDialog(); start(); screens:_purchaseChoices("payment"); capture("purchase-payment-options", { fullpage = true })
    activate(flowControl("Back to quote")); UIManager:forceRePaint()
    screens:_purchaseRecordDetails(screens.purchase_state); capture("purchase-record-details", { fullpage = true })
    activate(flowControl("Back")); UIManager:forceRePaint()
    check("scope_details_roundtrip_restores_live_quote", screens.scope_dialog == nil
        and button(screens.dialog, string.format(T("Confirm purchase · %s %s"), 30, T("coins")), true) ~= nil)
end)

scenario("purchase_pending_record_roundtrip", function()
    local range_quote = copy(quote)
    range_quote.scope, range_quote.episode_ids, range_quote.amount = copy(quote.batch_offers[2].scope), {}, 540
    range_quote.range_proof = { contract = "bilibili_pc_ordinal_range_v1", provenance = "primary_sdk_ordinal_contract_and_quote_catalog_consistency" }
    for index = 13, 32 do range_quote.episode_ids[#range_quote.episode_ids + 1] = tostring(index); range_quote.expected_access[tostring(index)] = { access = "owned" } end
    local intent = showIntent("purchase-pending-many-chapters", { quote = range_quote, episode_ids = range_quote.episode_ids })
    local before_purchase, before_reconcile = callCount("purchase"), callCount("reconcilePurchase")
    local record_control = flowControl("Purchase record and scope")
    local covered_refresh = button(screens.dialog, "Refresh result").callback
    activate(record_control); capture("purchase-pending-record-details-roundtrip", { fullpage = true })
    check("pending_record_details_exercise_multiple_native_pages", screens.scope_dialog.pages > 1)
    covered_refresh()
    check("covered_pending_refresh_remains_inactive", callCount("reconcilePurchase") == before_reconcile
        and callCount("purchase") == before_purchase)
    activate(flowControl("Back")); UIManager:forceRePaint()
    check("pending_record_back_restores_unknown_result", screens.scope_dialog == nil and screens.purchase_state.intent.state == "outcome_unknown")
    local refresh = button(screens.dialog, "Refresh result")
    activate(refresh); refresh.callback()
    check("pending_roundtrip_reconciles_once_without_repurchase", callCount("reconcilePurchase") == before_reconcile + 1
        and callCount("purchase") == before_purchase)
    finish("reconcilePurchase", intent); capture("purchase-pending-after-roundtrip-reconcile", { fullpage = true })
    local stale_refresh, generation, account = button(screens.dialog, "Refresh result").callback, controller.generation, controller.account_key
    controller.generation = generation + 1; stale_refresh()
    controller.generation, controller.account_key = generation, "synthetic-other-account"; stale_refresh()
    controller.account_key = account
    check("pending_roundtrip_retains_account_and_generation_guards", callCount("reconcilePurchase") == before_reconcile + 1
        and callCount("purchase") == before_purchase)
end)

scenario("purchase_payment_options_roundtrip", function()
    local offers = copy(quote)
    offers.discount_options = {}
    for index = 1, 7 do
        offers.discount_options[index] = { payment = { method = "coin", discount = { kind = "discount_card", id = "synthetic-offer-" .. index } },
            available = true, expire_time = os.time() + 86400 }
    end
    start(offers); screens:_purchaseChoices("payment")
    local before_purchase, before_quote, page = callCount("purchase"), callCount("quotePurchase"), 1
    capture("purchase-many-payment-options-1", { fullpage = true })
    local next_page = flowControl("Next", true)
    while next_page and next_page.enabled ~= false do
        activate(next_page); page = page + 1
        capture("purchase-many-payment-options-" .. page, { fullpage = true })
        next_page = flowControl("Next", true)
    end
    check("payment_options_exercise_multiple_selection_pages", page > 1)
    local previous_page = flowControl("Previous", true)
    while previous_page and previous_page.enabled ~= false do
        activate(previous_page); UIManager:forceRePaint(); page = page - 1
        capture("purchase-payment-options-back-" .. page, { fullpage = true })
        previous_page = flowControl("Previous", true)
    end
    firstPage(); UIManager:forceRePaint()
    check("payment_selection_roundtrip_returns_to_first_page", page == 1)
    check("payment_selection_roundtrip_does_not_quote_or_purchase", callCount("quotePurchase") == before_quote and callCount("purchase") == before_purchase)
    activate(flowControl("Back to quote")); UIManager:forceRePaint()
    check("payment_options_roundtrip_back_control_is_live", button(screens.dialog, string.format(T("Confirm purchase · %s %s"), 30, T("coins")), true) ~= nil)
end)

end
