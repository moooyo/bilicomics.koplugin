-- Run only in the isolated test-env KOReader runtime.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local Controller = require("bilicomics/controller")
local Session = require("bilicomics/protocol/session")
local Source = require("bilicomics/cover_source")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local tests = {}
local function check(name, condition)
    tests[#tests + 1] = { name = name, passed = not not condition }
    assert(condition, name)
end

local original = "https://i0.hdslb.com/synthetic-cover.jpg"
local derived = original .. "@480w.jpg"
check("official_jpeg_width_transform", Source.resolve(original).url == derived)
check("official_uppercase_jpeg_fallback", Source.resolve("https://i0.hdslb.com/cover.JPEG").url
    == "https://i0.hdslb.com/cover.JPEG@480w.jpg")
for _, extension in ipairs({ "png", "webp", "avif" }) do
    local url = "https://i0.hdslb.com/cover." .. extension
    check("official_png_fallback_" .. extension, Source.resolve(url).url == url .. "@480w.png")
end
for index, url in ipairs({ "https://i0.hdslb.com/cover.jpg@282w.jpg",
    "https://i0.hdslb.com/cover.jpg?width=800&format=png", "https://i0.hdslb.com/cover" }) do
    check("opaque_image_url_is_preserved_" .. index, Source.resolve(url).url == url
        and Source.resolve(url).thumbnail == false)
end
for index, url in ipairs({ "http://i0.hdslb.com/cover.jpg", "https://hdslb.com/cover.jpg",
    "https://i0.hdslb.com.evil.example/cover.jpg", "https://evil.example/cover.jpg",
    "https://i0.hdslb.com@evil.example/cover.jpg", "https://i0.hdslb.com:443/cover.jpg",
    "https://i0.hdslb.com/cover\n.jpg", "https://i0.hdslb.com/cover jpg", "//i0.hdslb.com/cover.jpg" }) do
    check("unsupported_or_ambiguous_url_is_rejected_" .. index, Source.resolve(url) == nil)
end

local ui = { queue = {} }
function ui:nextTick(fn) self.queue[#self.queue + 1] = fn end
function ui:scheduleIn() end
function ui:unschedule() end
function ui:show() end
function ui:close() end
function ui:drain()
    local maximum = 1000
    while #self.queue > 0 do maximum = maximum - 1; assert(maximum > 0); table.remove(self.queue, 1)() end
end
local function runnerFactory()
    local runner = { tasks = {}, count = 0 }
    function runner:submit(request, options, callback)
        self.count = self.count + 1
        local task = { request = request, options = options, callback = callback, id = self.count }
        self.tasks[task.id] = task
        return task.id
    end
    function runner:findCover()
        for _, task in pairs(self.tasks) do if task.request.kind == "download_cover" then return task end end
    end
    function runner:find(kind, method)
        for _, task in pairs(self.tasks) do
            if task.request.kind == kind and (not method or task.request.method == method) then return task end
        end
        error("No pending worker: " .. tostring(kind) .. "/" .. tostring(method))
    end
    function runner:finish(task, value, err)
        self.tasks[task.id] = nil; task.callback(value, err); ui:drain()
    end
    function runner:cancel(identifier)
        local task = self.tasks[identifier]
        if task then self.tasks[identifier] = nil; task.callback(nil, { kind = "canceled" }) end
    end
    function runner:close() self.closed = true end
    function runner:promote() end
    function runner:resume() end
    function runner:suspend() end
    return runner
end
local now, network = 1000, { connected = true }
function network:isConnected() return self.connected end
local app = Controller.new{ root = output .. "/data", ui_manager = ui, runner_factory = runnerFactory,
    network = network, clock = function() return now end }
ui:drain()
local cookie = "SESSDATA=synthetic-thumbnail-session; DedeUserID=42"
local session = assert(Session.parse(cookie))
assert(session:withIdentity({ id = "42", name = "Synthetic thumbnail account" }))
app:importSession(cookie, function(value, err) assert(value, err and err.kind) end)
app.runner:finish(app.runner:find("client", "validateSession"), { session = session:serialize() })
local library = {}
for index = 1, 20 do
    library[index] = { id = tostring(100 + index), title = "Synthetic library item " .. index,
        cover_url = "https://i0.hdslb.com/hidden-cover-" .. index .. ".jpg" }
end
local before_refresh, refreshed = app.runner.count
app:refreshLibrary("favorites", function(value, err) assert(value, err and err.kind); refreshed = value end)
app.runner:finish(app.runner:find("library"), library)
check("library_refresh_keeps_hidden_covers_out_of_worker_queue", refreshed and #refreshed == 20
    and app.runner:findCover() == nil and app.runner.count == before_refresh + 1)
local before_search, searched = app.runner.count
app:search("synthetic", function(value, err) assert(value, err and err.kind); searched = value end)
app.runner:finish(app.runner:find("client", "search"), library)
check("search_results_keep_hidden_covers_out_of_worker_queue", searched and #searched == 20
    and app.runner:findCover() == nil and app.runner.count == before_search + 1)
app:requestCover("101")
local visible = assert(app.runner:findCover())
check("only_explicit_visible_item_dispatches_its_cover", app.runner.count == before_search + 2
    and visible.request.url == "https://i0.hdslb.com/hidden-cover-1.jpg@480w.jpg")
app.runner:finish(visible, nil, { kind = "image_http" })
local function save(url, extra)
    app.account.store:upsertComic{ id = "10", title = "Synthetic cover", cover_url = url, extra = extra }
end
local function success(task)
    Files.write(task.request.temporary_path, Files.read(output .. "/fixture.png"))
    return { temporary_path = task.request.temporary_path, format = "png", width = 20, height = 40 }
end
save(original)
network.connected = false
app:requestCover("10")
check("offline_cover_does_not_dispatch", app.runner:findCover() == nil)
network.connected = true
app:requestCover("10")
local task = assert(app.runner:findCover())
check("cover_dispatch_uses_thumbnail_with_existing_budget", task.request.url == derived
    and task.request.max_bytes == 4 * 1024 * 1024 and task.options.priority == 60 and task.options.resource == "image")
local before = app.runner.count
app:requestCover("10")
check("repeated_visible_card_requests_share_one_worker", app.runner.count == before)
app.runner:finish(task, success(task))
local comic = app.account.store:getComic("10")
check("cover_commits_an_atomic_strategy_bound_cache", Files.exists(comic.cover_path)
    and not Files.exists(task.request.temporary_path) and comic.extra.cached_cover_url == derived
    and comic.extra.cached_cover_identity == Source.resolve(original).identity)
app:requestCover("10")
check("matching_strategy_cache_avoids_transfer", app.runner.count == before)

comic.extra.cached_cover_identity = nil
comic.extra.cached_cover_url = original
app.account.store:upsertComic(comic)
app:requestCover("10")
task = assert(app.runner:findCover())
check("legacy_original_cache_is_replaced", task.request.url == derived and app.runner.count == before + 1)
app.runner:finish(task, nil, { kind = "image_size" })
before = app.runner.count
app:requestCover("10")
now = 1299
app:requestCover("10")
check("failed_thumbnail_keeps_five_minute_backoff", app.runner.count == before)
now = 1300
app:requestCover("10")
task = assert(app.runner:findCover())
check("failed_thumbnail_retries_at_backoff_boundary", app.runner.count == before + 1)
app.runner:finish(task, nil, { kind = "image_size" })

local changed = "https://i0.hdslb.com/revised-cover.jpg"
save(changed)
app:requestCover("10")
task = assert(app.runner:findCover())
check("old_url_failure_does_not_delay_new_thumbnail", task.request.url == changed .. "@480w.jpg")
local superseded = success(task)
local latest = "https://i0.hdslb.com/latest-cover.jpg"
save(latest)
app.runner:finish(task, superseded)
check("obsolete_cover_result_is_removed", not Files.exists(superseded.temporary_path))
task = assert(app.runner:findCover())
check("changed_source_is_dispatched_after_old_result", task.request.url == latest .. "@480w.jpg")
local newer = "https://i0.hdslb.com/newer-cover.jpg"
save(newer)
app.runner:finish(task, nil, { kind = "image_http" })
task = assert(app.runner:findCover())
check("changed_source_retries_after_old_failure", task.request.url == newer .. "@480w.jpg")
app.runner:finish(task, success(task))

save("https://i0.hdslb.com/account-switch.jpg")
app:requestCover("10")
local old_runner, old_account = app.runner, app.account
task = assert(old_runner:findCover())
local obsolete = success(task)
app:_openAccount("bili_43", nil)
old_runner:finish(task, obsolete)
check("account_generation_discards_obsolete_cover", not Files.exists(obsolete.temporary_path)
    and app.account.key == "bili_43" and app.account.store:getComic("10") == nil
    and next(app.covers) == nil and next(app.cover_failures) == nil)
old_account.store:close()
app:close(); ui:drain()
Files.write(output .. "/cover-thumbnail-controller-result.json", json.encode({ tests = tests, count = #tests,
    passed = true, scope = "Production controller, native SQLite and controlled asynchronous workers; synthetic accounts only" }, { pretty = true }))
print(json.encode({ count = #tests, passed = true }))
