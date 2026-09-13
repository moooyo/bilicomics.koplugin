local Util = require("bilicomics/util")
local Budget = require("bilicomics/jobs/storage_budget")
local DownloadService = {}
DownloadService.__index = DownloadService
local function pageKey(descriptor, index) return descriptor.episode_id .. "/" .. descriptor.revision .. "/" .. index end
local function sourceGeneration(page) return tonumber((page and page.extra or {}).source_generation) or 0 end
local function interruptedState(err)
    local kind = err and err.kind
    return (kind == "authentication" or kind == "low_space" or kind == "network" or kind == "timeout") and "paused" or "failed"
end
local function isReadable(episode, offline)
    if not episode then return false end
    if episode.access == "owned" or episode.access == "free" then return true end
    if episode.access == "temporary" and episode.expires_at and episode.expires_at > os.time() then
        return not offline or (episode.extra and episode.extra.offline_allowed == true)
    end
    return false
end
DownloadService.isReadable = isReadable
function DownloadService.new(options)
    return setmetatable({ store = assert(options.store), pages = assert(options.pages), runner = assert(options.runner),
        account_key = assert(options.account_key), session = assert(options.session),
        prepare = assert(options.prepare), notify = options.notify or function() end,
        authentication_valid = options.authentication_valid, network_available = options.network_available,
        on_authentication_error = options.on_authentication_error or function() end,
        page_ready = options.page_ready or function() end, ui = options.ui or require("ui/uimanager"),
        settings = options.settings, requests = {}, failures = {}, generation = 1, closed = false }, DownloadService)
end
function DownloadService:_defer(fn)
    local generation = self.generation
    self.ui:nextTick(function() if not self.closed and generation == self.generation then fn() end end)
end
function DownloadService:_update(job)
    job.updated_at = os.time()
    self.store:putJob(job)
    self.notify()
end
function DownloadService:_authenticationAllowed()
    if self.authentication_error then return false end
    if self.authentication_valid then
        local ok, valid = pcall(self.authentication_valid)
        return ok and valid == true
    end
    return true
end
function DownloadService:_authenticationError()
    return self.authentication_error or Util.error("authentication", "Import a verified session before downloading missing images.")
end
function DownloadService:_networkAllowed()
    if not self.network_available then return true end
    local ok, available = pcall(self.network_available)
    return ok and available == true
end
function DownloadService:_networkError()
    return Util.error("network", "Connect and resume the download to acquire missing images.", { transmitted = false })
end
function DownloadService:_pauseOffline(job)
    if self:_networkAllowed() or (job.revision and self.pages:isComplete(job.episode_id, job.revision)) then return false end
    job.state, job.error = "paused", self:_networkError()
    job.run_generation = (job.run_generation or 0) + 1
    self:_update(job)
    return true
