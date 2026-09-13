-- One explicit, cancellable refresh of a retained partial chapter's image sources.
local Files = require("bilicomics/storage/files")
local Source = require("bilicomics/storage/source_refresh")
local Util = require("bilicomics/util")
local Budget = require("bilicomics/jobs/storage_budget")

local Refresh = {}
local function key(episode_id, revision) return tostring(episode_id) .. "/" .. tostring(revision) end
local function canceled() return Util.error("canceled", "The source refresh was canceled.") end

function Refresh.active(service, episode_id, revision)
    for _, operation in pairs(service.source_refreshes or {}) do
        if operation.episode_id == tostring(episode_id) and (revision == nil or operation.revision == tostring(revision)) then
            return operation
        end
    end
end

function Refresh.cancel(service, job_id)
    local operations = {}
    for _, operation in pairs(service.source_refreshes or {}) do
        if job_id == nil or operation.job_id == job_id then operations[#operations + 1] = operation end
    end
    for _, operation in ipairs(operations) do operation.finish(nil, canceled(), true) end
    return #operations > 0
end

function Refresh.start(service, job_id, fetch_index, callback, check_positions)
    if service.closed then return nil, Util.error("closed", "The download service is closed.") end
    local job = service.store:getJob(job_id)
    if not job or job.kind ~= "episode_download" or not job.revision or (job.payload or {}).removed
        or (job.payload or {}).replaced_by or job.state == "complete" then
        return nil, Util.error("invalid_request", "Select a retained partial chapter before refreshing its sources.")
    end
    if Refresh.active(service, job.episode_id) or service:isReplacingVersion(job.episode_id) then
        return nil, Util.error("busy", "The chapter already has a recovery operation in progress.")
    end
    if not service:_authenticationAllowed() then return nil, service:_authenticationError() end
    if not service.isReadable(service.store:getEpisode(job.episode_id), true) then
        return nil, Util.error("entitlement", "The chapter needs confirmed offline reading access.")
    end
    if (service.pages.active[key(job.episode_id, job.revision)] or 0) ~= 0 then
        return nil, Util.error("busy", "Close this chapter before refreshing its image sources.", { code = "chapter_active" })
    end
    service:pause(job_id)
    local recovered, recovery_error = service:_recoverCommits(job.episode_id, job.revision)
    if not recovered then return nil, recovery_error end
    local basis, error = Source.capture(service.pages, job.episode_id, job.revision)
    if not basis then return nil, error end
    if check_positions then
        local allowed, position_error = check_positions(basis)
        if not allowed then return nil, position_error end
    end
    job = service.store:getJob(job_id)
    local operation = { id = Util.id("source-refresh"), job_id = job_id, episode_id = job.episode_id,
        revision = job.revision, run_generation = job.run_generation, generation = service.generation,
        proofs = {}, basis = basis, checked = 0, total = 0 }
    for _, item in ipairs(basis.pages) do if item.history == "committed" then operation.total = operation.total + 1 end end
    service.source_refreshes = service.source_refreshes or {}
    local operation_key = key(job.episode_id, job.revision)
    service.source_refreshes[operation_key] = operation
    service.pages.source_refresh_locks = service.pages.source_refresh_locks or {}
    service.pages.source_refresh_locks[operation_key] = operation

    local function liveJob()
        if operation.finished or service.closed or service.generation ~= operation.generation
            or service.source_refreshes[operation_key] ~= operation then return nil end
        local current = service.store:getJob(job_id)
        if not current or current.state ~= "paused" or current.run_generation ~= operation.run_generation
            or current.revision ~= operation.revision then return nil end
        return current
    end
    local function update(stage)
        local current = liveJob()
        if not current then return nil end
        current.payload = current.payload or {}
        current.payload.source_refresh = { id = operation.id, stage = stage,
            checked = operation.checked, total = operation.total }
        service:_update(current)
        return true
    end
    local function removeCandidate()
        if operation.temporary_path then
            local temporary = operation.temporary_path
            operation.temporary_path = nil
            if Files.exists(temporary) then
                Files.assertRegular(temporary, service.pages.temporary_root)
                assert(os.remove(temporary), "The verification candidate could not be removed")
            end
        end
    end
    function operation.finish(value, err, stop_worker)
        if operation.finished then return end
        local inspected, current = pcall(liveJob)
        local terminal_error = not inspected
            and Util.error("storage", "The source refresh completion state could not be read safely.") or nil
        if not inspected then current = nil end
        operation.finished = true
        if service.source_refreshes[operation_key] == operation then service.source_refreshes[operation_key] = nil end
        if service.pages.source_refresh_locks[operation_key] == operation then service.pages.source_refresh_locks[operation_key] = nil end
        local function safely(fn)
            if not pcall(fn) then
                terminal_error = terminal_error or Util.error("storage", "The source refresh completed with a cleanup or storage error.")
            end
        end
        if stop_worker and operation.task_id then safely(function() service.runner:cancel(operation.task_id) end) end
        safely(removeCandidate)
        if current then
            current.payload = current.payload or {}
            current.payload.source_refresh = nil
            current.error = err and err.kind ~= "canceled" and err or nil
            safely(function() service:_update(current) end)
        end
        if err and err.kind == "authentication" and not service.closed and service.generation == operation.generation then
            safely(function() service:invalidateAuthentication() end)
        end
        if terminal_error then value, err = nil, terminal_error end
        Util.callback(callback, value, err)
    end
    local function protected(fn)
        local ok, failure = pcall(fn)
        if not ok then
            operation.finish(nil, type(failure) == "table" and failure.kind and failure
                or Util.error("storage", "The source refresh could not be completed safely."), true)
        end
    end
    local function current()
        if not liveJob() then operation.finish(nil, canceled(), true); return false end
        if not service:_authenticationAllowed() then operation.finish(nil, service:_authenticationError(), true); return false end
        if not service.isReadable(service.store:getEpisode(job.episode_id), true) then
            operation.finish(nil, Util.error("entitlement", "The chapter's offline access is no longer confirmed."), true); return false
        end
        if (service.pages.active[operation_key] or 0) ~= 0 then
            operation.finish(nil, Util.error("busy", "Close the chapter before refreshing its sources.", { code = "chapter_active" }), true)
            return false
        end
        return true
    end
    local next_page = 1
    local function advance()
        protected(function()
            if not current() then return end
            while next_page <= #basis.pages and basis.pages[next_page].history ~= "committed" do next_page = next_page + 1 end
            if next_page > #basis.pages then
                local result, err = Source.adopt(service.pages, basis, operation.index, operation.proofs)
                if result then service:clearFailures(job.episode_id) end
                operation.finish(result, err)
                return
            end
            local index, item = next_page, basis.pages[next_page]
            next_page = next_page + 1
            local space, space_error = Budget.check(service.pages.temporary_root, service:_minimumFree(), Budget.default_image_limit)
            if not space then operation.finish(nil, space_error); return end
            local temporary = service.pages.temporary_root .. "/" .. Util.id("source-proof") .. ".part"
            Files.assertContained(temporary, service.pages.temporary_root)
            operation.temporary_path = temporary
            local request = { kind = "verify_source_page", session = service.session(),
                source_path = operation.paths[index], index = index, expected_checksum = item.checksum,
                temporary_path = temporary, temporary_root = service.pages.temporary_root,
                minimum_free_bytes = service:_minimumFree(), max_bytes = Budget.default_image_limit }
            if item.reference_identity then
                request.reference = { path = item.record.path, root = service.pages.pages_root, identity = item.reference_identity }
            end
            local completed = false
            local task_id = service.runner:submit(request, { priority = 35, resource = "image", timeout = 120 }, function(result, err)
                completed = true
                operation.task_id = nil
                protected(function()
                    if not current() then os.remove(temporary); return end
                    if not result or result.temporary_path ~= temporary or result.checksum ~= item.checksum then
                        operation.finish(nil, err or Util.error("content_changed", "A refreshed page did not match its historical content."))
                        return
                    end
                    operation.proofs[index] = { checksum = result.checksum, reference_identity = result.reference_identity }
                    removeCandidate()
                    operation.checked = operation.checked + 1
                    update("verifying")
                    service:_defer(advance)
                end)
            end)
            if not completed and not operation.finished then operation.task_id = task_id end
            if not completed and not task_id then operation.finish(nil, Util.error("worker", "The verification worker could not start.")) end
        end)
    end
    protected(function()
        if not current() then return end
        if not update("index") then operation.finish(nil, canceled()); return end
        local completed = false
        local task_id = fetch_index(job.episode_id, function(index, err)
            completed = true
            operation.task_id = nil
            protected(function()
                if not current() then return end
                if not index then operation.finish(nil, err or Util.error("protocol", "The fresh image index is unavailable.")); return end
                local paths, validation_error = Source.validateIndex(basis, index)
                if not paths then operation.finish(nil, validation_error); return end
                operation.index, operation.paths = index, paths
                update("verifying")
                service:_defer(advance)
            end)
        end)
        if not completed and not operation.finished then operation.task_id = task_id end
        if not completed and not task_id then operation.finish(nil, Util.error("worker", "The index worker could not start.")) end
    end)
    return true
end

return Refresh
