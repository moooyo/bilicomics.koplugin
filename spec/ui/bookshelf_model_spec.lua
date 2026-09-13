-- Run only on test-env with the official KOReader runtime and synthetic metadata.
require("setupkoenv")
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. package.path
require("gettext").current_lang = "C"
local Model = require("bilicomics/ui/model")
local Catalog = require("bilicomics/catalog/init")
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local tests, contexts, sequence = {}, {}, 0

local function test(name, callback)
    local ok, failure = xpcall(callback, debug.traceback)
    for _, context in ipairs(contexts) do pcall(context.store.close, context.store) end
    contexts = {}
    tests[#tests + 1] = { name = name, passed = ok, failure = not ok and tostring(failure) or nil }
end

local function localComic(anchor)
    return { id = "comic", current_episode_id = "one", reading_position = anchor,
        extra = { progress_source = "local" } }
end

local function chapter(overrides)
    local value = { id = "one", comic_id = "comic", title = "First chapter", short_title = "1",
        order = 1, total_pages = 45, extra = { current_revision = "version-a" } }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

test("Local chapter and page override a stale server chapter without using latest publication metadata", function()
    local comic = localComic({ episode_id = "one", revision = "version-a", index = 4, page = 9 })
    comic.current_episode_id, comic.latest_episode_title = "two", "New publication"
    local episodes = { chapter(), { id = "two", title = "Second chapter", total_pages = 80 } }
    local progress = Model.comicProgress(comic, episodes)
    assert(Model.currentEpisode(comic, episodes) == "one")
    assert(progress.episode_id == "one" and progress.current_episode == episodes[1])
    assert(progress.state == "reading" and progress.page == 4 and progress.total_pages == 45)
    assert(progress.label == "Read to: Chapter 1 · 4/45" and progress.chapter_finished == false)
    assert(Model.comicUpdate(comic) == "Latest: New publication")
end)

test("Remote chapter history never establishes a precise page even when raw input claims one", function()
    local progress = Model.comicProgress({ current_episode_id = "one", last_read_at = 900,
        reading_position = { episode_id = "one", page = 17 }, extra = { progress_source = "server" } }, { chapter() })
    assert(progress.state == "reading" and progress.current_episode.id == "one")
    assert(progress.page == nil and progress.total_pages == nil and progress.label == "Read to: Chapter 1")
end)

test("A position without local provenance cannot display a claimed page", function()
    local progress = Model.comicProgress({ current_episode_id = "one", reading_position = { index = 7 } }, { chapter() })
    assert(progress.label == "Read to: Chapter 1" and progress.page == nil)
end)

test("A favorite with no history is unknown even when its publication is complete", function()
    local comic = { id = "comic", favorite = true, finished = true, latest_episode_id = "one",
        latest_episode_title = "Publication finale", latest_order = 150 }
    local progress = Model.comicProgress(comic, { chapter({ read = false }) })
    assert(progress.state == "unknown" and progress.label == "No reading position")
    assert(progress.current_episode == nil and progress.chapter_finished == false)
    assert(Model.comicUpdate(comic) == "Latest: Publication finale")
end)

test("Completing a chapter keeps the comic in known reading history", function()
    local progress = Model.comicProgress(localComic({ episode_id = "one", revision = "version-a", index = 45,
        finished = true }), { chapter({ read = "complete" }), { id = "two", title = "Next chapter" } })
    assert(progress.state == "reading" and progress.chapter_finished == true)
    assert(progress.label == "Read to: Chapter 1 · 45/45")
end)

test("An incomplete local anchor wins over a stale complete chapter flag", function()
    for _, finished in ipairs({ false, "true" }) do
        local progress = Model.comicProgress(localComic({ episode_id = "one", revision = "version-a", page = 3,
            finished = finished }), { chapter({ read = "complete" }) })
        assert(progress.chapter_finished == false and progress.page == 3)
    end
    local progress = Model.comicProgress(localComic({ episode_id = "one", revision = "version-a", page = 3 }),
        { chapter({ read = "complete" }) })
    assert(progress.chapter_finished == false)
end)

test("Chapter completion from catalog metadata remains useful without a native anchor", function()
    for _, completed in ipairs({ true, "read", "complete", "finished" }) do
        local progress = Model.comicProgress({ current_episode_id = "one" }, { chapter({ read = completed }) })
        assert(progress.chapter_finished == true and progress.state == "reading" and progress.page == nil)
    end
end)

test("History without chapter identity is known history with an unavailable position", function()
    local progress = Model.comicProgress({ last_read_at = 2300000000, latest_episode_title = "Latest" }, {})
    assert(progress.state == "reading" and progress.label == "Reading position unavailable")
    assert(progress.episode_id == nil and progress.page == nil)
end)

test("A chapter ID without catalog metadata is not presented as a chapter number", function()
    local progress = Model.comicProgress({ current_episode_id = "823452" }, {})
    assert(progress.episode_id == "823452" and progress.label == "Reading position unavailable")
    assert(not progress.label:find("823452", 1, true))
end)

test("An empty catalog has an unknown reading state", function()
    local progress = Model.comicProgress(nil, nil)
    assert(progress.state == "unknown" and progress.label == "No reading position")
    assert(Model.currentEpisode({}, {}) == nil and Model.comicUpdate(nil) == nil)
end)

test("A catalog reading marker can identify a chapter without guessing from publication order", function()
    local episode = { id = "one", read = "in_progress", order = 1.5 }
    local progress = Model.comicProgress({ latest_order = 100 }, { items = { episode } })
    assert(progress.current_episode == episode and progress.label == "Read to: Chapter 1.5")
end)

test("Completed earlier chapters prove history without selecting an arbitrary continuation", function()
    local progress = Model.comicProgress({}, { chapter({ read = "complete" }), { id = "two", read = false } })
    assert(progress.state == "reading" and progress.episode_id == nil)
    assert(progress.label == "Reading position unavailable" and progress.chapter_finished == false)
end)

test("Invalid page values are omitted instead of being rounded or defaulted to page one", function()
    for _, page in ipairs({ 0, -1, 0.5, 1.5, math.huge, 0 / 0, 2147483648, "bad", false, {} }) do
        local progress = Model.comicProgress(localComic({ episode_id = "one", revision = "version-a", index = page }),
            { chapter() })
        assert(progress.page == nil and progress.total_pages == nil and progress.label == "Read to: Chapter 1")
    end
end)

test("Missing or invalid totals retain only the trustworthy page number", function()
    for _, total in ipairs({ 0, -10, 0.5, math.huge, 0 / 0, 2147483648, "bad", false, {} }) do
        local progress = Model.comicProgress(localComic({ episode_id = "one", revision = "version-a", index = 4 }),
            { chapter({ total_pages = total }) })
        assert(progress.page == 4 and progress.total_pages == nil and progress.label == "Read to: Chapter 1 · page 4")
    end
    local progress = Model.comicProgress(localComic({ episode_id = "one", page = 4 }), {})
    assert(progress.page == 4 and progress.total_pages == nil and progress.label == "Read to page 4")
end)

test("A page outside the known matching snapshot is not displayed as a valid ratio", function()
    local progress = Model.comicProgress(localComic({ episode_id = "one", revision = "version-a", index = 46 }), { chapter() })
    assert(progress.page == nil and progress.total_pages == nil and progress.label == "Read to: Chapter 1")
end)

test("A retained snapshot page never uses the current snapshot page total", function()
    local progress = Model.comicProgress(localComic({ episode_id = "one", revision = "older-version", index = 70 }), { chapter() })
    assert(progress.page == 70 and progress.total_pages == nil)
    assert(progress.label == "Read to: Chapter 1 · page 70")
end)

test("A missing snapshot identity keeps the page without claiming a matching total", function()
    local progress = Model.comicProgress(localComic({ episode_id = "one", page = 4 }), { chapter() })
    assert(progress.page == 4 and progress.total_pages == nil and progress.label == "Read to: Chapter 1 · page 4")
    progress = Model.comicProgress(localComic({ episode_id = "one", revision = "version-a", page = 4 }),
        { chapter({ extra = {} }) })
    assert(progress.page == 4 and progress.total_pages == nil)
end)

test("Legacy extra fields retain a precise local chapter and numeric page strings", function()
    local progress = Model.comicProgress({ extra = { progress_source = "local", current_episode_id = "two",
        reading_position = { episode_id = "one", revision = "version-a", page = "4" } } }, { chapter() })
    assert(progress.episode_id == "one" and progress.page == 4 and progress.total_pages == 45)
end)

test("An untitled chapter can show a local page without turning an identity into a title", function()
    local episode = { id = "one", total_pages = 45, extra = { current_revision = "version-a" } }
    local progress = Model.comicProgress(localComic({ episode_id = "one", revision = "version-a", index = 4 }), { episode })
    assert(progress.label == "Read to page 4/45" and progress.current_episode == episode)
end)

test("Publication-only labels remain independent from reading history", function()
    assert(Model.comicUpdate({ latest_order = 1166 }) == "Latest chapter: 1166")
    assert(Model.comicUpdate({ has_update = true }) == "New chapters")
    assert(Model.comicUpdate({ finished = true }) == "Completed")
    assert(Model.comicProgress({ finished = true }, {}).state == "unknown")
end)

local function fixture()
    sequence = sequence + 1
    local root = output .. "/bookshelf-model-account-" .. sequence
    local store = Store.open({ root = root, account_key = "synthetic", wal = false })
    local pages = PageStore.new({ root = root, account_key = "synthetic", store = store })
    local context = { store = store, pages = pages }
    context.catalog = Catalog.new({ store = store, pages = pages, clock = function() return 1000 end })
    contexts[#contexts + 1] = context
    return context
end

local function catalogDetail(context)
    context.catalog:ingestDetail({ comic = { id = "comic", title = "Synthetic comic", latest_episode_id = "two",
        latest_episode_title = "Latest chapter two", finished = false }, episodes = {
        { id = "one", comic_id = "comic", title = "Opening chapter", short_title = "1", order = 1, access = "free" },
        { id = "two", comic_id = "comic", title = "Latest chapter two", short_title = "2", order = 2, access = "free" },
    } })
end

test("Actual catalog favorites do not become unread and remote history stays chapter-only", function()
    local context = fixture()
    context.catalog:ingestLibrary("favorites", { { id = "comic", title = "Synthetic comic", finished = true } })
    catalogDetail(context)
    local comic, episodes = context.catalog:getComic("comic"), context.catalog:getEpisodes("comic")
    assert(Model.comicProgress(comic, episodes).state == "unknown")
    context.catalog:ingestLibrary("history", { { id = "comic", title = "Synthetic comic", extra = {
        last_read_ep_id = "one", last_read_time = 800, reading_position = { index = 17 }, page = 17,
    } } })
    comic, episodes = context.catalog:getComic("comic"), context.catalog:getEpisodes("comic")
    local progress = Model.comicProgress(comic, episodes)
    assert(progress.state == "reading" and progress.current_episode.id == "one")
    assert(progress.page == nil and progress.label == "Read to: Chapter 1")
    assert(Model.comicUpdate(comic) == "Latest: Latest chapter two")
end)

test("Actual catalog native progress survives a newer server hint and matches descriptor page count", function()
    local context = fixture()
    catalogDetail(context)
    local descriptor = { schema_version = 1, account_key = "synthetic", comic_id = "comic",
        episode_id = "one", revision = "native-version", pages = {} }
    for index = 1, 3 do
        descriptor.pages[index] = { id = "page-" .. index, index = index, width = 40, height = 80 }
    end
    context.pages:ensureDescriptor(descriptor)
    context.catalog:updatePosition(descriptor, { index = 2, page_id = "page-2", x = 0, y = 0.25, finished = false })
    context.catalog:ingestLibrary("history", { { id = "comic", title = "Refreshed title",
        current_episode_id = "two", last_read_at = 9999 } })
    local progress = Model.comicProgress(context.catalog:getComic("comic"), context.catalog:getEpisodes("comic"))
    assert(progress.episode_id == "one" and progress.page == 2 and progress.total_pages == 3)
    assert(progress.label == "Read to: Chapter 1 · 2/3" and progress.chapter_finished == false)
    context.catalog:updatePosition(descriptor, { index = 3, page_id = "page-3", x = 0, y = 1, finished = true })
    progress = Model.comicProgress(context.catalog:getComic("comic"), context.catalog:getEpisodes("comic"))
    assert(progress.state == "reading" and progress.chapter_finished == true and progress.page == 3)
end)

local passed = true
for _, item in ipairs(tests) do passed = passed and item.passed end
local result = { spec = "bookshelf-model", host = "test-env", read_only_metadata = true,
    synthetic_data = true, tests = tests, passed = passed }
Files.write(output .. "/bookshelf-model-result.json", json.encode(result, { pretty = true }))
print(json.encode({ spec = result.spec, passed = passed, tests = #tests }))
assert(passed, "One or more bookshelf model tests failed")
