local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local W = require("bilicomics/ui/widgets")
local Model = require("bilicomics/ui/model")
local Helpers = require("bilicomics/ui/screen_helpers")
local T = require("bilicomics/ui/i18n")
local title, count, copy, accountKey = Helpers.title, Helpers.count, Helpers.copy, Helpers.accountKey

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

function Screens:_catalogDetails(comic)
    self:_closeDialog()
    local author = authorsOf(comic)
    local lines = { title(comic) }
    if author ~= "" then lines[#lines + 1] = author end
    if type(comic.finished) == "boolean" then lines[#lines + 1] = comic.finished and T("Completed") or T("Ongoing") end
    lines[#lines + 1], lines[#lines + 2] = "", synopsisOf(comic)
    local context, dialog = self:_catalogContext()
    dialog = TextViewer:new{ title = T("Comic overview"), text = table.concat(lines, "\n"), modal = true,
        close_callback = function()
            if self.dialog ~= dialog then return end
            self.dialog, self.context_dialog, self.context_dialog_account, self.context_dialog_dirty = nil, nil, nil, nil
            if self:_catalogCurrent(context) then self:_render() end
        end }
    self.dialog, self.context_dialog, self.context_dialog_account = dialog, dialog, context.account
    UIManager:show(dialog)
end

function Screens:_catalogFilter()
    local context, dialog = self:_catalogContext()
    local buttons = {}
    for _, choice in ipairs({ { "all", T("All chapters") }, { "unread", T("Unread") }, { "downloaded", T("Downloaded") } }) do
        local value = choice[1]
        buttons[#buttons + 1] = { { text = (self.filter == value and "[x] " or "[ ] ") .. choice[2], callback = function()
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

function Screens:_catalogJump(query)
    self:_closeDialog()
    local context, dialog = self:_catalogContext()
    local current = self.catalog_current_id
    local buttons = {}
    if current then
        buttons[#buttons + 1] = { { text = T("Current chapter"), callback = function()
            if self.dialog == dialog and self:_catalogCurrent(context) then self:_catalogLocate(current) end
        end } }
    end
    buttons[#buttons + 1] = {
        { text = T("Cancel"), callback = function() if self.dialog == dialog then self:_closeDialog() end end },
        { text = T("Find chapter"), is_enter_default = true, callback = function()
            if self.dialog ~= dialog or not self:_catalogCurrent(context) then return end
            local value = dialog:getInputText():match("^%s*(.-)%s*$")
            if value == "" then return end
            self:_catalogJumpResults(value)
        end },
    }
    dialog = InputDialog:new{ title = T("Jump to chapter"), input = query or "", input_hint = T("Chapter number or title"),
        description = T("Choose a result to locate it in this catalog."), buttons = buttons, modal = true }
    self.dialog = dialog
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Screens:_catalogJumpResults(query)
    local context, dialog = self:_catalogContext()
    local numeric, matches = tonumber(query), {}
    for _, episode in ipairs(self.catalog_all or {}) do
        local number_match = numeric and (tonumber(episode.order) == numeric or tonumber(episode.short_title) == numeric)
        if number_match then matches[#matches + 1] = episode end
    end
    if #matches == 0 then
        for _, episode in ipairs(self.catalog_all or {}) do
            if tostring(title(episode)):lower():find(query:lower(), 1, true) then matches[#matches + 1] = episode end
        end
    end
    if #matches == 1 then self:_catalogLocate(matches[1].id); return end
    local buttons = {}
    for _, episode in ipairs(matches) do
        local episode_id = tostring(episode.id)
        buttons[#buttons + 1] = { { text = title(episode), callback = function()
            if self.dialog == dialog and self:_catalogCurrent(context) then self:_catalogLocate(episode_id) end
        end } }
    end
    buttons[#buttons + 1] = { { text = T("Edit search"), callback = function()
        if self.dialog == dialog and self:_catalogCurrent(context) then self:_catalogJump(query) end
    end } }
    buttons[#buttons + 1] = { { text = T("Close"), callback = function() if self.dialog == dialog then self:_closeDialog() end end } }
    dialog = self:_showContextDialog(#matches == 0 and T("No matching chapter. Try another number or title.")
        or string.format(T("Matching chapters: %d"), #matches), buttons)
end

function Screens:_chapterActions(comic, episode)
    local context, dialog = self:_catalogContext()
    local readable = Model.readable(episode) or Model.storage(episode) == T("Downloaded")
    local downloadable = Model.downloadable(episode)
    local buttons = {
        { { text = readable and T("Read chapter") or T("Review reading purchase"), enabled = readable or episode.access == "locked", callback = function()
            if self.dialog ~= dialog or not self:_catalogCurrent(context) then return end
            self:_closeDialog(); self:_read(comic, episode)
        end } },
    }
    if downloadable or episode.access == "locked" then
        buttons[#buttons + 1] = { { text = downloadable and T("Download chapter") or T("Buy then download"), callback = function()
            if self.dialog ~= dialog or not self:_catalogCurrent(context) then return end
            self:_closeDialog()
            if not downloadable then self:_purchaseFor(comic, episode, "download"); return end
            self:_invoke("downloadEpisodes", { tostring(comic.id), { tostring(episode.id) } }, function(_value, error)
                if error then self:_error(error) else self:showDownloads() end
            end)
        end } }
    end
    buttons[#buttons + 1] = { { text = T("Close"), callback = function() if self.dialog == dialog then self:_closeDialog() end end } }
    local heading = title(episode) .. "\n" .. Model.reading(episode, self.catalog_current_id) .. " · "
        .. Model.entitlement(episode) .. " · " .. Model.storage(episode)
    local expiry = Model.entitlementExpiry(episode)
    if expiry then heading = heading .. "\n" .. expiry end
    dialog = self:_showContextDialog(heading, buttons)
end

function Screens:_catalogSelectionMenu()
    local context, dialog = self:_catalogContext()
    local function select(items)
        if self.dialog ~= dialog or not self:_catalogCurrent(context) then return end
        for _, episode in ipairs(items or {}) do
            if Model.downloadable(episode) then self.selected[tostring(episode.id)] = true end
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
            buttons[#buttons + 1] = { { text = "[x] " .. title(episode), callback = function()
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
        if self.selected[tostring(episode.id)] and Model.downloadable(episode) then ids[#ids + 1] = tostring(episode.id) end
    end
    if #ids == 0 then return end
    self:_invoke("downloadEpisodes", { self.comic_id, ids }, function(_value, error)
        if error then self:_error(error) else self:showDownloads() end
    end)
end

function Screens:_chapterRow(comic, episode, current, register_focus)
    local context = self:_catalogContext()
    local selected, downloadable = self.selected[tostring(episode.id)], Model.downloadable(episode)
    local action_width, gap = self.selecting and 0 or W.scale(42), self.selecting and 0 or W.scale(5)
    local content_width = self.width - action_width - gap
    local label = title(episode)
    if self.selecting then label = (selected and "[x] " or "[ ] ") .. label
    elseif tostring(episode.id) == current then label = "▌ " .. label
    elseif tostring(episode.id) == self.catalog_highlight_id then label = "› " .. label end
    local font = W.font or { item = 18, status = 15, meta = 14 }
    local axis, axis_gap = math.floor((content_width - W.scale(10)) / 3), W.scale(5)
    local content = W.column{
        W.text(label, content_width, font.item, { bold = tostring(episode.id) == current
            or tostring(episode.id) == self.catalog_highlight_id, height = W.scale(42) }),
        W.space(3),
        W.row{
            W.text(Model.reading(episode, current), axis, font.status), W.gap(axis_gap),
            W.text(Model.entitlement(episode), axis, font.status, { bold = episode.access == "locked" }), W.gap(axis_gap),
            W.text(Model.storage(episode), axis, font.status),
        },
    }
    local expiry = Model.entitlementExpiry(episode)
    if expiry then content[#content + 1] = W.space(3); content[#content + 1] = W.text(expiry, content_width, font.meta) end
    content:resetLayout()
    local row = W.ActionRow:new{ width = content_width, content = content,
        enabled = not self.selecting or downloadable,
        callback = function()
            if not self:_catalogCurrent(context) then return end
            if self.selecting then
                if Model.downloadable(episode) then
                    local key = tostring(episode.id)
                    self.selected[key] = not self.selected[key] and true or nil
                    self:_render()
                end
            else self:_read(comic, episode) end
        end,
        hold_callback = function()
            if self:_catalogCurrent(context) and not self.selecting then self:_chapterActions(comic, episode) end
        end }
    row.text = label
    local controls = { row }
    local body = row
    if not self.selecting then
        local actions = W.button("…", action_width, function()
            if self:_catalogCurrent(context) then self:_chapterActions(comic, episode) end
        end, { borderless = true, size = 22, height = 36 })
        controls[#controls + 1] = actions
        body = W.row{ row, W.gap(gap), actions }
    end
    local widget = W.column{ W.space(5), body, W.space(5), W.rule(self.width) }
    widget.catalog_focus = controls
    if register_focus ~= false then self.focus[#self.focus + 1] = controls end
    return widget
end

function Screens:_comic()
    local comic = self.controller:getComic(self.comic_id) or { id = self.comic_id, title = T("Comic details") }
    if self.catalog_scope_id ~= tostring(self.comic_id) then
        self.catalog_scope_id, self.catalog_highlight_id = tostring(self.comic_id), nil
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
        if not Model.downloadable(episode) then self.selected[key] = nil end
    end
    for key in pairs(self.selected) do if not present[key] then self.selected[key] = nil end end
    local items = {}
    for _, episode in ipairs(all) do
        if self.filter == "all" or self.filter == "unread" and Model.reading(episode, current) == T("Unread")
            or self.filter == "downloaded" and Model.storage(episode) == T("Downloaded") then items[#items + 1] = episode end
    end
    self.catalog_all, self.catalog_items, self.catalog_current_id = all, items, current
    local context = self:_catalogContext()
    local font = W.font or { title = 21, body = 18, status = 15, meta = 14 }
    local cover_width, cover_height, cover_gap = W.scale(42), W.scale(57), W.scale(10)
    local identity_width = self.width - cover_width - cover_gap
    local overview_width = W.scale(100)
    local author = authorsOf(comic)
    local identity = W.column{
        W.text(title(comic), identity_width, font.title, { bold = true, height = W.scale(43) }),
        W.row{
            W.text((author ~= "" and author .. " · " or "") .. string.format(T("%d chapters"), #all),
                identity_width - overview_width, font.meta, { muted = true, height = W.scale(21) }),
            W.text(T("Overview ›"), overview_width, font.meta, { bold = true, align = "right", height = W.scale(21) }),
        },
    }
    local identity_action = W.ActionRow:new{ width = identity_width, content = identity,
        callback = function() if self:_catalogCurrent(context) then self:_catalogDetails(comic) end end }
    self.focus[#self.focus + 1] = { identity_action }
    local rows = { W.row{ W.cover(comic, cover_width, cover_height), W.gap(cover_gap), identity_action }, W.space(5) }
    if self.selecting then
        rows[#rows + 1] = self:_buttons{
            { text = T("Select scope…"), callback = function() if self:_catalogCurrent(context) then self:_catalogSelectionMenu() end end, size = font.status },
            { text = self.status or string.format(T("Download selected (%d)"), count(self.selected)), primary = true,
                enabled = count(self.selected) > 0 and not self.status, callback = function()
                    if self:_catalogCurrent(context) then self:_catalogDownloadSelection() end
                end, size = font.status },
        }
    else
        local pending = self.controller.isFavoritePending and self.controller:isFavoritePending(self.comic_id)
        rows[#rows + 1] = self:_buttons{
            { text = self.status or (current and T("Continue reading") or T("Start reading")), primary = true,
                enabled = not self.status and #all > 0, callback = function()
                    if self:_catalogCurrent(context) then self:_readComic(comic) end
                end, size = font.body },
            { text = pending and T("Updating follow…") or (comic.favorite and T("Unfollow") or T("Follow")),
                enabled = not pending, callback = function()
                    if not self:_catalogCurrent(context) then return end
                    if self.controller.isFavoritePending and self.controller:isFavoritePending(self.comic_id) then return end
                    self:_invoke("setFavorite", { self.comic_id, not comic.favorite }, function(_value, error)
                        if error then self:_error(error) end
                    end, true)
                    if self:_catalogCurrent(context) then self:_render() end
                end, borderless = true, size = font.status },
        }
    end
    rows[#rows + 1] = W.space(3)
    rows[#rows + 1] = self:_buttons{
        { text = (({ all = T("All"), unread = T("Unread"), downloaded = T("Downloaded") })[self.filter] or T("All")) .. " ▾",
            callback = function() if self:_catalogCurrent(context) then self:_catalogFilter() end end, borderless = true, size = font.status },
        { text = self.descending and T("Newest first") or T("Oldest first"), callback = function()
            if not self:_catalogCurrent(context) then return end
            self.descending, self.page, self.epoch = not self.descending, 1, self.epoch + 1; self:_render()
        end, borderless = true, size = font.status },
        { text = T("Jump…"), enabled = #all > 0, callback = function()
            if self:_catalogCurrent(context) then self:_catalogJump() end
        end, borderless = true, size = font.status },
        { text = self.selecting and T("Done") or T("Select downloads"), enabled = #all > 0, callback = function()
            if not self:_catalogCurrent(context) then return end
            self.selecting, self.selected = not self.selecting, {}; self:_render()
        end, borderless = true, size = font.status },
    }
    rows[#rows + 1] = W.space(4)
    local summary
    if self.selecting then
        local clear_width, gap = W.scale(68), W.scale(6)
        local summary_width = self.width - clear_width - gap
        summary = W.text("", summary_width, font.meta, { height = W.scale(21), fixed_height = true })
        local summary_action = W.ActionRow:new{ width = summary_width, content = summary, enabled = count(self.selected) > 0,
            callback = function() if self:_catalogCurrent(context) then self:_catalogSelected() end end }
        local clear = W.button(T("Clear"), clear_width, function()
            if not self:_catalogCurrent(context) then return end
            self.selected = {}; self:_render()
        end, { borderless = true, size = font.meta, height = 24, enabled = count(self.selected) > 0 })
        self.focus[#self.focus + 1] = { summary_action, clear }
        rows[#rows + 1] = W.row{ summary_action, W.gap(gap), clear }
    end
    if #items > 0 then
        local status_width = self.width - (self.selecting and 0 or W.scale(47))
        local axis, gap = math.floor((status_width - W.scale(10)) / 3), W.scale(5)
        rows[#rows + 1] = W.row{
            W.text(T("Progress"), axis, font.meta, { bold = true }), W.gap(gap),
            W.text(T("Access"), axis, font.meta, { bold = true }), W.gap(gap),
            W.text(T("Storage"), axis, font.meta, { bold = true }),
        }
    end
    local header = W.column(rows)
    local row_cache = {}
    local function rowFor(episode)
        local key = tostring(episode.id)
        if not row_cache[key] then row_cache[key] = self:_chapterRow(comic, episode, current, false) end
        return row_cache[key]
    end
    local function rowHeight(episode) return rowFor(episode):getSize().h end
    local ranges = self:_pageRanges(items, rowHeight, header:getSize().h)
    if self.catalog_jump_id then
        for page, range in ipairs(ranges) do
            for index = range.first, range.last do
                if tostring(items[index].id) == self.catalog_jump_id then self.page = page end
            end
        end
        self.catalog_jump_id = nil
    end
    self.page = math.max(1, math.min(self.page, math.max(1, #ranges)))
    local visible, visible_selected = {}, 0
    local visible_range = ranges[self.page]
    if visible_range then
        for index = visible_range.first, visible_range.last do
            local episode = items[index]
            visible[#visible + 1] = episode
            if self.selected[tostring(episode.id)] then visible_selected = visible_selected + 1 end
        end
    end
    self.catalog_visible_items = visible
    if summary then
        summary:setText(string.format(T("Selected: %d · Outside this page: %d"), count(self.selected), count(self.selected) - visible_selected))
        header:resetLayout()
    end
    local empty = self.status and T("Loading chapter information…") or self.filter ~= "all"
        and T("No chapters match this filter. Choose another filter to continue.")
        or T("No chapter information is saved yet. Refresh the catalog to try again.")
    local content = self:_paginate(items, rowHeight, header:getSize().h, function(episode)
        local row = rowFor(episode)
        self.focus[#self.focus + 1] = row.catalog_focus
        return row
    end, empty, { jump_callback = function() self:_catalogJump() end })
    if #items == 0 then
        content[#content + 1] = W.space(8)
        content[#content + 1] = self:_button(self.filter ~= "all" and T("Clear filter") or T("Refresh chapters"), self.width, function()
            if not self:_catalogCurrent(context) then return end
            if self.filter ~= "all" then self.filter, self.page = "all", 1; self:_render() else self:_refreshComic() end
        end, { enabled = not self.status, borderless = true, size = font.status })
        content:resetLayout()
    end
    return W.column{ header, content }
end

end
