local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local W = require("bilicomics/ui/widgets")
local Model = require("bilicomics/ui/model")
local Helpers = require("bilicomics/ui/screen_helpers")
local T = require("bilicomics/ui/i18n")
local title, accountKey = Helpers.title, Helpers.accountKey

local function font(name, fallback) return W.font and W.font[name] or fallback end
local function stopped(job) return job.state == "paused" or job.state == "failed" or job.state == "canceled" end
local function savedCount(job) return math.max(0, math.floor(tonumber(job.completed) or 0)) end
local function totalCount(job) return math.max(0, math.floor(tonumber(job.total) or 0)) end
local function copyReference(job, short)
    local value = tostring(job.revision or job.id or ""):gsub("[%c]", " ")
    if short and #value > 22 and value:match("^[%w%._%-:]+$") then return value:sub(1, 10) .. "…" .. value:sub(-8) end
    return value
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
    dialog = ButtonDialog:new{ title = heading .. "\n\n" .. message, buttons = buttons, modal = true }
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
    dialog = ButtonDialog:new{ title = self:_downloadTargetText(job) .. "\n\n" .. T("Stopping keeps saved images. Removing deletes this copy's saved images.") .. "\n" .. opening,
        buttons = buttons, modal = true, width_factor = 0.94 }
    self:_showDownloadDialog(dialog)
end

