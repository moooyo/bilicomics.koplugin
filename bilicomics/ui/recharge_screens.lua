local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InputDialog = require("ui/widget/inputdialog")
local QRWidget = require("ui/widget/qrwidget")
local UIManager = require("ui/uimanager")
local W = require("bilicomics/ui/widgets")
local Helpers = require("bilicomics/ui/screen_helpers")
local T = require("bilicomics/ui/i18n")
local accountKey = Helpers.accountKey
local font = W.font or { title = 21, body = 18, status = 15, meta = 14, micro = 13 }

local function integer(value)
    return type(value) == "number" and value == value and value >= 0 and value <= 9007199254740991 and value % 1 == 0
end

local function decimalInput(value)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    local whole, fraction = value:match("^(%d+)%.(%d%d?)$")
    if not whole then whole, fraction = value:match("^(%d+)$"), "" end
    if not whole or #whole > 13 then return nil end
    local cents = tonumber(whole) * 100 + tonumber((fraction .. "00"):sub(1, 2))
    if not integer(cents) or cents <= 0 then return nil end
    return cents, string.format("%d.%02d", math.floor(cents / 100), cents % 100)
end

local function yuan(cents)
    if not integer(cents) then return T("Amount unavailable") end
    return string.format("%d.%02d", math.floor(cents / 100), cents % 100)
end

