-- Exercise the real anonymous bookstore with production workers and a strict live request boundary.
local plugin, output = assert(arg[1]), assert(arg[2])
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
G_reader_settings:saveSetting("color_rendering", false)
local Device = require("device")
require("document/canvascontext"):init(Device)
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
require("gettext").current_lang = "zh_CN"

local UIManager = require("ui/uimanager")
local JSON = require("bilicomics/protocol/json")
local Files = require("bilicomics/storage/files")
local CoverSource = require("bilicomics/cover_source")
local Header = require("bilicomics/storage/image_header")
local ImagePolicy = require("bilicomics/image_policy")
local SessionStorage = require("bilicomics/session_storage")
local Transport = require("bilicomics/protocol/transport")
local Runner = require("bilicomics/jobs/runner")
local ffi = require("ffi")
local clock = require("socket").gettime
local started, finished = clock(), false
local events = output .. "/requests.jsonl"
local controller, screens
local allowed_covers, session_lookups = {}, {}
local result = {
    passed = false, scope = "Real Runtime, Controller, Screens, Runner and TLS transport; anonymous official recommendations and visible CDN covers only",
    synthetic_data = false, isolated_profile = true, request_boundary_installed = false,
    width = Device.screen:getWidth(), height = Device.screen:getHeight(), worker_submissions = {},
}

local function event(value)
    value.pid = tonumber(ffi.C.getpid())
    local file = assert(io.open(events, "ab"))
    assert(file:write(assert(JSON.encode(value)), "\n"))
    assert(file:close())
end

local function denied(kind)
    event({ event = "blocked", kind = kind })
    return nil, { kind = "live_boundary", message = "The anonymous bookstore probe rejected an unrelated operation.", transmitted = false }
end

