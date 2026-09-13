-- Capture consecutive real anonymous bookstore pages through production workers and native widgets.
local plugin, output = assert(arg[1]), assert(arg[2])
local function positive(value, default, name)
    local number = tonumber(value or default)
    assert(number and number >= 1 and number % 1 == 0 and number < math.huge, name .. " must be a positive integer")
    return number
end
local requested_pages = positive(arg[3], 2, "pages")
local minimum_cards = positive(arg[4], 6, "min-visible-cards")
local minimum_recommendations = positive(arg[5], 12, "min-recommendations")
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
local started, finished, page_started = clock(), false, nil
local events = output .. "/bookstore-expanded-live-requests.jsonl"
local controller, screens
local allowed_covers, session_lookups, captured_ids = {}, {}, {}
local result = {
    passed = false,
    scope = "Real Runtime, Controller, Screens, Runner and TLS transport; consecutive anonymous official bookstore pages and visible CDN covers only",
    synthetic_data = false, isolated_profile = true, request_boundary_installed = false,
    width = Device.screen:getWidth(), height = Device.screen:getHeight(),
    requested_pages = requested_pages, min_visible_cards = minimum_cards, min_recommendations = minimum_recommendations,
    page_timeout_seconds = 75, worker_submissions = {}, captured_pages = {}, pagination_actions = {},
    recommendations = {}, visible_cards = {}, assertions = {},
}

local function event(value)
    value.pid = tonumber(ffi.C.getpid())
    local file = assert(io.open(events, "ab"))
    assert(file:write(assert(JSON.encode(value)), "\n"))
    assert(file:close())
end

local function check(name, condition, detail)
    result.assertions[#result.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end

local function denied(kind)
    event({ event = "blocked", kind = kind })
    return nil, { kind = "live_boundary", message = "The anonymous bookstore probe rejected an unrelated operation.", transmitted = false }
end

-- The anonymous identity is rejected by Storage.path before any session file is resolved or opened.
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
    probe = debug.getinfo(1, "S").source,
    runtime = debug.getinfo(Runtime.get, "S").source,
    controller = debug.getinfo(require("bilicomics/controller").new, "S").source,
    screens = debug.getinfo(require("bilicomics/ui/screens").showBookstore, "S").source,
    runner = debug.getinfo(Runner._start, "S").source,
    recommendations = debug.getinfo(require("bilicomics/protocol/recommendations").fetch, "S").source,
}
local source_files = {
    probe = "spec/ui/bookstore_expanded_live.lua", runtime = "bilicomics/runtime.lua",
    controller = "bilicomics/controller.lua", screens = "bilicomics/ui/screens.lua",
    runner = "bilicomics/jobs/runner.lua", recommendations = "bilicomics/protocol/recommendations.lua",
}
for name, source in pairs(result.loaded_sources) do
    assert(source == "@" .. plugin .. "/" .. source_files[name], "The production source identity differs from the selected checkout")
end

local function runnerIdle()
    local runner = controller.account.raw_runner
    return not next(runner.tasks) and #runner.queue == 0
end

