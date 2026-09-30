local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local InputDialog = require("ui/widget/inputdialog")
local FileChooser = require("ui/widget/filechooser")
local SessionInput = require("bilicomics/ui/session_input")
local QRLogin = require("bilicomics/ui/qr_login")
local UIManager = require("ui/uimanager")
local W = require("bilicomics/ui/widgets")
local Model = require("bilicomics/ui/model")
local T = require("bilicomics/ui/i18n")
local Screens = {}
Screens.__index = Screens

local function text(value, width, size, options) return W.text(value, width, W.fontSize(size), options) end
local function space(value) return W.spacePixels(W.dp(value)) end
local function buttonOptions(options)
    options = options or {}
    options.height_px = W.dp(options.height_dp or 64)
    options.size = W.fontSize(options.size_dp or 21)
    return options
end
local function textPages(value, width, size, max_height, line_height)
    local chars, pages = {}, {}
    for char in tostring(value or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = char end
    local first = 1
    while first <= #chars do
        local low, high, last = first, math.min(#chars, first + 299), first
        while low <= high do
            local middle = math.floor((low + high) / 2)
            local probe = text(table.concat(chars, "", first, middle), width, size, { line_height = line_height })
            local fits = probe:getSize().h <= max_height
            if probe.free then probe:free() end
            if fits then last, low = middle, middle + 1 else high = middle - 1 end
        end
        pages[#pages + 1], first = table.concat(chars, "", first, last), last + 1
    end
    return #pages > 0 and pages or { "" }
end

local function title(record) return record.title or record.short_title or tostring(record.id or "") end
local SearchInputDialog = InputDialog:extend{}
function SearchInputDialog:init()
    InputDialog.init(self)
    local inner = self.width - W.dp(64)
    local native_title = self.title_bar
    self.title_bar = W.line(self.title, inner, W.fontSize(24), { bold = true, height = W.dp(32) })
    self._input_widget.bordersize, self._input_widget._frame_textwidget.bordersize = 0, 0
    local field = W.box(W.inset(self._input_widget, W.dp(22), W.dp(22), 0, 0), inner, W.dp(70),
        { border_px = W.dp(1.5), align = "left" })
    local buttons, focus = {}, {}
    for index, entry in ipairs(self.buttons[1]) do
        if index > 1 then buttons[#buttons + 1] = W.gap(W.dp(16)) end
        local button = W.button(entry.text, math.floor((inner - W.dp(16)) / 2), entry.callback,
            { height_px = W.dp(64), size = W.fontSize(21), primary = index == 2 })
        buttons[#buttons + 1], focus[#focus + 1] = button, button
    end
    self.vgroup = W.inset(W.column{ self.title_bar, space(18), field, space(20), W.row(buttons) },
        W.dp(32), W.dp(32), W.dp(28), W.dp(30))
    self.dialog_frame[1], self.dialog_frame.radius, self.dialog_frame.color = self.vgroup, 0, W.ink
    self[1], self.layout = self.dialog_frame, { { self._input_widget }, focus }
    native_title:free()
end
function SearchInputDialog:paintTo(bb, _x, _y)
    local size = self.dialog_frame:getSize()
    local keyboard = self:isKeyboardVisible() and self._input_widget:getKeyboardDimen().h or 0
    self.dialog_frame:paintTo(bb, math.floor((Device.screen:getWidth() - size.w) / 2),
        math.max(0, math.min(W.dp(160), Device.screen:getHeight() - keyboard - size.h)))
end
local function count(map) local total = 0; for _ in pairs(map) do total = total + 1 end; return total end
local function asset(method) return method == "coupon" and T("coupons") or T("coins") end
local function copy(items) local result = {}; for _index, item in ipairs(items) do result[#result + 1] = item end; return result end
local function accountKey(controller)
    local account = controller:getAccount() or {}
    return account.account_key or account.id
end
local function bookstoreQuery(query)
    if not query then return nil end
    return { kind = "category", category_id = tostring(query.category_id), sort = 0 }
end
local function bookstoreQueryKey(query)
    return query and ("category:" .. tostring(query.category_id)) or "homepage"
end
local function sameFeedIdentity(left, right)
    return left and right and left.account_key == right.account_key
        and left.query_key == right.query_key and left.revision == right.revision
end
local function purchasePurpose(intent, fallback)
    local purpose = intent and intent.purpose or fallback
    return purpose == "download" and "download" or "read"
end

function Screens.new(options)
    return setmetatable({ controller = assert(options.controller), page = 1, epoch = 0,
        selected = {}, filter = "all", descending = false, loaded = {}, pending = {}, query = "" }, Screens)
end

function Screens:_ensureRouteViews()
    local key = accountKey(self.controller)
    if self.view_account_initialized and self.view_account == key then return true end
    self.view_account_initialized, self.view_account, self.route_views = true, key, {}
    self.query, self.search_results, self.search_error, self.loaded = "", nil, nil, {}
    self.comic_origin, self.account_origin, self.focused_comic_id = nil, nil, nil
    self.bookstore_query, self.bookstore_category = nil, nil
    return false
end

function Screens:_captureRoute()
    if not self.route then return nil end
    local selected = {}
    for id, value in pairs(self.selected or {}) do selected[id] = value end
    return { account_key = accountKey(self.controller), route = self.route, comic_id = self.comic_id,
        page = self.page, filter = self.filter, query = self.query, search_results = self.search_results, search_error = self.search_error,
        descending = self.descending, selecting = self.selecting, selected = selected,
        focused_comic_id = self.focused_comic_id, comic_origin = self.comic_origin,
        account_origin = self.account_origin, bookstore_query = self.bookstore_query,
        bookstore_category = self.bookstore_category }
end

function Screens:_navigate(route, id, restore)
    local same_account = self:_ensureRouteViews()
    if same_account and self.route then
        self.route_views[self.route .. ":" .. tostring(self.comic_id or "")] = self:_captureRoute()
        if self.route == "favorites" then self:_saveBookshelfView() end
    end
    local view = restore or route ~= "favorites" and route ~= "comic"
        and self.route_views[route .. ":" .. tostring(id or "")]
    if view and view.account_key ~= accountKey(self.controller) then view = nil end
    self:_closeDialog()
    self.purchase_visible = false
    self.epoch = self.epoch + 1
    if self.controller.cancelPendingRead then self.controller:cancelPendingRead() end
    self.bookstore_sequence = (self.bookstore_sequence or 0) + 1
    self.bookstore_loading, self.bookstore_error, self.bookstore_loading_more, self.bookstore_more_error = false, nil, false, nil
    self.route, self.comic_id, self.page = route, id, 1
    self.status, self.filter, self.selecting, self.selected = nil, "all", false, {}
    if route == "favorites" then self:_loadBookshelfView() end
    if view then
        self.page, self.filter = view.page or 1, view.filter or "all"
        if route == "search" then self.query, self.search_results, self.search_error = view.query or "", view.search_results, view.search_error end
        self.descending, self.selecting, self.selected = view.descending == true, view.selecting == true, view.selected or {}
        self.focused_comic_id, self.comic_origin = view.focused_comic_id, view.comic_origin
        self.account_origin = view.account_origin
        self.bookstore_query, self.bookstore_category = view.bookstore_query, view.bookstore_category
    end
    self:_render()
end

function Screens:_restoreRoute(view)
    if not view or view.account_key ~= accountKey(self.controller) then self:showLibrary(); return end
    self:_navigate(view.route, view.comic_id, view)
    if view.route == "favorites" then self:_syncBookshelf(false); self:_maybeBookshelfHelp()
    elseif view.route == "bookstore" and self.controller:getBookstore(self.bookstore_query).stale then self:_refreshBookstore()
    elseif view.route == "comic" and not self.loaded["comic:" .. tostring(view.comic_id)] then self:_refreshComic() end
end

function Screens:_rememberReaderReturn(comic_id)
    local ticket = { account_key = accountKey(self.controller), comic_id = tostring(comic_id),
        context = self:_captureRoute(), ready = false }
    self.bookshelf_reader_return = ticket
    return ticket
end

function Screens:_clearReaderReturn(ticket)
    if not ticket or self.bookshelf_reader_return == ticket then self.bookshelf_reader_return = nil end
end

-- Legacy continue/history links now return to the bookshelf without discarding progress.
function Screens:showLibrary()
    self:_navigate("favorites")
    self:_syncBookshelf(false)
    self:_maybeBookshelfHelp()
end
function Screens:showBookstore()
    self:_navigate("bookstore")
    if self.controller:getBookstore(self.bookstore_query).stale then self:_refreshBookstore() end
end
function Screens:showComic(id)
    local origin = self.route ~= "comic" and self:_captureRoute() or self.comic_origin
    self:_navigate("comic", tostring(id))
    self.comic_origin = origin
    if not self.loaded["comic:" .. tostring(id)] then self:_refreshComic() end
end
function Screens:showDownloads() self:_navigate("downloads") end
function Screens:showAccount()
    local origin = self.route ~= "account" and self:_captureRoute() or self.account_origin
    self:_navigate("account")
    self.account_origin = origin
end
function Screens:showSearch() self:_navigate("search") end
function Screens:refresh()
    if self.bookshelf_reader_return and self.bookshelf_reader_return.account_key ~= accountKey(self.controller) then
        self.bookshelf_reader_return = nil
    end
    if self.route then self:_render() end
end

function Screens:close(keep_reader_return)
    if self.route == "favorites" then self:_saveBookshelfView() end
    if not keep_reader_return then self.bookshelf_reader_return = nil end
    self.epoch = self.epoch + 1
    self.bookstore_sequence = (self.bookstore_sequence or 0) + 1
    self.bookstore_loading = false
    if self.controller.cancelPendingRead then self.controller:cancelPendingRead() end
    self:_closeDialog()
    if self.scope_dialog then UIManager:close(self.scope_dialog); self.scope_dialog = nil end
    if self.dialog then UIManager:close(self.dialog); self.dialog = nil end
    if self.widget then UIManager:close(self.widget); self.widget = nil end
    self.route = nil
end

function Screens:_closeDialog(keep_purchase)
    local repaint = self.context_dialog_dirty
    self:_rechargeClose()
    if not keep_purchase then self.purchase_visible = false end
    self.bookstore_synopsis, self.bookstore_synopsis_dirty = nil, nil
    self.bookstore_picker, self.bookstore_picker_state, self.bookstore_picker_dirty = nil, nil, nil
    self.context_dialog, self.context_dialog_dirty, self.context_dialog_account = nil, nil, nil
    self.session_input = nil
    if self.qr_login then self.qr_login:close(); self.qr_login = nil end
    if self.dialog then UIManager:close(self.dialog); self.dialog = nil end
    if repaint and self.route then self:_render() end
end

function Screens:_loadBookshelfView()
    local view = self.controller.getBookshelfViewState and self.controller:getBookshelfViewState() or { help_seen = true }
    self.bookshelf_view_account, self.bookshelf_view_loaded = accountKey(self.controller), true
    self.filter, self.bookshelf_sort, self.page = view.filter or "all", view.sort or "source", view.page or 1
    self.bookshelf_focused_comic_id = view.focused_comic_id and tostring(view.focused_comic_id) or nil
    self.bookshelf_restore_focus = self.bookshelf_focused_comic_id ~= nil
    self.bookshelf_order_ids, self.bookshelf_help_seen = copy(view.order_ids or {}), view.help_seen == true
    self.bookshelf_reorder = false
end

function Screens:_saveBookshelfView()
    if self.route ~= "favorites" or not self.bookshelf_view_loaded or self.bookshelf_view_account ~= accountKey(self.controller)
        or not self.controller.saveBookshelfViewState then return end
    self.controller:saveBookshelfViewState({ filter = self.filter or "all", sort = self.bookshelf_sort or "source", page = self.page or 1,
        focused_comic_id = self.bookshelf_focused_comic_id or false, order_ids = copy(self.bookshelf_order_ids or {}), help_seen = self.bookshelf_help_seen == true },
        self.bookshelf_view_account)
end

function Screens:onReaderClosed(event)
    local intent = self.bookshelf_reader_return
    self.bookshelf_reader_return = nil
    if not intent or not intent.ready or self.route ~= nil or intent.account_key ~= accountKey(self.controller)
        or not event or tostring(event.comic_id) ~= intent.comic_id then return false end
    if intent.context then self:_restoreRoute(intent.context) else self:showLibrary() end
    return true
end

function Screens:_showContextDialog(heading, buttons, on_dismiss, options)
    local dirty = self.context_dialog_dirty
    self:_closeDialog()
    local owner, epoch, key = self, self.epoch, accountKey(self.controller)
    local heading_title, body = heading:match("^([^\n]+)\n+(.*)$")
    local dialog = W.menuDialog(heading_title or heading, body and { body } or {}, buttons, options or { placement = "center",
        width = Device.screen:getWidth() - W.dp(144) })
    function dialog:onCloseWidget()
        UIManager:setDirty(nil, "ui")
        if owner.context_dialog ~= self then return end
        local repaint = owner.context_dialog_dirty
        owner.context_dialog, owner.context_dialog_dirty, owner.context_dialog_account = nil, nil, nil
        if owner.dialog == self then owner.dialog = nil end
        if owner.epoch == epoch and accountKey(owner.controller) == key then
            if on_dismiss then on_dismiss() end
            if repaint and owner.route then owner:_render() end
        end
    end
    self.dialog, self.context_dialog, self.context_dialog_dirty, self.context_dialog_account = dialog, dialog, dirty, key
    UIManager:show(dialog)
    return dialog
end

function Screens:_bookshelfSyncState()
    if self.controller.getBookshelfSyncState then return self.controller:getBookshelfSyncState() end
    local account = self.controller:getAccount() or {}
    local authenticated = account.session_valid
    if authenticated == nil and account.account_key == "anonymous" then authenticated = false end
    return { has_cache = true, syncing = false, can_sync = authenticated ~= false, authenticated = authenticated, offline = false }
end

function Screens:_syncBookshelf(manual)
    if self.route ~= "favorites" then return end
    local sync = self:_bookshelfSyncState()
    if sync.syncing or manual and not sync.can_sync then return end
    local epoch, key, completed = self.epoch, accountKey(self.controller), false
    local function done(value, error)
        completed = true
        if self.route ~= "favorites" or self.epoch ~= epoch or accountKey(self.controller) ~= key then return end
        if manual and value and not error then self.bookshelf_reorder = true end
        self:_render()
        self:_maybeBookshelfHelp()
    end
    if manual then
        if self.controller.syncBookshelf then self.controller:syncBookshelf(done)
        else self.controller:refreshLibrary("favorites", done) end
    elseif self.controller.ensureBookshelfSync then self.controller:ensureBookshelfSync(done)
    else return end
    if not completed and self.route == "favorites" and self.epoch == epoch and accountKey(self.controller) == key then self:_render() end
end

function Screens:_maybeBookshelfHelp()
    if self.route ~= "favorites" or self.bookshelf_help_seen or self.dialog or #(self.cards or {}) == 0 then return end
    local ticket = { epoch = self.epoch, account = accountKey(self.controller) }
    self.bookshelf_help_ticket = ticket
    UIManager:nextTick(function()
        if self.bookshelf_help_ticket ~= ticket then return end
        self.bookshelf_help_ticket = nil
        if self.route == "favorites" and self.epoch == ticket.epoch and accountKey(self.controller) == ticket.account
            and not self.bookshelf_help_seen and not self.dialog and #(self.cards or {}) > 0 then self:_bookshelfHelp() end
    end)
end

function Screens:_bookshelfHelp()
    local dialog
    dialog = self:_showContextDialog(T("Bookshelf help") .. "\n\n"
        .. T("Tap a cover to resume reading. Hold it to open chapters.") .. "\n\n"
        .. T("With keys, select a comic, then use More to open its chapter catalog.") .. "\n\n"
        .. T("Use More for sync, filters, sorting and settings."), {
        { { text = T("Got it"), callback = function() if self.dialog == dialog then dialog:onClose() end end } },
    }, function()
        self.bookshelf_help_seen = true
        if self.route == "favorites" then self:_saveBookshelfView()
        elseif self.controller.getBookshelfViewState and self.controller.saveBookshelfViewState then
            local view = self.controller:getBookshelfViewState(); view.help_seen = true
            self.controller:saveBookshelfViewState(view)
        end
    end)
end

function Screens:_selectedBookshelfComic()
    local focused = self.widget and self.widget:getFocusItem()
    if focused and focused.comic then self.bookshelf_focused_comic_id = tostring(focused.comic.id) end
    if self.resume_comic and tostring(self.resume_comic.id) == self.bookshelf_focused_comic_id then return self.resume_comic end
    for _index, card in ipairs(self.cards or {}) do
        if tostring(card.comic.id) == self.bookshelf_focused_comic_id then return card.comic end
    end
    return self.cards and self.cards[1] and self.cards[1].comic or self.resume_comic
end

function Screens:_more()
    if self.route == "favorites" then self:_bookshelfMore(); return end
    local epoch, key = self.epoch, accountKey(self.controller)
    local dialog
    local function current() return self.dialog == dialog and self.epoch == epoch and accountKey(self.controller) == key end
    local buttons, heading = {}, T("More")
    if self.route == "comic" then
        buttons[#buttons + 1] = { { text = T("Refresh chapters"), callback = function()
            if current() then self:_closeDialog(); self:_refreshComic() end
        end } }
        buttons[#buttons + 1] = { { text = T("Comic overview"), callback = function()
            if current() then self:_catalogDetails(self.controller:getComic(self.comic_id) or { id = self.comic_id }) end
        end } }
    end
    buttons[#buttons + 1] = { { text = T("Account and settings"), callback = function() if current() then self:showAccount() end end } }
    buttons[#buttons + 1] = { { text = T("Bookshelf help"), callback = function() if current() then self:_bookshelfHelp() end end } }
    buttons[#buttons + 1] = { { text = T("Close"), callback = function() if current() then dialog:onClose() end end } }
    dialog = self:_showContextDialog(heading, buttons, nil,
        { placement = "right", width = W.dp(440), top = W.dp(104), right = W.dp(40) })
end

function Screens:_bookshelfMore()
    self:_saveBookshelfView()
    self:_closeDialog()
    local sync, comic = self:_bookshelfSyncState(), self:_selectedBookshelfComic()
    local epoch, key, dialog = self.epoch, accountKey(self.controller), nil
    local function current() return self.dialog == dialog and self.epoch == epoch and accountKey(self.controller) == key end
    local width, inner = W.dp(440), W.dp(380)
    local timestamp = tonumber(sync.last_synced_at)
    local note = sync.syncing and T("Syncing bookshelf…") or timestamp and timestamp > 0
        and string.format(T("Last synced %s · Automatic sync on entry"), os.date("%m-%d %H:%M", timestamp)) or T("Not synced yet")
    local rows, focus = {}, {}
    local function row(label, value, callback, height, subline, enabled)
        local right = value and W.dp(132) or 0
        local content
        if subline then content = W.column{ text(label, inner, 21, { bold = true }), space(8), text(subline, inner, 16, { muted = true }) }
        else content = W.row{ text(label, inner - right, 21),
            value and text(value .. " ›", right, 19, { muted = true, align = "right" }) or W.gap(0) } end
        local action = W.ActionRow:new{ width = inner, enabled = enabled ~= false,
            content = W.box(content, inner, W.dp(height), { align = "left" }),
            callback = function() if current() then callback() end end }
        rows[#rows + 1], focus[#focus + 1] = action, { action }
    end
    row(T("Sync bookshelf"), nil, function() self:_closeDialog(); self:_syncBookshelf(true) end, 92, note, sync.can_sync and not sync.syncing)
    local filters = { all = T("All"), reading = T("Currently reading"), unknown = T("No reading record"),
        updated = T("Updated"), completed = T("Completed series") }
    local sorts = { source = T("Bookshelf order"), title = T("Title"), recent = T("Recently read") }
    row(T("Filter"), filters[self.filter] or filters.all, function() self:_bookshelfFilter() end, 72)
    row(T("Sort"), sorts[self.bookshelf_sort] or sorts.source, function() self:_bookshelfSort() end, 72)
    if Device:hasKeys() and comic then row(T("Open chapter catalog"), nil, function() self:showComic(comic.id) end, 72) end
    row(T("Bookshelf help"), nil, function() self:_bookshelfHelp() end, 72)
    rows[#rows + 1] = W.rule(inner, true)
    local account = self.controller:getAccount() or {}
    row(T("Account and settings"), account.name or account.username, function() self:showAccount() end, 72)
    local owner = self
    dialog = W.sheetDialog(W.inset(W.column(rows), W.dp(28), W.dp(28), 0, 0), focus,
        { placement = "right", width = width, top = W.dp(104), right = W.dp(40) })
    local original_close = dialog.onCloseWidget
    function dialog:onCloseWidget()
        original_close(self)
        if owner.context_dialog ~= self then return end
        local dirty = owner.context_dialog_dirty
        owner.context_dialog, owner.context_dialog_dirty, owner.context_dialog_account = nil, nil, nil
        if owner.dialog == self then owner.dialog = nil end
        if dirty and owner.route and owner.epoch == epoch and accountKey(owner.controller) == key then owner:_render() end
    end
    self.dialog, self.context_dialog, self.context_dialog_account = dialog, dialog, key
    UIManager:show(dialog)
end

function Screens:_bookshelfSort()
    local dialog
    local choices = { { "source", T("Bookshelf order") }, { "title", T("Title") }, { "recent", T("Recently read") } }
    local buttons = {}
    for _index, choice in ipairs(choices) do
        local value = choice[1]
        buttons[#buttons + 1] = { { text = choice[2] .. (self.bookshelf_sort == value and " ✓" or ""), callback = function()
            if self.dialog ~= dialog then return end
            self:_closeDialog()
            self.bookshelf_sort, self.bookshelf_reorder, self.page, self.epoch = value, true, 1, self.epoch + 1
            self:_render(); self:_saveBookshelfView()
        end } }
    end
    buttons[#buttons + 1] = { { text = T("Cancel"), callback = function() if self.dialog == dialog then dialog:onClose() end end } }
    dialog = self:_showContextDialog(T("Sort bookshelf"), buttons)
end

function Screens:_bookshelfItems()
    local items = copy(Model.array(self.controller.getBookshelfItems and self.controller:getBookshelfItems()
        or self.controller:getLibrary("favorites")))
    local records, source_order = {}, {}
    for index, comic in ipairs(items) do records[tostring(comic.id)], source_order[tostring(comic.id)] = comic, index end
    if self.bookshelf_reorder or #(self.bookshelf_order_ids or {}) == 0 then
        local function readTime(comic)
            local extra = comic.extra or {}
            if (comic.progress_source or extra.progress_source) ~= "local" then return nil end
            local value = tonumber(comic.last_read_at or extra.last_read_at)
            return value and value > 0 and value < math.huge and value or nil
        end
        if self.bookshelf_sort == "title" then
            table.sort(items, function(a, b)
                local left, right = tostring(title(a)):lower(), tostring(title(b)):lower()
                if left ~= right then return left < right end
                return source_order[tostring(a.id)] < source_order[tostring(b.id)]
            end)
        elseif self.bookshelf_sort == "recent" then
            table.sort(items, function(a, b)
                local left, right = readTime(a), readTime(b)
                if left ~= right then return left ~= nil and (right == nil or left > right) end
                return source_order[tostring(a.id)] < source_order[tostring(b.id)]
            end)
        end
        self.bookshelf_order_ids = {}
        for _index, comic in ipairs(items) do self.bookshelf_order_ids[#self.bookshelf_order_ids + 1] = tostring(comic.id) end
        self.bookshelf_reorder = false
    end
    local ordered, ids, seen = {}, {}, {}
    for _index, id in ipairs(self.bookshelf_order_ids or {}) do
        if records[id] and not seen[id] then ordered[#ordered + 1], ids[#ids + 1], seen[id] = records[id], id, true end
    end
    for _index, comic in ipairs(items) do
        local id = tostring(comic.id)
        if not seen[id] then ordered[#ordered + 1], ids[#ids + 1], seen[id] = comic, id, true end
    end
    self.bookshelf_order_ids = ids
    return ordered
end

function Screens:_back()
    if self.route == "comic" and self.comic_origin then
        local origin = self.comic_origin
        self.comic_origin = nil
        self:_restoreRoute(origin)
    elseif self.route == "account" then
        local origin = self.account_origin
        self.account_origin = nil
        self:_restoreRoute(origin)
    else self:close() end
end

function Screens:_error(error)
    local heading, message, action = Model.error(error)
    self:_closeDialog()
    local buttons = { { { text = T("Close"), callback = function() self:_closeDialog() end } } }
    if action == "account" then
        table.insert(buttons, 1, { { text = T("Open account"), callback = function()
            self:_closeDialog(); self:showAccount()
        end } })
    end
    if error and (error.kind == "low_space" or error.kind == "storage") then
        table.insert(buttons, 1, { { text = T("Storage and cache"), callback = function() self:_showStorageSettings() end } })
    elseif error and (error.kind == "source_unavailable" or error.kind == "image_decode") then
        table.insert(buttons, 1, { { text = T("Downloads"), callback = function() self:showDownloads() end } })
    end
    self:_showContextDialog(heading .. "\n\n" .. message, buttons)
end

function Screens:_invoke(method, args, done, quiet)
    local epoch = self.epoch
    local completed = false
    args[#args + 1] = function(value, error)
        if completed then return end
        completed = true
        if epoch ~= self.epoch then return end
        self.status = nil
        if done then done(value, error)
        elseif error then self:_error(error) end
        if self.route then self:_render() end
    end
    if not quiet then self.status = T("Updating…"); self:_render() end
    local ok = pcall(function() self.controller[method](self.controller, unpack(args)) end)
    if not ok and not completed then
        args[#args](nil, { kind = "internal" })
    end
end

function Screens:_refreshComic()
    local id = self.comic_id
    self:_invoke("refreshComic", { id }, function(value, error)
        if error then self:_error(error) else self.loaded["comic:" .. id] = true end
    end)
end

function Screens:_button(text, width, callback, options)
    local button = W.button(text, width, callback, options)
    self.focus[#self.focus + 1] = { button }
    return button
end

function Screens:_buttons(entries)
    local gap = W.scale(6)
    local width = math.floor((self.width - gap * (#entries - 1)) / #entries)
    local widgets, focus = {}, {}
    for index, entry in ipairs(entries) do
        if index > 1 then widgets[#widgets + 1] = W.gap(gap) end
        local button = W.button(entry.text, width, entry.callback, entry)
        widgets[#widgets + 1], focus[#focus + 1] = button, button
    end
    self.focus[#self.focus + 1] = focus
    return W.row(widgets)
end

function Screens:_pageRanges(items, row_height, fixed_height)
    local heights = {}
    for index, item in ipairs(items) do
        heights[index] = math.max(1, type(row_height) == "function" and row_height(item, index) or W.scale(row_height))
    end
    local function partition(reserve)
        local available = math.max(W.scale(32), self.body_height - fixed_height - reserve)
        local ranges, first, used = {}, 1, 0
        for index, height in ipairs(heights) do
            if index > first and used + height > available then
                ranges[#ranges + 1] = { first = first, last = index - 1 }
                first, used = index, 0
            end
            used = used + height
        end
        if #items > 0 then ranges[#ranges + 1] = { first = first, last = #items } end
        return ranges
    end
    local ranges = partition(0)
    if #ranges > 1 then ranges = partition(W.scale(42)) end
    return ranges, ranges[1] and ranges[1].last or 0
end

function Screens:_jumpPage()
    self:_closeDialog()
    local dialog, epoch, key = nil, self.epoch, accountKey(self.controller)
    dialog = InputDialog:new{ title = T("Go to page"), input = tostring(self.page), input_type = "number", modal = true,
        description = string.format(T("Choose a page from 1 to %d."), self.pages), buttons = {
            { { text = T("Cancel"), callback = function() self:_closeDialog() end },
              { text = T("Go"), is_enter_default = true, callback = function()
                  if self.dialog ~= dialog or self.epoch ~= epoch or accountKey(self.controller) ~= key then return end
                  local number = tonumber(dialog:getInputText())
                  if not number or number % 1 ~= 0 or number < 1 or number > self.pages then return end
                  self:_closeDialog(); self:_changePage(number - self.page)
              end } },
        } }
    self.dialog = dialog; UIManager:show(dialog); dialog:onShowKeyboard()
end

function Screens:_paginate(items, row_height, fixed_height, render, empty_message, options)
    options = options or {}
    local ranges = self:_pageRanges(items, row_height, fixed_height)
    self.page_ranges, self.pages = ranges, math.max(1, #ranges)
    if options.target_id then
        for page, range in ipairs(ranges) do
            for index = range.first, range.last do
                local id = options.item_id and options.item_id(items[index]) or items[index].id
                if tostring(id) == tostring(options.target_id) then self.page = page end
            end
        end
    end
    self.page = math.max(1, math.min(self.page or 1, self.pages))
    local rows = {}
    local range = ranges[self.page]
    if range then
        for index = range.first, range.last do rows[#rows + 1] = render(items[index], index) end
    end
    if #items == 0 and empty_message ~= false then
        rows[#rows + 1] = W.text(empty_message or T("No items are available."), self.width, W.font.body)
    end
    if self.pages > 1 then
        local width = math.floor(self.width / 3)
        local previous = W.button(T("Previous"), width, function() self:_changePage(-1) end,
            { borderless = true, size = W.font.meta, enabled = self.page > 1, align = "left" })
        local counter = W.button(string.format(T("%d / %d"), self.page, self.pages) .. " ▾", self.width - 2 * width,
            options.jump_callback or function() self:_jumpPage() end, { borderless = true, size = W.font.meta })
        local next_page = W.button(T("Next"), width, function() self:_changePage(1) end,
            { borderless = true, size = W.font.meta, enabled = self.page < self.pages, align = "right" })
        rows[#rows + 1], rows[#rows + 2] = W.space(8), W.row{ previous, counter, next_page }
        self.focus[#self.focus + 1] = { previous, counter, next_page }
        self.pagination = { previous = previous, counter = counter, next = next_page }
    end
    return W.column(rows)
end

function Screens:_changePage(delta)
    if self.route == "bookstore" and delta > 0 and self.page >= (self.pages or 1) then
        if self.controller:getBookstore(self.bookstore_query).can_load_more then self:_requestBookstore(true) end
        return
    end
    local page = math.max(1, math.min(self.pages or 1, self.page + delta))
    if page == self.page then return end
    self.epoch, self.page, self.status = self.epoch + 1, page, nil
    if self.controller.cancelPendingRead then self.controller:cancelPendingRead() end
    self:_render()
end

function Screens:_render()
    if not self.route then return end
    self:_rechargeCheckCurrent()
    if not self:_ensureRouteViews() then
        self.epoch = self.epoch + 1
        self.page, self.filter, self.selecting, self.selected = 1, "all", false, {}
        self:_closeDialog()
    end
    if self.context_dialog and self.context_dialog_account ~= accountKey(self.controller) then self:_closeDialog() end
    if self.route == "favorites" and (not self.bookshelf_view_loaded or self.bookshelf_view_account ~= accountKey(self.controller)) then
        if self.context_dialog then self:_closeDialog() end
        self.epoch = self.epoch + 1
        self:_loadBookshelfView()
    end
    if self.context_dialog and self.dialog == self.context_dialog then
        self.context_dialog_dirty = true
        return
    end
    if self.bookstore_synopsis and self.dialog == self.bookstore_synopsis then
        self.bookstore_synopsis_dirty = true
        return
    end
    if self.bookstore_picker and self.dialog == self.bookstore_picker then
        self.bookstore_picker_dirty = true
        return
    end
    if self.qr_login then self.qr_login:_current() end
    self.focus, self.cards, self.pagination = {}, {}, nil
    self.render_generation = (self.render_generation or 0) + 1
    local screen_width = Device.screen:getWidth()
    self.width = screen_width - 2 * W.dp(56)
    self.height = Device.screen:getHeight()
    local headings = { bookstore = T("Bookstore"), favorites = T("Bookshelf"), comic = T("Chapter catalog"),
        downloads = T("Downloads"), search = T("Search"), account = T("Account and settings") }
    local header, header_buttons = W.header(headings[self.route], screen_width, {
        back_callback = function() self:_back() end,
        more_callback = self.route ~= "account" and function() self:_more() end or nil,
        offline = self:_bookshelfSyncState().offline == true, controller = self.controller,
    })
    self.focus[#self.focus + 1] = header_buttons
    local builders = { bookstore = self._bookstore, favorites = self._library, comic = self._comic,
        downloads = self._downloads, search = self._search, account = self._account }
    local origin = self.route == "comic" and self.comic_origin and self.comic_origin.route or self.route
    local active_downloads = 0
    if self.controller.getDownloads then
        for _, job in ipairs(Model.array(self.controller:getDownloads())) do
            if job.state == "queued" or job.state == "running" then active_downloads = active_downloads + 1 end
        end
    end
    local navigation, navigation_buttons = W.navigation({
        { text = T("Bookshelf"), selected = origin == "favorites", callback = function() self:showLibrary() end },
        { text = T("Bookstore"), selected = origin == "bookstore", callback = function() self:showBookstore() end },
        { text = T("Search"), selected = origin == "search", callback = function() self:showSearch() end },
        { text = T("Downloads"), selected = origin == "downloads", badge = active_downloads > 0 and active_downloads or nil,
            callback = function() self:showDownloads() end },
    }, screen_width)
    self.body_height = self.height - W.dp(116) - W.dp(self.route == "comic" and self.selecting and 108 or 88)
    local body = builders[self.route](self)
    if self.route == "comic" and self.selecting and self._catalogSelectionFooter then
        navigation, navigation_buttons = self:_catalogSelectionFooter()
    end
    self.header, self.navigation = header, navigation
    self.navigation_buttons = navigation_buttons
    self.focus[#self.focus + 1] = navigation_buttons
    local content = W.column{ header, W.inset(W.box(body, self.width, self.body_height, { align = "left", valign = "top" }),
        W.dp(56), W.dp(56), 0, 0), navigation }
    local previous = self.widget
    local selected, restore_focus
    if previous and previous.view_epoch == self.epoch and previous.view_route == self.route
        and previous.view_page == self.page and previous.selected then
        local old = previous:getFocusItem()
        local position = previous.selected
        if self.focus[position.y] and self.focus[position.y][position.x] then selected = position end
        restore_focus = old and (old.focused or old[1] and old[1].invert)
    end
    local wanted_comic = self.route == "favorites" and self.bookshelf_focused_comic_id
        or self.route == "search" and self.focused_comic_id
    if not selected and wanted_comic then
        for y, row in ipairs(self.focus) do for x, item in ipairs(row) do
            if item.comic and tostring(item.comic.id) == wanted_comic then selected = { x = x, y = y } end
        end end
    end
    self.widget = W.Panel:new{ content = content, layout = self.focus, selected = selected,
        view_epoch = self.epoch, view_route = self.route, view_page = self.page,
        close_callback = function() self:_back() end,
        next_page = function() self:_changePage(1) end,
        previous_page = function() self:_changePage(-1) end }
    if previous then UIManager:close(previous) end
    UIManager:show(self.widget)
    if selected and restore_focus then
        local focused = self.widget:getFocusItem()
        if focused and focused.onFocus then focused:onFocus() end
    end
end

function Screens:_comicCard(comic, measure)
    if not measure and self.controller.requestCover then self.controller:requestCover(comic.id) end
    local cover_width, cover_height = W.dp(78), W.dp(104)
    local tag_width = comic.favorite and W.dp(106) or 0
    local text_width = self.width - cover_width - W.dp(28) - W.dp(36) - tag_width
    local subtitle = comic.latest_episode_title or (comic.extra or {}).latest_episode_title
        or (comic.latest_order and string.format(T("Latest chapter: %s"), tostring(comic.latest_order))) or T("Open chapter catalog")
    local authors = type(comic.authors) == "table" and comic.authors[1] or comic.authors
    if type(authors) == "table" then authors = authors.name end
    local metadata = {}
    for _, value in ipairs((comic.extra or {}).tags or {}) do
        if type(value) == "string" and #metadata < 2 then metadata[#metadata + 1] = value end
    end
    metadata[#metadata + 1] = subtitle
    local cover = measure and W.box(space(0), cover_width, cover_height) or W.cover(comic, cover_width, cover_height)
    local columns = { cover, W.gap(W.dp(28)), W.column{
        W.line(title(comic), text_width, W.fontSize(22), { bold = true, height = W.dp(28.6) }),
        space(5), W.line(type(authors) == "string" and authors or "", text_width, W.fontSize(18), { height = W.dp(23.4) }),
        space(5), W.line(table.concat(metadata, " · "), text_width, W.fontSize(16), { muted = true, height = W.dp(20.8) }),
    } }
    if comic.favorite then
        columns[#columns + 1] = W.box(W.line(T("In bookshelf"), W.dp(88), W.fontSize(16), { align = "center", height = W.dp(28) }),
            tag_width, W.dp(36), { border_px = W.dp(1.5) })
    end
    columns[#columns + 1] = text("›", W.dp(36), 28, { muted = true, align = "right" })
    local content = W.column{ W.box(W.row(columns), self.width, W.dp(129), { align = "left" }), W.rule(self.width) }
    local epoch, key = self.epoch, accountKey(self.controller)
    local row = W.ActionRow:new{ width = self.width, content = content, callback = function()
        if self.route ~= "search" or self.epoch ~= epoch or accountKey(self.controller) ~= key then return end
        self.focused_comic_id = tostring(comic.id); self:showComic(comic.id)
    end, focus_callback = function() self.focused_comic_id = tostring(comic.id) end }
    row.comic = comic
    if not measure then
        self.focus[#self.focus + 1] = { row }
        self.search_cards = self.search_cards or {}
        self.search_cards[#self.search_cards + 1] = row
    end
    return row
end

function Screens:_readComic(comic)
    self:_saveBookshelfView()
    self.epoch = self.epoch + 1
    if self.controller.cancelPendingRead then self.controller:cancelPendingRead() end
    local key, epoch = accountKey(self.controller), self.epoch
    self:_invoke("resolveReadingEpisode", { tostring(comic.id) }, function(target, error)
        if accountKey(self.controller) ~= key or self.epoch ~= epoch then return end
        if error then self:_error(error) else self:_read(target.comic, target.episode) end
    end)
end

function Screens:_bookshelfFilter()
    local rows, epoch, account = {}, self.epoch, accountKey(self.controller)
    local dialog
    for _, option in ipairs{
        { "all", T("All") }, { "reading", T("Currently reading") }, { "unknown", T("No reading record") },
        { "updated", T("Updated") }, { "completed", T("Completed series") },
    } do
        local key = option[1]
        rows[#rows + 1] = { { text = option[2] .. (self.filter == key and " ✓" or ""), callback = function()
            if self.dialog ~= dialog or self.epoch ~= epoch or accountKey(self.controller) ~= account then return end
            self:_closeDialog()
            self.filter, self.page, self.status, self.epoch = key, 1, nil, self.epoch + 1
            if self.controller.cancelPendingRead then self.controller:cancelPendingRead() end
            self:_render(); self:_saveBookshelfView()
        end } }
    end
    rows[#rows + 1] = { { text = T("Cancel"), callback = function()
        if self.dialog == dialog then dialog:onClose() end
    end } }
    dialog = self:_showContextDialog(T("Filter bookshelf"), rows)
end

function Screens:_stateBlock(heading, message, actions, options)
    options = options or {}
    local width = math.min(self.width, W.dp(600))
    local rows = { text(heading, width, 34, { bold = true, align = "center" }), space(20),
        text(message, width, 20, { muted = true, align = "center", line_height = 0.7 }) }
    local action_width = math.min(width, W.dp(360))
    for index, action in ipairs(actions or {}) do
        rows[#rows + 1] = space(index == 1 and 42 or 14)
        rows[#rows + 1] = W.box(self:_button(action.text, action_width, action.callback,
            buttonOptions{ primary = action.primary, enabled = action.enabled, height_dp = 68, size_dp = 23 }), width, W.dp(68))
    end
    local content = W.column(rows)
    return W.inset(W.box(content, self.width, content:getSize().h), 0, 0, W.dp(options.top or 120), 0)
end

function Screens:_inlinePager(current, can_load_more)
    if self.pages <= 1 and not can_load_more then return nil end
    local previous = W.button("‹", W.dp(46), function() if current() then self:_changePage(-1) end end,
        buttonOptions{ borderless = true, size_dp = 30, height_dp = 52, enabled = self.page > 1 })
    local counter = W.button(string.format(T("%d / %d"), self.page, self.pages), W.dp(80),
        function() if current() then self:_jumpPage() end end, buttonOptions{ borderless = true, size_dp = 20, height_dp = 52 })
    local next_page = W.button("›", W.dp(46), function() if current() then self:_changePage(1) end end,
        buttonOptions{ borderless = true, size_dp = 30, height_dp = 52,
            enabled = self.page < self.pages or can_load_more and not self.bookstore_loading })
    self.pagination = { previous = previous, counter = counter, next = next_page }
    return W.row{ previous, counter, next_page }, { previous, counter, next_page }
end

function Screens:_offlineAvailability(comic)
    local ready = 0
    for _, episode in ipairs(Model.array(self.controller:getEpisodes(comic.id))) do
        local extra = episode.extra or {}
        if Model.downloadable(episode) and (episode.downloaded or extra.downloaded
            or episode.cached_complete or extra.cached_complete) then
            ready = ready + 1
        end
    end
    return ready > 0 and string.format(T("Offline · %d chapters"), ready) or T("Connection required"), ready
end

function Screens:_resumeComic(items)
    local latest, timestamp, progress
    for _, comic in ipairs(items) do
        local extra = comic.extra or {}
        local last_read = tonumber(comic.last_read_at or extra.last_read_at)
        if (comic.progress_source or extra.progress_source) == "local" and last_read and last_read > 0
            and last_read < math.huge and (not timestamp or last_read > timestamp) then
            local position = Model.comicProgress(comic, self.controller:getEpisodes(comic.id))
            if position.state == "reading" and position.episode_id then latest, timestamp, progress = comic, last_read, position end
        end
    end
    return latest, progress, timestamp
end

function Screens:_resumeBlock(comic, progress, timestamp, current)
    local landscape = Device.screen:getWidth() > Device.screen:getHeight()
    local compact = landscape or Device.screen:getWidth() < 1000
    local cover_width, cover_height = W.dp(compact and 144 or 216), W.dp(compact and 192 or 288)
    local gap, right_width = W.dp(compact and 24 or 36), self.width - cover_width - W.dp(compact and 24 or 36)
    if self.controller.requestCover then self.controller:requestCover(comic.id) end
    local elapsed = math.max(0, os.time() - timestamp)
    local recent = elapsed < 3600 and T("Just now") or elapsed < 86400
        and string.format(T("%d hours ago"), math.floor(elapsed / 3600)) or os.date("%m-%d %H:%M", timestamp)
    local sync = self:_bookshelfSyncState()
    local tag_note = recent .. " · " .. T("Local progress")
    if sync.offline then
        local episode, downloaded = progress.current_episode or {}, false
        local extra = episode.extra or {}
        downloaded = Model.downloadable(episode) and (episode.downloaded or extra.downloaded
            or episode.cached_complete or extra.cached_complete)
        tag_note = downloaded and T("Downloaded chapters · Offline reading") or T("Connection required")
    end
    local tag_width = W.dp(88)
    local tag = W.box(W.line(T("Last read"), tag_width, W.fontSize(17),
        { bold = true, align = "center", color = W.paper, height = W.dp(29) }),
        tag_width, W.dp(29), { background = W.ink })
    local episode = progress.current_episode or {}
    local chapter_number = tonumber(episode.short_title) or tonumber(episode.order)
    local chapter_label = chapter_number and string.format(T("Ch. %s"), tostring(chapter_number)) or self:_bookshelfProgress(progress)
    if episode.title and episode.title ~= "" then chapter_label = chapter_label .. " · " .. episode.title end
    local top = W.column{ W.row{ tag, W.gap(W.dp(14)), W.line(tag_note, right_width - tag_width - W.dp(14), W.fontSize(17),
        { muted = true, height = W.dp(29) }) }, space(compact and 12 or 20),
        W.line(title(comic), right_width, W.fontSize(compact and 32 or 46),
            { bold = true, height = W.dp(compact and 42 or 53) }), space(10),
        W.line(chapter_label, right_width, W.fontSize(compact and 20 or 23), { height = W.dp(30) }) }
    local fraction = progress.page and progress.total_pages and progress.page / progress.total_pages or 0
    local percent = progress.total_pages and string.format("%d%%", math.floor(fraction * 100 + 0.5)) or ""
    local label = progress.page and progress.total_pages and string.format(T("Page %d / %d"), progress.page, progress.total_pages)
        or progress.page and string.format(T("Page %d"), progress.page) or T("Reading position unavailable")
    local catalog_width = W.dp(compact and 150 or 190)
    local resume = W.button(T("Continue reading"), right_width - catalog_width - W.dp(16),
        function() if current() then self:_readComic(comic) end end,
        buttonOptions{ primary = true, height_dp = 66, size_dp = compact and 21 or 23 })
    local catalog = W.button(T("Chapter catalog"), catalog_width,
        function() if current() then self:showComic(comic.id) end end, buttonOptions{ height_dp = 66, size_dp = 21 })
    resume.comic, catalog.comic = comic, comic
    local bottom = W.column{ W.row{ W.line(label, right_width - W.dp(60), W.fontSize(17), { muted = true, height = W.dp(22) }),
        W.line(percent, W.dp(60), W.fontSize(17), { muted = true, align = "right", height = W.dp(22) }) }, space(10),
        W.progress(right_width, W.dp(10), fraction), space(compact and 14 or 24), W.row{ resume, W.gap(W.dp(16)), catalog } }
    local right = W.column{ top, W.spacePixels(math.max(0, cover_height - top:getSize().h - bottom:getSize().h)), bottom }
    local cover = W.ActionRow:new{ width = cover_width,
        content = W.cover(comic, cover_width, cover_height, { hero = true, offline = sync.offline }),
        callback = function() if current() then self:_readComic(comic) end end,
        hold_callback = function() if current() then self:showComic(comic.id) end end,
        focus_callback = function() if current() then self.bookshelf_focused_comic_id = tostring(comic.id) end end }
    cover.comic = comic
    self.resume_card = cover
    self.focus[#self.focus + 1] = { cover, resume, catalog }
    self.resume_comic, self.resume_progress = comic, progress
    return W.column{ space(compact and 24 or 34), W.row{ cover, W.gap(gap), right }, space(compact and 24 or 32), W.rule(self.width, true) }
end

function Screens:_bookshelf(items)
    local entries, sync = {}, self:_bookshelfSyncState()
    local epoch, generation, key = self.epoch, self.render_generation, accountKey(self.controller)
    local function current() return self.route == "favorites" and self.epoch == epoch
        and self.render_generation == generation and accountKey(self.controller) == key end
    self.resume_comic, self.resume_progress, self.resume_card = nil, nil, nil
    if sync.syncing and not sync.has_cache then
        self.pages, self.page, self.page_ranges = 1, 1, {}
        local rows = { space(64), text(T("Syncing bookshelf…"), self.width, 34, { bold = true }), space(20),
            text(T("The first sync takes a moment. Your bookshelf appears when it is ready. You can browse Bookstore or Search meanwhile."),
                math.min(self.width, W.dp(600)), 20, { muted = true, line_height = 0.7 }), space(34) }
        local fetched, ready, total = tonumber(sync.comics_count), tonumber(sync.covers_ready), tonumber(sync.covers_total)
        if fetched then
            local counter = ready and total and string.format("%d / %d", ready, total) or ""
            rows[#rows + 1] = W.row{ text(string.format(T("Fetched %d comics · Preparing visible covers"), fetched), self.width - W.dp(100), 17,
                { muted = true }), text(counter, W.dp(100), 17, { muted = true, align = "right" }) }
        else rows[#rows + 1] = text(T("Fetching your bookshelf and reading progress…"), self.width, 17, { muted = true }) end
        local fraction = tonumber(sync.progress) or ready and total and total > 0 and ready / total
        if fraction and fraction == fraction and fraction >= 0 and fraction <= 1 then
            rows[#rows + 1], rows[#rows + 2] = space(10), W.progress(self.width, W.dp(10), fraction)
        end
        rows[#rows + 1], rows[#rows + 2], rows[#rows + 3] = space(44), W.rule(self.width, true), space(30)
        local browse = self:_button(T("Go to Bookstore"), W.dp(240), function() if current() then self:showBookstore() end end,
            buttonOptions{ height_dp = 64 })
        local search = self:_button(T("Search comics"), W.dp(240), function() if current() then self:showSearch() end end,
            buttonOptions{ height_dp = 64 })
        rows[#rows + 1] = W.row{ browse, W.gap(W.dp(16)), search }
        return W.column(rows)
    end
    if #items == 0 and sync.authenticated == false then
        self.pages, self.page, self.page_ranges = 1, 1, {}
        local state = self:_stateBlock(T("Sign in to sync your bookshelf"),
            T("Scan a QR code to sign in to Bilibili. Followed comics and reading progress will appear here. Downloaded chapters are available offline without signing in."), {
                { text = T("Sign in with QR code"), primary = true, callback = function()
                    if current() then self:showAccount(); self:_signInWithQR() end end },
                { text = T("Browse Bookstore"), callback = function() if current() then self:showBookstore() end end },
            })
        local downloaded, seen = 0, {}
        for _, job in ipairs(Model.array(self.controller.getDownloads and self.controller:getDownloads() or {})) do
            local id = tostring(job.comic_id or (job.payload or {}).comic_id or "")
            if job.state == "complete" and id ~= "" and not seen[id] then downloaded, seen[id] = downloaded + 1, true end
        end
        local footer_width = math.min(self.width, W.dp(560))
        local offline = self:_button(T("Read offline") .. " ›", W.dp(160), function() if current() then self:showDownloads() end end,
            buttonOptions{ borderless = true, align = "right", height_dp = 68, size_dp = 20 })
        return W.column{ state, space(72), W.box(W.column{ W.rule(footer_width), W.row{
            text(string.format(T("%d comics downloaded locally"), downloaded), footer_width - W.dp(160), 20, { muted = true }), offline } },
            self.width, W.dp(70)) }
    end
    local hero, hero_progress, timestamp = self:_resumeComic(items)
    local matched = 0
    for _, comic in ipairs(items) do
        local progress = Model.comicProgress(comic, self.controller:getEpisodes(comic.id))
        local updated = comic.updated or comic.has_update or (comic.extra or {}).has_update
        if self.filter == "all" or self.filter == progress.state or self.filter == "updated" and updated
            or self.filter == "completed" and comic.finished then
            matched = matched + 1
            if not hero or tostring(comic.id) ~= tostring(hero.id) then
                local availability, ready = self:_offlineAvailability(comic)
                entries[#entries + 1] = { comic = comic, progress = progress, updated = not not updated,
                    availability = sync.offline and availability or nil, progress_muted = sync.offline and ready == 0 or progress.state == "unknown" }
            end
        end
    end
    local rows = {}
    if hero then rows[#rows + 1] = self:_resumeBlock(hero, hero_progress, timestamp, current) end
    if sync.error and #items > 0 then
        rows[#rows + 1] = space(12)
        rows[#rows + 1] = text(T("Could not sync. Saved comics are still available."), self.width, 17, { muted = true })
    end
    local empty = self.filter ~= "all" and T("No comics match this filter.") or not sync.has_cache
        and (sync.offline and T("Connect, then retry bookshelf sync.") or T("Your bookshelf has not been synced yet."))
        or T("Your bookshelf is empty. Find a comic in Bookstore or Search.")
    local actions = {
        { text = T("Browse Bookstore"), primary = true, callback = function() if current() then self:showBookstore() end end },
        { text = T("Search comics"), callback = function() if current() then self:showSearch() end end },
    }
    if not sync.has_cache then actions = {
        { text = T("Retry sync"), primary = true, enabled = sync.can_sync,
            callback = function() if current() then self:_syncBookshelf(true) end end },
        { text = T("Read offline"), callback = function() if current() then self:showDownloads() end end },
    } end
    return self:_coverGrid(entries, { rows = rows, bookshelf = true, empty_message = empty,
        empty_heading = self.filter ~= "all" and T("No comics match this filter.") or T("Your bookshelf is empty"),
        actions = actions, total = #items, matched = matched, offline = sync.offline, sync = sync, hero = hero ~= nil })
end

function Screens:_bookshelfToolbar(pagination, current, options)
    options = options or {}
    local labels = { all = T("All"), reading = T("Currently reading"), unknown = T("No reading record"),
        updated = T("Updated"), completed = T("Completed series") }
    local sorts = { source = T("Bookshelf order"), title = T("Title"), recent = T("Recently read") }
    local pager_width = pagination and W.dp(172) or 0
    local heading_width = W.dp(Device.screen:getWidth() < 1000 and 225 or 274)
    local count_label = self.filter ~= "all" and string.format(T("%d / %d comics"), options.matched or 0, options.total or 0)
        or string.format(T("%d comics"), options.total or 0)
    local heading = W.row{ text(T("My bookshelf"), W.dp(130), 26, { bold = true }), W.gap(W.dp(12)),
        text(count_label, heading_width - W.dp(142), 19, { muted = true }) }
    local controls, focus = {}, {}
    if options.offline then
        local timestamp = tonumber(options.sync and options.sync.last_synced_at)
        local note = T("Offline") .. " · " .. (timestamp and timestamp > 0
            and string.format(T("Saved at %s"), os.date("%m-%d %H:%M", timestamp)) or T("Saved bookshelf"))
        controls[#controls + 1] = text(note, self.width - heading_width - pager_width, 18, { muted = true, align = "right" })
    else
        local width = self.width - heading_width - pager_width
        local control_width = width - W.dp(21)
        local filter_width = math.floor(control_width * 0.43)
        local filter = W.button((labels[self.filter] or labels.all) .. " ▾", filter_width,
            function() if current() then self:_bookshelfFilter() end end,
            buttonOptions{ borderless = true, size_dp = 20, height_dp = 52, bold = self.filter ~= "all" })
        local sort = W.button((sorts[self.bookshelf_sort] or sorts.source) .. " ▾", control_width - filter_width,
            function() if current() then self:_bookshelfSort() end end, buttonOptions{ borderless = true, size_dp = 20, height_dp = 52 })
        controls[#controls + 1] = filter
        controls[#controls + 1] = W.gap(W.dp(10))
        controls[#controls + 1] = W.box(nil, W.dp(1), W.dp(28), { background = W.divider })
        controls[#controls + 1] = W.gap(W.dp(10))
        controls[#controls + 1] = sort
        focus[#focus + 1], focus[#focus + 2] = filter, sort
        self.bookshelf_filter_button, self.bookshelf_sort_button = filter, sort
    end
    if pagination then
        controls[#controls + 1] = W.row{ pagination.previous, pagination.counter, pagination.next }
        for _, value in ipairs{ pagination.previous, pagination.counter, pagination.next } do focus[#focus + 1] = value end
    end
    self.bookshelf_toolbar_buttons, self.bookshelf_toolbar = focus,
        W.box(W.row{ heading, W.row(controls) }, self.width, W.dp(84), { align = "left" })
    if #focus > 0 then self.focus[#self.focus + 1] = focus end
    return self.bookshelf_toolbar
end

function Screens:_bookshelfProgress(progress)
    if not progress then return "" end
    local episode = progress.current_episode or {}
    local number = tonumber(episode.short_title) or tonumber(episode.order)
    if not number or number <= 0 or number ~= number or number == math.huge then return progress.label end
    local chapter = string.format(T("Ch. %s"), tostring(number))
    if progress.chapter_finished then return chapter .. " · " .. T("Finished reading") end
    if progress.page and progress.total_pages then return chapter .. " · " .. string.format("%d/%d", progress.page, progress.total_pages) end
    if progress.page then return chapter .. " · " .. string.format(T("Page %d"), progress.page) end
    return chapter
end

function Screens:_coverGrid(entries, options)
    options = options or {}
    local screen_width, screen_height = Device.screen:getWidth(), Device.screen:getHeight()
    local landscape = screen_width > screen_height
    local columns = options.bookshelf and (screen_width >= 1400 and 5 or screen_width >= 1000 and 4 or 3)
        or (screen_width >= 1400 and 4 or screen_width >= 900 and 3 or 2)
    if landscape then columns = options.bookshelf and 6 or 5 end
    local gap = W.dp(options.bookshelf and 22 or 24)
    local row_gap = W.dp(options.bookshelf and 26 or 22)
    local width = math.floor((self.width - gap * (columns - 1)) / columns)
    local cover_height = math.floor(width * 4 / 3)
    local metadata_height = W.dp(10) + W.dp(options.bookshelf and 23.4 or 24.7)
        + W.dp(4) + W.dp(options.bookshelf and 19.5 or 20.8)
    local rows = options.rows or {}
    local fixed_height = W.column(copy(rows)):getSize().h + W.dp(options.bookshelf and 84 or 88)
    if options.bookshelf and self.filter ~= "all" then fixed_height = fixed_height + W.dp(88) end
    local available = self.body_height - fixed_height
    local desired_rows = landscape and 1 or options.bookshelf and 2 or 3
    local row_count = math.max(1, math.min(desired_rows, math.floor((available + row_gap) / (cover_height + metadata_height + row_gap))))
    if not landscape and screen_width >= 1400 then row_count = desired_rows end
    cover_height = math.min(cover_height, math.max(W.dp(70), math.floor((available - row_gap * (row_count - 1)) / row_count) - metadata_height))
    if not options.bookshelf and not landscape and screen_width >= 1400 then cover_height = W.dp(240) end
    local capacity = columns * row_count
    if options.bookshelf then
        if self.bookshelf_restore_focus or self.bookshelf_grid_capacity and self.bookshelf_grid_capacity ~= capacity then
            for index, entry in ipairs(entries) do
                if tostring(entry.comic.id) == self.bookshelf_focused_comic_id then self.page = math.ceil(index / capacity); break end
            end
        end
        self.bookshelf_restore_focus, self.bookshelf_grid_capacity = nil, capacity
    end
    self.pages, self.page_ranges = math.max(1, math.ceil(#entries / capacity)), {}
    self.page = math.max(1, math.min(self.page or 1, self.pages))
    local epoch, key, generation = self.epoch, accountKey(self.controller), self.render_generation
    local route, query_key = self.route, bookstoreQueryKey(options.query)
    local function currentGrid()
        return self.route == route and self.epoch == epoch and accountKey(self.controller) == key and self.render_generation == generation
            and (not options.bookstore or bookstoreQueryKey(self.bookstore_query) == query_key)
    end
    local pager, pager_focus = self:_inlinePager(currentGrid, options.can_load_more)
    if options.bookshelf then
        rows[#rows + 1] = self:_bookshelfToolbar(self.pagination, currentGrid, options)
        if self.filter ~= "all" then
            local labels = { reading = T("Currently reading"), unknown = T("No reading record"), updated = T("Updated"), completed = T("Completed series") }
            local clear_width = W.dp(184)
            local clear = W.button(T("Clear filter") .. " ×", clear_width, function()
                if not currentGrid() then return end
                self.filter, self.page, self.epoch = "all", 1, self.epoch + 1
                self:_render(); self:_saveBookshelfView()
            end, buttonOptions{ borderless = true, bold = true, height_dp = 62, size_dp = 19 })
            self.focus[#self.focus + 1] = { clear }
            rows[#rows + 1] = W.box(W.row{ W.gap(W.dp(22)), text(T("Filter:") .. " " .. (labels[self.filter] or ""),
                self.width - clear_width - W.dp(22), 19, { bold = true }), clear }, self.width, W.dp(62), { border_px = W.dp(1.5), align = "left" })
            rows[#rows + 1] = space(26)
        end
    else
        local toolbar = options.toolbar(pager, currentGrid)
        rows[#rows + 1] = toolbar
        if pager_focus then self.focus[#self.focus + 1] = pager_focus end
    end
    self.cards, self.grid_columns, self.grid_rows = {}, columns, row_count
    local row, focus
    for index = (self.page - 1) * capacity + 1, math.min(self.page * capacity, #entries) do
        if not row or #focus == columns then
            if row then rows[#rows + 1] = W.row(row); rows[#rows + 1] = W.spacePixels(row_gap); self.focus[#self.focus + 1] = focus end
            row, focus = {}, {}
        end
        local entry, comic = entries[index], entries[index].comic
        if options.bookstore and self.controller.requestBookstoreCover then self.controller:requestBookstoreCover(comic.id, options.feed_identity)
        elseif self.controller.requestCover then self.controller:requestCover(comic.id) end
        local function current()
            return currentGrid() and (not options.bookstore or sameFeedIdentity(options.feed_identity,
                self.controller:getBookstore(self.bookstore_query).identity))
        end
        local card = W.CoverCard:new{ comic = comic, text = title(comic), width = width, cover_height = cover_height,
            redesign = true, compact = options.bookstore, bookshelf = options.bookshelf, offline = options.offline,
            progress = options.bookstore and entry.tags or entry.description or entry.progress and entry.progress.label or "",
            progress_label = entry.availability or options.bookshelf and self:_bookshelfProgress(entry.progress) or nil,
            progress_muted = entry.progress_muted, updated = options.bookshelf and entry.updated or false,
            update = options.bookstore and (entry.tags or "") or Model.comicUpdate(comic), callback = function()
                if not current() then return end
                self.focused_comic_id = tostring(comic.id)
                if options.bookshelf then self.bookshelf_focused_comic_id = tostring(comic.id) end
                if options.bookstore then self:showComic(comic.id) else self:_readComic(comic) end
            end, hold_callback = function()
                if not current() then return end
                if options.bookstore then self:_bookstoreSynopsis(comic) else self:showComic(comic.id) end
            end, focus_callback = function(focused)
                if options.bookshelf and current() then self.bookshelf_focused_comic_id = tostring(focused.id) end
            end }
        if #row > 0 then row[#row + 1] = W.gap(gap) end
        row[#row + 1], focus[#focus + 1], self.cards[#self.cards + 1] = card, card, card
    end
    if row then rows[#rows + 1] = W.row(row); self.focus[#self.focus + 1] = focus end
    if options.bookshelf and #self.cards > 0 then
        local found = false
        for _, card in ipairs(self.cards) do if tostring(card.comic.id) == self.bookshelf_focused_comic_id then found = true end end
        if not found then self.bookshelf_focused_comic_id = tostring(self.cards[1].comic.id) end
    end
    if #entries == 0 and not options.hero then
        rows[#rows + 1] = self:_stateBlock(options.empty_heading or T("No items are available."), options.empty_message or "", options.actions,
            { top = 74 })
    elseif #entries == 0 and self.filter ~= "all" then
        rows[#rows + 1] = text(options.empty_message, self.width, 20, { muted = true })
    end
    return W.column(rows)
end
function Screens:_library()
    return self:_bookshelf(self:_bookshelfItems())
end

function Screens:_refreshBookstore() self:_requestBookstore(false) end

function Screens:_requestBookstore(append)
    if self.route ~= "bookstore" or self.bookstore_loading then return end
    local query = bookstoreQuery(self.bookstore_query)
    local feed = self.controller:getBookstore(query)
    if append and not feed.can_load_more then return end
    local old_count, old_page = #feed.items, self.page
    local capacity = (self.grid_columns or 1) * (self.grid_rows or 1)
    if not append then self.page = 1 end
    self.bookstore_sequence = (self.bookstore_sequence or 0) + 1
    local sequence, key, query_key = self.bookstore_sequence, accountKey(self.controller), bookstoreQueryKey(query)
    self.bookstore_loading, self.bookstore_error, self.bookstore_loading_more, self.bookstore_more_error = true, nil, append, nil
    self:_render()
    local completed = false
    local function done(value, error)
        if completed then return end
        completed = true
        if sequence ~= self.bookstore_sequence or key ~= accountKey(self.controller)
            or query_key ~= bookstoreQueryKey(self.bookstore_query) or self.route ~= "bookstore" then return end
        self.bookstore_loading, self.bookstore_error, self.bookstore_loading_more = false, error, false
        self.bookstore_more_error = append and error or nil
        if append and not error and self.page == old_page then
            local updated = self.controller:getBookstore(query)
            -- Fill a partial cached page before advancing, so newly appended comics are not skipped.
            if #updated.items > old_count then self.page = math.floor(old_count / capacity) + 1 end
        end
        if self.route == "bookstore" then self:_render() end
    end
    local ok
    if append then ok = pcall(self.controller.loadMoreBookstore, self.controller, query, done)
    elseif query then ok = pcall(self.controller.refreshBookstore, self.controller, query, done)
    else ok = pcall(self.controller.refreshBookstore, self.controller, done) end
    if not ok then done(nil, { kind = "internal" }) end
end

function Screens:_selectBookstoreCategory(category)
    self.page = 1
    self.bookstore_category = category and { id = tostring(category.id), name = category.name } or nil
    self.bookstore_query = category and { kind = "category", category_id = tostring(category.id), sort = 0 } or nil
    self:showBookstore()
end

function Screens:_bookstoreCategoryPicker()
    if self.route ~= "bookstore" then return end
    self:_closeDialog()
    local state = { epoch = self.epoch, account = accountKey(self.controller) }
    self.bookstore_picker_state = state
    self:_renderBookstoreCategoryPicker(state)
    if self.controller:getBookstoreCategories().stale then self:_refreshBookstoreCategories(state) end
end

function Screens:_refreshBookstoreCategories(state)
    if state ~= self.bookstore_picker_state or state.loading then return end
    state.loading, state.error = true, nil
    self:_renderBookstoreCategoryPicker(state)
    local completed = false
    local function done(value, error)
        if completed then return end
        completed = true
        if state ~= self.bookstore_picker_state or state.epoch ~= self.epoch
            or state.account ~= accountKey(self.controller) or self.route ~= "bookstore" then return end
        state.loading, state.error = false, error
        self:_renderBookstoreCategoryPicker(state)
    end
    local ok = pcall(self.controller.refreshBookstoreCategories, self.controller, done)
    if not ok then done(nil, { kind = "internal" }) end
end

function Screens:_renderBookstoreCategoryPicker(state)
    if state ~= self.bookstore_picker_state or state.epoch ~= self.epoch or state.account ~= accountKey(self.controller) then return end
    local catalogue = self.controller:getBookstoreCategories()
    local width = Device.screen:getWidth() - W.dp(144)
    local inner = width - W.dp(72) - 2 * W.dp(2)
    local rows, focus, dialog = {}, {}, nil
    local function current()
        return self.dialog == dialog and self.bookstore_picker == dialog and self.bookstore_picker_state == state
            and self.route == "bookstore" and self.epoch == state.epoch and accountKey(self.controller) == state.account
    end
    rows[#rows + 1] = W.row{ text(T("Choose a category"), math.floor(inner * 0.5), 26, { bold = true }),
        text(T("Official categories · Popularity order"), inner - math.floor(inner * 0.5), 16, { muted = true, align = "right" }) }
    rows[#rows + 1] = space(26)
    if state.loading or state.error then
        rows[#rows + 1] = text(state.loading and T("Loading categories…")
            or #catalogue.items > 0 and T("Could not update categories. Choose a saved category.")
            or T("Categories could not be loaded. Retry to choose a category."), inner, 17, { muted = true })
        rows[#rows + 1] = space(16)
    end
    local all = W.button(T("All recommendations") .. (not self.bookstore_query and " ✓" or ""), inner,
        function() if current() then self:_selectBookstoreCategory(nil) end end,
        buttonOptions{ primary = not self.bookstore_query, height_dp = 64, size_dp = 21 })
    rows[#rows + 1], focus[#focus + 1] = all, { all }
    rows[#rows + 1] = space(12)
    local page_size, columns = 16, 4
    if Device.screen:getWidth() < 1000 then page_size, columns = 12, 3 end
    local pages = math.max(1, math.ceil(#catalogue.items / page_size))
    state.page = math.max(1, math.min(state.page or 1, pages))
    local cell_width = math.floor((inner - W.dp(12) * (columns - 1)) / columns)
    local row, row_focus
    for index = (state.page - 1) * page_size + 1, math.min(state.page * page_size, #catalogue.items) do
        if not row or #row_focus == columns then
            if row then rows[#rows + 1] = W.row(row); focus[#focus + 1] = row_focus; rows[#rows + 1] = space(12) end
            row, row_focus = {}, {}
        end
        local category = catalogue.items[index]
        local selected = self.bookstore_query and tostring(category.id) == self.bookstore_query.category_id
        local choice = W.button(category.name, cell_width, function() if current() then self:_selectBookstoreCategory(category) end end,
            buttonOptions{ primary = selected, height_dp = 64, size_dp = 21 })
        if #row > 0 then row[#row + 1] = W.gap(W.dp(12)) end
        row[#row + 1], row_focus[#row_focus + 1] = choice, choice
    end
    if row then rows[#rows + 1] = W.row(row); focus[#focus + 1] = row_focus end
    rows[#rows + 1] = space(24)
    local footer, footer_focus = {}, {}
    local cancel = W.button(T("Cancel"), W.dp(200), function() if current() then dialog:onClose() end end,
        buttonOptions{ height_dp = 62, size_dp = 21 })
    if pages > 1 then
        local arrow_width = W.dp(52)
        local previous = W.button("‹", arrow_width, function()
            if current() then state.page = state.page - 1; self:_renderBookstoreCategoryPicker(state) end
        end, buttonOptions{ borderless = true, height_dp = 62, size_dp = 30, enabled = state.page > 1 })
        local next_page = W.button("›", arrow_width, function()
            if current() then state.page = state.page + 1; self:_renderBookstoreCategoryPicker(state) end
        end, buttonOptions{ borderless = true, height_dp = 62, size_dp = 30, enabled = state.page < pages })
        footer = { previous, text(string.format(T("%d / %d"), state.page, pages), W.dp(80), 20, { align = "center" }), next_page,
            W.gap(inner - W.dp(384)), cancel }
        footer_focus = { previous, next_page, cancel }
    else
        local note = T("Official category list")
        local timestamp = tonumber(catalogue.updated_at or catalogue.fetched_at)
        if timestamp and timestamp > 0 then note = string.format(T("Category list updated %s"), os.date("%m-%d %H:%M", timestamp)) end
        footer = { text(note, inner - W.dp(200), 16, { muted = true }), cancel }
        footer_focus = { cancel }
    end
    rows[#rows + 1], focus[#focus + 1] = W.row(footer), footer_focus
    if state.error then
        local retry = W.button(T("Retry"), inner, function() if current() then self:_refreshBookstoreCategories(state) end end,
            buttonOptions{ height_dp = 62, size_dp = 21 })
        rows[#rows + 1], rows[#rows + 2], focus[#focus + 1] = space(14), retry, { retry }
    end
    local owner = self
    dialog = W.sheetDialog(W.inset(W.column(rows), W.dp(36), W.dp(36), W.dp(32), W.dp(32)), focus,
        { width = width, top = W.dp(176), left = W.dp(72), placement = "top",
            next_page = function() if current() and state.page < pages then state.page = state.page + 1; self:_renderBookstoreCategoryPicker(state) end end,
            previous_page = function() if current() and state.page > 1 then state.page = state.page - 1; self:_renderBookstoreCategoryPicker(state) end end,
            close_callback = function()
            if owner.bookstore_picker ~= dialog then return end
            UIManager:close(dialog)
            local dirty = owner.bookstore_picker_dirty
            owner.bookstore_picker, owner.bookstore_picker_state, owner.bookstore_picker_dirty = nil, nil, nil
            if owner.dialog == dialog then owner.dialog = nil end
            if dirty and owner.route == "bookstore" then owner:_render() end
        end })
    local previous = self.bookstore_picker
    self.dialog, self.bookstore_picker = dialog, dialog
    if previous then UIManager:close(previous) end
    UIManager:show(dialog)
end
function Screens:_bookstore()
    local query = bookstoreQuery(self.bookstore_query)
    local feed = self.controller:getBookstore(query)
    local category_name = self.bookstore_category and self.bookstore_category.name or T("Category")
    local entries = {}
    local epoch, generation, key, query_key = self.epoch, self.render_generation, accountKey(self.controller), bookstoreQueryKey(query)
    local function current() return self.route == "bookstore" and self.epoch == epoch and self.render_generation == generation
        and accountKey(self.controller) == key and bookstoreQueryKey(self.bookstore_query) == query_key end
    local sections = { recommendation = T("Recommended"), hot_seller = T("Bestsellers"),
        internet_hot = T("Trending"), completed = T("Completed picks") }
    for _, comic in ipairs(Model.array(feed.items)) do
        local extra, tags = comic.extra or {}, {}
        for _, tag in ipairs(extra.tags or {}) do if type(tag) == "string" then tags[#tags + 1] = tag end end
        local section = query and category_name or sections[extra.recommendation_section] or T("Recommended")
        local caption = section
        if #tags > 0 and tags[1] ~= section then caption = caption .. " · " .. tags[1] end
        if query and #tags > 0 then caption = tags[1] end
        entries[#entries + 1] = { comic = comic, description = extra.recommendation or extra.evaluate or "", tags = caption }
    end
    local rows = {}
    if self.bookstore_error and #entries > 0 then
        rows[#rows + 1] = text(self.bookstore_more_error and T("Could not load more. Tap the next arrow to retry.")
            or T("Could not refresh. Showing saved recommendations."), self.width, 17, { muted = true, height = W.dp(30) })
    elseif self.bookstore_loading and #entries > 0 then
        rows[#rows + 1] = text(self.bookstore_loading_more and T("Loading more comics…") or T("Refreshing recommendations…"),
            self.width, 17, { muted = true, height = W.dp(30) })
    elseif query and feed.limit_reached then
        rows[#rows + 1] = text(T("Browsing limit reached. Use Search to find more comics."), self.width, 17, { muted = true, height = W.dp(30) })
    end
    local empty_heading, empty_message, actions
    if self.bookstore_loading then
        empty_heading = query and T("Loading comics…") or T("Loading recommendations…")
        empty_message = T("The comics will appear when loading is complete.")
    elseif self.bookstore_error then
        if query and self.bookstore_error.kind == "network" then
            empty_heading = string.format(T("Connect to load “%s”"), category_name)
            empty_message = T("This category has no saved content. Saved recommendations remain available offline.")
            actions = { { text = T("Retry"), primary = true, callback = function() if current() then self:_refreshBookstore() end end },
                { text = T("View all recommendations"), callback = function() if current() then self:_selectBookstoreCategory(nil) end end } }
        else
            empty_heading = query and T("This category could not be loaded. Try again.") or T("Recommendations could not be loaded. Try again.")
            empty_message = T("Check the connection and try again.")
            actions = { { text = T("Retry"), primary = true, callback = function() if current() then self:_refreshBookstore() end end } }
        end
    else
        empty_heading = query and T("No comics are available in this category.") or T("No recommendations are available.")
        empty_message = T("Try another category or search for a comic.")
        actions = { { text = T("Search comics"), primary = true, callback = function() if current() then self:showSearch() end end } }
    end
    local function toolbar(pager, current)
        local subject_width = W.dp(query and 186 or 196)
        local pager_width = pager and W.dp(172) or 0
        local category = W.button((query and category_name or T("All recommendations")) .. " ▾", subject_width,
            function() if current() then self:_bookstoreCategoryPicker() end end,
            buttonOptions{ height_dp = 52, size_dp = 21, bold = true })
        self.bookstore_category_button = category
        self.focus[#self.focus + 1] = { category }
        local count_label = query and string.format(T("Loaded %d comics"), #entries)
            or string.format(T("Official recommendations · %d comics"), #entries)
        local parts = { category, W.gap(W.dp(22)), text(count_label,
            self.width - subject_width - pager_width - W.dp(22), 18, { muted = true }) }
        if pager then parts[#parts + 1] = pager end
        return W.box(W.row(parts), self.width, W.dp(88), { align = "left" })
    end
    return self:_coverGrid(entries, { rows = rows, bookstore = true, toolbar = toolbar,
        empty_heading = empty_heading, empty_message = empty_message, actions = actions,
        query = query, feed_identity = feed.identity, can_load_more = feed.can_load_more == true,
        offline = self:_bookshelfSyncState().offline })
end
function Screens:_bookstoreSynopsis(comic, page, preserve)
    if not preserve then self:_closeDialog() end
    local width = self.width - 2 * W.dp(2)
    local extra = comic.extra or {}
    local synopsis = extra.recommendation or extra.evaluate or T("No synopsis is available.")
    local max_height = math.min(W.dp(360), math.max(W.dp(70), Device.screen:getHeight() - W.dp(620)))
    local pages = textPages(synopsis, width, 20, max_height, 0.75)
    page = math.max(1, math.min(page or 1, #pages))
    local epoch, key, dialog = self.epoch, accountKey(self.controller), nil
    local function current() return self.dialog == dialog and self.bookstore_synopsis == dialog
        and self.epoch == epoch and self.route == "bookstore" and accountKey(self.controller) == key end
    local right_width = width - W.dp(186)
    local authors = comic.authors
    if type(authors) == "table" then authors = authors[1]; if type(authors) == "table" then authors = authors.name end end
    local meta = type(authors) == "string" and authors or ""
    local latest = comic.latest_episode_title or extra.latest_episode_title
    if latest then meta = meta .. (meta ~= "" and " · " or "") .. latest end
    local rows, focus = { W.row{ W.cover(comic, W.dp(150), W.dp(200)), W.gap(W.dp(36)), W.column{
        text(title(comic), right_width, 34, { bold = true, height = W.dp(48), fixed_height = true }), space(14),
        text(meta, right_width, 18, { muted = true, height = W.dp(56), fixed_height = true }), space(18),
        text(table.concat(extra.tags or {}, " · "), right_width, 16, { height = W.dp(48), fixed_height = true }),
    } }, space(28), text(pages[page], width, 20, { line_height = 0.75 }) }, {}
    if #pages > 1 then
        local previous = W.button(T("Previous"), W.dp(160), function()
            if current() then self:_bookstoreSynopsis(comic, page - 1, true) end
        end, buttonOptions{ borderless = true, height_dp = 52, size_dp = 20, enabled = page > 1 })
        local next_page = W.button(T("Next"), W.dp(160), function()
            if current() then self:_bookstoreSynopsis(comic, page + 1, true) end
        end, buttonOptions{ borderless = true, height_dp = 52, size_dp = 20, enabled = page < #pages })
        rows[#rows + 1], rows[#rows + 2] = space(20), W.row{ previous,
            text(string.format(T("%d / %d"), page, #pages), width - W.dp(320), 20, { align = "center" }), next_page }
        focus[#focus + 1] = { previous, next_page }
    end
    rows[#rows + 1] = space(32)
    local chapters = W.button(T("View chapters"), width - W.dp(392), function() if current() then self:showComic(comic.id) end end,
        buttonOptions{ primary = true, height_dp = 68, size_dp = 23 })
    local stored = self.controller:getComic(comic.id) or comic
    local pending = self.controller.isFavoritePending and self.controller:isFavoritePending(comic.id)
    local follow = W.button(stored.favorite and T("Following") .. " ✓" or T("Follow"), W.dp(200), function()
        if not current() or self.controller.isFavoritePending and self.controller:isFavoritePending(comic.id) then return end
        local function update()
            if not current() then return end
            self:_invoke("setFavorite", { tostring(comic.id), not stored.favorite }, function(value, error)
                if error then self:_error(error); return end
                if current() then self:_bookstoreSynopsis(value or comic, page, true) end
            end, true)
        end
        if self.controller:getComic(comic.id) then update()
        else self:_invoke("refreshComic", { tostring(comic.id) }, function(value, error)
            if error then self:_error(error) else stored = value and value.comic or stored; update() end
        end, true) end
    end, buttonOptions{ height_dp = 68, size_dp = 21, enabled = not pending })
    local close = W.button(T("Close"), W.dp(160), function() if current() then dialog:onClose() end end,
        buttonOptions{ height_dp = 68, size_dp = 21 })
    rows[#rows + 1], focus[#focus + 1] = W.row{ chapters, W.gap(W.dp(16)), follow, W.gap(W.dp(16)), close }, { chapters, follow, close }
    local owner, previous = self, self.bookstore_synopsis
    dialog = W.sheetDialog(W.inset(W.column(rows), W.dp(56), W.dp(56), W.dp(38), W.dp(40)), focus,
        { width = Device.screen:getWidth(),
            next_page = function() if current() and page < #pages then self:_bookstoreSynopsis(comic, page + 1, true) end end,
            previous_page = function() if current() and page > 1 then self:_bookstoreSynopsis(comic, page - 1, true) end end,
            close_callback = function()
            if owner.bookstore_synopsis ~= dialog then return end
            UIManager:close(dialog)
            local dirty = owner.bookstore_synopsis_dirty
            owner.bookstore_synopsis, owner.bookstore_synopsis_dirty = nil, nil
            if owner.dialog == dialog then owner.dialog = nil end
            if dirty and owner.route == "bookstore" then owner:_render() end
        end })
    self.dialog, self.bookstore_synopsis = dialog, dialog
    if previous then UIManager:close(previous) end
    UIManager:show(dialog)
end
function Screens:_searchHome()
    self:_closeDialog()
    self.epoch = self.epoch + 1
    self.query, self.search_results, self.search_error, self.status = "", nil, nil, nil
    self.page, self.filter, self.focused_comic_id = 1, "all", nil
    self:_render()
end

function Screens:_runSearch(query)
    query = tostring(query or ""):match("^%s*(.-)%s*$")
    if query == "" then self:_searchHome(); return end
    self:_closeDialog()
    self.epoch = self.epoch + 1
    self.query, self.search_results, self.search_error = query, nil, nil
    self.page, self.filter, self.focused_comic_id = 1, "all", nil
    self:_invoke("search", { query }, function(value, error)
        if self.query ~= query then return end
        self.search_error = error
        if value and not error then
            self.search_results = Model.array(value)
            local history, recent = self.controller:getSetting("search_history", {}), { query }
            for _, old in ipairs(history) do if old ~= query and #recent < 8 then recent[#recent + 1] = old end end
            self.controller:setSetting("search_history", recent)
        end
    end)
end

function Screens:_editSearch()
    self:_closeDialog()
    local dialog, epoch, key = nil, self.epoch, accountKey(self.controller)
    dialog = SearchInputDialog:new{ title = T("Search comics"), input = self.query, input_hint = T("Title or author"), modal = true,
        width = Device.screen:getWidth() - W.dp(112) - 2 * W.dp(2), border_size = W.dp(2), is_movable = false,
        text_width = self.width - W.dp(112) - 2 * W.dp(1.5), input_padding = 0, input_margin = 0,
        input_face = Font:getFace("cfont", W.fontSize(22)),
        buttons = { { { text = T("Cancel"), callback = function() self:_closeDialog() end },
            { text = T("Search"), is_enter_default = true, callback = function()
                if self.dialog ~= dialog or self.epoch ~= epoch or accountKey(self.controller) ~= key then return end
                self:_runSearch(dialog:getInputText())
            end } } } }
    self.dialog = dialog; UIManager:show(dialog); dialog:onShowKeyboard()
end

function Screens:_searchFilter()
    local dialog, epoch, key = nil, self.epoch, accountKey(self.controller)
    local buttons = {}
    for _, choice in ipairs({ { "all", T("All") }, { "ongoing", T("Ongoing") }, { "completed", T("Completed") } }) do
        local value = choice[1]
        buttons[#buttons + 1] = { { text = (self.filter == value and "[x] " or "[ ] ") .. choice[2], callback = function()
            if self.dialog ~= dialog or self.epoch ~= epoch or accountKey(self.controller) ~= key then return end
            self:_closeDialog(); self.filter, self.page, self.epoch = value, 1, self.epoch + 1; self:_render()
        end } }
    end
    buttons[#buttons + 1] = { { text = T("Cancel"), callback = function() self:_closeDialog() end } }
    dialog = self:_showContextDialog(T("Filter search results"), buttons)
end

function Screens:_searchLink(label, note, callback)
    local width = self.width - W.dp(46)
    local content = W.column{ W.box(W.row{ W.column{ text(label, width, 21, { height = W.dp(30), fixed_height = true }),
        space(5), text(note, width, 16, { muted = true, height = W.dp(24), fixed_height = true }) },
        text("›", W.dp(46), 24, { muted = true, align = "right" }) }, self.width, W.dp(81), { align = "left" }), W.rule(self.width) }
    local epoch, key = self.epoch, accountKey(self.controller)
    local row = W.ActionRow:new{ width = self.width, content = content, callback = function()
        if self.route == "search" and self.epoch == epoch and accountKey(self.controller) == key then callback() end
    end }
    self.focus[#self.focus + 1] = { row }
    return row
end

function Screens:_search()
    self.search_cards = {}
    local epoch, generation, key = self.epoch, self.render_generation, accountKey(self.controller)
    local function current() return self.route == "search" and self.epoch == epoch
        and self.render_generation == generation and accountKey(self.controller) == key end
    local field_width = self.width - W.dp(154)
    local clear_width = self.query ~= "" and W.dp(52) or 0
    local field = W.button(self.query ~= "" and self.query or T("Enter comic title or author"), field_width - clear_width - 2 * W.dp(1.5),
        function() if current() then self:_editSearch() end end,
        buttonOptions{ borderless = true, align = "left", size_dp = 22, height_dp = 69, padding_h = W.dp(22) })
    if self.query == "" and field.label_widget then field.label_widget.fgcolor = W.faint end
    local field_parts, field_focus = { field }, { field }
    if clear_width > 0 then
        local clear = W.button("×", clear_width, function() if current() then self:_searchHome() end end,
            buttonOptions{ borderless = true, size_dp = 26, height_dp = 69 })
        field_parts[#field_parts + 1], field_focus[#field_focus + 1] = clear, clear
        self.search_clear_button = clear
    end
    local submit = W.button(T("Search"), W.dp(140), function()
        if not current() then return end
        if self.query == "" then self:_editSearch() else self:_runSearch(self.query) end
    end, buttonOptions{ primary = true, size_dp = 23, height_dp = 72 })
    field_focus[#field_focus + 1] = submit
    self.focus[#self.focus + 1] = field_focus
    self.search_field, self.search_button = field, submit
    local rows = { space(34), W.row{ W.box(W.row(field_parts), field_width, W.dp(72), { border_px = W.dp(1.5), align = "left" }),
        W.gap(W.dp(14)), submit } }
    if self.query == "" then
        local history = self.controller:getSetting("search_history", {})
        rows[#rows + 1] = space(46)
        local clear = W.button(T("Clear history"), W.dp(100), function()
            if not current() then return end
            local _, error = self.controller:setSetting("search_history", {})
            if error then self:_error(error) else self:_render() end
        end, buttonOptions{ borderless = true, size_dp = 19, height_dp = 42, align = "right", enabled = #history > 0 })
        self.focus[#self.focus + 1] = { clear }
        rows[#rows + 1] = W.row{ text(T("Recent searches"), self.width - W.dp(100), 22, { bold = true }), clear }
        rows[#rows + 1] = W.rule(self.width, true)
        if #history == 0 then
            rows[#rows + 1] = W.box(text(T("No recent searches"), self.width, 19, { muted = true }), self.width, W.dp(68), { align = "left" })
        end
        for index, query in ipairs(history) do
            if index > 5 then break end
            local history_button = W.button(query .. "  ›", self.width,
                function() if current() then self:_runSearch(query) end end,
                buttonOptions{ borderless = true, align = "left", size_dp = 21, height_dp = 67, padding_h = 0 })
            self.focus[#self.focus + 1] = { history_button }
            rows[#rows + 1], rows[#rows + 2] = history_button, W.rule(self.width)
        end
        rows[#rows + 1] = space(38)
        rows[#rows + 1] = text(T("Other ways"), self.width, 22, { bold = true })
        rows[#rows + 1] = space(14)
        rows[#rows + 1] = W.rule(self.width, true)
        rows[#rows + 1] = self:_searchLink(T("Open by comic ID"), T("For example mc12345"), function() self:_lookupComicID() end)
        rows[#rows + 1] = self:_searchLink(T("Browse Bookstore"), T("Official recommendations and categories"), function() self:showBookstore() end)
    else
        local results = {}
        for _, comic in ipairs(self.search_results or {}) do
            if self.filter == "all" or self.filter == "completed" and comic.finished
                or self.filter == "ongoing" and not comic.finished then results[#results + 1] = comic end
        end
        local chips, chip_focus = {}, {}
        local choices = { { "all", T("All"), 92 }, { "ongoing", T("Ongoing"), 120 }, { "completed", T("Completed"), 120 } }
        for index, choice in ipairs(choices) do
            local value = choice[1]
            local chip = W.button(choice[2], W.dp(choice[3]), function()
                if not current() or self.filter == value then return end
                self.filter, self.page, self.epoch = value, 1, self.epoch + 1; self:_render()
            end, buttonOptions{ primary = self.filter == value, height_dp = 48, size_dp = 19, enabled = not self.status })
            if index > 1 then chips[#chips + 1] = W.gap(W.dp(12)) end
            chips[#chips + 1], chip_focus[#chip_focus + 1] = chip, chip
        end
        local summary_width = self.width - W.dp(356)
        self.focus[#self.focus + 1] = chip_focus
        rows[#rows + 1] = W.column{ W.box(W.row{ text(string.format(T("“%s” · %d comics"), self.query, #results), summary_width, 20,
            { bold = true, height = W.dp(32), fixed_height = true }), W.row(chips) }, self.width, W.dp(89), { align = "left" }),
            W.rule(self.width, true) }
        if self.status then
            rows[#rows + 1] = self:_stateBlock(T("Searching…"), T("Waiting for search results."), {}, { top = 100 })
        elseif self.search_error then
            local heading, message = Model.error(self.search_error)
            rows[#rows + 1] = self:_stateBlock(heading, message, {
                { text = T("Retry search"), primary = true, callback = function() if current() then self:_runSearch(self.query) end end },
            }, { top = 100 })
        elseif #results == 0 then
            rows[#rows + 1] = self:_stateBlock(string.format(T("No results for “%s”"), self.query),
                self.filter ~= "all" and T("Try another filter or return to all results.") or T("Try a shorter title or an author name."), {
                    { text = self.filter ~= "all" and T("Clear filter") or T("Change search"), primary = true, callback = function()
                        if not current() then return end
                        if self.filter ~= "all" then self.filter, self.page = "all", 1; self:_render() else self:_editSearch() end
                    end }, { text = T("Browse Bookstore"), callback = function() if current() then self:showBookstore() end end },
                }, { top = 100 })
        else
            local header_height = W.column(copy(rows)):getSize().h
            local capacity = math.max(1, math.min(6, math.floor((self.body_height - header_height - W.dp(60)) / W.dp(130))))
            self.pages, self.page_ranges = math.max(1, math.ceil(#results / capacity)), {}
            self.page = math.max(1, math.min(self.page or 1, self.pages))
            for index = (self.page - 1) * capacity + 1, math.min(self.page * capacity, #results) do
                rows[#rows + 1] = self:_comicCard(results[index])
            end
            if self.pages > 1 then
                local width = math.floor(self.width / 3)
                local previous = W.button(T("‹ Previous page"), width, function() if current() then self:_changePage(-1) end end,
                    buttonOptions{ borderless = true, height_dp = 60, size_dp = 20, align = "left", enabled = self.page > 1 })
                local counter = W.button(string.format(T("%d / %d"), self.page, self.pages), self.width - 2 * width,
                    function() if current() then self:_jumpPage() end end, buttonOptions{ borderless = true, height_dp = 60, size_dp = 20 })
                local next_page = W.button(T("Next page ›"), width, function() if current() then self:_changePage(1) end end,
                    buttonOptions{ borderless = true, height_dp = 60, size_dp = 20, align = "right", enabled = self.page < self.pages })
                rows[#rows + 1], self.focus[#self.focus + 1] = W.row{ previous, counter, next_page }, { previous, counter, next_page }
                self.pagination = { previous = previous, counter = counter, next = next_page }
            end
            return W.column(rows)
        end
    end
    self.pages, self.page, self.page_ranges = 1, 1, {}
    return W.column(rows)
end

function Screens:_lookupComicID()
    self:_closeDialog()
    local dialog
    dialog = InputDialog:new{ title = T("Open by comic ID"), input = "", input_hint = "mc12345", modal = true,
        description = T("Enter a positive comic ID, such as mc12345."),
        buttons = { { { text = T("Cancel"), callback = function() self:_closeDialog() end },
            { text = T("Open comic"), is_enter_default = true, callback = function()
                local value = dialog:getInputText()
                self:_closeDialog()
                self.lookup_sequence = (self.lookup_sequence or 0) + 1
                local sequence = self.lookup_sequence
                self:_invoke("lookupComicID", { value }, function(detail, error)
                    if sequence ~= self.lookup_sequence then return end
                    if error then self:_error(error); return end
                    if detail and detail.comic and detail.comic.id then
                        self.loaded["comic:" .. tostring(detail.comic.id)] = true
                        self:showComic(detail.comic.id)
                    end
                end)
            end } } } }
    self.dialog = dialog; UIManager:show(dialog); dialog:onShowKeyboard()
end

require("bilicomics/ui/catalog_screens")(Screens)
require("bilicomics/ui/downloads_screens")(Screens)
require("bilicomics/ui/account_screens")(Screens)
require("bilicomics/ui/recharge_screens")(Screens)
require("bilicomics/ui/purchase_screens")(Screens)

return Screens
