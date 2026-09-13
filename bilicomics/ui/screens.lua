local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local FileChooser = require("ui/widget/filechooser")
local SessionInput = require("bilicomics/ui/session_input")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local W = require("bilicomics/ui/widgets")
local Model = require("bilicomics/ui/model")
local _ = require("bilicomics/ui/i18n")
local Screens = {}
Screens.__index = Screens

local function title(record) return record.title or record.short_title or tostring(record.id or "") end
local function count(map) local total = 0; for _ in pairs(map) do total = total + 1 end; return total end
local function asset(method) return method == "coupon" and _("coupons") or _("coins") end
local function copy(items) local result = {}; for _index, item in ipairs(items) do result[#result + 1] = item end; return result end
local function accountKey(controller)
    local account = controller:getAccount() or {}
    return account.account_key or account.id
end
local function purchasePurpose(intent, fallback)
    local purpose = intent and intent.purpose or fallback
    return purpose == "download" and "download" or "read"
end

function Screens.new(options)
    return setmetatable({ controller = assert(options.controller), page = 1, epoch = 0,
        selected = {}, filter = "all", descending = false, loaded = {}, pending = {}, query = "" }, Screens)
end

function Screens:_navigate(route, id)
    self:_closeDialog()
    self.purchase_visible = false
    self.epoch = self.epoch + 1
    self.route, self.comic_id, self.page = route, id, 1
    self.status, self.filter, self.selecting, self.selected = nil, "all", false, {}
    self:_render()
end

function Screens:showLibrary(kind) self:_navigate(kind == "favorites" and "favorites" or "continue") end
function Screens:showComic(id)
    self:_navigate("comic", tostring(id))
    if not self.loaded["comic:" .. tostring(id)] then self:_refreshComic() end
end
function Screens:showDownloads() self:_navigate("downloads") end
function Screens:showAccount() self:_navigate("account") end
function Screens:showSearch() self:_navigate("search") end
function Screens:refresh() if self.route then self:_render() end end

function Screens:close()
    self.epoch = self.epoch + 1
    self.session_input = nil
    if self.scope_dialog then UIManager:close(self.scope_dialog); self.scope_dialog = nil end
    if self.dialog then UIManager:close(self.dialog); self.dialog = nil end
    if self.widget then UIManager:close(self.widget); self.widget = nil end
    self.route = nil
end

function Screens:_closeDialog(keep_purchase)
    if not keep_purchase then self.purchase_visible = false end
    self.session_input = nil
    if self.dialog then UIManager:close(self.dialog); self.dialog = nil end
end

function Screens:_error(error)
    local heading, message, action = Model.error(error)
    self:_closeDialog()
    local buttons = { { { text = _("Close"), callback = function() self:_closeDialog() end } } }
    if action == "account" then
        table.insert(buttons, 1, { { text = _("Open account"), callback = function()
            self:_closeDialog(); self:showAccount()
        end } })
    end
    self.dialog = ButtonDialog:new{ title = heading .. "\n\n" .. message, buttons = buttons, modal = true }
    UIManager:show(self.dialog)
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
    if not quiet then self.status = _("Updating…"); self:_render() end
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

function Screens:_paginate(items, row_height, fixed_height, render)
    local available = self.body_height - fixed_height - W.scale(51)
    local capacity = math.max(1, math.floor(available / W.scale(row_height)))
    self.pages = math.max(1, math.ceil(#items / capacity))
    self.page = math.max(1, math.min(self.page, self.pages))
    local rows = {}
    for index = (self.page - 1) * capacity + 1, math.min(self.page * capacity, #items) do
        rows[#rows + 1] = render(items[index], index)
    end
    if #items == 0 then
        rows[#rows + 1] = W.text(_("Nothing here yet. Refresh your library or search for a comic."), self.width, 20,
            { height = W.scale(95) })
    end
    rows[#rows + 1] = W.space(8)
    rows[#rows + 1] = self:_buttons{
        { text = _("Previous"), enabled = self.page > 1, callback = function() self:_changePage(-1) end },
        { text = string.format(_("%d / %d"), self.page, self.pages), enabled = false },
        { text = _("Next"), enabled = self.page < self.pages, callback = function() self:_changePage(1) end },
    }
    return W.column(rows)
end

function Screens:_changePage(delta)
    self.page = math.max(1, math.min(self.pages or 1, self.page + delta)); self:_render()
end

function Screens:_render()
    if not self.route then return end
    self.focus = {}
    self.width = Device.screen:getWidth() - W.scale(32)
    self.height = Device.screen:getHeight()
    self.body_height = self.height - W.scale(150)
    local headings = { continue = _("Continue reading"), favorites = _("Following"), comic = _("Chapters"),
        downloads = _("Downloads"), search = _("Search"), account = _("Account and settings") }
    local side_width = W.scale(78)
    local header = W.row{
        self:_button(_("Close"), side_width, function() self:close() end, { borderless = true, size = 16 }),
        W.text(headings[self.route], self.width - 2 * side_width, 25, { bold = true, align = "center", height = W.scale(38) }),
        self:_button(self.route == "account" and _("Library") or _("Account"), side_width,
            function() if self.route == "account" then self:showLibrary() else self:showAccount() end end,
            { borderless = true, size = 16 }),
    }
    local builders = { continue = self._library, favorites = self._library, comic = self._comic,
        downloads = self._downloads, search = self._search, account = self._account }
    local body = builders[self.route](self)
    local navigation = self:_buttons{
        { text = _("Reading"), primary = self.route == "continue", callback = function() self:showLibrary() end },
        { text = _("Following"), primary = self.route == "favorites", callback = function() self:showLibrary("favorites") end },
        { text = _("Search"), primary = self.route == "search", callback = function() self:showSearch() end },
        { text = _("Downloads"), primary = self.route == "downloads", callback = function() self:showDownloads() end },
    }
    local content = W.column{ header, W.space(6), W.rule(self.width, true), W.space(10), body }
    local filler = self.height - content:getSize().h - navigation:getSize().h - W.scale(16)
    content[#content + 1] = W.spacePixels(math.max(0, filler))
    content[#content + 1] = navigation
    content:resetLayout()
    local previous = self.widget
    self.widget = W.Panel:new{ content = content, layout = self.focus,
        close_callback = function() self:close() end,
        next_page = function() self:_changePage(1) end,
        previous_page = function() self:_changePage(-1) end }
    if previous then UIManager:close(previous) end
    UIManager:show(self.widget)
end

function Screens:_comicCard(comic, prominent)
    if self.controller.requestCover then self.controller:requestCover(comic.id) end
    local cover_width, cover_height = W.scale(prominent and 88 or 52), W.scale(prominent and 116 or 70)
    local text_width = self.width - cover_width - W.scale(14)
    local episodes = Model.array(self.controller:getEpisodes(comic.id))
    local current = Model.currentEpisode(comic, episodes)
    local subtitle = comic.latest_episode_title or (comic.extra or {}).latest_episode_title
        or (comic.latest_order and string.format(_("Latest chapter: %s"), tostring(comic.latest_order))) or _("Open chapter catalog")
    local current_episode
    for _index, episode in ipairs(episodes) do if tostring(episode.id) == current then current_episode = episode; break end end
    if prominent and current_episode then subtitle = title(current_episode) end
    local anchor = comic.reading_position or (comic.extra or {}).reading_position
    if prominent and anchor then subtitle = subtitle .. " · " .. string.format(_("Image %d"), anchor.page or anchor.index or 1) end
    local title_button = W.button(title(comic), text_width, function() self:showComic(comic.id) end,
        { borderless = true, align = "left", bold = true, size = prominent and 24 or 20, height = 27 })
    self.focus[#self.focus + 1] = { title_button }
    local texts = { title_button }
    if self.route == "favorites" and not prominent then
        local button_width = W.scale(92)
        local finished = current_episode and (current_episode.read == true or current_episode.read == "complete"
            or current_episode.read == "finished" or current_episode.read == "read")
        local read_button = W.button(finished and _("Read next") or (current_episode and _("Resume comic") or _("Read comic")), button_width,
            function()
                self:_invoke("resolveReadingEpisode", { tostring(comic.id) }, function(target, error)
                    if error then self:_error(error) else self:_read(target.comic, target.episode) end
                end)
            end, { size = 16, height = 23 })
        self.focus[#self.focus + 1] = { read_button }
        texts[#texts + 1] = W.row{ W.text(subtitle, text_width - button_width - W.scale(6), 16, { muted = true, height = W.scale(23) }),
            W.gap(W.scale(6)), read_button }
    else
        texts[#texts + 1] = W.text(subtitle, text_width, 16, { muted = true, height = W.scale(23) })
    end
    if prominent then
        texts[#texts + 1] = W.space(8)
        texts[#texts + 1] = self:_button(_("Resume reading"), text_width, function()
            if current_episode then self:_read(comic, current_episode) else self:showComic(comic.id) end
        end, { primary = true })
    end
    local cover = W.cover(comic, cover_width, cover_height)
    local row = W.row{ cover, W.gap(W.scale(12)), W.column(texts) }
    local rows = {}
    if prominent then rows[#rows + 1] = W.text(_("BOOKMARK"), self.width, 12, { bold = true }); rows[#rows + 1] = W.space(4) end
    rows[#rows + 1], rows[#rows + 2], rows[#rows + 3] = row, W.space(8), W.rule(self.width)
    rows[#rows + 1] = W.space(7)
    return W.column(rows)
end

function Screens:_library()
    local kind = self.route == "favorites" and "favorites" or "history"
    local items = copy(Model.array(self.controller:getLibrary(kind)))
    if self.route == "favorites" and self.filter ~= "all" then
        local filtered = {}
        for _index, comic in ipairs(items) do
            local updated = comic.updated or comic.has_update or (comic.extra or {}).has_update
            if (self.filter == "updated" and updated) or (self.filter == "completed" and comic.finished) then
                filtered[#filtered + 1] = comic
            end
        end
        items = filtered
    end
    local controls = self:_buttons{
        { text = self.status or _("Refresh library"), callback = function()
            self:_invoke("refreshLibrary", { kind }, function(_value, error) if error then self:_error(error) end end)
        end },
        { text = self.route == "favorites" and ({ all = _("All"), updated = _("Updated"), completed = _("Completed") })[self.filter]
            or _("Find a comic"), callback = function()
            if self.route == "favorites" then
                self.filter = ({ all = "updated", updated = "completed", completed = "all" })[self.filter]
                self.page = 1; self:_render()
            else self:showSearch() end
        end },
    }
    local rows, fixed = { controls, W.space(12) }, W.scale(54)
    if self.route == "continue" and #items > 0 then
        local recent = table.remove(items, 1)
        local card = self:_comicCard(recent, true)
        rows[#rows + 1], rows[#rows + 2] = card, W.space(6)
        fixed = fixed + card:getSize().h + W.scale(6)
    end
    rows[#rows + 1] = self:_paginate(items, 91, fixed, function(comic) return self:_comicCard(comic, false) end)
    return W.column(rows)
end

function Screens:_read(comic, episode)
    if not Model.readable(episode) and Model.storage(episode) ~= _("Downloaded") then
        if episode.access == "locked" then self:_purchaseFor(comic, episode)
        else self:_error({ kind = "access" }) end
        return
    end
    self:_invoke("readEpisode", { tostring(comic.id), tostring(episode.id) }, function(_value, error)
        if error then self:_error(error) else self:close() end
    end)
end

function Screens:_chapterRow(comic, episode, current)
    local selected = self.selected[tostring(episode.id)]
    local downloadable = Model.downloadable(episode)
    local purchase_download = not self.selecting and episode.access == "locked"
    local download_width = W.scale(136)
    local row_width = self.width - (purchase_download and download_width + W.scale(6) or 0)
    local label = title(episode)
    if self.selecting then label = (selected and "[x] " or "[ ] ") .. label
    elseif tostring(episode.id) == current then label = "▌ " .. label end
    local button = self:_button(label, row_width, function()
        if self.selecting then
            if downloadable then
                self.selected[tostring(episode.id)] = not selected and true or nil
                self:_render()
            end
        else self:_read(comic, episode) end
    end, { borderless = true, align = "left", bold = tostring(episode.id) == current,
        enabled = not self.selecting or downloadable, size = 20, height = 28 })
    if purchase_download then
        button = W.row{ button, W.gap(W.scale(6)), self:_button(_("Buy then download"), download_width,
            function() self:_purchaseFor(comic, episode, "download") end, { size = 16, height = 28 }) }
    end
    local axis = math.floor((self.width - W.scale(12)) / 3)
    local status = W.row{
        W.text(Model.reading(episode, current), axis, 15, { muted = true, height = W.scale(24) }), W.gap(W.scale(6)),
        W.text(Model.entitlement(episode), axis, 15, { height = W.scale(24) }), W.gap(W.scale(6)),
        W.text(Model.storage(episode), axis, 15, { muted = true, height = W.scale(24) }),
    }
    local rows = { button, W.space(1), status }
    local expiry = Model.entitlementExpiry(episode)
    if expiry then
        rows[#rows + 1] = W.space(1)
        rows[#rows + 1] = W.text(expiry, self.width, 14, { height = W.scale(24) })
    end
    rows[#rows + 1], rows[#rows + 2], rows[#rows + 3] = W.space(7), W.rule(self.width), W.space(4)
    return W.column(rows)
end

function Screens:_comic()
    local comic = self.controller:getComic(self.comic_id) or { id = self.comic_id, title = _("Comic details") }
    if self.controller.requestCover then self.controller:requestCover(self.comic_id) end
    local all = copy(Model.array(self.controller:getEpisodes(self.comic_id)))
    table.sort(all, function(a, b)
        local ao, bo = tonumber(a.order) or 0, tonumber(b.order) or 0
        if ao == bo then return tostring(a.id) < tostring(b.id) end
        if self.descending then return ao > bo end
        return ao < bo
    end)
    local current = Model.currentEpisode(comic, all)
    local row_height = 79
    for _index, episode in ipairs(all) do
        if episode.access == "temporary" then row_height = 105; break end
    end
    if self.selecting then
        for _index, episode in ipairs(all) do if not Model.downloadable(episode) then self.selected[tostring(episode.id)] = nil end end
    end
    local items = {}
    for _index, episode in ipairs(all) do
        if self.filter == "all" or (self.filter == "unread" and Model.reading(episode, current) == _("Unread"))
            or (self.filter == "downloaded" and Model.storage(episode) == _("Downloaded")) then
            items[#items + 1] = episode
        end
    end
    local cover_width = W.scale(54)
    local authors = type(comic.authors) == "table" and table.concat(comic.authors, ", ") or comic.authors or ""
    local header = W.row{ W.cover(comic, cover_width, W.scale(70)), W.gap(W.scale(12)), W.column{
        W.text(title(comic), self.width - cover_width - W.scale(16), 24, { bold = true, display = true, height = W.scale(31) }),
        W.text(authors, self.width - cover_width - W.scale(16), 16, { muted = true, height = W.scale(22) }),
        W.text(string.format(_("%d chapters"), #all), self.width - cover_width - W.scale(16), 14),
    } }
    local controls = self:_buttons{
        { text = ({ all = _("All"), unread = _("Unread"), downloaded = _("Downloaded") })[self.filter], callback = function()
            self.filter = ({ all = "unread", unread = "downloaded", downloaded = "all" })[self.filter]; self.page = 1; self:_render()
        end },
        { text = self.descending and _("Newest first") or _("Oldest first"), callback = function()
            self.descending = not self.descending; self.page = 1; self:_render()
        end },
        { text = self.selecting and _("Cancel selection") or _("Select downloads"), callback = function()
            self.selecting = not self.selecting; self.selected = {}; self:_render()
        end },
    }
    local actions
    if self.selecting then
        actions = self:_buttons{
            { text = _("Select downloadable"), callback = function()
                for _index, episode in ipairs(items) do if Model.downloadable(episode) then self.selected[tostring(episode.id)] = true end end
                self:_render()
            end },
            { text = string.format(_("Download selected (%d)"), count(self.selected)), primary = true,
                enabled = count(self.selected) > 0, callback = function()
                local ids = {}
                for _index, episode in ipairs(all) do if self.selected[tostring(episode.id)] then ids[#ids + 1] = tostring(episode.id) end end
                self:_invoke("downloadEpisodes", { self.comic_id, ids }, function(_value, error)
                    if error then self:_error(error) else self:showDownloads() end
                end)
            end },
        }
    else
        local following_pending = self.controller.isFavoritePending and self.controller:isFavoritePending(self.comic_id)
        actions = self:_buttons{
            { text = _("Current chapter"), enabled = current ~= nil, callback = function()
                self.filter = "all"
                local capacity = math.max(1, math.floor((self.body_height - W.scale(212) - W.scale(51)) / W.scale(row_height)))
                for index, episode in ipairs(all) do
                    if tostring(episode.id) == current then self.page = math.ceil(index / capacity); break end
                end
                self:_render()
            end },
            { text = self.status or _("Refresh chapters"), callback = function() self:_refreshComic() end },
            { text = following_pending and _("Updating follow…") or (comic.favorite and _("Unfollow") or _("Follow")),
                enabled = not following_pending, callback = function()
                    local comic_id, target = self.comic_id, not comic.favorite
                    self:_invoke("setFavorite", { comic_id, target }, function(_value, error)
                        if error then self:_error(error) end
                    end, true)
                    if self.route == "comic" then self:_render() end
                end },
        }
    end
    return W.column{ header, W.space(10), controls, W.space(6), actions, W.space(10),
        W.row{ W.text(_("Progress"), math.floor(self.width / 3), 13, { bold = true }),
            W.text(_("Access"), math.floor(self.width / 3), 13, { bold = true }),
            W.text(_("Storage"), math.floor(self.width / 3), 13, { bold = true }) },
        self:_paginate(items, row_height, W.scale(212), function(episode) return self:_chapterRow(comic, episode, current) end) }
end

function Screens:_jobRow(job)
    local state_labels = { queued = _("Queued"), running = _("Downloading"), paused = _("Paused"),
        complete = _("Downloaded"), failed = _("Failed"), canceled = _("Canceled") }
    local payload = job.payload or {}
    local comic = self.controller:getComic(job.comic_id) or { id = job.comic_id }
    local episode = self.controller.getEpisode and self.controller:getEpisode(job.episode_id)
    if not episode then
        for _index, item in ipairs(Model.array(self.controller:getEpisodes(job.comic_id))) do
            if tostring(item.id) == tostring(job.episode_id) then episode = item; break end
        end
    end
    local label = payload.comic_title or title(comic)
    local chapter = payload.title or (episode and title(episode)) or tostring(job.episode_id or "")
    local progress = string.format(_("%s · Images %d/%d"), state_labels[job.state] or _("Queued"), job.completed or 0, job.total or 0)
    local refresh = payload.source_refresh
    local replacement = payload.version_replacement
    local context = self:_downloadContext()
    local actions = {}
    if payload.replaced_by then
        progress = string.format(_("%s · Images %d/%d"), _("Older version retained"), job.completed or 0, job.total or 0)
        actions[1] = { text = _("Read retained version"), callback = function()
            if self:_downloadContextCurrent(context) then self:_readDownload(job, context) end
        end }
        actions[2] = { text = _("Remove download"), callback = function()
            if self:_downloadContextCurrent(context) then self:_confirmRemoveDownload(job) end
        end }
    elseif type(replacement) == "table" then
        progress = _("Preparing new version…")
        actions[1] = { text = _("Cancel preparation"), callback = function()
            if self:_downloadContextCurrent(context) then self:_cancelVersionReplacement(job) end
        end }
    elseif type(refresh) == "table" then
        progress = refresh.stage == "index" and _("Fetching image sources…")
            or string.format(_("Verifying historical images %d/%d"), refresh.checked or 0, refresh.total or 0)
        actions[1] = { text = _("Cancel verification"), callback = function()
            if self:_downloadContextCurrent(context) then self:_cancelSourceRefresh(job) end
        end }
        if job.revision then
            actions[2] = { text = _("Remove download"), callback = function()
                if self:_downloadContextCurrent(context) then self:_confirmRemoveDownload(job) end
            end }
        end
    elseif job.state == "complete" then
        actions[1] = { text = _("Read offline"), primary = true, callback = function()
            if self:_downloadContextCurrent(context) then self:_readDownload(job, context) end
        end }
        actions[2] = { text = _("Remove download"), callback = function() self:_confirmRemoveDownload(job) end }
    else
        local resume = job.state == "paused" or job.state == "failed" or job.state == "canceled"
        actions[1] = { text = resume and _("Resume") or _("Pause"), callback = function()
            if resume then self.controller:resumeJob(job.id) else self.controller:pauseJob(job.id) end; self:_render()
        end }
        actions[2] = { text = _("Cancel download"), callback = function() self.controller:cancelJob(job.id); self:_render() end }
        if job.revision then
            actions[3] = { text = _("Remove download"), callback = function() self:_confirmRemoveDownload(job) end }
        end
        if job.error or job.state == "failed" then
            actions[#actions + 1] = { text = _("Failure details"), callback = function()
                if self:_downloadContextCurrent(context) then self:_downloadRecovery(job) end
            end }
        elseif self:_canRefreshSources(job) or self:_canReplaceVersion(job) then
            actions[#actions + 1] = { text = _("Recovery options"), callback = function()
                if self:_downloadContextCurrent(context) then self:_downloadRecovery(job) end
            end }
        end
    end
    return W.column{ W.text(label .. " · " .. chapter, self.width, 19, { bold = true, height = W.scale(27) }),
        W.text(progress, self.width, 16, { muted = true, height = W.scale(24) }),
        self:_buttons(actions), W.space(8), W.rule(self.width), W.space(8) }
end

function Screens:_readDownload(job, context)
    self:_invoke("readDownload", { job.id }, function(_value, error)
        if not self:_downloadContextCurrent(context) then return end
        if error then self:_error(error) else self:close() end
    end)
end

function Screens:_downloadContext()
    return { epoch = self.epoch, account_key = accountKey(self.controller), generation = self.controller.generation }
end

function Screens:_downloadContextCurrent(context)
    return self.route == "downloads" and self.epoch == context.epoch and accountKey(self.controller) == context.account_key
        and self.controller.generation == context.generation
end

function Screens:_canRefreshSources(job)
    return self.controller.refreshDownloadSources ~= nil and job.revision ~= nil and not (job.payload or {}).removed
        and not (job.payload or {}).replaced_by and not (job.payload or {}).version_replacement
        and not (job.payload or {}).source_refresh and (job.state == "paused" or job.state == "failed" or job.state == "canceled")
end

function Screens:_canReplaceVersion(job)
    local payload = job.payload or {}
    return self.controller.replaceDownloadVersion ~= nil and job.revision ~= nil and not payload.removed
        and not payload.replaced_by and not payload.source_refresh and not payload.version_replacement
        and (job.state == "paused" or job.state == "failed" or job.state == "canceled")
end

function Screens:_currentDownload(job_id)
    for _index, job in ipairs(Model.array(self.controller:getDownloads())) do
        if job.id == job_id then return job end
    end
end

function Screens:_downloadRecovery(job, error)
    self:_closeDialog()
    local context, dialog = self:_downloadContext()
    local heading, message, action
    if error or job.error then heading, message, action = Model.error(error or job.error)
    else
        heading, message = _("Choose a recovery method"), _("Verify matching image sources, or download a separate new version while retaining this one.")
    end
    local buttons = {}
    if action == "account" then
        buttons[#buttons + 1] = { { text = _("Open account"), callback = function()
            if self.dialog == dialog and self:_downloadContextCurrent(context) then self:showAccount() end
        end } }
    end
    if self:_canRefreshSources(job) then
        buttons[#buttons + 1] = { { text = _("Refresh image sources"), callback = function()
            if self.dialog == dialog and self:_downloadContextCurrent(context) then self:_confirmSourceRefresh(job) end
        end } }
    end
    if self:_canReplaceVersion(job) then
        buttons[#buttons + 1] = { { text = _("Redownload as new version"), callback = function()
            if self.dialog == dialog and self:_downloadContextCurrent(context) then self:_confirmVersionReplacement(job) end
        end } }
    end
    buttons[#buttons + 1] = { { text = _("Close"), callback = function() if self.dialog == dialog then self:_closeDialog() end end } }
    dialog = ButtonDialog:new{ title = _("Download recovery") .. "\n\n" .. heading .. "\n" .. message, buttons = buttons, modal = true }
    self.dialog = dialog; UIManager:show(dialog)
end

function Screens:_confirmSourceRefresh(job)
    if not self:_canRefreshSources(job) then return end
    self:_closeDialog()
    local context, dialog, started = self:_downloadContext()
    dialog = ConfirmBox:new{
        text = _("Refresh this chapter's image sources? Previously saved images will be downloaded again for verification, using network data. Existing cache and reading progress are retained. If all checks pass, the download resumes. No purchase is made."),
        ok_text = _("Refresh image sources"), cancel_text = _("Cancel"), modal = true,
        ok_callback = function()
            if started or self.dialog ~= dialog or not self:_downloadContextCurrent(context) then return end
            local current = self:_currentDownload(job.id)
            if not current or not self:_canRefreshSources(current) then self:_closeDialog(); self:_render(); return end
            started = true; self:_closeDialog()
            self.source_refresh_requests = self.source_refresh_requests or {}
            self.source_refresh_requests[job.id] = context
            local function completed(value, err)
                if self.source_refresh_requests[job.id] ~= context then return end
                self.source_refresh_requests[job.id] = nil
                if not self:_downloadContextCurrent(context) then return end
                if err and err.kind ~= "canceled" and not self.dialog then
                    local retained = self:_currentDownload(job.id)
                    if retained and self:_canReplaceVersion(retained) and (err.kind == "unknown_history"
                        or err.kind == "content_changed" or err.kind == "unverified_position") then
                        self:_downloadRecovery(retained, err)
                    else self:_error(err) end
                end
                self:_render()
            end
            local ok = pcall(function() self.controller:refreshDownloadSources(job.id, completed) end)
            if not ok then completed(nil, { kind = "internal" }) end
            if self:_downloadContextCurrent(context) then self:_render() end
        end,
    }
    self.dialog = dialog; UIManager:show(dialog)
end

function Screens:_confirmVersionReplacement(job)
    if not self:_canReplaceVersion(job) then return end
    self:_closeDialog()
    local context, dialog, started = self:_downloadContext()
    dialog = ConfirmBox:new{
        text = _("Download this chapter as a separate new version? All images will be downloaded, requiring additional space and network data. The new version starts from the beginning. This version's cache and reading position stay in a separate older-version row, where you can read or remove them. No purchase is made."),
        ok_text = _("Redownload as new version"), cancel_text = _("Cancel"), modal = true,
        ok_callback = function()
            if started or self.dialog ~= dialog or not self:_downloadContextCurrent(context) then return end
            local current = self:_currentDownload(job.id)
            if not current or not self:_canReplaceVersion(current) then self:_closeDialog(); self:_render(); return end
            started = true; self:_closeDialog()
            self.version_replacement_requests = self.version_replacement_requests or {}
            self.version_replacement_requests[job.id] = context
            local function completed(_value, err)
                if self.version_replacement_requests[job.id] ~= context then return end
                self.version_replacement_requests[job.id] = nil
                if not self:_downloadContextCurrent(context) then return end
                if err and err.kind ~= "canceled" and not self.dialog then self:_error(err) end
                self:_render()
            end
            local ok = pcall(function() self.controller:replaceDownloadVersion(job.id, completed) end)
            if not ok then completed(nil, { kind = "internal" }) end
            if self:_downloadContextCurrent(context) then self:_render() end
        end,
    }
    self.dialog = dialog; UIManager:show(dialog)
end

function Screens:_cancelVersionReplacement(job)
    if self.version_replacement_requests then self.version_replacement_requests[job.id] = nil end
    local ok, _, err = pcall(self.controller.cancelVersionReplacement, self.controller, job.id)
    if not ok then self:_error({ kind = "internal" })
    elseif err then self:_error(err) end
    self:_render()
end

function Screens:_cancelSourceRefresh(job)
    if self.source_refresh_requests then self.source_refresh_requests[job.id] = nil end
    local ok, _, err = pcall(self.controller.cancelSourceRefresh, self.controller, job.id)
    if not ok then self:_error({ kind = "internal" })
    elseif err then self:_error(err) end
    self:_render()
end

function Screens:_confirmRemoveDownload(job)
    self:_closeDialog()
    local context, dialog = self:_downloadContext()
    local verifying = (job.payload or {}).source_refresh ~= nil
    dialog = ConfirmBox:new{ text = verifying
            and _("Cancel source verification and remove this downloaded chapter? Reading position and access are preserved.")
            or _("Remove this downloaded chapter? Reading position and purchase access are preserved."),
        ok_text = _("Remove download"), cancel_text = _("Cancel"), ok_callback = function()
            if self.dialog ~= dialog or not self:_downloadContextCurrent(context) then return end
            if verifying then
                if self.source_refresh_requests then self.source_refresh_requests[job.id] = nil end
                self.controller:cancelSourceRefresh(job.id)
            end
            self:_invoke("removeDownload", { job.id }, function(_value, error)
                if error then self:_error(error) end
            end)
        end }
    self.dialog = dialog; UIManager:show(dialog)
end

function Screens:_downloads()
    local jobs = Model.array(self.controller:getDownloads())
    local items, active, complete = {}, 0, 0
    for _index, job in ipairs(jobs) do
        if job.kind == nil or job.kind == "episode_download" then
            local older = (job.payload or {}).replaced_by ~= nil
            if not older then
                if job.state == "complete" then complete = complete + 1 else active = active + 1 end
            end
            if self.filter == "all" or (not older and ((self.filter == "complete" and job.state == "complete")
                or (self.filter == "active" and job.state ~= "complete"))) then items[#items + 1] = job end
        end
    end
    table.sort(items, function(a, b)
        if ((a.payload or {}).replaced_by ~= nil) ~= ((b.payload or {}).replaced_by ~= nil) then return (a.payload or {}).replaced_by == nil end
        if (a.state == "complete") ~= (b.state == "complete") then return a.state ~= "complete" end
        return tostring(a.id) < tostring(b.id)
    end)
    local storage = self.controller:getStorageSummary() or {}
    local summary = string.format(_("%d in queue · %d downloaded · %s retained"), active, complete,
        Model.bytes(storage.pinned_bytes or storage.retained_bytes or storage.download_bytes))
    return W.column{ W.text(summary, self.width, 17, { height = W.scale(29) }), W.space(6), self:_buttons{
        { text = ({ all = _("All downloads"), active = _("In progress"), complete = _("Ready offline") })[self.filter], callback = function()
            self.filter = ({ all = "active", active = "complete", complete = "all" })[self.filter]; self.page = 1; self:_render()
        end },
        { text = _("Refresh status"), callback = function() self:_render() end },
    }, W.space(12), self:_paginate(items, 120, W.scale(92), function(job) return self:_jobRow(job) end) }
end

function Screens:_editSearch()
    self:_closeDialog()
    local dialog
    dialog = InputDialog:new{ title = _("Search comics"), input = self.query, input_hint = _("Title or author"), modal = true,
        buttons = { { { text = _("Cancel"), callback = function() self:_closeDialog() end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local query = dialog:getInputText():match("^%s*(.-)%s*$")
                self:_closeDialog()
                if query == "" then return end
                self.query, self.page, self.search_results = query, 1, nil
                self:_invoke("search", { query }, function(value, error)
                    if self.query ~= query then return end
                    if error then self:_error(error) else
                        self.search_results = Model.array(value)
                        local history = self.controller:getSetting("search_history", {})
                        local recent = { query }
                        for _index, old in ipairs(history) do if old ~= query and #recent < 8 then recent[#recent + 1] = old end end
                        self.controller:setSetting("search_history", recent)
                    end
                end)
            end } } } }
    self.dialog = dialog; UIManager:show(dialog); dialog:onShowKeyboard()
end

function Screens:_search()
    local rows = { self:_button(self.query ~= "" and self.query or _("Search by title or author"), self.width,
        function() self:_editSearch() end, { align = "left", size = 20, height = 36 }), W.space(6),
        self:_button(_("Open by comic ID"), self.width, function() self:_lookupComicID() end), W.space(12) }
    if self.query == "" then
        rows[#rows + 1] = W.text(_("Recent searches"), self.width, 18, { bold = true })
        rows[#rows + 1] = W.space(8)
        local history = self.controller:getSetting("search_history", {})
        if #history == 0 then rows[#rows + 1] = W.text(_("Search for a comic to start reading."), self.width, 19) end
        for index, query in ipairs(history) do
            if index > 5 then break end
            rows[#rows + 1] = self:_button(query, self.width, function()
                self.query, self.search_results = query, nil
                self:_invoke("search", { query }, function(value, error)
                    if self.query ~= query then return end
                    if error then self:_error(error) else self.search_results = Model.array(value) end
                end)
            end, { align = "left", borderless = true })
        end
    else
        local results = {}
        for _index, comic in ipairs(self.search_results or {}) do
            if self.filter == "all" or (self.filter == "completed" and comic.finished)
                or (self.filter == "ongoing" and not comic.finished) then results[#results + 1] = comic end
        end
        rows[#rows + 1] = self:_buttons{
            { text = ({ all = _("All"), ongoing = _("Ongoing"), completed = _("Completed") })[self.filter], callback = function()
                self.filter = ({ all = "ongoing", ongoing = "completed", completed = "all" })[self.filter]
                self.page = 1; self:_render()
            end },
            { text = _("Change search"), callback = function() self:_editSearch() end },
        }
        rows[#rows + 1] = W.space(10)
        rows[#rows + 1] = W.text(self.status or string.format(_("%d results"), #results), self.width, 16, { muted = true })
        rows[#rows + 1] = W.space(10)
        rows[#rows + 1] = self:_paginate(results, 91, W.scale(202), function(comic) return self:_comicCard(comic, false) end)
    end
    return W.column(rows)
end

function Screens:_lookupComicID()
    self:_closeDialog()
    local dialog
    dialog = InputDialog:new{ title = _("Open by comic ID"), input = "", input_hint = "mc12345", modal = true,
        description = _("Enter a positive comic ID, such as mc12345."),
        buttons = { { { text = _("Cancel"), callback = function() self:_closeDialog() end },
            { text = _("Open comic"), is_enter_default = true, callback = function()
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

function Screens:_importSession()
    self:_closeDialog()
    local dialog
    dialog = InputDialog:new{ title = _("Import web session"), input = "", input_hint = _("Paste the Cookie header from your own Bilibili web session"), modal = true,
        text_type = "password", description = _("Your session is stored privately on this device. Replacing it switches the account used by this plugin."),
        buttons = { { { text = _("Import from file"), callback = function()
            if self.dialog == dialog then self:_importSessionFile() end
        end } }, { { text = _("Cancel"), callback = function() self:_closeDialog() end },
            { text = _("Import session"), callback = function()
                local text = dialog:getInputText()
                self:_closeDialog()
                self:_invoke("importSession", { text }, function(_value, error)
                    if error then self:_error(error) else self.loaded = {}; self:showAccount() end
                end)
            end } } } }
    self.dialog = dialog; UIManager:show(dialog); dialog:onShowKeyboard()
end

function Screens:_sessionFileCurrent(state, result)
    local current = accountKey(self.controller)
    return self.session_input == state and self.route ~= nil and self.epoch == state.epoch
        and ((current == state.account_key and self.controller.generation == state.generation)
            or (result and result.account_key == current))
end

function Screens:_sessionFileError(err)
    self:_closeDialog()
    local messages = {
        size = _("Choose a session text file no larger than 128 KiB."),
        regular_file = _("Choose a regular file. Folders and symbolic links cannot be imported."),
        format = _("Choose a nonempty .txt, .json or .cookies session file."),
        read = _("The selected session file could not be read. Check its location and permissions."),
    }
    self.dialog = ButtonDialog:new{ title = _("Session could not be imported") .. "\n\n" .. (messages[err and err.code] or messages.read),
        buttons = { { { text = _("Close"), callback = function() self:_closeDialog() end } } }, modal = true }
    UIManager:show(self.dialog)
end

function Screens:_importSessionFile()
    self:_closeDialog()
    local host = self.controller.host_ui or require("apps/reader/readerui").instance
        or require("apps/filemanager/filemanager").instance
    if not host or not host.folder_shortcuts then self:_sessionFileError({ code = "read" }); return end
    local state = { epoch = self.epoch, account_key = accountKey(self.controller), generation = self.controller.generation }
    self.session_input = state
    local chooser
    chooser = FileChooser:new{
        ui = host,
        title = _("Choose a session file"), path = require("apps/filemanager/filemanagerutil").getHomeFolder(),
        modal = true, show_unsupported = false, file_filter = SessionInput.accepts,
        show_file = function(_chooser, filename) return SessionInput.accepts(filename) end,
        onFileSelect = function(_chooser, item)
            if not self:_sessionFileCurrent(state) or state.selected then return end
            state.selected = true
            local selected_path = item.path
            UIManager:close(chooser)
            if self.dialog == chooser then self.dialog = nil end
            -- The native picker must finish closing before the import status is shown.
            UIManager:nextTick(function()
                if not self:_sessionFileCurrent(state) then return end
                local content, err = SessionInput.read(selected_path)
                if not content then self:_sessionFileError(err); return end
                self.dialog = ButtonDialog:new{ title = _("Validating the selected session…"),
                    buttons = { { { text = _("Close"), callback = function() self:_closeDialog() end } } }, modal = true }
                UIManager:show(self.dialog)
                local function completed(result, error)
                    if state.completed then return end
                    state.completed = true
                    if not self:_sessionFileCurrent(state, result) then return end
                    if error or not result then self:_error(error); return end
                    self:_closeDialog(); self.loaded = {}; self:_render()
                    self.dialog = ButtonDialog:new{ title = _("Session imported") .. "\n\n" .. _("The selected session was validated and saved."),
                        buttons = { { { text = _("Close"), callback = function() self:_closeDialog() end } } }, modal = true }
                    UIManager:show(self.dialog)
                end
                local ok = pcall(function() self.controller:importSession(content, completed) end)
                content = nil
                if not ok then completed(nil, { kind = "internal" }) end
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

function Screens:_account()
    local account, wallet = self.controller:getAccount() or {}, self.controller:getWallet() or {}
    local signed_in = account.session_valid == true or (account.session_valid ~= false and account.id ~= nil)
    local prefetch = self.controller:getSetting("prefetch_pages", 3)
    local cache_limit = self.controller:getSetting("cache_limit_mb", 512)
    local storage = self.controller:getStorageSummary() or {}
    local rows = {
        W.text(signed_in and (account.name or _("Signed in")) or _("Not signed in"), self.width, 27, { display = true, bold = true }),
        W.space(8), W.text(string.format(_("Coins: %s · Coupons: %s"), tostring(wallet.remain_gold or "—"),
            tostring(wallet.remain_coupon or "—")), self.width, 19), W.space(6),
        W.text(wallet.stale and _("Balance may be outdated. Refresh before reviewing a purchase.") or _("Purchases use your existing balance and eligible coupons."),
            self.width, 16, { muted = true, height = W.scale(38) }), W.space(10),
        self:_buttons{
            { text = signed_in and _("Replace session") or _("Import session"), callback = function() self:_importSession() end },
            { text = _("Import from file"), callback = function() self:_importSessionFile() end },
            { text = _("Refresh balance"), callback = function() self:_invoke("refreshWallet", {}, function(_value, error)
                if error then self:_error(error) end
            end) end },
        }, W.space(18), W.rule(self.width, true), W.space(12),
        W.text(_("Reading and cache"), self.width, 21, { bold = true }), W.space(8),
        self:_buttons{
            { text = _("Reader defaults"), callback = function() self:_readerDefaults() end },
            { text = _("Local diagnostics"), callback = function() self:_diagnostics() end },
        }, W.space(6),
        self:_button(string.format(_("Preload next images: %d"), prefetch), self.width, function()
            self.controller:setSetting("prefetch_pages", ({ [0] = 1, [1] = 3, [3] = 5, [5] = 0 })[prefetch] or 3); self:_render()
        end, { align = "left" }), W.space(6),
        self:_button(string.format(_("Automatic cache limit: %d MiB"), cache_limit), self.width, function()
            self.controller:setSetting("cache_limit_mb", ({ [256] = 512, [512] = 1024, [1024] = 2048, [2048] = 256 })[cache_limit] or 512); self:_render()
        end, { align = "left" }), W.space(10),
        W.text(string.format(_("Automatic cache: %s · Downloads: %s"), Model.bytes(storage.automatic_bytes or storage.cache_bytes),
            Model.bytes(storage.pinned_bytes or storage.retained_bytes)), self.width, 16, { muted = true }), W.space(8),
        self:_button(_("Clear automatic cache"), self.width, function()
            self:_closeDialog()
            self.dialog = ConfirmBox:new{ text = _("Clear automatic cache? Explicit downloads and current reading content are preserved."),
                ok_text = _("Clear cache"), ok_callback = function()
                    local _, error = self.controller:clearAutomaticCache()
                    if error then self:_error(error) end; self:_render()
                end }
            UIManager:show(self.dialog)
        end),
    }
    local pending = Model.pending(self.controller)
    if #pending > 0 then
        rows[#rows + 1] = W.space(14)
        rows[#rows + 1] = self:_button(string.format(_("Purchases awaiting confirmation: %d"), #pending), self.width,
            function() self:_pendingList(pending) end, { primary = true })
    end
    return W.column(rows)
end

function Screens:_readerDefaults()
    self:_closeDialog()
    local mode = self.controller:getSetting("reading_mode", "auto")
    local direction = self.controller:getSetting("reading_direction", "ltr")
    local function choose(key, value)
        local saved, error = self.controller:setSetting(key, value)
        if saved == nil and error then self:_error(error) else self:_readerDefaults() end
    end
    local function label(message, selected) return (selected and "[x] " or "[ ] ") .. _(message) end
    self.dialog = ButtonDialog:new{ modal = true, title = _("Reader defaults") .. "\n\n"
        .. _("These defaults apply to new chapters. Saved chapter settings and reading positions are preserved."), buttons = {
        { { text = label("Automatic", mode == "auto"), callback = function() choose("reading_mode", "auto") end },
          { text = label("Page comic", mode == "page"), callback = function() choose("reading_mode", "page") end },
          { text = label("Long strip", mode == "strip"), callback = function() choose("reading_mode", "strip") end } },
        { { text = label("Left to right", direction == "ltr"), callback = function() choose("reading_direction", "ltr") end },
          { text = label("Right to left", direction == "rtl"), callback = function() choose("reading_direction", "rtl") end } },
        { { text = _("Close"), callback = function() self:_closeDialog() end } },
    } }
    UIManager:show(self.dialog)
end

function Screens:_diagnostics()
    self:_closeDialog()
    local epoch = self.epoch
    local loading = ButtonDialog:new{ modal = true, title = _("Checking local capabilities…"), buttons = {
        { { text = _("Close"), callback = function() self:_closeDialog() end } },
    } }
    self.dialog = loading; UIManager:show(loading)
    self.controller:getDiagnostics(function(snapshot, error)
        if self.epoch ~= epoch or self.dialog ~= loading or not UIManager:isWidgetShown(loading) then return end
        self:_closeDialog()
        if error then self:_error(error); return end
        local session_labels = { stored = _("Saved; server validity was not checked"), invalid = _("Marked invalid; import a new session"), missing = _("No usable local session") }
        local platform = snapshot.platform or {}
        local function known(value) return value and value ~= "unknown" and value or _("Unknown") end
        local lines = {
            string.format(_("Plugin version: %s"), known(snapshot.plugin_version)),
            string.format(_("KOReader version: %s"), known(snapshot.koreader_version)),
            string.format(_("Platform: %s / %s / %s"), known(platform.os), known(platform.arch), known(platform.target)),
            "", string.format(_("Local session: %s"), session_labels[snapshot.local_session] or session_labels.missing),
            string.format(_("Credential storage: %s"), snapshot.credential_storage == "app_private" and _("App-private directory") or _("Account directory")),
            "", _("Local capabilities"),
        }
        for _index, item in ipairs({ { "request_signing", _("Request signing") }, { "response_decoding", _("Response decoding") },
            { "image_index", _("Chapter image index") }, { "image_tokens", _("Image access adapter") },
            { "encrypted_images", _("Image conversion") }, { "purchase", _("Purchase adapter") } }) do
            local value = (snapshot.capabilities or {})[item[1]]
            local state = value == true and _("Locally available") or value == false and _("Locally unavailable") or _("Not checked")
            lines[#lines + 1] = item[2] .. ": " .. state
        end
        lines[#lines + 1], lines[#lines + 2] = "", _("These local checks do not verify the Bilibili service, account access, image retrieval or purchases.")
        self.dialog = TextViewer:new{ title = _("Local diagnostics"), text = table.concat(lines, "\n"), modal = true }
        UIManager:show(self.dialog)
    end)
end

function Screens:_pendingList(pending)
    self:_closeDialog()
    local epoch, account_key = self.epoch, accountKey(self.controller)
    local generation = self.controller.generation
    local buttons = {}
    for _index, intent in ipairs(pending) do
        local label = string.format(intent.range_outcome_pending and _("Review purchase %s") or _("Refresh purchase %s"), tostring(intent.id))
        if intent.range_outcome_pending then label = label .. "\n" .. _("Range result pending; purchases paused") end
        buttons[#buttons + 1] = { { text = label, height = intent.range_outcome_pending and W.scale(62) or nil, callback = function()
                if epoch ~= self.epoch or account_key ~= accountKey(self.controller) or generation ~= self.controller.generation then return end
                self.purchase_state = { intent = intent, comic = self.controller:getComic(intent.comic_id) or {},
                    episode = { id = (intent.quote or {}).episode_id or (intent.episode_ids or {})[1] }, quote = intent.quote,
                    purpose = purchasePurpose(intent), epoch = self.epoch, account_key = accountKey(self.controller), generation = generation }
                self.purchase_visible = true
            self:_purchaseDialog()
        end } }
    end
    buttons[#buttons + 1] = { { text = _("Close"), callback = function() self:_closeDialog() end } }
    self.dialog = ButtonDialog:new{ title = _("Purchases awaiting confirmation"), buttons = buttons, modal = true }
    UIManager:show(self.dialog)
end

function Screens:_purchaseFor(comic, episode, purpose)
    self.purchase_state = { comic = comic, episode = episode, loading = true, purpose = purchasePurpose(nil, purpose),
        epoch = self.epoch, account_key = accountKey(self.controller), generation = self.controller.generation }
    self.purchase_visible = true
    for _index, intent in ipairs(Model.pending(self.controller)) do
        for _index, id in ipairs(intent.episode_ids or {}) do
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
    state.loading, state.error, state.quote = true, nil, nil
    state.request = (state.request or 0) + 1
    local request = state.request
    self:_purchaseDialog()
    -- Nil arguments must retain their positions before the async callback.
    local epoch = self.epoch
    self.controller:quotePurchase(tostring(state.episode.id), scope, payment, function(quote, error)
        if not self:_purchaseCurrent(state) or request ~= state.request or epoch ~= self.epoch then return end
        state.loading, state.quote, state.error = nil, quote, error
        if quote then
            state.scope, state.payment = Model.purchaseScope(quote.scope), Model.purchasePayment(quote.payment)
            state.options_quote = quote
        end
        self:_purchaseDialog()
    end)
end

function Screens:_scopeText(quote)
    local episodes, lines = Model.array(self.controller:getEpisodes(quote.comic_id)), {}
    local by_id = {}; for _index, episode in ipairs(episodes) do by_id[tostring(episode.id)] = title(episode) end
    if (quote.scope or {}).kind == "batch" then
        lines[#lines + 1] = Model.ordinalRange(quote) and Model.purchaseRangeLabel(quote.scope) or _("Batch selection")
        lines[#lines + 1] = _("Catalog updates or purchases elsewhere may change the actual chapters. Details show the current expected list.")
        local anchor_id = tostring(quote.episode_id or "")
        local selected = (self.purchase_state or {}).episode
        local anchor_title = type(selected) == "table" and tostring(selected.id) == anchor_id and title(selected) or by_id[anchor_id]
        if anchor_title then lines[#lines + 1] = string.format(_("Starting chapter: %s"), anchor_title) end
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("Current expected chapters:")
    end
    for _index, id in ipairs(quote.episode_ids or {}) do lines[#lines + 1] = by_id[tostring(id)] or tostring(id) end
    return table.concat(lines, "\n")
end

local function purchaseLabel(value)
    if type(value) ~= "string" and type(value) ~= "number" then return "?" end
    local text = tostring(value):gsub("[%c]", " ")
    return #text <= 48 and text or text:sub(1, 45) .. "…"
end

local function purchaseDiscountName(kind)
    local names = { none = _("No discount"), discount_card = _("Discount coupon"),
        activity = _("Activity offer"), free_gold_card = _("Free-coin card") }
    return names[kind] or _("Unverified discount")
end

function Screens:_purchaseSelectionText(state, trusted_quote)
    local scope, payment = state.scope or {}, state.payment or {}
    local range = trusted_quote and Model.ordinalRange(trusted_quote) and Model.purchaseRangeLabel(scope)
    local lines = { scope.kind == "batch" and (range or _("Batch selection")) or _("Single chapter"),
        string.format(_("Payment: %s"), asset(payment.method)) }
    if type(payment.discount) == "table" and payment.discount.kind ~= "none" then
        lines[#lines + 1] = string.format(_("Selected discount: %s / %s"), purchaseDiscountName(payment.discount.kind), purchaseLabel(payment.discount.id))
    elseif payment.method == "coin" then
        lines[#lines + 1] = _("No discount")
    end
    if type(payment.coupon_ids) == "table" and #payment.coupon_ids > 0 then
        lines[#lines + 1] = string.format(_("Selected coupons: %d"), #payment.coupon_ids)
    end
    if trusted_quote and (trusted_quote.payment or {}).method == "coupon" then
        local ids = Model.couponIdentifiers(trusted_quote)
        if ids then
            lines[#lines + 1] = _("Coupon IDs (identification only):")
            for _index, id in ipairs(ids) do lines[#lines + 1] = id end
        else lines[#lines + 1] = _("Coupon identifiers are unavailable in this quote.") end
    end
    if payment.method == "coin" then
        lines[#lines + 1] = scope.order == 2 and _("Order: expiry") or _("Order: discount")
    end
    return table.concat(lines, "\n")
end

function Screens:_candidateAmountLines(quote)
    local values, lines = type(quote.amounts) == "table" and quote.amounts or {}, {}
    for _index, field in ipairs({ { "original", _("Platform original price: %s") },
        { "display", _("Platform display reference: %s") }, { "submission", _("Settlement reference (not confirmed charge): %s") },
        { "free_gold", _("Free-coin deduction reference: %s") } }) do
        local value = Model.purchaseNumber(values[field[1]])
        if value then lines[#lines + 1] = string.format(field[2], value) end
    end
    return lines
end

function Screens:_candidateDetails(state, quote)
    local labels = { scope_unverified = _("Chapter range is not verified."), amount_unverified = _("Final charge is not verified."),
        asset_unverified = _("Payment asset is not verified."), discount_unverified = _("The discount is not verified."),
        entitlement_unverified = _("The resulting access is not verified."), asset_unavailable = _("The selected payment asset is unavailable."),
        context_unverified = _("The offer context is not verified."), offer_unavailable = _("The selected offer is unavailable.") }
    local lines = { _("This candidate cannot be submitted. Its exact chapters and final charge have not been confirmed."),
        "", self:_purchaseSelectionText(state), "", _("Reported amounts are separate observations, not a confirmed payable total.") }
    for _index, line in ipairs(self:_candidateAmountLines(quote)) do lines[#lines + 1] = line end
    local seen = {}
    lines[#lines + 1] = ""
    for _index, code in ipairs(type(quote.blockers) == "table" and quote.blockers or {}) do
        local message = labels[code] or _("Additional verification is required.")
        if not seen[message] then lines[#lines + 1] = message; seen[message] = true end
    end
    self.scope_dialog = TextViewer:new{ title = _("Unverified offer details"), text = table.concat(lines, "\n"), modal = true }
    UIManager:show(self.scope_dialog)
end

function Screens:_purchaseChoices(which, page)
    local state = self.purchase_state
    if not state or not self:_purchaseCurrent(state) or state.loading or state.submitting or state.intent then return end
    local source, request = state.quote or state.options_quote, state.request
    if not source then source = {}; state.options_quote = source end
    local entries = {}
    local function add(selection, label, available, details)
        for _index, entry in ipairs(entries) do if Model.samePurchaseSelection(entry.selection, selection) then return end end
        entries[#entries + 1] = { selection = selection, label = label, available = available ~= false, details = details or {} }
    end
    if which == "scope" then
        add(Model.purchaseScope({ kind = "single", order = (state.scope or {}).order }), _("Single chapter"), true)
        if state.purpose ~= "download" then
            for index, offer in ipairs(source.batch_offers or {}) do
                if type(offer.scope) == "table" and offer.scope.kind == "batch" then
                    local details, amount = {}, Model.purchaseNumber(offer.amount)
                    if amount and offer.scope.batch_limit ~= 0 then details[#details + 1] = string.format(_("Reported chapters: %s"), amount) end
                    local original, display = Model.purchaseNumber(offer.original_amount), Model.purchaseNumber(offer.display_amount)
                    if original then details[#details + 1] = string.format(_("Platform original price: %s"), original) end
                    if display then details[#details + 1] = string.format(_("Platform display reference: %s"), display) end
                    add(Model.purchaseScope(offer.scope), offer.scope.batch_limit == 0 and _("Remaining from this chapter")
                        or string.format(_("Batch offer %d"), index), offer.available, details)
                end
            end
            for index, option in ipairs(source.scopes or {}) do
                if option.kind == "batch" then
                    add(Model.purchaseScope(option), option.batch_limit == 0 and _("Remaining from this chapter")
                        or string.format(_("Supported batch %s"), purchaseLabel(option.batch_limit or index)), option.available)
                end
            end
        end
    else
        for _index, option in ipairs(source.payments or {}) do
            add(Model.purchasePayment(option), asset(option.method), option.available)
        end
        add(Model.purchasePayment({ method = "coin" }), _("Coins without discount"), true)
        for index, option in ipairs(source.discount_options or {}) do
            if type(option.payment) == "table" then
                local discount = option.payment.discount or {}
                add(Model.purchasePayment(option.payment), string.format(_("Coin discount option %d"), index), option.available,
                    { string.format(_("Discount: %s / %s"), purchaseDiscountName(discount.kind), purchaseLabel(discount.id)) })
            end
        end
        add(Model.purchasePayment(state.payment), _("Current payment selection"), false, { self:_purchaseSelectionText(state) })
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
    local heading = which == "scope" and _("Choose purchase range") or _("Choose payment option")
    if which == "scope" and #(source.batch_offers or {}) > 0 then
        heading = heading .. "\n" .. _("Reported offer amounts do not confirm the final charge.")
    end
    local buttons = {}
    for index = (page - 1) * per_page + 1, math.min(page * per_page, #entries) do
        local entry = entries[index]
        heading = heading .. "\n\n" .. entry.label
        for _detail_index, line in ipairs(entry.details) do heading = heading .. "\n" .. line end
        buttons[#buttons + 1] = { { text = (Model.samePurchaseSelection(entry.selection, selected) and "[x] " or "[ ] ") .. entry.label,
            enabled = entry.available, callback = function()
                if not current() or not entry.available then return end
                if which == "scope" then self:_quote(entry.selection, Model.purchasePayment(state.payment))
                else self:_quote(Model.purchaseScope(state.scope), entry.selection) end
            end } }
    end
    buttons[#buttons + 1] = {
        { text = _("Previous"), enabled = page > 1, callback = function() if current() then self:_purchaseChoices(which, page - 1) end end },
        { text = string.format(_("%d / %d"), page, pages), enabled = false },
        { text = _("Next"), enabled = page < pages, callback = function() if current() then self:_purchaseChoices(which, page + 1) end end },
    }
    buttons[#buttons + 1] = { { text = _("Back to quote"), callback = function() if current() then self:_purchaseDialog() end end } }
    dialog = ButtonDialog:new{ title = heading, buttons = buttons, dismissable = false, modal = true, width_factor = 0.94 }
    self.dialog = dialog; UIManager:show(dialog)
end

function Screens:_purchaseSelectionButtons(state, buttons, current)
    buttons[#buttons + 1] = {
        { text = _("Choose range"), enabled = not state.submitting, callback = function() if current() then self:_purchaseChoices("scope") end end },
        { text = _("Choose payment"), enabled = not state.submitting, callback = function() if current() then self:_purchaseChoices("payment") end end },
    }
    if (state.payment or {}).method == "coin" then
        local function order(value)
            if not current() then return end
            local scope = Model.purchaseScope(state.scope); scope.order = value
            self:_quote(scope, Model.purchasePayment(state.payment))
        end
        buttons[#buttons + 1] = {
            { text = ((state.scope.order or 1) == 1 and "[x] " or "[ ] ") .. _("By discount"), enabled = not state.submitting, callback = function() order(1) end },
            { text = (state.scope.order == 2 and "[x] " or "[ ] ") .. _("By expiry"), enabled = not state.submitting, callback = function() order(2) end },
        }
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
    local function current()
        return self:_purchaseCurrent(state) and self.dialog == dialog and UIManager:getTopmostVisibleWidget() == dialog
            and state.request == request and not state.loading and not state.submitting and not state.intent
    end
    local heading = (candidate and _("Review unverified offer") or _("Review purchase")) .. "\n" .. title(state.comic)
    heading = heading .. "\n" .. (purpose == "download" and _("Next action: download this chapter") or _("Next action: read this chapter"))
    local buttons = {}
    if state.loading then
        heading = heading .. "\n\n" .. _("Getting the current price…")
    elseif state.error then
        local error_title, message, action = Model.error(state.error)
        heading = heading .. "\n\n" .. error_title .. "\n" .. message
        if action == "account" then
            buttons[#buttons + 1] = { { text = _("Open account"), callback = function() if current() then self:showAccount() end end } }
        end
        self:_purchaseSelectionButtons(state, buttons, current)
        buttons[#buttons + 1] = {
            { text = _("Single chapter"), callback = function()
                if current() then self:_quote({ kind = "single", order = (state.scope or {}).order }, Model.purchasePayment(state.payment)) end
            end },
            { text = _("Refresh quote"), callback = function() if current() then self:_quote(nil, nil) end end },
        }
    elseif intent then
        local confirmed = intent.state == "access_confirmed" and not intent.persistence_pending
        local rejected = intent.state == "rejected" and not intent.persistence_pending
        local range_pending = intent.range_outcome_pending == true
        heading = heading .. "\n\n" .. (confirmed and (not range_pending and intent.transaction_evidence == "server_accepted" and _("Purchase confirmed") or _("Chapter access confirmed"))
            or rejected and _("Purchase rejected") or _("Purchase result pending"))
        heading = heading .. "\n" .. (confirmed and (range_pending
            and _("Reading access is confirmed, but the range purchase result is still unknown. Further purchases for this comic are paused.")
            or _("Reading access is ready. Image loading can be retried without purchasing again."))
            or rejected and _("The purchase was not accepted. Get a new quote before trying again.")
            or _("This purchase will not be sent again. Refresh the result to confirm chapter access."))
        if confirmed then
            buttons[#buttons + 1] = { { text = purpose == "download" and (state.continuation_error and _("Retry download") or _("Download chapter")) or _("Read chapter"),
                enabled = not state.continuing, callback = function()
                if not self:_purchaseCurrent(state) or state.intent ~= intent or state.continuing then return end
                state.continuing, state.continuation_error, state.notice = true, nil, nil
                local episode_id = tostring((intent.quote or {}).episode_id or (intent.episode_ids or {})[1])
                self:_purchaseDialog()
                self:_invoke(purpose == "download" and "downloadEpisodes" or "readEpisode",
                    { tostring(intent.comic_id), purpose == "download" and { episode_id } or episode_id }, function(_value, error)
                    state.continuing = nil
                    if not self:_purchaseCurrent(state) then return end
                    if error then
                        local error_title, message = Model.error(error)
                        state.continuation_error, state.notice = error, error_title .. "\n" .. message
                        self:_purchaseDialog()
                    elseif purpose == "download" then self:showDownloads()
                    else self:close() end
                end, true)
            end } }
        elseif rejected then
            buttons[#buttons + 1] = { { text = _("Get new quote"), callback = function()
                if self:_purchaseCurrent(state) and state.intent == intent then state.intent = nil; self:_quote(nil, nil) end
            end } }
        else
            buttons[#buttons + 1] = { { text = state.submitting and _("Checking result…") or _("Refresh result"), enabled = not state.submitting,
                callback = function()
                    if not self:_purchaseCurrent(state) or state.submitting then return end
                    state.submitting = true; self:_purchaseDialog()
                    self.controller:reconcilePurchase(intent.id, function(value, error)
                        state.submitting = nil
                        if value then state.intent = value end
                        if self:_purchaseCurrent(state) then
                            if error and not value then state.notice = _("Result is still pending. Check the connection and refresh again.") end
                            self:_purchaseDialog()
                        end
                    end)
                end } }
        end
    elseif candidate then
        heading = heading .. "\n\n" .. _("Final charge is not confirmed. This offer cannot be submitted.")
        local display = Model.purchaseNumber((quote.amounts or {}).display)
        if display then heading = heading .. "\n" .. string.format(_("Platform display reference: %s"), display) end
        self:_purchaseSelectionButtons(state, buttons, current)
        buttons[#buttons + 1] = { { text = _("Review candidate details"), callback = function()
            if current() and state.quote == quote then self:_candidateDetails(state, quote) end
        end } }
        buttons[#buttons + 1] = {
            { text = _("Single chapter"), callback = function()
                if current() then self:_quote({ kind = "single", order = (state.scope or {}).order }, Model.purchasePayment(state.payment)) end
            end },
            { text = _("Refresh quote"), callback = function() if current() then self:_quote(nil, nil) end end },
        }
    elseif quote then
        local amount = tostring(quote.amount or "?")
        local batch, ordinal = (quote.scope or {}).kind == "batch", Model.ordinalRange(quote)
        if batch then
            heading = heading .. "\n\n" .. (ordinal and Model.purchaseRangeLabel(quote.scope) or _("Batch selection"))
                .. "\n" .. string.format(_("Total: %s %s"), amount, asset(quote.method))
        else
            heading = heading .. "\n\n" .. string.format(_("%d chapters · %s %s"), #(quote.episode_ids or {}), amount, asset(quote.method))
        end
        local permanent = #(quote.episode_ids or {}) > 0
        for _index, id in ipairs(quote.episode_ids or {}) do
            local access = (quote.expected_access or {})[tostring(id)]
            if not access or access.access ~= "owned" then permanent = false end
        end
        heading = heading .. "\n" .. (permanent and _("Permanent ownership") or _("Chapter reading access"))
        heading = heading .. "\n" .. string.format(_("Available: %s %s"), tostring(quote.balance or "?"), asset(quote.method))
        if (state.payment or {}).discount and state.payment.discount.kind ~= "none" then
            heading = heading .. "\n" .. _("A discount option is selected; review its payment details.")
        end
        local scope_text = self:_scopeText(quote)
        if batch then
            heading = heading .. "\n" .. _("Catalog updates or purchases elsewhere may change the actual chapters. Details show the current expected list.")
        elseif #(quote.episode_ids or {}) <= 3 then heading = heading .. "\n" .. scope_text end
        buttons[#buttons + 1] = { { text = batch and _("Review expected chapters") or _("Review exact chapters"), enabled = not state.submitting, callback = function()
            if not current() or state.quote ~= quote or quote.submittable == false then return end
            self.scope_dialog = TextViewer:new{ title = batch and _("Expected purchase chapters") or _("Purchase scope"), text = scope_text .. "\n\n"
                .. self:_purchaseSelectionText({ scope = quote.scope, payment = quote.payment }, quote), modal = true }
            UIManager:show(self.scope_dialog)
        end } }
        self:_purchaseSelectionButtons(state, buttons, current)
        if quote.can_afford == false then
            heading = heading .. "\n\n" .. _("Insufficient balance")
            buttons[#buttons + 1] = { { text = _("Refresh balance"), enabled = not state.submitting, callback = function()
                if not current() or state.quote ~= quote then return end
                self:_invoke("refreshWallet", {}, function(_value, error)
                    if not current() or state.quote ~= quote then return end
                    if error then self:_error(error) else self:_quote(Model.purchaseScope(state.scope), Model.purchasePayment(state.payment)) end
                end, true)
            end } }
        elseif quote.submittable ~= false and quote.can_afford == true and quote.amount ~= nil and quote.fingerprint then
            buttons[#buttons + 1] = { { text = state.submitting and _("Submitting purchase…")
                or string.format(_("Confirm purchase · %s %s"), amount, asset(quote.method)), enabled = not state.submitting,
                callback = function()
                    if not current() or state.error or state.quote ~= quote or quote.submittable == false then return end
                    state.submitting = true; self:_purchaseDialog()
                    self.controller:purchase(quote, purpose, function(value, error)
                        state.submitting = nil
                        if value then state.intent = value
                        elseif error and (error.kind == "outcome_unknown" or error.kind == "purchase_unknown" or error.kind == "purchase_busy") then
                            -- The persistent pending record is authoritative after an interrupted worker.
                            for _index, pending in ipairs(Model.pending(self.controller)) do
                                if pending.quote and pending.quote.fingerprint == quote.fingerprint then state.intent = pending; break end
                            end
                            if not state.intent then state.intent = { state = "outcome_unknown", comic_id = quote.comic_id,
                                episode_ids = quote.episode_ids, quote = quote, id = error.intent_id, purpose = purpose } end
                        else state.error = error or { kind = "internal" } end
                        if self:_purchaseCurrent(state) then self:_purchaseDialog() end
                    end)
                end } }
        end
    end
    if state.notice then heading = heading .. "\n\n" .. state.notice end
    buttons[#buttons + 1] = { { text = _("Close"), enabled = not state.submitting, callback = function() self:_closeDialog() end } }
    dialog = ButtonDialog:new{ title = heading, buttons = buttons, dismissable = not state.submitting, width_factor = 0.94, modal = true,
        tap_close_callback = function() self:_closeDialog() end }
    self.dialog = dialog; UIManager:show(dialog)
end

return Screens
