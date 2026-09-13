-- Run only on test-env with the official KOReader runtime and real SQLite.
require("setupkoenv")
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. package.path
local Catalog = require("bilicomics/catalog/init")
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local tests, contexts, sequence = {}, {}, 0
local function check(condition, message) assert(condition, message) end

local function fixture()
    sequence = sequence + 1
    local root = output .. "/catalog-account-" .. sequence
    local store = Store.open({ root = root, account_key = "account-a", wal = false })
    local pages = PageStore.new({ root = root, account_key = "account-a", store = store })
    pages.isComplete = function() error("UI aggregation must not read image files") end
    pages.getPage = function() error("UI aggregation must only read stored page metadata") end
    local context = { store = store, pages = pages, now = 1000 }
    context.catalog = Catalog.new({ store = store, pages = pages, clock = function() return context.now end })
    contexts[#contexts + 1] = context
    return context
end

local function detail(c, episodes, comic)
    return c.catalog:ingestDetail({ comic = comic or { id = "comic", title = "A story", latest_episode_id = "episode-2" },
        episodes = episodes or {
            { id = "episode-1", comic_id = "comic", order = 1, title = "First chapter", access = "owned" },
            { id = "episode-2", comic_id = "comic", order = 2, title = "Second chapter", access = "free" },
        } })
end

local function descriptor(c, episode_id, revision, count)
    local value = { schema_version = 1, account_key = "account-a", comic_id = "comic",
        episode_id = episode_id or "episode-1", revision = revision or "revision-1", pages = {} }
    for index = 1, count or 2 do
        value.pages[index] = { id = "image-" .. index, index = index, width = 40, height = 80 }
    end
    local path = c.pages:ensureDescriptor(value)
    return value, path
end

local function markReady(c, value, index)
    local page = c.store:getPage(value.episode_id .. "/" .. value.revision .. "/" .. index)
    page.state, page.path = "ready", "/synthetic/metadata-only.png"
    c.store:putPage(page)
end

local function anchor(index, finished)
    return { schema_version = 1, index = index, page_id = "image-" .. index,
        x = 0.25, y = 0.6, source = { x = 0.2, y = 0.5 }, mode = "continuous", finished = finished }
end

local function test(name, fn)
    local ok, failure = xpcall(fn, debug.traceback)
    for _, context in ipairs(contexts) do
        if context.store.connection then pcall(context.store.close, context.store) end
    end
    contexts = {}
    tests[#tests + 1] = { name = name, passed = ok, error = not ok and failure or nil }
    io.stdout:write((ok and "PASS " or "FAIL ") .. name .. "\n")
    if not ok then io.stdout:write(failure .. "\n") end
end

test("Favorite snapshots remove stale membership while retaining local records and progress", function()
    local c = fixture()
    detail(c)
    c.catalog:ingestLibrary("favorites", { { id = "comic", title = "A story" }, { id = "old", title = "Old favorite" } })
    local value = descriptor(c)
    c.catalog:updatePosition(value, anchor(2))
    c.catalog:ingestLibrary("favorites", { { id = "old", title = "Renamed favorite" } })
    local saved = c.catalog:getComic("comic")
    check(saved.favorite == false and saved.current_episode_id == "episode-1" and saved.reading_position.index == 2,
        "Removing a favorite must preserve the precise native bookmark")
    check(#c.catalog:getLibrary("favorites") == 1 and #c.catalog:getLibrary("history") == 1,
        "Favorite and continuation membership must remain independent")
    c.catalog:ingestLibrary("favorites", {})
    check(#c.catalog:getLibrary("favorites") == 0 and c.store:getComic("old"), "An empty snapshot clears membership only")
end)

test("Server history never replaces a local source anchor or current episode", function()
    local c = fixture()
    detail(c)
    local value = descriptor(c)
    c.catalog:updatePosition(value, anchor(2))
    c.catalog:ingestLibrary("history", { { id = "comic", title = "Refreshed story", last_read_at = 5000,
        current_episode_id = "episode-2", reading_position = { index = 99 },
        extra = { last_read_ep_id = "episode-2", reading_position = { index = 99 } } } })
    local saved = c.catalog:getComic("comic")
    local exact = c.store:getAnchor("episode-1", "revision-1")
    check(saved.current_episode_id == "episode-1" and saved.last_read_at == 1000 and saved.reading_position.page == 2,
        "Even newer server timestamps cannot claim a more precise native position")
    check(exact.source.x == 0.2 and exact.y == 0.6 and saved.title == "Refreshed story", "Metadata may refresh independently of anchors")
end)

test("Existing Store.putAnchor progress overrides an earlier server current episode hint", function()
    local c = fixture()
    detail(c)
    c.catalog:ingestLibrary("history", { { id = "comic", title = "A story", current_episode_id = "episode-2", last_read_at = 500 } })
    local value = descriptor(c)
    local saved_anchor = anchor(1)
    saved_anchor.updated_at = 600
    c.store:putAnchor(value.episode_id, value.revision, saved_anchor)
    c.catalog:ingestLibrary("history", { { id = "comic", title = "A story", current_episode_id = "episode-2", last_read_at = 9999 } })
    local saved = c.catalog:getComic("comic")
    check(saved.current_episode_id == "episode-1" and saved.reading_position.index == 1 and saved.last_read_at == 600,
        "The Store observer gap must not let an old current_episode_id hide newer native progress")
end)

test("Remote chapter history is useful without inventing a precise page position", function()
    local c = fixture()
    c.catalog:ingestLibrary("history", {
        { id = "comic", title = "Server chapter", extra = { last_read_ep_id = 9, last_read_time = 700000,
            page = 7, index = 7, reading_position = { index = 7 } } },
        { id = "unknown", title = "History without chapter identity", extra = { latest_ep_id = 99, last_ord = 10 } },
    })
    local saved = c.catalog:getComic("comic")
    check(saved.current_episode_id == "9" and saved.last_read_at == 700000 and saved.reading_position == nil,
        "Remote history may establish chapter identity and ordering, never a native anchor")
    check(c.catalog:getComic("unknown").current_episode_id == nil and #c.catalog:getLibrary("history") == 2,
        "Latest publication information must not be mistaken for reading progress")
end)

test("Detail refresh preserves local revision and source identity while removing acquisition secrets", function()
    local c = fixture()
    detail(c)
    c.store:upsertEpisodes("comic", { { id = "episode-1", order = 1, extra = {
        current_revision = "trusted-revision", local_revision = "local-revision", source_identity = "trusted-source",
        local_note = "Keep this", public_metadata = { existing = true },
    } } })
    detail(c, { { id = "episode-1", order = 1, title = "Updated chapter", access = "owned", extra = {
        current_revision = "remote-revision", local_revision = "remote-local", source_identity = "remote-source",
        public_metadata = { updated = true }, Cookie = "secret", access_token = "secret",
        nested = { signed_url = "https://example.invalid/image?sign=secret", ordinary_url = "https://example.invalid/?key=secret",
            relative_url = "//example.invalid/image?signature=secret", path = "/image?token=secret",
            relative_path = "images/page?token=secret", signature = "secret" },
        url = "https://example.invalid/image?signature=secret",
    } } })
    local saved = c.store:getEpisode("episode-1")
    check(saved.extra.current_revision == "trusted-revision" and saved.extra.local_revision == "local-revision"
        and saved.extra.source_identity == "trusted-source" and saved.extra.local_note == "Keep this", "Local identity must survive metadata refresh")
    check(saved.extra.public_metadata.existing and saved.extra.public_metadata.updated and saved.extra.url == nil
        and saved.extra.Cookie == nil and saved.extra.access_token == nil and next(saved.extra.nested) == nil,
        "Public metadata must merge without persisting credentials or signed URLs")
end)

test("Temporary access expires when displayed and never becomes a permanent offline download", function()
    local c = fixture()
    detail(c, { { id = "episode-1", order = 1, access = "temporary", expires_at = 1100, extra = { offline_allowed = true } } })
    local value = descriptor(c)
    markReady(c, value, 1)
    markReady(c, value, 2)
    local episode = c.catalog:getEpisodes("comic")[1]
    check(episode.access == "temporary" and episode.cached_pages == 2 and not episode.downloaded
        and episode.cached_complete and not episode.extra.offline_allowed and episode.download_state == "cached",
        "Temporary access must not advertise permanent retention")
    c.now = 1100
    check(c.catalog:getEpisodes("comic")[1].access == "locked", "Access must expire without another network refresh")
    detail(c, { { id = "episode-1", order = 1, access = "owned" } })
    local owned = c.catalog:getEpisodes("comic")[1]
    check(owned.offline_allowed and owned.cached_complete and not owned.downloaded
        and c.store:getEpisode("episode-1").expires_at == 0,
        "Explicit permanent ownership clears expiry without implicitly retaining automatic cache")
    c.pages:pinEpisode(value.episode_id, value.revision, true)
    check(c.catalog:getEpisodes("comic")[1].downloaded, "Permanent rights and explicit retention allow the downloaded label")
end)

test("Descriptor selection prefers explicit revision then newest download job before legacy fallback", function()
    local c = fixture()
    detail(c)
    local older, older_path = descriptor(c, "episode-1", "z-old")
    local newer = descriptor(c, "episode-1", "a-new")
    c.store:putJob({ id = "newer-job", kind = "episode_download", episode_id = "episode-1", comic_id = "comic",
        revision = newer.revision, state = "complete", updated_at = 1100 })
    c.store:putJob({ id = "older-job", kind = "episode_download", episode_id = "episode-1", comic_id = "comic",
        revision = older.revision, state = "complete", updated_at = 1000 })
    check(c.catalog:getDescriptor("episode-1").revision == "a-new", "Hash ordering must not override a newer job revision")
    c.store:upsertEpisodes("comic", { { id = "episode-1", order = 1, extra = { current_revision = older.revision } } })
    local selected, path = c.catalog:getDescriptor("episode-1")
    check(selected.revision == "z-old" and path == older_path, "The prepared current revision is authoritative")
    check(c.catalog:getDescriptor("missing") == nil, "Missing descriptor lookup must be harmless")
end)

test("Download status comes from matching page metadata rather than stale completion jobs", function()
    local c = fixture()
    detail(c)
    local value = descriptor(c)
    c.pages:pinEpisode(value.episode_id, value.revision, true)
    c.store:putJob({ id = "download", kind = "episode_download", episode_id = "episode-1", comic_id = "comic",
        revision = value.revision, state = "complete", total = 2, completed = 2, updated_at = 900 })
    markReady(c, value, 1)
    local episode = c.catalog:getEpisodes("comic")[1]
    check(not episode.downloaded and episode.download_state == "partial" and episode.cached_pages == 1 and episode.total_pages == 2,
        "A completed job cannot override missing pages")
    markReady(c, value, 2)
    check(c.catalog:getEpisodes("comic")[1].downloaded, "Complete matching metadata and explicit retention provide the downloaded label")
    c.store:updatePage("episode-1/revision-1/2", { id = "wrong-source" })
    check(not c.catalog:getEpisodes("comic")[1].downloaded, "A page from another source identity must not count")
    local job = c.store:getJob("download")
    job.state = "paused"
    c.store:putJob(job)
    check(c.catalog:getEpisodes("comic")[1].download_state == "paused", "Active job state explains incomplete downloads")
end)

test("Complete automatic cache remains distinct from an explicitly retained download", function()
    local c = fixture()
    detail(c)
    local value = descriptor(c)
    markReady(c, value, 1)
    markReady(c, value, 2)
    local episode = c.catalog:getEpisodes("comic")[1]
    check(episode.cached_complete and episode.extra.cached_complete and episode.cached_pages == 2 and episode.total_pages == 2,
        "The cache completeness axis must report all matching page metadata")
    check(not episode.downloaded and not episode.extra.downloaded and episode.download_state == "cached"
        and episode.extra.download_state == "cached" and episode.offline_allowed,
        "An unpinned complete cache cannot appear as a retained download or change access rights")
    c.store:putJob({ id = "stale-complete", kind = "episode_download", episode_id = value.episode_id, comic_id = "comic",
        revision = value.revision, state = "complete", total = 2, completed = 2, updated_at = 900 })
    check(c.catalog:getEpisodes("comic")[1].download_state == "cached", "A stale completed job cannot substitute for a durable pin")
    c.pages:pinEpisode(value.episode_id, value.revision, true)
    local retained = c.catalog:getEpisodes("comic")[1]
    check(retained.downloaded and retained.download_state == "complete" and retained.cached_complete,
        "Explicit retention promotes the complete cache to a downloaded chapter")
    c.pages:pinEpisode(value.episode_id, value.revision, false)
    local released = c.catalog:getEpisodes("comic")[1]
    check(not released.downloaded and released.download_state == "cached" and released.cached_complete,
        "Removing retention immediately restores the automatic cache label without changing the pages")
end)

test("Native progress supplies UI read state and survives reopening SQLite", function()
    local c = fixture()
    detail(c)
    local value = descriptor(c)
    c.catalog:updatePosition(value, anchor(2, true))
    check(c.catalog:getEpisodes("comic")[1].read == "complete", "Finished native anchors must map to the UI vocabulary")
    local root = c.store.root
    c.store:close()
    c.store = Store.open({ root = root, account_key = "account-a", wal = false })
    c.catalog = Catalog.new({ store = c.store, pages = c.pages, clock = function() return c.now end })
    local saved = c.catalog:getComic("comic")
    check(saved.current_episode_id == "episode-1" and saved.reading_position.source.x == 0.2
        and saved.latest_episode_title == "Second chapter" and saved.has_update, "Native progress and publication state must survive restart")
end)

test("Search keeps result order, membership, query filtering, and authoritative anchors independent", function()
    local c = fixture()
    c.catalog:ingestLibrary("favorites", { { id = "comic", title = "A story" } })
    local results = c.catalog:ingestSearch({ { id = "second", title = "B story" }, { id = "comic", title = "A renamed story", favorite = false } })
    check(results[1].id == "second" and results[2].favorite and #c.catalog:getLibrary("favorites", "RENAMED") == 1,
        "Search order must be stable and cannot silently remove favorite membership")
    check(#c.catalog:getLibrary("history") == 0, "Searching must not create reading history")
end)

test("Invalid detail and native identities roll back the entire local ingestion", function()
    local c = fixture()
    detail(c)
    local ok = pcall(c.catalog.ingestDetail, c.catalog, { comic = { id = "comic", title = "Uncommitted title" },
        episodes = { { id = "episode-1", comic_id = "other", order = 1, access = "owned" } } })
    check(not ok and c.catalog:getComic("comic").title == "A story", "Episode mismatch must roll back comic updates")
    local value = descriptor(c)
    value.account_key = "account-b"
    check(not pcall(c.catalog.updatePosition, c.catalog, value, anchor(1)), "A foreign account descriptor must not create an anchor")
    value.account_key = "account-a"
    check(not pcall(c.catalog.updatePosition, c.catalog, value, anchor(99)), "An unknown page identity must not create a misleading anchor")
    check(#c.catalog:getLibrary("history") == 0, "Rejected native position writes must leave history unchanged")
    c.catalog:updatePosition(value, anchor(2))
    local foreign = { schema_version = 1, account_key = "account-a", comic_id = "other",
        episode_id = value.episode_id, revision = "foreign-revision", pages = value.pages }
    c.pages:ensureDescriptor(foreign)
    local foreign_anchor = anchor(1)
    foreign_anchor.updated_at = 9999
    c.store:putAnchor(foreign.episode_id, foreign.revision, foreign_anchor)
    check(c.catalog:getComic("comic").reading_position.revision == value.revision,
        "A legacy descriptor assigned to another comic cannot replace the valid source anchor")
end)

local passed = true
for _, item in ipairs(tests) do passed = passed and item.passed end
Files.write(output .. "/catalog-result.json", json.encode({ host = "test-env", tests = tests, passed = passed }, { pretty = true }))
assert(passed, "One or more catalog contract tests failed")
