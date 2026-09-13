-- Capture the real category picker and first category page through production anonymous workers.
local plugin, output = assert(arg[1]), assert(arg[2])
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
require("gettext").current_lang = "zh_CN"
local UIManager = require("ui/uimanager")
local JSON = require("bilicomics/protocol/json")
local Files = require("bilicomics/storage/files")
local Categories = require("bilicomics/protocol/categories")
local Assets = require("bilicomics/protocol/assets")
local Header = require("bilicomics/storage/image_header")
local ImagePolicy = require("bilicomics/image_policy")
local SessionStorage = require("bilicomics/session_storage")
local Transport = require("bilicomics/protocol/transport")
local Runner = require("bilicomics/jobs/runner")
local clock = require("socket").gettime
local controller, screens, selected_query
local allowed_covers, session_lookups = {}, {}
local started, finished, selected = clock(), false, false
local result = { passed = false, synthetic_data = false, isolated_profile = true,
    scope = "Production category route, real picker callback and first category page; fresh anonymous profile; existing read-only guard",
    width = Device.screen:getWidth(), height = Device.screen:getHeight(), worker_submissions = {}, screenshots = {} }
local function event(value)
    local file = assert(io.open(output .. "/bookstore-categories-live-requests.jsonl", "ab"))
    file:write(assert(JSON.encode(value)), "\n"); file:close()
