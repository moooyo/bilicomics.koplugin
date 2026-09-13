-- Measure storage digests in production getters using real SQLite and PNG files.
-- The controller is assembled directly to exclude sessions, workers, and startup.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path

local Catalog = require("bilicomics/catalog/init")
local Controller = require("bilicomics/controller")
local Files = require("bilicomics/storage/files")
local PageStore = require("bilicomics/storage/page_store")
local Store = require("bilicomics/storage/store")
local json = require("rapidjson")
local now = require("socket").gettime
local fixtures = json.decode(Files.read(output .. "/fixtures.json"))
local root, key = output .. "/account", "anonymous"
Files.mkdir(root)
local store = Store.open{ root = root, account_key = key }
local pages = PageStore.new{ root = root, account_key = key, store = store }
local descriptors, comic_ids = {}, { "1", "2" }
local total_bytes = 0

for _, comic_id in ipairs(comic_ids) do
    store:upsertComic{ id = comic_id, title = "Synthetic comic " .. comic_id,
        favorite = true, last_read_at = 1700000000 + tonumber(comic_id) }
end
for number = 1, 4 do
    local comic_id, episode_id = tostring(math.ceil(number / 2)), tostring(100 + number)
    local descriptor = { schema_version = 1, account_key = key, comic_id = comic_id,
        episode_id = episode_id, revision = "synthetic-r1", pages = {} }
    for index = 1, 2 do
        local fixture = fixtures[(number - 1) * 2 + index]
        descriptor.pages[index] = { index = index, id = "image-" .. number .. "-" .. index,
            width = fixture.width, height = fixture.height }
    end
    store:upsertEpisodes(comic_id, { { id = episode_id, order = number, title = "Synthetic chapter " .. number,
        access = "free", extra = { current_revision = descriptor.revision } } })
    pages:ensureDescriptor(descriptor)
    for index = 1, 2 do
        local fixture = fixtures[(number - 1) * 2 + index]
        local temporary_path = pages.temporary_root .. "/image-" .. number .. "-" .. index .. ".part"
        assert(os.rename(output .. "/" .. fixture.path, temporary_path))
        local committed = pages:commitPage({ account_key = key, episode_id = episode_id,
            revision = descriptor.revision, index = index, id = descriptor.pages[index].id },
            { temporary_path = temporary_path, checksum = fixture.checksum,
                width = fixture.width, height = fixture.height, format = "png" })
        total_bytes = total_bytes + committed.bytes
    end
    pages:pinEpisode(episode_id, descriptor.revision, true)
    store:putJob{ id = "download-" .. number, kind = "episode_download", state = "complete",
        comic_id = comic_id, episode_id = episode_id, revision = descriptor.revision,
        total = 2, completed = 2, payload = {} }
    descriptors[#descriptors + 1] = descriptor
end
assert(total_bytes <= 64 * 1024 * 1024, "The synthetic cache exceeds the safety bound")

local ui = { queue = {} }
function ui:nextTick(callback) self.queue[#self.queue + 1] = callback end
function ui:drain()
    local count = 0
    while #self.queue > 0 do
        count = count + 1
        assert(count < 100, "Unbounded deferred work")
        table.remove(self.queue, 1)()
    end
end
local controller = setmetatable({ account = { key = key, store = store, pages = pages,
    catalog = Catalog.new{ store = store, pages = pages } }, generation = 1, ui_manager = ui }, Controller)

local original_digest, counters = Files.digest, nil
Files.digest = function(path)
    local digest, bytes = original_digest(path)
    if counters then
        counters.digest_calls = counters.digest_calls + 1
        counters.digest_bytes = counters.digest_bytes + bytes
    end
    return digest, bytes
end

local measurements = {}
local function measure(name, callback)
    -- Cold means the PageStore verification memo is empty, not a cold OS cache.
    pages.verified = {}
    local samples = {}
    for iteration = 1, 4 do
        collectgarbage("collect")
        counters = { digest_calls = 0, digest_bytes = 0 }
        local started = now()
        callback()
        local elapsed = now() - started
        samples[#samples + 1] = { iteration = iteration,
            phase = iteration == 1 and "first_empty_verification_memo" or "repeat",
            seconds = elapsed, digest_calls = counters.digest_calls, digest_bytes = counters.digest_bytes }
        counters = nil
    end
    measurements[#measurements + 1] = { name = name, samples = samples }
end

local function episodesGetter()
    for _, comic_id in ipairs(comic_ids) do
        local episodes = controller:getEpisodes(comic_id)
        assert(#episodes == 2 and episodes[1].downloaded and episodes[2].downloaded)
    end
end
local function libraryGetter()
    assert(#controller:getLibrary("history") == 2)
    assert(#controller:getLibrary("favorites") == 2)
end
local function storageGetter()
    local summary = controller:getStorageSummary()
    assert(summary.total_bytes == total_bytes and summary.ready_pages == 8)
end
local function downloadsGetter()
    local jobs = controller:getDownloads()
    assert(#jobs == 4)
    storageGetter()
    for _, job in ipairs(jobs) do
        assert(controller:getComic(job.comic_id))
        assert(controller:getEpisode(job.episode_id))
    end
end
measure("controller_getEpisodes_all_comics", episodesGetter)
measure("controller_getLibrary_history_and_favorites", libraryGetter)
measure("controller_getStorageSummary", storageGetter)
measure("downloads_route_getters_all_rows", downloadsGetter)
measure("notify_coalesced_library_getters", function()
    controller.screens = { refresh = function() libraryGetter(); episodesGetter() end }
    controller:_notify()
    controller:_notify()
    assert(#ui.queue == 1, "Notifications were not coalesced")
    ui:drain()
end)
measure("notify_coalesced_downloads_getters", function()
    controller.screens = { refresh = downloadsGetter }
    controller:_notify()
    controller:_notify()
    assert(#ui.queue == 1, "Notifications were not coalesced")
    ui:drain()
end)
measure("page_store_getPage_all_pages", function()
    for _, descriptor in ipairs(descriptors) do
        for index in ipairs(descriptor.pages) do
            assert(pages:getPage(descriptor.episode_id, descriptor.revision, index).state == "ready")
        end
    end
end)
measure("page_store_isComplete_all_episodes", function()
    for _, descriptor in ipairs(descriptors) do
        assert(pages:isComplete(descriptor.episode_id, descriptor.revision))
    end
end)
measure("page_store_getSummary", function()
    local summary = pages:getSummary()
    assert(summary.complete_episodes == 4 and summary.total_bytes == total_bytes)
end)
Files.digest = original_digest
store:close()
local result = { schema_version = 1, runtime = "official-unmodified-KOReader-v2026.07.1",
    source_plugin = plugin, cache_bytes = total_bytes, page_count = 8, episode_count = 4,
    comic_count = 2, image_format = "png", image_width = fixtures[1].width, image_height = fixtures[1].height,
    repetitions = 3, network_requests = 0, measurements = measurements,
    notes = { "Only getter and deferred notification time is measured; startup and seeding are excluded.",
        "Notifications invoke production getters through a screen proxy; native rendering is not measured.",
        "First resets the PageStore verification memo; no attempt is made to evict the OS page cache.",
        "Every fixture is a valid PNG with incompressible RGB pixel data, not padding or a truncated image." } }
Files.write(output .. "/results.json", json.encode(result, { pretty = true }))
print(json.encode(result))
