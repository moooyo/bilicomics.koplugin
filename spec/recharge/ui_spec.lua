-- Exercise real recharge widgets with isolated, synthetic controller callbacks.
-- In-memory records model controller ownership; durable storage is tested separately.
require("setupkoenv")
local source, output_dir = assert(arg[1]), assert(arg[2])
local ffi = require("ffi")
require("ffi/posix_h")
if not pcall(function() return ffi.C.readlink end) then
    ffi.cdef[[long readlink(const char *path, char *buffer, unsigned long size);]]
end
local parent_namespace = assert(os.getenv("BILI_RECHARGE_PARENT_NETNS"), "The parent network namespace is required")
local namespace_buffer = ffi.new("char[256]")
local namespace_length = tonumber(ffi.C.readlink("/proc/self/ns/net", namespace_buffer, 256))
assert(namespace_length and namespace_length > 0 and namespace_length < 256, "Cannot inspect the current network namespace")
assert(parent_namespace ~= "" and ffi.string(namespace_buffer, namespace_length) ~= parent_namespace,
    "A separate network namespace is required")
local routes, route_count = assert(io.open("/proc/net/route", "rb")), 0
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
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local prohibited_modules = { "bilicomics/controller", "bilicomics/runtime", "bilicomics/protocol/client",
    "bilicomics/protocol/transport", "bilicomics/protocol/session", "bilicomics/recharge/service",
    "bilicomics/purchase/service", "bilicomics/purchase/quote_fetch" }
for module_index, name in ipairs(prohibited_modules) do
    assert(package.loaded[name] == nil, "A production business module was already loaded")
    package.preload[name] = function() error("Production business modules are forbidden in this synthetic UI spec") end
end
require("gettext").current_lang = arg[3] or "zh_CN"
local UIManager = require("ui/uimanager")
local Screens = require("bilicomics/ui/screens")
local json = require("rapidjson")
local T = require("bilicomics/ui/i18n")
local report = { spec = "native-synthetic-recharge-ui", synthetic_only = true, actual_order_created = false,
    actual_payment_made = false, network_namespace_isolated = true, no_network_routes = true,
    width = Device.screen:getWidth(), height = Device.screen:getHeight(), assertions = {}, screens = {},
    storage_scope = "In-memory controller snapshots only; no durable-storage claim" }
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
local function contains(text, fragment) return type(text) == "string" and text:find(fragment, 1, true) ~= nil end
local function safeText(text)
    for marker_index, marker in ipairs({ "SDK_SECRET", "raw-token-value", "synthetic-cookie", "/private/recharge" }) do
        if contains(text, marker) then return false end
    end
    return true
end
local timers, schedule_in, unschedule = {}, UIManager.scheduleIn, UIManager.unschedule
UIManager.scheduleIn = function(manager, delay, callback) timers[callback] = delay end
UIManager.unschedule = function(manager, callback) timers[callback] = nil end
local controller = { generation = 1, closed = false, account_key = "bili_recharge_fixture", account_id = "10001",
    calls = {}, waiting = {}, forbidden = {}, orders = {}, sequence = 0, config_snapshot = false,
    wallet = { remain_gold = 100, remain_coupon = 2 }, signed_in = true, recharge_supported = true }
