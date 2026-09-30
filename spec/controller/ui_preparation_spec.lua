-- Production controller, real SQLite and controlled workers in an isolated KOReader profile.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(require("datastorage"):getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local Controller = require("bilicomics/controller")
local Bookshelf = require("bilicomics/bookshelf_state")
local Source = require("bilicomics/cover_source")
local Session = require("bilicomics/protocol/session")
local Screens = require("bilicomics/ui/screens")
local Files = require("bilicomics/storage/files")
local Codec = require("bilicomics/storage/codec")
local json = require("rapidjson")
local tests, contexts, sequence = {}, {}, 0

local function check(name, value)
    tests[#tests + 1] = { name = name, passed = not not value }
    assert(value, name)
end

local function comic(identifier, url)
    return { id = tostring(identifier), title = "Synthetic comic " .. identifier, cover_url = url }
end

local function fixture(visible)
    sequence = sequence + 1
    local context = { now = 1000, callbacks = {}, retired = {} }
    local ui = { queue = {}, timers = {} }
    function ui:nextTick(callback) self.queue[#self.queue + 1] = callback end
    function ui:scheduleIn(delay, callback) self.timers[callback] = delay end
    function ui:unschedule(callback) self.timers[callback] = nil end
    function ui:close() end
    function ui:drain()
        local remaining = 1000
        while #self.queue > 0 do
            remaining = remaining - 1; assert(remaining > 0, "Unbounded deferred work")
            table.remove(self.queue, 1)()
        end
    end
    local function runnerFactory()
        local runner = { tasks = {}, count = 0 }
        function runner:submit(request, options, callback)
            self.count = self.count + 1
            local task = { id = self.count, request = request, options = options, callback = callback }
            self.tasks[task.id] = task
            return task.id
        end
        function runner:find(kind, library)
            for _, task in pairs(self.tasks) do
                if task.request.kind == kind and (not library or task.request.library == library) then return task end
            end
        end
        function runner:finish(task, value, err)
            self.tasks[task.id] = nil
            task.callback(value, err); ui:drain()
        end
        function runner:start(task)
            local allowed, err = true
            if task.options.before_start then allowed, err = task.options.before_start() end
            if allowed ~= true then self:finish(task, nil, err); return false end
            return true
        end
        function runner:cancel(identifier)
            local task = self.tasks[identifier]
            if task then self:finish(task, nil, { kind = "canceled", transmitted = false }) end
        end
        function runner:close() self.closed = true end
        function runner:suspend() self.suspended = true end
        function runner:resume() self.suspended = false end
        function runner:promote() end
        return runner
    end
    context.network = { connected = true }
    function context.network:isConnected() return self.connected end
    context.ui = ui
    context.app = Controller.new{ root = output .. "/account-" .. sequence, ui_manager = ui,
        runner_factory = runnerFactory, network = context.network, clock = function() return context.now end }
    context.app.account.session = Session.new{ cookies = { SESSDATA = "synthetic-only", DedeUserID = "42", buvid3 = "synthetic-device" } }
    context.app.account.session_valid = true
    context.app:setScreens{ route = "favorites", getInitialBookshelfCoverIDs = function(_screen, items)
        if type(visible) == "function" then return visible(context.app, items) end
        return visible or {}
    end,
        refresh = function() context.refreshes = (context.refreshes or 0) + 1 end, close = function() end }
    function context:begin()
        self.app:syncBookshelf(function(value, err) self.callbacks[#self.callbacks + 1] = { value = value, error = err } end)
        return self.app.account.raw_runner
    end
    function context:ingest(comics)
        local runner = self:begin()
        runner:finish(assert(runner:find("library", "favorites")), comics)
        runner:finish(assert(runner:find("library", "history")), {})
        return runner
    end
    function context:cache(comic_value)
        local source = assert(Source.resolve(comic_value.cover_url))
        local root = self.app.account.root .. "/covers"
        Files.mkdir(root)
        comic_value.cover_path = root .. "/cached-" .. comic_value.id .. ".png"
        Files.write(comic_value.cover_path, Files.read(output .. "/fixture.png"))
        comic_value.extra = { cached_cover_identity = source.identity, cached_cover_url = source.url }
        self.app.account.store:upsertComic(comic_value)
        return comic_value
    end
    function context:success(task)
        Files.write(task.request.temporary_path, Files.read(output .. "/fixture.png"))
        return { temporary_path = task.request.temporary_path, format = "png" }
    end
    contexts[#contexts + 1] = context
    ui:drain()
    return context
end

local c = fixture{ "101", "102", "103", "104" }
local cached = c:cache(comic("101", "https://i0.hdslb.com/cached.jpg"))
-- A nonfavorite cache is reusable without certifying that the first bookshelf was synced.
check("cover cache alone does not certify a first bookshelf", not c.app:getBookshelfSyncState().has_cache)
c.network.connected = false
local cache_observation
c.app:_cacheCover(cached, false, nil, function(value) cache_observation = value end)
check("offline cache hits are actual ready covers and do not dispatch", cache_observation.ready
    and cache_observation.status == "cached" and c.app.account.raw_runner.count == 0)
c.network.connected = true
local runner = c:begin()
runner:finish(assert(runner:find("library", "favorites")), { cached, comic("102"), comic("103", "https://unsupported.example/cover.jpg"),
    comic("104", "https://i0.hdslb.com/uncached.jpg"), comic("105", "https://i0.hdslb.com/hidden.jpg") })
local fetching = c.app:getBookshelfSyncState()
check("A6 library-phase counts come from received favorites before publication", fetching.phase == "library"
    and fetching.comics_count == 5 and fetching.covers_total == 0 and not fetching.has_cache and #c.callbacks == 0)
runner:finish(assert(runner:find("library", "history")), {})
local state = c.app:getBookshelfSyncState()
check("A6 exposes observed staged counts without partial first presentation", state.first_sync and state.syncing
    and not state.has_cache and state.phase == "covers" and state.comics_count == 5
    and state.covers_total == 4 and state.covers_ready == 1 and state.covers_settled == 3 and state.progress == 0.75
    and #c.callbacks == 0 and c.app.account.store:getSetting(Bookshelf.sync_key).presentation_ready == false)
local task = assert(runner:find("download_cover"))
check("A6 fetches only actual visible uncached official covers", runner.count == 3
    and task.request.url == "https://i0.hdslb.com/uncached.jpg@480w.jpg")
local result = c:success(task)
runner:finish(task, result)
state = c.app:getBookshelfSyncState()
check("A6 publishes once after every visible cover terminal result", state.has_cache and not state.syncing
    and state.phase == "ready" and state.covers_total == 4 and state.covers_ready == 2
    and state.covers_settled == 4 and state.progress == 1 and #c.callbacks == 1 and #c.callbacks[1].value == 5
    and c.app.account.store:getSetting(Bookshelf.sync_key).presentation_ready == true)
task.callback(result); c.ui:drain()
check("duplicate cover completion cannot increment observed counts", #c.callbacks == 1 and c.app:getBookshelfSyncState().covers_ready == 2)

c = fixture{ "201" }
runner = c:ingest{ comic("201", "https://i0.hdslb.com/failure.jpg") }
task = assert(runner:find("download_cover"))
runner:finish(task, nil, { kind = "image_http" })
state = c.app:getBookshelfSyncState()
check("failed covers settle A6 without inventing successful counts", state.has_cache and not state.syncing
    and state.covers_ready == 0 and state.covers_settled == 1 and state.covers_total == 1 and #c.callbacks == 1)
local before = runner.count
c.app:requestCover("201")
check("failed first presentation retains existing cover retry backoff", runner.count == before)

c = fixture{ "301" }
runner = c:ingest{ comic("301", "https://i0.hdslb.com/offline.jpg") }
task = assert(runner:find("download_cover"))
c.network.connected = false
check("queued cover cannot start after connectivity changes", runner:start(task) == false)
state = c.app:getBookshelfSyncState()
check("offline rejection finishes the staged first presentation", state.has_cache and state.offline
    and not state.syncing and state.covers_ready == 0 and state.covers_settled == 1 and #c.callbacks == 1)

c = fixture{ "401" }
runner = c:ingest{ comic("401", "https://i0.hdslb.com/suspended.jpg") }
task = assert(runner:find("download_cover"))
c.app:suspend(); c.ui:drain()
state = c.app:getBookshelfSyncState()
check("suspension settles visible preparation without a permanently pending A6", state.has_cache and not state.syncing
    and state.covers_ready == 0 and state.covers_settled == 1 and #c.callbacks == 1 and next(c.app.cover_requests) == nil)
task.callback(nil, { kind = "canceled" }); c.ui:drain()
check("suspended cover late callback cannot republish", #c.callbacks == 1 and c.app:getBookshelfSyncState().covers_settled == 1)

c = fixture{ "501" }
runner = c:begin()
c.app:suspend(); c.ui:drain()
state = c.app:getBookshelfSyncState()
check("suspension cancels incomplete library collection instead of publishing partial favorites", not state.syncing
    and not state.has_cache and #c.callbacks == 1 and c.callbacks[1].error.kind == "canceled"
    and #c.app.account.store:listComics("favorites") == 0 and runner:find("library") == nil)

c = fixture{ "601" }
runner = c:ingest{ comic("601", "https://i0.hdslb.com/timeout.jpg") }
task = assert(runner:find("download_cover"))
local request = assert(c.app.cover_requests["601"])
check("A6 cover queueing has a finite preparation deadline", c.ui.timers[request.timeout] == c.app:getSetting("worker_timeout", 90) + 5)
request.timeout(); c.ui:drain()
state = c.app:getBookshelfSyncState()
check("a missing worker callback cannot leave A6 indefinitely pending", state.has_cache and not state.syncing
    and state.covers_settled == 1 and state.covers_ready == 0 and #c.callbacks == 1 and next(c.app.cover_requests) == nil)

c = fixture{ "701" }
runner = c:ingest{ comic("701", "https://i0.hdslb.com/account.jpg") }
task = assert(runner:find("download_cover"))
local observed = {}
c.app:_cacheCover(c.app.account.store:getComic("701"), false, nil, function(value, err) observed[#observed + 1] = { value = value, error = err } end)
check("concurrent visible observers share one existing worker", runner.count == 3)
local previous = c.app.account
c.retired[#c.retired + 1] = previous
c.app:_openAccount("bili_43", nil); c.ui:drain()
check("an account switch retires cover observers but suppresses obsolete bookshelf callbacks", #observed == 1
    and observed[1].value.status == "canceled" and observed[1].error.kind == "account_mismatch"
    and #c.callbacks == 0 and not c.app:getBookshelfSyncState().has_cache and next(c.app.cover_requests) == nil)
task.callback(nil, { kind = "canceled" }); c.ui:drain()
check("late retired cover workers cannot update a new account", #observed == 1 and c.app:getComic("701") == nil)

c = fixture{ "801" }
runner = c:ingest{ comic("801", "https://i0.hdslb.com/original.jpg") }
task = assert(runner:find("download_cover"))
c.app.account.store:upsertComic(comic("801", "https://i0.hdslb.com/replaced.jpg"))
runner:finish(task, c:success(task))
local replacement = assert(runner:find("download_cover"))
check("changed cover sources keep A6 pending for the current visible source", c.app:getBookshelfSyncState().syncing
    and not c.app:getBookshelfSyncState().has_cache and #c.callbacks == 0
    and replacement.request.url == "https://i0.hdslb.com/replaced.jpg@480w.jpg")
runner:finish(replacement, c:success(replacement))
check("changed cover source observers settle once with the final cache", #c.callbacks == 1
    and c.app:getBookshelfSyncState().covers_ready == 1 and c.app:getBookshelfSyncState().covers_settled == 1)

local account = c.app.account
account.store:upsertEpisodes("801", { { id = "8011", order = 1, access = "free", extra = { current_revision = "current" } },
    { id = "8012", order = 2, access = "free" } })
local function stored(revision, count, ready_count)
    local descriptor = { schema_version = 1, account_key = account.key, comic_id = "801", episode_id = "8011",
        revision = revision, pages = {} }
    for index = 1, count do descriptor.pages[index] = { id = "page-" .. index, index = index, width = 20, height = 40 } end
    account.pages:ensureDescriptor(descriptor)
    local total = 0
    for index = 1, ready_count do
        local page = account.store:getPage("8011/" .. revision .. "/" .. index)
        page.path = account.pages.pages_root .. "/" .. revision .. "-" .. index .. ".png"
        Files.write(page.path, Files.read(output .. "/fixture.png"))
        page.bytes, page.state = Files.size(page.path), "ready"
        total = total + page.bytes
        account.store:putPage(page)
    end
    return total
end
local current_bytes, older_bytes = stored("current", 4, 2), stored("older", 1, 1)
local estimate = c.app:getDownloadEstimate("801", { "8011" })
check("D2 controller exposes observed current-revision extrapolation", estimate.bytes == current_bytes * 2
    and estimate.estimated and estimate.known_chapters == 1 and estimate.total_chapters == 1)
estimate = c.app:getDownloadEstimate("801", { "8011", "8012" })
check("D2 controller leaves incomplete selection size unknown", estimate.bytes == nil and estimate.known_bytes == current_bytes * 2
    and estimate.known_chapters == 1 and estimate.total_chapters == 2)
account.store:putJob{ id = "current-copy", kind = "episode_download", state = "paused", episode_id = "8011",
    comic_id = "801", revision = "current", completed = 2, total = 4 }
account.store:putJob{ id = "older-copy", kind = "episode_download", state = "complete", episode_id = "8011",
    comic_id = "801", revision = "older", completed = 1, total = 1, payload = { replaced_by = "current-copy" } }
account.store:putJob{ id = "unknown-copy", kind = "episode_download", state = "paused", episode_id = "8012",
    comic_id = "801", revision = "absent", completed = 0, total = 4 }
local before_jobs = Codec.canonical(account.store:listJobs())
local displayed = {}
for _, job in ipairs(c.app:getDownloads()) do displayed[job.id] = job end
check("F1 F2 F3 storage bytes belong to the displayed copy revision", displayed["current-copy"].bytes == current_bytes
    and displayed["older-copy"].bytes == older_bytes and displayed["unknown-copy"].bytes == nil)
check("download size enrichment is read-only", Codec.canonical(account.store:listJobs()) == before_jobs)

c = fixture{ "901" }
runner = c:ingest{ comic("901", "https://i0.hdslb.com/storage-failure.jpg") }
task = assert(runner:find("download_cover"))
local original_upsert = c.app.account.store.upsertComic
c.app.account.store.upsertComic = function() error("Injected cover metadata persistence failure") end
runner:finish(task, c:success(task))
c.app.account.store.upsertComic = original_upsert
state = c.app:getBookshelfSyncState()
check("cover persistence failures settle A6 without reporting an unavailable thumbnail as ready", state.has_cache and not state.syncing
    and state.covers_ready == 0 and state.covers_settled == 1 and #c.callbacks == 1
    and not c.app.account.store:getComic("901").cover_path and next(c.app.cover_requests) == nil)

for _, mutation in ipairs{ "filter", "sort", "local resume", "favorite" } do
    c = fixture(function(app, items)
        return Screens.getInitialBookshelfCoverIDs({ controller = app }, items)
    end)
    local library = {}
    for index = 1, 25 do
        library[index] = comic(tostring(10000 + index), "https://i0.hdslb.com/view-" .. mutation:gsub(" ", "-") .. "-" .. index .. ".jpg")
        library[index].title = string.format("Synthetic %02d", 100 - index)
        library[index].extra = { has_update = index % 2 == 0 }
    end
    runner = c:ingest(library)
    local initial = c.app.screens:getInitialBookshelfCoverIDs(c.app:getBookshelfItems())
    local initial_workers = {}
    for _, pending_task in pairs(runner.tasks) do
        if pending_task.request.kind == "download_cover" then initial_workers[#initial_workers + 1] = pending_task end
    end
    check("the real responsive selector queues actual initial visible covers for " .. mutation,
        #initial_workers == #initial and #initial > 0 and #initial < #library)
    if mutation == "filter" then
        assert(c.app:saveBookshelfViewState{ filter = "updated" })
    elseif mutation == "sort" then
        assert(c.app:saveBookshelfViewState{ sort = "title", order_ids = {} })
    elseif mutation == "local resume" then
        local hidden_id = library[#library].id
        local episode_id = "20025"
        c.app.account.store:upsertEpisodes(hidden_id, { { id = episode_id, order = 1, access = "free", title = "Resume chapter" } })
        local descriptor = { schema_version = 1, account_key = c.app.account.key, comic_id = hidden_id, episode_id = episode_id,
            revision = "local-resume", pages = { { id = "resume-page", index = 1, width = 20, height = 40 } } }
        c.app.account.pages:ensureDescriptor(descriptor)
        c.app.account.catalog:updatePosition(descriptor, { index = 1, page_id = "resume-page", x = 0, y = 0.1, finished = false })
    else
        c.app:setFavorite(initial[1], false, function(value, err) assert(value, err and err.kind) end)
        local change = assert(runner:find("set_favorite"))
        runner:finish(change, { accepted = true, comic_id = initial[1], favorite = false })
    end
    local changed = c.app.screens:getInitialBookshelfCoverIDs(c.app:getBookshelfItems())
    check("persisted " .. mutation .. " changes the real first presentation selection", table.concat(initial, ",") ~= table.concat(changed, ","))
    for _, pending_task in ipairs(initial_workers) do runner:finish(pending_task, c:success(pending_task)) end
    state = c.app:getBookshelfSyncState()
    check("A6 revalidates " .. mutation .. " before publishing the first grid", state.syncing and not state.has_cache
        and #c.callbacks == 0 and state.covers_total == #changed and runner:find("download_cover") ~= nil)
    local remaining = 100
    while runner:find("download_cover") do
        remaining = remaining - 1; assert(remaining > 0, "Unbounded revalidated cover work")
        local pending_task = runner:find("download_cover")
        runner:finish(pending_task, c:success(pending_task))
    end
    state = c.app:getBookshelfSyncState()
    check("the fresh " .. mutation .. " first grid publishes once after its visible covers settle",
        state.has_cache and not state.syncing and #c.callbacks == 1 and state.covers_ready == #changed
        and state.covers_settled == #changed and state.covers_total == #changed)
end

local cutoff_ids = { "30001" }
c = fixture(cutoff_ids)
runner = c:ingest{ comic("30001", "https://i0.hdslb.com/deadline-old.jpg"), comic("30002", "https://i0.hdslb.com/deadline-new.jpg") }
local staged = assert(c.app.account.bookshelf_sync)
check("first preparation retains one overall deadline across changing views", staged.preparation_deadline == c.now + c.app:getSetting("worker_timeout", 90) + 5
    and c.ui.timers[staged.preparation_timeout] == c.app:getSetting("worker_timeout", 90) + 5)
cutoff_ids[1], c.now = "30002", staged.preparation_deadline
staged.preparation_timeout(); c.ui:drain()
state = c.app:getBookshelfSyncState()
check("the overall deadline settles the fresh visible selection without new requests or invented readiness",
    state.has_cache and not state.syncing and state.covers_total == 1 and state.covers_ready == 0
    and state.covers_settled == 1 and #c.callbacks == 1 and runner.count == 3 and next(c.app.cover_requests) == nil
    and c.ui.timers[staged.preparation_timeout] == nil)

account = c.app.account
account.store:upsertEpisodes("30001", {
    { id = "300011", order = 1, access = "free", extra = { current_revision = "new-32", local_revision = "new-32",
        source_replacement_revision = "new-32" } },
    { id = "300012", order = 2, access = "free", image_count = 32 },
})
local function replacementDescriptor(episode_id, revision, count)
    local descriptor = { schema_version = 1, account_key = account.key, comic_id = "30001", episode_id = episode_id,
        revision = revision, pages = {} }
    for index = 1, count do descriptor.pages[index] = { id = "replacement-page-" .. index, index = index, width = 20, height = 40 } end
    account.pages:ensureDescriptor(descriptor)
    local page = account.store:getPage(episode_id .. "/" .. revision .. "/1")
    page.path = account.pages.pages_root .. "/" .. revision .. "-metadata.png"
    Files.write(page.path, Files.read(output .. "/fixture.png"))
    page.bytes, page.state = Files.size(page.path), "ready"
    account.store:putPage(page)
    return page.bytes
end
replacementDescriptor("300011", "old-24", 24)
local replacement_bytes = replacementDescriptor("300011", "new-32", 32)
account.store:putJob{ id = "metadata-old-copy", kind = "episode_download", state = "paused", episode_id = "300011",
    comic_id = "30001", revision = "old-24", completed = 1, total = 24, payload = { replaced_by = "metadata-new-copy" } }
estimate = c.app:getDownloadEstimate("30001", { "300011" })
local metadata = estimate.descriptors["300011"]
check("F2 current descriptor metadata uses the new 32-page revision instead of the retained 24-page job",
    metadata and metadata.revision == "new-32" and metadata.total_pages == 32
    and metadata.bytes == replacement_bytes * 32 and metadata.estimated == true and estimate.bytes == metadata.bytes)
estimate = c.app:getDownloadEstimate("30001", { "300012" })
check("F2 declared-page size estimates do not fabricate validated descriptor metadata",
    estimate.bytes == replacement_bytes * 32 and estimate.estimated and estimate.descriptors["300012"] == nil)
local changed_episode = account.store:getEpisode("300011")
changed_episode.extra.source_replacement_revision = "unavailable-new-source"
account.store:upsertEpisodes("30001", { changed_episode })
estimate = c.app:getDownloadEstimate("30001", { "300011" })
check("F2 changed source markers cannot revive the preceding validated descriptor count or size",
    estimate.bytes == nil and estimate.descriptors["300011"] == nil and estimate.known_chapters == 0)

for _, context in ipairs(contexts) do
    context.app:close()
    for _, account in ipairs(context.retired) do account.store:close() end
end
Files.write(output .. "/ui-preparation-result.json", json.encode({ passed = true, count = #tests, assertions = tests }, { pretty = true }))
print(json.encode({ passed = true, count = #tests }))
