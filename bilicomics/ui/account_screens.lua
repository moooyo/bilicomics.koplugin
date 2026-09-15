local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local FileChooser = require("ui/widget/filechooser")
local SessionInput = require("bilicomics/ui/session_input")
local QRLogin = require("bilicomics/ui/qr_login")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local W = require("bilicomics/ui/widgets")
local Model = require("bilicomics/ui/model")
local Helpers = require("bilicomics/ui/screen_helpers")
local T = require("bilicomics/ui/i18n")
local accountKey = Helpers.accountKey
local font = W.font or { page = 24, title = 21, item = 18, body = 18, status = 15, meta = 14, micro = 13 }

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
    dialog = ButtonDialog:new{ title = T("Validating the selected session…") .. "\n\n"
        .. T("Validation continues in the background. A valid session will switch the active account. The result will be shown in Account."),
        buttons = { { { text = T("Continue in background"), callback = function()
            if self.dialog ~= dialog then return end
            self:_closeDialog()
            if self.route then self:_render() end
        end } } }, modal = true,
        onCloseWidget = function(widget)
            ButtonDialog.onCloseWidget(widget)
            if self.dialog == widget then self.dialog = nil end
        end }
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
    self.dialog = ButtonDialog:new{ title = T("Session could not be imported") .. "\n\n" .. (messages[err and err.code] or messages.read),
        buttons = {
            { { text = T("Choose another file"), callback = function() self:_importSessionFile(directory) end } },
            { { text = T("Close"), callback = function() self:_closeDialog() end } },
        }, modal = true }
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
        or T("Scan a code to sign in and enable automatic renewal.")
    local recharge_supported = account.recharge_supported == true and self._openRecharge ~= nil
    local recharge_orders = recharge_supported and self:_rechargeOrdersSnapshot() or {}
    local balance_text = string.format(T("Coins: %s · Coupons: %s"), tostring(wallet.remain_gold or "—"), tostring(wallet.remain_coupon or "—"))
    local balance
    if recharge_supported then
        local recharge_width, gap = W.scale(108), W.scale(8)
        balance = W.row{
            W.text(balance_text, self.width - recharge_width - gap, font.item), W.gap(gap),
            self:_button(T("Recharge"), recharge_width, function() self:_openRecharge() end,
                { enabled = signed_in and not renewing, size = font.status }),
        }
    else balance = W.text(balance_text, self.width, font.item) end
    local function sign_in_methods()
        if recharge_supported and #recharge_orders > 0 then
            return self:_buttons{
                { text = T("Other sign-in methods"), size = font.meta, callback = function() self:_otherSignInMethods() end },
                { text = string.format(T("Recharge orders (%d)"), #recharge_orders), size = font.meta, callback = function() self:_showRechargeOrders() end },
            }
        end
        return self:_button(T("Other sign-in methods"), self.width, function() self:_otherSignInMethods() end)
    end
    local rows = {
        W.text(signed_in and (account.name or T("Signed in")) or T("Not signed in"), self.width, font.page,
            { display = true, bold = true }),
        W.space(4), balance, W.space(4),
        W.text(status, self.width, font.status, { bold = attention, muted = not attention and not renewing }), W.space(6),
        self:_buttons{
            { text = T("Sign in with QR code"), primary = true, callback = function() self:_signInWithQR() end },
            { text = T("Refresh balance"), enabled = signed_in and not renewing,
                callback = function() self:_invoke("refreshWallet", {}, function(_value, error)
                if error then self:_error(error) end
            end) end },
        }, W.space(4),
        sign_in_methods(),
    }
    if wallet.stale then
        rows[#rows + 1] = W.space(4)
        rows[#rows + 1] = W.text(T("Balance may be outdated. Refresh before reviewing a purchase."), self.width, font.status)
    end
    local import = self.session_import
    if import and import.status == "validating" and import.import_sequence
        and import.import_sequence ~= self.controller.import_sequence then
        self.session_import, import = nil, nil
    end
    if import and (import.account_key == accountKey(self.controller) or import.status == "validating") then
        rows[#rows + 1] = W.space(4)
        rows[#rows + 1] = self:_button(import.status == "validating" and T("Session validation is running in the background")
            or T("View session import result"), self.width, function()
                if import.status ~= "validating" then self:_sessionImportResult(import) end
            end, { enabled = import.status ~= "validating", size = font.status, bold = import.status == "failed" })
    end
    local pending = Model.pending(self.controller)
    if #pending > 0 then
        rows[#rows + 1] = W.space(6)
        rows[#rows + 1] = self:_button(string.format(T("Purchases awaiting confirmation: %d"), #pending), self.width,
            function() self:_pendingList(pending) end, { primary = true })
    end
    rows[#rows + 1] = W.space(10)
    rows[#rows + 1] = W.rule(self.width)
    rows[#rows + 1] = W.space(8)
    rows[#rows + 1] = W.text(T("Reading and cache"), self.width, font.title, { bold = true })
    rows[#rows + 1] = W.space(4)
    rows[#rows + 1] = self:_button(T("Defaults for new chapters"), self.width, function() self:_readerDefaults() end)
    rows[#rows + 1] = W.space(4)
    rows[#rows + 1] = self:_buttons{
        { text = string.format(T("Preload next images: %d"), prefetch), callback = function() self:_prefetchOptions() end,
            align = "left", size = font.status },
        { text = string.format(T("Concurrent images: %d"), concurrency), callback = function() self:_imageConcurrency() end,
            align = "left", size = font.status },
    }
    rows[#rows + 1] = W.space(4)
    rows[#rows + 1] = self:_button(T("Storage and cache"), self.width, function() self:_storageSettings() end)
    rows[#rows + 1] = W.space(10)
    rows[#rows + 1] = W.rule(self.width)
    rows[#rows + 1] = W.space(8)
    rows[#rows + 1] = W.text(T("Help and diagnostics"), self.width, font.title, { bold = true })
    rows[#rows + 1] = W.space(4)
    rows[#rows + 1] = self:_button(T("Local diagnostics"), self.width, function() self:_diagnostics() end)
    return W.column(rows)
end

function Screens:_saveAccountSetting(key, value)
    local ok, saved, err = pcall(self.controller.setSetting, self.controller, key, value)
    if not ok then err = { kind = "storage" } end
    if not ok or (saved == nil and err) then self:_error(err); return false end
    self.context_dialog_dirty = true
    return true
end

function Screens:_prefetchOptions()
    local selected = self.controller:getSetting("prefetch_pages", 3)
    local buttons, dialog, key = {}, nil, accountKey(self.controller)
    local values = { 0, 1, 3, 5 }
    for index, value in ipairs(values) do
        if index % 2 == 1 then buttons[#buttons + 1] = {} end
        local label = value == 0 and T("No preloading") or string.format(T("%d images"), value)
        local row = buttons[#buttons]
        row[#row + 1] = { text = (selected == value and "[x] " or "[ ] ") .. label, callback = function()
            if self.dialog ~= dialog or accountKey(self.controller) ~= key then return end
            if self:_saveAccountSetting("prefetch_pages", value) then self:_prefetchOptions() end
        end }
    end
    buttons[#buttons + 1] = { { text = T("Close"), callback = function() if self.dialog == dialog then dialog:onClose() end end } }
    dialog = self:_showContextDialog(T("Preload next images") .. "\n\n"
        .. T("Choose how many images to fetch ahead while reading online. More images use more data and automatic cache. The selected value is saved immediately."), buttons)
end

function Screens:_showStorageSettings()
    self:showAccount()
    self:_storageSettings()
end

function Screens:_storageSettings()
    local storage = self.controller:getStorageSummary() or {}
    local limit = self.controller:getSetting("cache_limit_mb", 512)
    local dialog
    dialog = self:_showContextDialog(T("Storage and cache") .. "\n\n"
        .. string.format(T("Automatic cache: %s · Downloads: %s"), Model.bytes(storage.automatic_bytes or storage.cache_bytes),
            Model.bytes(storage.pinned_bytes or storage.retained_bytes)) .. "\n\n"
        .. T("Automatic cache is managed by its limit. Downloaded chapters stay until you remove them."), {
        { { text = string.format(T("Automatic cache limit: %d MiB"), limit), callback = function()
            if self.dialog == dialog then self:_cacheLimitOptions() end
        end } },
        { { text = T("Clear automatic cache"), callback = function() if self.dialog == dialog then self:_clearAutomaticCache() end end } },
        { { text = T("Manage downloads"), callback = function() if self.dialog == dialog then self:showDownloads() end end } },
        { { text = T("Close"), callback = function() if self.dialog == dialog then dialog:onClose() end end } },
    })
end

function Screens:_cacheLimitOptions()
    local selected = self.controller:getSetting("cache_limit_mb", 512)
    local buttons, dialog, key = {}, nil, accountKey(self.controller)
    for index, value in ipairs({ 256, 512, 1024, 2048 }) do
        if index % 2 == 1 then buttons[#buttons + 1] = {} end
        local row = buttons[#buttons]
        row[#row + 1] = { text = (selected == value and "[x] " or "[ ] ") .. string.format(T("%d MiB"), value), callback = function()
            if self.dialog ~= dialog or accountKey(self.controller) ~= key or value == selected then return end
            local function save()
                if accountKey(self.controller) ~= key then return end
                if self:_saveAccountSetting("cache_limit_mb", value) then self:_cacheLimitOptions() end
            end
            if value < selected then
                self:_closeDialog()
                self.dialog = ConfirmBox:new{ text = string.format(T("Reduce automatic cache to %d MiB? Older automatic images above this limit will be removed now. Downloads and current reading content are preserved."), value),
                    ok_text = T("Apply cache limit"), cancel_text = T("Cancel"), ok_callback = save,
                    cancel_callback = function() if accountKey(self.controller) == key then self:_cacheLimitOptions() end end }
                UIManager:show(self.dialog)
            else save() end
        end }
    end
    buttons[#buttons + 1] = { { text = T("Back to storage"), callback = function() if self.dialog == dialog then self:_storageSettings() end end } }
    dialog = self:_showContextDialog(T("Automatic cache limit") .. "\n\n"
        .. T("Choose a limit for automatically loaded images. Downloads and current reading content are preserved. Larger values are saved immediately; smaller values ask before clearing older images."), buttons)
end

function Screens:_clearAutomaticCache()
    self:_closeDialog()
    local key = accountKey(self.controller)
    self.dialog = ConfirmBox:new{ text = T("Clear automatic cache? Explicit downloads and current reading content are preserved."),
        ok_text = T("Clear cache"), cancel_text = T("Cancel"), ok_callback = function()
            if accountKey(self.controller) ~= key then return end
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
        end }
    UIManager:show(self.dialog)
end

function Screens:_imageConcurrency()
    local selected = self.controller:getSetting("download_concurrency", 2)
    local buttons, row = {}, nil
    local dialog, key = nil, accountKey(self.controller)
    for value = 1, 4 do
        if value % 2 == 1 then row = {}; buttons[#buttons + 1] = row end
        row[#row + 1] = { text = (selected == value and "[x] " or "[ ] ") .. value, callback = function()
            if self.dialog ~= dialog or accountKey(self.controller) ~= key then return end
            if self:_saveAccountSetting("download_concurrency", value) then self:_imageConcurrency() end
        end }
    end
    buttons[#buttons + 1] = { { text = T("Close"), callback = function() if self.dialog == dialog then dialog:onClose() end end } }
    dialog = self:_showContextDialog(T("Concurrent image downloads") .. "\n\n"
        .. T("Applies to online cache and downloads. Images already downloading will finish.") .. "\n\n"
        .. T("Your selection is saved immediately."), buttons)
end

function Screens:_readerDefaults()
    local mode = self.controller:getSetting("reading_mode", "auto")
    local direction = self.controller:getSetting("reading_direction", "ltr")
    local dialog, account_key = nil, accountKey(self.controller)
    local function choose(key, value)
        if self.dialog ~= dialog or accountKey(self.controller) ~= account_key then return end
        if self:_saveAccountSetting(key, value) then self:_readerDefaults() end
    end
    local function label(message, selected) return (selected and "[x] " or "[ ] ") .. T(message) end
    dialog = self:_showContextDialog(T("Defaults for new chapters") .. "\n\n"
        .. T("These defaults apply to new chapters. Saved chapter settings and reading positions are preserved.") .. "\n\n"
        .. T("To change the chapter you are reading, use its reading menu. Your selection here is saved immediately."), {
        { { text = label("Automatic", mode == "auto"), callback = function() choose("reading_mode", "auto") end },
          { text = label("Page comic", mode == "page"), callback = function() choose("reading_mode", "page") end },
          { text = label("Long strip", mode == "strip"), callback = function() choose("reading_mode", "strip") end } },
        { { text = label("Left to right", direction == "ltr"), callback = function() choose("reading_direction", "ltr") end },
          { text = label("Right to left", direction == "rtl"), callback = function() choose("reading_direction", "rtl") end } },
        { { text = T("Close"), callback = function() if self.dialog == dialog then dialog:onClose() end end } },
    })
end

function Screens:_diagnostics()
    self:_closeDialog()
    local epoch = self.epoch
    local loading = ButtonDialog:new{ modal = true, title = T("Checking local capabilities…"), buttons = {
        { { text = T("Close"), callback = function() self:_closeDialog() end } },
    } }
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
        self.dialog = TextViewer:new{ title = T("Local diagnostics"), text = table.concat(lines, "\n"), modal = true }
        UIManager:show(self.dialog)
    end)
end


end