end
function DownloadService:invalidateAuthentication()
    if self.closed or self.authentication_error then return false end
    self.authentication_error = Util.error("authentication", "The account session is no longer valid. Import a verified session.")
    self:cancelSourceRefresh()
    self:cancelVersionReplacement()
    -- This service owns only image tasks. Purchase workers must never be canceled here.
    local listed, jobs = pcall(self.store.listJobs, self.store, { "running", "queued" })
    for _, job in ipairs(listed and jobs or {}) do
        if job.kind == "episode_download" then
            job.state, job.error = "paused", self.authentication_error
            job.run_generation = (job.run_generation or 0) + 1
            pcall(self._update, self, job)
        end
    end
    local retiring = {}
    for key, request in pairs(self.requests) do
        request.retired, request.retire_error = true, self.authentication_error
        self.requests[key] = nil
        retiring[#retiring + 1] = request
    end
    for _, request in ipairs(retiring) do self.runner:cancel(request.task_id) end
    Util.callback(self.on_authentication_error, self.authentication_error)
    Util.callback(self.notify)
    return true
end
function DownloadService:_cleanupTemporary(request)
    if request.commit_attempted then
        local ok, journals = pcall(self.store.listCommits, self.store)
        if not ok then return end
        for _, journal in ipairs(journals) do
            if journal.temporary_path == request.temporary_path then return end
        end
    end
    os.remove(request.temporary_path)
end
function DownloadService:_pageReady(page, descriptor)
    self.failures[page.key] = nil
    Util.callback(self.page_ready, page, descriptor)
end
function DownloadService:_minimumFree()
    return self.settings and self.settings:get("minimum_free_bytes") or Budget.default_minimum
end
function DownloadService:_ensureSpace()
    local available, err = Budget.available(self.pages.temporary_root)
    if not available then return nil, err end
    local required = self:_minimumFree() + Budget.default_image_limit
    if available < required then
        local ok = pcall(function()
            local automatic = 0
            for _, page in ipairs(self.store:listAllPages()) do
                if page.state == "ready" and not self.store:isPinned(page.episode_id, page.revision) then
                    automatic = automatic + (page.bytes or 0)
                end
            end
            self.pages:evictToLimit(math.max(0, automatic - (required - available)))
        end)
        if not ok then return nil, Util.error("storage", "Automatic cache cleanup could not finish safely.") end
    end
    return Budget.check(self.pages.temporary_root, self:_minimumFree(), Budget.default_image_limit)
end
function DownloadService:_recoverCommits(episode_id, revision)
    local ok, summary = pcall(self.pages.recoverPendingCommits, self.pages)
    if not ok then return nil, Util.error("storage", "Interrupted image commits could not be recovered.") end
    for _, page in ipairs(summary.recovered_pages or {}) do
        local found, descriptor = pcall(self.store.getDescriptor, self.store, page.episode_id, page.revision)
        if not found then descriptor = nil end
        self:_pageReady(page, descriptor)
    end
    if (summary.recovered or 0) > 0 then Util.callback(self.notify) end
    local listed, journals = pcall(self.store.listCommits, self.store)
    if not listed then return nil, Util.error("storage", "Interrupted image commits could not be inspected.") end
    for _, journal in ipairs(journals) do
        if journal.page.episode_id == episode_id and (not revision or journal.page.revision == revision) then
            return nil, Util.error("storage", "This chapter has an interrupted image commit that still needs recovery.")
        end
    end
    return true
end
function DownloadService:requestPage(descriptor, index, options, callback)
    options = options or {}
    if self.closed then return end
    if options.retry then
        local recovered, recovery_error = self:_recoverCommits(descriptor.episode_id, descriptor.revision)
        if not recovered then self:_defer(function() Util.callback(callback, nil, recovery_error) end); return end
    end
    local page = self.pages:getPage(descriptor.episode_id, descriptor.revision, index)
    if page and page.state == "ready" then self:_defer(function() Util.callback(callback, page) end); return end
    if self:isRetiredVersion(descriptor.episode_id, descriptor.revision) then
        self:_defer(function() Util.callback(callback, nil,
            Util.error("version_replaced", "Only cached pages are available in this retained older version.")) end)
        return
    end
    if not self:_authenticationAllowed() then
        self:_defer(function() Util.callback(callback, nil, self:_authenticationError()) end)
        return
    end
    local episode = self.store:getEpisode(descriptor.episode_id)
    if not isReadable(episode, false) then
        self:_defer(function() Util.callback(callback, nil, Util.error("locked", "The episode has no confirmed readable access.")) end)
        return
    end
    if not self:_networkAllowed() then
        self:_defer(function() Util.callback(callback, nil, self:_networkError()) end)
        return
    end
    local key = pageKey(descriptor, index)
    local owner = options.owner or ("reader:" .. tostring(options.reader_generation or "active"))
    local priority = options.priority or (options.prefetch and 20 or 0)
    local existing = self.requests[key]
    if existing and (existing.context.expected_source_generation or 0) ~= sourceGeneration(page) then
        existing.retired = true
        self.requests[key], self.failures[key] = nil, nil
        self.runner:cancel(existing.task_id)
        existing = nil
    end
    if existing then
        existing.owners[owner] = true
        if callback then existing.callbacks[#existing.callbacks + 1] = callback end
        self.runner:promote(existing.task_id, priority)
        return existing.task_id
    end
    if self.failures[key] and not options.retry then
        self:_defer(function() Util.callback(callback, nil, self.failures[key]) end)
        return
    end
    local source = page and page.extra and page.extra.source_path
    if not source then
        self:_defer(function() Util.callback(callback, nil, Util.error("index_missing", "Refresh the episode index before downloading this page.")) end)
        return
    end
    local enough_space, space_error = self:_ensureSpace()
    if not enough_space then
        self.failures[key] = space_error
        self:_defer(function() Util.callback(callback, nil, space_error) end)
        return
    end
    local id, generation = Util.id("page"), self.generation
    local context = { account_key = self.account_key, episode_id = descriptor.episode_id, revision = descriptor.revision,
        index = index, id = descriptor.pages[index].id, expected_content_generation = page.content_generation,
        expected_source_generation = sourceGeneration(page), expected_checksum = (page.extra or {}).expected_source_checksum }
    local request = { id = id, context = context, owners = { [owner] = true }, callbacks = {}, descriptor = descriptor,
        temporary_path = self.pages.temporary_root .. "/" .. id .. ".part" }
    if callback then request.callbacks[1] = callback end
    self.requests[key] = request
    request.task_id = self.runner:submit({ kind = "download_page", session = self.session(),
        source_path = source, index = index, temporary_path = request.temporary_path,
        minimum_free_bytes = self:_minimumFree(), max_bytes = Budget.default_image_limit },
        { id = id, priority = priority, resource = "image", timeout = 120,
            before_start = function()
                if self:_networkAllowed() then return true end
                return nil, self:_networkError()
            end }, function(result, err)
            if self.requests[key] == request then self.requests[key] = nil end
            if self.closed or generation ~= self.generation or request.retired then
                self:_cleanupTemporary(request)
                if request.retired and not self.closed then
                    for _, done in ipairs(request.callbacks) do
                        Util.callback(done, nil, request.retire_error or Util.error("canceled", "The operation was canceled."))
                    end
                end
                return
            end
            local current = self.store:getPage(key)
            if not current or current.id ~= context.id or current.content_generation ~= context.expected_content_generation
                or sourceGeneration(current) ~= context.expected_source_generation then
                result, err = nil, Util.error("canceled", "The page source changed while its image was being acquired.")
            end
            if err and err.kind == "authentication" then self:invalidateAuthentication() end
            local committed
            if result then
                if context.expected_checksum and result.checksum ~= context.expected_checksum then
                    err = Util.error("content_changed", "The refreshed image no longer matches its verified content.")
                else
                    request.commit_attempted = true
                    local ok, value = pcall(self.pages.commitPage, self.pages, context, result)
                    if ok then committed = value else err = Util.error("storage", "The completed image could not be committed safely.") end
                end
            end
            if not committed and err and err.kind ~= "canceled" then
                local current = self.store:getPage(key)
                if current and current.content_generation == context.expected_content_generation
                    and sourceGeneration(current) == context.expected_source_generation then
                    self.failures[key] = err
                    current.state, current.error = "failed", err.message
                    self.store:putPage(current)
                end
            end
            if committed then
                self:_pageReady(committed, descriptor)
                if self.settings then
                    -- Cleanup failure cannot undo a committed image or suppress its completion.
                    pcall(self.pages.evictToLimit, self.pages, self.settings:get("cache_limit_bytes"))
                end
            end
            if not committed then self:_cleanupTemporary(request) end
            for _, done in ipairs(request.callbacks) do Util.callback(done, committed, err) end
            self.notify()
        end)
    return request.task_id
end
function DownloadService:clearFailures(episode_id)
    for key in pairs(self.failures) do if key:sub(1, #episode_id + 1) == episode_id .. "/" then self.failures[key] = nil end end
end
function DownloadService:isRefreshingSources(episode_id, revision)
    return require("bilicomics/jobs/source_refresh").active(self, episode_id, revision) ~= nil
end
function DownloadService:refreshSources(job_id, fetch_index, callback, check_positions)
    return require("bilicomics/jobs/source_refresh").start(self, job_id, fetch_index, callback, check_positions)
end
function DownloadService:cancelSourceRefresh(job_id)
    return require("bilicomics/jobs/source_refresh").cancel(self, job_id)
end
function DownloadService:isReplacingVersion(episode_id)
    return require("bilicomics/jobs/version_replacement").active(self, episode_id) ~= nil
end
function DownloadService:isRetiredVersion(episode_id, revision)
    for _, job in ipairs(self.store:listJobs()) do
        if job.kind == "episode_download" and job.episode_id == tostring(episode_id)
            and job.revision == tostring(revision) and (job.payload or {}).replaced_by then return true end
    end
    return false
end
function DownloadService:replaceVersion(job_id, fetch_index, callback)
    return require("bilicomics/jobs/version_replacement").start(self, job_id, fetch_index, callback)
end
function DownloadService:cancelVersionReplacement(job_id)
    return require("bilicomics/jobs/version_replacement").cancel(self, job_id)
end
function DownloadService:releaseReader(generation)
    local owner = "reader:" .. tostring(generation or "active")
    for key, request in pairs(self.requests) do
        request.owners[owner] = nil
        if not next(request.owners) then
            request.retired = true; self.requests[key] = nil
            self.runner:cancel(request.task_id)
        end
    end
end
function DownloadService:_run(job)
    if self.closed or job.state ~= "queued" then return end
    if not self:_authenticationAllowed()
        and not (job.revision and self.pages:isComplete(job.episode_id, job.revision)) then
        job.state, job.error = "paused", self:_authenticationError()
        self:_update(job)
        return
    end
    if self:_pauseOffline(job) then return end
    job.run_generation = (job.run_generation or 0) + 1
    local run_generation, service_generation = job.run_generation, self.generation
    self:_update(job)
    local function preparedChapter(prepared, err)
        if self.closed or service_generation ~= self.generation then return end
        job = self.store:getJob(job.id)
        if not job or job.state ~= "queued" or job.run_generation ~= run_generation then return end
        if not prepared then job.state, job.error = interruptedState(err), err; self:_update(job); return end
        if not isReadable(self.store:getEpisode(job.episode_id), true) then
            job.state, job.error = "failed", Util.error("entitlement", "Offline access for this episode has not been confirmed.")
            self:_update(job); return
        end
        local descriptor = prepared.descriptor
        job.revision, job.total, job.completed = descriptor.revision, #descriptor.pages, 0
        self.pages:pinEpisode(job.episode_id, job.revision, true)
        job.state, job.error = "running", nil
        self:_update(job)
        local function advance()
            if self.closed or service_generation ~= self.generation then return end
            job = self.store:getJob(job.id)
            if not job or job.state ~= "running" or job.run_generation ~= run_generation then return end
            local next_index
            job.completed = 0
            for index = 1, #descriptor.pages do
                local page = self.pages:getPage(job.episode_id, job.revision, index)
                if page and page.state == "ready" then job.completed = job.completed + 1
                elseif not next_index then next_index = index end
            end
            if not next_index then job.state = "complete"; self:_update(job); return end
            self:_update(job)
            self:requestPage(descriptor, next_index, { owner = "job:" .. job.id, priority = 40, retry = true }, function(_, page_error)
                if self.closed or service_generation ~= self.generation then return end
                job = self.store:getJob(job.id)
                if not job or job.state ~= "running" or job.run_generation ~= run_generation then return end
                if page_error then
                    job.state = interruptedState(page_error)
                    job.error = page_error; self:_update(job)
                else self:_defer(advance) end
            end)
        end
        self:_defer(advance)
    end
    if job.revision then
        -- Durable jobs belong to one snapshot, even when a newer catalog version exists.
        local ok, descriptor, path = pcall(self.store.getDescriptor, self.store, job.episode_id, job.revision)
        if not ok or not descriptor or not path then
            preparedChapter(nil, Util.error("cache_missing", "This download's chapter descriptor is unavailable."))
        else
            local valid, stored = pcall(self.pages.readDescriptor, self.pages, path)
            if not valid or Util.hash(stored) ~= Util.hash(descriptor) then
                preparedChapter(nil, Util.error("cache_missing", "This download's chapter descriptor is inconsistent."))
            else preparedChapter({ descriptor = descriptor, path = path }) end
        end
    else self.prepare(job.comic_id, job.episode_id, preparedChapter) end
end
function DownloadService:enqueue(comic_id, episode_id)
    comic_id, episode_id = tostring(comic_id), tostring(episode_id)
    local episode = self.store:getEpisode(episode_id)
    if not isReadable(episode, true) then return nil, Util.error("entitlement", "Offline access for this episode has not been confirmed.") end
    if self:isReplacingVersion(episode_id) or self:isRefreshingSources(episode_id) then
        return nil, Util.error("busy", "Finish or cancel this chapter's recovery operation first.")
    end
    local revision = episode.extra and (episode.extra.current_revision or episode.extra.local_revision)
    for _, existing in ipairs(self.store:listJobs()) do
        if existing.kind == "episode_download" and existing.episode_id == episode_id and existing.state ~= "canceled"
            and not (existing.payload or {}).removed and not (existing.payload or {}).replaced_by
            and (not revision or not existing.revision or existing.revision == revision) then
            if existing.state == "complete" and existing.revision and not self.pages:isComplete(episode_id, existing.revision) then
                existing.state = "paused"; self:_update(existing)
            end
            if existing.state == "failed" or existing.state == "paused" then self:resume(existing.id) end
            return self.store:getJob(existing.id)
        end
    end
    local comic = self.store:getComic(comic_id) or {}
    local job = { id = Util.id("download"), kind = "episode_download", state = "queued", comic_id = comic_id,
        episode_id = episode_id, completed = 0, total = 0,
        revision = revision,
        payload = { title = episode.title, comic_title = comic.title }, created_at = os.time() }
    self:_update(job); self:_run(job)
    return job
end
function DownloadService:pause(id, canceled)
    local job = self.store:getJob(id)
    if not job or job.state == "complete" then return false end
    self:cancelSourceRefresh(id)
    self:cancelVersionReplacement(id)
    job = self.store:getJob(id)
    job.state = canceled and "canceled" or "paused"
    job.run_generation = (job.run_generation or 0) + 1
    self:_update(job)
    for key, request in pairs(self.requests) do
        request.owners["job:" .. id] = nil
        if not next(request.owners) then
            request.retired = true; self.requests[key] = nil
            self.runner:cancel(request.task_id)
        end
    end
    return true
end
function DownloadService:resume(id)
    local job = self.store:getJob(id)
    if not job or job.state == "complete" then return false end
    if (job.payload or {}).removed or (job.payload or {}).replaced_by then
        return false, Util.error("invalid_request", "This retained older download cannot be resumed as the current version.")
    end
    if self:isRefreshingSources(job.episode_id) or self:isReplacingVersion(job.episode_id) then
        return false, Util.error("busy", "Wait for the source refresh or cancel it before resuming.")
    end
    local recovered, err = self:_recoverCommits(job.episode_id, job.revision)
    if not recovered then
        job.state, job.error = "failed", err
        self:_update(job)
        return false, err
    end
    if not self:_authenticationAllowed()
        and not (job.revision and self.pages:isComplete(job.episode_id, job.revision)) then
        err = self:_authenticationError()
        job.state, job.error = "paused", err
        self:_update(job)
        return false, err
    end
    if self:_pauseOffline(job) then return false, job.error end
    self:clearFailures(job.episode_id)
    job.state, job.error = "queued", nil
    self:_update(job); self:_run(job)
    return true
end
function DownloadService:recover()
    self.pages:reconcile()
    for _, job in ipairs(self.store:listJobs()) do
        if job.kind == "episode_download" and (job.payload or {}).version_replacement then
            job.payload.version_replacement = nil
            if job.state ~= "canceled" then
                job.state, job.error = "paused", Util.error("version_replacement_interrupted", "Restart the interrupted new-version preparation explicitly.")
            end
            self:_update(job)
        end
        if job.kind == "episode_download" and (job.payload or {}).source_refresh then
            job.payload.source_refresh = nil
            if job.state ~= "canceled" then
                job.state, job.error = "paused", Util.error("source_refresh_interrupted", "Restart the interrupted source verification explicitly.")
            end
            self:_update(job)
        end
        if job.kind == "episode_download" and (job.state == "running" or job.state == "queued") then
            job.state = "paused"; job.error = nil; self:_update(job)
        elseif job.kind == "episode_download" and job.state == "complete" and job.revision
            and not self.pages:isComplete(job.episode_id, job.revision) then
            job.state = "paused"; job.error = Util.error("cache_missing", "Some downloaded pages need to be restored."); self:_update(job)
        end
    end
end
function DownloadService:suspend()
    self:cancelSourceRefresh()
    self:cancelVersionReplacement()
    for _, job in ipairs(self.store:listJobs()) do
        if job.state == "running" or job.state == "queued" then self:pause(job.id) end
    end
end
function DownloadService:close()
    self:suspend()
    self.closed = true
    self.generation = self.generation + 1
    for _, request in pairs(self.requests) do self.runner:cancel(request.task_id) end
    self.requests = {}
end
return DownloadService
