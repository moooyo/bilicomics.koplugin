local ButtonDialog = require("ui/widget/buttondialog")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local W = require("bilicomics/ui/widgets")
local Model = require("bilicomics/ui/model")
local Helpers = require("bilicomics/ui/screen_helpers")
local T = require("bilicomics/ui/i18n")
local title, asset = Helpers.title, Helpers.asset
local accountKey, purchasePurpose = Helpers.accountKey, Helpers.purchasePurpose

local function short(value, limit)
    if type(value) ~= "string" and type(value) ~= "number" then return "?" end
    local text, characters = tostring(value):gsub("[%c]", " "), {}
    for character in text:gmatch(".[\128-\191]*") do
        characters[#characters + 1] = character
        if #characters > (limit or 40) then
            characters[#characters] = "…"
            return table.concat(characters)
        end
    end
    return text
end

local function purchaseDate(value)
    local number = tonumber(value)
    if not number and type(value) == "string" and value ~= "" and not value:find("[%c]") then
        return short(value, 48)
    end
    if not number or number ~= number or number <= 0 or number > 253402300799 then return T("Time unavailable") end
    local ok, result = pcall(os.date, "!%Y-%m-%d %H:%M UTC", number)
    return ok and result or T("Time unavailable")
end

local function discountName(kind)
    local names = { none = T("No discount"), discount_card = T("Discount coupon"),
        activity = T("Activity offer"), free_gold_card = T("Free-coin card") }
    return names[kind] or T("Unverified discount")
end

local function requestedRange(scope)
    scope = scope or {}
    if scope.kind ~= "batch" then return T("Single chapter") end
    if scope.batch_limit == 0 then return T("Remaining from this chapter") end
    return string.format(T("Requested batch: %s chapters"), short(scope.batch_limit))
end

local function paymentName(payment)
    payment = Model.purchasePayment(payment)
    if payment.method == "coupon" then return T("Reading coupons") end
    local discount = payment.discount or {}
    return discount.kind and discount.kind ~= "none"
        and string.format(T("Coins · %s"), discountName(discount.kind)) or T("Coins without discount")
end

local function intentHeading(intent)
    if intent.persistence_pending then return T("Purchase result is not saved") end
    if intent.state == "access_confirmed" then
        if intent.range_outcome_pending then return T("Access ready · purchase pending") end
        return intent.transaction_evidence == "server_accepted" and T("Purchase confirmed") or T("Chapter access confirmed")
    end
    if intent.state == "rejected" then return T("Purchase rejected") end
    return T("Purchase result pending")
end

local function action(text, callback, options)
    local button = { text = text, callback = callback, font_size = 18, font_bold = false,
        height = W.scale(38), avoid_text_truncation = true }
    for key, value in pairs(options or {}) do button[key] = value end
    return button
end

local function dialogWithSummary(heading, paragraphs, buttons, options)
    options = options or {}
    local multiline = {}
    for row_index, row in ipairs(buttons) do
        for column, button in ipairs(row) do
            if type(button.text) == "string" and button.text:find("\n", 1, true) then
                button.id = button.id or "purchase-row-" .. row_index .. "-" .. column
                multiline[#multiline + 1] = button
            end
        end
    end
    local dialog = ButtonDialog:new{
        title = heading, use_info_style = false, title_face = Font:getFace("cfont", 21),
        title_padding = W.scale(8), title_margin = 0, buttons = buttons,
        width_factor = 0.94, modal = true, dismissable = options.dismissable ~= false,
        tap_close_callback = options.close, rows_per_page = options.rows_per_page, selected = options.selected,
    }
    local width, rows, text = dialog:getAddedWidgetAvailableWidth(), {}, { heading }
    for _paragraph_index, paragraph in ipairs(paragraphs or {}) do
        local item = type(paragraph) == "table" and paragraph or { text = paragraph }
        if item.text and item.text ~= "" then
            if #rows > 0 then rows[#rows + 1] = W.space(4) end
            rows[#rows + 1] = W.text(item.text, width, item.size or 18, { bold = item.bold })
            text[#text + 1] = item.text
        end
    end
    if #rows > 0 then
        local summary = W.column(rows)
        summary.not_focusable, summary.parent = true, dialog
        dialog:addWidget(summary)
    end
    -- Native Button starts with a single-line TextWidget. Keep its geometry and
    -- input behavior, but use a native TextBoxWidget for intentional line breaks.
    for _entry_index, entry in ipairs(multiline) do
        local button = dialog:getButtonById(entry.id)
        local label = TextBoxWidget:new{
            text = entry.text, width = button.label_container.dimen.w, height = button.label_container.dimen.h,
            height_adjust = true, height_overflow_show_ellipsis = true, line_height = 0,
            alignment = entry.align or "left", face = Font:getFace("cfont", entry.font_size or 18),
            bold = entry.font_bold == true, fgcolor = entry.enabled == false and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK,
        }
        button.label_widget:free()
        button.label_widget, button.label_container[1] = label, label
        button.did_truncation_tweaks = true
    end
    -- Keep a text-only description available to accessibility and capture consumers.
    dialog.purchase_text = table.concat(text, "\n")
    return dialog
end

local function purchaseError(error, context)
    local heading, message, route = Model.error(error)
    local kind = type(error) == "table" and error.kind
    if kind == "network" or kind == "connectivity" or kind == "timeout" or kind == "transport" then
        message = context == "quote" and T("The quote could not be loaded. Check the connection, then refresh the quote.")
            or context == "result" and T("The purchase is still unresolved. Check the connection, then check its result again.")
            or T("Access is preserved. Check the connection, then retry this content operation.")
    elseif context == "result" and (kind == "purchase_busy" or kind == "outcome_unknown" or kind == "purchase_unknown") then
        heading, message = T("Purchase result pending"), T("No purchase will be sent again. Check the result when ready.")
    elseif kind == "storage" or kind == "persistence_pending" then
        message = context == "result" and T("Check writable storage and free space, then check the saved result. Do not purchase again.")
            or T("Check writable storage and free space before retrying.")
    end
    return heading, message, route
end

return function(Screens)

function Screens:_purchaseChapter(state, quote)
    quote = quote or (state.intent or {}).quote or state.quote or {}
    local id = tostring(quote.episode_id or (quote.episode_ids or {})[1] or (state.episode or {}).id or "")
    if state.episode and tostring(state.episode.id) == id and (state.episode.title or state.episode.short_title) then
        return title(state.episode), id
    end
    local comic_id = quote.comic_id or (state.intent or {}).comic_id or (state.comic or {}).id
    for _episode_index, episode in ipairs(Model.array(self.controller:getEpisodes(comic_id))) do
        if tostring(episode.id) == id then return title(episode), id end
    end
    return string.format(T("Chapter %s"), short(id)), id
end

function Screens:_purchaseContext(state, quote)
    local chapter = self:_purchaseChapter(state, quote)
    return short(title(state.comic or {}), 34) .. "\n" .. short(chapter, 40)
end

function Screens:_pendingList(pending)
    self:_closeDialog()
    local epoch, account_key, generation = self.epoch, accountKey(self.controller), self.controller.generation
    local buttons, dialog = {}
    for _intent_index, intent in ipairs(pending) do
        local state = { intent = intent, comic = self.controller:getComic(intent.comic_id) or { id = intent.comic_id },
            episode = { id = (intent.quote or {}).episode_id or (intent.episode_ids or {})[1] }, quote = intent.quote,
            scope = Model.purchaseScope((intent.quote or {}).scope), payment = Model.purchasePayment((intent.quote or {}).payment),
            purpose = purchasePurpose(intent), epoch = epoch, account_key = account_key, generation = generation }
        local chapter = self:_purchaseChapter(state)
        local quote = intent.quote or {}
        local amount = Model.purchaseNumber(quote.amount)
        local purpose = state.purpose == "download" and T("Download") or T("Read")
        local label = short(title(state.comic), 27) .. " · " .. short(chapter, 24)
            .. "\n" .. intentHeading(intent) .. " · " .. purpose
            .. "\n" .. (amount and string.format(T("Submitted quote: %s %s"), amount, asset(quote.method)) or T("Quote amount unavailable"))
            .. "\n" .. purchaseDate(intent.created_at)
        buttons[#buttons + 1] = { action(label, function()
            if self.dialog ~= dialog or epoch ~= self.epoch or account_key ~= accountKey(self.controller)
                or generation ~= self.controller.generation then return end
            self.purchase_state, self.purchase_visible = state, true
            self:_purchaseDialog()
        end, { align = "left", height = W.scale(106) }) }
    end
    buttons[#buttons + 1] = { action(T("Close"), function() if self.dialog == dialog then self:_closeDialog() end end) }
    dialog = dialogWithSummary(T("Purchases awaiting confirmation"), #pending == 0 and { T("No purchases need attention.") }
        or { T("Choose a purchase to review its saved terms and result.") }, buttons, { rows_per_page = 3 })
    self.dialog = dialog; UIManager:show(dialog)
end

function Screens:_purchaseFor(comic, episode, purpose)
    self.purchase_state = { comic = comic, episode = episode, loading = true, purpose = purchasePurpose(nil, purpose),
        epoch = self.epoch, account_key = accountKey(self.controller), generation = self.controller.generation }
    self.purchase_visible = true
    for _intent_index, intent in ipairs(Model.pending(self.controller)) do
        for _episode_index, id in ipairs(intent.episode_ids or {}) do
            if tostring(id) == tostring(episode.id) then
                self.purchase_state.intent, self.purchase_state.quote = intent, intent.quote
                self.purchase_state.purpose = purchasePurpose(intent)
                self.purchase_state.loading = nil; self:_purchaseDialog(); return
            end
        end
    end
    self:_quote(nil, nil)
end

function Screens:_purchaseCurrent(state)
    return self.purchase_state == state and self.purchase_visible and self.route ~= nil
        and state.epoch == self.epoch and state.account_key == accountKey(self.controller) and state.generation == self.controller.generation
end

function Screens:_quote(scope, payment)
    local state = self.purchase_state
    if not state or not self:_purchaseCurrent(state) or state.submitting or state.intent then return end
    if self.scope_dialog then UIManager:close(self.scope_dialog); self.scope_dialog = nil end
    scope = Model.purchaseScope(scope or state.scope or (state.quote or {}).scope)
    if state.purpose == "download" then scope = { kind = "single", order = scope.order } end
    payment = Model.purchasePayment(payment or state.payment or (state.quote or {}).payment)
    state.options_quote = state.quote or state.options_quote
    state.scope, state.payment = scope, payment
    state.loading, state.error, state.quote, state.notice, state.result_error = true, nil, nil, nil, nil
    state.request = (state.request or 0) + 1
    local request, epoch = state.request, self.epoch
    self:_purchaseDialog()
    self.controller:quotePurchase(tostring(state.episode.id), scope, payment, function(quote, error)
        if not self:_purchaseCurrent(state) or request ~= state.request or epoch ~= self.epoch then return end
        state.loading, state.quote, state.error = nil, quote, error
        if quote then
            state.scope, state.payment = Model.purchaseScope(quote.scope), Model.purchasePayment(quote.payment)
            state.options_quote = quote
            if state.previous_quote then
                state.notice = T("Quote refreshed. Review these terms and confirm again.")
                local previous, current = Model.purchaseNumber(state.previous_quote.amount), Model.purchaseNumber(quote.amount)
                if previous and current and (previous ~= current or state.previous_quote.method ~= quote.method) then
                    state.notice = string.format(T("Previous quote: %s %s. Review the new total before confirming."), previous, asset(state.previous_quote.method))
                end
            end
        end
        self:_purchaseDialog()
    end)
end

function Screens:_scopeText(quote, submitted)
    local episodes, lines = Model.array(self.controller:getEpisodes(quote.comic_id)), {}
    local by_id = {}; for _episode_index, episode in ipairs(episodes) do by_id[tostring(episode.id)] = title(episode) end
    if (quote.scope or {}).kind == "batch" then
        lines[#lines + 1] = Model.ordinalRange(quote) and Model.purchaseRangeLabel(quote.scope) or T("Batch selection")
        lines[#lines + 1] = T("Catalog updates or purchases elsewhere may change the actual chapters. Details show the current expected list.")
        local anchor_id = tostring(quote.episode_id or "")
        local selected = (self.purchase_state or {}).episode
        local anchor_title = type(selected) == "table" and tostring(selected.id) == anchor_id and title(selected) or by_id[anchor_id]
        if anchor_title then lines[#lines + 1] = string.format(T("Starting chapter: %s"), anchor_title) end
        lines[#lines + 1] = ""
        lines[#lines + 1] = submitted and T("Expected chapters in the submitted quote:") or T("Current expected chapters:")
    end
    for _episode_index, id in ipairs(quote.episode_ids or {}) do lines[#lines + 1] = by_id[tostring(id)] or tostring(id) end
    return table.concat(lines, "\n")
end

function Screens:_purchaseSelectionText(state, trusted_quote)
    local scope, payment = state.scope or {}, Model.purchasePayment(state.payment)
    local range = trusted_quote and Model.ordinalRange(trusted_quote) and Model.purchaseRangeLabel(scope)
    local lines = { scope.kind == "batch" and (range or requestedRange(scope)) or T("Single chapter"),
        string.format(T("Payment: %s"), asset(payment.method)) }
    if type(payment.discount) == "table" and payment.discount.kind ~= "none" then
        lines[#lines + 1] = string.format(T("Selected discount: %s / %s"), discountName(payment.discount.kind), short(payment.discount.id, 48))
    elseif payment.method == "coin" then lines[#lines + 1] = T("No discount") end
    if type(payment.coupon_ids) == "table" and #payment.coupon_ids > 0 then
        lines[#lines + 1] = string.format(T("Selected coupons: %d"), #payment.coupon_ids)
    end
    if trusted_quote and (trusted_quote.payment or {}).method == "coupon" then
        local ids = Model.couponIdentifiers(trusted_quote)
        if ids then
            lines[#lines + 1] = T("Coupon IDs (identification only):")
            for _coupon_index, id in ipairs(ids) do lines[#lines + 1] = id end
        else lines[#lines + 1] = T("Coupon identifiers are unavailable in this quote.") end
    end
    if payment.method == "coin" then lines[#lines + 1] = scope.order == 2 and T("Order: expiry") or T("Order: discount") end
    return table.concat(lines, "\n")
end

function Screens:_candidateAmountLines(quote)
    local values, lines = type(quote.amounts) == "table" and quote.amounts or {}, {}
    for _field_index, field in ipairs({ { "original", T("Platform original price: %s") },
        { "display", T("Platform display reference: %s") }, { "submission", T("Settlement reference (not confirmed charge): %s") },
        { "free_gold", T("Free-coin deduction reference: %s") } }) do
        local value = Model.purchaseNumber(values[field[1]])
        if value then lines[#lines + 1] = string.format(field[2], value) end
    end
    return lines
end

function Screens:_candidateDetails(state, quote)
    local labels = { scope_unverified = T("Chapter range is not verified."), amount_unverified = T("Final charge is not verified."),
        asset_unverified = T("Payment asset is not verified."), discount_unverified = T("The discount is not verified."),
        entitlement_unverified = T("The resulting access is not verified."), asset_unavailable = T("The selected payment asset is unavailable."),
        context_unverified = T("The offer context is not verified."), offer_unavailable = T("The selected offer is unavailable.") }
    local lines = { T("This candidate cannot be submitted. Its exact chapters and final charge have not been confirmed."),
        "", T("Requested selection · unverified"), self:_purchaseSelectionText(state),
        "", T("Reported amounts are separate observations, not a confirmed payable total.") }
    for _line_index, line in ipairs(self:_candidateAmountLines(quote)) do lines[#lines + 1] = line end
    local seen = {}; lines[#lines + 1] = ""
    for _blocker_index, code in ipairs(type(quote.blockers) == "table" and quote.blockers or {}) do
        local message = labels[code] or T("Additional verification is required.")
        if not seen[message] then lines[#lines + 1] = message; seen[message] = true end
    end
    self.scope_dialog = TextViewer:new{ title = T("Unverified offer details"), text = table.concat(lines, "\n"), modal = true }
    UIManager:show(self.scope_dialog)
end

function Screens:_purchaseRecordDetails(state)
    local intent, quote = state.intent, (state.intent or {}).quote or state.quote or {}
    local purpose = purchasePurpose(intent, state.purpose)
    local chapter = self:_purchaseChapter(state, quote)
    local lines = { title(state.comic or {}), chapter,
        purpose == "download" and T("Next action: download this chapter") or T("Next action: read this chapter") }
    if intent then
        lines[#lines + 1], lines[#lines + 2] = "", intentHeading(intent)
        lines[#lines + 1] = string.format(T("Record ID: %s"), short(intent.id, 256))
        lines[#lines + 1] = string.format(T("Submitted: %s"), purchaseDate(intent.created_at))
        lines[#lines + 1] = string.format(T("Submitted quote: %s %s"), Model.purchaseNumber(quote.amount) or T("Not confirmed"), asset(quote.method))
        lines[#lines + 1] = T("Submitted terms are a reference, not proof of payment.")
        if intent.range_outcome_pending then
            lines[#lines + 1] = T("The range purchase result remains unverified. Reading access does not prove which chapters were purchased. Further purchases for this comic remain paused.")
        end
    end
    lines[#lines + 1], lines[#lines + 2] = "", self:_scopeText(quote, intent ~= nil)
    lines[#lines + 1], lines[#lines + 2] = "", self:_purchaseSelectionText({ scope = quote.scope, payment = quote.payment }, quote)
    self.scope_dialog = TextViewer:new{ title = intent and T("Purchase record") or T("Purchase scope"), text = table.concat(lines, "\n"), modal = true }
    UIManager:show(self.scope_dialog)
end

function Screens:_purchaseChoices(which, page)
    local state = self.purchase_state
    if not state or not self:_purchaseCurrent(state) or state.loading or state.submitting or state.intent then return end
    local source, request = state.quote or state.options_quote, state.request
    if not source then source = {}; state.options_quote = source end
    local entries = {}
    local function add(selection, label, available, details)
        for _entry_index, entry in ipairs(entries) do if Model.samePurchaseSelection(entry.selection, selection) then return end end
        entries[#entries + 1] = { selection = selection, label = label, available = available ~= false, details = details or {} }
    end
    if which == "scope" then
        add(Model.purchaseScope({ kind = "single", order = (state.scope or {}).order }), T("Single chapter"), true)
        if state.purpose ~= "download" then
            for _offer_index, offer in ipairs(source.batch_offers or {}) do
                if type(offer.scope) == "table" and offer.scope.kind == "batch" then
                    local details, display = {}, Model.purchaseNumber(offer.display_amount)
                    if display then details[#details + 1] = string.format(T("Reference price: %s · not the final charge"), display) end
                    add(Model.purchaseScope(offer.scope), requestedRange(offer.scope), offer.available, details)
                end
            end
            for _option_index, option in ipairs(source.scopes or {}) do
                if option.kind == "batch" then add(Model.purchaseScope(option), requestedRange(option), option.available) end
            end
        end
    else
        for _option_index, option in ipairs(source.payments or {}) do
            add(Model.purchasePayment(option), paymentName(option), option.available,
                option.available == false and { T("Unavailable for this selection") } or nil)
        end
        add(Model.purchasePayment({ method = "coin" }), T("Coins without discount"), true)
        for _option_index, option in ipairs(source.discount_options or {}) do
            if type(option.payment) == "table" then
                local discount, details = option.payment.discount or {}, {}
                if option.expire_time then details[#details + 1] = string.format(T("Expires: %s"), purchaseDate(option.expire_time)) end
                if option.available == false then
                    details[#details + 1] = option.unavailable_reason == "free_gold_card_banned"
                        and T("Free-coin cards cannot be used here") or T("This asset is not usable for this selection")
                end
                if discount.kind and discount.kind ~= "none" then
                    details[#details + 1] = string.format(T("Asset: %s"), short(discount.id, 28))
                end
                add(Model.purchasePayment(option.payment), paymentName(option.payment), option.available, details)
            end
        end
        add(Model.purchasePayment(state.payment), paymentName(state.payment), false, { T("The saved selection is unavailable. Choose another option.") })
    end
    local selected = which == "scope" and Model.purchaseScope(state.scope) or Model.purchasePayment(state.payment)
    local per_page, pages = 2, math.max(1, math.ceil(#entries / 2))
    if not page then
        page = 1
        for index, entry in ipairs(entries) do
            if Model.samePurchaseSelection(entry.selection, selected) then page = math.ceil(index / per_page); break end
        end
    end
    page = math.max(1, math.min(pages, page))
    self:_closeDialog(true)
    local dialog
    local function current()
        return self:_purchaseCurrent(state) and self.dialog == dialog and UIManager:getTopmostVisibleWidget() == dialog
            and state.request == request and (state.quote or state.options_quote or {}) == source
            and not state.loading and not state.submitting and not state.intent
    end
    local buttons = {}
    for index = (page - 1) * per_page + 1, math.min(page * per_page, #entries) do
        local entry = entries[index]
        local lines = { (Model.samePurchaseSelection(entry.selection, selected) and "● " or "○ ") .. entry.label }
        for _line_index, line in ipairs(entry.details) do lines[#lines + 1] = line end
        if entry.available == false and #entry.details == 0 then lines[#lines + 1] = T("Unavailable for this selection") end
        buttons[#buttons + 1] = { action(table.concat(lines, "\n"), function()
            if not current() or not entry.available then return end
            if which == "scope" then self:_quote(entry.selection, Model.purchasePayment(state.payment))
            else self:_quote(Model.purchaseScope(state.scope), entry.selection) end
        end, { enabled = entry.available, align = "left", height = W.scale(36 + math.min(#lines - 1, 3) * 22) }) }
    end
    if which == "payment" and (state.payment or {}).method == "coin" then
        buttons[#buttons + 1] = { action(string.format(T("Offer priority: %s"), (state.scope or {}).order == 2 and T("Expiry first") or T("Discount first")), function()
            if current() then self:_purchasePaymentOrder() end
        end) }
    end
    if pages > 1 then
        buttons[#buttons + 1] = {
            action(T("Previous"), function() if current() then self:_purchaseChoices(which, page - 1) end end, { enabled = page > 1 }),
            action(string.format(T("%d / %d"), page, pages), function() end, { enabled = false }),
            action(T("Next"), function() if current() then self:_purchaseChoices(which, page + 1) end end, { enabled = page < pages }),
        }
    end
    buttons[#buttons + 1] = { action(T("Back to quote"), function() if current() then self:_purchaseDialog() end end) }
    dialog = dialogWithSummary(which == "scope" and T("Choose purchase range") or T("Choose payment option"),
        { T("Selecting an option requests a new quote. It does not purchase anything.") }, buttons, { dismissable = false })
    self.dialog = dialog; UIManager:show(dialog)
end

function Screens:_purchasePaymentOrder()
    local state = self.purchase_state
    if not state or not self:_purchaseCurrent(state) or state.loading or state.submitting or state.intent then return end
    self:_closeDialog(true)
    local dialog, buttons, request = nil, {}, state.request
    local function current()
        return self:_purchaseCurrent(state) and self.dialog == dialog and UIManager:getTopmostVisibleWidget() == dialog
            and state.request == request and not state.loading and not state.submitting and not state.intent
    end
    for index, label in ipairs({ T("Discount first"), T("Expiry first") }) do
        local order = index
        buttons[#buttons + 1] = { action(((state.scope or {}).order == order and "● " or "○ ") .. label, function()
            if not current() then return end
            local scope = Model.purchaseScope(state.scope); scope.order = order
            self:_quote(scope, Model.purchasePayment(state.payment))
        end) }
    end
    buttons[#buttons + 1] = { action(T("Back to payment options"), function() if current() then self:_purchaseChoices("payment") end end) }
    dialog = dialogWithSummary(T("Offer priority"), { T("Choose how eligible offers are prioritized. The final selection is checked in a new quote.") }, buttons, { dismissable = false })
    self.dialog = dialog; UIManager:show(dialog)
end

function Screens:_purchaseSelectionButtons(state, buttons, current)
    local choices = {}
    if state.purpose ~= "download" then
        choices[#choices + 1] = action(T("Choose range"), function() if current() then self:_purchaseChoices("scope") end end,
            { enabled = not state.submitting })
    end
    choices[#choices + 1] = action(T("Choose payment"), function() if current() then self:_purchaseChoices("payment") end end,
        { enabled = not state.submitting })
    buttons[#buttons + 1] = choices
end

function Screens:_purchaseRecoveryButtons(state, error, buttons, current)
    local _error_heading, _error_message, route = Model.error(error)
    local kind = type(error) == "table" and error.kind
    if route == "account" then
        buttons[#buttons + 1] = { action(T("Open account"), function() if current() then self:showAccount() end end) }
    elseif kind == "storage" or kind == "low_space" or kind == "persistence_pending" then
        buttons[#buttons + 1] = { action(T("Check storage"), function()
            if not current() then return end
            if self._showStorageSettings then self:_showStorageSettings() else self:showAccount() end
        end) }
    end
end

function Screens:_purchaseDialog()
    local state = self.purchase_state
    if not state or not self:_purchaseCurrent(state) then return end
    self:_closeDialog(true)
    local quote, intent = state.quote, state.intent
    local purpose = purchasePurpose(intent, state.purpose)
    local candidate = quote and quote.submittable == false
    local dialog, request = nil, state.request
    local function visible()
        return self:_purchaseCurrent(state) and self.dialog == dialog and UIManager:getTopmostVisibleWidget() == dialog
            and state.request == request
    end
    local function current() return visible() and not state.loading and not state.submitting and not state.intent end
    local function intentCurrent() return visible() and state.intent == intent and not state.submitting and not state.continuing end
    local heading, paragraphs, buttons = T("Review this purchase"), {}, {}
    paragraphs[#paragraphs + 1] = { text = self:_purchaseContext(state, intent and intent.quote or quote), bold = true }
    paragraphs[#paragraphs + 1] = { text = purpose == "download" and T("Next action: download this chapter")
        or T("Next action: read this chapter"), size = 15 }
    if state.loading then
        heading = T("Getting purchase quote…")
        paragraphs[#paragraphs + 1] = T("No purchase has been submitted for this quote.")
    elseif intent then
        local confirmed = intent.state == "access_confirmed" and not intent.persistence_pending
        local rejected = intent.state == "rejected" and not intent.persistence_pending
        local range_pending = intent.range_outcome_pending == true
        heading = state.submitting and T("Checking purchase result…") or state.continuing
            and (purpose == "download" and T("Creating download…") or T("Opening chapter…")) or intentHeading(intent)
        local submitted_quote = intent.quote or quote or {}
        local amount = Model.purchaseNumber(submitted_quote.amount)
        if amount then
            paragraphs[#paragraphs + 1] = { text = string.format(T("Submitted quote: %s %s"), amount, asset(submitted_quote.method))
                .. "\n" .. T("Quote reference, not proof of payment."), size = 15 }
        end
        if confirmed then
            paragraphs[#paragraphs + 1] = range_pending and T("Reading is available. The range result is pending; purchases for this comic remain paused.")
                or T("Access is ready. Continue below without purchasing again.")
            buttons[#buttons + 1] = { action(state.continuing and (purpose == "download" and T("Creating download…") or T("Opening chapter…"))
                or purpose == "download" and (state.continuation_error and T("Retry download") or T("Download chapter"))
                or (state.continuation_error and T("Retry opening chapter") or T("Read chapter")), function()
                if not intentCurrent() then return end
                state.continuing, state.continuation_error, state.notice = true, nil, nil
                local episode_id = tostring((intent.quote or {}).episode_id or (intent.episode_ids or {})[1])
                local ticket = purpose == "read" and self._rememberReaderReturn and self:_rememberReaderReturn(tostring(intent.comic_id))
                self:_purchaseDialog()
                self:_invoke(purpose == "download" and "downloadEpisodes" or "readEpisode",
                    { tostring(intent.comic_id), purpose == "download" and { episode_id } or episode_id }, function(_value, error)
                    state.continuing = nil
                    if error and ticket and self._clearReaderReturn then self:_clearReaderReturn(ticket) end
                    if not self:_purchaseCurrent(state) then return end
                    if error then state.continuation_error = error; self:_purchaseDialog()
                    elseif purpose == "download" then self:showDownloads()
                    else if ticket then ticket.ready = true end; self:close(true) end
                end, true)
            end, { enabled = not state.continuing, font_bold = true }) }
        elseif rejected then
            paragraphs[#paragraphs + 1] = T("The purchase was not accepted. Get a new quote before trying again.")
            buttons[#buttons + 1] = { action(T("Get new quote"), function()
                if not intentCurrent() then return end
                state.intent, state.result_error, state.error = nil, nil, nil
                self:_quote(nil, nil)
            end, { font_bold = true }) }
        else
            paragraphs[#paragraphs + 1] = intent.persistence_pending and T("The result is waiting for local storage. Do not purchase again.")
                or T("No purchase will be sent again. Check the result when ready.")
            buttons[#buttons + 1] = { action(state.submitting and T("Checking result…") or T("Refresh result"), function()
                if not intentCurrent() then return end
                state.submitting, state.result_error = true, nil
                self:_purchaseDialog()
                self.controller:reconcilePurchase(intent.id, function(value, error)
                    state.submitting = nil
                    if value then state.intent = value end
                    -- An existing intent and a recoverable error may arrive together.
                    state.result_error = error
                    if self:_purchaseCurrent(state) then self:_purchaseDialog() end
                end)
            end, { enabled = not state.submitting, font_bold = true }) }
        end
        local recovery_error = state.continuation_error or state.result_error
        if recovery_error then
            local error_heading, message = purchaseError(recovery_error, state.continuation_error and "content" or "result")
            paragraphs[#paragraphs + 1] = error_heading .. "\n" .. message
            self:_purchaseRecoveryButtons(state, recovery_error, buttons, intentCurrent)
        elseif intent.persistence_pending then
            self:_purchaseRecoveryButtons(state, { kind = "persistence_pending" }, buttons, intentCurrent)
        end
        buttons[#buttons + 1] = { action(T("Purchase record and scope"), function()
            if intentCurrent() then self:_purchaseRecordDetails(state) end
        end, { enabled = not state.submitting and not state.continuing }) }
    elseif state.error then
        local error_heading, message = purchaseError(state.error, "quote")
        heading = error_heading
        paragraphs[#paragraphs + 1] = message
        paragraphs[#paragraphs + 1] = { text = requestedRange(state.scope) .. " · " .. paymentName(state.payment), size = 15 }
        self:_purchaseRecoveryButtons(state, state.error, buttons, current)
        buttons[#buttons + 1] = { action(T("Refresh quote"), function() if current() then self:_quote(nil, nil) end end, { font_bold = true }) }
        self:_purchaseSelectionButtons(state, buttons, current)
    elseif candidate then
        heading = T("Offer cannot be purchased")
        paragraphs[#paragraphs + 1] = T("The final charge or chapter access is not verified. This offer cannot be submitted.")
        paragraphs[#paragraphs + 1] = { text = T("Requested selection · unverified") .. "\n"
            .. requestedRange(state.scope) .. " · " .. paymentName(state.payment), size = 15 }
        buttons[#buttons + 1] = { action(T("Request single-chapter quote"), function()
            if current() then self:_quote({ kind = "single", order = (state.scope or {}).order }, Model.purchasePayment(state.payment)) end
        end, { font_bold = true }) }
        self:_purchaseSelectionButtons(state, buttons, current)
        buttons[#buttons + 1] = {
            action(T("Offer details"), function() if current() and state.quote == quote then self:_candidateDetails(state, quote) end end),
            action(T("Refresh quote"), function() if current() then self:_quote(nil, nil) end end),
        }
    elseif quote then
        local amount = tostring(quote.amount or "?")
        local batch, ordinal = (quote.scope or {}).kind == "batch", Model.ordinalRange(quote)
        heading = state.submitting and T("Submitting purchase…") or quote.can_afford == false and T("Insufficient balance") or heading
        paragraphs[#paragraphs + 1] = { text = string.format(T("Total: %s %s"), amount, asset(quote.method)), size = 21, bold = true }
        local range = batch and (ordinal and Model.purchaseRangeLabel(quote.scope) or T("Batch selection")) or T("Single chapter")
        paragraphs[#paragraphs + 1] = range .. " · " .. paymentName(quote.payment)
        local permanent = #(quote.episode_ids or {}) > 0
        for _episode_index, id in ipairs(quote.episode_ids or {}) do
            local access = (quote.expected_access or {})[tostring(id)]
            if not access or access.access ~= "owned" then permanent = false end
        end
        paragraphs[#paragraphs + 1] = { text = (permanent and T("Permanent ownership") or T("Chapter reading access"))
            .. " · " .. string.format(T("Available: %s %s"), tostring(quote.balance or "?"), asset(quote.method)), size = 15 }
        if batch then paragraphs[#paragraphs + 1] = { text = T("Expected chapters may change with catalog updates or purchases elsewhere. Review the scope."), size = 15 } end
        if quote.can_afford == false then
            buttons[#buttons + 1] = { action(T("Refresh balance"), function()
                if not current() or state.quote ~= quote then return end
                self:_invoke("refreshWallet", {}, function(_value, error)
                    if not current() or state.quote ~= quote then return end
                    if error then state.error = error; self:_purchaseDialog()
                    else self:_quote(Model.purchaseScope(state.scope), Model.purchasePayment(state.payment)) end
                end, true)
            end, { enabled = not state.submitting, font_bold = true }) }
        elseif quote.submittable ~= false and quote.can_afford == true and quote.amount ~= nil and quote.fingerprint then
            buttons[#buttons + 1] = { action(state.submitting and T("Submitting purchase…")
                or string.format(T("Confirm purchase · %s %s"), amount, asset(quote.method)), function()
                if not current() or state.error or state.quote ~= quote or quote.submittable == false then return end
                state.submitting, state.result_error = true, nil
                self:_purchaseDialog()
                self.controller:purchase(quote, purpose, function(value, error)
                    state.submitting = nil
                    if value then state.intent, state.result_error = value, error
                    elseif error and (error.kind == "outcome_unknown" or error.kind == "purchase_unknown" or error.kind == "purchase_busy") then
                        for _pending_index, pending in ipairs(Model.pending(self.controller)) do
                            if pending.quote and pending.quote.fingerprint == quote.fingerprint then state.intent = pending; break end
                        end
                        if not state.intent then state.intent = { state = "outcome_unknown", comic_id = quote.comic_id,
                            episode_ids = quote.episode_ids, quote = quote, id = error.intent_id, purpose = purpose } end
                        state.result_error = error
                    else
                        state.error = error or { kind = "internal" }
                        if error and (error.kind == "quote_changed" or error.kind == "quote_expired" or error.kind == "insufficient_balance") then
                            state.previous_quote = quote
                        end
                    end
                    if self:_purchaseCurrent(state) then self:_purchaseDialog() end
                end)
            end, { enabled = not state.submitting, font_bold = true }) }
        end
        self:_purchaseSelectionButtons(state, buttons, current)
        buttons[#buttons + 1] = { action(batch and T("Review expected chapters") or T("Review exact chapters"), function()
            if current() and state.quote == quote and quote.submittable ~= false then self:_purchaseRecordDetails(state) end
        end, { enabled = not state.submitting }) }
    end
    if state.notice and not intent then paragraphs[#paragraphs + 1] = { text = state.notice, size = 15 } end
    buttons[#buttons + 1] = { action(T("Close"), function() if visible() and not state.submitting then self:_closeDialog() end end,
        { enabled = not state.submitting }) }
    dialog = dialogWithSummary(heading, paragraphs, buttons, { dismissable = not state.submitting,
        selected = not state.submitting and { x = 1, y = #buttons } or nil,
        close = function() if not state.submitting then self:_closeDialog() end end })
    self.dialog = dialog; UIManager:show(dialog)
end

end