local allowed = { getRechargeConfig = true, createRechargeOrder = true, refreshRechargeOrder = true }
local function enqueue(method, args, callback)
    assert(allowed[method] and type(callback) == "function", "Unexpected synthetic controller operation")
    controller.sequence = controller.sequence + 1
    local request = { id = controller.sequence, method = method, args = copy(args), callback = callback,
        account_key = controller.account_key, generation = controller.generation }
    controller.calls[#controller.calls + 1] = request
    controller.waiting[#controller.waiting + 1] = request
    return request
end
local function save(order)
    assert(type(order) == "table" and type(order.local_id or order.id) == "string", "A synthetic order requires an exact local ID")
    local value = copy(order)
    for index, previous in ipairs(controller.orders) do
        if (previous.local_id or previous.id) == (value.local_id or value.id) then controller.orders[index] = value; return end
    end
    controller.orders[#controller.orders + 1] = value
end
function controller:getAccount()
    return { id = self.account_id, account_key = self.account_key, name = "Synthetic recharge account",
        session_valid = self.signed_in, recharge_supported = self.recharge_supported }
end
function controller:getWallet() return copy(self.wallet) end
function controller:getSetting(key, default) return copy(default) end
function controller:getStorageSummary() return { automatic_bytes = 0, pinned_bytes = 0 } end
function controller:getPendingPurchases() return {} end
function controller:getDownloads() return {} end
function controller:cancelPendingRead() end
function controller:getRechargeConfigSnapshot() return copy(self.config_snapshot) end
function controller:getRechargeOrders() return copy(self.orders) end
function controller:getRechargeConfig(callback) enqueue("getRechargeConfig", {}, callback) end
function controller:createRechargeOrder(input, callback, token)
    local request = enqueue("createRechargeOrder", { input, token }, callback)
    assert(type(input) == "string", "The amount must remain a decimal string")
    local whole, fraction = input:match("^(%d+)%.(%d%d)$")
    assert(whole and fraction, "The synthetic request requires a normalized decimal amount")
    request.local_id = "local-request-" .. request.id
    request.amount_cents = tonumber(whole) * 100 + tonumber(fraction)
    save({ local_id = request.local_id, account_key = request.account_key, state = "creating",
        amount_cents = request.amount_cents })
end
function controller:refreshRechargeOrder(local_id, callback) enqueue("refreshRechargeOrder", { local_id }, callback) end
setmetatable(controller, { __index = function(self, key)
    self.forbidden[#self.forbidden + 1] = tostring(key)
    error("Controller member is outside the synthetic UI allowlist: " .. tostring(key))
end })
local function callCount(method)
    local count = 0
    for call_index, call in ipairs(controller.calls) do if call.method == method then count = count + 1 end end
    return count
end
local function pending(method)
    for request_index, request in ipairs(controller.waiting) do if request.method == method then return request end end
    error("No synthetic request is waiting for " .. method)
end
local function finish(request, result, err)
    for index, waiting in ipairs(controller.waiting) do
        if waiting == request then
            table.remove(controller.waiting, index)
            local delivered = copy(result)
            if request.method == "getRechargeConfig" and result then controller.config_snapshot = copy(result) end
            if (request.method == "createRechargeOrder" or request.method == "refreshRechargeOrder") and result then
                save(result)
            elseif request.method == "createRechargeOrder" and err and err.transmitted == false and err.definitive == true then
                -- A definitive rejection before submission leaves no controller order.
                for order_index, value in ipairs(controller.orders) do
                    if (value.local_id or value.id) == request.local_id then table.remove(controller.orders, order_index); break end
                end
            elseif request.method == "createRechargeOrder" then
                save({ local_id = request.local_id, account_key = request.account_key, state = "unknown", amount_cents = request.amount_cents })
            end
            request.callback(delivered, copy(err)); return delivered
        end
    end
    error("The synthetic request was already completed")
end
local screens = Screens.new{ controller = controller }
local function visit(widget, predicate, result, seen)
    result, seen = result or {}, seen or {}
    if type(widget) ~= "table" or seen[widget] then return result end
    seen[widget] = true
    if predicate(widget) then result[#result + 1] = widget end
    for child_index, child in ipairs(widget) do visit(child, predicate, result, seen) end
    for field_index, field in ipairs({ "content", "_added_widgets" }) do visit(widget[field], predicate, result, seen) end
    return result
end
local function nativeButtons(widget)
    return visit(widget, function(item) return type(item.text) == "string" and type(item.callback) == "function" end)
end
local function uniqueButton(buttons, label, optional)
    local found
    for button_index, button in ipairs(buttons) do
        if button.text == label then assert(not found, "Visible control is ambiguous: " .. label); found = button end
    end
    if optional then return found end
    return assert(found, "Visible control not found: " .. label)
end
local function screenButton(message, optional)
    local buttons = {}
    for row_index, row in ipairs(screens.focus or {}) do
        for button_index, button in ipairs(row) do buttons[#buttons + 1] = button end
    end
    return uniqueButton(buttons, T(message), optional)
end
local function dialogButton(message, optional)
    return uniqueButton(nativeButtons(assert(screens.dialog)), T(message), optional)
end
local function activate(button)
    assert(button and button.enabled ~= false and type(button.callback) == "function", "The visible control is not actionable")
    button.callback()
end
local function press(message)
    assert(not screens.dialog, "The account control must be visible without a modal")
    activate(screenButton(message))
end
local function dialogPress(message)
    assert(screens.dialog and UIManager:getTopmostVisibleWidget() == screens.dialog, "The dialog must be topmost")
    activate(dialogButton(message))
end
local function shownText(widget)
    local lines = {}
    for item_index, item in ipairs(visit(widget, function() return true end)) do
        for field_index, field in ipairs({ "text", "title", "description", "recharge_text" }) do
            if type(item[field]) == "string" then lines[#lines + 1] = item[field] end
        end
    end
    return table.concat(lines, "\n")
end
local function qrWidgets()
    return visit(screens.dialog, function(widget) return widget.image ~= nil and type(widget.text) == "string"
        and widget.text:find("^https?://") ~= nil end)
end
local function capture(name)
    UIManager:forceRePaint()
    Device.screen.bb:writePNG(output_dir .. "/" .. name .. ".png")
    report.screens[#report.screens + 1] = name .. ".png"
    local size = assert(screens.widget).content:getSize()
    check(name .. "_screen_fits", size.w <= report.width and size.h <= report.height, { width = size.w, height = size.h })
    local top = screens.dialog or screens.widget
    if screens.dialog then
        local box = top.movable and top.movable:getSize() or top:getSize()
        check(name .. "_dialog_fits", box.w <= report.width and box.h <= report.height, { width = box.w, height = box.h })
    end
    check(name .. "_is_topmost", UIManager:getTopmostVisibleWidget() == top)
    check(name .. "_text_is_safe", safeText(shownText(top)))
end
local function checkQRQuietZone(qr)
    local encoded, grid = require("ffi/qrencode").qrcode(qr.text)
    local width, height = qr.image:getWidth(), qr.image:getHeight()
    local module_pixels = encoded and width / #grid or 0
    check("pending_qr_uses_whole_native_modules", encoded and module_pixels >= 1 and module_pixels % 1 == 0)
    local quiet = module_pixels * 4
    local x, y = math.floor(qr.dimen.x - qr._offset_x), math.floor(qr.dimen.y - qr._offset_y)
    local left, top, right, bottom = x - quiet, y - quiet, x + width + quiet - 1, y + height + quiet - 1
    check("pending_qr_quiet_zone_fits_the_screen", left >= 0 and top >= 0
        and right < Device.screen.bb:getWidth() and bottom < Device.screen.bb:getHeight(),
        { x = x, y = y, module_pixels = module_pixels, quiet_pixels = quiet })
    local nonwhite
    for py = top, bottom do
        for px = left, right do
            if (px < x or px >= x + width or py < y or py >= y + height)
                and Device.screen.bb:getPixel(px, py):getColor8().a ~= 255 then
                nonwhite = { x = px, y = py }; break
            end
        end
        if nonwhite then break end
    end
    check("pending_qr_has_four_white_modules_on_every_side", nonwhite == nil,
        { quiet_pixels = quiet, first_nonwhite = nonwhite })
end
local function tick()
    local state = assert(screens.recharge_state)
    local timer = assert(state.timer, "The recharge timer is missing")
    assert(timers[timer] == 3, "Recharge checks must use the configured three-second interval")
    timers[timer] = nil; timer(); return timer
end
local function config(token)
    local options = {}
    for index = 1, 8 do options[index] = { amount_cents = index * 1000, amount_yuan = tostring(index * 10) .. ".00", coin_amount = index * 137 } end
    return { options = options, custom_amount = { allowed = false, reason = "not_advertised" },
        confirmation_token = token or "raw-token-value-config-1", channels = { "Wechat", "Ali" } }
end
local payment_url = "https://pay.bilibili.com/payplatform-h5/index.html?order_id=900719925474099312345678901"
local function order(local_id, state, overrides)
    local result = { id = local_id, local_id = local_id, account_key = controller.account_key,
        order_id = "900719925474099312345678901", state = state or "pending", amount_cents = 1000,
        code_url = payment_url, qr_validated = true }
    for key, value in pairs(overrides or {}) do result[key] = copy(value) end
    return result
end
local function reset(orders)
    screens:close()
    assert(#controller.waiting == 0, "A previous synthetic callback is still pending")
    controller.orders = copy(orders or {})
    screens:showAccount()
end
local function openConfig(token)
    reset(); press("Recharge")
    finish(pending("getRechargeConfig"), config(token))
end
local function openOrder(value)
    reset({ value }); press("Recharge")
    assert(screens.recharge_state.order.local_id == value.local_id, "The saved order was not reopened")
end
local function noCode() return #qrWidgets() == 0 end
local function enterAmount(value)
    dialogPress("Enter amount (official options)")
    screens.dialog._input_widget:setText(value); dialogPress("Review amount")
end
local function ordersEntry(value, label)
    local reference = value.order_id or value.local_id
    return string.format(T("CNY %s · %s · %s"), string.format("%d.%02d", math.floor(value.amount_cents / 100), value.amount_cents % 100),
        T(label), #reference > 8 and reference:sub(-8) or reference)
end

local function run()
    screens:showAccount()
    check("recharge_entry_is_visible_for_supported_signed_in_account", screenButton("Recharge").enabled ~= false)
    capture("recharge-account")
    controller.signed_in = false; screens:refresh()
    check("signed_out_account_disables_recharge", screenButton("Recharge").enabled == false and callCount("getRechargeConfig") == 0)
    capture("recharge-account-signed-out")
    controller.signed_in = true; screens:refresh(); press("Recharge")
    check("opening_recharge_loads_config_without_creating_order", callCount("getRechargeConfig") == 1 and callCount("createRechargeOrder") == 0)
    capture("recharge-config-loading")
    finish(pending("getRechargeConfig"), nil, { kind = "network", message = "SDK_SECRET synthetic-cookie /private/recharge" })
    check("config_failure_has_safe_explicit_recovery", dialogButton("Reload official amounts") and noCode() and callCount("createRechargeOrder") == 0)
    capture("recharge-config-error")
    dialogPress("Reload official amounts"); finish(pending("getRechargeConfig"), config())
    capture("recharge-options")
    dialogPress("Next")
    check("official_options_are_reachable_across_pages", dialogButton(string.format(T("CNY %s"), "80.00")) ~= nil)
    capture("recharge-options-next-page")
    dialogPress("Previous"); enterAmount("10.01")
    check("manual_unadvertised_amount_is_preserved_and_rejected", screens.dialog:getInputText() == "10.01"
        and contains(shownText(screens.dialog), T("This amount is not an official option. Choose a listed amount or type the same amount."))
        and callCount("createRechargeOrder") == 0)
    capture("recharge-manual-unavailable")
    screens.dialog._input_widget:setText("10.00"); dialogPress("Review amount")
    check("manual_supported_amount_requires_explicit_confirmation", contains(shownText(screens.dialog), string.format(T("Recharge amount: CNY %s"), "10.00"))
        and contains(shownText(screens.dialog), string.format(T("Official option shows %s manga coins."), "137"))
        and callCount("createRechargeOrder") == 0 and noCode())
    check("review_describes_one_code_for_both_phone_payment_methods", contains(shownText(screens.dialog),
        T("Create one official payment QR code, then choose WeChat or Alipay on your phone to complete payment.")))
    capture("recharge-manual-review")
    local confirm = dialogButton("Create payment QR")
    activate(confirm)
    local creation = pending("createRechargeOrder")
    check("explicit_confirmation_uses_exact_amount_string_and_config_token", creation.args[1] == "10.00"
        and type(creation.args[1]) == "string" and creation.args[2] == "raw-token-value-config-1")
    confirm.callback()
    check("creating_cannot_submit_the_confirmation_twice", callCount("createRechargeOrder") == 1 and noCode()
        and controller.orders[1].state == "creating" and not dialogButton("Create payment QR", true))
    capture("recharge-creating")
    local first_order = order(creation.local_id)
    finish(creation, first_order)
    local qrs = qrWidgets()
    check("pending_order_displays_one_real_verified_qr", #qrs == 1 and qrs[1].text == payment_url)
    check("one_qr_supports_wechat_and_alipay_without_two_code_claim", contains(shownText(screens.dialog), T("Scan the official code with WeChat or Alipay.")))
    check("server_order_id_is_preserved_as_an_exact_long_string", contains(shownText(screens.dialog), first_order.order_id)
        and screens.recharge_state.order.order_id == first_order.order_id)
    check("missing_server_expiry_is_not_fabricated", contains(shownText(screens.dialog), T("Payment code expiry follows the payment page on your phone."))
        and screens.recharge_state.order.expires_at == nil)
    capture("recharge-pending-no-expiry")
    local qr_pixels, minimum_qr_pixels = qrs[1].image:getWidth(), math.floor(report.width * 0.30)
    check("pending_qr_has_a_readable_native_image_size", qr_pixels >= minimum_qr_pixels
        and qrs[1].image:getHeight() == qr_pixels,
        { width = qr_pixels, height = qrs[1].image:getHeight(), minimum = minimum_qr_pixels })
    checkQRQuietZone(qrs[1])
    local original_dialog = screens.dialog
    local fired_timer = tick()
    local poll = pending("refreshRechargeOrder")
    local checks_before = callCount("refreshRechargeOrder")
    fired_timer(); dialogButton("Check credit").callback()
    check("timer_and_manual_checks_do_not_overlap", callCount("refreshRechargeOrder") == checks_before and poll.args[1] == creation.local_id)
    finish(poll, first_order)
    local next_timer = screens.recharge_state.timer
    poll.callback(order(first_order.local_id, "credited"))
    check("duplicate_poll_callback_cannot_claim_credit", screens.recharge_state.order.state == "pending" and screens.recharge_state.timer == next_timer)
    original_dialog = screens.dialog
    tick(); poll = pending("refreshRechargeOrder"); finish(poll, first_order)
    check("unchanged_automatic_check_preserves_the_qr_dialog", screens.dialog == original_dialog)
    controller.wallet.remain_gold = 99999
    tick(); finish(pending("refreshRechargeOrder"), first_order)
    check("wallet_increase_does_not_prove_credit", screens.recharge_state.order.state == "pending"
        and screens.dialog.title == T("Awaiting payment confirmation"))
    dialogPress("Check credit")
    capture("recharge-checking-credit")
    finish(pending("refreshRechargeOrder"), order(first_order.local_id, "unknown"), { kind = "network", message = "SDK_SECRET synthetic-cookie" })
    check("unknown_result_and_network_error_preserve_the_order", screens.recharge_state.order.local_id == first_order.local_id
        and screens.recharge_state.order.state == "unknown" and callCount("createRechargeOrder") == 1
        and contains(shownText(screens.dialog), T("The latest check could not confirm credit. The order is still unresolved.")))
    capture("recharge-unknown-network")
    dialogPress("Check credit"); finish(pending("refreshRechargeOrder"), order(first_order.local_id, "credited"))
    check("credit_requires_matching_official_order_and_stops_polling", screens.dialog.title == T("Recharge credited")
        and screens.recharge_state.timer == nil and noCode() and callCount("createRechargeOrder") == 1)
    capture("recharge-credited")
    dialogPress("Close")
    press(string.format(T("Recharge orders (%d)"), #controller.orders))
    dialogPress("New recharge")
    check("new_recharge_first_requires_separate_order_notice", callCount("getRechargeConfig") == 2 and callCount("createRechargeOrder") == 1)
    capture("recharge-new-order-notice")
    dialogPress("Choose a new amount"); finish(pending("getRechargeConfig"), config("raw-token-value-config-2"))
    dialogPress(string.format(T("CNY %s"), "20.00"))
    check("new_official_option_does_not_automatically_create", callCount("createRechargeOrder") == 1)
    capture("recharge-option-review")
    dialogPress("Create payment QR"); creation = pending("createRechargeOrder")
    check("new_request_requires_fresh_token_and_explicit_amount_confirmation", creation.args[1] == "20.00"
        and creation.args[2] == "raw-token-value-config-2" and callCount("createRechargeOrder") == 2)
    finish(creation, order(creation.local_id, "failed_not_submitted", { amount_cents = 2000 }))
    check("not_submitted_result_does_not_retry_or_show_payment_code", screens.dialog.title == T("Order was not submitted")
        and screens.recharge_state.timer == nil and noCode() and callCount("createRechargeOrder") == 2)
    capture("recharge-failed-not-submitted")

    openOrder(order("unverified", "unknown", { qr_validated = false, code_url = "https://unsafe.invalid/SDK_SECRET" }))
    check("unverified_payment_url_never_becomes_a_native_qr", noCode() and safeText(shownText(screens.dialog)))
    capture("recharge-unverified-code")
    local long_url = "https://pay.bilibili.com/synthetic-order?payload=" .. string.rep("a", 2954)
    local creates_before_long_url = callCount("createRechargeOrder")
    openOrder(order("unrenderable-long-code", "pending", { code_url = long_url }))
    check("overlong_payment_url_is_preserved_without_encoding_a_truncated_code", #long_url > 2953 and noCode()
        and screens.recharge_state.order.code_url == long_url and controller.orders[1].code_url == long_url
        and screens.recharge_state.order.order_id == controller.orders[1].order_id)
    check("overlong_payment_code_uses_recovery_without_creating_a_replacement", contains(shownText(screens.dialog),
        T("The payment code could not be displayed. Keep this order and check its result; no replacement order will be created automatically."))
        and callCount("createRechargeOrder") == creates_before_long_url and dialogButton("Check credit") ~= nil
        and not dialogButton("Create payment QR", true))
    capture("recharge-unrenderable-long-code")
    openOrder(order("future-expiry", "pending", { expires_at = os.time() + 3600 }))
    check("advertised_expiry_is_explicitly_a_server_value", contains(shownText(screens.dialog), T("Valid until: %s"):match("^(.-)%%")) and #qrWidgets() == 1)
    capture("recharge-pending-server-expiry")
    openOrder(order("expired", "pending", { expires_at = os.time() - 1 }))
    check("expired_qr_stops_automatic_checks_without_recreating_order", screens.dialog.title == T("Payment code expired")
        and screens.recharge_state.timer == nil and noCode())
    capture("recharge-expired-code")
    dialogPress("Check credit")
    check("expired_payment_can_check_the_same_saved_order", pending("refreshRechargeOrder").args[1] == "expired")
    finish(pending("refreshRechargeOrder"), order("expired", "credited"))
    openOrder(order("unsaved", "credited", { persistence_pending = true }))
    check("unsaved_result_does_not_display_a_completed_receipt", screens.dialog.title == T("Order record is not saved")
        and noCode() and screens.recharge_state.timer == nil and not dialogButton("New recharge", true))
    capture("recharge-persistence-pending")
    dialogPress("Check credit"); finish(pending("refreshRechargeOrder"), order("unsaved", "credited"))
    check("saved_credit_result_can_replace_the_storage_warning", screens.dialog.title == T("Recharge credited"))

    openConfig("raw-token-value-background"); enterAmount("10.00"); dialogPress("Create payment QR")
    creation = pending("createRechargeOrder")
    dialogPress("Close")
    check("closing_creation_keeps_the_controller_request_and_record", #controller.waiting == 1 and controller.orders[1].state == "creating")
    screens:refresh(); press(string.format(T("Recharge orders (%d)"), 1))
    check("creating_history_disables_new_recharge", dialogButton("New recharge").enabled == false)
    capture("recharge-creating-history")
    dialogPress("Close")
    local background_order = order(creation.local_id)
    finish(creation, background_order)
    check("background_creation_is_saved_before_feedback_without_reopening_ui", screens.dialog == nil and screens.recharge_state == nil
        and controller.orders[1].state == "pending" and controller.orders[1].order_id == background_order.order_id)
    screens:refresh(); press(string.format(T("Recharge orders (%d)"), 1))
    dialogPress(ordersEntry(background_order, "Awaiting payment confirmation"))
    check("saved_background_result_can_reopen_without_another_create", screens.recharge_state.order.local_id == background_order.local_id and #qrWidgets() == 1)
    capture("recharge-background-result-reopened")

    local history = {}
    for index = 1, 7 do history[index] = order("history-" .. index, "pending", { order_id = "90071992547409931234567000" .. index }) end
    reset(history); press(string.format(T("Recharge orders (%d)"), 7))
    capture("recharge-orders-page-one")
    dialogPress("Next"); capture("recharge-orders-page-two")
    dialogPress(ordersEntry(history[7], "Awaiting payment confirmation"))
    check("history_selects_the_exact_long_order_id", screens.recharge_state.order.order_id == history[7].order_id
        and contains(shownText(screens.dialog), history[7].order_id))
    dialogPress("Check credit")
    check("history_queries_the_exact_local_id", pending("refreshRechargeOrder").args[1] == "history-7")
    finish(pending("refreshRechargeOrder"), history[7]); capture("recharge-history-selected-order")
    dialogPress("Close")
    press(string.format(T("Recharge orders (%d)"), #controller.orders))
    controller.orders = {}; dialogPress("Refresh saved orders")
    check("empty_history_explains_that_no_records_are_saved", contains(shownText(screens.dialog), T("No local recharge orders are saved for this account.")))
    capture("recharge-orders-empty")

    local close_paths = {
        { "button", function() dialogPress("Close") end },
        { "native", function() UIManager:close(screens.dialog) end },
        { "navigation", function() screens:showSearch() end },
        { "screen", function() screens:close() end },
        { "account", function() controller.account_key = "bili_other_fixture"; screens:refresh() end },
        { "generation", function() controller.generation = controller.generation + 1; screens:refresh() end },
    }
    for path_index, path in ipairs(close_paths) do
        controller.account_key = "bili_recharge_fixture"
        local value = order("close-" .. path[1])
        openOrder(value)
        local timer = assert(screens.recharge_state.timer)
        local before = callCount("refreshRechargeOrder")
        path[2]()
        timer()
        check("closing_" .. path[1] .. "_retires_scheduled_checks", screens.recharge_state == nil and screens.dialog == nil
            and timers[timer] == nil and callCount("refreshRechargeOrder") == before)
        controller.account_key = "bili_recharge_fixture"
        openOrder(value); tick()
        local request = pending("refreshRechargeOrder")
        path[2]()
        local creates_before = callCount("createRechargeOrder")
        finish(request, order(value.local_id, "credited", { account_key = "bili_recharge_fixture" }))
        request.callback(value)
        check("closing_" .. path[1] .. "_retires_inflight_feedback", screens.recharge_state == nil and screens.dialog == nil
            and callCount("createRechargeOrder") == creates_before and callCount("refreshRechargeOrder") == before + 1)
    end
    controller.account_key = "bili_recharge_fixture"
    reset(); press("Recharge"); local old_config = pending("getRechargeConfig"); dialogPress("Close")
    press("Recharge"); local new_config
    for request_index, request in ipairs(controller.waiting) do if request ~= old_config then new_config = request end end
    finish(assert(new_config), config("raw-token-value-latest"))
    local latest_dialog = screens.dialog
    finish(old_config, config("raw-token-value-obsolete"))
    check("late_config_cannot_replace_the_latest_confirmation_context", screens.dialog == latest_dialog
        and screens.recharge_state.config.confirmation_token == "raw-token-value-latest")
    local creates_before = callCount("createRechargeOrder")
    dialogPress(string.format(T("CNY %s"), "10.00")); local stale_confirm = dialogButton("Create payment QR")
    dialogPress("Cancel"); stale_confirm.callback()
    check("covered_or_closed_confirmation_does_not_create", callCount("createRechargeOrder") == creates_before)
    dialogPress("Close")

    openConfig("raw-token-value-rejected"); enterAmount("10.00")
    local rejected_confirmation = dialogButton("Create payment QR")
    activate(rejected_confirmation); creation = pending("createRechargeOrder")
    local rejected_creates = callCount("createRechargeOrder")
    finish(creation, nil, { kind = "recharge_config_expired", transmitted = false, definitive = true,
        message = "SDK_SECRET raw-token-value synthetic-cookie" })
    check("definitive_pre_submission_rejection_is_not_an_unknown_order", screens.dialog.title == T("Order was not submitted")
        and contains(shownText(screens.dialog), T("No payment order was submitted. Reload the official amounts and review your account and amount again."))
        and dialogButton("Reload official amounts") and dialogButton("Close") and noCode()
        and not dialogButton("Create payment QR", true) and screens.recharge_state.amount_input == "10.00"
        and #controller.orders == 0 and callCount("createRechargeOrder") == rejected_creates)
    capture("recharge-definitive-not-submitted")
    rejected_confirmation.callback()
    check("definitive_rejection_retires_the_old_confirmation", callCount("createRechargeOrder") == rejected_creates)
    local reloads_before = callCount("getRechargeConfig")
    dialogPress("Reload official amounts")
    check("definitive_rejection_reload_only_requests_fresh_config", callCount("getRechargeConfig") == reloads_before + 1
        and callCount("createRechargeOrder") == rejected_creates and screens.recharge_state.phase == "loading_config"
        and #controller.waiting == 1 and pending("getRechargeConfig"))
    finish(pending("getRechargeConfig"), config("raw-token-value-after-rejection"))
    check("reloaded_rejection_requires_a_new_amount_review", screens.recharge_state.phase == "amounts"
        and screens.recharge_state.config.confirmation_token == "raw-token-value-after-rejection"
        and dialogButton("Enter amount (official options)") and not dialogButton("Create payment QR", true)
        and callCount("createRechargeOrder") == rejected_creates and #controller.waiting == 0)

    openConfig(); enterAmount("10.00"); dialogPress("Create payment QR"); creation = pending("createRechargeOrder")
    finish(creation, nil, { kind = "network", message = "SDK_SECRET raw-token-value synthetic-cookie" })
    check("creation_without_result_never_automatically_retries", screens.dialog.title == T("Order creation is not confirmed")
        and not dialogButton("Create payment QR", true) and noCode())
    capture("recharge-creation-unknown")
    dialogPress("View recharge orders")
    check("unknown_creation_keeps_its_controller_owned_record", #controller.orders == 1 and controller.orders[1].state == "unknown")
    capture("recharge-unknown-history")
    check("all_operations_remain_synthetic_and_accounted_for", #controller.waiting == 0 and #controller.forbidden == 0, controller.forbidden)
    for module_index, name in ipairs(prohibited_modules) do
        check("business_module_stays_unloaded_" .. module_index, package.loaded[name] == nil)
    end
end

local ok, failure = xpcall(run, debug.traceback)
report.passed, report.error, report.count = ok, not ok and tostring(failure) or nil, #report.assertions
report.fake_order_request_count = callCount("createRechargeOrder")
report.calls = {}
for call_index, call in ipairs(controller.calls) do report.calls[call.method] = (report.calls[call.method] or 0) + 1 end
pcall(screens.close, screens)
UIManager.scheduleIn, UIManager.unschedule = schedule_in, unschedule
local file = assert(io.open(output_dir .. "/ui-result.json", "wb"))
assert(file:write(json.encode(report, { pretty = true }))); assert(file:close())
print(json.encode(report, { pretty = true }))
if not ok then error(failure) end
