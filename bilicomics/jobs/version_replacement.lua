-- Explicitly prepare a new local snapshot without retiring the old retained data.
local Replacement = require("bilicomics/storage/version_replacement")
local Util = require("bilicomics/util")
local Flow = {}

function Flow.active(service, episode_id)
    return (service.version_replacements or {})[tostring(episode_id)]
end

function Flow.cancel(service, job_id)
    local pending = {}
    for _, operation in pairs(service.version_replacements or {}) do
        if job_id == nil or operation.job_id == job_id then pending[#pending + 1] = operation end
    end
    for _, operation in ipairs(pending) do
        operation.finish(nil, Util.error("canceled", "New-version preparation was canceled."), true)
    end
    return #pending > 0
end

function Flow.start(service, job_id, fetch_index, callback)
    if service.closed then return nil, Util.error("closed", "The download service is closed.") end
    local job = service.store:getJob(job_id)
    if not job or job.kind ~= "episode_download" or not job.revision or job.state == "complete"
        or (job.payload or {}).removed or (job.payload or {}).replaced_by then
        return nil, Util.error("invalid_request", "Select a retained partial download to create a new version.")
    end
    if Flow.active(service, job.episode_id) or service:isRefreshingSources(job.episode_id) then
        return nil, Util.error("busy", "Finish or cancel this chapter's existing recovery operation first.")
    end
    if not service:_authenticationAllowed() then return nil, service:_authenticationError() end
    if not service.isReadable(service.store:getEpisode(job.episode_id), true) then
        return nil, Util.error("entitlement", "The chapter needs confirmed offline reading access.")
    end
    if (service.pages.active[job.episode_id .. "/" .. job.revision] or 0) > 0 then
        return nil, Util.error("busy", "Close this chapter before downloading a new version.", { code = "chapter_active" })
    end
    service:pause(job_id)
    local recovered, recovery_error = service:_recoverCommits(job.episode_id, job.revision)
    if not recovered then return nil, recovery_error end
    job = service.store:getJob(job_id)
    local operation = { id = Util.id("version-replacement"), job_id = job_id, episode_id = job.episode_id,
        revision = job.revision, run_generation = job.run_generation, generation = service.generation }
    service.version_replacements = service.version_replacements or {}
    service.version_replacements[job.episode_id] = operation
    local snapshot_key = job.episode_id .. "/" .. job.revision
    service.pages.version_replacement_locks = service.pages.version_replacement_locks or {}
    service.pages.version_replacement_locks[snapshot_key] = operation

    local function current()
        if operation.finished or service.closed or service.generation ~= operation.generation
            or service.version_replacements[operation.episode_id] ~= operation then return nil end
        local found = service.store:getJob(job_id)
        if found and found.state == "paused" and found.revision == operation.revision
            and found.run_generation == operation.run_generation then return found end
    end
    function operation.finish(value, err, cancel_worker)
        if operation.finished then return end
        operation.finished = true
        if service.version_replacements[operation.episode_id] == operation then
            service.version_replacements[operation.episode_id] = nil
        end
        if service.pages.version_replacement_locks[snapshot_key] == operation then
            service.pages.version_replacement_locks[snapshot_key] = nil
        end
        local terminal_error
        local function safely(fn)
            if not pcall(fn) then terminal_error = Util.error("storage", "New-version preparation ended with a storage error.") end
        end
        if cancel_worker and operation.task_id then safely(function() service.runner:cancel(operation.task_id) end) end
        -- Successful publication already removed this marker in its transaction.
        if not value then
            safely(function()
                local found = service.store:getJob(job_id)
                local marker = found and (found.payload or {}).version_replacement
                if marker and marker.id == operation.id then
                    found.payload.version_replacement = nil
                    found.error = err and err.kind ~= "canceled" and err or nil
                    service:_update(found)
                end
            end)
        end
        if err and err.kind == "authentication" and not service.closed and service.generation == operation.generation then
            safely(function() service:invalidateAuthentication() end)
        end
        Util.callback(callback, value, terminal_error or err)
    end
    local function protected(fn)
        local ok, failure = pcall(fn)
        if not ok then
            operation.finish(nil, type(failure) == "table" and failure.kind and failure
                or Util.error("storage", "The new chapter version could not be prepared safely."), true)
        end
    end
    protected(function()
        job.payload = job.payload or {}
        job.payload.version_replacement = { id = operation.id, stage = "index" }
        service:_update(job)
        local basis, capture_error = Replacement.capture(service.pages, job_id)
        if not basis then operation.finish(nil, capture_error); return end
        local completed = false
        local task_id = fetch_index(job.episode_id, function(index, err)
            completed = true; operation.task_id = nil
            protected(function()
                if not current() then
                    operation.finish(nil, Util.error("canceled", "The selected download changed during preparation.")); return
                end
                if not service:_authenticationAllowed() then operation.finish(nil, service:_authenticationError()); return end
                if not service.isReadable(service.store:getEpisode(job.episode_id), true) then
                    operation.finish(nil, Util.error("entitlement", "The chapter's offline access is no longer confirmed.")); return
                end
                if not index then operation.finish(nil, err or Util.error("protocol", "The fresh chapter index is unavailable.")); return end
                local result, publication_error = Replacement.publish(service.pages, basis, index)
                operation.finish(result, publication_error)
            end)
        end)
        if not completed and not operation.finished then operation.task_id = task_id end
        if not completed and not task_id then operation.finish(nil, Util.error("worker", "The index worker could not start.")) end
    end)
    return true
end

return Flow
