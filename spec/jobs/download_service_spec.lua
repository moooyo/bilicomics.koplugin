-- Exercise real SQLite and PageStore with an explicitly asynchronous runner double.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(require("datastorage"):getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. package.path
local Service = require("bilicomics/jobs/download_service")
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Files = require("bilicomics/storage/files")
local Util = require("bilicomics/util")
local Budget = require("bilicomics/jobs/storage_budget")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local tests, contexts, sequence = {}, {}, 0
local function check(condition, message) assert(condition, message) end
local function fixture(count)
    sequence = sequence + 1
    local root = output .. "/download-account-" .. sequence
    local store = Store.open({ root = root, account_key = "account-a", wal = false })
    local pages = PageStore.new({ root = root, account_key = "account-a", store = store })
    local descriptor = { schema_version = 1, account_key = "account-a", comic_id = "comic", episode_id = "episode",
        revision = "r1", pages = {} }
    for index = 1, count or 2 do descriptor.pages[index] = { id = "image-" .. index, index = index, width = 40, height = 80 } end
    store:upsertComic({ id = "comic", title = "Synthetic comic" })
    store:upsertEpisodes("comic", { { id = "episode", title = "Synthetic episode", order = 1, access = "owned" } })
    local descriptor_path = pages:ensureDescriptor(descriptor)
    for index in ipairs(descriptor.pages) do
        store:updatePage("episode/r1/" .. index, { extra = { source_path = "synthetic-source-" .. index } })
    end
    local ui = { queue = {} }
    function ui:nextTick(fn) self.queue[#self.queue + 1] = fn end
    function ui:flush()
        local limit = 100
        while #self.queue > 0 do
            limit = limit - 1
            check(limit > 0, "Deferred callbacks must settle without spinning")
            table.remove(self.queue, 1)()
        end
    end
    local runner = { submitted = {}, canceled = {}, promotions = {} }
    function runner:submit(request, options, callback)
        local task = { id = options.id, request = request, options = options, callback = callback }
        self.submitted[#self.submitted + 1] = task
        return task.id
    end
    function runner:promote(id, priority) self.promotions[#self.promotions + 1] = { id = id, priority = priority } end
    function runner:cancel(id)
        self.canceled[#self.canceled + 1] = id
        for _, task in ipairs(self.submitted) do if task.id == id then task.canceled = true end end
        return true
    end
    function runner:complete(task, result, err)
        check(not task.finished, "A runner callback must settle once")
        task.finished = true
        task.callback(result, err)
    end
    local context = { store = store, pages = pages, runner = runner, descriptor = descriptor, descriptor_path = descriptor_path,
        ui = ui, notifications = 0, preparations = 0, ready = 0, ready_records = {} }
    context.service = Service.new({ store = store, pages = pages, runner = runner, account_key = "account-a", ui = ui,
        session = function() return { synthetic = true } end,
        prepare = function(_, _, done)
            context.preparations = context.preparations + 1
            done({ descriptor = descriptor, path = descriptor_path })
        end,
        page_ready = function(page, descriptor)
            context.ready = context.ready + 1
            context.ready_records[#context.ready_records + 1] = { page = page, descriptor = descriptor }
        end,
        notify = function() context.notifications = context.notifications + 1 end })
    contexts[#contexts + 1] = context
    return context
end
local function image(context, name)
    local path = context.pages.temporary_root .. "/" .. name .. ".part"
    Files.write(path, Files.read(output .. "/fixtures/page-a.png"))
    return { temporary_path = path, checksum = Files.digest(path), width = 40, height = 80, format = "png" }
end
local function taskImage(context, task)
    local path = task.request.temporary_path
    Files.write(path, Files.read(output .. "/fixtures/page-a.png"))
    return { temporary_path = path, checksum = Files.digest(path), width = 40, height = 80, format = "png" }
end
local function finish(context, task, name)
    context.runner:complete(task, taskImage(context, task))
    context.ui:flush()
end
local function anotherEpisode(context, episode_id)
    local descriptor = { schema_version = 1, account_key = "account-a", comic_id = "comic", episode_id = episode_id,
        revision = "r1", pages = { { id = "other-image", index = 1, width = 40, height = 80 } } }
    context.store:upsertEpisodes("comic", { { id = episode_id, title = "Another episode", order = 2, access = "owned" } })
    context.pages:ensureDescriptor(descriptor)
    context.store:updatePage(episode_id .. "/r1/1", { extra = { source_path = "synthetic-other-source" } })
    return descriptor
end
local function pendingCommit(context, descriptor, name, blocked)
    context.pages.fault_hook = function(stage)
        if stage == "after_journal" then error("Synthetic failure after durable journal creation") end
    end
    local ok = pcall(context.pages.commitPage, context.pages,
        { episode_id = descriptor.episode_id, revision = descriptor.revision, index = 1 }, image(context, name))
    context.pages.fault_hook = nil
    check(not ok, "The fixture must interrupt a real page commit after its journal is durable")
    local found
    for _, journal in ipairs(context.store:listCommits()) do
        if journal.page.episode_id == descriptor.episode_id then found = journal end
    end
    check(found and Files.exists(found.temporary_path), "The interrupted image must remain owned by its journal")
    if blocked then
        check(not lfs.attributes(found.page.path), "The injected blocker must occupy a new destination")
        Files.mkdir(found.page.path)
    end
    return found
end
local function insufficientSpace(context)
    local available = assert(Budget.available(context.pages.temporary_root))
    local minimum = available + 1024 * 1024 * 1024 * 1024
    context.service.settings = { get = function(_, key)
        if key == "minimum_free_bytes" then return minimum end
        if key == "cache_limit_bytes" then return 256 * 1024 * 1024 end
    end }
    return minimum
end
local function test(name, fn)
    local ok, failure = xpcall(fn, debug.traceback)
    for _, context in ipairs(contexts) do
        if context.store.connection then
            local close_ok, close_error = pcall(function() context.service:close(); context.store:close() end)
            if not close_ok then ok, failure = false, tostring(failure or "") .. tostring(close_error) end
        end
    end
    contexts = {}
    tests[#tests + 1] = { name = name, passed = ok, error = ok and nil or failure }
    print((ok and "PASS " or "FAIL ") .. name)
end

test("Visible and prefetch owners share a single acquisition and cached reads stay asynchronous", function()
    local c, callbacks = fixture(), {}
    local function done(page, err) callbacks[#callbacks + 1] = { page = page, error = err } end
    local id = c.service:requestPage(c.descriptor, 1, { reader_generation = 10, prefetch = true }, done)
    local same = c.service:requestPage(c.descriptor, 1, { reader_generation = 11 }, done)
    check(id == same and #c.runner.submitted == 1, "One source page must have one acquisition")
    check(c.runner.promotions[1].id == id and c.runner.promotions[1].priority == 0, "Visible owner must promote existing prefetch")
    finish(c, c.runner.submitted[1], "deduplicated")
    check(#callbacks == 2 and callbacks[1].page.state == "ready" and not callbacks[2].error and c.ready == 1,
        "One committed image must fan out to both subscribers")
    c.service:requestPage(c.descriptor, 1, {}, done)
    check(#callbacks == 2 and #c.runner.submitted == 1, "Cached callback must defer and avoid another network request")
    c.ui:flush()
    check(#callbacks == 3 and callbacks[3].page.path == callbacks[1].page.path, "Cached callback must return the same committed path")
end)

test("Manual downloads reuse online cache, pin all pages, and complete only after all files exist", function()
    local c = fixture(2)
    c.pages:commitPage({ episode_id = "episode", revision = "r1", index = 1 }, image(c, "cached-first"))
    local identity = Files.read(c.descriptor_path)
    local job = c.service:enqueue("comic", "episode")
    c.ui:flush()
    check(c.store:getJob(job.id).state == "running" and c.store:getJob(job.id).completed == 1,
        "Existing cache must count toward an incomplete download")
    check(#c.runner.submitted == 1 and c.runner.submitted[1].request.index == 2, "Only the missing second page may download")
    check(c.store:isPinned("episode", "r1") and not c.pages:isComplete("episode", "r1"),
        "Manual retention is independent of completeness")
    finish(c, c.runner.submitted[1], "download-second")
    job = c.store:getJob(job.id)
    check(job.state == "complete" and job.completed == 2 and c.pages:isComplete("episode", "r1"),
        "Complete state requires every committed image")
    check(c.pages:evictToLimit(0).removed_pages == 0 and Files.read(c.descriptor_path) == identity,
        "Pinned files and chapter identity must survive automatic cleanup")
    check(c.service:enqueue("comic", "episode").id == job.id and #c.runner.submitted == 1,
        "Repeated enqueue must reuse the completed manual download")
end)

test("A completed download with a missing file can be restored and loses its complete badge on recovery", function()
    local c = fixture(1)
    local job = c.service:enqueue("comic", "episode")
    c.ui:flush()
    finish(c, c.runner.submitted[1], "original-download")
    local page = c.pages:getPage("episode", "r1", 1)
    check(c.store:getJob(job.id).state == "complete", "Fixture must first complete a real download")
    assert(os.remove(page.path))
    local restored = c.service:enqueue("comic", "episode")
    c.ui:flush()
    check(restored.id == job.id and c.store:getJob(job.id).state == "running" and #c.runner.submitted == 2,
        "Missing complete content must restart the existing job")
    finish(c, c.runner.submitted[2], "restored-download")
    check(c.pages:isComplete("episode", "r1") and c.store:getJob(job.id).state == "complete", "Restoration must finish normally")
    assert(os.remove(c.pages:getPage("episode", "r1", 1).path))
    c.service:recover()
    check(c.store:getJob(job.id).state == "paused" and c.store:getJob(job.id).error.kind == "cache_missing",
        "Recovery must persist an actionable state instead of retaining a false complete badge")
end)

test("Immediate resume does not attach new work to an asynchronously canceled attempt", function()
    local c = fixture(1)
    local job = c.service:enqueue("comic", "episode")
    c.ui:flush()
    local previous = c.runner.submitted[1]
    check(c.service:pause(job.id) and c.store:getJob(job.id).state == "paused", "Pause must persist before cancellation")
    check(previous.canceled, "Exclusive download request must cancel on pause")
    c.service:resume(job.id)
    c.ui:flush()
    c.runner:complete(previous, nil, Util.error("canceled", "Synthetic delayed cancellation", { transmitted = true }))
    c.ui:flush()
    check(c.store:getJob(job.id).state ~= "failed", "The canceled old attempt cannot fail a resumed job")
    check(#c.runner.submitted == 2, "Resume must acquire a fresh attempt after retiring the canceled request")
    finish(c, c.runner.submitted[2], "resumed")
    check(c.store:getJob(job.id).state == "complete", "Resumed download must finish normally")
end)

test("Reader and download ownership prevent canceling a still-needed image", function()
    local c = fixture(1)
    c.service:requestPage(c.descriptor, 1, { reader_generation = 42 })
    local job = c.service:enqueue("comic", "episode")
    c.ui:flush()
    check(#c.runner.submitted == 1, "Reader and download must share image work")
    c.service:releaseReader(42)
    check(#c.runner.canceled == 0, "Closing the reader cannot cancel a download-owned request")
    c.service:pause(job.id)
    check(#c.runner.canceled == 1, "The last owner releasing must cancel the request")
end)

test("Canceled acquisitions remove partial files left by a killed child", function()
    local c = fixture(1)
    c.service:requestPage(c.descriptor, 1, { reader_generation = 14 })
    local task = c.runner.submitted[1]
    Files.write(task.request.temporary_path, "synthetic partial image written before SIGKILL")
    c.service:releaseReader(14)
    c.runner:complete(task, nil, Util.error("canceled", "Synthetic killed worker", { transmitted = true }))
    check(not Files.exists(task.request.temporary_path), "Canceled children cannot accumulate abandoned partial images")
    check(c.store:getPage("episode/r1/1").state == "missing", "Canceled partial content cannot become readable")
end)

test("Storage-owned commit journals retain their image for recovery after a commit error", function()
    local c = fixture(1)
    c.pages.fault_hook = function(stage)
        if stage == "after_journal" then error("Synthetic failure after durable journal creation") end
    end
    c.service:requestPage(c.descriptor, 1, {})
    local task = c.runner.submitted[1]
    c.runner:complete(task, taskImage(c, task))
    check(#c.store:listCommits() == 1, "Fixture must reach the durable commit boundary")
    check(Files.exists(task.request.temporary_path), "Service cleanup cannot delete a file owned by a recovery journal")
    c.pages.fault_hook = nil
    local recovered = c.pages:reconcile()
    check(recovered.recovered == 1 and c.pages:isComplete("episode", "r1"),
        "Recovery must finish the previously verified image without fetching it again")
end)

test("Persistent page-state write failures settle every owner and retire the running download", function()
    local c, callbacks = fixture(1), {}
    local job = c.service:enqueue("comic", "episode")
    c.ui:flush()
    c.service:requestPage(c.descriptor, 1, { reader_generation = 91 }, function(_, err)
        callbacks[#callbacks + 1] = err
        error("Synthetic consumer failure must not suppress other owners")
    end)
    c.service:requestPage(c.descriptor, 1, { reader_generation = 92 }, function(_, err) callbacks[#callbacks + 1] = err end)
    local task = c.runner.submitted[1]
    Files.write(task.request.temporary_path, "synthetic failed acquisition")
    local put_page = c.store.putPage
    c.store.putPage = function() error("Synthetic persistent page-state write failure") end
    local settled = pcall(c.runner.complete, c.runner, task, nil, Util.error("network", "Synthetic network failure"))
    c.store.putPage = put_page
    check(settled and #callbacks == 2 and callbacks[1].kind == "storage" and callbacks[2].kind == "storage",
        "A failed failure-state write must still settle every owner with a typed storage error")
    check(c.store:getJob(job.id).state == "failed" and c.store:getJob(job.id).error.kind == "storage",
        "The download cannot retain a running state after its acquisition has settled")
    check(not next(c.service.requests) and not Files.exists(task.request.temporary_path),
        "Failed completion must retire its request and clean unowned temporary content")
    local notifications = c.notifications
    task.callback(nil, Util.error("network", "Duplicate worker completion"))
    check(#callbacks == 2 and c.notifications == notifications,
        "Duplicate completions cannot repeat callbacks, cleanup, or notification")
end)

test("A read-only database exposes an unsaved paused state and resumes after storage recovery", function()
    local Controller = require("bilicomics/controller")
    local c, callbacks = fixture(1), {}
    local job = c.service:enqueue("comic", "episode")
    c.ui:flush()
    c.service:requestPage(c.descriptor, 1, { reader_generation = 93 }, function(_, err) callbacks[#callbacks + 1] = err end)
    local task = c.runner.submitted[1]
    Files.write(task.request.temporary_path, "synthetic partial content before the database becomes read-only")
    c.store.connection:exec("PRAGMA query_only=ON")
    local settled = pcall(c.runner.complete, c.runner, task, nil, Util.error("network", "Synthetic worker failure"))
    local controller = setmetatable({ account = { store = c.store, downloads = c.service } }, Controller)
    local visible = controller:getDownloads()[1]
    c.store.connection:exec("PRAGMA query_only=OFF")
    check(settled and #callbacks == 1 and callbacks[1].kind == "storage",
        "Real SQLite write rejection must not swallow the acquisition callback")
    check(c.store:getJob(job.id).state == "running" and visible.state == "paused"
        and visible.persistence_pending and visible.error.kind == "storage",
        "The UI must distinguish the unsaved local terminal state from the unchanged durable job")
    check(not next(c.service.requests) and not Files.exists(task.request.temporary_path),
        "Read-only metadata cannot prevent cleanup of an unowned partial file")
    local newer = c.store:getJob(job.id)
    newer.state, newer.run_generation = "paused", newer.run_generation + 1
    c.store:putJob(newer)
    check(not controller:getDownloads()[1].persistence_pending,
        "A newer durable job state supersedes an obsolete process-local failure projection")
    check(c.service:resume(job.id), "Restored writable storage must allow an explicit retry")
    c.ui:flush()
    check(#c.runner.submitted == 2 and not controller:getDownloads()[1].persistence_pending,
        "A successfully persisted retry clears the process-local projection")
    finish(c, c.runner.submitted[2])
    check(controller:getDownloads()[1].state == "complete", "The retried download must complete normally")
end)

test("A failed pause write cannot project an active acquisition as already paused", function()
    local c = fixture(1)
    local job = c.service:enqueue("comic", "episode")
    c.ui:flush()
    c.store.connection:exec("PRAGMA query_only=ON")
    local paused = pcall(c.service.pause, c.service, job.id)
    c.store.connection:exec("PRAGMA query_only=OFF")
    local visible = c.service:projectJob(c.store:getJob(job.id))
    check(not paused and visible.state == "running" and not visible.persistence_pending,
        "An unsuccessful pause cannot claim that its still-owned worker has settled")
    check(#c.runner.canceled == 0 and next(c.service.requests) ~= nil,
        "The projection must describe actual task ownership when pause itself was rejected")
    finish(c, c.runner.submitted[1])
    check(c.store:getJob(job.id).state == "complete", "The unchanged running operation must still settle normally")
end)

test("Read-only failure after journal creation preserves the image and recovers without another worker", function()
    local c, callbacks = fixture(1), {}
    local job = c.service:enqueue("comic", "episode")
    c.ui:flush()
    c.service:requestPage(c.descriptor, 1, { reader_generation = 94 }, function(_, err) callbacks[#callbacks + 1] = err end)
    local task = c.runner.submitted[1]
    c.pages.fault_hook = function(stage)
        if stage == "after_journal" then
            c.store.connection:exec("PRAGMA query_only=ON")
            error("Synthetic read-only transition after the image journal is durable")
        end
    end
    local settled = pcall(c.runner.complete, c.runner, task, taskImage(c, task))
    c.store.connection:exec("PRAGMA query_only=OFF")
    c.pages.fault_hook = nil
    local pending = c.service:projectJob(c.store:getJob(job.id))
    check(settled and #callbacks == 1 and callbacks[1].kind == "storage" and pending.persistence_pending,
        "Both image and job write failures must settle the same acquisition exactly once")
    check(#c.store:listCommits() == 1 and Files.exists(task.request.temporary_path) and c.ready == 0,
        "Failure cleanup must preserve the journal's only verified image")
    check(c.service:resume(job.id), "Explicit retry must recover the durable journal")
    c.ui:flush()
    check(#c.runner.submitted == 1 and #c.store:listCommits() == 0 and c.ready == 1
        and c.store:getJob(job.id).state == "complete" and c.pages:isComplete("episode", "r1"),
        "Recovery must publish one ready notification and complete without reacquiring the image")
    check(not c.service:projectJob(c.store:getJob(job.id)).persistence_pending and #callbacks == 1,
        "Durable recovery must clear the unsaved projection without replaying old callbacks")
end)

test("Successful image callbacks survive cache-setting and notification failures", function()
    local c, callbacks = fixture(1), {}
    c.service.settings = { get = function(_, key)
        if key == "cache_limit_bytes" then error("Synthetic cache-setting read failure") end
        return Budget.default_minimum
    end }
    c.service.notify = function() error("Synthetic notification failure") end
    c.service:requestPage(c.descriptor, 1, {}, function(page, err) callbacks[#callbacks + 1] = { page = page, error = err } end)
    local task = c.runner.submitted[1]
    local settled = pcall(c.runner.complete, c.runner, task, taskImage(c, task))
    check(settled and #callbacks == 1 and callbacks[1].page.state == "ready" and not callbacks[1].error and c.ready == 1,
        "An already committed image remains successful when subsequent maintenance or notification fails")
    check(not next(c.service.requests) and #c.store:listCommits() == 0,
        "Success cleanup must not leave a live request or a completed journal")
end)

test("Retired acquisitions still settle once when temporary-file cleanup throws", function()
    local c, callbacks = fixture(1), {}
    c.service:requestPage(c.descriptor, 1, { reader_generation = 95 }, function(_, err) callbacks[#callbacks + 1] = err end)
    local task = c.runner.submitted[1]
    c.service:releaseReader(95)
    local cleanup = c.service._cleanupTemporary
    c.service._cleanupTemporary = function() error("Synthetic temporary-file cleanup failure") end
    local settled = pcall(c.runner.complete, c.runner, task, nil, Util.error("canceled", "Synthetic canceled worker"))
    c.service._cleanupTemporary = cleanup
    task.callback(nil, Util.error("canceled", "Duplicate canceled completion"))
    check(settled and #callbacks == 1 and callbacks[1].kind == "canceled" and not next(c.service.requests),
        "Cleanup failure must neither replace cancellation nor suppress or repeat its callback")
end)

test("Reader retry recovers an interrupted commit and notifies the active reader without downloading again", function()
    local c, callback = fixture(1), nil
    c.pages:setActiveEpisode("episode", "r1", true)
    c.pages.fault_hook = function(stage)
        if stage == "after_journal" then error("Synthetic interrupted reader commit") end
    end
    c.service:requestPage(c.descriptor, 1, { reader_generation = 99 })
    c.runner:complete(c.runner.submitted[1], taskImage(c, c.runner.submitted[1]))
    check(#c.store:listCommits() == 1 and c.ready == 0, "Reader retry must begin with an unannounced interrupted image")
    c.pages.fault_hook = nil
    c.service:requestPage(c.descriptor, 1, { reader_generation = 99, retry = true }, function(page, err)
        callback = { page = page, error = err }
    end)
    c.ui:flush()
    check(#c.runner.submitted == 1 and #c.store:listCommits() == 0, "Retry must finish the journal before considering network acquisition")
    check(callback and callback.page and callback.page.state == "ready" and not callback.error,
        "Reader retry must return its locally recovered image")
    check(c.ready == 1 and c.ready_records[1].page.key == "episode/r1/1"
        and c.ready_records[1].descriptor.episode_id == "episode", "Recovery must emit the exact page and descriptor to the active reader")
    c.pages:setActiveEpisode("episode", "r1", false)
end)

test("Download resume recovers its cached image while preserving another worker's partial file", function()
    local c = fixture(2)
    c.pages:commitPage({ episode_id = "episode", revision = "r1", index = 1 }, image(c, "resume-cached-first"))
    local job = c.service:enqueue("comic", "episode")
    c.ui:flush()
    c.pages.fault_hook = function(stage)
        if stage == "after_journal" then error("Synthetic interrupted download commit") end
    end
    c.runner:complete(c.runner.submitted[1], taskImage(c, c.runner.submitted[1]))
    c.ui:flush()
    c.pages.fault_hook = nil
    check(c.store:getJob(job.id).state == "failed" and #c.store:listCommits() == 1,
        "Resume must start from a durable failed job with recoverable content")
    local other = anotherEpisode(c, "other-active")
    c.service:requestPage(other, 1, { reader_generation = 87 })
    local active_task = c.runner.submitted[2]
    Files.write(active_task.request.temporary_path, "synthetic image still being written by another worker")
    local partial = Files.read(active_task.request.temporary_path)
    c.service:resume(job.id)
    c.ui:flush()
    check(#c.runner.submitted == 2 and c.store:getJob(job.id).state == "complete" and c.pages:isComplete("episode", "r1"),
        "Resume must count recovered and previously ready files without re-downloading either image")
    check(c.ready == 1 and c.ready_records[1].page.index == 2, "Recovered completion must announce the page that became readable")
    check(not active_task.finished and not active_task.canceled and Files.read(active_task.request.temporary_path) == partial,
        "Retry recovery must never run full reconciliation or remove another acquisition's partial file")
end)

test("An unrelated unresolved journal cannot block the requested chapter", function()
    local c = fixture(1)
    local other = anotherEpisode(c, "other-blocked")
    local journal = pendingCommit(c, other, "unrelated-journal", true)
    c.service:requestPage(c.descriptor, 1, { retry = true })
    c.ui:flush()
    check(#c.runner.submitted == 1 and c.runner.submitted[1].request.source_path == "synthetic-source-1",
        "An unrelated pending chapter must not suppress the requested page's network work")
    finish(c, c.runner.submitted[1], "unrelated-progress")
    check(c.pages:isComplete("episode", "r1") and #c.store:listCommits() == 1
        and Files.exists(journal.temporary_path), "Progress on this chapter must preserve the unrelated recovery journal")
    assert(lfs.rmdir(journal.page.path))
end)

test("An unresolved journal for this chapter prevents page retry and download resume from fetching images", function()
    local c, callback = fixture(1), nil
    local journal = pendingCommit(c, c.descriptor, "blocked-current-journal", true)
    c.service:requestPage(c.descriptor, 1, { retry = true }, function(page, err) callback = { page = page, error = err } end)
    c.ui:flush()
    check(#c.runner.submitted == 0 and callback and not callback.page and callback.error,
        "Page retry must report unresolved local storage before submitting another image request")
    c.store:putJob({ id = "blocked-download", kind = "episode_download", state = "paused", comic_id = "comic",
        episode_id = "episode", revision = "r1", completed = 0, total = 1, payload = {} })
    c.service:resume("blocked-download")
    c.ui:flush()
    local job = c.store:getJob("blocked-download")
    check(#c.runner.submitted == 0 and (job.state == "failed" or job.state == "paused") and job.error,
        "A blocked local commit must produce an actionable download state without duplicate acquisition")
    check(c.preparations == 0, "An unresolved local commit must block resume before fetching a remote chapter index")
    check(#c.store:listCommits() == 1 and Files.exists(journal.temporary_path),
        "Failed recovery must retain its existing verified image and journal")
    assert(lfs.rmdir(journal.page.path))
end)

test("Insufficient real free space prevents a new page task before submission", function()
    local c, callback = fixture(1), nil
    local minimum = insufficientSpace(c)
    c.service:requestPage(c.descriptor, 1, {}, function(page, err) callback = { page = page, error = err } end)
    c.ui:flush()
    check(#c.runner.submitted == 0 and callback and not callback.page and callback.error.kind == "low_space",
        "A missing page must fail preflight without starting network work")
    check(callback.error.required_bytes >= minimum and callback.error.available_bytes < callback.error.required_bytes,
        "Low-space feedback must contain the actual required and available byte values")
    check(c.store:getPage("episode/r1/1").state == "missing", "Capacity rejection cannot manufacture cached content")
end)

test("Cached reads and recoverable journals remain readable below the free-space threshold", function()
    local c, callback = fixture(1), nil
    c.pages:commitPage({ episode_id = "episode", revision = "r1", index = 1 }, image(c, "space-cached"))
    insufficientSpace(c)
    c.service:requestPage(c.descriptor, 1, {}, function(page, err) callback = { page = page, error = err } end)
    c.ui:flush()
    check(callback and callback.page and not callback.error and #c.runner.submitted == 0,
        "Existing offline content must bypass acquisition capacity checks")
    local other = anotherEpisode(c, "space-recoverable")
    pendingCommit(c, other, "space-journal", false)
    callback = nil
    c.service:requestPage(other, 1, { retry = true }, function(page, err) callback = { page = page, error = err } end)
    c.ui:flush()
    check(callback and callback.page and callback.page.state == "ready" and not callback.error
        and #c.runner.submitted == 0 and #c.store:listCommits() == 0,
        "An already-written journal image must recover without requesting more free image capacity")
    check(c.ready == 1 and c.ready_records[1].page.episode_id == "space-recoverable",
        "Recovered content must still notify the reader when capacity is low")
end)

test("Low capacity pauses a manual download and never deletes protected cached pages", function()
    local c = fixture(1)
    local pinned = anotherEpisode(c, "space-pinned")
    c.pages:commitPage({ episode_id = pinned.episode_id, revision = "r1", index = 1 }, image(c, "space-pinned-image"))
    c.pages:pinEpisode(pinned.episode_id, "r1", true)
    local active = anotherEpisode(c, "space-active")
    c.pages:commitPage({ episode_id = active.episode_id, revision = "r1", index = 1 }, image(c, "space-active-image"))
    c.pages:setActiveEpisode(active.episode_id, "r1", true)
    local automatic = anotherEpisode(c, "space-automatic")
    c.pages:commitPage({ episode_id = automatic.episode_id, revision = "r1", index = 1 }, image(c, "space-automatic-image"))
    insufficientSpace(c)
    local job = c.service:enqueue("comic", "episode")
    c.ui:flush()
    job = c.store:getJob(job.id)
    check(job.state == "paused" and job.error.kind == "low_space" and #c.runner.submitted == 0,
        "A manual download must become resumable after low-space preflight failure")
    check(c.pages:isComplete(pinned.episode_id, "r1") and c.pages:isComplete(active.episode_id, "r1"),
        "Capacity cleanup must preserve retained downloads and active reader content")
    check(c.pages:getPage(automatic.episode_id, "r1", 1).state == "missing",
        "Capacity cleanup must attempt to release available automatic cache")
    c.pages:setActiveEpisode(active.episode_id, "r1", false)
end)

test("A worker-time low-space response pauses the current download without committing its partial file", function()
    local c = fixture(1)
    local job = c.service:enqueue("comic", "episode")
    c.ui:flush()
    local task = c.runner.submitted[1]
    check(task.request.minimum_free_bytes == Budget.default_minimum and task.request.max_bytes == Budget.default_image_limit,
        "The actual worker must receive the same reserve and transfer budget as preflight")
    Files.write(task.request.temporary_path, "synthetic partial file before a capacity failure")
    c.runner:complete(task, nil, { kind = "low_space", message = "Synthetic capacity change after queueing", retryable = false })
    c.ui:flush()
    check(c.store:getJob(job.id).state == "paused" and c.store:getJob(job.id).error.kind == "low_space",
        "Capacity changes after queueing must also produce a resumable pause")
    check(not Files.exists(task.request.temporary_path) and not c.pages:isComplete("episode", "r1"),
        "A rejected worker result cannot leave a partial file or false complete state")
end)

test("Removed page generations reject a late acquisition without restoring cached content", function()
    local c, callback = fixture(1), nil
    c.service:requestPage(c.descriptor, 1, {}, function(value, err) callback = { value = value, error = err } end)
    local result = taskImage(c, c.runner.submitted[1])
    c.pages:removeEpisode("episode", "r1")
    local generation = c.store:getPage("episode/r1/1").content_generation
    c.runner:complete(c.runner.submitted[1], result)
    local page = c.store:getPage("episode/r1/1")
    check(page.state == "missing" and page.content_generation == generation and not page.path and not c.pages:isComplete("episode", "r1"),
        "Explicit removal must win over the older acquisition result")
    check(callback and not callback.value and callback.error and c.ready == 0, "Rejected generation cannot notify the reader of a ready image")
    c.service:requestPage(c.descriptor, 1, {})
    c.ui:flush()
    check(#c.runner.submitted == 2, "An obsolete completion cannot poison a later read with its stale storage failure")
end)

test("An account generation change discards late images and removes their temporary file", function()
    local c, calls = fixture(1), 0
    c.service:requestPage(c.descriptor, 1, {}, function() calls = calls + 1 end)
    local result = taskImage(c, c.runner.submitted[1])
    c.service.generation = c.service.generation + 1
    c.runner:complete(c.runner.submitted[1], result)
    check(c.store:getPage("episode/r1/1").state == "missing" and not Files.exists(result.temporary_path)
        and calls == 0 and c.ready == 0, "Old account work must be dropped before touching page state")
end)

test("Account close makes late acquisition safe after the SQLite connection closes", function()
    local c, calls = fixture(1), 0
    c.service:requestPage(c.descriptor, 1, {}, function() calls = calls + 1 end)
    local result = taskImage(c, c.runner.submitted[1])
    c.service:close()
    c.store:close()
    c.runner:complete(c.runner.submitted[1], result)
    check(not Files.exists(result.temporary_path) and calls == 0 and c.ready == 0,
        "Closed service must discard the late result without reading a closed database")
end)

test("Late index preparation after account close cannot access closed SQLite", function()
    local c, prepared = fixture(1), nil
    c.service.prepare = function(_, _, callback) prepared = callback end
    local job = c.service:enqueue("comic", "episode")
    check(job.state == "queued" and prepared, "Fixture must stop at asynchronous index preparation")
    c.service:close()
    c.store:close()
    prepared({ descriptor = c.descriptor })
    check(#c.runner.submitted == 0, "Closing during preparation must not launch image work")
end)

test("A preparation from before pause cannot replace the resumed preparation", function()
    local c, pending = fixture(1), {}
    c.service.prepare = function(_, _, callback) pending[#pending + 1] = callback end
    local job = c.service:enqueue("comic", "episode")
    c.service:pause(job.id)
    c.service:resume(job.id)
    check(#pending == 2, "Resume must issue a new preparation attempt")
    pending[1](nil, Util.error("network", "Obsolete preparation failure"))
    check(c.store:getJob(job.id).state == "queued", "Obsolete preparation cannot fail or start the resumed job")
    pending[2]({ descriptor = c.descriptor })
    c.ui:flush()
    check(c.store:getJob(job.id).state == "running" and #c.runner.submitted == 1,
        "Only the current preparation may start downloading")
    finish(c, c.runner.submitted[1], "fresh-preparation")
    check(c.store:getJob(job.id).state == "complete", "Current preparation must lead to completion")
end)

test("Account close drops deferred cached callbacks before they reach the previous UI", function()
    local c, callbacks = fixture(1), 0
    c.pages:commitPage({ episode_id = "episode", revision = "r1", index = 1 }, image(c, "close-cached"))
    c.service:requestPage(c.descriptor, 1, {}, function() callbacks = callbacks + 1 end)
    c.service:close()
    c.store:close()
    c.ui:flush()
    check(callbacks == 0, "An old-account deferred callback cannot update a replaced UI")
end)

test("Offline permission is checked again after asynchronous preparation refreshes rights", function()
    local c, prepared = fixture(1), nil
    c.service.prepare = function(_, _, callback) prepared = callback end
    local job = c.service:enqueue("comic", "episode")
    c.store:upsertEpisodes("comic", { { id = "episode", order = 1, access = "temporary",
        expires_at = os.time() + 600, extra = { offline_allowed = false } } })
    prepared({ descriptor = c.descriptor })
    c.ui:flush()
    check(#c.runner.submitted == 0 and not c.store:isPinned("episode", "r1"),
        "Refreshed temporary online-only rights cannot become a retained download")
    check(c.store:getJob(job.id).state == "failed" or c.store:getJob(job.id).state == "paused",
        "Lost offline permission must become an actionable persisted job state")
end)

test("Expired temporary access and unconfirmed offline permission reject manual downloads", function()
    local c = fixture(1)
    c.store:upsertEpisodes("comic", { { id = "episode", order = 1, access = "temporary", expires_at = os.time() - 1 } })
    local job, err = c.service:enqueue("comic", "episode")
    check(not job and err.kind == "entitlement" and #c.runner.submitted == 0, "Expired access cannot download")
    c.store:upsertEpisodes("comic", { { id = "episode", order = 1, access = "temporary", expires_at = os.time() + 600 } })
    job, err = c.service:enqueue("comic", "episode")
    check(not job and err.kind == "entitlement", "Temporary online access alone does not authorize offline retention")
    c.service:requestPage(c.descriptor, 1, {})
    check(#c.runner.submitted == 1, "Unexpired temporary access may acquire a page for online reading")
end)

test("Restart recovery persists interrupted downloads as paused and keeps existing verified pages", function()
    local c = fixture(2)
    c.pages:commitPage({ episode_id = "episode", revision = "r1", index = 1 }, image(c, "recovery-cached"))
    local job = c.service:enqueue("comic", "episode")
    c.ui:flush()
    local root = c.pages.root
    c.store:close()
    c.store = Store.open({ root = root, account_key = "account-a", wal = false })
    c.pages = PageStore.new({ root = root, account_key = "account-a", store = c.store })
    local fresh_runner = { calls = 0, cancel = function() end, submit = function(self) self.calls = self.calls + 1 end }
    c.service = Service.new({ store = c.store, pages = c.pages, runner = fresh_runner,
        account_key = "account-a", session = function() return {} end, ui = c.ui,
        prepare = function() error("Recovery cannot fetch a remote index") end })
    c.service:recover()
    check(c.store:getJob(job.id).state == "paused" and c.pages:getPage("episode", "r1", 1).state == "ready",
        "Recovery must not silently resume network work or discard verified pages")
    check(fresh_runner.calls == 0 and c.store:isPinned("episode", "r1"),
        "Process-state replacement must preserve retention without starting workers")
end)

local passed = true
for _, item in ipairs(tests) do passed = passed and item.passed end
Files.write(output .. "/download-result.json", json.encode({ tests = tests, passed = passed }, { pretty = true }))
assert(passed, "One or more download service contract tests failed")
