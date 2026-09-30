local BB = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local FileChooser = require("ui/widget/filechooser")
local SessionInput = require("bilicomics/ui/session_input")
local QRLogin = require("bilicomics/ui/qr_login")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local W = require("bilicomics/ui/widgets")
local Model = require("bilicomics/ui/model")
local Helpers = require("bilicomics/ui/screen_helpers")
local T = require("bilicomics/ui/i18n")
local accountKey = Helpers.accountKey
local font = W.font or { page = 24, title = 21, item = 18, body = 18, status = 15, meta = 14, micro = 13 }

local function space(value) return W.spacePixels(W.dp(value)) end
local function face(value) return W.fontSize(value) end
local function singleText(value, size, options)
    options = options or {}
    return TextWidget:new{ text = tostring(value), face = Font:getFace("cfont", face(size)),
        bold = options.bold or false, fgcolor = options.muted and W.muted or W.ink, padding = 0 }
end
local function box(content, width, height, border, background)
    border = border or 0
    return FrameContainer:new{ padding = 0, margin = 0, radius = 0, bordersize = border,
        color = BB.Color8(0x11), background = background or W.paper,
        CenterContainer:new{ dimen = Geom:new{ w = width - border * 2, h = height - border * 2 }, content } }
end

local SettingsRow = InputContainer:extend{}
function SettingsRow:init()
    local arrow_width, label_width = W.dp(30), math.floor(self.width * 0.52)
    local text_width = self.width - label_width - arrow_width
    self.frame = box(W.row{
        W.text(self.label, label_width, face(21)),
        W.text(self.value or "", text_width, face(19), { muted = true, align = "right", height = W.dp(32), fixed_height = true }),
        W.text("›", arrow_width, face(22), { muted = true, align = "right" }),
    }, self.width, W.dp(66))
    self[1] = self.frame
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = W.dp(66) }
    self.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function SettingsRow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.frame:paintTo(bb, x, y)
    if self.focused then
        bb:paintRect(x, y, W.dp(4), self.dimen.h, BB.Color8(0x11))
    end
end
function SettingsRow:onFocus() self.focused = true; return true end
function SettingsRow:onUnfocus() self.focused = false; return true end
function SettingsRow:onTapSelect() if self.callback then self.callback() end; return true end
SettingsRow.onSelect = SettingsRow.onTapSelect

local ChoiceCard = InputContainer:extend{}
function ChoiceCard:init()
    self[1] = self.content
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function ChoiceCard:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.content:paintTo(bb, x, y)
    if self.focused then bb:paintRect(x, y + self.height - W.dp(5), self.width, W.dp(5), BB.Color8(0x11)) end
end
function ChoiceCard:onFocus() self.focused = true; return true end
function ChoiceCard:onUnfocus() self.focused = false; return true end
function ChoiceCard:onTapSelect() if self.callback then self.callback() end; return true end
ChoiceCard.onSelect = ChoiceCard.onTapSelect

local function modeLabel(value)
    return T(value == "page" and "Page comic" or value == "strip" and "Long strip" or "Automatic")
end
local function directionLabel(value) return T(value == "rtl" and "Right to left" or "Left to right") end
local function timestamp(value)
    if type(value) ~= "number" or value <= 0 then return nil end
    local ok, label = pcall(os.date, "%H:%M", value)
    return ok and label or nil
end

return function(Screens)

function Screens:_importSession()
    self:_closeDialog()
    local dialog
    dialog = InputDialog:new{ title = T("Import web session"), input = "", input_hint = T("Paste the Cookie header from your own Bilibili web session"), modal = true,
        text_type = "password", description = T("Your session is stored privately on this device. Replacing it switches the account used by this plugin."),
        buttons = { { { text = T("Import from file"), callback = function()
            if self.dialog == dialog then self:_importSessionFile() end
        end } }, { { text = T("Cancel"), callback = function() self:_closeDialog() end },
            { text = T("Import session"), callback = function()
                self:_beginSessionImport(dialog:getInputText(), "paste")
            end } } } }
    self.dialog = dialog; UIManager:show(dialog); dialog:onShowKeyboard()
end

function Screens:_otherSignInMethods()
    local dialog
    dialog = self:_showContextDialog(T("Other sign-in methods") .. "\n\n"
        .. T("QR sign-in renews automatically. Imported web sessions need to be replaced when they expire.") .. "\n\n"
        .. T("Session files: .txt, .json or .cookies, up to 128 KiB."), {
        { { text = T("Paste web session"), callback = function() if self.dialog == dialog then self:_importSession() end end } },
        { { text = T("Import from file"), callback = function() if self.dialog == dialog then self:_importSessionFile() end end } },
        { { text = T("Close"), callback = function() if self.dialog == dialog then dialog:onClose() end end } },
    })
end