end
local load_session = SessionStorage.load
function SessionStorage:load(key)
    assert(key == "anonymous", "The category capture cannot inspect an authenticated session")
    session_lookups[#session_lookups + 1] = key
    return load_session(self, key)
end
for _index, name in ipairs({ "save", "remove" }) do
    SessionStorage[name] = function() error("Session mutation is forbidden in this capture") end
end
assert(assert(loadfile(plugin .. "/spec/local/readonly_guard.lua"))().install(output))
local guarded_request, guarded_submit = Transport.request, Runner.submit
function Transport:request(request)
    local route
    if request.url == Categories.metadata_url then route = "AllLabel"
    elseif request.url == Categories.device_url then route = "AnonymousDevice"
    elseif request.url:sub(1, #Categories.page_url) == Categories.page_url then route = "ClassPage"
    elseif request.url == Assets.manifest.signing.url then route = "PinnedSigningAsset"
    elseif allowed_covers[request.url] then route = "VisibleCover"
    else error("An unrelated capture request was blocked") end
    local device_cookie = false
    for key, value in pairs(request.headers or {}) do
        local lower = key:lower()
        assert(lower ~= "authorization" and lower ~= "x-xsrf-token")
        if lower == "cookie" then
            assert(route == "ClassPage" and value:match("^buvid3=[%w_-]+$"))
            device_cookie = true
        end
    end
    local response, err = guarded_request(self, request)
    -- The existing guard verifies exact routes, bodies, headers and signatures; do not log their values.
    event({ route = route, method = request.method, status = response and response.status,
        bytes = response and response.bytes, anonymous_device_cookie_only = device_cookie,
        account_credentials_absent = true, error_kind = err and err.kind })
    return response, err
end
function Runner:submit(request, options, callback)
    assert(controller.account.key == "anonymous" and controller.account.session == nil
        and request.session == nil and request.public_bookstore == true)
    local allowed = request.kind == "client" and request.method == "bookstoreCategories"
    if request.kind == "client" and request.method == "bookstoreCategoryPage" then
        local query = request.arguments[1]
        allowed = selected_query and query.category_id == selected_query.category_id and query.sort == 0 and request.arguments[2] == 1
    elseif request.kind == "download_cover" then
        allowed = selected_query and controller:_bookstoreCoverAllowed(request.comic_id, request.url, request.feed_identity)
            and Files.within(request.temporary_path, controller.account.root .. "/covers")
        if allowed then allowed_covers[request.url] = true end
    end
    assert(allowed, "An unrelated worker was blocked")
    result.worker_submissions[#result.worker_submissions + 1] = { kind = request.kind, method = request.method, comic_id = request.comic_id }
    return guarded_submit(self, request, options, callback)
end
local Runtime = require("bilicomics/runtime")
controller, screens = Runtime.get(nil, { root = output .. "/profile/plugin-data" })
assert(controller.account.key == "anonymous" and controller.account.session == nil)
assert(getmetatable(controller.account.raw_runner) == Runner)
result.loaded_sources = {
    runtime = debug.getinfo(Runtime.get, "S").source,
    controller = debug.getinfo(require("bilicomics/controller").new, "S").source,
    screens = debug.getinfo(require("bilicomics/ui/screens")._bookstoreCategoryPicker, "S").source,
    runner = debug.getinfo(Runner._start, "S").source,
}
local function idle()
    return not next(controller.account.raw_runner.tasks) and #controller.account.raw_runner.queue == 0
end
local function capture(name)
    UIManager:forceRePaint()
    local size = screens.widget.content:getSize()
    assert(size.w <= result.width and size.h <= result.height)
    if screens.dialog then
        local modal = screens.dialog.movable:getSize()
        assert(modal.w <= result.width and modal.h <= result.height)
    end
    Device.screen.bb:writePNG(output .. "/" .. name)
    result.screenshots[#result.screenshots + 1] = name
end
local function finish(reason)
    if finished then return end
    finished = true
    result.reason, result.elapsed_seconds = reason, clock() - started
    result.account_key, result.session_present = controller.account.key, controller.account.session ~= nil
    result.session_lookups, result.runner_idle = session_lookups, idle()
    result.favorite_count, result.history_count, result.download_count = #controller:getLibrary("favorites"), #controller:getLibrary("history"), #controller:getDownloads()
    result.passed = reason == "loaded" and #result.screenshots == 2 and #result.visible_cards == 6
        and result.runner_idle and not result.session_present and result.favorite_count == 0 and result.history_count == 0 and result.download_count == 0
    Runtime.close(); result.runtime_closed = Runtime.peek() == nil
    local file = assert(io.open(output .. "/bookstore-categories-live-result.json", "wb"))
    file:write(assert(JSON.encode(result))); file:close()
    UIManager:quit(result.passed and 0 or 1)
end
local function inspect()
    if finished then return end
    local ok, err = pcall(function()
        if clock() - started > 75 then return finish("deadline") end
        if not selected then
            local metadata = controller:getBookstoreCategories()
            if #metadata.items > 0 and screens.bookstore_picker_state and not screens.bookstore_picker_state.loading then
                local category
                for _index, item in ipairs(metadata.items) do if item.id == "999" then category = item; break end end
                assert(category and category.name == "\231\131\173\232\161\128", "The requested category must exist in official metadata")
                result.categories, result.selected_category = metadata.items, category
                capture("bookstore-categories-live-picker.png")
                local control
                for _row_index, row in ipairs(screens.dialog.buttons) do for _button_index, entry in ipairs(row) do
                    if entry.text:gsub("^%[[x ]%] ", "") == category.name then control = entry end
                end end
                assert(control, "The real native category option must be present")
                selected_query = { kind = "category", category_id = category.id, sort = 0 }
                selected = true
                control.callback()
                result.selection_used_native_callback = true
            end
        elseif not screens.bookstore_loading then
            if screens.bookstore_error then return finish("category_error_" .. screens.bookstore_error.kind) end
            local feed = controller:getBookstore(selected_query)
            local ready = #screens.cards == 6 and idle()
            for _index, card in ipairs(screens.cards) do
                local comic = controller:getComic(card.comic.id)
                ready = ready and comic and comic.cover_path and ImagePolicy.fitsCover(Header.read(comic.cover_path))
            end
            if ready then
                screens:refresh()
                result.feed_source, result.query, result.comic_count = feed.source, selected_query, #feed.items
                result.page, result.loaded_pages = screens.page, feed.loaded_pages
                result.visible_cards = {}
                for index, card in ipairs(screens.cards) do
                    assert(tostring(card.comic.id) == tostring(feed.items[index].id))
                    local comic = controller:getComic(card.comic.id)
                    local header = assert(Header.read(comic.cover_path))
                    result.visible_cards[#result.visible_cards + 1] = { id = card.comic.id, title = card.comic.title,
                        cover_loaded = ImagePolicy.fitsCover(header), cover_width = header.width, cover_height = header.height }
                end
                capture("bookstore-categories-live-heat.png")
                return finish("loaded")
            end
        end
        UIManager:scheduleIn(0.1, inspect)
    end)
    if not ok then event({ route = "CaptureError", error_kind = "capture_error" }); finish("capture_error") end
end
result.visible_cards = {}
-- Open the production route without repeating the already-verified homepage load, then use real menu callbacks.
screens:_navigate("bookstore")
screens.bookstore_category_button.callback()
result.picker_used_native_callback = true
UIManager:scheduleIn(0.1, inspect)
UIManager:run()
assert(finished and result.passed, "The anonymous category capture did not complete")
