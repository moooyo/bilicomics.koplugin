local InputDialog = require("ui/widget/inputdialog")
local BB = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local W = require("bilicomics/ui/widgets")
local Model = require("bilicomics/ui/model")
local Helpers = require("bilicomics/ui/screen_helpers")
local T = require("bilicomics/ui/i18n")
local title, count, copy, accountKey = Helpers.title, Helpers.count, Helpers.copy, Helpers.accountKey

local function space(value) return W.spacePixels(W.dp(value)) end
local function text(value, width, size, options) return W.text(value, width, W.fontSize(size), options) end
local function lineText(value, width, size, height, options)
    options = options or {}
    options.height = W.dp(height)
    return W.line(value, width, W.fontSize(size), options)
end
local function button(value, width, callback, options)
    options = options or {}
    options.size, options.height_px = W.fontSize(options.size or 21), W.dp(options.height or 62)
    return W.button(value, width, callback, options)
end

local function chapterNumber(episode)
    return tostring(tonumber(episode.short_title) or tonumber(episode.order) or episode.short_title or "—")
end

local function selectable(episode)
    return Model.downloadable(episode) and Model.storage(episode) ~= T("Downloaded")
end

local function readingLabel(episode, current)
    local state = Model.reading(episode, current)
    return state == T("Read") and T("Already read") or state
end

local function chapterPrice(episode)
    local amount = tonumber(episode.pay_gold)
    if amount and amount == amount and amount >= 0 and amount < math.huge then
        return string.format(T("%s comic coins"), tostring(amount))
    end
    return T("Locked")
end

local function accessLabel(episode)
    if episode.access == "locked" then return chapterPrice(episode) end
    if episode.access == "temporary" then
        if Model.entitlementExpiry(episode) == T("Temporary access expiry is unknown.") then return T("Limited · Expiry unknown") end
        local expiry, now = episode.expires_at, os.time()
        if expiry <= now then return T("Limited access expired") end
        return string.format(T("Limited %d days"), math.max(1, math.ceil((expiry - now) / 86400)))
    end
    return Model.entitlement(episode)
end

