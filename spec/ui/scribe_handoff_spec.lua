-- Accept the Scribe handoff using native widgets, original art, and controlled callbacks.
-- This independent suite preserves the historical density assertions in older specs.
require("setupkoenv")
local plugin, output_dir = assert(arg[1]), assert(arg[2])
local ffi = require("ffi")
require("ffi/posix_h")
if not pcall(function() return ffi.C.readlink end) then
    ffi.cdef[[long readlink(const char *path, char *buffer, unsigned long size);]]
end
local namespace_buffer = ffi.new("char[256]")
local namespace_length = tonumber(ffi.C.readlink("/proc/self/ns/net", namespace_buffer, 256))
assert(namespace_length and namespace_length > 0 and namespace_length < 256)
assert(ffi.string(namespace_buffer, namespace_length) ~= assert(os.getenv("BILI_SCRIBE_PARENT_NETNS")),
    "A separate network namespace is required")
local routes, route_count = assert(io.open("/proc/net/route", "rb")), 0
for line in routes:lines() do
    if line:match("%S") and not line:match("^Iface%s") then route_count = route_count + 1 end
end
assert(routes:close())
assert(route_count == 0, "The synthetic acceptance namespace must have no network routes")

G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local forbidden_modules = { "bilicomics/controller", "bilicomics/runtime", "bilicomics/protocol/client",
    "bilicomics/protocol/transport", "bilicomics/protocol/session", "bilicomics/purchase/service",
    "bilicomics/purchase/quote_fetch", "bilicomics/recharge/service" }
for _, name in ipairs(forbidden_modules) do
    assert(package.loaded[name] == nil, "A production business module was already loaded")
    package.preload[name] = function() error("Production business modules are forbidden in this synthetic acceptance") end