local function snapshot()
    local value = controller:getBookstore()
    check("official_anonymous_recommendation_source", value.source == "official_homepage" and value.personalized == false)
    check("minimum_real_recommendation_count", #value.items >= minimum_recommendations, #value.items)
    local ids = {}
    for index, comic in ipairs(value.items) do
        local id = tostring(comic.id)
        check("unique_recommendation_" .. index, comic.id ~= nil and not ids[id], id)
        ids[id] = true
    end
    if #result.recommendations == 0 then
        for _, comic in ipairs(value.items) do
            result.recommendations[#result.recommendations + 1] = { id = tostring(comic.id), title = comic.title }
        end
        result.feed_source, result.personalized = value.source, value.personalized
        result.recommendations_unique = true
    else
        check("recommendation_count_stays_stable", #value.items == #result.recommendations)
        for index, comic in ipairs(value.items) do
            check("cached_recommendation_order_" .. index, tostring(comic.id) == result.recommendations[index].id)
        end
    end
    return value
end

local function coverState(card)
    local comic = controller:getComic(card.comic.id)
    local header
    if comic and comic.cover_path and Files.exists(comic.cover_path) then
        local ok, value = pcall(Header.read, comic.cover_path)
        if ok and ImagePolicy.fitsCover(value) then header = value end
    end
    return comic, header
end

local function allCoversReady()
    if screens.bookstore_loading or #(screens.cards or {}) < minimum_cards then return false end
    for _, card in ipairs(screens.cards) do
        local _, header = coverState(card)
        if not header then return false end
    end
    return true
end

local function finish(reason, detail)
    if finished then return end
    finished = true
    result.reason, result.failure_detail = reason, detail
    result.elapsed_seconds = clock() - started
    result.account_key, result.session_present = controller.account.key, controller.account.session ~= nil
    result.session_lookups = session_lookups
    result.route, result.page, result.pages = screens.route, screens.page, screens.pages
    result.runner_idle = runnerIdle()
    result.favorite_count = #controller:getLibrary("favorites")
    result.history_count = #controller:getLibrary("history")
    result.download_count = #controller:getDownloads()
    result.passed = reason == "loaded" and #result.captured_pages == requested_pages
        and #result.recommendations >= minimum_recommendations and result.recommendations_unique == true
        and result.visible_ids_unique_and_ordered == true and result.first_screen_covers_loaded == true
        and result.runner_idle and result.account_key == "anonymous" and not result.session_present
        and result.favorite_count == 0 and result.history_count == 0 and result.download_count == 0
    if not result.passed and screens.widget then
        local ok = pcall(function()
            UIManager:forceRePaint()
            Device.screen.bb:writePNG(output .. "/bookstore-expanded-live-failure.png")
        end)
        if ok then result.failure_screenshot = "bookstore-expanded-live-failure.png" end
    end
    Runtime.close()
    result.runtime_closed = Runtime.peek() == nil
    result.passed = result.passed and result.runtime_closed
    local file = assert(io.open(output .. "/bookstore-expanded-live-result.json", "wb"))
    assert(file:write(assert(JSON.encode(result))))
    assert(file:close())
    UIManager:quit(result.passed and 0 or 1)
end

local function capturePage()
    local expected_page = #result.captured_pages + 1
    check("sequential_page_" .. expected_page, screens.route == "bookstore" and screens.page == expected_page)
    check("enough_visible_cards_page_" .. expected_page, #screens.cards >= minimum_cards, #screens.cards)
    check("idle_workers_page_" .. expected_page, runnerIdle())
    local feed = snapshot()
    -- Rebuild native image widgets after cache publication, even if its repaint notification is still queued.
    screens:refresh()
    check("completed_cover_widgets_page_" .. expected_page, allCoversReady() and runnerIdle())
    UIManager:forceRePaint()
    local content = assert(screens.widget).content:getSize()
    check("native_content_fits_page_" .. expected_page, content.w <= result.width and content.h <= result.height)
    local page = { page = expected_page, cards = {}, rects = {}, source = feed.source, personalized = feed.personalized,
        cache_updated_at = feed.updated_at, runner_idle = true, all_covers_loaded = true,
        content_bounds = { w = content.w, h = content.h }, elapsed_seconds = clock() - page_started,
        screenshot = string.format("bookstore-expanded-live-page-%02d.png", expected_page) }
    local offset = 0
    for _, captured in ipairs(result.captured_pages) do offset = offset + #captured.cards end
    local page_ids = {}
    for index, card in ipairs(screens.cards) do
        local id, source_index = tostring(card.comic.id), offset + index
        local expected = result.recommendations[source_index]
        check("visible_order_page_" .. expected_page .. "_card_" .. index, expected and expected.id == id)
        check("unique_visible_page_" .. expected_page .. "_card_" .. index, not page_ids[id] and not captured_ids[id], id)
        page_ids[id] = true
        local comic, header = coverState(card)
        check("loaded_cover_page_" .. expected_page .. "_card_" .. index, header ~= nil)
        local source = CoverSource.resolve(comic.cover_url)
        check("production_thumbnail_page_" .. expected_page .. "_card_" .. index,
            source and comic.extra and comic.extra.cached_cover_url == source.url)
        local rect = assert(card.dimen)
        check("card_fits_page_" .. expected_page .. "_card_" .. index,
            type(rect.x) == "number" and type(rect.y) == "number" and type(rect.w) == "number" and type(rect.h) == "number"
            and rect.x >= 0 and rect.y >= 0 and rect.w > 0 and rect.h > 0
            and rect.x + rect.w <= result.width and rect.y + rect.h <= result.height)
        for previous_index, previous in ipairs(page.rects) do
            check("cards_do_not_overlap_page_" .. expected_page .. "_" .. previous_index .. "_" .. index,
                rect.x >= previous.x + previous.w or previous.x >= rect.x + rect.w
                or rect.y >= previous.y + previous.h or previous.y >= rect.y + rect.h)
        end
        page.cards[#page.cards + 1] = { id = id, title = card.comic.title, source_index = source_index,
            cover_loaded = true, cover_width = header.width, cover_height = header.height, cover_format = header.format,
            cached_cover_url = comic.extra.cached_cover_url }
        page.rects[#page.rects + 1] = { id = id, x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    end
    Device.screen.bb:writePNG(output .. "/" .. page.screenshot)
    for id in pairs(page_ids) do captured_ids[id] = true end
    result.captured_pages[#result.captured_pages + 1] = page
    if expected_page == 1 then
        result.visible_cards, result.screenshot = page.cards, page.screenshot
        result.first_screen_covers_loaded = true
    end
    result.visible_ids_unique_and_ordered = true
end

local function inspect()
    if finished then return end
    local ok, failure = pcall(function()
        local expected_page = #result.captured_pages + 1
        if screens.route ~= "bookstore" or screens.page ~= expected_page then return finish("unexpected_page") end
        if screens.bookstore_error then return finish("feed_error_" .. tostring(screens.bookstore_error.kind)) end
        if clock() - page_started > result.page_timeout_seconds then return finish("deadline_page_" .. expected_page) end
        if not screens.bookstore_loading then
            if #controller:getBookstore().items < minimum_recommendations then return finish("insufficient_recommendations") end
            if #(screens.cards or {}) < minimum_cards then return finish("insufficient_visible_cards_page_" .. expected_page) end
        end
        if allCoversReady() and runnerIdle() then
            capturePage()
            if #result.captured_pages == requested_pages then return finish("loaded") end
            local next_page = screens.pagination and screens.pagination.next
            if not next_page or next_page.enabled == false or type(next_page.callback) ~= "function" then
                return finish("insufficient_pages")
            end
            local previous_page = screens.page
            page_started = clock()
            next_page.callback()
            check("native_next_callback_advances_page_" .. previous_page, screens.page == previous_page + 1)
            result.pagination_actions[#result.pagination_actions + 1] = {
                from = previous_page, to = screens.page, method = "screens.pagination.next.callback",
            }
        end
        UIManager:scheduleIn(0.1, inspect)
    end)
    if not ok then
        event({ event = "probe_error", message = tostring(failure) })
        finish("probe_error", tostring(failure))
    end
end

page_started = clock()
screens:showBookstore()
UIManager:scheduleIn(0.1, inspect)
UIManager:run()
assert(finished and result.passed, "The live anonymous bookstore did not provide the required complete consecutive pages")
