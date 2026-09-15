local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local FileChooser = require("ui/widget/filechooser")
local SessionInput = require("bilicomics/ui/session_input")
local QRLogin = require("bilicomics/ui/qr_login")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local W = require("bilicomics/ui/widgets")
local Model = require("bilicomics/ui/model")
local T = require("bilicomics/ui/i18n")
local Screens = {}
Screens.__index = Screens

local function title(record) return record.title or record.short_title or tostring(record.id or "") end
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

function Screens:_showContextDialog(heading, buttons, on_dismiss)
    local dirty = self.context_dialog_dirty
    self:_closeDialog()
    local owner, epoch, key = self, self.epoch, accountKey(self.controller)
    local dialog = ButtonDialog:new{ title = heading, buttons = buttons, modal = true, width_factor = 0.94, rows_per_page = 8 }
    function dialog:onCloseWidget()
        ButtonDialog.onCloseWidget(self)
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
    for _index, card in ipairs(self.cards or {}) do
        if tostring(card.comic.id) == self.bookshelf_focused_comic_id then return card.comic end
    end
    return self.cards and self.cards[1] and self.cards[1].comic
end

function Screens:_more()
    local epoch, key = self.epoch, accountKey(self.controller)
    local dialog
    local function current() return self.dialog == dialog and self.epoch == epoch and accountKey(self.controller) == key end
    local buttons, heading = {}, T("More")
    if self.route == "favorites" then
        local sync, comic = self:_bookshelfSyncState(), self:_selectedBookshelfComic()
        self:_saveBookshelfView()
        local timestamp = tonumber(sync.last_synced_at)
        heading = T("Bookshelf") .. "\n" .. (timestamp and timestamp > 0
            and string.format(T("Last synced: %s"), os.date("%Y-%m-%d %H:%M", timestamp)) or T("Not synced yet"))
        if sync.syncing then heading = heading .. "\n" .. T("Syncing bookshelf…") end
        if sync.error then heading = heading .. "\n" .. Model.error(sync.error) end
        if sync.authenticated == false then heading = heading .. "\n" .. T("Sign in to sync your bookshelf.")
        elseif sync.offline then heading = heading .. "\n" .. T("Connect, then retry bookshelf sync.")
        elseif not sync.can_sync then heading = heading .. "\n" .. T("Bookshelf sync is temporarily unavailable.") end
        if comic then heading = heading .. "\n" .. string.format(T("Selected: %s"), title(comic)) end
        buttons[#buttons + 1] = { { text = T("Refresh bookshelf"), enabled = sync.can_sync == true and not sync.syncing,
            callback = function() if current() then self:_closeDialog(); self:_syncBookshelf(true) end end } }
        buttons[#buttons + 1] = { { text = T("Filter bookshelf"), callback = function() if current() then self:_bookshelfFilter() end end } }
        buttons[#buttons + 1] = { { text = T("Sort bookshelf"), callback = function() if current() then self:_bookshelfSort() end end } }
        buttons[#buttons + 1] = { { text = T("Open chapter catalog"), enabled = comic ~= nil, callback = function()
            if current() and comic then self:showComic(comic.id) end
        end } }
    elseif self.route == "comic" then
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
    dialog = self:_showContextDialog(heading, buttons)
end

function Screens:_bookshelfSort()
    local dialog
    local choices = { { "source", T("Bookshelf order") }, { "title", T("Title") }, { "recent", T("Recently read") } }
    local buttons = {}
    for _index, choice in ipairs(choices) do
        local value = choice[1]
        buttons[#buttons + 1] = { { text = (self.bookshelf_sort == value and "[x] " or "[ ] ") .. choice[2], callback = function()
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
    self.width = Device.screen:getWidth() - W.scale(28)
    self.height = Device.screen:getHeight()
    local headings = { bookstore = T("Bookstore"), favorites = T("Bookshelf"), comic = T("Chapters"),
        downloads = T("Downloads"), search = T("Search"), account = T("Account and settings") }
    local side_width = W.scale(78)
    local header = W.column{ W.row{
        self:_button(T("Back"), side_width, function() self:_back() end, { borderless = true, size = 16 }),
        W.text(headings[self.route], self.width - 2 * side_width, W.font.page, { bold = true, align = "center", height = W.scale(34) }),
        self:_button(T("More"), side_width, function() self:_more() end, { borderless = true, size = 16 }),
    }, W.space(6), W.rule(self.width), W.space(10) }
    local builders = { bookstore = self._bookstore, favorites = self._library, comic = self._comic,
        downloads = self._downloads, search = self._search, account = self._account }
    local navigation, navigation_buttons = W.navigation({
        { text = T("Bookshelf"), selected = self.route == "favorites", callback = function() self:showLibrary() end },
        { text = T("Bookstore"), selected = self.route == "bookstore", callback = function() self:showBookstore() end },
        { text = T("Search"), selected = self.route == "search", callback = function() self:showSearch() end },
        { text = T("Downloads"), selected = self.route == "downloads", callback = function() self:showDownloads() end },
    }, self.width)
    self.body_height = self.height - header:getSize().h - navigation:getSize().h - W.scale(16)
    local body = builders[self.route](self)
    self.navigation_buttons = navigation_buttons
    self.focus[#self.focus + 1] = navigation_buttons
    local content = W.column{ header, body }
    local filler = self.height - content:getSize().h - navigation:getSize().h - W.scale(16)
    content[#content + 1] = W.spacePixels(math.max(0, filler))
    content[#content + 1] = navigation
    content:resetLayout()
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
    local cover_width, cover_height = W.scale(46), W.scale(62)
    local text_width = self.width - cover_width - W.scale(14)
    local subtitle = comic.latest_episode_title or (comic.extra or {}).latest_episode_title
        or (comic.latest_order and string.format(T("Latest chapter: %s"), tostring(comic.latest_order))) or T("Open chapter catalog")
    local authors = type(comic.authors) == "table" and comic.authors[1] or comic.authors
    if type(authors) == "table" then authors = authors.name end
    local metadata = type(authors) == "string" and authors ~= "" and authors .. " · " .. subtitle or subtitle
    local cover = measure and W.space(62) or W.cover(comic, cover_width, cover_height)
    local content = W.column{ W.row{ cover, W.gap(W.scale(12)), W.column{
        W.text(title(comic), text_width, W.font.item, { bold = true, height = W.scale(42), fixed_height = true }),
        W.space(3), W.text(metadata, text_width, W.font.meta, { muted = true, height = W.scale(32), fixed_height = true }),
    } }, W.space(8), W.rule(self.width), W.space(5) }
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
        rows[#rows + 1] = { { text = (self.filter == key and "[x] " or "[ ] ") .. option[2], callback = function()
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

function Screens:_bookshelf(items)
    local entries = {}
    for _, comic in ipairs(items) do
        local episodes = Model.array(self.controller:getEpisodes(comic.id))
        local progress = Model.comicProgress(comic, episodes)
        local updated = comic.updated or comic.has_update or (comic.extra or {}).has_update
        if self.filter == "all" or self.filter == progress.state
            or self.filter == "updated" and updated or self.filter == "completed" and comic.finished then
            entries[#entries + 1] = { comic = comic, progress = progress, updated = not not updated }
        end
    end
    local rows = {}
    local sync = self:_bookshelfSyncState()
    local message = self.status or (sync.syncing and T("Syncing bookshelf…"))
        or (sync.error and #items > 0 and T("Could not sync. Saved comics are still available."))
    if message and #items > 0 then
        rows[#rows + 1] = W.text(message, self.width, 13, { muted = true, height = W.scale(24) })
    end
    local empty
    if self.filter ~= "all" then empty = T("No comics match this filter.")
    elseif sync.syncing then empty = T("Loading your bookshelf…")
    elseif not sync.has_cache then
        if sync.authenticated == false then empty = T("Sign in to load your bookshelf.")
        elseif sync.offline then empty = T("Connect, then retry bookshelf sync.")
        elseif not sync.can_sync then empty = T("Bookshelf sync is temporarily unavailable.")
        else empty = T("Your bookshelf has not been synced yet.") end
    else empty = T("Your bookshelf is empty. Find a comic in Bookstore or Search.") end
    local body = self:_coverGrid(entries, { rows = rows, bookshelf = true, hint = "", empty_message = empty })
    if #entries == 0 and self.filter == "all" then
        local action
        if sync.authenticated == false then action = self:_button(T("Sign in with QR code"), self.width, function() self:showAccount(); self:_signInWithQR() end)
        elseif not sync.has_cache and not sync.syncing then action = self:_button(T("Retry sync"), self.width,
            function() self:_syncBookshelf(true) end, { enabled = sync.can_sync == true }) end
        if action then body[#body + 1] = W.space(8); body[#body + 1] = action; body:resetLayout() end
    end
    return body
end

function Screens:_bookshelfToolbar(pagination, current)
    local labels = { all = T("All"), reading = T("Currently reading"), unknown = T("No reading record"),
        updated = T("Updated"), completed = T("Completed series") }
    local sorts = { source = T("Bookshelf order"), title = T("Title"), recent = T("Recently read") }
    local pager_width = pagination and pagination.previous:getSize().w + pagination.counter:getSize().w
        + pagination.next:getSize().w + W.scale(8) or 0
    local filter_width = math.floor((self.width - pager_width) / 2)
    local sort_width = self.width - pager_width - filter_width
    local filter = W.button((labels[self.filter] or labels.all) .. " ▾", filter_width,
        function() if current() then self:_bookshelfFilter() end end,
        { borderless = true, size = W.font.meta, height = 28, align = "left" })
    local sort = W.button((sorts[self.bookshelf_sort] or sorts.source) .. " ▾", sort_width,
        function() if current() then self:_bookshelfSort() end end,
        { borderless = true, size = W.font.meta, height = 28, align = "left" })
    local widgets, focus = { filter, sort }, { filter, sort }
    if pagination then
        widgets[#widgets + 1] = W.gap(W.scale(8))
        for _, button in ipairs({ pagination.previous, pagination.counter, pagination.next }) do
            widgets[#widgets + 1], focus[#focus + 1] = button, button
        end
    end
    self.bookshelf_filter_button, self.bookshelf_sort_button = filter, sort
    self.bookshelf_toolbar_buttons = focus
    self.bookshelf_toolbar = W.row(widgets)
    self.focus[#self.focus + 1] = focus
    return self.bookshelf_toolbar
end

function Screens:_bookshelfProgress(progress)
    if not progress then return "" end
    local episode = progress.current_episode or {}
    local number = tonumber(episode.short_title) or tonumber(episode.order)
    if not number or number <= 0 or number ~= number or number == math.huge then return progress.label end
    local chapter = string.format(T("Ch. %s"), tostring(number))
    if progress.page and progress.total_pages then
        return chapter .. " · " .. string.format("%d/%d", progress.page, progress.total_pages)
    elseif progress.page then
        return chapter .. " · " .. string.format(T("Page %d"), progress.page)
    end
    return chapter
end

function Screens:_coverGrid(entries, options)
    options = options or {}
    local gap = W.scale(12)
    local screen_width = Device.screen:getWidth()
    local columns = screen_width >= 720 and 3 or 2
    if options.bookshelf then columns = screen_width >= 900 and 4 or screen_width >= 600 and 3 or 2 end
    if options.bookstore then columns = screen_width >= 900 and 4 or screen_width >= 600 and 3 or 2 end
    local width = math.floor((self.width - gap * (columns - 1)) / columns)
    local probe_height = W.scale(80)
    local probe = W.CoverCard:new{ comic = {}, text = "", progress = "", update = "", width = width,
        cover_height = probe_height, compact = options.bookstore, bookshelf = options.bookshelf }
    local metadata_height = probe:getSize().h - probe_height
    if probe.free then probe:free() end
    local available = self.body_height - W.column(copy(options.rows or {})):getSize().h - W.scale(42)
    local cover_height = math.floor((width - W.scale(12)) * 1.34)
    local row_height = cover_height + metadata_height
    local row_count = math.max(1, math.floor((available + gap) / (row_height + gap)))
    if options.bookshelf then
        row_count = available >= 2 * (metadata_height + W.scale(70)) + gap and 2 or 1
    end
    if options.bookstore then
        row_count = available >= 2 * (metadata_height + W.scale(80)) + gap and 2 or 1
        if Device.screen:getWidth() > Device.screen:getHeight() then row_count = 1 end
    end
    local capacity = columns * row_count
    if options.bookshelf then
        if self.bookshelf_restore_focus or self.bookshelf_grid_capacity and self.bookshelf_grid_capacity ~= capacity then
            for index, entry in ipairs(entries) do
                if tostring(entry.comic.id) == self.bookshelf_focused_comic_id then self.page = math.ceil(index / capacity); break end
            end
        end
        self.bookshelf_restore_focus, self.bookshelf_grid_capacity = nil, capacity
    end
    self.pages = math.max(1, math.ceil(#entries / capacity))
    self.page = math.max(1, math.min(self.page, self.pages))
    local rows = options.rows or {}
    local hint = options.hint or T("Tap to read · Hold for chapters")
    local epoch, key, render_generation = self.epoch, accountKey(self.controller), self.render_generation
    local route, query_key = self.route, bookstoreQueryKey(options.query)
    local function currentGrid()
        return self.route == route and self.epoch == epoch and accountKey(self.controller) == key
            and self.render_generation == render_generation
            and (not options.bookstore or bookstoreQueryKey(self.bookstore_query) == query_key)
    end
    if self.pages > 1 or options.can_load_more then
        local arrow_width, counter_width = W.scale(options.bookshelf and 30 or 36), W.scale(64)
        local previous = W.button("‹", arrow_width, function() if currentGrid() then self:_changePage(-1) end end,
            { borderless = true, size = options.bookshelf and 18 or 22, height = options.bookshelf and 28 or 24, enabled = self.page > 1 })
        local next_page = W.button("›", arrow_width, function() if currentGrid() then self:_changePage(1) end end,
            { borderless = true, size = options.bookshelf and 18 or 22, height = options.bookshelf and 28 or 24,
                enabled = self.page < self.pages or options.can_load_more == true and not self.bookstore_loading })
        local page_label = options.remote_pagination and string.format(T("Page %d"), self.page)
            or string.format(T("%d / %d"), self.page, self.pages)
        local counter = W.button(page_label, counter_width, function() if currentGrid() then self:_jumpPage() end end,
            { borderless = true, size = W.font.meta, height = options.bookshelf and 28 or 24 })
        local hint_width = self.width - 2 * arrow_width - counter_width - W.scale(8)
        self.pagination = { previous = previous, next = next_page, counter = counter }
        if not options.bookshelf then
            rows[#rows + 1] = W.row{
                hint ~= "" and W.text(hint, hint_width, 12, { muted = true, height = W.scale(20) }) or W.gap(hint_width),
                W.gap(W.scale(8)), previous, counter, next_page,
            }
            self.focus[#self.focus + 1] = { previous, counter, next_page }
        end
    elseif hint ~= "" then
        rows[#rows + 1] = W.text(hint, self.width, 12,
            { muted = true, height = W.scale(20) })
    end
    if options.bookshelf then table.insert(rows, 1, self:_bookshelfToolbar(self.pagination, currentGrid)) end
    rows[#rows + 1] = W.space(8)
    local grid_height = self.body_height - W.column(copy(rows)):getSize().h - W.scale(2)
    cover_height = math.max(W.scale(30), math.min(cover_height,
        math.floor((grid_height - gap * (row_count - 1)) / row_count) - metadata_height))
    self.cards, self.grid_columns, self.grid_rows = {}, columns, row_count
    local row, focus
    for index = (self.page - 1) * capacity + 1, math.min(self.page * capacity, #entries) do
        if not row or #focus == columns then
            if row then rows[#rows + 1] = W.row(row); rows[#rows + 1] = W.spacePixels(gap); self.focus[#self.focus + 1] = focus end
            row, focus = {}, {}
        end
        local entry = entries[index]
        local comic = entry.comic
        if options.bookstore then self.controller:requestBookstoreCover(comic.id, options.feed_identity)
        elseif self.controller.requestCover then self.controller:requestCover(comic.id) end
        local function current()
            if not currentGrid() then return false end
            return not options.bookstore or sameFeedIdentity(options.feed_identity,
                self.controller:getBookstore(self.bookstore_query).identity)
        end
        local card = W.CoverCard:new{ comic = comic, text = title(comic), width = width, cover_height = cover_height,
            compact = options.bookstore, bookshelf = options.bookshelf,
            progress = entry.description or entry.progress and entry.progress.label or "",
            progress_label = options.bookshelf and self:_bookshelfProgress(entry.progress) or nil,
            updated = options.bookshelf and entry.updated or false,
            update = options.bookstore and (entry.tags or "") or Model.comicUpdate(comic),
            callback = function()
                if not current() then return end
                self.focused_comic_id = tostring(comic.id)
                if options.bookshelf then self.bookshelf_focused_comic_id = tostring(comic.id) end
                if options.bookstore then self:showComic(comic.id) else self:_readComic(comic) end
            end,
            hold_callback = function()
                if not current() then return end
                if options.bookstore then self:_bookstoreSynopsis(comic) else self:showComic(comic.id) end
            end,
            focus_callback = function(focused)
                if options.bookshelf and current() then self.bookshelf_focused_comic_id = tostring(focused.id) end
            end }
        if #row > 0 then row[#row + 1] = W.gap(gap) end
        row[#row + 1], focus[#focus + 1], self.cards[#self.cards + 1] = card, card, card
    end
    if row then rows[#rows + 1] = W.row(row); self.focus[#self.focus + 1] = focus end
    if options.bookshelf and #self.cards > 0 then
        local found = false
        for _index, card in ipairs(self.cards) do if tostring(card.comic.id) == self.bookshelf_focused_comic_id then found = true end end
        if not found then self.bookshelf_focused_comic_id = tostring(self.cards[1].comic.id) end
    end
    if #entries == 0 then
        rows[#rows + 1] = W.text(options.empty_message or T("No recommendations are available."), self.width, 18,
            { height = W.scale(80) })
        if options.retry then
            rows[#rows + 1] = self:_button(T("Retry"), W.scale(130), function() self:_refreshBookstore() end)
        end
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
    local heading = T("Choose a category")
    if state.loading then heading = heading .. "\n" .. T("Loading categories…")
    elseif state.error then
        heading = heading .. "\n" .. (#catalogue.items > 0 and T("Could not update categories. Choose a saved category.")
            or T("Categories could not be loaded. Retry to choose a category."))
    end
    local dialog
    local function current()
        return self.dialog == dialog and self.bookstore_picker == dialog and self.bookstore_picker_state == state
            and self.route == "bookstore" and self.epoch == state.epoch and accountKey(self.controller) == state.account
    end
    local buttons = { { { text = (self.bookstore_query and "[ ] " or "[x] ") .. T("All recommendations"),
        callback = function() if current() then self:_selectBookstoreCategory(nil) end end } } }
    local row
    for index, category in ipairs(catalogue.items) do
        if (index - 1) % 3 == 0 then row = {}; buttons[#buttons + 1] = row end
        local selected = self.bookstore_query and tostring(category.id) == self.bookstore_query.category_id
        row[#row + 1] = { text = (selected and "[x] " or "[ ] ") .. category.name,
            callback = function() if current() then self:_selectBookstoreCategory(category) end end }
    end
    if state.error then
        buttons[#buttons + 1] = { { text = T("Retry"), callback = function()
            if current() then self:_refreshBookstoreCategories(state) end
        end } }
    end
    buttons[#buttons + 1] = { { text = T("Cancel"), callback = function() if current() then dialog:onClose() end end } }
    dialog = ButtonDialog:new{ title = heading, buttons = buttons, modal = true, width_factor = 0.94, rows_per_page = 8 }
    local owner = self
    function dialog:onCloseWidget()
        ButtonDialog.onCloseWidget(self)
        if owner.bookstore_picker ~= self then return end
        local dirty = owner.bookstore_picker_dirty
        owner.bookstore_picker, owner.bookstore_picker_state, owner.bookstore_picker_dirty = nil, nil, nil
        if owner.dialog == self then owner.dialog = nil end
        if dirty and owner.route == "bookstore" then owner:_render() end
    end
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
    local sections = { recommendation = T("Recommended"), hot_seller = T("Bestsellers"),
        internet_hot = T("Trending"), completed = T("Completed picks") }
    for _index, comic in ipairs(Model.array(feed.items)) do
        local extra, tags = comic.extra or {}, {}
        for _tag_index, tag in ipairs(extra.tags or {}) do if type(tag) == "string" then tags[#tags + 1] = tag end end
        local section = query and category_name or sections[extra.recommendation_section] or T("Recommended")
        local caption = section
        if #tags > 0 and tags[1] ~= section then caption = caption .. " · " .. tags[1] end
        if query and #tags > 0 then caption = tags[1] end
        entries[#entries + 1] = { comic = comic, description = extra.recommendation or extra.evaluate or "", tags = caption }
    end
    local epoch, generation, key = self.epoch, self.render_generation, accountKey(self.controller)
    local query_key = bookstoreQueryKey(query)
    local function current()
        return self.route == "bookstore" and self.epoch == epoch and self.render_generation == generation
            and accountKey(self.controller) == key and bookstoreQueryKey(self.bookstore_query) == query_key
    end
    local category_width, refresh_width = math.floor(self.width * 0.43), W.scale(88)
    self.bookstore_category_button = W.button((query and category_name or T("All recommendations")) .. " ▾",
        category_width, function() if current() then self:_bookstoreCategoryPicker() end end,
        { borderless = true, size = 16, bold = true, align = "left" })
    local refresh = W.button(T("Refresh"), refresh_width, function() if current() then self:_refreshBookstore() end end,
        { borderless = true, size = 15, enabled = not self.bookstore_loading })
    local count_label = string.format(query and T("Loaded: %d comics") or T("%d comics"), #entries)
    local rows = { W.row{ self.bookstore_category_button,
        W.text(count_label, self.width - category_width - refresh_width, 14, { muted = true, align = "center" }), refresh }, W.space(8) }
    self.focus[#self.focus + 1] = { self.bookstore_category_button, refresh }
    local offset = 76
    if self.bookstore_error and #entries > 0 then
        local message = self.bookstore_more_error and T("Could not load more. Tap the next arrow to retry.")
            or query and T("Could not refresh. Showing saved comics.") or T("Could not refresh. Showing saved recommendations.")
        rows[#rows + 1] = W.text(message, self.width, 13,
            { muted = true, height = W.scale(30) })
        offset = offset + 30
    elseif self.bookstore_loading and #entries > 0 then
        local message = self.bookstore_loading_more and T("Loading more comics…")
            or query and T("Refreshing comics…") or T("Refreshing recommendations…")
        rows[#rows + 1] = W.text(message, self.width, 13,
            { muted = true, height = W.scale(24) })
        offset = offset + 24
    elseif query and feed.limit_reached then
        rows[#rows + 1] = W.text(T("Browsing limit reached. Use Search to find more comics."), self.width, 13,
            { muted = true, height = W.scale(30) })
        offset = offset + 30
    elseif query and #entries > 0 and (feed.loaded_pages or 0) > 0 and feed.has_more == false then
        rows[#rows + 1] = W.text(T("All available comics are loaded."), self.width, 13,
            { muted = true, height = W.scale(24) })
        offset = offset + 24
    end
    local empty = query and T("No comics are available in this category.") or T("No recommendations are available.")
    if self.bookstore_loading then empty = query and T("Loading comics…") or T("Loading recommendations…")
    elseif self.bookstore_error then
        if query then empty = self.bookstore_error.kind == "network" and T("Connect to load this category.")
            or T("This category could not be loaded. Try again.")
        else empty = self.bookstore_error.kind == "network" and T("Connect to load recommendations.")
            or T("Recommendations could not be loaded. Try again.") end
    end
    return self:_coverGrid(entries, { rows = rows, bookstore = true, fixed_height = offset,
        hint = T("Tap: chapters · Hold: synopsis"), empty_message = empty, retry = self.bookstore_error and not self.bookstore_loading,
        query = query, feed_identity = feed.identity, can_load_more = feed.can_load_more == true, remote_pagination = query ~= nil })
end

function Screens:_bookstoreSynopsis(comic)
    self:_closeDialog()
    local extra = comic.extra or {}
    local dialog
    dialog = TextViewer:new{ title = title(comic),
        text = extra.recommendation or extra.evaluate or T("No synopsis is available."), modal = true,
        close_callback = function()
            if self.bookstore_synopsis ~= dialog then return end
            local dirty = self.bookstore_synopsis_dirty
            self.bookstore_synopsis, self.bookstore_synopsis_dirty = nil, nil
            if self.dialog == dialog then self.dialog = nil end
            if dirty and self.route == "bookstore" then self:_render() end
        end }
    self.dialog, self.bookstore_synopsis = dialog, dialog
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
    dialog = InputDialog:new{ title = T("Search comics"), input = self.query, input_hint = T("Title or author"), modal = true,
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

function Screens:_search()
    self.search_cards = {}
    local rows = { self:_button(self.query ~= "" and self.query or T("Search by title or author"), self.width,
        function() self:_editSearch() end, { align = "left", size = W.font.item, height = 36 }), W.space(4),
        self:_buttons{
            { text = T("Open by comic ID"), callback = function() self:_lookupComicID() end,
                borderless = true, size = W.font.meta, align = "left" },
            { text = self.query ~= "" and T("Clear search") or T("Bookstore"), borderless = true, size = W.font.meta,
                callback = function() if self.query ~= "" then self:_searchHome() else self:showBookstore() end end },
        }, W.space(12) }
    if self.query == "" then
        local history = self.controller:getSetting("search_history", {})
        if #history == 0 then
            rows[#rows + 1] = W.text(T("Find your next comic"), self.width, W.font.title, { bold = true })
            rows[#rows + 1] = W.space(8)
            rows[#rows + 1] = W.text(T("Search by title or author, or browse Bookstore."), self.width, W.font.body)
        else
            local clear_width = W.scale(155)
            rows[#rows + 1] = W.row{ W.text(T("Recent searches"), self.width - clear_width, W.font.item, { bold = true }),
                self:_button(T("Clear history"), clear_width, function()
                    local _, error = self.controller:setSetting("search_history", {})
                    if error then self:_error(error) else self:_render() end
                end, { borderless = true, size = W.font.meta, align = "right" }) }
            rows[#rows + 1] = W.space(8)
            for index, query in ipairs(history) do
                if index > 5 then break end
                rows[#rows + 1] = self:_button(query, self.width, function() self:_runSearch(query) end,
                    { align = "left", borderless = true, size = W.font.body })
            end
        end
    else
        local results = {}
        for _, comic in ipairs(self.search_results or {}) do
            if self.filter == "all" or self.filter == "completed" and comic.finished
                or self.filter == "ongoing" and not comic.finished then results[#results + 1] = comic end
        end
        rows[#rows + 1] = self:_buttons{
            { text = ({ all = T("All"), ongoing = T("Ongoing"), completed = T("Completed") })[self.filter] .. " ▾",
                callback = function() self:_searchFilter() end, borderless = true, size = W.font.meta, align = "left" },
            { text = T("Change search"), callback = function() self:_editSearch() end, borderless = true, size = W.font.meta },
        }
        rows[#rows + 1] = W.space(8)
        if self.status then
            rows[#rows + 1] = W.text(T("Searching…"), self.width, W.font.item, { bold = true })
            rows[#rows + 1] = W.space(8)
            rows[#rows + 1] = W.text(T("Waiting for search results."), self.width, W.font.body)
        elseif self.search_error then
            local heading, message = Model.error(self.search_error)
            rows[#rows + 1] = W.text(heading, self.width, W.font.item, { bold = true })
            rows[#rows + 1] = W.space(8)
            rows[#rows + 1] = W.text(message, self.width, W.font.body)
            rows[#rows + 1] = W.space(12)
            rows[#rows + 1] = self:_button(T("Retry search"), self.width, function() self:_runSearch(self.query) end, { primary = true })
        elseif #results == 0 then
            rows[#rows + 1] = W.text(T("No matching comics"), self.width, W.font.item, { bold = true })
            rows[#rows + 1] = W.space(8)
            rows[#rows + 1] = W.text(self.filter ~= "all" and T("Try another filter or return to all results.")
                or T("Try a shorter title or an author name."), self.width, W.font.body)
            rows[#rows + 1] = W.space(12)
            rows[#rows + 1] = self:_button(self.filter ~= "all" and T("Clear filter") or T("Change search"), self.width,
                function() if self.filter ~= "all" then self.filter, self.page = "all", 1; self:_render() else self:_editSearch() end end,
                { primary = true })
        else
            rows[#rows + 1] = W.text(string.format(T("%d results"), #results), self.width, W.font.meta, { muted = true })
            rows[#rows + 1] = W.space(8)
            local header = W.column(rows)
            local function rowHeight(comic)
                local row = self:_comicCard(comic, true)
                local height = row:getSize().h
                if row.free then row:free() end
                return height
            end
            return W.column{ header, self:_paginate(results, rowHeight, header:getSize().h,
                function(comic) return self:_comicCard(comic) end, false) }
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