end
require("gettext").current_lang = arg[3] or "zh_CN"
local UIManager = require("ui/uimanager")
local Screens = require("bilicomics/ui/screens")
local Model = require("bilicomics/ui/model")
local W = require("bilicomics/ui/widgets")
local T = require("bilicomics/ui/i18n")
local json = require("rapidjson")
local width, height = Device.screen:getWidth(), Device.screen:getHeight()
local scribe = width == 1860 and height == 2480
local report = { spec = "native-scribe-handoff", width = width, height = height, language = arg[3] or "zh_CN",
    synthetic_only = true, actual_purchase_executed = false, actual_recharge_created = false,
    network_namespace_isolated = true, no_network_routes = true, assertions = {}, screenshots = {}, scenarios = {},
    density_scope = "Independent handoff requirements; no replacement of historical density assertions" }
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
local function visit(widget, predicate, result, seen)
    result, seen = result or {}, seen or {}
    if type(widget) ~= "table" or seen[widget] then return result end
    seen[widget] = true
    if predicate(widget) then result[#result + 1] = widget end
    for _, child in ipairs(widget) do visit(child, predicate, result, seen) end
    for _, field in ipairs({ "content", "_added_widgets", "layout", "header", "footer" }) do
        visit(widget[field], predicate, result, seen)
    end
    return result
end
local function allButtons(widget)
    return visit(widget, function(item) return type(item.text) == "string" and type(item.callback) == "function"
        and type(item.getSize) == "function" end)
end
local function normalize(label)
    return type(label) == "string" and label:gsub("^%[[x ]%] ", ""):gsub(" ▾$", "") or label
end
local function button(widget, message, optional)
    local label = T(message)
    for _, item in ipairs(allButtons(widget)) do
        if item.text == label or normalize(item.text) == label then return item end
    end
    if not optional then error("The native control was not found: " .. message) end
end
local function shownText(widget)
    local lines = {}
    for _, item in ipairs(visit(widget, function() return true end)) do
        for _, field in ipairs({ "text", "title", "purchase_text", "recharge_text", "description" }) do
            if type(item[field]) == "string" then lines[#lines + 1] = item[field] end
        end
    end
    return table.concat(lines, "\n")
end
local function hasText(widget, message) return shownText(widget):find(T(message), 1, true) ~= nil end
local function rectangle(widget)
    local size = widget:getSize()
    local dimen = widget.dimen or {}
    return { x = dimen.x or 0, y = dimen.y or 0, w = size.w, h = size.h }
end
local function within(box)
    return box.w <= width + 1 and box.h <= height + 1 and box.x >= -1 and box.y >= -1
        and box.x + box.w <= width + 1 and box.y + box.h <= height + 1
end
local timers, native_schedule, native_unschedule = {}, UIManager.scheduleIn, UIManager.unschedule
UIManager.scheduleIn = function(_manager, delay, callback) timers[callback] = delay end
UIManager.unschedule = function(_manager, callback) timers[callback] = nil end

local controller = { generation = 1, account_key = "synthetic-handoff", signed_in = true,
    calls = {}, waiting = {}, settings = { search_history = { "Original art", "Paper crane" } },
    comics = {}, episodes = {}, jobs = {}, purchases = {}, orders = {}, view = { help_seen = true, sort = "recent" },
    wallet = { remain_gold = 80, remain_coupon = 2 }, storage = { automatic_bytes = 36 * 1024 * 1024,
        pinned_bytes = 64 * 1024 * 1024, limit_bytes = 512 * 1024 * 1024 },
    sync = { has_cache = true, can_sync = true, authenticated = true, last_synced_at = os.time() - 600 },
    feed_stale = false, feed_items = {}, feed_revision = 1, feed_pages = 1 }
local function enqueue(method, args, callback)
    assert(type(callback) == "function", "A synthetic asynchronous operation requires a callback")
    local request = { method = method, args = copy(args or {}), callback = callback }
    controller.calls[#controller.calls + 1] = request
    controller.waiting[#controller.waiting + 1] = request
    return request
end
local function populate(amount, hero)
    controller.comics = {}
    for index = 1, amount do
        controller.comics[index] = { id = tostring(index), title = "Original story " .. index,
            authors = { "Synthetic author" }, description = "An original acceptance fixture, drawn for this UI verification.",
            cover_path = output_dir .. "/fixtures/synthetic-cover-" .. ((index - 1) % 5 + 1) .. ".png",
            favorite = true, finished = index % 4 == 0, has_update = index % 2 == 0,
            current_episode_id = index % 3 ~= 0 and "2" or nil, latest_episode_title = "The next horizon",
            progress_source = hero and index == 1 and "local" or nil,
            last_read_at = hero and index == 1 and os.time() - 7200 or nil,
            reading_position = hero and index == 1 and { episode_id = "2", index = 8, revision = "synthetic-r1" } or nil }
    end
    controller.feed_items = controller.comics
end
for index = 1, 32 do
    controller.episodes[index] = { id = tostring(index), comic_id = "1", order = index, short_title = tostring(index),
        title = "A new horizon " .. index, total_pages = 24, current_revision = "synthetic-r1",
        access = index > 5 and "locked" or index == 4 and "temporary" or index == 5 and "owned" or "free",
        offline_allowed = index <= 5 and index ~= 4, read = index == 1,
        expires_at = index == 4 and os.time() + 86400 * 3 or nil, downloaded = index == 3,
        pay_gold = index > 5 and 20 or nil }
end
local base_jobs = {
    { id = "running", kind = "episode_download", comic_id = "1", episode_id = "2", revision = "synthetic-r1", state = "running", completed = 8, total = 24 },
    { id = "paused", kind = "episode_download", comic_id = "2", episode_id = "3", revision = "synthetic-r1", state = "paused", completed = 6, total = 24 },
    { id = "failed", kind = "episode_download", comic_id = "3", episode_id = "2", revision = "synthetic-r1", state = "failed", completed = 7, total = 24,
        error = { kind = "source_unavailable" } },
    { id = "complete", kind = "episode_download", comic_id = "4", episode_id = "3", revision = "synthetic-r1", state = "complete", completed = 24, total = 24 },
}
populate(24, true); controller.jobs = copy(base_jobs)
function controller:getAccount()
    return { id = self.signed_in and "synthetic" or nil, account_key = self.account_key, name = "Synthetic account",
        session_valid = self.signed_in, renewable = true, auth_state = self.auth_state, recharge_supported = true }
end
function controller:getLibrary() return self.comics end
function controller:getBookshelfItems() return self.comics end
function controller:getBookshelfViewState() return copy(self.view) end
function controller:saveBookshelfViewState(value) self.view = copy(value); return true end
function controller:getBookshelfSyncState() return copy(self.sync) end
function controller:ensureBookshelfSync(callback) if callback then callback(self.comics) end end
function controller:refreshBookshelf(callback) enqueue("refreshBookshelf", {}, callback) end
function controller:refreshLibrary(kind, callback) enqueue("refreshLibrary", { kind }, callback) end
function controller:getComic(id) return self.comics[tonumber(id)] end
function controller:getEpisodes() return self.hide_episodes and {} or self.episodes end
function controller:getEpisode(id) return self.episodes[tonumber(id)] end
function controller:getDownloads() return self.jobs end
function controller:getWallet() return copy(self.wallet) end
function controller:getPendingPurchases() return self.purchases end
function controller:getStorageSummary() return copy(self.storage) end
function controller:getSetting(key, fallback) if self.settings[key] == nil then return copy(fallback) end; return copy(self.settings[key]) end
function controller:setSetting(key, value) self.settings[key] = copy(value); return true end
function controller:requestCover() end
function controller:requestBookstoreCover() end
function controller:cancelPendingRead() end
function controller:isFavoritePending() return false end
function controller:getBookstore(query)
    return { items = self.feed_items, stale = self.feed_stale, loaded_pages = self.feed_pages,
        has_more = false, can_load_more = false, identity = { account_key = self.account_key,
            query_key = query and "category:" .. tostring(query.category_id) or "homepage", revision = self.feed_revision } }
end
function controller:getBookstoreCategories()
    return { stale = false, items = { { id = "1", name = "Original adventures" }, { id = "2", name = "Quiet landscapes" } } }
end
function controller:refreshBookstore(query, callback)
    if type(query) == "function" then callback, query = query, nil end
    enqueue("refreshBookstore", { query }, callback)
end
function controller:refreshBookstoreCategories(callback) enqueue("refreshBookstoreCategories", {}, callback) end
function controller:loadMoreBookstore(query, callback) enqueue("loadMoreBookstore", { query }, callback) end
function controller:refreshComic(id, callback) enqueue("refreshComic", { id }, callback) end
function controller:search(query, callback) enqueue("search", { query }, callback) end
function controller:lookupComicID(id, callback) enqueue("lookupComicID", { id }, callback) end
function controller:resolveReadingEpisode(id, callback) enqueue("resolveReadingEpisode", { id }, callback) end
function controller:readEpisode(comic, episode, callback) enqueue("readEpisode", { comic, episode }, callback) end
function controller:downloadEpisodes(comic, episodes, callback) enqueue("downloadEpisodes", { comic, episodes }, callback) end
function controller:setFavorite(comic, favorite, callback) enqueue("setFavorite", { comic, favorite }, callback) end
function controller:quotePurchase(episode, scope, payment, callback) enqueue("quotePurchase", { episode, scope, payment }, callback) end
function controller:purchase(quote, purpose, callback) enqueue("purchase", { quote, purpose }, callback) end
function controller:reconcilePurchase(id, callback) enqueue("reconcilePurchase", { id }, callback) end
function controller:refreshWallet(callback) enqueue("refreshWallet", {}, callback) end
function controller:getDiagnostics(callback) enqueue("getDiagnostics", {}, callback) end
function controller:beginQRLogin(callback) enqueue("beginQRLogin", {}, callback) end
function controller:pollQRLogin(key, callback) enqueue("pollQRLogin", { key }, callback) end
function controller:cancelQRLogin() end
function controller:getRechargeConfigSnapshot() return copy(self.config_snapshot) end
function controller:getRechargeOrders() return copy(self.orders) end
function controller:getRechargeConfig(callback) enqueue("getRechargeConfig", {}, callback) end
function controller:createRechargeOrder(input, callback, token) enqueue("createRechargeOrder", { input, token }, callback) end
function controller:refreshRechargeOrder(id, callback) enqueue("refreshRechargeOrder", { id }, callback) end
function controller:clearAutomaticCache() self.storage.automatic_bytes = 0; return { freed_bytes = 36 * 1024 * 1024 } end
function controller:pauseJob() return true end
function controller:resumeJob() return true end
function controller:cancelJob() return true end
function controller:canRefreshDownloadSources() return true end
function controller:canReplaceDownloadVersion() return true end
function controller:refreshDownloadSources(id, callback) enqueue("refreshDownloadSources", { id }, callback) end
function controller:replaceDownloadVersion(id, callback) enqueue("replaceDownloadVersion", { id }, callback) end
local screens = Screens.new{ controller = controller }
local function pending(method)
    for _, request in ipairs(controller.waiting) do if request.method == method then return request end end
    error("No synthetic callback is waiting for " .. method)
end
local function finish(method, value, error_value)
    local request = pending(method)
    for index, item in ipairs(controller.waiting) do if item == request then table.remove(controller.waiting, index); break end end
    request.callback(copy(value), copy(error_value)); return request
end
local function callCount(method)
    local count = 0; for _, request in ipairs(controller.calls) do if request.method == method then count = count + 1 end end; return count
end
local function activate(item)
    assert(item and item.enabled ~= false and type(item.callback) == "function", "The native control is not actionable")
    item.callback()
end
local function press(message) activate(button(screens.widget, message)) end
local function pressDialog(message) activate(button(assert(screens.dialog), message)) end
local function dialogActionWithText(message)
    local function find()
        return button(screens.dialog, message, true) or visit(screens.dialog, function(item)
            return item.text == nil and type(item.callback) == "function" and hasText(item, message)
        end)[1]
    end
    local found = find()
    for _page = 2, screens.dialog.pages or 1 do
        if found then break end
        screens.dialog:onNextPage(); UIManager:forceRePaint(); found = find()
    end
    return assert(found, "The native flow action was not found: " .. message)
end
local function closeDialog() screens:_closeDialog() end
local function capture(name, options)
    options = options or {}
    UIManager:forceRePaint()
    local top = screens.dialog or assert(screens.widget)
    local size = rectangle(top)
    check(name .. "_native_surface_fits", within(size), size)
    if options.fullpage then
        check(name .. "_replaces_the_entire_page", math.abs(size.w - width) <= 1 and math.abs(size.h - height) <= 1, size)
    end
    local bounds, overflow = true, {}
    if top.content then
        local content_size = top.content:getSize()
        check(name .. "_content_fits_framebuffer", content_size.w <= width + 1 and content_size.h <= height + 1,
            { w = content_size.w, h = content_size.h })
    end
    for _, item in ipairs(allButtons(top)) do
        local box = rectangle(item)
        if box.w > 0 and box.h > 0 and not within(box) then
            bounds = false; overflow[#overflow + 1] = { label = item.text, bounds = box }
        end
    end
    check(name .. "_native_controls_fit", bounds, #overflow > 0 and overflow or nil)
    if options.fullpage then
        check(name .. "_uses_native_flow_page", top.fullpage == true and top.header and top.body and top.footer ~= nil)
        if top.header and top.footer then
            check(name .. "_flow_header_is_116dp", math.abs(top.header:getSize().h - W.dp(116)) <= 1)
            check(name .. "_flow_footer_is_108dp", math.abs(top.footer:getSize().h - W.dp(108)) <= 1)
            local has_tab = false
            for _, item in ipairs(allButtons(top.footer)) do
                for _, label in ipairs({ "Bookshelf", "Bookstore", "Search", "Downloads" }) do
                    if normalize(item.text) == T(label) then has_tab = true end
                end
            end
            check(name .. "_flow_has_no_primary_tab_navigation", not has_tab)
        end
    end
    local path = output_dir .. "/" .. name .. ".png"
    Device.screen.bb:writePNG(path)
    report.screenshots[#report.screenshots + 1] = { name = name, file = name .. ".png", route = screens.route,
        fullpage = options.fullpage == true, native_framebuffer = true }
end
local function chrome(name, active)
    UIManager:forceRePaint()
    local content = assert(screens.widget).content
    local header = screens.header or content[1]
    local navigation = screens.navigation or content[#content]
    local header_box, nav_box = rectangle(header), rectangle(navigation)
    check(name .. "_header_is_116dp", math.abs(header_box.h - W.dp(116)) <= 1, header_box)
    local strip = assert(header.status_strip, "The native header must expose its status strip")
    local title_bar = assert(header.title_bar, "The native header must expose its title bar")
    check(name .. "_status_strip_is_40dp", strip:getSize().h == W.dp(40))
    check(name .. "_title_bar_is_75dp_above_rule", math.abs(title_bar:getSize().h - W.dp(75)) <= 1)
    check(name .. "_navigation_is_88dp", math.abs(nav_box.h - W.dp(88)) <= 1, nav_box)
    check(name .. "_header_spans_the_screen", header_box.w == width and math.abs(header_box.y) <= 1, header_box)
    check(name .. "_status_exposes_device_time", shownText(header):match("%d%d:%d%d") ~= nil)
    local expected = { T("Bookshelf"), T("Bookstore"), T("Search"), T("Downloads") }
    local entries = screens.navigation_buttons or {}
    -- Native HorizontalGroup does not store its paint origin. Its buttons do.
    if entries[1] then
        nav_box.x = entries[1].dimen.x
        nav_box.y = entries[1].dimen.y - W.dp(6)
    end
    check(name .. "_navigation_native_cells_end_at_screen_bottom", nav_box.w == width
        and math.abs(nav_box.y + nav_box.h - height) <= 1, nav_box)
    check(name .. "_navigation_has_four_ordered_cells", #entries == 4)
    for index, item in ipairs(entries) do
        check(name .. "_navigation_cell_" .. index, item.text == expected[index]
            and item.selected == (index == active), { text = item.text, selected = item.selected })
    end
end
local function cardsGeometry(name)
    UIManager:forceRePaint()
    local rows, columns, seen = {}, {}, {}
    local safe, order = true, true
    local previous
    for _, card in ipairs(screens.cards or {}) do
        local box = rectangle(card)
        if not within(box) then safe = false end
        rows[box.y], columns[box.x] = true, true
        if previous and (box.y < previous.y or box.y == previous.y and box.x <= previous.x) then order = false end
        previous = box
        if seen[tostring(card.comic.id)] then safe = false end
        seen[tostring(card.comic.id)] = true
        if card.ges_events and card.ges_events.TapSelect then
            check(name .. "_card_" .. tostring(card.comic.id) .. "_tap_bounds_follow_paint",
                card.ges_events.TapSelect[1].range == card.dimen and card.dimen.w == box.w and card.dimen.h == box.h)
        end
    end
    local row_count, column_count = 0, 0
    for _ in pairs(rows) do row_count = row_count + 1 end
    for _ in pairs(columns) do column_count = column_count + 1 end
    check(name .. "_cards_are_unique_and_in_bounds", safe)
    check(name .. "_focus_matches_visual_order", order)
    return column_count, row_count
end
local function footer(name, left, right)
    UIManager:forceRePaint()
    local first, last = button(assert(screens.dialog), left), button(screens.dialog, right)
    local a, b = rectangle(first), rectangle(last)
    check(name .. "_footer_action_order", a.x < b.x and math.abs(a.y - b.y) <= 1, { left = a, right = b })
    check(name .. "_footer_action_height_is_68dp", a.h == W.dp(68) and b.h == W.dp(68), { left = a.h, right = b.h })
    check(name .. "_footer_is_below_body", math.min(a.y, b.y) >= height - W.dp(108) - 1)
end
local function neutralFocus(name, paid_label)
    local dialog = assert(screens.dialog)
    local item = dialog.getFocusItem and dialog:getFocusItem()
    if not item and dialog.selected and dialog.layout then
        item = dialog.layout[dialog.selected.y] and dialog.layout[dialog.selected.y][dialog.selected.x]
    end
    local label = item and normalize(item.text)
    check(name .. "_initial_focus_is_nonpaying", label == T("Cancel") or label == T("Close")
        or label == T("Back to catalog") or label == T("Back to edit"), { label = label })
    check(name .. "_payment_is_not_an_enter_default", not button(dialog, paid_label).is_enter_default)
end
local function scenario(name, callback)
    local ok, failure = xpcall(callback, debug.traceback)
    report.scenarios[#report.scenarios + 1] = { name = name, completed = ok, error = not ok and tostring(failure) or nil }
    check(name .. "_scenario_completed", ok, not ok and tostring(failure) or nil)
    pcall(screens.close, screens)
    controller.waiting, controller.orders, controller.purchases = {}, {}, {}
    controller.sync = { has_cache = true, can_sync = true, authenticated = true, last_synced_at = os.time() - 600 }
    controller.signed_in, controller.auth_state, controller.hide_episodes = true, nil, nil
    controller.view, controller.jobs = { help_seen = true, sort = "recent" }, copy(base_jobs)
    controller.feed_stale, controller.feed_pages = false, 1
    populate(24, true)
    screens = Screens.new{ controller = controller }
end

scenario("bookshelf", function()
    screens:showLibrary(); capture("bookshelf-resume"); chrome("bookshelf", 1)
    local columns, rows = cardsGeometry("bookshelf-resume")
    check("bookshelf_hero_is_most_recent_local_progress", screens.resume_comic and screens.resume_comic.id == "1")
    local unique_hero = true
    for _, card in ipairs(screens.cards) do if card.comic.id == "1" then unique_hero = false end end
    check("bookshelf_hero_is_not_repeated_in_grid", unique_hero)
    if scribe then check("scribe_bookshelf_has_five_columns_and_two_rows", columns == 5 and rows == 2 and #screens.cards == 10,
        { columns = columns, rows = rows, cards = #screens.cards }) end
    local pager = assert(screens.pagination)
    local retired_card = assert(screens.cards[1])
    local old_page = screens.page
    activate(pager.next); capture("bookshelf-page-two")
    check("bookshelf_pager_tap_changes_page", screens.page == old_page + 1)
    local before_retired = #controller.calls
    retired_card.callback()
    check("bookshelf_pagination_retires_old_card_callback", #controller.calls == before_retired)
    screens.widget:onPreviousPage(); check("bookshelf_previous_page_key_changes_page", screens.page == old_page)
    screens.widget:onNextPage(); check("bookshelf_next_page_key_changes_page", screens.page == old_page + 1)
    screens.widget:onSwipePage(nil, { direction = "east" })
    check("bookshelf_swipe_previous_changes_page", screens.page == old_page)
    screens:_bookshelfFilter(); capture("bookshelf-filter")
    pressDialog("Updated"); capture("bookshelf-filtered")
    check("bookshelf_filter_applies_explicitly", screens.filter == "updated" and screens.page == 1)
    screens:_bookshelfSort(); capture("bookshelf-sort"); closeDialog()
    screens:_more(); capture("bookshelf-more"); closeDialog()
    controller.sync.offline = true; screens:refresh(); capture("bookshelf-offline")
    check("bookshelf_offline_status_is_visible", hasText(screens.widget.content[1], "Offline"))
    populate(24, false); screens.filter = "all"; screens:refresh(); capture("bookshelf-no-resume")
    columns, rows = cardsGeometry("bookshelf-no-resume")
    check("bookshelf_without_local_progress_has_no_resume", screens.resume_comic == nil)
    if scribe then check("scribe_bookshelf_without_resume_keeps_five_by_two", columns == 5 and rows == 2 and #screens.cards == 10,
        { columns = columns, rows = rows, cards = #screens.cards }) end
    populate(0, false); controller.sync.offline = false; screens:refresh(); capture("bookshelf-empty")
    controller.sync.has_cache, controller.sync.syncing = false, true; screens:refresh(); capture("bookshelf-first-sync")
    controller.sync.syncing, controller.sync.error = false, { kind = "network" }; screens:refresh(); capture("bookshelf-sync-error")
    controller.signed_in, controller.sync.authenticated = false, false; screens:refresh(); capture("bookshelf-signed-out")
end)

scenario("bookstore", function()
    screens:showBookstore(); capture("bookstore-default"); chrome("bookstore", 2)
    local columns, rows = cardsGeometry("bookstore-default")
    if scribe then check("scribe_bookstore_is_four_by_three", columns == 4 and rows == 3 and #screens.cards == 12,
        { columns = columns, rows = rows, cards = #screens.cards }) end
    screens:_bookstoreCategoryPicker(); capture("bookstore-categories"); closeDialog()
    controller.feed_items, controller.feed_stale = {}, true
    screens:showBookstore(); capture("bookstore-loading")
    finish("refreshBookstore", nil, { kind = "network" }); capture("bookstore-error")
    controller.feed_stale = false; screens:showBookstore(); capture("bookstore-empty")
end)

scenario("search", function()
    screens:showSearch(); capture("search-history"); chrome("search", 3)
    screens:_runSearch("Original"); capture("search-loading")
    finish("search", controller.comics); capture("search-results")
    check("search_has_results_and_local_pagination", screens.search_results and #screens.search_results == 24 and screens.pages > 1)
    screens:_searchFilter(); capture("search-filter"); closeDialog()
    screens:_runSearch("Missing"); finish("search", {}); capture("search-empty-results")
    screens:_runSearch("Network"); finish("search", nil, { kind = "network" }); capture("search-error")
end)

scenario("catalog", function()
    screens:showLibrary(); screens:showComic("1"); finish("refreshComic", controller.comics[1])
    capture("catalog-default"); chrome("catalog", 1)
    local visible = assert(screens.catalog_visible_items)
    if scribe then check("scribe_catalog_has_ten_chapter_rows", #visible == 10, { rows = #visible }) end
    local axes, aligned = {}, true
    for _, episode in ipairs(visible) do
        local row
        for _, focus_row in ipairs(screens.focus) do
            for _, item in ipairs(focus_row) do if item.text == episode.title and item.hold_callback then row = item end end
        end
        if row then
            local title_widget = visit(row, function(item) return item.text == episode.title and not item.callback end)[1]
            local number_widget = visit(row, function(item) return item.text == tostring(episode.order) and not item.callback end)[1]
            if title_widget and number_widget then
                local number_axis, title_axis = rectangle(number_widget).x, rectangle(title_widget).x
                if axes.number and (axes.number ~= number_axis or axes.title ~= title_axis) then aligned = false end
                axes.number, axes.title = number_axis, title_axis
                check("catalog_" .. episode.id .. "_number_precedes_title", number_axis < title_axis)
                check("catalog_" .. episode.id .. "_touch_bounds_match_row", row.dimen.h == row:getSize().h
                    and row.ges_events.TapSelect[1].range == row.dimen)
            else aligned = false end
        else aligned = false end
    end
    check("catalog_number_and_title_columns_are_aligned", aligned and axes.number ~= nil, axes)
    local common_offsets, offset_aligned = nil, true
    local actual_rows = screens.catalog_rows or {}
    check("catalog_exposes_actual_native_rows", #actual_rows == #visible)
    for _, chapter in ipairs(actual_rows) do
        local offsets, order = chapter.chapter_column_offsets, chapter.chapter_column_order
        local columns, total = chapter.chapter_columns, 0
        if not offsets or not order or not columns then offset_aligned = false
        else
            for _, key in ipairs(order) do
                if offsets[key] ~= total or columns[key] <= 0 then offset_aligned = false end
                if common_offsets and common_offsets[key] ~= offsets[key] then offset_aligned = false end
                total = total + columns[key]
            end
            common_offsets = offsets
            check("catalog_" .. chapter.episode.id .. "_columns_fill_row", math.abs(total - screens.width) <= 1, { total = total, width = screens.width })
            check("catalog_" .. chapter.episode.id .. "_has_separate_status_axes", offsets.title < offsets.progress
                and offsets.progress < offsets.access and offsets.access < offsets.storage and offsets.storage < offsets.actions)
        end
    end
    check("catalog_all_status_columns_share_axes", offset_aligned and common_offsets ~= nil, common_offsets)
    local old_page = screens.page; screens.widget:onNextPage(); capture("catalog-page-two")
    check("catalog_page_key_changes_page", screens.page == old_page + 1)
    screens:_catalogDetails(controller.comics[1]); capture("catalog-overview-sheet"); closeDialog()
    screens:_chapterActions(controller.comics[1], controller.episodes[6]); capture("catalog-locked-actions"); closeDialog()
    screens.selecting = true; screens:_render(); capture("catalog-download-selection")
    check("catalog_selection_rejects_online_only_and_locked_chapters", not Model.downloadable(controller.episodes[4])
        and not Model.downloadable(controller.episodes[6]))
    screens.selecting, controller.hide_episodes = false, true; screens:_render(); capture("catalog-empty")
end)

scenario("downloads", function()
    screens:showDownloads(); capture("downloads-mixed-states"); chrome("downloads", 4)
    screens:_downloadRecovery(controller.jobs[3]); capture("download-recovery", { fullpage = true }); closeDialog()
    controller.jobs = {}; screens:refresh(); capture("downloads-empty")
end)

scenario("account-settings", function()
    screens:showAccount(); capture("account-signed-in"); chrome("account", nil)
    screens:_storageSettings(); capture("storage-settings", { fullpage = true }); closeDialog()
    screens:_readerDefaults(); capture("reader-defaults", { fullpage = true })
    activate(dialogActionWithText("Long strip"))
    activate(dialogActionWithText("Right to left (manga)"))
    check("reader_default_controls_persist_exact_enums", controller.settings.reading_mode == "strip"
        and controller.settings.reading_direction == "rtl")
    capture("reader-defaults-selected", { fullpage = true }); closeDialog()
    controller.signed_in, controller.auth_state = false, "reauth_required"; screens:refresh(); capture("account-expired")
    controller.auth_state = nil; screens:refresh(); capture("account-signed-out")
end)

local quote = { id = "synthetic-quote", episode_id = "6", comic_id = "1", episode_ids = { "6" },
    scope = { kind = "single", order = 1 }, payment = { method = "coin" }, method = "coin", amount = 20, balance = 80,
    can_afford = true, submittable = true, fingerprint = "synthetic-handoff-quote",
    expected_access = { ["6"] = { access = "owned" } },
    scopes = { { kind = "single" }, { kind = "batch", batch_limit = 3 } },
    payments = { { method = "coin", available = true }, { method = "coupon", available = true } } }
scenario("purchase", function()
    screens:showComic("1"); finish("refreshComic", controller.comics[1])
    screens:_purchaseFor(controller.comics[1], controller.episodes[6]); capture("purchase-loading", { fullpage = true })
    finish("quotePurchase", quote); capture("purchase-confirmation", { fullpage = true })
    local confirm_label = string.format(T("Confirm purchase · %s %s"), "20", T("coins"))
    neutralFocus("purchase", confirm_label)
    footer("purchase-confirmation", "Cancel", confirm_label)
    local count_before = callCount("purchase")
    local confirm = button(screens.dialog, confirm_label)
    activate(confirm); capture("purchase-submitting", { fullpage = true })
    confirm.callback()
    check("purchase_duplicate_confirmation_sends_one_synthetic_request", callCount("purchase") == count_before + 1)
    local intent = { id = "synthetic-purchase-1", state = "outcome_unknown", comic_id = "1", episode_ids = { "6" },
        quote = copy(quote), purpose = "read", transaction_evidence = "none", created_at = os.time() }
    controller.purchases = { intent }; finish("purchase", intent); capture("purchase-unknown", { fullpage = true })
    check("purchase_unknown_result_has_no_confirmation_button", button(screens.dialog, confirm_label, true) == nil)
    local quote_count = callCount("quotePurchase")
    pressDialog("Refresh result")
    check("purchase_unknown_result_reconciles_without_resubmit", callCount("purchase") == count_before + 1
        and callCount("quotePurchase") == quote_count and pending("reconcilePurchase").args[1] == intent.id)
    intent.state, intent.transaction_evidence, intent.access_confirmed_at = "access_confirmed", "server_accepted", os.time()
    controller.purchases = {}; finish("reconcilePurchase", intent); capture("purchase-confirmed", { fullpage = true })
    check("purchase_access_confirmation_waits_for_explicit_read", callCount("readEpisode") == 0)
    closeDialog()
    screens:_purchaseFor(controller.comics[1], controller.episodes[7])
    local unaffordable = copy(quote); unaffordable.episode_id, unaffordable.episode_ids = "7", { "7" }
    unaffordable.amount, unaffordable.balance, unaffordable.can_afford = 120, 80, false
    finish("quotePurchase", unaffordable); capture("purchase-insufficient-balance", { fullpage = true })
    check("purchase_insufficient_balance_cannot_confirm", button(screens.dialog,
        string.format(T("Confirm purchase · %s %s"), "120", T("coins")), true) == nil)
    closeDialog(); screens:_purchaseFor(controller.comics[1], controller.episodes[8])
    finish("quotePurchase", nil, { kind = "network" }); capture("purchase-quote-error", { fullpage = true })
end)

scenario("qr-sign-in", function()
    screens:showAccount(); screens:_signInWithQR(); capture("qr-loading", { fullpage = true })
    finish("beginQRLogin", { key = "synthetic-key", expires_at = os.time() + 600,
        url = "https://passport.bilibili.com/h5-app/passport/login/scan?navhide=1&qrcode_key=synthetic-key" })
    capture("qr-waiting", { fullpage = true })
    footer("qr-waiting", "Other sign-in methods", "Cancel")
    local native_qr = visit(screens.dialog, function(item) return item.image ~= nil and item.text and item.text:find("qrcode_key=", 1, true) end)
    check("qr_sign_in_uses_native_qr_image", #native_qr == 1)
    local timer = assert(screens.qr_login.timer)
    check("qr_poll_is_scheduled_without_animation", timers[timer] == 3); timer()
    finish("pollQRLogin", { status = "scanned" }); capture("qr-scanned", { fullpage = true })
    screens.qr_login.timer(); finish("pollQRLogin", { status = "expired" }); capture("qr-expired", { fullpage = true })
    check("qr_expiry_stops_polling", screens.qr_login.timer == nil)
    pressDialog("Get a new code"); finish("beginQRLogin", nil, { kind = "network" }); capture("qr-error", { fullpage = true })
end)

scenario("recharge", function()
    screens:showAccount(); screens:_openRecharge(); capture("recharge-loading", { fullpage = true })
    local config = { confirmation_token = "synthetic-config-token", channels = { "Wechat", "Ali" },
        custom_amount = { allowed = false }, options = { { amount_cents = 600, amount_yuan = "6.00", coin_amount = 600 },
            { amount_cents = 1000, amount_yuan = "10.00", coin_amount = 1000 },
            { amount_cents = 3000, amount_yuan = "30.00", coin_amount = 3000 } } }
    controller.config_snapshot = copy(config); finish("getRechargeConfig", config); capture("recharge-amounts", { fullpage = true })
    local amount_label = string.format(T("CNY %s"), "10.00")
    local amount_tile = visit(screens.dialog, function(item) return type(item.callback) == "function"
        and item.text == nil and hasText(item, amount_label) end)[1]
    activate(assert(amount_tile, "The native recharge amount tile was not found"))
    check("recharge_tile_selects_the_exact_official_amount", screens.recharge_state.amount_input == "10.00")
    capture("recharge-amount-selected", { fullpage = true })
    pressDialog("Next: review amount"); capture("recharge-confirmation", { fullpage = true })
    neutralFocus("recharge", "Create payment QR")
    local before = callCount("createRechargeOrder")
    local create = button(screens.dialog, "Create payment QR")
    activate(create); capture("recharge-creating", { fullpage = true }); create.callback()
    check("recharge_duplicate_confirmation_creates_one_synthetic_order", callCount("createRechargeOrder") == before + 1)
    local order = { id = "synthetic-order", local_id = "synthetic-order", account_key = controller.account_key,
        order_id = "900719925474099312345678901", state = "pending", amount_cents = 1000,
        code_url = "https://pay.bilibili.com/payplatform-h5/index.html?order_id=900719925474099312345678901",
        qr_validated = true, expires_at = os.time() + 600 }
    controller.orders = { order }; finish("createRechargeOrder", order); capture("recharge-payment-code", { fullpage = true })
    footer("recharge-payment-code", "Check credit", "Close")
    local code = visit(screens.dialog, function(item) return item.image ~= nil and item.text == order.code_url end)
    check("recharge_uses_native_qr_image", #code == 1)
    pressDialog("Check credit"); order.state = "unknown"; controller.orders = { order }
    finish("refreshRechargeOrder", order); capture("recharge-unknown", { fullpage = true })
    check("recharge_unknown_does_not_create_another_order", callCount("createRechargeOrder") == before + 1)
    closeDialog(); order.state, order.qr_expired = "expired", true; controller.orders = { order }
    screens:_showRechargeOrders(); capture("recharge-order-history", { fullpage = true })
    screens:_rechargeAttachOrder(screens.recharge_state, copy(order)); capture("recharge-expired", { fullpage = true })
    check("recharge_expired_code_is_not_shown", #visit(screens.dialog, function(item) return item.image ~= nil and item.text == order.code_url end) == 0)
    pressDialog("Check credit"); order.state, order.qr_expired = "credited", false
    order.history_evidence, order.credited_observed_at = { product_amount = 1000 }, os.time()
    controller.wallet = { remain_gold = 1080, remain_coupon = 2, updated_at = os.time(), stale = false }
    controller.orders = { order }
    finish("refreshRechargeOrder", order); capture("recharge-credited", { fullpage = true })
end)

UIManager.scheduleIn, UIManager.unschedule = native_schedule, native_unschedule
for _, name in ipairs(forbidden_modules) do check("production_module_remains_unloaded_" .. name:gsub("/", "_"), package.loaded[name] == nil) end
report.passed = true
for _, item in ipairs(report.assertions) do if not item.passed then report.passed = false end end
local result_file = assert(io.open(output_dir .. "/scribe-handoff-result.json", "wb"))
result_file:write(json.encode(report, { pretty = true })); result_file:close()
print(json.encode({ passed = report.passed, assertions = #report.assertions, screenshots = #report.screenshots,
    width = width, height = height, language = report.language }))
os.exit(report.passed and 0 or 1)