function Screens:_sessionImportResult(state)
    if self.session_import ~= state then return end
    self:_closeDialog()
    local buttons = {}
    if state.status == "complete" then
        buttons[#buttons + 1] = { { text = T("Open bookshelf"), callback = function()
            if self.session_import ~= state then return end
            self.session_import = nil
            self:showLibrary()
        end } }
    elseif state.source == "file" then
        buttons[#buttons + 1] = { { text = T("Choose another file"), callback = function()
            if self.session_import == state then self:_importSessionFile(state.directory) end
        end } }
    else
        buttons[#buttons + 1] = { { text = T("Paste web session"), callback = function()
            if self.session_import == state then self:_importSession() end
        end } }
    end
    buttons[#buttons + 1] = { { text = T("Close"), callback = function()
        if self.session_import == state then self.session_import = nil end
        self:_closeDialog()
        if self.route then self:_render() end
    end } }
    self:_showContextDialog(state.heading .. "\n\n" .. state.message, buttons)
end

function Screens:_beginSessionImport(content, source, directory)
    self:_closeDialog()
    local state = { account_key = accountKey(self.controller), generation = self.controller.generation,
        status = "validating", source = source, directory = directory }
    self.session_import = state
    local dialog
    dialog = W.menuDialog(T("Validating the selected session…"), {
        T("Validation continues in the background. A valid session will switch the active account. The result will be shown in Account."),
    }, { { { text = T("Continue in background"), callback = function()
            if self.dialog ~= dialog then return end
            self:_closeDialog()
            if self.route then self:_render() end
        end } } }, { placement = "center", width = self.width - W.dp(32),
        close_callback = function() self:_closeDialog() end })
    local owner, native_close = self, dialog.onCloseWidget
    function dialog:onCloseWidget()
        if native_close then native_close(self) end
        if owner.dialog == self then owner.dialog = nil end
    end
    state.dialog = dialog
    self.dialog = dialog
    UIManager:show(dialog)
    local function completed(result, err)
        if self.session_import ~= state or state.status ~= "validating" or self.controller.closed then return end
        local current = accountKey(self.controller)
        if result then
            if result.account_key ~= current then self.session_import = nil; return end
            state.status, state.account_key = "complete", current
            state.heading, state.message = T("Session imported"), T("The selected session was validated and saved.")
            self.loaded = {}
        else
            if current ~= state.account_key or self.controller.generation ~= state.generation then
                self.session_import = nil; return
            end
            state.status = "failed"
            state.heading, state.message = Model.error(err or { kind = "internal" })
        end
        local foreground = self.dialog == state.dialog
        state.dialog = nil
        if foreground then self:_closeDialog() end
        if self.route and not self.dialog then self:_render() end
        if foreground then
            self:_sessionImportResult(state)
        else
            UIManager:show(InfoMessage:new{ text = state.status == "complete"
                and T("Session imported. View the result in Account.")
                or T("Session import failed. View the result in Account."), timeout = 6 })
        end
    end
    local ok = pcall(function() self.controller:importSession(content, completed) end)
    state.import_sequence = self.controller.import_sequence
    content = nil
    if not ok then completed(nil, { kind = "internal" }) end
end

function Screens:_sessionFileCurrent(state, result)
    local current = accountKey(self.controller)
    return self.session_input == state and self.route ~= nil and self.epoch == state.epoch
        and ((current == state.account_key and self.controller.generation == state.generation)
            or (result and result.account_key == current))
end

function Screens:_sessionFileError(err, directory)
    self:_closeDialog()
    local messages = {
        size = T("Choose a session text file no larger than 128 KiB."),
        regular_file = T("Choose a regular file. Folders and symbolic links cannot be imported."),
        format = T("Choose a nonempty .txt, .json or .cookies session file."),
        read = T("The selected session file could not be read. Check its location and permissions."),
    }
    self.dialog = W.menuDialog(T("Session could not be imported"), { messages[err and err.code] or messages.read }, {
            { { text = T("Choose another file"), callback = function() self:_importSessionFile(directory) end } },
            { { text = T("Close"), callback = function() self:_closeDialog() end } },
        }, { placement = "center", width = self.width - W.dp(32), close_callback = function() self:_closeDialog() end })
    UIManager:show(self.dialog)
end