-- Anonymous Storage.load returns before resolving or opening any session path.
local load_session = SessionStorage.load
function SessionStorage:load(key)
    session_lookups[#session_lookups + 1] = key
    assert(key == "anonymous", "The live bookstore profile must never inspect an authenticated account")
    return load_session(self, key)
end
for _, name in ipairs({ "save", "remove" }) do
    SessionStorage[name] = function() error("Session changes are forbidden in the live bookstore probe") end
end

assert(assert(loadfile(plugin .. "/spec/local/readonly_guard.lua"))().install(output))
local guarded_request, guarded_submit = Transport.request, Runner.submit
local feed_url = "https://manga.bilibili.com/index.pageContext.json"
local header_names = { ["user-agent"] = true, accept = true, referer = true }

function Transport:request(request)
    if type(request) ~= "table" or request.method ~= "GET" or request.body ~= nil then return denied("method_or_body") end
    local headers = {}
    for key, value in pairs(request.headers or {}) do
        local lower = type(key) == "string" and key:lower()
        if not lower or not header_names[lower] or headers[lower] or type(value) ~= "string"
            or value:find("[%c]") then return denied("request_headers") end
        headers[lower] = true
    end
    local category
    if request.url == feed_url and request.output_path == nil and request.max_bytes == 4 * 1024 * 1024 then
        category = "official_recommendations"
    elseif allowed_covers[request.url] and type(request.output_path) == "string"
        and Files.within(request.output_path, output .. "/profile/plugin-data/accounts/anonymous/covers")
        and request.max_bytes == 4 * 1024 * 1024 then
        category = "visible_official_cover"
    else return denied("url_or_output") end
    local names = {}
    for name in pairs(headers) do names[#names + 1] = name end
    table.sort(names)
    event({ event = "request", category = category, url = request.url, method = "GET",
        body_absent = true, credentials_absent = true, header_names = names, max_bytes = request.max_bytes })
    local response, err = guarded_request(self, request)
    event({ event = "response", category = category, url = request.url, status = response and response.status,
        bytes = response and response.bytes, error_kind = err and err.kind })
    return response, err
end

function Runner:submit(request, options, callback)
    if not controller or controller.account.key ~= "anonymous" or controller.account.session ~= nil
        or type(request) ~= "table" or request.session ~= nil or request.public_bookstore ~= true
        or request.transport_options ~= nil then return denied("worker_identity") end
    local allowed = request.kind == "client" and request.method == "recommendations"
        and type(request.arguments) == "table" and next(request.arguments) == nil
    if request.kind == "download_cover" and controller:_bookstoreMember(request.comic_id) then
        local comic = controller:getComic(request.comic_id)
        local source = comic and CoverSource.resolve(comic.cover_url)
        allowed = source ~= nil and request.url == source.url and request.max_bytes == 4 * 1024 * 1024
            and type(request.temporary_path) == "string"
            and Files.within(request.temporary_path, controller.account.root .. "/covers")
        if allowed then allowed_covers[request.url] = tostring(request.comic_id) end
    end
    if not allowed then return denied("worker_kind") end
    result.worker_submissions[#result.worker_submissions + 1] = {
        kind = request.kind, method = request.method, comic_id = request.comic_id, anonymous = true,
    }
    return guarded_submit(self, request, options, callback)
end
result.request_boundary_installed = true

local Runtime = require("bilicomics/runtime")
controller, screens = Runtime.get(nil, { root = output .. "/profile/plugin-data" })
assert(controller.account.key == "anonymous" and controller.account.session == nil)
assert(getmetatable(controller.account.raw_runner) == Runner, "The production subprocess Runner is required")
result.loaded_sources = {
    runtime = debug.getinfo(Runtime.get, "S").source,
    controller = debug.getinfo(require("bilicomics/controller").new, "S").source,
    screens = debug.getinfo(require("bilicomics/ui/screens").showBookstore, "S").source,
    runner = debug.getinfo(Runner._start, "S").source,
}
for name, source in pairs(result.loaded_sources) do
    local expected = name == "runner" and "bilicomics/jobs/runner.lua"
        or name == "screens" and "bilicomics/ui/screens.lua" or "bilicomics/" .. name .. ".lua"
    assert(source == "@" .. plugin .. "/" .. expected, "The production source identity differs from the selected checkout")
end

local function finish(reason)
    if finished then return end
    finished = true
    result.reason = reason
    result.elapsed_seconds = clock() - started
    result.account_key, result.session_present = controller.account.key, controller.account.session ~= nil
    result.session_lookups = session_lookups
    result.route, result.page, result.pages = screens.route, screens.page, screens.pages
    result.recommendations, result.visible_cards = {}, {}
    local snapshot = controller:getBookstore()
    result.feed_source, result.personalized = snapshot.source, snapshot.personalized
    for _, comic in ipairs(snapshot.items) do
        result.recommendations[#result.recommendations + 1] = { id = comic.id, title = comic.title }
    end
    local all_covers = #(screens.cards or {}) > 0
    for _, card in ipairs(screens.cards or {}) do
        local comic = controller:getComic(card.comic.id)
        local header = comic and comic.cover_path and Header.read(comic.cover_path)
        local loaded = header ~= nil and ImagePolicy.fitsCover(header)
        all_covers = all_covers and loaded
        result.visible_cards[#result.visible_cards + 1] = {
            id = tostring(card.comic.id), title = card.comic.title, cover_loaded = loaded,
            cover_width = header and header.width, cover_height = header and header.height,
            cover_format = header and header.format,
            cached_cover_url = comic and comic.extra and comic.extra.cached_cover_url,
        }
    end
    result.first_screen_covers_loaded = all_covers
    result.runner_idle = not next(controller.account.raw_runner.tasks) and #controller.account.raw_runner.queue == 0
    result.favorite_count = #controller:getLibrary("favorites")
    result.history_count = #controller:getLibrary("history")
    result.download_count = #controller:getDownloads()
    result.passed = reason == "loaded" and #snapshot.items > 0 and all_covers and result.runner_idle
        and result.account_key == "anonymous" and not result.session_present
        and result.favorite_count == 0 and result.history_count == 0 and result.download_count == 0
    UIManager:forceRePaint()
    Device.screen.bb:writePNG(output .. "/bookstore-live.png")
    result.screenshot = "bookstore-live.png"
    Runtime.close()
    result.runtime_closed = Runtime.peek() == nil
    local file = assert(io.open(output .. "/bookstore-live-result.json", "wb"))
    assert(file:write(assert(JSON.encode(result))))
    assert(file:close())
    UIManager:quit(result.passed and 0 or 1)
end

local function inspect()
    if finished then return end
    local ok, failure = pcall(function()
        if screens.bookstore_error then return finish("feed_error_" .. tostring(screens.bookstore_error.kind)) end
        local all_covers = not screens.bookstore_loading and #(screens.cards or {}) > 0
        for _, card in ipairs(screens.cards or {}) do
            local comic = controller:getComic(card.comic.id)
            all_covers = all_covers and comic ~= nil and comic.cover_path ~= nil and Files.exists(comic.cover_path)
        end
        local runner = controller.account.raw_runner
        if all_covers and not next(runner.tasks) and #runner.queue == 0 then return finish("loaded") end
        if clock() - started > 75 then return finish("deadline") end
        UIManager:scheduleIn(0.1, inspect)
    end)
    if not ok then
        event({ event = "probe_error", message = tostring(failure) })
        finish("probe_error")
    end
end

screens:showBookstore()
UIManager:scheduleIn(0.1, inspect)
UIManager:run()
assert(finished and result.passed, "The live anonymous bookstore did not reach a complete first screen")
