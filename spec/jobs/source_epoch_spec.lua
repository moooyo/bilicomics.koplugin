-- Reading-only storage and delayed image completion checks on test-env.
require("setupkoenv")
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. package.path
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Downloads = require("bilicomics/jobs/download_service")
local Files = require("bilicomics/storage/files")
local JSON = require("bilicomics/protocol/json")
local checks = {}
local function check(name, value) assert(value, name); checks[#checks + 1] = name end
local function fixture(name)
    local root = output .. "/" .. name
    local store = Store.open{ root = root, account_key = "synthetic" }
    local pages = PageStore.new{ root = root, account_key = "synthetic", store = store }
    store:upsertComic{ id = "1", title = "Synthetic comic" }
    store:upsertEpisodes("1", { { id = "2", access = "free", order = 1 } })
    local descriptor = { schema_version = 1, account_key = "synthetic", comic_id = "1", episode_id = "2",
        revision = "snapshot", pages = { { id = "first", index = 1, width = 40, height = 80 } } }
    pages:ensureDescriptor(descriptor)
    local page = store:getPage("2/snapshot/1")
    page.extra.source_path = "/synthetic/old-source.png"
    store:putPage(page)
    local runner = { tasks = {}, canceled = {} }
    function runner:submit(request, options, callback)
        local task = { request = request, callback = callback, id = options.id }
        self.tasks[#self.tasks + 1] = task
        return task.id
    end
    function runner:promote() end
    function runner:cancel(id) self.canceled[id] = true end
    local ui = { queue = {} }
    function ui:nextTick(fn) self.queue[#self.queue + 1] = fn end
    local invalidated = 0
    local service = Downloads.new{ store = store, pages = pages, runner = runner, account_key = "synthetic",
        session = function() return {} end, prepare = function() error("No index preparation is expected") end,
        ui = ui, on_authentication_error = function() invalidated = invalidated + 1 end }
    local function rotate(expected)
        local current = store:getPage("2/snapshot/1")
        current.extra.source_generation = (current.extra.source_generation or 0) + 1
        current.extra.source_path = "/synthetic/new-source.png"
        current.extra.expected_source_checksum = expected
        store:putPage(current)
    end
    local function acquired(task, image)
        Files.write(task.request.temporary_path, Files.read(output .. "/fixtures/" .. image .. ".png"))
        return { temporary_path = task.request.temporary_path, checksum = Files.digest(task.request.temporary_path),
            format = "png", width = 40, height = 80 }
    end
    return store, pages, service, runner, descriptor, rotate, acquired, function() return invalidated end
end
do
    local store, _, service, runner, descriptor, rotate, acquired = fixture("stale-success")
    local failure
    service:requestPage(descriptor, 1, {}, function(_, err) failure = err end)
    local task = runner.tasks[1]
    local image = acquired(task, "page-a")
    rotate()
    task.callback(image)
    check("old_source_success_is_canceled", failure and failure.kind == "canceled")
    check("old_source_cannot_publish_or_fail_new_epoch", store:getPage("2/snapshot/1").state == "missing"
        and not store:getPage("2/snapshot/1").error and #store:listCommits() == 0)
    check("old_source_candidate_is_removed", not Files.exists(image.temporary_path))
    store:close()
end
do
    local store, _, service, runner, descriptor, rotate, _, invalidated = fixture("stale-error")
    local failure
    service:requestPage(descriptor, 1, {}, function(_, err) failure = err end)
    rotate()
    runner.tasks[1].callback(nil, { kind = "authentication", message = "Synthetic old error" })
    check("old_source_error_is_canceled", failure and failure.kind == "canceled")
    check("old_source_authentication_error_does_not_invalidate_new_epoch", invalidated() == 0 and not service.authentication_error)
    check("old_source_error_does_not_poison_retry_state", next(service.failures) == nil and store:getPage("2/snapshot/1").state == "missing")
    store:close()
end
do
    local store, _, service, runner, descriptor, rotate = fixture("deduplication")
    service:requestPage(descriptor, 1, {})
    local old = runner.tasks[1]
    rotate()
    service:requestPage(descriptor, 1, {})
    check("new_epoch_retires_old_request_instead_of_deduplicating_into_it", runner.canceled[old.id]
        and #runner.tasks == 2 and runner.tasks[2].request.source_path == "/synthetic/new-source.png")
    store:close()
end
do
    local store, pages, service, runner, descriptor, rotate, acquired = fixture("bound-digest")
    local expected = Files.digest(output .. "/fixtures/page-a.png")
    rotate(expected)
    local failure, completed
    service:requestPage(descriptor, 1, {}, function(value, err) completed, failure = value, err end)
    local wrong = acquired(runner.tasks[1], "page-b")
    runner.tasks[1].callback(wrong)
    check("refreshed_binding_rejects_different_bytes", not completed and failure and failure.kind == "content_changed")
    check("different_bytes_do_not_become_cached_content", store:getPage("2/snapshot/1").state == "failed"
        and not store:getPage("2/snapshot/1").checksum and not Files.exists(wrong.temporary_path))
    service:requestPage(descriptor, 1, { retry = true }, function(value, err) completed, failure = value, err end)
    local correct = acquired(runner.tasks[2], "page-a")
    runner.tasks[2].callback(correct)
    check("matching_bound_bytes_commit_normally", completed and not failure and completed.checksum == expected
        and pages:getPage("2", "snapshot", 1).state == "ready")
    local rejected = acquired({ request = { temporary_path = pages.temporary_root .. "/direct.part" } }, "page-a")
    local accepted = pcall(pages.commitPage, pages,
        { episode_id = "2", revision = "snapshot", index = 1, expected_source_generation = 0 }, rejected)
    check("page_store_itself_rejects_a_stale_source_generation", not accepted and #store:listCommits() == 0)
    os.remove(rejected.temporary_path)
    store:close()
end
Files.write(output .. "/source-epoch-result.json", assert(JSON.encode({ passed = #checks, checks = checks,
    scope = "Real SQLite and page commits with controlled delayed image results; no live network or payment operations",
    network_requests = 0, purchase_testing = false })))
print("PASS " .. #checks .. " image source epoch checks")