function Screens:_importSessionFile(directory)
    self:_closeDialog()
    local host = self.controller.host_ui or require("apps/reader/readerui").instance
        or require("apps/filemanager/filemanager").instance
    if not host or not host.folder_shortcuts then self:_sessionFileError({ code = "read" }); return end
    local state = { epoch = self.epoch, account_key = accountKey(self.controller), generation = self.controller.generation }
    self.session_input = state
    local chooser
    chooser = FileChooser:new{
        ui = host,
        title = T("Session file (up to 128 KiB)"), path = directory or require("apps/filemanager/filemanagerutil").getHomeFolder(),
        modal = true, show_unsupported = false, file_filter = SessionInput.accepts,
        show_file = function(_chooser, filename) return SessionInput.accepts(filename) end,
        onFileSelect = function(_chooser, item)
            if not self:_sessionFileCurrent(state) or state.selected then return end
            state.selected = true
            local selected_path = item.path
            local selected_directory = selected_path:match("^(.*)/[^/]+$")
            UIManager:close(chooser)
            if self.dialog == chooser then self.dialog = nil end
            -- The native picker must finish closing before the import status is shown.
            UIManager:nextTick(function()
                if not self:_sessionFileCurrent(state) then return end
                local content, err = SessionInput.read(selected_path)
                if not content then self:_sessionFileError(err, selected_directory); return end
                self:_beginSessionImport(content, "file", selected_directory)
            end)
        end,
        onCloseWidget = function(widget)
            FileChooser.onCloseWidget(widget)
            if self.session_input == state and not state.selected then self.session_input = nil end
            if self.dialog == widget then self.dialog = nil end
        end,
        close_callback = function()
            if self.session_input == state and not state.selected then self.session_input = nil end
            if self.dialog == chooser then self.dialog = nil end
        end,
    }
    self.dialog = chooser; UIManager:show(chooser)
end

function Screens:_signInWithQR()
    self:_closeDialog()
    self.session_import = nil
    local state = { epoch = self.epoch, account_key = accountKey(self.controller), generation = self.controller.generation }
    local login
    login = QRLogin.new{ controller = self.controller,
        is_current = function(confirmed)
            return self.qr_login == login and self.route ~= nil and self.epoch == state.epoch
                and (confirmed or (accountKey(self.controller) == state.account_key and self.controller.generation == state.generation))
        end,
        on_dialog = function(dialog) self.dialog = dialog end,
        on_close = function(dialog)
            if self.dialog == dialog then self.dialog = nil end
            if self.qr_login == login then self.qr_login = nil end
        end,
        on_confirmed = function()
            self.loaded = {}
            self:showAccount()
        end,
        on_other_methods = function() self:_otherSignInMethods() end,
    }
    self.qr_login = login
    login:start()
end

