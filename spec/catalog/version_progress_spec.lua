-- Run only on test-env with synthetic records and real SQLite.
require("setupkoenv")
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. package.path
local Catalog = require("bilicomics/catalog/init")
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Codec = require("bilicomics/storage/codec")
local Files = require("bilicomics/storage/files")
local JSON = require("bilicomics/protocol/json")
local contexts, passed, sequence = {}, {}, 0

local function anchor(index, finished, time)
    return {schema_version = 1, page_id = "page-" .. index, index = index,
        x = 0.1, y = 0.2, mode = "continuous", finished = finished, updated_at = time}
end
local function descriptor(c, revision, episode_id)
    local value = {schema_version = 1, account_key = "synthetic-account", comic_id = "81",
        episode_id = episode_id or "101", revision = revision, pages = {}}
    for index = 1, 2 do value.pages[index] = {id = "page-" .. index, index = index, width = 20, height = 40} end
    return value, c.pages:ensureDescriptor(value)
end
local function fixture(seed_progress)
    sequence = sequence + 1
    local c = {root = output .. "/account-" .. sequence, now = 1000}
    c.store = Store.open({root = c.root, account_key = "synthetic-account", wal = false})
    c.pages = PageStore.new({root = c.root, account_key = "synthetic-account", store = c.store})
    c.catalog = Catalog.new({store = c.store, pages = c.pages, clock = function() return c.now end})
    c.catalog:ingestDetail({comic = {id = "81", title = "Synthetic comic"}, episodes = {
        {id = "101", comic_id = "81", order = 1, access = "free", title = "First"},
        {id = "102", comic_id = "81", order = 2, access = "owned", title = "Second"},
    }})
    c.old, c.old_path = descriptor(c, "old")
    c.new, c.new_path = descriptor(c, "replacement")
    if seed_progress ~= false then c.catalog:updatePosition(c.old, anchor(2, true, 1000)) end
    contexts[#contexts + 1] = c
    return c
end
local function markReplacement(c)
    local episode = c.store:getEpisode("101")
    episode.extra = episode.extra or {}
    episode.extra.current_revision, episode.extra.local_revision = "replacement", "replacement"
    episode.extra.source_replacement_revision, episode.extra.progress_source = "replacement", "local"
    episode.extra.local_finished_at, episode.read = nil, false
    c.store:upsertEpisodes("81", {episode})
end
local function persistedProgress(c)
    return Codec.canonical({episode = c.store:getEpisode("101"), comic = c.store:getComic("81")})
end
local function test(name, fn)
    local ok, failure = xpcall(fn, debug.traceback)
    for _, c in ipairs(contexts) do if c.store.connection then c.store:close() end end
    contexts = {}
    assert(ok, name .. ": " .. tostring(failure))
    passed[#passed + 1] = name
    print("PASS " .. name)
end

test("A new snapshot is unread without copying an older anchor or comic position", function()
    local c = fixture()
    local old_anchor, old_bytes = Codec.canonical(c.store:getAnchor("101", "old")), Files.read(c.old_path)
    markReplacement(c)
    local chapter, comic = c.catalog:getEpisodes("81")[1], c.catalog:getComic("81")
    assert(chapter.read == false and comic.reading_position == nil and comic.extra.reading_position == nil)
    assert(c.catalog:getDescriptor("101").revision == "replacement" and c.old_path ~= c.new_path)
    assert(c.store:getAnchor("101", "replacement") == nil)
    assert(Codec.canonical(c.store:getAnchor("101", "old")) == old_anchor and Files.read(c.old_path) == old_bytes)
end)

test("Direct Store writes from an old native reader do not change global progress", function()
    local c = fixture()
    markReplacement(c)
    local before = persistedProgress(c)
    c.store:putAnchor("101", "old", anchor(1, false, 9000))
    assert(persistedProgress(c) == before and c.store:getAnchor("101", "old").index == 1)
    assert(c.catalog:getEpisodes("81")[1].read == false and c.catalog:getComic("81").reading_position == nil)
end)

test("Catalog writes for an old descriptor only update that version's anchor", function()
    local c = fixture()
    markReplacement(c)
    local before = persistedProgress(c)
    c.now = 7000
    c.catalog:updatePosition(c.old, anchor(1, false))
    assert(persistedProgress(c) == before)
    local saved = c.store:getAnchor("101", "old")
    assert(saved.index == 1 and saved.updated_at == 7000 and saved.finished == false)
    assert(c.store:getAnchor("101", "replacement") == nil)
end)

test("The current snapshot progresses normally and ignores a newer old-version timestamp", function()
    local c = fixture()
    markReplacement(c)
    c.now = 2000
    c.catalog:updatePosition(c.new, anchor(1, false))
    local before = persistedProgress(c)
    c.store:putAnchor("101", "old", anchor(2, true, 9999))
    assert(persistedProgress(c) == before)
    local comic = c.catalog:getComic("81")
    assert(comic.reading_position.revision == "replacement" and comic.reading_position.index == 1)
    assert(c.catalog:getEpisodes("81")[1].read == "reading")
    c.now = 3000
    c.catalog:updatePosition(c.new, anchor(2, true))
    assert(c.catalog:getEpisodes("81")[1].read == "complete")
    assert(c.store:getEpisode("101").extra.local_revision == "replacement")
end)

test("Current direct Store writes still publish progress", function()
    local c = fixture()
    markReplacement(c)
    c.store:putAnchor("101", "replacement", anchor(1, false, 4000))
    assert(c.store:getEpisode("101").read == "in_progress" and c.store:getComic("81").last_read_at == 4000)
    assert(c.catalog:getComic("81").reading_position.revision == "replacement")
end)

test("Explicit anchor-only Store writes work without a replacement marker", function()
    local c = fixture(false)
    local before = persistedProgress(c)
    c.store:putAnchor("101", "old", anchor(1, true, 5000), {update_progress = false})
    assert(persistedProgress(c) == before and c.store:getAnchor("101", "old").finished)
    c.store:putAnchor("101", "old", anchor(1, false, 6000))
    assert(c.store:getEpisode("101").read == "in_progress" and c.store:getComic("81").last_read_at == 6000)
end)

test("Detail and display ignore old completion values for an unstarted replacement", function()
    local c = fixture()
    markReplacement(c)
    for _, stale in ipairs({true, "finished", "complete", "reading", "in_progress"}) do
        local episode = c.store:getEpisode("101")
        episode.read = stale
        c.store:upsertEpisodes("81", {episode})
        assert(c.catalog:getEpisodes("81")[1].read == false)
    end
    c.catalog:ingestDetail({comic = {id = "81", title = "Updated metadata"}, episodes = {
        {id = "101", comic_id = "81", order = 1, access = "free", read = true,
            extra = {source_replacement_revision = "remote-value", current_revision = "old"}},
    }})
    local saved = c.store:getEpisode("101")
    assert(saved.read == false and saved.extra.source_replacement_revision == "replacement")
    assert(saved.extra.current_revision == "replacement" and c.store:getAnchor("101", "old"))
end)

test("A cached comic position cannot bypass missing current-version anchor evidence", function()
    local c = fixture(false)
    c.store:putAnchor("101", "old", anchor(2, true, 5000), {update_progress = false})
    c.store:upsertComic({id = "81", reading_position = {episode_id = "101", revision = "old", index = 2},
        extra = {progress_source = "local", reading_position = {episode_id = "101", revision = "old", index = 2}}})
    markReplacement(c)
    local comic = c.catalog:getComic("81")
    assert(comic.reading_position == nil and comic.extra.reading_position == nil)
end)

test("Server history cannot revive an older continuation hint for a marked unstarted snapshot", function()
    local c = fixture()
    markReplacement(c)
    c.catalog:ingestLibrary("history", {{id = "81", title = "Refreshed title", current_episode_id = "102",
        last_read_at = 9000, extra = {last_read_ep_id = "102", last_read_time = 9000}}})
    local comic = c.catalog:getComic("81")
    assert(comic.current_episode_id == "101" and comic.reading_position == nil)
    assert(c.catalog:getEpisodes("81")[1].read == false)
end)

test("Progress for another chapter remains available", function()
    local c = fixture()
    local other = descriptor(c, "other-version", "102")
    c.now = 2000
    c.catalog:updatePosition(other, anchor(1, false))
    markReplacement(c)
    local comic = c.catalog:getComic("81")
    assert(comic.reading_position.episode_id == "102" and comic.reading_position.revision == "other-version")
    assert(c.catalog:getEpisodes("81")[1].read == false)
end)

test("Retired removed and unbound jobs cannot replace the current version's badge", function()
    local c = fixture()
    markReplacement(c)
    for _, job in ipairs({
        {id = "new-job", revision = "replacement", state = "running", updated_at = 100},
        {id = "old-job", revision = "old", state = "failed", updated_at = 900, payload = {replaced_by = "new-job"}},
        {id = "removed-job", revision = "replacement", state = "paused", updated_at = 1000, payload = {removed = true}},
        {id = "unbound-job", state = "failed", updated_at = 1100},
    }) do
        job.kind, job.comic_id, job.episode_id = "episode_download", "81", "101"
        c.store:putJob(job)
    end
    assert(c.catalog:getEpisodes("81")[1].download_state == "running")
    assert(#c.store:listJobs() == 4)
end)

test("Unmarked legacy anchors retain their previous selection behavior", function()
    local c = fixture()
    c.store:putAnchor("101", "replacement", anchor(1, false, 2000))
    assert(c.catalog:getComic("81").reading_position.revision == "replacement")
    c.now = 3000
    c.catalog:updatePosition(c.old, anchor(2, true))
    assert(c.catalog:getComic("81").reading_position.revision == "old")
end)

test("Version isolation survives a real database close and reopen", function()
    local c = fixture()
    markReplacement(c)
    c.now = 2000
    c.catalog:updatePosition(c.new, anchor(1, false))
    c.store:putAnchor("101", "old", anchor(2, true, 9999))
    c.store:close()
    c.store = Store.open({root = c.root, account_key = "synthetic-account", wal = false})
    c.pages = PageStore.new({root = c.root, account_key = "synthetic-account", store = c.store})
    c.catalog = Catalog.new({store = c.store, pages = c.pages, clock = function() return 3000 end})
    assert(c.catalog:getEpisodes("81")[1].read == "reading")
    assert(c.catalog:getComic("81").reading_position.revision == "replacement")
    assert(c.store:getAnchor("101", "old").updated_at == 9999)
    assert(c.store:getAnchor("101", "replacement").updated_at == 2000)
end)

local file = assert(io.open(output .. "/version_progress_result.json", "wb"))
assert(file:write(assert(JSON.encode({passed = #passed, cases = passed,
    scope = "Synthetic version progress isolation with real SQLite; no network, session, or payment operations"}))))
assert(file:close())