function Screens:_downloadActionRow(entries, measure)
    local gap, cells, focus = W.scale(8), {}, {}
    for index, entry in ipairs(entries) do
        local width = #entries == 1 and self.width or math.floor((self.width - gap) / 2)
        if index == #entries then width = self.width - (width + gap) * (index - 1) end
        local options = { primary = entry.primary, borderless = entry.borderless, size = font("meta", 14), height = 30 }
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
    local left_width = math.floor(self.width * 0.5)
    local rows = { W.text(comic .. " · " .. chapter, self.width, font("item", 18), { bold = true, height = W.scale(44) }),
        W.space(3), W.text(self:_downloadCopyLabel(job, true), self.width, font("meta", 14), { bold = payload.replaced_by ~= nil, height = W.scale(22) }),
        W.space(4), W.row{
            W.text(status, left_width, font("status", 15), { bold = true }),
            W.text(progress, self.width - left_width, font("status", 15), { align = "right" }),
        } }
    if payload.replaced_by then
        rows[#rows + 1] = W.space(3)
        rows[#rows + 1] = W.text(T("Only saved images remain readable; missing images cannot be fetched in this copy."), self.width, font("meta", 14))
    elseif job.error and not payload.source_refresh and not payload.version_replacement then
        local heading = Model.error(job.error)
        rows[#rows + 1] = W.space(3)
        rows[#rows + 1] = W.text(heading, self.width, font("meta", 14), { height = W.scale(24) })
    end
    rows[#rows + 1] = W.space(7)
    local action_row, action_focus = self:_downloadActionRow(self:_downloadActions(job, render_jobs), measure)
    rows[#rows + 1] = action_row
    rows[#rows + 1], rows[#rows + 2], rows[#rows + 3] = W.space(10), W.rule(self.width), W.space(10)
    return W.column(rows), action_focus
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
    buttons[#buttons + 1] = { { text = T("Close"), callback = function() if self.dialog == dialog then self:_closeDownloadDialog() end end } }
    dialog = ButtonDialog:new{ title = heading .. "\n\n" .. self:_downloadTargetText(job) .. "\n\n" .. message,
        buttons = buttons, modal = true, width_factor = 0.94 }
    self:_showDownloadDialog(dialog)
end

function Screens:_confirmSourceRefresh(job)
    if not self:_canRefreshSources(job) then return end
    self:_closeDownloadDialog()
    local context, dialog, started = self:_downloadContext()
    dialog = ConfirmBox:new{
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
    self:_showDownloadDialog(dialog)
end

function Screens:_confirmVersionReplacement(job)
    if not self:_canReplaceVersion(job) then return end
    self:_closeDownloadDialog()
    local context, dialog, started = self:_downloadContext()
    dialog = ConfirmBox:new{
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
    dialog = ConfirmBox:new{ text = self:_downloadTargetText(job) .. "\n\n" .. self:_downloadProgress(job) .. "\n\n"
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
    self:_showDownloadDialog(dialog)
end

function Screens:_downloadFilter()
    self:_closeDownloadDialog()
    local dialog, context, buttons = nil, self:_downloadContext(), {}
    for _index, option in ipairs({ { "all", T("All downloads") }, { "active", T("Unfinished downloads") }, { "complete", T("Ready offline") } }) do
        local value, label = option[1], option[2]
        buttons[#buttons + 1] = { { text = (self.filter == value and "[x] " or "[ ] ") .. label, callback = function()
            if self.dialog ~= dialog or not self:_downloadContextCurrent(context) then return end
            self:_closeDownloadDialog(); self.filter, self.page = value, 1; self:_render()
        end } }
    end
    buttons[#buttons + 1] = { { text = T("Close"), callback = function() if self.dialog == dialog then self:_closeDownloadDialog() end end } }
    dialog = ButtonDialog:new{ title = T("Filter downloads"), buttons = buttons, modal = true }
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

function Screens:_downloads()
    local jobs = Model.array(self.controller:getDownloads())
    local items, unfinished, complete, total_jobs = {}, 0, 0, 0
    if self.filter ~= "all" and self.filter ~= "active" and self.filter ~= "complete" then self.filter = "all" end
    for _index, job in ipairs(jobs) do
        if (job.kind == nil or job.kind == "episode_download") and not (job.payload or {}).removed then
            total_jobs = total_jobs + 1
            local older = (job.payload or {}).replaced_by ~= nil
            if not older then
                if job.state == "complete" then complete = complete + 1 else unfinished = unfinished + 1 end
            end
            if self.filter == "all" or (not older and ((self.filter == "complete" and job.state == "complete")
                or (self.filter == "active" and job.state ~= "complete"))) then items[#items + 1] = job end
        end
    end
    local by_id = {}
    for _index, job in ipairs(jobs) do by_id[tostring(job.id)] = job end
    local function family(job)
        local visited, current = {}, job
        while (current.payload or {}).replaced_by and not visited[tostring(current.id)] do
            visited[tostring(current.id)] = true
            local newer = by_id[tostring(current.payload.replaced_by)]
            if not newer then break end
            current = newer
        end
        return tostring(current.id), current
    end
    table.sort(items, function(a, b)
        local a_family, a_current = family(a)
        local b_family, b_current = family(b)
        if a_family ~= b_family then
            if (a_current.state == "complete") ~= (b_current.state == "complete") then return a_current.state ~= "complete" end
            return a_family < b_family
        end
        if ((a.payload or {}).replaced_by ~= nil) ~= ((b.payload or {}).replaced_by ~= nil) then return (a.payload or {}).replaced_by == nil end
        return tostring(a.id) < tostring(b.id)
    end)
    local storage = self.controller:getStorageSummary() or {}
    local context = self:_downloadContext()
    local header = W.column{
        W.text(string.format(T("%d unfinished · %d ready offline"), unfinished, complete), self.width, font("status", 15), { bold = true }),
        W.space(3), W.text(string.format(T("Saved downloads: %s"), Model.bytes(storage.pinned_bytes or storage.retained_bytes or storage.download_bytes)),
            self.width, font("meta", 14), { muted = true }), W.space(6), self:_buttons{
            { text = ({ all = T("All downloads"), active = T("Unfinished downloads"), complete = T("Ready offline") })[self.filter] .. " ▾",
                borderless = true, align = "left", size = font("status", 15), callback = function()
                    if self:_downloadContextCurrent(context) then self:_downloadFilter() end
                end },
            { text = T("Refresh list"), borderless = true, size = font("meta", 14), callback = function()
                if self:_downloadContextCurrent(context) then self:_render() end
            end },
        }, W.space(10),
    }
    if #items == 0 then
        self.page, self.pages, self.pagination = 1, 1, nil
        local empty_title = total_jobs == 0 and T("No downloads yet")
            or self.filter == "complete" and T("No offline-ready chapters") or T("No unfinished downloads")
        local explanation = total_jobs == 0 and T("Open a comic's chapter catalog and choose chapters to download for offline reading.")
            or self.filter == "complete" and T("Saved copies may still be unfinished or retained older versions. View all downloads to check them.")
            or T("There are no unfinished tasks in this filter. Completed and retained copies are available under All downloads.")
        local action = total_jobs == 0 and T("Choose a comic") or T("Show all downloads")
        local empty = W.column{ W.space(10), W.text(empty_title, self.width, font("title", 21), { bold = true }), W.space(8),
            W.text(explanation, self.width, font("body", 18)), W.space(12),
            self:_button(action, self.width, function()
                if not self:_downloadContextCurrent(context) then return end
                if total_jobs == 0 then self:showLibrary() else self.filter, self.page = "all", 1; self:_render() end
            end, { primary = true }),
        }
        return W.column{ header, empty }
    end
    local measured = {}
    local function row(job)
        if not measured[job] then
            local widget, focus = self:_jobRow(job, true, by_id)
            measured[job] = { widget = widget, focus = focus }
        end
        return measured[job]
    end
    local target = self.download_focus_job_id
    self.download_focus_job_id = nil
    local body = self:_paginate(items, function(job) return row(job).widget:getSize().h end, header:getSize().h,
        function(job)
            local item = row(job)
            if item.focus and #item.focus > 0 then self.focus[#self.focus + 1] = item.focus end
            return item.widget
        end, false, { target_id = target, item_id = function(job) return tostring(job.id) end })
    return W.column{ header, body }
end


end