local function text(value, limit)
    if type(value) ~= "string" and type(value) ~= "number" then return "" end
    local result, count = {}, 0
    for character in tostring(value):gsub("[%c]", " "):gmatch(".[\128-\191]*") do
        count = count + 1
        if count > (limit or 120) then result[#result + 1] = "…"; break end
        result[#result + 1] = character
    end
    return table.concat(result)
end

local function orderId(order) return order and (order.local_id or order.id) end

local function terminal(order)
    return order and not order.persistence_pending and (order.state == "credited" or order.state == "expired" or order.state == "failed_not_submitted")
end

local function effectiveState(order)
    if not order then return "unknown" end
    if order.persistence_pending then return "unsaved" end
    if order.state == "credited" then return "credited" end
    if order.state == "expired" or order.qr_expired == true then return "expired" end
    if integer(order.expires_at) and order.expires_at > 0 and order.expires_at <= os.time() then return "expired" end
    return order.state or "unknown"
end

local function timeLabel(value)
    if not integer(value) or value <= 0 or value > 253402300799 then return nil end
    local ok, result = pcall(os.date, "!%Y-%m-%d %H:%M UTC", value)
    return ok and result or nil
end

local function stateLabel(order)
    local labels = { creating = T("Creating order"), pending = T("Awaiting payment confirmation"), unknown = T("Result not confirmed"),
        credited = T("Recharge credited"), expired = T("Payment code expired"), failed_not_submitted = T("Order was not submitted"),
        unsaved = T("Order record is not saved") }
    return labels[effectiveState(order)] or labels.unknown
end

local function customRules(config)
    local custom = config and config.custom_amount
    if type(custom) ~= "table" or custom.allowed ~= true or not integer(custom.min_cents) or custom.min_cents <= 0
        or not integer(custom.max_cents) or custom.max_cents < custom.min_cents then return nil end
    if custom.step_cents ~= nil and (not integer(custom.step_cents) or custom.step_cents <= 0) then return nil end
    return custom
end

local function optionsFrom(config)
    local result = {}
    local supplied = type(config) == "table" and type(config.options) == "table" and config.options or {}
    for option_index, option in ipairs(supplied) do
        if type(option) == "table" and integer(option.amount_cents) and option.amount_cents > 0 then
            local cents = option.amount_yuan ~= nil and decimalInput(tostring(option.amount_yuan)) or option.amount_cents
            if cents == option.amount_cents then result[#result + 1] = option end
        end
    end
    return result
end

return function(Screens)

function Screens:_rechargeOrdersSnapshot()
    if type(self.controller.getRechargeOrders) ~= "function" then return {} end
    local ok, orders = pcall(self.controller.getRechargeOrders, self.controller)
    if not ok or type(orders) ~= "table" then return {} end
    local key, result = accountKey(self.controller), {}
    for order_index, order in ipairs(orders) do
        if type(order) == "table" and orderId(order) ~= nil and (order.account_key == nil or order.account_key == key) then result[#result + 1] = order end
    end
    return result
end

function Screens:_rechargeCurrent(state)
    return state and self.recharge_state == state and state.active and self.route ~= nil and self.epoch == state.epoch
        and accountKey(self.controller) == state.account_key and self.controller.generation == state.generation and not self.controller.closed
end

function Screens:_rechargeVisible(state)
    if not self:_rechargeCurrent(state) or not state.dialog or self.dialog ~= state.dialog then return false end
    return UIManager:getTopmostVisibleWidget() == state.dialog
end

function Screens:_rechargeUnschedule(state)
    if state and state.timer then UIManager:unschedule(state.timer); state.timer = nil end
end

function Screens:_rechargeClose()
    local state = self.recharge_state
    if not state then return end
    self.recharge_state = nil
    state.active, state.sequence = false, state.sequence + 1
    self:_rechargeUnschedule(state)
    local dialog = state.dialog
    state.dialog = nil
    if self.dialog == dialog then self.dialog = nil end
    if self.context_dialog == dialog then
        self.context_dialog, self.context_dialog_account, self.context_dialog_dirty = nil, nil, nil
    end
    if dialog then UIManager:close(dialog) end
end

function Screens:_rechargeCheckCurrent()
    local state = self.recharge_state
    if state and not self:_rechargeCurrent(state) then self:_rechargeClose(); return false end
    return state ~= nil
end

function Screens:_rechargeDismiss(state)
    if self.recharge_state ~= state then return end
    self:_rechargeClose()
    if self.route then self:_render() end
end

function Screens:_rechargeNewState()
    self:_closeDialog()
    local account = self.controller:getAccount() or {}
    local name = text(account.name or account.id or T("Current account"), 48)
    if account.id ~= nil and tostring(account.id) ~= name then name = name .. " (" .. text(account.id, 32) .. ")" end
    local state = { active = true, sequence = 0, epoch = self.epoch, account_key = accountKey(self.controller),
        generation = self.controller.generation, account_name = name, options_page = 1 }
    self.recharge_state = state
    return state
end

function Screens:_rechargeOwnDialog(state, dialog, previous)
    if not self:_rechargeCurrent(state) then return end
    local owner, native_close = self, dialog.onCloseWidget
    function dialog:onCloseWidget()
        if native_close then native_close(self) end
        if state.dialog ~= self or owner.recharge_state ~= state then return end
        state.dialog = nil
        local repaint = owner.context_dialog == self and owner.context_dialog_dirty
        if owner.dialog == self then owner.dialog = nil end
        if owner.context_dialog == self then owner.context_dialog, owner.context_dialog_account, owner.context_dialog_dirty = nil, nil, nil end
        owner:_rechargeClose()
        if repaint and owner.route then owner:_render() end
    end
    local dirty = self.context_dialog_dirty
    state.dialog, self.dialog, self.context_dialog = dialog, dialog, dialog
    self.context_dialog_account, self.context_dialog_dirty = state.account_key, dirty
    if previous and previous ~= dialog then UIManager:close(previous) end
    UIManager:show(dialog)
end

function Screens:_rechargeDialog(state, heading, paragraphs, buttons, options)
    if not self:_rechargeCurrent(state) then return nil end
    options = options or {}
    local dialog, previous = nil, state.dialog
    for row_index, row in ipairs(buttons) do
        for button_index, button in ipairs(row) do
            local callback = button.callback
            button.font_size, button.font_bold = button.font_size or font.status, button.font_bold == true
            button.height, button.avoid_text_truncation = button.height or W.scale(34), true
            button.callback = function()
                if not self:_rechargeCurrent(state) or state.dialog ~= dialog or self.dialog ~= dialog then return end
                if callback then callback() end
            end
        end
    end
    dialog = ButtonDialog:new{ title = heading, title_face = Font:getFace("cfont", font.title), use_info_style = false,
        title_padding = W.scale(7), title_margin = 0, buttons = buttons, modal = true, width_factor = 0.94,
        selected = options.selected or { x = 1, y = #buttons }, dismissable = true }
    local width, rows, description = dialog:getAddedWidgetAvailableWidth(), {}, { heading }
    for paragraph_index, paragraph in ipairs(paragraphs or {}) do
        local item = type(paragraph) == "table" and paragraph or { text = paragraph }
        if item.text and item.text ~= "" then
            if #rows > 0 then rows[#rows + 1] = W.space(4) end
            rows[#rows + 1] = W.text(item.text, width, item.size or font.status, { bold = item.bold == true })
            description[#description + 1] = item.text
        end
    end
    if options.qr_url then
        rows[#rows + 1] = W.space(8)
        local measuring_rows = {}
        for index, row in ipairs(rows) do measuring_rows[index] = row end
        local content_height = W.column(measuring_rows):getSize().h
        local frame_height = dialog.movable and dialog.movable:getSize().h or dialog:getSize().h
        local quiet_zone = W.scale(42)
        local remaining = Device.screen:getHeight() - frame_height - content_height - quiet_zone * 2 - W.scale(8)
        local size = math.floor(math.max(W.scale(80), math.min(width - W.scale(24), Device.screen:getHeight() * 0.30, W.scale(230), remaining)))
        -- QRWidget silently truncates longer inputs, which must never change a payment URL.
        local ok, qr = false, nil
        if #options.qr_url <= 2953 then
            ok, qr = pcall(QRWidget.new, QRWidget, { text = options.qr_url, width = size, height = size, scale_factor = 1 })
        end
        if ok and qr.image and qr.image:getWidth() > 0 then
            rows[#rows + 1] = CenterContainer:new{ dimen = Geom:new{ w = width, h = size + quiet_zone * 2 }, not_focusable = true, qr }
        else rows[#rows + 1] = W.text(T("The payment code could not be displayed. Keep this order and check its result; no replacement order will be created automatically."), width, font.meta) end
    end
    if #rows > 0 then
        local summary = W.column(rows)
        summary.parent, summary.not_focusable = dialog, true
        dialog:addWidget(summary)
    end
    dialog.recharge_text = table.concat(description, "\n")
    self:_rechargeOwnDialog(state, dialog, previous)
    return dialog
end

function Screens:_rechargeCloseButton(state)
    return { text = T("Close"), is_enter_default = true, callback = function() self:_rechargeDismiss(state) end }
end

function Screens:_rechargeCreationBlock()
    for order_index, order in ipairs(self:_rechargeOrdersSnapshot()) do
        if order.persistence_pending then return "unsaved" end
        if order.state == "creating" then return "creating" end
    end
    return nil
end

function Screens:_openRecharge()
    local state = self:_rechargeNewState()
    for order_index, order in ipairs(self:_rechargeOrdersSnapshot()) do
        if not terminal(order) then self:_rechargeAttachOrder(state, order); return end
    end
    self:_rechargeLoadConfig(state)
end

function Screens:_rechargeLoadConfig(state)
    if not self:_rechargeCurrent(state) then return end
    if self:_rechargeCreationBlock() then self:_rechargeOrdersView(state); return end
    self:_rechargeUnschedule(state)
    state.phase, state.config, state.order, state.amount_input, state.option = "loading_config", nil, nil, nil, nil
    state.submitted, state.poll_error, state.display_key = false, nil, nil
    state.inflight, state.sequence = true, state.sequence + 1
    local sequence, completed = state.sequence, false
    self:_rechargeDialog(state, T("Recharge manga coins"), { T("Loading official recharge amounts…") }, { { self:_rechargeCloseButton(state) } })
    local function done(config, error)
        if completed then return end
        completed = true
        if not self:_rechargeCurrent(state) or state.sequence ~= sequence then return end
        state.inflight = false
        local options = optionsFrom(config)
        if error or type(config) ~= "table" or config.confirmation_token == nil or (#options == 0 and not customRules(config)) then
            state.phase = "config_error"
            self:_rechargeDialog(state, T("Recharge options unavailable"), {
                T("Official recharge amounts could not be confirmed. No order was created. Check your sign-in and connection, then try again."),
            }, { { { text = T("Reload official amounts"), callback = function() self:_rechargeLoadConfig(state) end } }, { self:_rechargeCloseButton(state) } })
            return
        end
        state.config, state.options, state.options_page = config, options, 1
        self:_rechargeAmountsView(state)
    end
    local ok = pcall(self.controller.getRechargeConfig, self.controller, done)
    if not ok then done(nil, { kind = "internal" }) end
end

function Screens:_rechargeAmountsView(state)
    if not self:_rechargeCurrent(state) or not state.config then return end
    state.phase = "amounts"
    local rules, buttons = customRules(state.config), {}
    local pages = math.max(1, math.ceil(#state.options / 6))
    state.options_page = math.max(1, math.min(state.options_page or 1, pages))
    for index = (state.options_page - 1) * 6 + 1, math.min(state.options_page * 6, #state.options) do
        local option = state.options[index]
        if (index - 1) % 2 == 0 then buttons[#buttons + 1] = {} end
        local row = buttons[#buttons]
        row[#row + 1] = { text = string.format(T("CNY %s"), yuan(option.amount_cents)), callback = function()
            self:_rechargeReviewAmount(state, yuan(option.amount_cents), option)
        end }
    end
    if pages > 1 then
        buttons[#buttons + 1] = {
            { text = T("Previous"), enabled = state.options_page > 1, callback = function() state.options_page = state.options_page - 1; self:_rechargeAmountsView(state) end },
            { text = string.format("%d / %d", state.options_page, pages), enabled = false },
            { text = T("Next"), enabled = state.options_page < pages, callback = function() state.options_page = state.options_page + 1; self:_rechargeAmountsView(state) end },
        }
    end
    buttons[#buttons + 1] = { { text = rules and T("Enter an amount") or T("Enter amount (official options)"), callback = function() self:_rechargeInputAmount(state) end } }
    buttons[#buttons + 1] = { self:_rechargeCloseButton(state) }
    local paragraphs = { string.format(T("Receiving account: %s"), state.account_name),
        rules and string.format(T("Custom amount allowed: CNY %s to %s."), yuan(rules.min_cents), yuan(rules.max_cents))
            or T("The server has not enabled arbitrary amounts. Typed amounts must match an official option.") }
    if type(state.config.notice) == "string" and state.config.notice ~= "" then paragraphs[#paragraphs + 1] = text(state.config.notice, 180) end
    self:_rechargeDialog(state, T("Choose recharge amount"), paragraphs, buttons)
end

function Screens:_rechargeValidateAmount(state, input)
    local cents, normalized = decimalInput(input)
    if not cents then return nil, nil, T("Enter a positive yuan amount with no more than two decimal places.") end
    for option_index, option in ipairs(state.options or {}) do
        if option.amount_cents == cents then return normalized, option end
    end
    local rules = customRules(state.config)
    if not rules then return nil, nil, T("This amount is not an official option. Choose a listed amount or type the same amount.") end
    if cents < rules.min_cents or cents > rules.max_cents or (rules.step_cents and (cents - rules.min_cents) % rules.step_cents ~= 0) then
        return nil, nil, T("The amount does not meet the server's allowed range or step.")
    end
    return normalized, nil
end

function Screens:_rechargeInputAmount(state, value, message)
    if not self:_rechargeCurrent(state) or not state.config then return end
    state.phase = "input"
    local dialog, previous = nil, state.dialog
    local rules = customRules(state.config)
    local description = message or (rules
        and string.format(T("Allowed range: CNY %s to %s. Use no more than two decimal places."), yuan(rules.min_cents), yuan(rules.max_cents))
        or T("Arbitrary amounts are not advertised by the server. Enter one of the official amounts shown in the previous screen."))
    dialog = InputDialog:new{ title = rules and T("Enter recharge amount (CNY)") or T("Enter amount (official options)"),
        input = value or "", input_type = "number", input_hint = T("Amount in yuan"), description = description, modal = true,
        buttons = { { { text = T("Cancel"), callback = function()
            if self:_rechargeCurrent(state) and state.dialog == dialog then self:_rechargeAmountsView(state) end
        end }, { text = T("Review amount"), is_enter_default = true, callback = function()
            if not self:_rechargeCurrent(state) or state.dialog ~= dialog then return end
            local entered = dialog:getInputText()
            local normalized, option, error = self:_rechargeValidateAmount(state, entered)
            if not normalized then self:_rechargeInputAmount(state, entered, error); return end
            self:_rechargeReviewAmount(state, normalized, option)
        end } } } }
    self:_rechargeOwnDialog(state, dialog, previous)
    dialog:onShowKeyboard()
end

function Screens:_rechargeReviewAmount(state, input, option)
    if not self:_rechargeCurrent(state) or not state.config then return end
    local normalized, selected, error = self:_rechargeValidateAmount(state, input)
    if not normalized then self:_rechargeInputAmount(state, input, error); return end
    state.phase, state.amount_input, state.option = "confirm", normalized, selected or option
    local paragraphs = { string.format(T("Receiving account: %s"), state.account_name),
        { text = string.format(T("Recharge amount: CNY %s"), normalized), size = font.title, bold = true } }
    if state.option and state.option.coin_amount ~= nil then
        paragraphs[#paragraphs + 1] = string.format(T("Official option shows %s manga coins."), text(state.option.coin_amount, 40))
    end
    for offer_index, key in ipairs({ "first_text", "activity_text" }) do
        local value = state.option and state.option[key] or state.config[key]
        if type(value) == "string" and value ~= "" then paragraphs[#paragraphs + 1] = text(value, 180) end
    end
    paragraphs[#paragraphs + 1] = T("Create one official payment QR code, then choose WeChat or Alipay on your phone to complete payment.")
    paragraphs[#paragraphs + 1] = T("Creating a code does not confirm payment or credit. The next screen checks the matching order record.")
    self:_rechargeDialog(state, T("Review recharge"), paragraphs, { {
        { text = T("Cancel"), is_enter_default = true, callback = function() self:_rechargeAmountsView(state) end },
        { text = T("Create payment QR"), callback = function() self:_rechargeCreate(state) end },
    } }, { selected = { x = 1, y = 1 } })
end

function Screens:_rechargeCreate(state)
    if not self:_rechargeCurrent(state) or not self:_rechargeVisible(state) or state.phase ~= "confirm"
        or state.inflight or state.submitted or not state.config then return end
    if self:_rechargeCreationBlock() then self:_rechargeOrdersView(state); return end
    local normalized = self:_rechargeValidateAmount(state, state.amount_input)
    if not normalized then self:_rechargeInputAmount(state, state.amount_input); return end
    local token = state.config.confirmation_token
    if token == nil then self:_rechargeLoadConfig(state); return end
    state.phase, state.submitted, state.inflight, state.sequence = "creating", true, true, state.sequence + 1
    local sequence, completed = state.sequence, false
    self:_rechargeDialog(state, T("Creating recharge order"), {
        string.format(T("Receiving account: %s"), state.account_name),
        { text = string.format(T("Recharge amount: CNY %s"), normalized), bold = true },
        T("One order request has been sent. Closing this view does not undo it. Its known or unknown result remains in Recharge orders."),
    }, { { self:_rechargeCloseButton(state) } })
    local function done(order, error)
        if completed then return end
        completed = true
        if not self:_rechargeCurrent(state) or state.sequence ~= sequence then return end
        state.inflight = false
        if type(order) == "table" and orderId(order) ~= nil then
            state.poll_error = error and true or nil
            self:_rechargeAttachOrder(state, order)
            return
        end
        if error and error.transmitted == false and error.definitive == true then
            state.phase = "creation_not_submitted"
            self:_rechargeDialog(state, T("Order was not submitted"), {
                T("No payment order was submitted. Reload the official amounts and review your account and amount again."),
            }, { { { text = T("Reload official amounts"), callback = function() self:_rechargeLoadConfig(state) end } },
                { self:_rechargeCloseButton(state) } })
            return
        end
        state.phase = "creation_unknown"
        self:_rechargeDialog(state, T("Order creation is not confirmed"), {
            string.format(T("Receiving account: %s"), state.account_name),
            string.format(T("Requested amount: CNY %s"), normalized),
            T("The request outcome could not be confirmed. Review saved recharge orders before trying another amount. This view will not send the request again."),
        }, { { { text = T("View recharge orders"), callback = function() self:_rechargeOrdersView(state) end } }, { self:_rechargeCloseButton(state) } })
    end
    local ok = pcall(self.controller.createRechargeOrder, self.controller, normalized, done, token)
    if not ok then done(nil, { kind = "internal" }) end
end

function Screens:_rechargeAttachOrder(state, order)
    if not self:_rechargeCurrent(state) or type(order) ~= "table" or orderId(order) == nil then return end
    if order.account_key ~= nil and order.account_key ~= state.account_key then self:_rechargeDismiss(state); return end
    self:_rechargeUnschedule(state)
    state.sequence, state.inflight, state.phase, state.order, state.manual_check = state.sequence + 1, false, "order", order, false
    state.display_key = nil
    self:_rechargeOrderView(state)
    self:_rechargeSchedule(state)
end

function Screens:_rechargeOrderView(state)
    if not self:_rechargeCurrent(state) or not state.order then return end
    local order, phase = state.order, effectiveState(state.order)
    local code_allowed = (phase == "pending" or phase == "unknown") and order.qr_validated == true
        and type(order.code_url) == "string" and order.code_url ~= ""
        and type(order.order_id) == "string" and order.order_id ~= "" and integer(order.amount_cents) and order.amount_cents > 0
    local key = table.concat({ tostring(orderId(order)), phase, tostring(order.order_id), tostring(order.amount_cents),
        tostring(order.code_url), tostring(order.qr_validated), tostring(order.expires_at), tostring(state.poll_error), tostring(state.manual_check) }, "|")
    if state.display_key == key and state.dialog and self.dialog == state.dialog then return end
    if state.dialog and not self:_rechargeVisible(state) then return end
    state.display_key = key
    local paragraphs = {
        string.format(T("Receiving account: %s"), state.account_name),
        { text = string.format(T("Recharge amount: CNY %s"), yuan(order.amount_cents)), size = font.title, bold = true },
        type(order.order_id) == "string" and order.order_id ~= "" and string.format(T("Order: %s"), order.order_id)
            or string.format(T("Local record: %s"), text(orderId(order), 80)),
    }
    local actions = {}
    if phase == "credited" then
        paragraphs[#paragraphs + 1] = T("Recharge credited. Return to Account to view your manga coin balance.")
    elseif phase == "unsaved" then
        paragraphs[#paragraphs + 1] = T("The local order record could not be saved. Restore writable storage and check this order again. This view cannot show a completed receipt yet.")
    elseif phase == "failed_not_submitted" then
        paragraphs[#paragraphs + 1] = T("This request was not submitted as a payment order. Reload the official amounts before explicitly creating another order.")
    elseif phase == "expired" then
        paragraphs[#paragraphs + 1] = T("This payment code is no longer valid. If you already paid, check the same order for credit. A new order will not be created automatically.")
    elseif phase == "creating" then
        paragraphs[#paragraphs + 1] = T("Order creation is still being recorded. Do not send another request. Reopen Recharge orders to review the result.")
    elseif code_allowed then
        paragraphs[#paragraphs + 1] = T("Scan the official code with WeChat or Alipay.")
        local expiry = timeLabel(order.expires_at)
        paragraphs[#paragraphs + 1] = { text = expiry and string.format(T("Valid until: %s"), expiry)
            or T("Payment code expiry follows the payment page on your phone."), size = font.micro }
    else
        paragraphs[#paragraphs + 1] = T("This order has no usable payment code. Check its result or reopen it from Recharge orders.")
    end
    if state.poll_error and phase ~= "credited" and phase ~= "failed_not_submitted" then
        paragraphs[#paragraphs + 1] = { text = T("The latest check could not confirm credit. The order is still unresolved."), size = font.meta }
    end
    if phase ~= "credited" and phase ~= "failed_not_submitted" and phase ~= "creating" then
        actions[#actions + 1] = { text = state.inflight and T("Checking credit…") or T("Check credit"), enabled = not state.inflight,
            callback = function() self:_rechargePoll(state, true) end }
    end
    paragraphs[#paragraphs + 1] = { text = T("Closing stops automatic checks; the order is not canceled."), size = font.micro }
    actions[#actions + 1] = self:_rechargeCloseButton(state)
    self:_rechargeDialog(state, stateLabel(order), paragraphs, { actions }, {
        qr_url = code_allowed and order.code_url or nil, selected = { x = #actions, y = 1 },
    })
end

function Screens:_rechargeSchedule(state)
    if not self:_rechargeCurrent(state) or not state.order or state.phase ~= "order" then return end
    local phase = effectiveState(state.order)
    self:_rechargeUnschedule(state)
    local can_poll = phase ~= "credited" and phase ~= "expired" and phase ~= "unsaved" and phase ~= "failed_not_submitted"
        and phase ~= "creating" and type(state.order.order_id) == "string" and state.order.order_id ~= ""
    if not can_poll and self:_rechargeVisible(state) then self:_rechargeOrderView(state); return end
    local timer
    timer = function()
        if state.timer ~= timer then return end
        state.timer = nil
        if not self:_rechargeCurrent(state) then self:_rechargeCheckCurrent(); return end
        if not self:_rechargeVisible(state) then self:_rechargeSchedule(state); return end
        -- A visibility tick also removes an expired code while a slow check is in flight.
        self:_rechargeOrderView(state)
        local current_phase = effectiveState(state.order)
        if current_phase == "credited" or current_phase == "expired" or current_phase == "unsaved"
            or current_phase == "failed_not_submitted" or current_phase == "creating"
            or type(state.order.order_id) ~= "string" or state.order.order_id == "" then return end
        if state.inflight then self:_rechargeSchedule(state); return end
        self:_rechargePoll(state, false)
    end
    state.timer = timer
    UIManager:scheduleIn(3, timer)
end

function Screens:_rechargePoll(state, manual)
    if not self:_rechargeCurrent(state) or state.phase ~= "order" or not state.order then return end
    if not self:_rechargeVisible(state) then if not manual then self:_rechargeSchedule(state) end; return end
    if not manual then
        local phase = effectiveState(state.order)
        if phase == "credited" or phase == "expired" or phase == "unsaved" or phase == "failed_not_submitted" or phase == "creating" then
            self:_rechargeOrderView(state); return
        end
    end
    if state.inflight then
        if manual then state.manual_check = true; self:_rechargeOrderView(state) end
        return
    end
    local active_check = self.recharge_inflight_check
    if active_check and active_check.account_key == state.account_key and active_check.generation == state.generation then
        self:_rechargeSchedule(state)
        return
    end
    self:_rechargeUnschedule(state)
    local selected_id = orderId(state.order)
    state.inflight, state.manual_check, state.sequence = true, manual == true, state.sequence + 1
    local sequence, completed = state.sequence, false
    local check = { account_key = state.account_key, generation = state.generation }
    self.recharge_inflight_check = check
    if manual then self:_rechargeOrderView(state) end
    local function done(order, error)
        if completed then return end
        completed = true
        if self.recharge_inflight_check == check then self.recharge_inflight_check = nil end
        if not self:_rechargeCurrent(state) or state.sequence ~= sequence then return end
        state.inflight, state.manual_check = false, false
        if type(order) == "table" and tostring(orderId(order)) == tostring(selected_id)
            and (order.account_key == nil or order.account_key == state.account_key) then
            state.order = order
            state.poll_error = error and true or nil
        else state.poll_error = true end
        if self:_rechargeVisible(state) then self:_rechargeOrderView(state) end
        self:_rechargeSchedule(state)
    end
    local ok = pcall(self.controller.refreshRechargeOrder, self.controller, selected_id, done)
    if not ok then done(nil, { kind = "internal" }) end
    if self:_rechargeCurrent(state) and state.sequence == sequence then self:_rechargeSchedule(state) end
end

function Screens:_rechargeNewOrderNotice(state)
    if not self:_rechargeCurrent(state) then return end
    if state.inflight then state.manual_check = true; self:_rechargeOrderView(state); return end
    if self:_rechargeCreationBlock() then self:_rechargeOrdersView(state); return end
    self:_rechargeUnschedule(state)
    local previous = state.order
    state.phase = "new_order_notice"
    self:_rechargeDialog(state, T("Create a separate recharge"), {
        T("A new recharge does not cancel earlier orders. If an earlier payment is unresolved, check that order before paying again."),
        T("Continue to reload official amounts. A new payment order is created only after you review and confirm the chosen amount."),
    }, { {
        { text = T("Cancel"), is_enter_default = true, callback = function()
            if previous then state.phase, state.display_key = "order", nil; self:_rechargeOrderView(state); self:_rechargeSchedule(state)
            else self:_rechargeOrdersView(state) end
        end },
        { text = T("Choose a new amount"), callback = function() self:_rechargeLoadConfig(state) end },
    } }, { selected = { x = 1, y = 1 } })
end

function Screens:_showRechargeOrders()
    local state = self:_rechargeNewState()
    self:_rechargeOrdersView(state)
end

function Screens:_rechargeOrdersView(state, page)
    if not self:_rechargeCurrent(state) then return end
    self:_rechargeUnschedule(state)
    state.phase, state.sequence, state.inflight, state.manual_check, state.order = "orders", state.sequence + 1, false, false, nil
    local orders = self:_rechargeOrdersSnapshot()
    local pages = math.max(1, math.ceil(#orders / 5))
    page = math.max(1, math.min(page or 1, pages))
    local buttons, creating, unsaved = {}, false, false
    for order_index, order in ipairs(orders) do
        if order.state == "creating" then creating = true end
        if order.persistence_pending then unsaved = true end
    end
    for index = (page - 1) * 5 + 1, math.min(page * 5, #orders) do
        local order = orders[index]
        local reference = type(order.order_id) == "string" and order.order_id or tostring(orderId(order))
        local suffix = #reference > 8 and reference:sub(-8) or reference
        buttons[#buttons + 1] = { { text = string.format(T("CNY %s · %s · %s"), yuan(order.amount_cents), stateLabel(order), suffix), callback = function()
            self:_rechargeAttachOrder(state, order)
        end } }
    end
    if pages > 1 then
        buttons[#buttons + 1] = {
            { text = T("Previous"), enabled = page > 1, callback = function() self:_rechargeOrdersView(state, page - 1) end },
            { text = string.format("%d / %d", page, pages), enabled = false },
            { text = T("Next"), enabled = page < pages, callback = function() self:_rechargeOrdersView(state, page + 1) end },
        }
    end
    buttons[#buttons + 1] = { { text = T("Refresh saved orders"), callback = function() self:_rechargeOrdersView(state, page) end },
        { text = T("New recharge"), enabled = not creating and not unsaved, callback = function() self:_rechargeNewOrderNotice(state) end } }
    buttons[#buttons + 1] = { self:_rechargeCloseButton(state) }
    local paragraphs = { string.format(T("Receiving account: %s"), state.account_name),
        #orders == 0 and T("No local recharge orders are saved for this account.") or T("Open an order to view its full ID, amount, payment code, and confirmed result.") }
    if unsaved then paragraphs[#paragraphs + 1] = T("Save the unresolved order record before creating another recharge. Restore writable storage, then reopen and check that order.")
    elseif creating then paragraphs[#paragraphs + 1] = T("An order is still being created. New recharge requests are disabled until its result is recorded.") end
    self:_rechargeDialog(state, T("Recharge orders"), paragraphs, buttons)
end

end
