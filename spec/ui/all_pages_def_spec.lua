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
local report = { spec = "native-all-pages-def", width = width, height = height, language = arg[3] or "zh_CN",
    artboards = { "D1", "D2", "D3", "D4", "F1", "F2", "F3", "F4" },
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
    require("spec/ui/fidelity_geometry").check(screens, name, W, check, report)
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

local function everyDialogPage(name, design_id)
    local dialog = assert(screens.dialog)
    local pages = dialog.pages or 1
    for page = 1, pages do
        if page > 1 then screens.dialog:onNextPage() end
        capture(name .. (page > 1 and "-page-" .. page or ""), { fullpage = screens.dialog.fullpage })
        report.screenshots[#report.screenshots].design_id = design_id
    end
    for page = pages - 1, 1, -1 do
        screens.dialog:onPreviousPage()
        capture(name .. "-return-page-" .. page, { fullpage = screens.dialog.fullpage })
        report.screenshots[#report.screenshots].design_id = design_id
    end
    if pages > 1 then check(name .. "_returns_to_first_native_page", screens.dialog.page == 1) end
end
local function captured(name, design_id, options)
    capture(name, options)
    report.screenshots[#report.screenshots].design_id = design_id
end
local function measure(name, actual, expected, tolerance)
    if not scribe then return end
    report.fidelity_measurements = report.fidelity_measurements or {}
    report.fidelity_measurements[#report.fidelity_measurements + 1] = {
        metric = name, actual_px = actual, design_px = expected, tolerance_px = tolerance or 1 }
    check(name, math.abs(actual - expected) <= (tolerance or 1), { actual = actual, expected = expected })
end
function controller:getDownloadEstimate(_comic_id, ids)
    if self.estimate_unknown then return { total_chapters = #ids, known_chapters = 0, estimated = true } end
    return { bytes = #ids * 16 * 1024 * 1024, total_chapters = #ids, known_chapters = #ids, estimated = true,
        descriptors = copy(self.estimate_descriptors or {}) }
end
function controller:removeDownload(id, callback) enqueue("removeDownload", { id }, callback) end
function controller:readDownload(id, callback) enqueue("readDownload", { id }, callback) end
function controller:cancelSourceRefresh() return true end
function controller:cancelVersionReplacement() return true end

scenario("D1-D4", function()
    local fixture = copy(controller.episodes)
    for index = 1, 32 do
        controller.episodes[index].access = index <= 20 and "owned" or "locked"
        controller.episodes[index].offline_allowed = index <= 20
    end
    controller.episodes[4].access, controller.episodes[4].expires_at = "temporary", os.time() + 86400 * 2
    controller.episodes[4].offline_allowed = false
    controller.comics[1].tags = { "Fantasy", "Adventure" }
    controller.comics[1].reading_position = { episode_id = "12", index = 8, revision = "synthetic-r1" }
    controller.comics[1].current_episode_id = "12"
    screens:showLibrary(); screens:showComic("1"); finish("refreshComic", controller.comics[1])
    captured("D1-default", "D1"); chrome("D1", 1)
    local cover = visit(screens.widget, function(item) return item.outer_width == W.dp(114) and item.outer_height == W.dp(152) end)[1]
    check("D1_native_official_cover_slot", cover ~= nil)
    if cover then
        local box = rectangle(cover)
        measure("D1_cover_x", box.x, W.dp(56)); measure("D1_cover_y", box.y, W.dp(144))
        measure("D1_cover_width", box.w, W.dp(114)); measure("D1_cover_height", box.h, W.dp(152))
    end
    check("D1_catalog_opens_on_current_page", screens.page == 2 or not scribe, screens.page)
    screens:_catalogFilter(); everyDialogPage("D1-filter-menu", "D1"); closeDialog()
    for _, catalog_row in ipairs(screens.catalog_rows) do
        measure("D1_row_height_" .. catalog_row.episode.id, catalog_row:getSize().h, W.dp(64))
        for _, focus_item in ipairs(catalog_row.catalog_focus or {}) do
            if focus_item.current_marker then
                local box = rectangle(focus_item)
                check("D1_current_marker_reaches_screen_edge", Device.screen.bb:getPixel(0, box.y + math.floor(box.h / 2)):getR() == 0x11)
            end
        end
    end
    for _, filter in ipairs({ "unread", "readable", "downloaded" }) do
        screens.filter, screens.page = filter, 1; screens:_render(); captured("D1-filter-" .. filter, "D1")
        for _, episode in ipairs(screens.catalog_visible_items) do
            check("D1_" .. filter .. "_episode_" .. episode.id,
                filter == "unread" and Model.reading(episode, screens.catalog_current_id) == T("Unread")
                or filter == "readable" and (Model.readable(episode) or Model.storage(episode) == T("Downloaded"))
                or filter == "downloaded" and Model.storage(episode) == T("Downloaded"))
        end
    end
    screens.filter, screens.page, screens.descending = "all", 1, true
    screens:_render(); captured("D1-descending", "D1")
    check("D1_descending_preserves_status_and_order", screens.catalog_visible_items[1].order > screens.catalog_visible_items[#screens.catalog_visible_items].order)
    screens.descending, screens.selecting, screens.page = false, true, 1
    screens.selected = { ["1"] = true, ["2"] = true, ["12"] = true, ["21"] = true }
    screens:_render(); captured("D2-cross-page-selection", "D2")
    if scribe then check("D2_ten_rows_match_design", #screens.catalog_visible_items == 10) end
    check("D2_locked_selection_is_removed", screens.selected["21"] == nil)
    check("D2_cross_page_selection_and_estimate", screens.navigation.selection_detail:find(Model.bytes(48 * 1024 * 1024), 1, true) ~= nil)
    check("D2_no_overview_in_selecting_header", not hasText(screens.widget, "Overview ›"))
    measure("D2_action_bar_height", screens.navigation:getSize().h, W.dp(108))
    screens:_catalogSelectionMenu(); everyDialogPage("D2-selection-scope", "D2"); closeDialog()
    screens:_catalogSelected(); everyDialogPage("D2-selected-review", "D2"); closeDialog()
    local selected_before = copy(screens.selected)
    screens.widget:onNextPage(); captured("D2-selection-next-page", "D2")
    check("D2_selection_survives_native_pagination", screens.selected["1"] == selected_before["1"] and screens.selected["12"] == true)
    controller.estimate_unknown = true; screens:_render(); captured("D2-unknown-size", "D2")
    check("D2_unknown_size_does_not_invent_mb", screens.navigation.selection_detail:find(T(" · Size unknown"), 1, true) ~= nil)
    controller.estimate_unknown = nil
    screens.selecting, screens.selected, screens.page = false, {}, 1; screens:_render()
    screens:_more(); everyDialogPage("D1-more-menu", "D1"); closeDialog()
    screens:_chapterActions(controller.comics[1], controller.episodes[21]); captured("D3-locked", "D3"); closeDialog()
    screens:_chapterActions(controller.comics[1], controller.episodes[2]); captured("D3-readable", "D3"); closeDialog()
    screens:_chapterActions(controller.comics[1], controller.episodes[4]); captured("D3-temporary", "D3"); closeDialog()
    UIManager:forceRePaint()
    local catalog_underlay = Device.screen.bb:copy()
    screens:_catalogJump(); captured("D4-empty-query", "D4")
    check("D4_empty_input_does_not_enable_locate", screens.dialog.locate_button.enabled == false)
    closeDialog(); screens:_catalogJump("12"); captured("D4-number-match", "D4")
    local jump = screens.dialog
    measure("D4_dialog_left", rectangle(jump.dialog_frame).x, W.dp(56))
    measure("D4_dialog_top", rectangle(jump.dialog_frame).y, W.dp(176))
    measure("D4_input_height", jump.input_field:getSize().h, W.dp(70))
    jump:setInputText("horizon"); captured("D4-title-many-results", "D4")
    if jump.results_pages > 1 then jump:onNextPage(); captured("D4-title-results-next-page", "D4") end
    local previous_frame = rectangle(jump.dialog_frame)
    check("D4_title_matching_uses_all_catalog_pages", #jump.matches == 32)
    jump:setInputText("unmatched synthetic title"); captured("D4-no-match", "D4")
    check("D4_no_match_disables_locate", #jump.matches == 0 and jump.locate_button.enabled == false)
    local current_frame, restored = rectangle(jump.dialog_frame), true
    for y = current_frame.y + current_frame.h + 1, math.min(height - 1, previous_frame.y + previous_frame.h - 1), math.max(1, W.dp(12)) do
        for x = previous_frame.x + W.dp(4), math.min(width - 1, previous_frame.x + previous_frame.w - W.dp(4)), math.max(1, W.dp(12)) do
            if Device.screen.bb:getPixel(x, y):getR() ~= catalog_underlay:getPixel(x, y):getR() then restored = false end
        end
    end
    check("D4_shrinking_results_restores_catalog_underlay_pixels", restored)
    catalog_underlay:free()
    jump:setInputText("12"); jump:onShowKeyboard(); if not jump:isKeyboardVisible() then jump:onShowKeyboard() end
    captured("D4-native-keyboard", "D4")
    check("D4_uses_native_keyboard", jump._input_widget.keyboard ~= nil and jump:isKeyboardVisible())
    closeDialog()
    screens:_catalogDetails(controller.comics[1]); everyDialogPage("D1-overview", "D1"); closeDialog()
    controller.hide_episodes = true; screens:_render(); captured("D1-empty-catalog", "D1")
    screens.filter = "downloaded"; screens:_render(); captured("D1-filter-empty", "D1")
    controller.episodes = fixture
end)

scenario("F1-F4", function()
    controller.storage = { pinned_bytes = 690 * 1024 * 1024, automatic_bytes = 312 * 1024 * 1024,
        free_bytes = 5800 * 1024 * 1024, capacity_bytes = 8192 * 1024 * 1024 }
    controller.jobs[3].error = { kind = "content_changed" }
    for _, job in ipairs(controller.jobs) do job.bytes = 21 * 1024 * 1024 end
    for index = 5, 8 do
        controller.jobs[#controller.jobs + 1] = { id = "complete-" .. index, kind = "episode_download", comic_id = tostring(index),
            episode_id = "3", revision = "synthetic-r1", state = "complete", completed = 24, total = 24, bytes = 42 * 1024 * 1024 }
    end
    screens:showDownloads(); captured("F1-all-groups", "F1"); chrome("F1", 4)
    local ready_row = button(screens.widget, controller.comics[4].title, true)
    local first_download_page = screens.page
    while not ready_row and screens.page < screens.pages do
        screens.widget:onNextPage(); captured("F1-offline-groups-page-" .. screens.page, "F1")
        ready_row = button(screens.widget, controller.comics[4].title, true)
    end
    assert(ready_row, "An offline comic must remain reachable through native pagination")
    local comic_label = visit(ready_row, function(item) return item.text == controller.comics[4].title and item.label_widget ~= nil end)[1]
    local range_label = visit(ready_row, function(item) return item.text == screens:_downloadChapterRange({ controller.jobs[4] }) and item.label_widget ~= nil end)[1]
    if comic_label and range_label then
        measure("F1_offline_range_gap", rectangle(range_label).x - rectangle(comic_label).x - comic_label:getSize().w, W.dp(16))
    else check("F1_offline_labels_expose_native_geometry", false) end
    while screens.page > first_download_page do
        screens.widget:onPreviousPage(); captured("F1-return-page-" .. screens.page, "F1")
    end
    local job_heights = {}
    for _, job in ipairs(controller.jobs) do job_heights[#job_heights + 1] = { id = job.id, height = screens:_jobRow(job, true, {}):getSize().h } end
    check("F1_density_measurements", true, { body_height = screens.body_height, header_height = screens.download_header:getSize().h,
        job_heights = job_heights, ranges = screens.page_ranges })
    if scribe and report.language == "zh_CN" then check("F1_design_eight_tasks_fit_one_page", screens.pages == 1, { pages = screens.pages }) end
    for _, filter in ipairs({ "active", "attention", "complete" }) do
        screens.filter, screens.page = filter, 1; screens:_render(); captured("F1-filter-" .. filter, "F1")
    end
    screens.filter, screens.page = "all", 1; screens:_render()
    screens:_downloadFilter(); everyDialogPage("F1-filter-menu", "F1"); closeDialog()
    local job_actions = screens:_downloadActions(controller.jobs[1])
    activate(assert(job_actions[2])); everyDialogPage("F1-more-menu", "F1"); closeDialog()
    local failed = controller.jobs[3]
    screens:_downloadRecovery(failed); everyDialogPage("F2-content-changed", "F2")
    check("F2_unknown_new_version_does_not_promise_old_image_count", screens.dialog.download_text:find(T("All images will be downloaded, using additional space and network data."), 1, true) ~= nil)
    check("F2_content_changed_has_new_version_and_remove", button(screens.dialog, "Redownload as new version", true) ~= nil
        or screens.dialog.pages > 1)
    closeDialog()
    controller.estimate_descriptors = { [tostring(failed.episode_id)] = { revision = "synthetic-new-version", total_pages = 32 } }
    screens:_downloadRecovery(failed); everyDialogPage("F2-known-new-version", "F2")
    check("F2_new_version_uses_verified_new_image_count", screens.dialog.download_text:find(string.format(T("Download all %d images%s. A separate new copy starts from the beginning. This copy's saved images and reading position stay separate."),
        32, string.format(T(", about %s"), Model.bytes(16 * 1024 * 1024))), 1, true) ~= nil)
    closeDialog(); controller.estimate_descriptors = nil
    for _, kind in ipairs({ "network", "authentication", "access", "storage", "busy", "unsupported_image_size",
        "unknown_history", "unverified_position", "source_unavailable", "source_refresh_interrupted",
        "version_replacement_interrupted", "reference_changed", "stale_source_refresh", "stale_version_replacement" }) do
        failed.error = { kind = kind }
        screens:_downloadRecovery(failed); everyDialogPage("F2-" .. kind, "F2"); closeDialog()
    end
    failed.error = { kind = "content_changed" }
    controller.jobs[#controller.jobs + 1] = { id = "retained", comic_id = "1", episode_id = "2", revision = "old-r1",
        state = "paused", completed = 14, total = 32, bytes = 21 * 1024 * 1024, payload = { replaced_by = "running" } }
    local retained = controller.jobs[#controller.jobs]
    screens:_render(); captured("F1-retained-version", "F1")
    screens:_downloadRecovery(retained); everyDialogPage("F2-retained-version", "F2"); closeDialog()
    for _, kind in ipairs({ "network", "storage", "authentication" }) do
        screens:_downloadRecovery(retained, { kind = kind }); everyDialogPage("F2-retained-" .. kind, "F2")
        local all = screens.dialog.download_text
        check("F2_retained_" .. kind .. "_has_no_dead_resume_option", all:find(T("Retry download"), 1, true) == nil
            and all:find(T("Storage is ready; retry download"), 1, true) == nil and all:find(T("Retry with current sign-in"), 1, true) == nil)
        closeDialog()
    end
    controller.jobs[2].payload = { source_refresh = { stage = "verify", checked = 5, total = 12 } }
    screens:_render(); captured("F1-source-verification", "F1")
    controller.jobs[2].payload = { version_replacement = { stage = "index" } }
    screens:_render(); captured("F1-version-preparation", "F1")
    controller.jobs[2].payload = nil
    screens:_downloadComicCopies("4"); everyDialogPage("F1-offline-comic-copies", "F1"); closeDialog()
    screens:_confirmSourceRefresh(failed); everyDialogPage("F2-source-refresh-confirmation", "F2")
    local revision = failed.revision
    local obsolete_refresh = button(screens.dialog, "Refresh image sources").callback
    failed.revision = "synthetic-new-revision"
    obsolete_refresh()
    check("F2_stale_revision_cannot_refresh_new_sources", callCount("refreshDownloadSources") == 0 and screens.dialog == nil)
    failed.revision = revision
    screens:_confirmVersionReplacement(failed); everyDialogPage("F2-version-replacement-confirmation", "F2")
    local obsolete_replace = button(screens.dialog, "Redownload as new version").callback
    failed.revision = "synthetic-new-revision"
    obsolete_replace()
    check("F2_stale_revision_cannot_replace_new_version", callCount("replaceDownloadVersion") == 0 and screens.dialog == nil)
    failed.revision = revision
    screens:_confirmRemoveDownload(controller.jobs[4]); captured("F3-remove-normal", "F3")
    local remove = button(screens.dialog, "Remove download")
    measure("F3_dialog_left", rectangle(screens.dialog.frame).x, W.dp(115))
    measure("F3_dialog_top", rectangle(screens.dialog.frame).y, W.dp(420))
    measure("F3_button_height", remove:getSize().h, W.dp(66))
    local stale = remove.callback; controller.jobs[4].revision = "new-revision"
    stale()
    check("F3_stale_revision_cannot_remove_replacement", callCount("removeDownload") == 0 and screens.dialog == nil)
    screens:_confirmRemoveDownload(retained); captured("F3-remove-retained", "F3"); closeDialog()
    failed.payload = { source_refresh = { stage = "verify", checked = 5, total = 24 } }
    screens:_confirmRemoveDownload(failed); captured("F3-remove-verifying", "F3"); closeDialog()
    controller.jobs = {}; controller.storage.pinned_bytes = 0
    screens:_render(); captured("F4-empty-with-cache", "F4")
    check("F4_has_no_download_filter_tabs", not hasText(screens.widget, "In progress") and not hasText(screens.widget, "Remaining space"))
    check("F4_has_cache_and_bookshelf_actions", button(screens.widget, "Manage cache ›", true) ~= nil
        and button(screens.widget, "Choose a comic from the bookshelf", true) ~= nil)
    controller.storage.automatic_bytes = 0; screens:_render(); captured("F4-empty-no-cache", "F4")
end)

UIManager.scheduleIn, UIManager.unschedule = native_schedule, native_unschedule
for _, name in ipairs(forbidden_modules) do check("production_module_remains_unloaded_" .. name:gsub("/", "_"), package.loaded[name] == nil) end
report.passed = true
for _, item in ipairs(report.assertions) do if not item.passed then report.passed = false end end
local result_file = assert(io.open(output_dir .. "/all-pages-def-result.json", "wb"))
result_file:write(json.encode(report, { pretty = true })); result_file:close()
print(json.encode({ passed = report.passed, assertions = #report.assertions, screenshots = #report.screenshots,
    width = width, height = height, language = report.language }))
os.exit(report.passed and 0 or 1)
