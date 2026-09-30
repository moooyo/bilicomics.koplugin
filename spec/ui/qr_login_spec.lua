-- Exercise native QR widgets with controlled callbacks and no live account.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
require("gettext").current_lang = arg[3] or "zh_CN"
local UIManager = require("ui/uimanager")
local Screens = require("bilicomics/ui/screens")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local _ = require("bilicomics/ui/i18n")
local results = { assertions = {}, screens = {}, scope = "Native KOReader widgets; controlled QR callbacks; isolated network namespace; synthetic account only" }
local function check(name, value)
    results.assertions[#results.assertions + 1] = { name = name, passed = not not value }
    assert(value, name)
end

local timers, schedule_in, unschedule = {}, UIManager.scheduleIn, UIManager.unschedule
UIManager.scheduleIn = function(_manager, delay, callback)
    timers[callback] = delay
end
UIManager.unschedule = function(_manager, callback) timers[callback] = nil end
local controller = { generation = 1, account = {}, begin = {}, poll = {}, canceled = 0 }
function controller:getAccount() return self.account end
function controller:getWallet() return { remain_gold = 12, remain_coupon = 3 } end
function controller:getSetting(_key, default) return default end
function controller:getStorageSummary() return {} end
function controller:getPendingPurchases() return {} end
function controller:getLibrary() return {} end
function controller:beginQRLogin(callback) self.begin[#self.begin + 1] = callback end
function controller:pollQRLogin(key, callback) self.poll[#self.poll + 1] = { key = key, callback = callback } end
function controller:cancelQRLogin() self.canceled = self.canceled + 1 end
local screens = Screens.new{ controller = controller }
local function findButton(rows, message, scope)
    local found
    for _index, row in ipairs(rows) do
        for _index, button in ipairs(row) do
            if button.text == _(message) then
                assert(not found, scope .. " button is ambiguous: " .. message)
                found = button
            end
        end
    end
    return assert(found, scope .. " button not found: " .. message)
end
local function press(message)
    local button = findButton(screens.focus, message, "Account")
    assert(button.enabled ~= false and type(button.callback) == "function", "Account button is not actionable: " .. message)
    button.callback()
end
local function dialogPress(message)
    local button = findButton(assert(screens.dialog).buttons, message, "Dialog")
    assert(button.enabled ~= false and type(button.callback) == "function", "Dialog button is not actionable: " .. message)
    button.callback()
end
local function capture(name)
    UIManager:forceRePaint()
    local size = screens.widget.content:getSize()
    check(name .. "_account_fits_screen", size.w <= Device.screen:getWidth() and size.h <= Device.screen:getHeight())
    if screens.dialog then
        size = screens.dialog.movable:getSize()
        check(name .. "_dialog_fits_screen", size.w <= Device.screen:getWidth() and size.h <= Device.screen:getHeight())
    end
    Device.screen.bb:writePNG(output .. "/" .. name .. ".png")
    results.screens[#results.screens + 1] = name .. ".png"
end
local function findWidget(widget, predicate, seen)
    if type(widget) ~= "table" then return nil end
    seen = seen or {}
    if seen[widget] then return nil end
    seen[widget] = true
    if predicate(widget) then return widget end
    for _index, child in ipairs(widget) do
        local found = findWidget(child, predicate, seen)
        if found then return found end
    end
    for _, field in ipairs({ "content", "_added_widgets" }) do
        local found = findWidget(widget[field], predicate, seen)
        if found then return found end
    end
end
local function hasText(widget, message)
    return findWidget(widget, function(child) return child.text == _(message) end) ~= nil
end
local qr_url = "https://passport.bilibili.com/h5-app/passport/login/scan?navhide=1&qrcode_key=synthetic-qr-key"
local function generated(expiry)
    controller.begin[#controller.begin]({ key = "synthetic-qr-key", expires_at = expiry,
        url = qr_url })
end
local function tick()
    local timer = assert(screens.qr_login.timer)
    check("poll_delay_is_three_seconds_" .. tostring(#controller.poll), timers[timer] == 3)
    timers[timer] = nil
    timer()
    return timer
end
local function start()
    screens:showAccount()
    press("Sign in with QR code")
    generated()
end

screens:showAccount()
capture("qr-account-signed-out")
press("Sign in with QR code")
check("account_action_begins_qr_login", #controller.begin == 1 and screens.qr_login.status == "loading")
capture("qr-loading")
generated()
local waiting_dialog = screens.dialog
local native_qr = findWidget(waiting_dialog, function(widget) return widget.image ~= nil and widget.text == qr_url end)
check("native_qr_image_is_created", native_qr ~= nil)
check("qr_key_is_not_in_visible_text", not waiting_dialog.title:find("synthetic-qr-key", 1, true))
capture("qr-waiting")
local timer = tick()
check("first_poll_uses_returned_key", #controller.poll == 1 and controller.poll[1].key == "synthetic-qr-key")
timer(); screens.qr_login:_poll()
check("inflight_poll_cannot_overlap", #controller.poll == 1 and screens.qr_login.timer ~= nil)
screens.qr_login.timer()
check("expiry_visibility_tick_does_not_overlap_network_poll", #controller.poll == 1)
controller.poll[1].callback({ status = "waiting" })
check("unchanged_poll_does_not_repaint_qr", screens.dialog == waiting_dialog and screens.qr_login.timer ~= nil)
local next_timer = screens.qr_login.timer
controller.poll[1].callback({ status = "expired" })
check("duplicate_callback_is_ignored", screens.qr_login.timer == next_timer and screens.qr_login.status == "waiting")
tick()
controller.poll[2].callback({ status = "scanned" })
check("scanned_state_is_visible", screens.qr_login.status == "scanned")
capture("qr-scanned")
tick()
controller.poll[3].callback({ status = "expired" })
check("expired_code_stops_polling", screens.qr_login.status == "expired" and screens.qr_login.timer == nil)
capture("qr-expired")
dialogPress("Get a new code")
check("expired_code_can_be_replaced", #controller.begin == 2 and screens.qr_login.status == "loading")
generated()
tick()
controller.account = { id = "424242", account_key = "bili_424242", name = "Synthetic QR account", session_valid = true, renewable = true }
controller.generation = controller.generation + 1
controller.poll[#controller.poll].callback({ status = "confirmed" })
check("confirmed_login_closes_dialog_and_renders_account", screens.qr_login == nil and screens.dialog == nil and screens.route == "account")
capture("qr-account-renewable")
for _index, state in ipairs({ "checking", "refreshing", "pending_confirmation" }) do
    controller.account.auth_state = state
    screens:refresh()
    check("renewal_maintenance_state_" .. state, hasText(screens.widget.content, "Checking or renewing your sign-in…"))
    check("renewal_maintenance_disables_balance_refresh_" .. state,
        findButton(screens.focus, "Refresh balance", "Account").enabled == false)
end
capture("qr-account-maintenance")
controller.account.auth_state = "error"
screens:refresh()
check("renewal_error_is_actionable", hasText(screens.widget.content, "Automatic renewal is unavailable. Sign in again with QR code.")
    and findButton(screens.focus, "Sign in with QR code", "Account").enabled ~= false)
capture("qr-account-renewal-error")
controller.account.auth_state = "reauth_required"
screens:refresh()
check("reauthentication_required_overrides_renewable", hasText(screens.widget.content, "Sign in again to restore your account."))
capture("qr-account-reauthentication")
controller.account.auth_state = "ready"
screens:refresh()
check("renewal_ready_restores_normal_status", hasText(screens.widget.content, "Automatic sign-in renewal is enabled."))

start()
tick()
local stale_poll = controller.poll[#controller.poll].callback
dialogPress("Cancel")
check("cancel_retires_timer_and_flow", screens.dialog == nil and screens.qr_login == nil)
stale_poll({ status = "confirmed" })
check("late_confirmation_cannot_reopen_dialog", screens.dialog == nil and screens.qr_login == nil)

screens:_signInWithQR()
local stale_begin = controller.begin[#controller.begin]
screens:_signInWithQR()
local current_dialog = screens.dialog
stale_begin({ key = "obsolete", url = "https://example.invalid/obsolete" })
check("new_flow_ignores_old_generation_callback", screens.dialog == current_dialog and screens.qr_login.status == "loading")
generated()
local replaced_timer = screens.qr_login.timer
press("Other sign-in methods")
check("new_dialog_cancels_qr_polling", screens.qr_login == nil and timers[replaced_timer] == nil
    and screens.dialog == screens.context_dialog and screens.dialog ~= current_dialog)
check("other_sign_in_methods_exposes_session_import", findButton(screens.dialog.buttons, "Paste web session", "Dialog").callback
    and findButton(screens.dialog.buttons, "Import from file", "Dialog").callback)
dialogPress("Close")

start()
local native_dialog, native_timer = screens.dialog, screens.qr_login.timer
UIManager:close(native_dialog)
check("native_close_retires_qr_flow", screens.dialog == nil and screens.qr_login == nil and timers[native_timer] == nil)

start()
local account_timer = screens.qr_login.timer
controller.account = { id = "515151", account_key = "bili_515151", session_valid = true }
controller.generation = controller.generation + 1
screens:refresh()
check("account_switch_stops_polling", screens.qr_login == nil and screens.dialog == nil and timers[account_timer] == nil)

start()
local navigation_timer = screens.qr_login.timer
screens:showLibrary()
check("navigation_stops_polling", screens.qr_login == nil and screens.dialog == nil and timers[navigation_timer] == nil
    and screens.route == "favorites")

start()
tick()
controller.poll[#controller.poll].callback(nil, { kind = "network", message = "synthetic-secret-cookie" })
check("network_error_stops_and_redacts_detail", screens.qr_login.status == "error" and screens.qr_login.timer == nil
    and not screens.dialog.title:find("synthetic-secret-cookie", 1, true))
capture("qr-error")
dialogPress("Get a new code")
controller.begin[#controller.begin](nil, { kind = "network", message = "synthetic-secret-cookie" })
check("code_generation_error_is_retryable", screens.qr_login.status == "error")
dialogPress("Get a new code")
generated(os.time() - 1)
local before_expiry_poll = #controller.poll
tick()
check("known_expired_code_never_polls", screens.qr_login.status == "expired" and #controller.poll == before_expiry_poll)

start()
local closing_timer = screens.qr_login.timer
screens:close()
check("screen_close_stops_all_polling", screens.qr_login == nil and screens.dialog == nil and timers[closing_timer] == nil)
UIManager.scheduleIn, UIManager.unschedule = schedule_in, unschedule
results.passed = true
Files.write(output .. "/qr-login-result.json", json.encode(results, { pretty = true }))
print(json.encode({ passed = true, assertions = #results.assertions, width = Device.screen:getWidth(), height = Device.screen:getHeight() }))