function Screens:_account()
    local account, wallet = self.controller:getAccount() or {}, self.controller:getWallet() or {}
    local signed_in = account.session_valid == true or (account.session_valid ~= false and account.id ~= nil)
    local prefetch = self.controller:getSetting("prefetch_pages", 3)
    local concurrency = self.controller:getSetting("download_concurrency", 2)
    local renewing = account.auth_state == "checking" or account.auth_state == "refreshing"
        or account.auth_state == "pending_confirmation"
    local attention = account.auth_state == "reauth_required" or account.auth_state == "error"
    local status = account.auth_state == "reauth_required" and T("Sign in again to restore your account.")
        or renewing and T("Checking or renewing your sign-in…")
        or account.auth_state == "error" and T("Automatic renewal is unavailable. Sign in again with QR code.")
        or account.renewable and T("Automatic sign-in renewal is enabled.")
        or signed_in and T("Imported session: use QR sign-in to enable automatic renewal.")
        or T("Sign in to sync your bookshelf, read purchased chapters, and use your manga coins. QR sign-in renews automatically.")
    local recharge_supported = account.recharge_supported == true and self._openRecharge ~= nil
    local recharge_orders = recharge_supported and self:_rechargeOrdersSnapshot() or {}
    local width, rows, focus_start = self.width, { space(32) }, #self.focus
    local function setting(label, value, callback)
        rows[#rows + 1] = W.rule1dp(width, BB.Color8(0xCC))
        local row = SettingsRow:new{ width = width, label = label, value = value, callback = callback }
        rows[#rows + 1] = row
        row.account_focus = { row }
        self.focus[#self.focus + 1] = { row }
    end
    local function group(label)
        local heading = W.column{ space(26), W.text(label, width, face(18), { bold = true, muted = true }), space(10) }
        heading.account_group_heading = true
        rows[#rows + 1] = heading
    end
    if signed_in then
        local tag_width, gap = W.dp(104), W.dp(16)
        local name = account.name or T("Signed in")
        local name_width = math.min(width - tag_width - gap, singleText(name, 36, { bold = true }):getSize().w)
        rows[#rows + 1] = W.row{
            W.text(name, name_width, face(36), { bold = true, height = W.dp(48), fixed_height = true }),
            W.gap(gap), box(W.text(account.renewable and T("QR sign-in") or T("Imported session"), tag_width - W.dp(12), face(15),
                { align = "center" }), tag_width, W.dp(32), W.dp(1.5)),
        }
        rows[#rows + 1] = space(10)
        rows[#rows + 1] = W.text((account.id and ("UID " .. tostring(account.id) .. " · ") or "") .. status,
            width, face(17), { muted = not attention, bold = attention, height = W.dp(26), fixed_height = true })
        rows[#rows + 1] = space(20)
        local balance_row = W.row{
            singleText(wallet.remain_gold or "—", 48, { bold = true }), W.gap(W.dp(10)),
            singleText(T("Manga coins"), 19), W.gap(W.dp(48)),
            singleText(wallet.remain_coupon or "—", 48, { bold = true }), W.gap(W.dp(10)),
            singleText(T("Reading coupons"), 19),
        }
        rows[#rows + 1] = balance_row
        local updated = timestamp(wallet.updated_at)
        rows[#rows + 1] = W.text(wallet.stale and T("Balance may be outdated. Refresh before reviewing a purchase.")
            or updated and string.format(T("Balance updated at %s"), updated) or T("Balance has not been refreshed."),
            width, face(16), { muted = true, height = W.dp(28), fixed_height = true })
        rows[#rows + 1] = space(14)
        local actions, action_focus = {}, {}
        local function append_action(widget)
            if #actions > 0 then actions[#actions + 1] = W.gap(W.dp(16)) end
            actions[#actions + 1], action_focus[#action_focus + 1] = widget, widget
        end
        if recharge_supported then
            append_action(W.button(T("Recharge manga coins"), W.dp(220), function() self:_openRecharge() end,
                { primary = true, enabled = not renewing, size = face(22), height_px = W.dp(62) }))
        end
        append_action(W.button(T("Refresh balance"), W.dp(180), function()
            self:_invoke("refreshWallet", {}, function(_value, error) if error then self:_error(error) end end)
        end, { enabled = not renewing, size = face(21), height_px = W.dp(62) }))
        local switch_width = width - (#actions > 1 and W.dp(432) or W.dp(196))
        append_action(W.button(T("Switch account") .. " ›", switch_width, function() self:_signInWithQR() end,
            { borderless = true, size = face(19), align = "right", height_px = W.dp(62) }))
        local action_row = W.row(actions)
        action_row.account_focus = action_focus
        rows[#rows + 1] = action_row
        self.focus[#self.focus + 1] = action_focus
    else
        rows[#rows + 1] = W.text(T("Not signed in"), width, face(36), { bold = true })
        rows[#rows + 1] = space(14)
        rows[#rows + 1] = W.text(status, width, face(20), { muted = not attention, bold = attention, line_height = 1.6 })
        rows[#rows + 1] = space(24)
        local login = W.button(T("Sign in with QR code"), W.dp(260), function() self:_signInWithQR() end,
            { primary = true, size = face(22), height_px = W.dp(66) })
        local alternate = W.button(T("Other sign-in methods"), W.dp(240), function() self:_otherSignInMethods() end,
            { size = face(21), height_px = W.dp(66) })
        local action_row = W.row{ login, W.gap(W.dp(16)), alternate }
        action_row.account_focus = { login, alternate }
        rows[#rows + 1] = action_row
        self.focus[#self.focus + 1] = { login, alternate }
    end
    rows[#rows + 1] = space(26)
    rows[#rows + 1] = W.rule1dp(width, BB.Color8(0x11))
    local import = self.session_import
    if import and import.status == "validating" and import.import_sequence
        and import.import_sequence ~= self.controller.import_sequence then self.session_import, import = nil, nil end
    if import and (import.account_key == accountKey(self.controller) or import.status == "validating") then
        setting(import.status == "validating" and T("Session validation is running in the background") or T("View session import result"),
            "", function() if import.status ~= "validating" then self:_sessionImportResult(import) end end)
    end
    group(T("Reading and cache"))
    setting(T("Defaults for new chapters"), modeLabel(self.controller:getSetting("reading_mode", "auto")) .. " · "
        .. directionLabel(self.controller:getSetting("reading_direction", "ltr")), function() self:_readerDefaults() end)
    setting(T("Preload next images"), prefetch == 0 and T("No preloading") or string.format(T("%d images"), prefetch),
        function() self:_prefetchOptions() end)
    setting(T("Concurrent image downloads"), string.format(T("%d images"), concurrency), function() self:_imageConcurrency() end)
    local storage = self.controller:getStorageSummary() or {}
    setting(T("Storage and cache"), string.format(T("Used %s"), Model.bytes(storage.total_bytes or 0)), function() self:_storageSettings() end)
    rows[#rows + 1] = W.rule1dp(width, BB.Color8(0xCC))
    if signed_in then
        group(T("Purchases and recharge"))
        local pending = Model.pending(self.controller)
        setting(T("Purchases awaiting confirmation"), #pending == 0 and T("None") or string.format(T("%d pending"), #pending),
            function() if #pending > 0 then self:_pendingList(pending) end end)
        local unresolved = 0
        for _, order in ipairs(recharge_orders) do
            if order.persistence_pending or (order.state ~= "credited" and order.state ~= "expired" and order.state ~= "failed_not_submitted") then
                unresolved = unresolved + 1
            end
        end
        if recharge_supported then
            setting(T("Recharge orders"), unresolved > 0 and string.format(T("%d orders awaiting check"), unresolved)
                or string.format(T("%d orders"), #recharge_orders), function() self:_showRechargeOrders() end)
        end
        rows[#rows + 1] = W.rule1dp(width, BB.Color8(0xCC))
    end
    group(T("Help and diagnostics"))
    setting(T("Bookshelf help"), "—", function() self:_bookshelfHelp() end)
    setting(T("Local diagnostics"), T("Device and plugin"), function() self:_diagnostics() end)
    rows[#rows + 1] = W.rule1dp(width, BB.Color8(0xCC))
    for index = #self.focus, focus_start + 1, -1 do self.focus[index] = nil end
    local function partition(reserve)
        local pages, page, used = {}, {}, 0
        for index, row in ipairs(rows) do
            local height = row:getSize().h
            local keep = row.account_group_heading and W.dp(67) or 0
            if #page > 0 and used + height + keep > self.body_height - reserve then
                pages[#pages + 1], page, used = page, {}, 0
            end
            page[#page + 1], used = row, used + height
        end
        if #page > 0 then pages[#pages + 1] = page end
        return pages
    end
    local pages = partition(0)
    if #pages > 1 then pages = partition(W.dp(68)) end
    self.pages = math.max(1, #pages)
    self.page = math.max(1, math.min(self.page or 1, self.pages))
    local visible = {}
    for _, row in ipairs(pages[self.page] or {}) do
        visible[#visible + 1] = row
        if row.account_focus then self.focus[#self.focus + 1] = row.account_focus end
    end
    if self.pages > 1 then
        local cell_width = math.floor(width / 3)
        local previous = W.button("‹ " .. T("Previous"), cell_width, function() self:_changePage(-1) end,
            { borderless = true, align = "left", enabled = self.page > 1, size = face(20), height_px = W.dp(60) })
        local counter = W.button(string.format("%d / %d", self.page, self.pages), width - cell_width * 2,
            function() self:_jumpPage() end, { borderless = true, size = face(20), height_px = W.dp(60) })
        local next_page = W.button(T("Next") .. " ›", cell_width, function() self:_changePage(1) end,
            { borderless = true, align = "right", enabled = self.page < self.pages, size = face(20), height_px = W.dp(60) })
        visible[#visible + 1], visible[#visible + 2] = space(8), W.row{ previous, counter, next_page }
        self.focus[#self.focus + 1] = { previous, counter, next_page }
        self.pagination = { previous = previous, counter = counter, next = next_page }
    end
    return W.column(visible)
end
function Screens:_saveAccountSetting(key, value)
    local ok, saved, err = pcall(self.controller.setSetting, self.controller, key, value)
    if not ok then err = { kind = "storage" } end
    if not ok or (saved == nil and err) then self:_error(err); return false end
    self.context_dialog_dirty = true
    return true
end

function Screens:_prefetchOptions()
    self:_readerDefaults()
end
function Screens:_showStorageSettings()
    self:showAccount()
    self:_storageSettings()
end

function Screens:_showAccountFlow(title, body, layout, buttons, options)
    options = options or {}
    local dirty = self.context_dialog_dirty
    self:_closeDialog()
    local owner, epoch, key = self, self.epoch, accountKey(self.controller)
    options.body, options.layout = body, layout
    options.body_padding_px = options.body_padding_px or 0
    options.close_callback = function() owner:_closeDialog() end
    options.on_page = function(page)
        options.page = page
        if options.rebuild then options.rebuild(page)
        else owner:_showAccountFlow(title, body, layout, buttons, options) end
    end
    local dialog = W.flowDialog(title, {}, buttons or { { { text = T("Close"), callback = options.close_callback } } }, options)
    local native_close = dialog.onCloseWidget
    function dialog:onCloseWidget()
        if native_close then native_close(self) end
        if owner.context_dialog ~= self then return end
        local repaint = owner.context_dialog_dirty
        owner.context_dialog, owner.context_dialog_dirty, owner.context_dialog_account = nil, nil, nil
        if owner.dialog == self then owner.dialog = nil end
        if repaint and owner.epoch == epoch and accountKey(owner.controller) == key and owner.route then owner:_render() end
    end
    self.dialog, self.context_dialog = dialog, dialog
    self.context_dialog_dirty, self.context_dialog_account = dirty, key
    UIManager:show(dialog)
    return dialog
end

function Screens:_accountSegments(entries, selected, width, callback, layout, height)
    local border, items, focus = W.dp(1.5), {}, {}
    local inner = width - border * (#entries + 1)
    for index, entry in ipairs(entries) do
        if index > 1 then
            items[#items + 1] = box(space(0), border, W.dp(height or 64), 0, BB.Color8(0x11))
        end
        local cell_width = math.floor(inner * index / #entries) - math.floor(inner * (index - 1) / #entries)
        local button = W.button(entry.text, cell_width, function() callback(entry.value) end,
            { primary = entry.value == selected, bold = entry.value == selected, borderless = true,
                size = face(20), height_px = W.dp(height or 64) - border * 2 })
        items[#items + 1], focus[#focus + 1] = button, button
    end
    layout[#layout + 1] = focus
    return box(W.row(items), width, W.dp(height or 64), border)
end

function Screens:_storageSettings(page)
    local storage = self.controller:getStorageSummary() or {}
    local automatic = storage.automatic_bytes or storage.cache_bytes or 0
    local downloaded = storage.pinned_bytes or storage.retained_bytes or 0
    local total = storage.total_bytes or automatic + downloaded
    local free = storage.free_bytes or storage.available_bytes
    local limit = self.controller:getSetting("cache_limit_mb", 512)
    local width, rows, layout = self.width, { space(38) }, {}
    local dialog, key = nil, accountKey(self.controller)
    rows[#rows + 1] = W.text(Model.bytes(total), width, face(52), { bold = true })
    rows[#rows + 1] = space(12)
    rows[#rows + 1] = W.text(string.format(T("Plugin storage · Device free %s"), free and Model.bytes(free) or T("Unknown")), width, face(18), { muted = true })
    rows[#rows + 1] = space(24)
    local stroke, capacity = W.dp(1), math.max(1, total + (free or 0))
    local bar_width = width - stroke * 2
    local manual_width = math.floor(bar_width * downloaded / capacity)
    local automatic_width = math.floor(bar_width * automatic / capacity)
    rows[#rows + 1] = FrameContainer:new{ padding = 0, margin = 0, bordersize = stroke, radius = 0,
        color = BB.Color8(0x11), W.row{
            box(space(0), manual_width, W.dp(18) - stroke * 2, 0, BB.Color8(0x11)),
            box(space(0), automatic_width, W.dp(18) - stroke * 2, 0, BB.Color8(0x99)),
            box(space(0), math.max(0, bar_width - manual_width - automatic_width), W.dp(18) - stroke * 2),
        } }
    rows[#rows + 1] = space(24)
    local function legend(label, description, value, shade)
        local swatch = box(space(0), W.dp(22), W.dp(22), shade and 0 or W.dp(1.5), shade and BB.Color8(shade) or W.paper)
        rows[#rows + 1] = box(W.row{
            swatch, W.gap(W.dp(18)),
            W.column{ W.text(label, width - W.dp(210), face(21)), space(5),
                W.text(description or "", width - W.dp(210), face(16), { muted = true }) },
            W.text(value, W.dp(170), face(21), { bold = true, align = "right" }),
        }, width, W.dp(80))
    end
    legend(T("Manual downloads"), T("Kept until you remove them"), Model.bytes(downloaded), 0x11)
    legend(T("Automatic cache"), T("Online images saved automatically; older images are cleared at the limit"), Model.bytes(automatic), 0x99)
    legend(T("Device free"), "", free and Model.bytes(free) or T("Unknown"))
    rows[#rows + 1] = space(28)
    rows[#rows + 1] = W.row{
        W.text(T("Automatic cache limit"), math.floor(width * 0.48), face(22), { bold = true }),
        W.text(string.format(T("Used %s / %s"), Model.bytes(automatic), Model.bytes(limit * 1024 * 1024)),
            width - math.floor(width * 0.48), face(18), { muted = true, align = "right" }),
    }
    rows[#rows + 1] = space(16)
    rows[#rows + 1] = self:_accountSegments({
        { text = "256 MB", value = 256 }, { text = "512 MB", value = 512 },
        { text = "1 GB", value = 1024 }, { text = "2 GB", value = 2048 },
    }, limit, width, function(value)
        if self.dialog ~= dialog or accountKey(self.controller) ~= key or value == limit then return end
        local function save()
            if accountKey(self.controller) ~= key then return end
            if self:_saveAccountSetting("cache_limit_mb", value) then self:_storageSettings() end
        end
        if value < limit then
            self:_closeDialog()
            local confirmation
            local function cancel()
                self:_closeDialog()
                if accountKey(self.controller) == key then self:_storageSettings() end
            end
            confirmation = self:_showContextDialog(T("Automatic cache limit") .. "\n\n"
                .. string.format(T("Reduce automatic cache to %d MiB? Older automatic images above this limit will be removed now. Downloads and current reading content are preserved."), value), { {
                { text = T("Cancel"), callback = function() if self.dialog == confirmation then cancel() end end },
                { text = T("Apply cache limit"), primary = true, callback = function()
                    if self.dialog ~= confirmation or accountKey(self.controller) ~= key then return end
                    self:_closeDialog()
                    save()
                end },
            } }, nil, { placement = "center", width = self.width - W.dp(32), selected = { x = 1, y = 1 }, close_callback = cancel })
        else save() end
    end, layout, 66)
    rows[#rows + 1] = space(16)
    rows[#rows + 1] = W.text(T("Increasing the limit applies immediately. Decreasing asks before clearing older cache. Downloads and current reading content are preserved."),
        width, face(18), { muted = true, line_height = 1.6 })
    rows[#rows + 1] = space(30)
    rows[#rows + 1] = W.text(T("Cleanup"), width, face(22), { bold = true })
    rows[#rows + 1] = space(16)
    local clear = W.button(string.format(T("Clear unused automatic cache · %s"), Model.bytes(automatic)), width,
        function() if self.dialog == dialog then self:_clearAutomaticCache() end end, { size = face(21), height_px = W.dp(66) })
    local manage = W.button(T("Manage manual downloads") .. " ›", width,
        function() if self.dialog == dialog then self:showDownloads() end end, { size = face(21), height_px = W.dp(66) })
    rows[#rows + 1], rows[#rows + 2], rows[#rows + 3] = clear, space(14), manage
    layout[#layout + 1], layout[#layout + 2] = { clear }, { manage }
    dialog = self:_showAccountFlow(T("Storage and cache"), W.column(rows), layout, nil,
        { page = page, rebuild = function(next_page) self:_storageSettings(next_page) end })
end

function Screens:_cacheLimitOptions()
    self:_storageSettings()
end
function Screens:_clearAutomaticCache()
    self:_closeDialog()
    local key = accountKey(self.controller)
    local confirmation
    local function clear()
            if self.dialog ~= confirmation or accountKey(self.controller) ~= key then return end
            local result, err = self.controller:clearAutomaticCache()
            if err then self:_error(err); return end
            result = type(result) == "table" and result or {}
            local freed = result.freed_bytes or 0
            local message = freed > 0 and string.format(T("Freed %s of automatic cache."), Model.bytes(freed))
                or T("There is no unused automatic cache to clear.")
            if (result.remaining_bytes or 0) > 0 then
                message = message .. "\n\n" .. string.format(T("Kept %s for current reading or protected content."), Model.bytes(result.remaining_bytes))
            end
            self:_closeDialog()
            self:_render()
            local dialog
            dialog = self:_showContextDialog(T("Cache cleanup complete") .. "\n\n" .. message .. "\n\n"
                .. T("Downloaded chapters are preserved."), {
                { { text = T("Back to storage"), callback = function() if self.dialog == dialog then self:_storageSettings() end end } },
                { { text = T("Close"), callback = function() if self.dialog == dialog then dialog:onClose() end end } },
            })
    end
    confirmation = self:_showContextDialog(T("Storage and cache") .. "\n\n"
        .. T("Clear automatic cache? Explicit downloads and current reading content are preserved."), { {
        { text = T("Cancel"), callback = function() if self.dialog == confirmation then self:_closeDialog() end end },
        { text = T("Clear cache"), primary = true, callback = clear },
    } }, nil, { placement = "center", width = self.width - W.dp(32), selected = { x = 1, y = 1 },
        close_callback = function() self:_closeDialog() end })
end

function Screens:_imageConcurrency()
    self:_readerDefaults()
end

function Screens:_readerDefaults(page)
    local mode = self.controller:getSetting("reading_mode", "auto")
    local direction = self.controller:getSetting("reading_direction", "ltr")
    local prefetch = self.controller:getSetting("prefetch_pages", 3)
    local concurrency = self.controller:getSetting("download_concurrency", 2)
    local width, rows, layout = self.width, { space(30) }, {}
    local dialog, key = nil, accountKey(self.controller)
    local function choose(setting, value)
        if self.dialog ~= dialog or accountKey(self.controller) ~= key then return end
        if self:_saveAccountSetting(setting, value) then self:_readerDefaults() end
    end
    rows[#rows + 1] = W.text(T("These defaults apply to new chapters. Saved chapter settings and reading positions are preserved.")
        .. " " .. T("To change the chapter you are reading, use its reading menu. Your selection here is saved immediately."),
        width, face(19), { muted = true, line_height = 1.6 })
    rows[#rows + 1] = space(24)
    rows[#rows + 1] = W.rule1dp(width, BB.Color8(0x11))
    rows[#rows + 1] = space(28)
    rows[#rows + 1] = W.text(T("Reading mode"), width, face(22), { bold = true })
    rows[#rows + 1] = space(16)
    local card_width, cards, card_focus = math.floor((width - W.dp(32)) / 3), {}, {}
    local mode_entries = {
        { value = "auto", label = T("Automatic"), hint = T("Choose by image proportions") },
        { value = "page", label = T("Page comic"), hint = T("One page fits the screen; turn pages to read") },
        { value = "strip", label = T("Long strip"), hint = T("Fit width; read continuously") },
    }
    for index, entry in ipairs(mode_entries) do
        if index > 1 then cards[#cards + 1] = W.gap(W.dp(16)) end
        local diagram
        if entry.value == "auto" then
            diagram = W.row{ box(space(0), W.dp(44), W.dp(60), W.dp(2)),
                W.gap(W.dp(12)), box(space(0), W.dp(26), W.dp(84), W.dp(2)) }
        elseif entry.value == "page" then diagram = box(space(0), W.dp(62), W.dp(84), W.dp(2))
        else diagram = box(space(0), W.dp(34), W.dp(96), W.dp(2)) end
        local selected = mode == entry.value
        local content = box(W.column{
            W.text(entry.label .. (selected and " ✓" or ""), card_width - W.dp(20), face(21),
                { align = "center", bold = selected }),
            space(16), CenterContainer:new{ dimen = Geom:new{ w = card_width - W.dp(20), h = W.dp(100) }, diagram },
            space(12), W.text(entry.hint, card_width - W.dp(22), face(15),
                { align = "center", muted = true, height = W.dp(38), fixed_height = true }),
        }, card_width, W.dp(204), W.dp(selected and 3 or 1.5))
        local card = ChoiceCard:new{ content = content, width = card_width, height = W.dp(204),
            callback = function() choose("reading_mode", entry.value) end }
        cards[#cards + 1], card_focus[#card_focus + 1] = card, card
    end
    rows[#rows + 1], layout[#layout + 1] = W.row(cards), card_focus
    local function section(title, entries, selected, setting, hint)
        rows[#rows + 1] = space(28)
        rows[#rows + 1] = W.text(title, width, face(22), { bold = true })
        rows[#rows + 1] = space(14)
        rows[#rows + 1] = self:_accountSegments(entries, selected, width,
            function(value) choose(setting, value) end, layout, 64)
        if hint then
            rows[#rows + 1] = space(10)
            rows[#rows + 1] = W.text(hint, width, face(17), { muted = true })
        end
    end
    section(T("Reading direction"), {
        { text = T("Left to right"), value = "ltr" }, { text = T("Right to left (manga)"), value = "rtl" },
    }, direction, "reading_direction")
    section(T("Preload next images"), {
        { text = T("No preloading"), value = 0 }, { text = string.format(T("%d images"), 1), value = 1 },
        { text = string.format(T("%d images"), 3), value = 3 }, { text = string.format(T("%d images"), 5), value = 5 },
    }, prefetch, "prefetch_pages", T("More images use more data and automatic cache."))
    local concurrent_entries = {}
    for value = 1, 4 do concurrent_entries[#concurrent_entries + 1] = { text = string.format(T("%d images"), value), value = value } end
    section(T("Concurrent image downloads"), concurrent_entries, concurrency, "download_concurrency", T("Applies to online cache and downloads."))
    dialog = self:_showAccountFlow(T("Defaults for new chapters"), W.column(rows), layout, nil,
        { page = page, rebuild = function(next_page) self:_readerDefaults(next_page) end })
end
function Screens:_diagnostics()
    self:_closeDialog()
    local epoch = self.epoch
    local loading = W.flowDialog(T("Local diagnostics"), { T("Checking local capabilities…") }, {
        { { text = T("Close"), callback = function() self:_closeDialog() end } },
    }, { close_callback = function() self:_closeDialog() end })
    self.dialog = loading; UIManager:show(loading)
    self.controller:getDiagnostics(function(snapshot, error)
        if self.epoch ~= epoch or self.dialog ~= loading or not UIManager:isWidgetShown(loading) then return end
        self:_closeDialog()
        if error then self:_error(error); return end
        local session_labels = { stored = T("Saved; server validity was not checked"), invalid = T("Marked invalid; import a new session"), missing = T("No usable local session") }
        local platform = snapshot.platform or {}
        local function known(value) return value and value ~= "unknown" and value or T("Unknown") end
        local lines = {
            string.format(T("Plugin version: %s"), known(snapshot.plugin_version)),
            string.format(T("KOReader version: %s"), known(snapshot.koreader_version)),
            string.format(T("Platform: %s / %s / %s"), known(platform.os), known(platform.arch), known(platform.target)),
            "", string.format(T("Local session: %s"), session_labels[snapshot.local_session] or session_labels.missing),
            string.format(T("Credential storage: %s"), snapshot.credential_storage == "app_private" and T("App-private directory") or T("Account directory")),
            "", T("Local capabilities"),
        }
        for _index, item in ipairs({ { "request_signing", T("Request signing") }, { "response_decoding", T("Response decoding") },
            { "image_index", T("Chapter image index") }, { "image_tokens", T("Image access adapter") },
            { "encrypted_images", T("Image conversion") }, { "purchase", T("Purchase adapter") } }) do
            local value = (snapshot.capabilities or {})[item[1]]
            local state = value == true and T("Locally available") or value == false and T("Locally unavailable") or T("Not checked")
            lines[#lines + 1] = item[2] .. ": " .. state
        end
        lines[#lines + 1], lines[#lines + 2] = "", T("These local checks do not verify the Bilibili service, account access, image retrieval or purchases.")
        local body_rows = {}
        for _, line in ipairs(lines) do
            body_rows[#body_rows + 1] = { widget = line == "" and space(16)
                or W.column{ W.text(line, self.width, face(18), { line_height = 1.6 }), space(10) } }
        end
        self:_showAccountFlow(T("Local diagnostics"), nil, nil, nil,
            { body_rows = body_rows, body_padding_px = W.dp(28) })
    end)
end


end