local function tagsOf(comic)
    local extra, result = comic.extra or {}, {}
    local source = comic.tags or extra.tags or extra.styles or extra.style
    if type(source) == "table" then
        for _, item in ipairs(source) do
            local label = type(item) == "table" and (item.name or item.title) or item
            if type(label) == "string" and label ~= "" then result[#result + 1] = label end
        end
    elseif type(source) == "string" and source ~= "" then result[1] = source end
    return result
end

local function synopsisPages(value, width, height)
    local measurement = text("", width, 20, { height = height, fixed_height = true, line_height = 0.75 })
    local columns = math.max(1, math.floor(width / measurement.face.size))
    local lines = math.max(1, math.floor(height / measurement.line_height_px))
    measurement:free()
    local pages, buffer, used, line = {}, {}, 0, 1
    for character in tostring(value):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if character == "\n" or used >= columns then
            line, used = line + 1, 0
            if line > lines then
                pages[#pages + 1], buffer, line = table.concat(buffer), {}, 1
                if character == "\n" then character = "" end
            end
        end
        buffer[#buffer + 1] = character
        if character ~= "\n" and character ~= "" then used = used + 1 end
    end
    if #buffer > 0 or #pages == 0 then pages[#pages + 1] = table.concat(buffer) end
    return pages
end

local CatalogRow = W.ActionRow:extend{}
function CatalogRow:paintTo(bb, x, y)
    W.ActionRow.paintTo(self, bb, x, y)
    if self.current_marker then bb:paintRect(x - W.dp(56), y, W.dp(10), self:getSize().h + W.dp(1), W.ink) end
end

local CatalogJumpDialog = InputDialog:extend{}
function CatalogJumpDialog:init()
    self._closing = false
    InputDialog.init(self)
    local native_title = self.title_bar
    local padding = W.dp(32)
    local width = self.width - 2 * padding
    self.title_bar = W.column{
        lineText(self.title, width, 26, 34, { bold = true }), space(8),
        text(self.description or "", width, 17, { muted = true, line_height = 0.4 }), space(22),
    }
    self._input_widget.bordersize, self._input_widget._frame_textwidget.bordersize = 0, 0
    self._input_widget._frame_textwidget.color = W.ink
    self._input_widget.dimen = self._input_widget._frame:getSize()
    self.input_field = W.box(W.inset(self._input_widget, W.dp(20), W.dp(20), 0, 0), width, W.dp(70),
        { border_px = W.dp(1.5), align = "left", color = W.ink })
    self.dialog_frame.radius, self.dialog_frame.color = 0, W.ink
    self[1] = self.dialog_frame
    self.ges_events.SwipePage = { GestureRange:new{ ges = "swipe",
        range = Geom:new{ w = self.screen_width, h = self.screen_height } } }
    if Device:hasKeys() then
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PreviousPage = { { Device.input.group.PgBack } }
    end
    native_title:free()
    self:refreshResults()
end

function CatalogJumpDialog:refreshResults()
    if not self.input_field or self._closing then return end
    if self.results_content then self.results_content:free() end
    local content, focus = self.build_results(self)
    self.results_content = content
    self.vgroup = W.inset(W.column{ self.title_bar, self.input_field, content }, W.dp(32), W.dp(32), W.dp(30), W.dp(32))
    self.dialog_frame[1] = self.vgroup
    self.layout = { { self._input_widget } }
    for _, row in ipairs(focus) do self.layout[#self.layout + 1] = row end
    UIManager:setDirty(self, "ui")
end

function CatalogJumpDialog:paintTo(bb, _x, _y)
    local size = self.dialog_frame:getSize()
    local keyboard_height = self:isKeyboardVisible() and self._input_widget:getKeyboardDimen().h or 0
    local top = math.max(0, math.min(W.dp(176), Device.screen:getHeight() - keyboard_height - size.h))
    self.dialog_frame:paintTo(bb, math.floor((Device.screen:getWidth() - size.w) / 2), top)
end

function CatalogJumpDialog:onShowKeyboard(...)
    InputDialog.onShowKeyboard(self, ...)
    self:refreshResults()
end

function CatalogJumpDialog:onCloseKeyboard()
    InputDialog.onCloseKeyboard(self)
    self:refreshResults()
end

function CatalogJumpDialog:onClose()
    self._closing = true
    return InputDialog.onClose(self)
end

function CatalogJumpDialog:onCloseDialog()
    if self.dismiss_callback then self.dismiss_callback() end
    return true
end

function CatalogJumpDialog:onNextPage()
    if self.turn_results then self.turn_results(1) end
    return true
end

function CatalogJumpDialog:onPreviousPage()
    if self.turn_results then self.turn_results(-1) end
    return true
end

function CatalogJumpDialog:onSwipePage(_, gesture)
    if gesture.direction == "west" or gesture.direction == "north" then return self:onNextPage() end
    if gesture.direction == "east" or gesture.direction == "south" then return self:onPreviousPage() end
    return true
end

local function authorsOf(comic)
    if type(comic.authors) == "table" then
        local names = {}
        for _, author in ipairs(comic.authors) do
            local name = type(author) == "table" and (author.name or author.author_name) or author
            if type(name) == "string" and name ~= "" then names[#names + 1] = name end
        end
        return table.concat(names, ", ")
    end
    return type(comic.authors) == "string" and comic.authors or ""
end

local function synopsisOf(comic)
    local extra = type(comic.extra) == "table" and comic.extra or {}
    for _, value in ipairs({ comic.description or false, comic.synopsis or false, extra.evaluate or false,
        extra.description or false, extra.synopsis or false, extra.recommendation or false }) do
        if type(value) == "string" and value:find("%S") then return value end
    end
    return T("No synopsis is available.")
end

return function(Screens)

function Screens:_catalogContext()
    return { epoch = self.epoch, comic_id = tostring(self.comic_id), account = accountKey(self.controller),
        generation = self.controller.generation }
end

function Screens:_catalogCurrent(context)
    return self.route == "comic" and tostring(self.comic_id) == context.comic_id and self.epoch == context.epoch
        and accountKey(self.controller) == context.account and self.controller.generation == context.generation
end

function Screens:_read(comic, episode)
    if not Model.readable(episode) and Model.storage(episode) ~= T("Downloaded") then
        if episode.access == "locked" then self:_purchaseFor(comic, episode)
        else self:_error({ kind = "access" }) end
        return
    end
    local intent = self:_rememberReaderReturn(comic.id)
    self:_saveBookshelfView()
    self:_invoke("readEpisode", { tostring(comic.id), tostring(episode.id) }, function(_value, error)
        if error then self:_clearReaderReturn(intent); self:_error(error)
        else intent.ready = true; self:close(true) end
    end)
end

function Screens:_catalogSheet(content, focus, context, options)
    self:_closeDialog()
    local dialog
    options = options or {}
    options.width, options.placement = Device.screen:getWidth(), "bottom"
    options.close_callback = function() if self.dialog == dialog then self:_closeDialog() end end
    dialog = W.sheetDialog(content, focus, options)
    self.dialog, self.context_dialog, self.context_dialog_account = dialog, dialog, context.account
    UIManager:show(dialog)
    return dialog
end

function Screens:_catalogDetails(comic, page)
    local context = self:_catalogContext()
    local width, gap = Device.screen:getWidth() - W.dp(112), W.dp(28)
    local cover_width, cover_height = W.dp(150), W.dp(200)
    local identity_width, author = width - cover_width - gap, authorsOf(comic)
    local metadata = author ~= "" and author or ""
    if type(comic.finished) == "boolean" then
        metadata = metadata .. (metadata ~= "" and " · " or "") .. (comic.finished and T("Completed") or T("Ongoing"))
    end
    local identity = { text(title(comic), identity_width, 34, { bold = true, height = W.dp(86) }), space(12),
        text(metadata, identity_width, 18, { muted = true, height = W.dp(54) }) }
    local chips, used = {}, 0
    for _, tag in ipairs(tagsOf(comic)) do
        local chip_width = math.min(identity_width, W.dp(28 + #tag * 8))
        if used + chip_width > identity_width then break end
        if #chips > 0 then chips[#chips + 1] = W.gap(W.dp(10)); used = used + W.dp(10) end
        chips[#chips + 1] = W.box(text(tag, chip_width - W.dp(20), 16, { align = "center" }), chip_width, W.dp(34),
            { border_px = W.dp(1.5), background = W.paper })
        used = used + chip_width
    end
    if #chips > 0 then identity[#identity + 1], identity[#identity + 2] = space(10), W.row(chips) end
    local body_height = math.max(W.dp(70), math.min(W.dp(245), Device.screen:getHeight() - W.dp(590)))
    local pages = synopsisPages(synopsisOf(comic), width, body_height)
    page = math.max(1, math.min(page or 1, #pages))
    local rows = { W.row{ W.cover(comic, cover_width, cover_height), W.gap(gap), W.column(identity) },
        space(28), text(pages[page], width, 20, { height = body_height, fixed_height = true, line_height = 0.75 }) }
    local focus = {}
    if #pages > 1 then
        local pager_width = math.floor(width / 3)
        local previous = button(T("‹ Previous page"), pager_width, function()
            if self:_catalogCurrent(context) then self:_catalogDetails(comic, page - 1) end
        end, { borderless = true, height = 54, size = 20, enabled = page > 1, align = "left" })
        local next_page = button(T("Next page ›"), pager_width, function()
            if self:_catalogCurrent(context) then self:_catalogDetails(comic, page + 1) end
        end, { borderless = true, height = 54, size = 20, enabled = page < #pages, align = "right" })
        rows[#rows + 1] = W.row{ previous, text(string.format("%d / %d", page, #pages), width - 2 * pager_width, 20,
            { align = "center", height = W.dp(54) }), next_page }
        focus[#focus + 1] = { previous, next_page }
    end
    rows[#rows + 1] = space(28)
    local close = button(T("Close"), width, function() self:_closeDialog() end, { height = 68, size = 23 })
    rows[#rows + 1], focus[#focus + 1] = close, { close }
    self:_catalogSheet(W.inset(W.column(rows), W.dp(56), W.dp(56), W.dp(38), W.dp(40)), focus, context,
        { next_page = function() if page < #pages and self:_catalogCurrent(context) then self:_catalogDetails(comic, page + 1) end end,
            previous_page = function() if page > 1 and self:_catalogCurrent(context) then self:_catalogDetails(comic, page - 1) end end })
end

function Screens:_catalogFilter()
    local context, dialog = self:_catalogContext()
    local buttons = {}
    for _, choice in ipairs({ { "all", T("All chapters") }, { "unread", T("Unread") },
        { "readable", T("Readable") }, { "downloaded", T("Downloaded") } }) do
        local value = choice[1]
        buttons[#buttons + 1] = { { text = choice[2] .. (self.filter == value and " ✓" or ""), callback = function()
            if self.dialog ~= dialog or not self:_catalogCurrent(context) then return end
            self:_closeDialog()
            self.filter, self.page, self.epoch = value, 1, self.epoch + 1
            self:_render()
        end } }
    end
    buttons[#buttons + 1] = { { text = T("Cancel"), callback = function() if self.dialog == dialog then self:_closeDialog() end end } }
    dialog = self:_showContextDialog(T("Filter chapters"), buttons)
end

function Screens:_catalogLocate(episode_id)
    self:_closeDialog()
    self.filter, self.catalog_jump_id, self.epoch = "all", tostring(episode_id), self.epoch + 1
    self.catalog_highlight_id = tostring(episode_id)
    self:_render()
end

function Screens:_catalogJump(query, page, selected_id)
    self:_closeDialog()
    local context, dialog = self:_catalogContext()
    local close_callback = function() if self.dialog == dialog then self:_closeDialog() end end
    local function build_results(owner)
        local value = owner:getInputText():match("^%s*(.-)%s*$")
        if owner.search_query ~= value then owner.search_query, owner.results_page, owner.selected_episode_id = value, 1, nil end
        local matches = {}
        if value ~= "" then
            local needle = value:lower()
            for _, episode in ipairs(self.catalog_all or {}) do
                if chapterNumber(episode):lower():find(needle, 1, true) or title(episode):lower():find(needle, 1, true) then
                    matches[#matches + 1] = episode
                end
            end
        end
        local width = owner.width - W.dp(64)
        local keyboard_height = owner:isKeyboardVisible() and owner._input_widget:getKeyboardDimen().h or 0
        local available = Device.screen:getHeight() - keyboard_height - W.dp(176) - W.dp(344)
        local per_page = math.max(1, math.min(6, math.floor(available / W.dp(82))))
        local pages = math.max(1, math.ceil(#matches / per_page))
        if owner.results_per_page ~= per_page and owner.selected_episode_id then
            for index, episode in ipairs(matches) do
                if tostring(episode.id) == owner.selected_episode_id then owner.results_page = math.ceil(index / per_page); break end
            end
        end
        owner.results_per_page = per_page
        owner.results_page = math.max(1, math.min(owner.results_page or 1, pages))
        local first = (owner.results_page - 1) * per_page + 1
        local selected
        for _, episode in ipairs(matches) do if tostring(episode.id) == owner.selected_episode_id then selected = episode end end
        if not selected then selected = matches[first]; owner.selected_episode_id = selected and tostring(selected.id) or nil end
        local rows, focus, result_rows = { space(20),
            lineText(value ~= "" and (#matches == 0 and T("No matching chapter. Try another number or title.")
                or string.format(T("Matching chapters: %d"), #matches)) or T("Enter a chapter number or title to find matches."),
                width, 16, 24, { muted = true }), space(10) }, {}, {}
        for index = first, math.min(#matches, first + per_page - 1) do
            local episode = matches[index]
            local episode_id = tostring(episode.id)
            local active = episode_id == owner.selected_episode_id
            local color, inset, gap = active and W.paper or W.ink, W.dp(22), W.dp(18)
            local status = readingLabel(episode, self.catalog_current_id) .. " · "
                .. (episode.access == "locked" and T("Pending purchase") or Model.entitlement(episode))
            local status_width = math.min(W.dp(205), math.floor(width * 0.3))
            local content = W.row{
                lineText(chapterNumber(episode), W.dp(60), 24, 36, { bold = true, color = color }), W.gap(gap),
                lineText(title(episode), math.max(1, width - 2 * inset - W.dp(60) - status_width - 2 * gap), 21, 36, { color = color }),
                W.gap(gap), lineText(status, status_width, 16, 36, { color = active and W.paper or W.muted, align = "right" }),
            }
            local result = W.ActionRow:new{ width = width,
                content = W.box(W.inset(content, inset, inset, 0, 0), width, W.dp(72),
                    { border_px = W.dp(1.5), background = active and W.ink or W.paper }),
                callback = function()
                    if self.dialog ~= owner or not self:_catalogCurrent(context) then return end
                    owner.selected_episode_id = episode_id
                    owner:onCloseKeyboard()
                end }
            result.text, result.episode, result.selected = title(episode), episode, active
            rows[#rows + 1], focus[#focus + 1], result_rows[#result_rows + 1] = result, { result }, result
            if index < math.min(#matches, first + per_page - 1) then rows[#rows + 1] = space(10) end
        end
        local function turn(delta)
            if self.dialog == owner and self:_catalogCurrent(context) and owner.results_page + delta >= 1
                and owner.results_page + delta <= pages then
                owner.results_page, owner.selected_episode_id = owner.results_page + delta, nil
                owner:refreshResults()
            end
        end
        owner.turn_results = turn
        if pages > 1 then
            rows[#rows + 1] = space(10)
            local cell_width = math.floor(width / 3)
            local previous = button(T("‹ Previous page"), cell_width, function() turn(-1) end,
                { borderless = true, height = 54, size = 20, enabled = owner.results_page > 1, align = "left" })
            local next_page = button(T("Next page ›"), cell_width, function() turn(1) end,
                { borderless = true, height = 54, size = 20, enabled = owner.results_page < pages, align = "right" })
            rows[#rows + 1] = W.row{ previous, lineText(string.format("%d / %d", owner.results_page, pages),
                width - 2 * cell_width, 20, 54, { align = "center" }), next_page }
            focus[#focus + 1] = { previous, next_page }
        end
        rows[#rows + 1] = space(26)
        local cancel_width, gap = W.dp(180), W.dp(14)
        local locate_label = selected and string.format(T("Locate chapter %s"), chapterNumber(selected)) or T("Locate chapter")
        local locate_callback = function()
            if self.dialog == owner and self:_catalogCurrent(context) and selected then self:_catalogLocate(selected.id) end
        end
        local cancel = button(T("Cancel"), cancel_width, close_callback, { height = 66, size = 21 })
        local locate = button(locate_label, width - cancel_width - gap, locate_callback,
            { height = 66, size = 22, primary = true, enabled = selected ~= nil })
        rows[#rows + 1], focus[#focus + 1] = W.row{ cancel, W.gap(gap), locate }, { cancel, locate }
        owner.result_rows, owner.locate_button = result_rows, locate
        owner.matches, owner.results_pages = matches, pages
        owner.buttons = { { { text = T("Cancel"), id = "close", callback = close_callback },
            { text = locate_label, callback = locate_callback, enabled = selected ~= nil } } }
        return W.column(rows), focus
    end
    dialog = CatalogJumpDialog:new{ title = T("Jump to chapter"), input = query or "", input_hint = T("Chapter number or title"),
        description = T("Choose a result to locate it in this catalog."), modal = true, keyboard_visible = false,
        buttons = { { { text = T("Cancel"), id = "close", callback = close_callback } } },
        width = Device.screen:getWidth() - W.dp(112) - 2 * W.dp(2),
        text_width = Device.screen:getWidth() - W.dp(112 + 4 + 64 + 40 + 3), text_height = W.dp(34),
        input_face = Font:getFace("cfont", W.fontSize(24)), border_size = W.dp(2),
        input_padding = 0, input_margin = 0, button_padding = W.dp(32), is_movable = false,
        results_page = page or 1, selected_episode_id = selected_id, search_query = query or "", build_results = build_results,
        dismiss_callback = close_callback, edited_callback = function()
            if dialog and self.dialog == dialog and self:_catalogCurrent(context) then dialog:refreshResults() end
        end,
        enter_callback = function()
            if dialog and self.dialog == dialog and self:_catalogCurrent(context) then dialog:onCloseKeyboard() end
        end }
    self.dialog, self.context_dialog, self.context_dialog_account = dialog, dialog, context.account
    UIManager:show(dialog)
end

function Screens:_catalogJumpResults(query, page, selected_id)
    self:_catalogJump(query, page, selected_id)
end

function Screens:_chapterActions(comic, episode)
    local context, dialog = self:_catalogContext()
    local readable = Model.readable(episode) or Model.storage(episode) == T("Downloaded")
    local downloadable = Model.downloadable(episode)
    local width = Device.screen:getWidth() - W.dp(112)
    local read_label = readable and T("Read chapter") or T("Review reading purchase")
    if not readable and episode.access == "locked" and chapterPrice(episode) ~= T("Locked") then
        read_label = string.format(T("Review purchase quote · %s"), chapterPrice(episode))
    end
    local read = button(read_label, width, function()
            if self.dialog ~= dialog or not self:_catalogCurrent(context) then return end
            self:_closeDialog(); self:_read(comic, episode)
        end, { primary = true, enabled = readable or episode.access == "locked", height = 68, size = 23 })
    local rows, focus = {}, { { read } }
    local number = TextWidget:new{ text = chapterNumber(episode), face = Font:getFace("cfont", W.fontSize(28)),
        bold = true, fgcolor = W.muted }
    local number_width = number:getSize().w
    rows[#rows + 1] = W.row{ W.box(number, number_width, W.dp(36)), W.gap(W.dp(18)),
        lineText(title(episode), width - number_width - W.dp(18), 28, 36, { bold = true }) }
    rows[#rows + 1] = space(8)
    local access = episode.access == "locked" and T("Pending purchase") .. " " .. chapterPrice(episode) or accessLabel(episode)
    rows[#rows + 1] = lineText(title(comic) .. " · " .. readingLabel(episode, self.catalog_current_id) .. " · "
        .. access .. " · " .. Model.storage(episode), width, 18, 24, { muted = true })
    local expiry = Model.entitlementExpiry(episode)
    if expiry then rows[#rows + 1] = text(expiry, width, 16, { muted = true, height = W.dp(42) }) end
    rows[#rows + 1], rows[#rows + 2] = space(28), read
    if downloadable or episode.access == "locked" then
        local download = button(downloadable and T("Download chapter") or T("Buy then download"), width, function()
            if self.dialog ~= dialog or not self:_catalogCurrent(context) then return end
            self:_closeDialog()
            if not downloadable then self:_purchaseFor(comic, episode, "download"); return end
            self:_invoke("downloadEpisodes", { tostring(comic.id), { tostring(episode.id) } }, function(_value, error)
                if error then self:_error(error) else self:showDownloads() end
            end)
        end, { height = 68, size = 23 })
        rows[#rows + 1], rows[#rows + 2], focus[#focus + 1] = space(12), download, { download }
    end
    local close = button(T("Close"), width, function() if self.dialog == dialog then self:_closeDialog() end end,
        { height = 68, size = 23 })
    rows[#rows + 1], rows[#rows + 2], focus[#focus + 1] = space(12), close, { close }
    dialog = self:_catalogSheet(W.inset(W.column(rows), W.dp(56), W.dp(56), W.dp(34), W.dp(40)), focus, context)
end

function Screens:_catalogSelectionMenu()
    local context, dialog = self:_catalogContext()
    local function select(items)
        if self.dialog ~= dialog or not self:_catalogCurrent(context) then return end
        for _, episode in ipairs(items or {}) do
            if selectable(episode) then self.selected[tostring(episode.id)] = true end
        end
        self:_closeDialog(); self:_render()
    end
    dialog = self:_showContextDialog(T("Selection applies across pages. Choose its scope."), {
        { { text = T("Select downloadable on this page"), callback = function() select(self.catalog_visible_items) end } },
        { { text = T("Select all downloadable matches"), callback = function() select(self.catalog_items) end } },
        { { text = T("Clear selection"), enabled = count(self.selected) > 0, callback = function()
            if self.dialog ~= dialog or not self:_catalogCurrent(context) then return end
            self.selected = {}; self:_closeDialog(); self:_render()
        end } },
        { { text = T("Review selected chapters"), enabled = count(self.selected) > 0, callback = function()
            if self.dialog == dialog and self:_catalogCurrent(context) then self:_catalogSelected() end
        end } },
        { { text = T("Close"), callback = function() if self.dialog == dialog then self:_closeDialog() end end } },
    })
end

function Screens:_catalogSelected()
    local context, dialog = self:_catalogContext()
    local buttons, selected_count = {}, 0
    for _, episode in ipairs(self.catalog_all or {}) do
        local episode_id = tostring(episode.id)
        if self.selected[episode_id] then
            selected_count = selected_count + 1
            buttons[#buttons + 1] = { { text = "✓ " .. title(episode), callback = function()
                if self.dialog ~= dialog or not self:_catalogCurrent(context) then return end
                self.selected[episode_id] = nil
                self.context_dialog_dirty = true
                self:_catalogSelected()
            end } }
        end
    end
    buttons[#buttons + 1] = { { text = T("Clear selection"), enabled = selected_count > 0, callback = function()
        if self.dialog ~= dialog or not self:_catalogCurrent(context) then return end
        self.selected = {}; self.context_dialog_dirty = true; self:_catalogSelected()
    end } }
    buttons[#buttons + 1] = { { text = T("Back to chapters"), callback = function()
        if self.dialog ~= dialog or not self:_catalogCurrent(context) then return end
        self:_closeDialog(); self:_render()
    end } }
    dialog = self:_showContextDialog(string.format(T("Selected chapters: %d"), selected_count) .. "\n"
        .. T("Tap a selected chapter to remove it from the selection."), buttons)
end

function Screens:_catalogDownloadSelection()
    if self.status then return end
    local ids = {}
    for _, episode in ipairs(self.catalog_all or {}) do
        if self.selected[tostring(episode.id)] and selectable(episode) then ids[#ids + 1] = tostring(episode.id) end
    end
    if #ids == 0 then return end
    self:_invoke("downloadEpisodes", { self.comic_id, ids }, function(_value, error)
        if error then self:_error(error) else self:showDownloads() end
    end)
end

function Screens:_catalogColumns()
    if self.selecting then
        return { checkbox = W.dp(58), number = W.dp(62), access = W.dp(122), storage = W.dp(122),
            title = self.width - W.dp(364) }
    end
    return { number = W.dp(70), progress = W.dp(122), access = W.dp(122), storage = W.dp(104), actions = W.dp(36),
        title = self.width - W.dp(454) }
end

function Screens:_chapterRow(comic, episode, current, register_focus)
    local context, columns = self:_catalogContext(), self:_catalogColumns()
    local selected, downloadable = self.selected[tostring(episode.id)], selectable(episode)
    local current_row = tostring(episode.id) == current
    local highlighted = tostring(episode.id) == self.catalog_highlight_id
    local read_row = Model.reading(episode, current) == T("Read")
    local color = self.selecting and not downloadable and BB.Color8(0x88) or read_row and W.muted or W.ink
    local cells = {}
    local function cell(value, width, size, bold)
        return lineText(value, width, size, 40, { bold = bold, color = color })
    end
    if self.selecting then
        local checkbox = W.box(text(selected and "✓" or "", W.dp(26), 20,
            { bold = true, align = "center", color = selected and W.paper or color }), W.dp(30), W.dp(30),
            { border_px = W.dp(2), color = downloadable and W.ink or BB.Color8(0xCC),
                background = selected and W.ink or downloadable and W.paper or BB.Color8(0xEE) })
        cells[#cells + 1] = W.box(checkbox, columns.checkbox, W.dp(63))
    end
    cells[#cells + 1] = cell(chapterNumber(episode), columns.number, 24, true)
    cells[#cells + 1] = cell(title(episode), columns.title, 21, current_row or highlighted)
    if not self.selecting then
        local progress = readingLabel(episode, current)
        if current_row then
            local position = Model.comicProgress(comic, { episode })
            if position.page and position.total_pages then progress = string.format(T("Reading %d/%d"), position.page, position.total_pages) end
        end
        cells[#cells + 1] = cell(progress, columns.progress, 18, current_row)
    end
    if episode.access == "locked" then
        local price_width = columns.access - W.dp(10)
        cells[#cells + 1] = W.box(text(chapterPrice(episode), price_width - W.dp(10), 16,
            { bold = true, color = color, align = "center", height = W.dp(24) }), price_width, W.dp(34),
            { border_px = W.dp(1.5), color = self.selecting and not downloadable and BB.Color8(0xCC) or color })
        cells[#cells + 1] = W.gap(W.dp(10))
    else
        local label = accessLabel(episode)
        cells[#cells + 1] = cell(label, columns.access, label == T("Limited · Expiry unknown") and 16 or 18)
    end
    local storage = Model.storage(episode)
    if storage == T("Not downloaded") then storage = "—" end
    cells[#cells + 1] = cell(storage, columns.storage, 18)
    local content_width = self.width - (columns.actions or 0)
    local row = CatalogRow:new{ width = content_width, content = W.box(W.row(cells), content_width, W.dp(63)),
        current_marker = current_row, enabled = not self.selecting or downloadable,
        callback = function()
            if not self:_catalogCurrent(context) then return end
            if self.selecting then
                if selectable(episode) then
                    local key = tostring(episode.id)
                    self.selected[key] = not self.selected[key] and true or nil
                    self:_render()
                end
            else self:_read(comic, episode) end
        end,
        hold_callback = function()
            if self:_catalogCurrent(context) and not self.selecting then self:_chapterActions(comic, episode) end
        end }
    row.text, row.episode, row.comic = title(episode), episode, comic
    row.chapter_columns, row.column_widgets = columns, cells
    local order = self.selecting and { "checkbox", "number", "title", "access", "storage" }
        or { "number", "title", "progress", "access", "storage", "actions" }
    local offsets, offset = {}, 0
    for _, name in ipairs(order) do offsets[name], offset = offset, offset + columns[name] end
    row.chapter_column_offsets, row.chapter_column_order = offsets, order
    local controls, body = { row }, row
    if not self.selecting then
        local actions = button("⋯", columns.actions, function()
            if self:_catalogCurrent(context) then self:_chapterActions(comic, episode) end
        end, { borderless = true, size = 22, height = 63 })
        controls[#controls + 1], body = actions, W.row{ row, actions }
    end
    local widget = W.column{ body, W.rule1dp(self.width, BB.Color8(0xCC)) }
    widget.catalog_focus, widget.episode, widget.chapter_columns = controls, episode, columns
    widget.chapter_column_offsets, widget.chapter_column_order = offsets, order
    if register_focus ~= false then self.focus[#self.focus + 1] = controls end
    return widget
end

function Screens:_catalogSelectionFooter()
    local width, context = Device.screen:getWidth(), self:_catalogContext()
    local inner, gap = width - W.dp(112), W.dp(14)
    local cancel_width, download_width = W.dp(150), W.dp(230)
    local total, visible = count(self.selected), 0
    for _, episode in ipairs(self.catalog_visible_items or {}) do
        if self.selected[tostring(episode.id)] then visible = visible + 1 end
    end
    local summary_width = inner - cancel_width - download_width - 2 * gap
    local summary = W.column{
        lineText(string.format(T("Selected chapters: %d"), total), summary_width, 22, 30, { bold = true }),
        space(4), lineText(string.format(T("This page %d · Other pages %d"), visible, total - visible), summary_width, 16, 25,
            { muted = true }),
    }
    local cancel = button(T("Cancel"), cancel_width, function()
        if not self:_catalogCurrent(context) then return end
        self.selecting, self.selected = false, {}; self:_render()
    end, { height = 66, size = 21 })
    local download = button(self.status or string.format(T("Download %d selected chapters"), total), download_width, function()
        if self:_catalogCurrent(context) then self:_catalogDownloadSelection() end
    end, { height = 66, size = 22, primary = true, enabled = total > 0 and not self.status })
    local footer_rule = W.rule1dp(width, W.ink)
    local actions = W.row{ summary, W.gap(gap), cancel, W.gap(gap), download }
    local bottom = math.max(0, W.dp(108) - footer_rule:getSize().h - actions:getSize().h - W.dp(20))
    local footer = W.column{ footer_rule, W.inset(actions, W.dp(56), W.dp(56), W.dp(20), bottom) }
    return footer, { cancel, download }
end

function Screens:_comic()
    local comic = self.controller:getComic(self.comic_id) or { id = self.comic_id, title = T("Comic details") }
    local new_scope = self.catalog_scope_id ~= tostring(self.comic_id) or self.catalog_scope_account ~= accountKey(self.controller)
        or self.widget and self.widget.view_route ~= "comic"
    if new_scope then
        self.catalog_scope_id, self.catalog_highlight_id = tostring(self.comic_id), nil
        self.catalog_scope_account = accountKey(self.controller)
        self.catalog_located_current = false
    end
    if self.controller.requestCover then self.controller:requestCover(self.comic_id) end
    local all = copy(Model.array(self.controller:getEpisodes(self.comic_id)))
    table.sort(all, function(a, b)
        local left, right = tonumber(a.order) or 0, tonumber(b.order) or 0
        if left == right then return tostring(a.id) < tostring(b.id) end
        return self.descending and left > right or not self.descending and left < right
    end)
    local current, present = Model.currentEpisode(comic, all), {}
    for _, episode in ipairs(all) do
        local key = tostring(episode.id)
        present[key] = true
        if not selectable(episode) then self.selected[key] = nil end
    end
    for key in pairs(self.selected) do if not present[key] then self.selected[key] = nil end end
    local items = {}
    for _, episode in ipairs(all) do
        if self.filter == "all" or self.filter == "unread" and Model.reading(episode, current) == T("Unread")
            or self.filter == "readable" and (Model.readable(episode) or Model.storage(episode) == T("Downloaded"))
            or self.filter == "downloaded" and Model.storage(episode) == T("Downloaded") then items[#items + 1] = episode end
    end
    self.catalog_all, self.catalog_items, self.catalog_current_id = all, items, current
    local context = self:_catalogContext()
    local cover_width, cover_height, cover_gap = W.dp(114), W.dp(152), W.dp(28)
    local identity_width = self.width - cover_width - cover_gap
    local author, tags = authorsOf(comic), tagsOf(comic)
    local metadata = author ~= "" and author .. " · " or ""
    if #tags > 0 then metadata = metadata .. table.concat(tags, " / ") .. " · " end
    if type(comic.finished) == "boolean" then metadata = metadata .. (comic.finished and T("Completed") or T("Ongoing")) .. " · " end
    metadata = metadata .. string.format(T("%d chapters"), #all)
    local overview_width = W.dp(100)
    local identity = W.column{
        W.row{ lineText(title(comic), identity_width - overview_width, 34, 48, { bold = true }),
            lineText(T("Overview ›"), overview_width, 18, 48, { align = "right" }) },
        space(7), lineText(metadata, identity_width, 18, 28, { muted = true }),
    }
    local identity_action = W.ActionRow:new{ width = identity_width, content = identity,
        callback = function() if self:_catalogCurrent(context) then self:_catalogDetails(comic) end end }
    self.focus[#self.focus + 1] = { identity_action }
    local identity_rows = { identity_action, space(7) }
    if self.selecting then
        local scope_width = W.dp(180)
        local scope = button(T("Select scope…"), scope_width, function()
            if self:_catalogCurrent(context) then self:_catalogSelectionMenu() end
        end, { height = 58, size = 20 })
        local labels = W.column{
            lineText(T("Select chapters to download"), identity_width - scope_width - W.dp(14), 21, 29, { bold = true }),
            lineText(T("Downloaded and locked chapters are unavailable · Selection persists across pages"),
                identity_width - scope_width - W.dp(14), 16, 29, { muted = true }),
        }
        identity_rows[#identity_rows + 1] = W.row{ labels, W.gap(W.dp(14)), scope }
        self.focus[#self.focus + 1] = { scope }
    else
        local pending = self.controller.isFavoritePending and self.controller:isFavoritePending(self.comic_id)
        local side_width, gap = W.dp(150), W.dp(14)
        local resume_label = current and T("Continue reading") or T("Start reading")
        if current then
            for _, episode in ipairs(all) do
                if tostring(episode.id) == current then resume_label = string.format(T("Continue reading · Chapter %s"), chapterNumber(episode)); break end
            end
        end
        local resume = button(self.status or resume_label, identity_width - 2 * side_width - 2 * gap, function()
            if self:_catalogCurrent(context) then self:_readComic(comic) end
        end, { primary = true, enabled = not self.status and #all > 0, height = 62, size = 22 })
        local favorite = button(pending and T("Updating follow…") or (comic.favorite and T("Following ✓") or T("Follow")),
            side_width, function()
                if not self:_catalogCurrent(context) then return end
                if self.controller.isFavoritePending and self.controller:isFavoritePending(self.comic_id) then return end
                self:_invoke("setFavorite", { self.comic_id, not comic.favorite }, function(_value, error)
                    if error then self:_error(error) end
                end, true)
                if self:_catalogCurrent(context) then self:_render() end
            end, { enabled = not pending, height = 62, size = 21 })
        local select_downloads = button(T("Select downloads"), side_width, function()
            if not self:_catalogCurrent(context) then return end
            self.selecting, self.selected = true, {}; self:_render()
        end, { enabled = #all > 0, height = 62, size = 21 })
        identity_rows[#identity_rows + 1] = W.row{ resume, W.gap(gap), favorite, W.gap(gap), select_downloads }
        self.focus[#self.focus + 1] = { resume, favorite, select_downloads }
    end
    local rows = { space(28), W.row{ W.cover(comic, cover_width, cover_height),
        W.gap(cover_gap), W.column(identity_rows) }, space(26), W.rule1dp(self.width, W.ink) }
    local tabs_width, tabs, tab_focus = 0, {}, {}
    for index, entry in ipairs({ { "all", T("All") }, { "unread", T("Unread") },
        { "readable", T("Readable") }, { "downloaded", T("Downloaded") } }) do
        local value, label = entry[1], entry[2]
        local active = self.filter == value
        local measured = TextWidget:new{ text = label, face = Font:getFace("cfont", W.fontSize(20)), bold = active }
        local label_width = measured:getSize().w
        measured:free()
        local left_padding, right_padding = index == 1 and 0 or W.dp(20), W.dp(20)
        local tab_width = label_width + left_padding + right_padding
        local tab = button(label, tab_width, function()
            if not self:_catalogCurrent(context) then return end
            self.filter, self.page, self.epoch = value, 1, self.epoch + 1; self:_render()
        end, { borderless = true, height = 57, size = 20, bold = active, align = "left", padding_h = left_padding })
        local underline = W.box(nil, label_width, W.dp(5), { background = active and W.ink or W.paper })
        tabs[#tabs + 1] = W.column{ tab, W.inset(underline, left_padding, right_padding, 0, 0) }
        tabs_width = tabs_width + tab_width
        tab_focus[#tab_focus + 1] = tab
    end
    local utility_width = self.width - tabs_width
    if self.selecting then
        local clear = button(T("Clear selection"), utility_width, function()
            if not self:_catalogCurrent(context) then return end
            self.selected = {}; self:_render()
        end, { borderless = true, height = 62, size = 20, bold = true, enabled = count(self.selected) > 0, align = "right" })
        tabs[#tabs + 1], tab_focus[#tab_focus + 1] = clear, clear
    else
        local sort_width = math.floor(utility_width / 2)
        local sort = button(self.descending and T("Descending ↓") or T("Ascending ↑"), sort_width, function()
            if not self:_catalogCurrent(context) then return end
            self.descending, self.page, self.epoch = not self.descending, 1, self.epoch + 1; self:_render()
        end, { borderless = true, height = 62, size = 20, align = "right" })
        local jump = button(T("Jump…"), utility_width - sort_width, function()
            if self:_catalogCurrent(context) then self:_catalogJump() end
        end, { borderless = true, height = 62, size = 20, enabled = #all > 0, align = "right" })
        tabs[#tabs + 1], tabs[#tabs + 2] = sort, jump
        tab_focus[#tab_focus + 1], tab_focus[#tab_focus + 2] = sort, jump
    end
    rows[#rows + 1], self.focus[#self.focus + 1] = W.row(tabs), tab_focus
    local columns, labels = self:_catalogColumns(), {}
    local function columnLabel(label, width) return text(label, width, 15, { muted = true, height = W.dp(30) }) end
    if self.selecting then labels[#labels + 1] = columnLabel("", columns.checkbox) end
    labels[#labels + 1], labels[#labels + 2] = columnLabel(T("Chapter"), columns.number), columnLabel(T("Title"), columns.title)
    if not self.selecting then labels[#labels + 1] = columnLabel(T("Progress"), columns.progress) end
    labels[#labels + 1], labels[#labels + 2] = columnLabel(T("Access"), columns.access), columnLabel(T("Storage"), columns.storage)
    if not self.selecting then labels[#labels + 1] = columnLabel("", columns.actions) end
    rows[#rows + 1], rows[#rows + 2] = W.box(W.row(labels), self.width, W.dp(39)), W.rule1dp(self.width, W.ink)
    local header = W.column(rows)
    local pager_height, row_height = W.dp(70), W.dp(63) + math.max(1, W.dp(1))
    local available = self.body_height - header:getSize().h
    local per_page = math.max(1, math.min(10, math.floor((available - (#items > 10 and pager_height or 0)) / row_height)))
    local pages = math.max(1, math.ceil(#items / per_page))
    if pages > 1 then per_page = math.max(1, math.min(10, math.floor((available - pager_height) / row_height))); pages = math.max(1, math.ceil(#items / per_page)) end
    local ranges = {}
    for index = 1, #items, per_page do ranges[#ranges + 1] = { first = index, last = math.min(#items, index + per_page - 1) } end
    local locate = self.catalog_jump_id
    if not locate and not self.catalog_located_current and self.filter == "all" and current then locate = current end
    if locate then
        for page, range in ipairs(ranges) do
            for index = range.first, range.last do
                if tostring(items[index].id) == tostring(locate) then self.page = page end
            end
        end
        self.catalog_located_current = true
    end
    self.catalog_jump_id = nil
    self.page, self.pages, self.page_ranges = math.max(1, math.min(self.page or 1, pages)), pages, ranges
    local visible, content = {}, {}
    self.catalog_rows = {}
    local range = ranges[self.page]
    if range then
        for index = range.first, range.last do
            local episode = items[index]
            visible[#visible + 1] = episode
            local row = self:_chapterRow(comic, episode, current)
            content[#content + 1], self.catalog_rows[#self.catalog_rows + 1] = row, row
        end
    else
        local empty = self.status and T("Loading chapter information…") or self.filter ~= "all"
            and T("No chapters match this filter. Choose another filter to continue.")
            or T("No chapter information is saved yet. Refresh the catalog to try again.")
        content[#content + 1], content[#content + 2] = space(44), text(empty, self.width, 20, { muted = true, height = W.dp(88) })
        content[#content + 1] = space(28)
        local refresh = button(self.filter ~= "all" and T("Clear filter") or T("Refresh chapters"), W.dp(320), function()
            if not self:_catalogCurrent(context) then return end
            if self.filter ~= "all" then self.filter, self.page = "all", 1; self:_render() else self:_refreshComic() end
        end, { enabled = not self.status, height = 68, size = 23 })
        content[#content + 1] = W.box(refresh, self.width, W.dp(68))
        self.focus[#self.focus + 1] = { refresh }
    end
    self.catalog_visible_items = visible
    if pages > 1 then
        local pager_width = math.floor(self.width / 3)
        local previous = button(T("‹ Previous page"), pager_width, function() self:_changePage(-1) end,
            { borderless = true, height = 70, size = 20, enabled = self.page > 1, align = "left" })
        local counter = button(string.format("%d / %d", self.page, pages), self.width - 2 * pager_width,
            function() self:_catalogJump() end, { borderless = true, height = 70, size = 20 })
        local next_page = button(T("Next page ›"), pager_width, function() self:_changePage(1) end,
            { borderless = true, height = 70, size = 20, enabled = self.page < pages, align = "right" })
        content[#content + 1] = W.row{ previous, counter, next_page }
        self.focus[#self.focus + 1], self.pagination = { previous, counter, next_page }, { previous = previous, counter = counter, next = next_page }
    end
    return W.column{ header, W.column(content) }
end

end
