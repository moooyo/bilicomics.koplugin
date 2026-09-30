local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local UIManager = require("ui/uimanager")
local W = require("bilicomics/ui/widgets")
local Model = require("bilicomics/ui/model")
local Helpers = require("bilicomics/ui/screen_helpers")
local T = require("bilicomics/ui/i18n")
local title, accountKey = Helpers.title, Helpers.accountKey
local Screen = Device.screen

local function space(value) return W.spacePixels(W.dp(value)) end
local function text(value, width, size, options) return W.text(value, width, W.fontSize(size), options) end
local function stopped(job) return job.state == "paused" or job.state == "failed" or job.state == "canceled" end
local function savedCount(job) return math.max(0, math.floor(tonumber(job.completed) or 0)) end
local function totalCount(job) return math.max(0, math.floor(tonumber(job.total) or 0)) end
local function copyReference(job, short)
    local value = tostring(job.revision or job.id or ""):gsub("[%c]", " ")
    if short and #value > 22 and value:match("^[%w%._%-:]+$") then return value:sub(1, 10) .. "…" .. value:sub(-8) end
    return value
end

local function downloadFlow(heading, paragraphs, buttons, options)
    options = options or {}
    local adjusted, capture = {}, {}
    for _, paragraph in ipairs(paragraphs or {}) do
        local value = type(paragraph) == "table" and paragraph or { text = paragraph }
        adjusted[#adjusted + 1] = { text = value.text, size = W.fontSize(value.size or 20), bold = value.bold,
            muted = value.muted, line_height = value.line_height }
        if value.text then capture[#capture + 1] = value.text end
    end
    local replacement = options.on_replace
    options.on_replace = function(next_dialog, previous)
        next_dialog.download_text = previous.download_text
        if replacement then replacement(next_dialog, previous)
        else UIManager:close(previous); UIManager:show(next_dialog) end
    end
    local dialog = W.flowDialog(heading, adjusted, buttons, options)
    dialog.download_text = options.capture_text or table.concat(capture, "\n")
    return dialog
end

local function downloadMenu(heading, paragraphs, buttons, options)
    local adjusted, capture = {}, {}
    for _, paragraph in ipairs(paragraphs or {}) do
        local value = type(paragraph) == "table" and paragraph or { text = paragraph }
        adjusted[#adjusted + 1] = { text = value.text, size = W.fontSize(value.size or 19), bold = value.bold, muted = value.muted }
        if value.text then capture[#capture + 1] = value.text end
    end
    local dialog = W.menuDialog(heading, adjusted, buttons, options)
    dialog.download_text = table.concat(capture, "\n")
    return dialog
end

return function(Screens)

function Screens:_downloadIdentity(job)
    local payload = job.payload or {}
    local comic = self.controller:getComic(job.comic_id) or { id = job.comic_id }
    local episode = self.controller.getEpisode and self.controller:getEpisode(job.episode_id)
    if not episode then
        for _index, item in ipairs(Model.array(self.controller:getEpisodes(job.comic_id))) do
            if tostring(item.id) == tostring(job.episode_id) then episode = item; break end
        end
    end
    return payload.comic_title or title(comic), payload.title or (episode and title(episode)) or tostring(job.episode_id or ""), episode
end

function Screens:_downloadCopyLabel(job, short)
    local payload = job.payload or {}
    local kind = payload.replaced_by and T("Retained copy") or payload.replaces_job_id and T("New copy") or T("Current copy")
    return kind .. " · " .. (job.revision and copyReference(job, short) or T("Not prepared yet"))
end

function Screens:_downloadTargetText(job)
    local comic, chapter = self:_downloadIdentity(job)
    return string.format(T("Comic: %s\nChapter: %s\nCopy: %s"), comic, chapter, self:_downloadCopyLabel(job, false))
end

function Screens:_downloadProgress(job)
    local total = totalCount(job)
    return total > 0 and string.format(T("Saved (recorded): %d/%d"), savedCount(job), total)
        or string.format(T("Saved (recorded): %d images"), savedCount(job))
end

function Screens:_downloadRecoveryKind(job, error)
    local account = self.controller:getAccount() or {}
    if account.session_valid == false then return "account" end
    local comic_label, chapter_label, episode = self:_downloadIdentity(job)
    if episode and episode.access and not Model.downloadable(episode) then return "access" end
    local err = error == false and {} or error or job.error or {}
    local kind = type(err) == "table" and err.kind or nil
    local error_heading, error_message, action = Model.error(err)
    if action == "account" then return "account" end
    if kind == "entitlement" or kind == "locked" or kind == "access" then return "access" end
    if kind == "low_space" or kind == "storage" then return "storage" end
    if kind == "busy" or kind == "active_content" or kind == "in_use" or kind == "reference_changed"
        or kind == "stale_source_refresh" or kind == "stale_version_replacement" then return "prerequisite" end
    if kind == "unsupported_image_size" or kind == "capability" or kind == "unsupported" then return "unsupported" end
    if kind == "unknown_history" or kind == "content_changed" or kind == "unverified_position"
        or kind == "version_replacement_interrupted" then return "replace" end
    if kind == "source_unavailable" or kind == "source_refresh_interrupted" then return "refresh" end
    if kind == "network" or kind == "connectivity" or kind == "timeout" or kind == "transport" then return "retry" end
    return "choose"
end

function Screens:_downloadControl(job, context, method)
    if not self:_downloadContextCurrent(context) then return end
    local current = self:_currentDownload(job.id)
    if not current or (current.payload or {}).removed or (current.payload or {}).replaced_by then return end
    if method == "resumeJob" and (not stopped(current) or (current.payload or {}).source_refresh or (current.payload or {}).version_replacement) then return end
    if (method == "pauseJob" or method == "cancelJob") and current.state ~= "running" and current.state ~= "queued" then return end
    local ok, _result, err = pcall(self.controller[method], self.controller, current.id)
    if not self:_downloadContextCurrent(context) then return end
    if not ok then self:_downloadError({ kind = "internal" })
    elseif err then self:_downloadRecovery(self:_currentDownload(job.id) or current, err) end
    self:_render()
end

function Screens:_downloadOpenStorage()
    self:_closeDownloadDialog()
    if self._showStorageSettings then self:_showStorageSettings() else self:showAccount() end
end

function Screens:_downloadActions(job, render_jobs)
    local payload, context = job.payload or {}, self:_downloadContext()
    local comic_label, chapter_label, episode = self:_downloadIdentity(job)
    local readable = not episode or not episode.access or Model.downloadable(episode)
    local primary, secondary = nil, {}
    local function guarded(callback)
        return function()
            if not self:_downloadContextCurrent(context) then return end
            local current = self:_currentDownload(job.id)
            if current and current.revision ~= job.revision then self:_render(); return end
            if current and not (current.payload or {}).removed then callback(current) end
        end
    end
    local function add(text, callback) secondary[#secondary + 1] = { text = text, callback = guarded(callback) } end
    local function setPrimary(text, callback) primary = { text = text, primary = true, callback = guarded(callback) } end
    if payload.replaced_by then
        if readable then setPrimary(T("Open retained copy"), function(current) self:_readDownload(current, context) end)
        else setPrimary(T("Review chapter access"), function(current) self:showComic(current.comic_id) end) end
        local related = render_jobs and render_jobs[tostring(payload.replaced_by)] or not render_jobs and self:_currentDownload(payload.replaced_by)
        if related then add(T("Show current copy"), function() self:_showRelatedDownload(payload.replaced_by) end) end
    elseif payload.version_replacement then
        setPrimary(T("Cancel preparation"), function(current)
            if (current.payload or {}).version_replacement then self:_cancelVersionReplacement(current) end
        end)
    elseif payload.source_refresh then
        setPrimary(T("Cancel verification"), function(current)
            if (current.payload or {}).source_refresh then self:_cancelSourceRefresh(current) end
        end)
    elseif job.state == "complete" then
        if readable then setPrimary(T("Read offline"), function(current) self:_readDownload(current, context) end)
        else setPrimary(T("Review chapter access"), function(current) self:showComic(current.comic_id) end) end
    elseif job.state == "running" or job.state == "queued" then
        setPrimary(T("Pause"), function(current) self:_downloadControl(current, context, "pauseJob") end)
        add(T("Stop download; keep saved images"), function(current) self:_downloadControl(current, context, "cancelJob") end)
    else
        local kind = self:_downloadRecoveryKind(job)
        if kind == "account" then setPrimary(T("Open account"), function() self:showAccount() end)
        elseif kind == "access" then setPrimary(T("Review chapter access"), function(current) self:showComic(current.comic_id) end)
        elseif kind == "storage" then setPrimary(T("Manage storage"), function() self:_downloadOpenStorage() end)
        elseif (kind == "choose" and job.state ~= "failed") or kind == "retry" then
            setPrimary(job.state == "failed" and T("Retry download") or T("Resume"), function(current) self:_downloadControl(current, context, "resumeJob") end)
        else setPrimary(T("Review recovery"), function(current) self:_downloadRecovery(current) end) end
        if primary.text ~= T("Review recovery") and (job.error or self:_canRefreshSources(job) or self:_canReplaceVersion(job)) then
            add(T("Recovery options"), function(current) self:_downloadRecovery(current) end)
        end
        if job.revision and readable then add(T("Open this copy"), function(current) self:_readDownload(current, context) end) end
    end
    if job.revision and not payload.version_replacement then add(T("Remove download"), function(current) self:_confirmRemoveDownload(current) end) end
    if not primary and #secondary > 0 then primary = table.remove(secondary, 1) end
    local actions = primary and { primary } or {}
    if #secondary == 1 then
        secondary[1].borderless = true; actions[#actions + 1] = secondary[1]
    elseif #secondary > 1 then
        actions[#actions + 1] = { text = T("More actions"), borderless = true, callback = guarded(function(current)
            self:_downloadMore(current, secondary)
        end) }
    end
    return actions
end

function Screens:_showDownloadDialog(dialog)
    local owner, context, previous_close = self, self:_downloadContext(), dialog.onCloseWidget
    function dialog:onCloseWidget()
        if previous_close then previous_close(self) end
        if owner.context_dialog ~= self then return end
        local dirty = owner.context_dialog_dirty
        owner.context_dialog, owner.context_dialog_dirty, owner.context_dialog_account = nil, nil, nil
        if owner.dialog == self then owner.dialog = nil end
        if dirty and owner:_downloadContextCurrent(context) then owner:_render() end
    end
    self.dialog, self.context_dialog, self.context_dialog_account = dialog, dialog, context.account_key
    self.context_dialog_dirty = false
    UIManager:show(dialog)
end

function Screens:_closeDownloadDialog()
    Screens._closeDialog(self)
end

function Screens:_downloadError(error)
    self:_closeDownloadDialog()
    local heading, message, action = Model.error(error)
    local dialog, context, buttons = nil, self:_downloadContext(), {}
    if action == "account" then
        buttons[#buttons + 1] = { { text = T("Open account"), callback = function()
            if self.dialog == dialog and self:_downloadContextCurrent(context) then self:showAccount() end
        end } }
    end
    buttons[#buttons + 1] = { { text = T("Close"), callback = function()
        if self.dialog == dialog then self:_closeDownloadDialog() end
    end } }
    dialog = downloadFlow(heading, { message }, buttons, { close = function() if self.dialog == dialog then self:_closeDownloadDialog() end end,
        on_replace = function(replacement, previous)
            UIManager:close(previous); dialog = replacement; self:_showDownloadDialog(replacement)
        end })
    self:_showDownloadDialog(dialog)
end

function Screens:_downloadMore(job, actions)
    self:_closeDownloadDialog()
    local dialog, context, buttons = nil, self:_downloadContext(), {}
    for _index, action in ipairs(actions) do
        local selected = action
        buttons[#buttons + 1] = { { text = selected.text, callback = function()
            if self.dialog ~= dialog or not self:_downloadContextCurrent(context) then return end
            self:_closeDownloadDialog(); selected.callback()
        end } }
    end
    buttons[#buttons + 1] = { { text = T("Close"), callback = function() if self.dialog == dialog then self:_closeDownloadDialog() end end } }
    local opening = (job.payload or {}).replaced_by and T("Only saved images remain readable; missing images cannot be fetched in this copy.")
        or T("Opening the current copy may fetch missing images using your sign-in and network connection.")
    dialog = downloadMenu(T("Download actions"), { { text = self:_downloadTargetText(job), size = 20, bold = true },
        T("Stopping keeps saved images. Removing deletes this copy's saved images."), opening }, buttons,
        { placement = "bottom", close = function() if self.dialog == dialog then self:_closeDownloadDialog() end end,
            on_replace = function(replacement, previous)
                UIManager:close(previous); dialog = replacement; self:_showDownloadDialog(replacement)
            end })
    self:_showDownloadDialog(dialog)
end

function Screens:_downloadActionRow(entries, measure)
    local gap, cells, focus = W.dp(16), {}, {}
    for index, entry in ipairs(entries) do
        local width = #entries == 1 and self.width or math.floor((self.width - gap) / 2)
        if index == #entries then width = self.width - (width + gap) * (index - 1) end
        local options = { primary = entry.primary and entry.text ~= T("Pause"), borderless = entry.borderless,
            size = W.fontSize(20), height_px = W.dp(58) }
        local button = W.button(entry.text, width, entry.callback, options)
        if index > 1 then cells[#cells + 1] = W.gap(gap) end
        cells[#cells + 1], focus[#focus + 1] = button, button
    end
    if not measure and #focus > 0 then self.focus[#self.focus + 1] = focus end
    return W.row(cells), focus
end

function Screens:_jobRow(job, measure, render_jobs)
    local payload = job.payload or {}
    local comic, chapter = self:_downloadIdentity(job)
    local states = { queued = T("Queued"), running = T("Downloading"), paused = T("Paused"), complete = T("Downloaded"),
        failed = T("Needs attention"), canceled = T("Stopped") }
    local status, progress = states[job.state] or T("Queued"), self:_downloadProgress(job)
    if payload.replaced_by then status = T("Retained copy")
    elseif payload.version_replacement then status = T("Preparing new version…")
    elseif payload.source_refresh then
        status = payload.source_refresh.stage == "index" and T("Fetching image sources…") or T("Verifying saved images")
        if payload.source_refresh.stage ~= "index" then
            progress = string.format(T("Checked %d/%d images"), payload.source_refresh.checked or 0, payload.source_refresh.total or 0)
        end
    end
    local action_width, gap = W.dp(190), W.dp(24)
    local info_width = self.width - action_width - gap
    local actions = self:_downloadActions(job, render_jobs)
    local main = actions[1]
    local main_button = main and W.button(main.text, action_width, main.callback,
        { primary = main.primary and self.download_primary_job_id == job.id,
            size = W.fontSize(20), height_px = W.dp(58) })
    local focus = main_button and { main_button } or {}
    local status_text = status .. " · " .. progress
    if payload.replaced_by then status_text = self:_downloadCopyLabel(job, true) .. " · " .. progress end
    local detail = { text(comic .. " · " .. chapter, info_width, 21, { bold = true }), space(8),
        text(status_text, info_width, 17, { muted = not payload.replaced_by }), }
    if job.revision and not payload.replaced_by then
        detail[#detail + 1] = space(5)
        detail[#detail + 1] = text(self:_downloadCopyLabel(job, true)
            .. ((payload.source_refresh or payload.version_replacement) and " · " .. self:_downloadProgress(job) or ""), info_width, 15, { muted = true })
    end
    local rows = { space(16), W.row{ W.column(detail), W.gap(gap), main_button or W.gap(action_width) } }
    if payload.replaced_by then
        rows[#rows + 1] = space(8)
        rows[#rows + 1] = text(T("Only saved images remain readable; missing images cannot be fetched in this copy."), self.width, 17)
    elseif job.error and not payload.source_refresh and not payload.version_replacement then
        local heading = Model.error(job.error)
        rows[#rows + 1] = space(8)
        rows[#rows + 1] = text(heading, self.width, 17)
    end
    if not payload.replaced_by and totalCount(job) > 0 then
        rows[#rows + 1], rows[#rows + 2] = space(12), W.progress(self.width, W.dp(8), savedCount(job) / totalCount(job))
    end
    if #actions > 1 then
        local more = W.button(T("More actions") .. " ›", self.width, function()
            if actions[2].text == T("More actions") then actions[2].callback()
            else self:_downloadMore(job, actions) end
        end,
            { borderless = true, align = "right", size = W.fontSize(17), height_px = W.dp(46) })
        rows[#rows + 1], focus[#focus + 1] = more, more
    end
    rows[#rows + 1], rows[#rows + 2] = space(20), W.rule1dp(self.width, Blitbuffer.Color8(0xCC))
    if not measure and #focus > 0 then self.focus[#self.focus + 1] = focus end
    return W.column(rows), focus
end

function Screens:_readDownload(job, context)
    self:_invoke("readDownload", { job.id }, function(_value, error)
        if not self:_downloadContextCurrent(context) then return end
        if error then self:_downloadError(error) else self:close() end
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
    self:_closeDownloadDialog()
    local context, dialog = self:_downloadContext()
    local heading, message, action
    if error ~= false and (error or job.error) then heading, message, action = Model.error(error or job.error)
    else
        heading, message = T("Choose a recovery method"), T("Verify matching image sources, or download a separate new version while retaining this one.")
    end
    local kind = self:_downloadRecoveryKind(job, error)
    local comic_label, chapter_label, episode = self:_downloadIdentity(job)
    if kind == "account" and action ~= "account" then heading, message = Model.error({ kind = "authentication" }) end
    if kind == "access" then heading, message = T("Review chapter access"), T("Offline rights must be confirmed before downloading missing images.") end
    local buttons = {}
    local function add(text, callback)
        buttons[#buttons + 1] = { { text = text, callback = function()
            if self.dialog ~= dialog or not self:_downloadContextCurrent(context) then return end
            local current = self:_currentDownload(job.id)
            if not current or (current.payload or {}).removed then self:_closeDownloadDialog(); self:_render(); return end
            callback(current)
        end } }
    end
    local can_refresh, can_replace = self:_canRefreshSources(job), self:_canReplaceVersion(job)
    if kind == "account" then
        add(T("Open account"), function() self:showAccount() end)
        if (self.controller:getAccount() or {}).session_valid == true and stopped(job) then
            add(T("Retry with current sign-in"), function(current) self:_closeDownloadDialog(); self:_downloadControl(current, context, "resumeJob") end)
        end
    elseif kind == "access" then
        add(T("Review chapter access"), function(current) self:showComic(current.comic_id) end)
    elseif kind == "storage" then
        add(T("Manage storage"), function() self:_downloadOpenStorage() end)
        add(T("Storage is ready; retry download"), function(current) self:_closeDownloadDialog(); self:_downloadControl(current, context, "resumeJob") end)
    elseif kind == "prerequisite" then
        message = message .. "\n\n" .. T("Close this chapter, pause its other downloads, then review recovery options again. The next operation will check these conditions.")
        add(T("Prerequisites resolved; review options"), function(current) self:_downloadRecovery(current, false) end)
    elseif kind == "unsupported" then
        add(T("Open chapter catalog"), function(current) self:showComic(current.comic_id) end)
    elseif kind == "replace" then
        message = message .. "\n\n" .. T("A separate new copy starts from the beginning. This copy's saved images and reading position stay separate.")
        if can_replace then add(T("Redownload as new version"), function(current) self:_confirmVersionReplacement(current) end) end
    elseif kind == "retry" then
        add(T("Retry download"), function(current) self:_closeDownloadDialog(); self:_downloadControl(current, context, "resumeJob") end)
        if can_refresh or can_replace then add(T("Other recovery options"), function(current) self:_downloadRecovery(current, false) end) end
    else
        if can_refresh then add(T("Refresh image sources"), function(current) self:_confirmSourceRefresh(current) end) end
        if can_replace then add(T("Redownload as new version"), function(current) self:_confirmVersionReplacement(current) end) end
    end
    if job.revision and (not episode or not episode.access or Model.downloadable(episode)) then
        message = message .. "\n\n" .. ((job.payload or {}).replaced_by
            and T("Only saved images remain readable; missing images cannot be fetched in this copy.")
            or T("Opening the current copy may fetch missing images using your sign-in and network connection."))
        add((job.payload or {}).replaced_by and T("Open retained copy") or T("Open this copy"), function(current) self:_closeDownloadDialog(); self:_readDownload(current, context) end)
    end
    if job.revision and not (job.payload or {}).version_replacement then
        add(T("Remove download"), function(current) self:_confirmRemoveDownload(current) end)
    end
    local width, rows = Screen:getWidth() - W.dp(112), {}
    local comic, chapter = self:_downloadIdentity(job)
    rows[#rows + 1] = { widget = W.column{ text(comic .. " · " .. chapter, width, 26, { bold = true }), space(10),
        text(self:_downloadCopyLabel(job, true) .. " · " .. self:_downloadProgress(job), width, 18, { muted = true }),
        space(28), W.rule1dp(width, W.ink), space(32), text(heading, width, 30, { bold = true }), space(20) } }
    for paragraph in (message .. "\n\n"):gmatch("(.-)\n\n") do
        rows[#rows + 1] = { widget = W.column{ text(paragraph, width, 20, { line_height = 0.7 }), space(24) } }
    end
    rows[#rows + 1] = { widget = W.column{ text(T("Choose a recovery method"), width, 20, { bold = true }), space(18) } }
    local descriptions = {
        [T("Redownload as new version")] = T("All images will be downloaded, using additional space and network data. The new copy starts at the beginning."),
        [T("Refresh image sources")] = T("Saved content and reading position are preserved. New image sources are used only after verification succeeds."),
        [T("Open retained copy")] = T("Only saved images remain readable; missing images cannot be fetched in this copy."),
        [T("Open this copy")] = T("Opening the current copy may fetch missing images using your sign-in and network connection."),
        [T("Remove download")] = T("Remove saved images from this copy. Reading position and purchase access are preserved."),
    }
    for _, spec in ipairs(buttons) do
        local entry = spec[1]
        local description = descriptions[entry.text]
        local inner = width - W.dp(56)
        local card = FrameContainer:new{ padding = W.dp(22), padding_left = W.dp(26), padding_right = W.dp(26), margin = 0,
            bordersize = W.dp(entry.text == T("Redownload as new version") and 2 or 1.5), color = W.ink, background = W.paper,
            W.column{ W.row{ text(entry.text, inner - W.dp(36), 21, { bold = entry.text == T("Redownload as new version") }),
                text("›", W.dp(36), 26, { align = "right" }) },
                description and space(10) or space(0), description and text(description, inner, 17,
                    { muted = true, line_height = 0.6 }) or space(0) } }
        local row = W.ActionRow:new{ width = width, content = card, callback = entry.callback }
        row.text = entry.text
        rows[#rows + 1] = { widget = W.column{ row, space(14) }, focus = { row } }
    end
    rows[#rows + 1] = { widget = text(T("None of these operations purchases a chapter."), width, 16, { muted = true }) }
    local close = function() if self.dialog == dialog then self:_closeDownloadDialog() end end
    dialog = downloadFlow(T("Download recovery"), {}, { { { text = T("Back to downloads"), callback = close } } },
        { body_rows = rows, capture_text = self:_downloadTargetText(job) .. "\n" .. message,
            close = close, on_replace = function(replacement, previous)
            UIManager:close(previous); dialog = replacement; self:_showDownloadDialog(replacement)
        end })
    self:_showDownloadDialog(dialog)
end

function Screens:_confirmSourceRefresh(job)
    if not self:_canRefreshSources(job) then return end
    self:_closeDownloadDialog()
    local context, dialog, started = self:_downloadContext()
    local confirmation = {
        text = self:_downloadTargetText(job) .. "\n\n" .. T("Refresh and verify this copy's image sources?") .. "\n\n"
            .. T("Saved images may be downloaded again, using network data. Saved content and reading position are preserved; new sources are applied only after verification succeeds.")
            .. "\n\n" .. T("Close this chapter before proceeding. After verification succeeds, the download resumes. No purchase is made."),
        ok_text = T("Refresh image sources"), cancel_text = T("Cancel"), modal = true,
        ok_callback = function()
            if started or self.dialog ~= dialog or not self:_downloadContextCurrent(context) then return end
            local current = self:_currentDownload(job.id)
            if not current or current.revision ~= job.revision or not self:_canRefreshSources(current) then self:_closeDownloadDialog(); self:_render(); return end
            started = true; self:_closeDownloadDialog()
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
                    else self:_downloadError(err) end
                end
                self:_render()
            end
            local ok = pcall(function() self.controller:refreshDownloadSources(job.id, completed) end)
            if not ok then completed(nil, { kind = "internal" }) end
            if self:_downloadContextCurrent(context) then self:_render() end
        end,
    }
    local close = function() if self.dialog == dialog then self:_closeDownloadDialog() end end
    dialog = downloadFlow(T("Verify image sources"), { confirmation.text }, { {
        { text = confirmation.cancel_text, callback = close },
        { text = confirmation.ok_text, callback = confirmation.ok_callback, primary = true },
    } }, { close = close, on_replace = function(replacement, previous)
        UIManager:close(previous); dialog = replacement; self:_showDownloadDialog(replacement)
    end })
    self:_showDownloadDialog(dialog)
end

function Screens:_confirmVersionReplacement(job)
    if not self:_canReplaceVersion(job) then return end
    self:_closeDownloadDialog()
    local context, dialog, started = self:_downloadContext()
    local confirmation = {
        text = self:_downloadTargetText(job) .. "\n\n" .. T("Download a separate new copy of this chapter?") .. "\n\n"
            .. T("All images will be downloaded, using additional space and network data. The new copy starts at the beginning.")
            .. "\n\n" .. T("This copy's saved images and reading position stay in an independent retained copy. Close every version of this chapter before proceeding. No purchase is made."),
        ok_text = T("Redownload as new version"), cancel_text = T("Cancel"), modal = true,
        ok_callback = function()
            if started or self.dialog ~= dialog or not self:_downloadContextCurrent(context) then return end
            local current = self:_currentDownload(job.id)
            if not current or current.revision ~= job.revision or not self:_canReplaceVersion(current) then self:_closeDownloadDialog(); self:_render(); return end
            started = true; self:_closeDownloadDialog()
            self.version_replacement_requests = self.version_replacement_requests or {}
            self.version_replacement_requests[job.id] = context
            local function completed(_value, err)
                if self.version_replacement_requests[job.id] ~= context then return end
                self.version_replacement_requests[job.id] = nil
                if not self:_downloadContextCurrent(context) then return end
                if err and err.kind ~= "canceled" and not self.dialog then self:_downloadError(err) end
                self:_render()
            end
            local ok = pcall(function() self.controller:replaceDownloadVersion(job.id, completed) end)
            if not ok then completed(nil, { kind = "internal" }) end
            if self:_downloadContextCurrent(context) then self:_render() end
        end,
    }
    local close = function() if self.dialog == dialog then self:_closeDownloadDialog() end end
    dialog = downloadFlow(T("Download new version"), { confirmation.text }, { {
        { text = confirmation.cancel_text, callback = close },
        { text = confirmation.ok_text, callback = confirmation.ok_callback, primary = true },
    } }, { close = close, on_replace = function(replacement, previous)
        UIManager:close(previous); dialog = replacement; self:_showDownloadDialog(replacement)
    end })
    self:_showDownloadDialog(dialog)
end

function Screens:_cancelVersionReplacement(job)
    local context = self:_downloadContext()
    if self.version_replacement_requests then self.version_replacement_requests[job.id] = nil end
    local ok, _result, err = pcall(self.controller.cancelVersionReplacement, self.controller, job.id)
    if not self:_downloadContextCurrent(context) then return end
    if not ok then self:_downloadError({ kind = "internal" })
    elseif err then self:_downloadError(err) end
    self:_render()
end

function Screens:_cancelSourceRefresh(job)
    local context = self:_downloadContext()
    if self.source_refresh_requests then self.source_refresh_requests[job.id] = nil end
    local ok, _result, err = pcall(self.controller.cancelSourceRefresh, self.controller, job.id)
    if not self:_downloadContextCurrent(context) then return end
    if not ok then self:_downloadError({ kind = "internal" })
    elseif err then self:_downloadError(err) end
    self:_render()
end

function Screens:_confirmRemoveDownload(job)
    self:_closeDownloadDialog()
    local context, dialog, started = self:_downloadContext()
    local verifying = (job.payload or {}).source_refresh ~= nil
    local confirmation = { text = self:_downloadTargetText(job) .. "\n\n" .. self:_downloadProgress(job) .. "\n\n"
            .. (verifying and T("Stop verification and remove this copy's saved images?") or T("Remove this copy's saved images?"))
            .. "\n" .. T("Tasks using this same copy will stop. Other versions, reading positions, and purchase access are preserved. Offline reading of this copy will no longer be available."),
        ok_text = T("Remove download"), cancel_text = T("Cancel"), modal = true, ok_callback = function()
            if started or self.dialog ~= dialog or not self:_downloadContextCurrent(context) then return end
            local current = self:_currentDownload(job.id)
            if not current or current.revision ~= job.revision or (current.payload or {}).removed or (current.payload or {}).version_replacement then
                self:_closeDownloadDialog(); self:_render(); return
            end
            started = true
            if (current.payload or {}).source_refresh then
                if self.source_refresh_requests then self.source_refresh_requests[job.id] = nil end
                local ok, _result, err = pcall(self.controller.cancelSourceRefresh, self.controller, current.id)
                if not ok or err then self:_closeDownloadDialog(); self:_downloadError(err or { kind = "internal" }); return end
            end
            self:_closeDownloadDialog()
            self:_invoke("removeDownload", { current.id }, function(_value, error)
                if not self:_downloadContextCurrent(context) then return end
                if error then self:_downloadError(error) end
            end)
        end }
    local close = function() if self.dialog == dialog then self:_closeDownloadDialog() end end
    dialog = downloadMenu(T("Remove this chapter download?"), { confirmation.text }, { {
        { text = confirmation.cancel_text, callback = close },
        { text = confirmation.ok_text, callback = confirmation.ok_callback, primary = true },
    } }, { placement = "center", width = Screen:getWidth() - W.dp(230), top = W.dp(420), close = close,
        selected = { x = 1, y = 1 } })
    self:_showDownloadDialog(dialog)
end

function Screens:_downloadFilter()
    self:_closeDownloadDialog()
    local dialog, context, buttons = nil, self:_downloadContext(), {}
    for _index, option in ipairs({ { "all", T("All downloads") }, { "active", T("In progress") },
        { "attention", T("Needs attention") }, { "complete", T("Ready offline") } }) do
        local value, label = option[1], option[2]
        buttons[#buttons + 1] = { { text = (self.filter == value and "✓ " or "") .. label,
            primary = self.filter == value, callback = function()
            if self.dialog ~= dialog or not self:_downloadContextCurrent(context) then return end
            self:_closeDownloadDialog(); self.filter, self.page = value, 1; self:_render()
        end } }
    end
    buttons[#buttons + 1] = { { text = T("Close"), callback = function() if self.dialog == dialog then self:_closeDownloadDialog() end end } }
    dialog = downloadMenu(T("Filter downloads"), {}, buttons, { placement = "bottom", close = function()
        if self.dialog == dialog then self:_closeDownloadDialog() end
    end })
    self:_showDownloadDialog(dialog)
end

function Screens:_showRelatedDownload(job_id)
    self:_closeDownloadDialog()
    local by_id, visited = {}, {}
    for _index, job in ipairs(Model.array(self.controller:getDownloads())) do by_id[tostring(job.id)] = job end
    local current = by_id[tostring(job_id)]
    while current and (current.payload or {}).replaced_by and not visited[tostring(current.id)] do
        visited[tostring(current.id)] = true
        local newer = by_id[tostring(current.payload.replaced_by)]
        if not newer then break end
        current = newer
    end
    self.filter, self.page, self.download_focus_job_id = "all", 1, current and current.id or job_id
    self:_render()
end

function Screens:_downloadComicCopies(comic_id)
    self:_closeDownloadDialog()
    local rows, dialog, by_id = {}, nil, {}
    local jobs = Model.array(self.controller:getDownloads())
    for _, job in ipairs(jobs) do by_id[tostring(job.id)] = job end
    for _, job in ipairs(jobs) do
        if tostring(job.comic_id) == tostring(comic_id) and not (job.payload or {}).removed
            and (job.kind == nil or job.kind == "episode_download") then
            local widget, focus = self:_jobRow(job, true, by_id)
            rows[#rows + 1] = { widget = widget, focus = focus }
        end
    end
    local close = function() if self.dialog == dialog then self:_closeDownloadDialog() end end
    local comic = self.controller:getComic(comic_id) or { id = comic_id }
    dialog = downloadFlow(title(comic), {}, { { { text = T("Back to downloads"), callback = close } } },
        { body_rows = rows, close = close, on_replace = function(replacement, previous)
            UIManager:close(previous); dialog = replacement; self:_showDownloadDialog(replacement)
        end })
    self:_showDownloadDialog(dialog)
end

function Screens:_downloads()
    local jobs, by_id = Model.array(self.controller:getDownloads()), {}
    local buckets = { active = {}, attention = {}, complete = {}, retained = {} }
    local ready_by_comic, total_jobs = {}, 0
    if not ({ all = true, active = true, attention = true, complete = true })[self.filter] then self.filter = "all" end
    for _, job in ipairs(jobs) do
        by_id[tostring(job.id)] = job
        local payload = job.payload or {}
        if (job.kind == nil or job.kind == "episode_download") and not payload.removed then
            total_jobs = total_jobs + 1
            if payload.replaced_by then buckets.retained[#buckets.retained + 1] = job
            elseif job.state == "complete" then
                buckets.complete[#buckets.complete + 1] = job
                local key = tostring(job.comic_id)
                local group = ready_by_comic[key]
                if not group then
                    group = { id = "comic:" .. key, comic_id = key, jobs = {}, kind = "comic_group" }
                    ready_by_comic[key] = group
                end
                group.jobs[#group.jobs + 1] = job
            elseif not payload.source_refresh and not payload.version_replacement and (job.state == "failed" or job.error) then
                buckets.attention[#buckets.attention + 1] = job
            else buckets.active[#buckets.active + 1] = job end
        end
    end
    for _, bucket in pairs(buckets) do table.sort(bucket, function(a, b) return tostring(a.id) < tostring(b.id) end) end
    self.download_primary_job_id = nil
    for _, job in ipairs(buckets.active) do
        if stopped(job) and not job.error and not (job.payload or {}).source_refresh and not (job.payload or {}).version_replacement then
            self.download_primary_job_id = job.id; break
        end
    end
    local ready_groups = {}
    for _, group in pairs(ready_by_comic) do ready_groups[#ready_groups + 1] = group end
    table.sort(ready_groups, function(a, b)
        local a_title = self:_downloadIdentity(a.jobs[1])
        local b_title = self:_downloadIdentity(b.jobs[1])
        return a_title == b_title and a.comic_id < b.comic_id or a_title < b_title
    end)
    local storage, context = self.controller:getStorageSummary() or {}, self:_downloadContext()
    local pinned = math.max(0, tonumber(storage.pinned_bytes or storage.retained_bytes or storage.download_bytes) or 0)
    local automatic = math.max(0, tonumber(storage.automatic_bytes) or 0)
    local used = tonumber(storage.total_bytes) or pinned + automatic
    local free = tonumber(storage.free_bytes or storage.available_bytes)
    local capacity = tonumber(storage.capacity_bytes or storage.device_total_bytes) or free and used + free or math.max(1, used)
    local inner_width, inner_height = self.width - W.dp(2), W.dp(12)
    local manual_width = math.max(0, math.min(inner_width, math.floor(inner_width * pinned / math.max(1, capacity))))
    local cache_width = math.max(0, math.min(inner_width - manual_width, math.floor(inner_width * automatic / math.max(1, capacity))))
    local bar = FrameContainer:new{ padding = 0, margin = 0, bordersize = W.dp(1), color = W.ink,
        W.row{ W.box(space(0), manual_width, inner_height, { background = W.ink }),
            W.box(space(0), cache_width, inner_height, { background = Blitbuffer.Color8(0x99) }),
            W.box(space(0), inner_width - manual_width - cache_width, inner_height) } }
    local storage_heading_width = math.floor(self.width * 0.55)
    local storage_right
    if total_jobs == 0 then
        storage_right = W.button(T("Manage cache ›"), self.width - storage_heading_width, function()
            if self:_downloadContextCurrent(context) then self:_downloadOpenStorage() end
        end, { borderless = true, align = "right", height_px = W.dp(58), size = W.fontSize(18) })
        self.focus[#self.focus + 1] = { storage_right }
    else storage_right = text(string.format(T("Device free %s"), free and Model.bytes(free) or T("Unknown")), self.width - storage_heading_width, 18,
        { muted = true, align = "right" }) end
    local header_rows = { space(28), W.row{
        W.column{ text(Model.bytes(used), storage_heading_width, 36, { bold = true }), space(5),
            text(total_jobs == 0 and pinned == 0 and T("Automatic cache") or T("Plugin storage"), storage_heading_width, 18, { muted = true }) },
        storage_right }, space(18), bar, space(12),
        text(string.format(T("Manual downloads %s · Automatic cache %s"), Model.bytes(pinned), Model.bytes(automatic)), self.width, 16, { muted = true }),
        space(24), W.rule1dp(self.width, W.ink) }
    local tabs, tab_focus, tab_width = {}, {}, math.floor(self.width / 4)
    local filters = { { "all", T("All"), total_jobs }, { "active", T("In progress"), #buckets.active },
        { "attention", T("Needs attention"), #buckets.attention }, { "complete", T("Ready offline"), #ready_groups } }
    for index, filter in ipairs(filters) do
        local value, label = filter[1], filter[2] .. " " .. filter[3]
        local width = index == 4 and self.width - 3 * tab_width or tab_width
        local selected = value == self.filter
        local button = W.button(label, width, function()
            if not self:_downloadContextCurrent(context) then return end
            self.filter, self.page = value, 1; self:_render()
        end, { borderless = true, bold = selected, size = W.fontSize(20), height_px = W.dp(57) })
        local indicator = selected and W.box(space(0), math.floor(width * 0.7), W.dp(5), { background = W.ink }) or space(0)
        tabs[#tabs + 1] = W.column{ button, W.box(indicator, width, W.dp(5)) }
        tab_focus[#tab_focus + 1] = button
    end
    self.focus[#self.focus + 1] = tab_focus
    header_rows[#header_rows + 1], header_rows[#header_rows + 2] = W.row(tabs), W.rule1dp(self.width, Blitbuffer.Color8(0xCC))
    local header = W.column(header_rows)
    local items = {}
    local function append(group, values)
        for index, value in ipairs(values) do
            items[#items + 1] = { id = value.id, job = value.kind ~= "comic_group" and value or nil,
                group = value.kind == "comic_group" and value or nil, label = index == 1 and group or nil }
        end
    end
    if self.filter == "all" or self.filter == "active" then append(string.format(T("In progress · %d"), #buckets.active), buckets.active) end
    if self.filter == "all" or self.filter == "attention" then append(string.format(T("Needs attention · %d"), #buckets.attention), buckets.attention) end
    if self.filter == "all" or self.filter == "complete" then append(string.format(T("Ready offline · %d comics"), #ready_groups), ready_groups) end
    if self.filter == "all" then append(T("Retained versions"), buckets.retained) end
    if #items == 0 then
        self.page, self.pages, self.pagination = 1, 1, nil
        local empty_title = total_jobs == 0 and T("No downloads yet") or self.filter == "complete" and T("No offline-ready chapters")
            or self.filter == "attention" and T("No downloads need attention") or T("No unfinished downloads")
        local explanation = total_jobs == 0 and T("Open a comic's chapter catalog and choose chapters to download for offline reading.")
            or T("Completed and retained copies remain available under All downloads.")
        local action_width = math.min(self.width, W.dp(340))
        local button = self:_button(total_jobs == 0 and T("Choose a comic from the bookshelf") or T("Show all downloads"), action_width,
            function()
                if not self:_downloadContextCurrent(context) then return end
                if total_jobs == 0 then self:showLibrary() else self.filter, self.page = "all", 1; self:_render() end
            end, { primary = true, size = W.fontSize(23), height_px = W.dp(68) })
        local empty = W.column{ space(124), text(empty_title, self.width, 34, { bold = true, align = "center" }), space(20),
            text(explanation, self.width, 20, { muted = true, align = "center", line_height = 0.7 }), space(44), W.box(button, self.width, W.dp(68)) }
        return W.column{ header, empty }
    end
    local measured = {}
    local function row(entry)
        if measured[entry] then return measured[entry] end
        local widget, focus
        if entry.job then widget, focus = self:_jobRow(entry.job, true, by_id)
        else
            local group = entry.group
            local comic = self:_downloadIdentity(group.jobs[1])
            local size, known_size = 0, false
            for _, job in ipairs(group.jobs) do
                local bytes = tonumber(job.bytes or (job.payload or {}).bytes or (job.payload or {}).saved_bytes)
                if bytes then size, known_size = size + bytes, true end
            end
            local name_width, size_width = math.floor(self.width * 0.44), W.dp(100)
            local content = W.column{ W.box(W.row{
                text(comic, name_width, 20, { bold = true }),
                text(string.format(T("%d chapters saved"), #group.jobs), self.width - name_width - size_width - W.dp(28), 17, { muted = true }),
                text(known_size and Model.bytes(size) or "", size_width, 17, { muted = true, align = "right" }),
                text("›", W.dp(28), 22, { muted = true, align = "right" }),
            }, self.width, W.dp(62)), W.rule1dp(self.width, Blitbuffer.Color8(0xCC)) }
            local action = W.ActionRow:new{ width = self.width, content = content, callback = function()
                if self:_downloadContextCurrent(context) then self:_downloadComicCopies(group.comic_id) end
            end }
            action.text = comic
            widget, focus = action, { action }
        end
        if entry.label then widget = W.column{ space(24), text(entry.label, self.width, 18, { bold = true, muted = true }), space(10), widget } end
        measured[entry] = { widget = widget, focus = focus }
        return measured[entry]
    end
    local target = self.download_focus_job_id
    self.download_focus_job_id = nil
    local body = self:_paginate(items, function(entry) return row(entry).widget:getSize().h end, header:getSize().h,
        function(entry)
            local result = row(entry)
            if result.focus and #result.focus > 0 then self.focus[#self.focus + 1] = result.focus end
            return result.widget
        end, false, { target_id = target, item_id = function(entry)
            if entry.group and target then for _, job in ipairs(entry.group.jobs) do if tostring(job.id) == tostring(target) then return tostring(target) end end end
            return tostring(entry.id)
        end })
    return W.column{ header, body }
end


end
