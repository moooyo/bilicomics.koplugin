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
local report = { spec = "native-all-pages-ghi", width = width, height = height, language = arg[3] or "zh_CN",
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
    local native_hits = visit(top, function(item) return type(item.callback) == "function"
        and type(item.getSize) == "function" and item.dimen ~= nil end)
    local hits_fit = true
    for _, item in ipairs(native_hits) do
        local hit = rectangle(item)
        if hit.w > 0 and hit.h > 0 and not within(hit) then hits_fit = false end
    end
    check(name .. "_native_tap_targets_fit", hits_fit, { targets = #native_hits })
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
    while #UIManager._window_stack > 0 do UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget) end
    controller.waiting, controller.orders, controller.purchases = {}, {}, {}
    controller.sync = { has_cache = true, can_sync = true, authenticated = true, last_synced_at = os.time() - 600 }
    controller.signed_in, controller.auth_state, controller.hide_episodes = true, nil, nil
    controller.view, controller.jobs = { help_seen = true, sort = "recent" }, copy(base_jobs)
    controller.feed_stale, controller.feed_pages = false, 1
    populate(24, true)
    screens = Screens.new{ controller = controller }
end

local function capturePages(name, flow)
    local current = flow and screens.dialog or screens
    if flow then
        while (screens.dialog.page or 1) > 1 do screens.dialog:onPreviousPage() end
    elseif screens.page > 1 then
        screens.page = 1; screens:_render()
    end
    current = flow and screens.dialog or screens
    local pages = current.pages or 1
    for index = 1, pages do
        capture(name .. "-page-" .. index, { fullpage = flow })
        if index < pages then
            if flow then screens.dialog:onNextPage() else screens:_changePage(1) end
        end
    end
    check(name .. "_all_native_pages_captured", (flow and screens.dialog.page or screens.page) == pages,
        { pages = pages })
end
local function flowButton(message)
    while (screens.dialog.page or 1) > 1 do screens.dialog:onPreviousPage() end
    return dialogActionWithText(message)
end
local function geometry(name, item, expected)
    local actual = rectangle(assert(item))
    report.fidelity_measurements = report.fidelity_measurements or {}
    for key, target in pairs(expected) do
        report.fidelity_measurements[#report.fidelity_measurements + 1] = {
            screen = name, metric = key, actual_px = actual[key], design_px = target, tolerance_px = 1 }
        check(name .. "_geometry_" .. key, math.abs(actual[key] - target) <= 1, actual)
    end
end
local function exactText(message)
    return visit(screens.dialog or screens.widget, function(item) return item.text == T(message) end)[1]
end
local function focusPixels(name, widget, inset, selected)
    local box = rectangle(widget)
    local stroke, inner = math.max(1, W.dp(2)), W.dp(inset or 0)
    local y = box.y + inner + stroke + 2
    local border = Device.screen.bb:getPixel(box.x + inner + stroke - 1, y):getR()
    local following = Device.screen.bb:getPixel(box.x + inner + stroke, y):getR()
    check(name .. "_focus_outline_is_two_dp", border == 0x11 and (selected or following == 0xFF),
        { border = border, following = following, stroke = stroke, box = box, focused = widget.focused,
            top_left = Device.screen.bb:getPixel(box.x + inner, box.y + inner):getR(),
            neighboring = Device.screen.bb:getPixel(box.x + inner + 1, box.y + inner + 1):getR() })
    if selected then
        check(name .. "_focus_separates_selected_fill", Device.screen.bb:getPixel(box.x + inner - 1, y):getR() == 0xFF,
            { pixel = Device.screen.bb:getPixel(box.x + inner - 1, y):getR(), focused = widget.focused, box = box })
    end
end
local original_account = controller.getAccount
function controller:getAccount()
    local account = original_account(self)
    account.renewable = self.renewable ~= false
    account.name, account.id = self.account_name or "Synthetic account", self.signed_in and (self.account_id or "10001") or nil
    return account
end
function controller:importSession(content, callback)
    self.import_sequence = (self.import_sequence or 0) + 1
    enqueue("importSession", { content }, callback)
end

scenario("account-states", function()
    controller.wallet = { remain_gold = 280, remain_coupon = 2, updated_at = os.time() - 600 }
    screens:showAccount(); capturePages("G1-account-signed-in"); chrome("G1-account", nil)
    screens.page = 1; screens:_render()
    local settings_row = visit(screens.widget, function(item) return item.label == T("Defaults for new chapters") and item.callback end)[1]
    settings_row:onFocus(); UIManager:setDirty(screens.widget, "ui"); capture("account-setting-key-focus")
    focusPixels("account_setting", settings_row, 0); settings_row:onUnfocus()
    for _, state in ipairs({ "checking", "refreshing", "pending_confirmation", "reauth_required", "error" }) do
        controller.auth_state = state; screens.page = 1; screens:refresh()
        capturePages("account-" .. state)
        if state == "checking" or state == "refreshing" or state == "pending_confirmation" then
            screens.page = 1; screens:refresh()
            check("account_" .. state .. "_disables_refresh", button(screens.widget, "Refresh balance").enabled == false)
        end
    end
    controller.auth_state, controller.renewable, controller.wallet.stale = nil, false, true
    screens.page = 1; screens:refresh(); capturePages("account-imported-stale-balance")
    controller.signed_in = false; screens.page = 1; screens:refresh(); capturePages("G2-account-signed-out")
    check("signed_out_hides_purchase_and_recharge_group", not hasText(screens.widget, "Purchases and recharge"))
    controller.auth_state, controller.sync.offline = "reauth_required", true
    screens.page = 1; screens:refresh(); capturePages("account-expired-offline")
end)

scenario("account-storage-defaults", function()
    controller.storage = { total_bytes = 1002 * 1024 * 1024, automatic_bytes = 312 * 1024 * 1024,
        pinned_bytes = 690 * 1024 * 1024, free_bytes = 5800 * 1024 * 1024 }
    controller.settings = { cache_limit_mb = 256, reading_mode = "auto", reading_direction = "ltr",
        prefetch_pages = 3, download_concurrency = 2 }
    screens:showAccount(); screens:_storageSettings(); capturePages("G3-storage", true)
    check("legacy_cache_limit_is_not_silently_lowered", controller.settings.cache_limit_bytes == nil)
    while (screens.dialog.page or 1) > 1 do screens.dialog:onPreviousPage() end
    check("legacy_cache_limit_displays_actual_bytes", shownText(screens.dialog):find(Model.bytes(256 * 1024 * 1024), 1, true) ~= nil)
    activate(flowButton("256 MB")); capture("storage-reduce-confirmation")
    check("storage_reduction_requires_confirmation", controller.settings.cache_limit_bytes == nil and controller.settings.cache_limit_mb == 256)
    pressDialog("Cancel"); capturePages("storage-reduction-canceled", true)
    activate(flowButton("256 MB")); pressDialog("Apply cache limit"); capturePages("storage-reduction-applied", true)
    check("storage_reduction_updates_exact_limit", controller.settings.cache_limit_bytes == 256000000)
    local larger = flowButton("1 GB")
    local storage_page = screens.dialog.page
    activate(larger); check("storage_choice_retains_current_page", screens.dialog.page == storage_page)
    capturePages("storage-increase-applied", true)
    check("storage_increase_saves_immediately", controller.settings.cache_limit_bytes == 1000000000)
    screens:_clearAutomaticCache(); capture("storage-cleanup-confirmation"); pressDialog("Cancel")
    screens:_storageSettings(); screens:_clearAutomaticCache(); pressDialog("Clear cache"); capturePages("storage-cleanup-result", false)
    local clear_cache = controller.clearAutomaticCache
    for _, result in ipairs({ { freed_bytes = 0 }, { freed_bytes = 12 * 1024 * 1024, remaining_bytes = 5 * 1024 * 1024 } }) do
        controller.clearAutomaticCache = function() return result end
        screens:_storageSettings(); screens:_clearAutomaticCache(); pressDialog("Clear cache")
        capture("storage-cleanup-" .. (result.remaining_bytes and "protected" or "no-op")); closeDialog()
    end
    controller.clearAutomaticCache = function() return nil, { kind = "storage" } end
    screens:_storageSettings(); screens:_clearAutomaticCache(); pressDialog("Clear cache"); capture("storage-cleanup-error"); closeDialog()
    controller.clearAutomaticCache = clear_cache
    closeDialog(); screens:_readerDefaults(); capturePages("G4-reader-defaults-auto", true)
    while (screens.dialog.page or 1) > 1 do screens.dialog:onPreviousPage() end
    local cards = visit(screens.dialog, function(item) return item.callback and item.height == W.dp(204) and item.content end)
    cards[2]:onFocus(); UIManager:setDirty(screens.dialog, "ui"); capture("reader-mode-key-focus", { fullpage = true })
    focusPixels("reader_mode", cards[2], 5); cards[2]:onUnfocus()
    activate(flowButton("Page comic")); capturePages("G4-reader-defaults-page", true)
    check("page_mode_saved_immediately", controller.settings.reading_mode == "page")
    activate(flowButton("Long strip")); capturePages("G4-reader-defaults-strip", true)
    activate(flowButton("Right to left (manga)")); capturePages("reader-defaults-rtl", true)
    local no_preloading = flowButton("No preloading")
    local reader_page = screens.dialog.page
    activate(no_preloading); check("reader_choice_retains_current_page", screens.dialog.page == reader_page)
    capturePages("reader-defaults-no-preload", true)
    activate(flowButton(string.format(T("%d images"), 5))); capturePages("reader-defaults-five-preload", true)
    check("reader_defaults_saved_exact_values", controller.settings.reading_direction == "rtl" and controller.settings.prefetch_pages == 5)
    closeDialog()
end)

scenario("account-session-import", function()
    screens:showAccount(); screens:_otherSignInMethods(); capture("account-other-sign-in")
    pressDialog("Paste web session"); capture("account-session-paste-input"); closeDialog()
    controller.host_ui = { folder_shortcuts = { hasFolderShortcut = function() return false end,
        getShortcutFullName = function() return nil end } }
    G_reader_settings:saveSetting("home_dir", output_dir .. "/fixtures")
    screens:_importSessionFile(output_dir .. "/fixtures"); capture("account-native-session-file-picker"); closeDialog()
    screens:_sessionFileError({ code = "size" }); capture("account-session-file-too-large"); closeDialog()
    for _, code in ipairs({ "regular_file", "format", "read" }) do
        screens:_sessionFileError({ code = code }); capture("account-session-file-" .. code); closeDialog()
    end
    screens:_beginSessionImport("synthetic-only", "paste"); capture("account-session-validating")
    pressDialog("Continue in background"); capturePages("account-session-background-validation")
    finish("importSession", { account_key = controller.account_key }); screens:refresh()
    local transient = UIManager:getTopmostVisibleWidget()
    if transient ~= screens.widget then
        capture("account-session-background-notice"); UIManager:close(transient)
    end
    capturePages("account-session-background-result"); screens:_sessionImportResult(screens.session_import)
    capture("account-session-import-success"); closeDialog()
    screens:_beginSessionImport("synthetic-only", "paste"); finish("importSession", nil, { kind = "authentication" })
    capture("account-session-import-auth-error"); closeDialog()
    screens:_beginSessionImport("synthetic-only", "file", output_dir); finish("importSession", nil, { kind = "network" })
    capture("account-session-import-network-error"); closeDialog()
    screens:_beginSessionImport("synthetic-only", "paste")
    local obsolete = pending("importSession"); controller.generation = controller.generation + 1
    finish("importSession", nil, { kind = "network" })
    check("obsolete_import_cannot_replace_account_feedback", screens.session_import == nil)
    closeDialog()
end)

scenario("account-diagnostics", function()
    screens:showAccount(); screens:_diagnostics(); capture("diagnostics-loading", { fullpage = true })
    finish("getDiagnostics", { plugin_version = "0.1.0-synthetic", koreader_version = "v2026.07.1",
        local_session = "stored", credential_storage = "app_private", platform = { os = "Linux", arch = "x86_64", target = "emulator" },
        capabilities = { request_signing = true, response_decoding = false, image_index = true,
            image_tokens = true, encrypted_images = false, purchase = true } })
    capturePages("diagnostics-result", true); closeDialog()
    screens:_diagnostics(); finish("getDiagnostics", nil, { kind = "storage" }); capture("diagnostics-error"); closeDialog()
    screens:_diagnostics(); local retired = pending("getDiagnostics"); closeDialog()
    finish("getDiagnostics", { plugin_version = "obsolete" })
    check("closed_diagnostics_callback_is_ignored", screens.dialog == nil)
end)

scenario("qr-all-states", function()
    screens:showAccount(); screens:_signInWithQR(); capture("qr-loading", { fullpage = true })
    local url = "https://passport.bilibili.com/h5-app/passport/login/scan?qrcode_key=synthetic-only"
    finish("beginQRLogin", { key = "synthetic-key", expires_at = os.time() + 180, url = url })
    capture("H1-qr-waiting", { fullpage = true }); footer("qr", "Other sign-in methods", "Cancel")
    if scribe then
        local qrframe = visit(screens.dialog, function(item) return item.base ~= nil and item.getSize and item:getSize().w == W.dp(480) end)[1]
        geometry("H1-qr-frame", qrframe, { x = W.dp(225), y = W.dp(269), w = W.dp(480), h = W.dp(480) })
    end
    local waiting = screens.dialog
    screens.qr_login.timer(); finish("pollQRLogin", { status = "waiting" })
    check("unchanged_qr_status_preserves_native_surface", screens.dialog == waiting)
    screens.qr_login.timer(); finish("pollQRLogin", { status = "scanned" }); capture("H2-qr-scanned", { fullpage = true })
    check("scanned_flow_only_cancel_footer", #screens.dialog.footer_buttons == 1 and screens.dialog.footer_buttons[1].text == T("Cancel"))
    screens.qr_login.timer(); finish("pollQRLogin", { status = "expired" }); capture("H3-qr-expired", { fullpage = true })
    check("expired_qr_stops_polling", screens.qr_login.timer == nil)
    pressDialog("Get a new code"); finish("beginQRLogin", nil, { kind = "network" }); capture("qr-network-error", { fullpage = true })
    pressDialog("Get a new code"); finish("beginQRLogin", { key = "synthetic-key", expires_at = os.time() + 180, url = url })
    screens.qr_login.timer(); local late = pending("pollQRLogin"); pressDialog("Cancel")
    finish("pollQRLogin", { status = "confirmed" }); check("canceled_qr_ignores_late_confirmation", screens.dialog == nil)
    screens:_signInWithQR(); finish("beginQRLogin", { key = "synthetic-key", expires_at = os.time() - 1, url = url })
    screens.qr_login.timer(); capture("qr-local-expiry", { fullpage = true }); check("local_qr_expiry_prevents_poll", screens.qr_login.status == "expired")
    pressDialog("Get a new code"); finish("beginQRLogin", { key = "synthetic-key", expires_at = os.time() + 180, url = url })
    screens.qr_login.timer(); local expired_request = pending("pollQRLogin")
    screens.qr_login.code.expires_at = os.time() - 1
    screens.qr_login.timer(); capture("qr-inflight-local-expiry", { fullpage = true })
    check("inflight_request_does_not_hide_local_expiry", screens.qr_login.status == "expired" and screens.qr_login.timer == nil)
    finish("pollQRLogin", { status = "scanned" })
    check("expired_inflight_callback_cannot_restore_code", screens.qr_login.status == "expired")
    closeDialog()
    controller.signed_in = false; screens:showLibrary(); screens:_signInWithQR()
    finish("beginQRLogin", { key = "synthetic-key", expires_at = os.time() + 180, url = url })
    screens.qr_login.timer(); controller.signed_in = true
    finish("pollQRLogin", { status = "confirmed" }); capture("qr-confirmed-returns-bookshelf")
    check("qr_confirmation_returns_to_origin", screens.route == "favorites" and screens.qr_login == nil)
end)

local config = { confirmation_token = "synthetic-config", fetched_at = os.time(), custom_amount = { allowed = false }, options = {} }
for index, cents in ipairs({ 600, 1000, 3000, 5000, 10000, 30000, 50000 }) do
    config.options[index] = { amount_cents = cents, amount_yuan = string.format("%.2f", cents / 100), coin_amount = cents }
end
local function rechargeConfig()
    screens:_openRecharge(); finish("getRechargeConfig", copy(config))
end
local function sampleOrder(state)
    return { id = "synthetic-order", local_id = "synthetic-order", order_id = "90071992547409931234",
        account_key = controller.account_key, state = state or "pending", amount_cents = 3000,
        qr_validated = true, code_url = "https://pay.bilibili.com/payplatform-h5/index.html?order_id=synthetic-only",
        metadata = { config_snapshot = { option = copy(config.options[3]) } } }
end
scenario("recharge-configuration-review", function()
    screens:showAccount(); screens:_openRecharge(); capture("recharge-config-loading", { fullpage = true })
    finish("getRechargeConfig", nil, { kind = "network" }); capturePages("recharge-config-error", true)
    activate(flowButton("Reload official amounts")); finish("getRechargeConfig", copy(config))
    capturePages("I1-recharge-options", true)
    while (screens.dialog.page or 1) > 1 do screens.dialog:onPreviousPage() end
    local focus_tile = visit(screens.dialog, function(item) return item.selected == true and item.callback and item.content
        and item.dimen and item.dimen.h == W.dp(150) end)[1]
    focus_tile:onFocus(); UIManager:setDirty(screens.dialog, "ui"); capture("recharge-tier-key-focus", { fullpage = true })
    focusPixels("recharge_tier", focus_tile, 4, true); focus_tile:onUnfocus()
    if scribe then
        local tiles = visit(screens.dialog, function(item) return item.selected ~= nil and item.callback and item.content
            and item.dimen and item.dimen.h == W.dp(150) end)
        check("I1_six_official_tiers_use_two_rows", #tiles == 6)
        geometry("I1-tier", tiles[1], { h = W.dp(150), x = W.dp(56) })
    end
    local state = screens.recharge_state
    state.options_page = 2; screens:_rechargeAmountsView(state); capturePages("recharge-options-page-two", true)
    screens:_rechargeReviewAmount(state, "30.00", config.options[3]); capturePages("I2-recharge-review", true)
    neutralFocus("recharge_review", "Create payment QR")
    pressDialog("Back to edit"); screens:_rechargeInputAmount(state); capture("recharge-native-amount-input")
    screens:_rechargeInputAmount(state, "12.34", "The amount is not an official option."); capture("recharge-input-validation-error")
    screens:_rechargeReviewAmount(state, "12.34"); check("unlisted_amount_cannot_reach_confirmation", state.phase == "input")
    closeDialog()
end)
scenario("recharge-order-states", function()
    screens:showAccount(); local state = screens:_rechargeNewState()
    local order = sampleOrder(); controller.orders = { copy(order) }
    screens:_rechargeAttachOrder(state, order); capturePages("I3-recharge-code-no-expiry", true); footer("I3-recharge", "Check credit", "Close")
    if scribe then
        local qrframe = visit(screens.dialog, function(item) return item.bordersize == W.dp(2) and item.getSize
            and item:getSize().w == W.dp(460) and item:getSize().h == W.dp(460) end)[1]
        geometry("I3-qr-frame", qrframe, { w = W.dp(460), h = W.dp(460), x = W.dp(235) })
    end
    order.expires_at = os.time() + 180; screens:_rechargeAttachOrder(state, order); capturePages("recharge-code-server-expiry", true)
    activate(flowButton("Check credit")); capturePages("recharge-checking", true)
    finish("refreshRechargeOrder", copy(order), { kind = "network" }); capturePages("recharge-network-check-error", true)
    for _, phase in ipairs({ "unknown", "expired", "failed_not_submitted", "creating", "unsaved" }) do
        order = sampleOrder(phase == "unsaved" and "credited" or phase)
        order.persistence_pending = phase == "unsaved" or nil
        if phase == "unknown" then order.qr_validated = false end
        controller.orders = { copy(order) }; screens:_rechargeAttachOrder(state, order); capturePages("recharge-" .. phase, true)
        check("recharge_" .. phase .. "_never_creates_replacement", callCount("createRechargeOrder") == 0)
        if phase ~= "unknown" then
            check("recharge_" .. phase .. "_does_not_show_payment_code", #visit(screens.dialog, function(item) return item.image and item.text == order.code_url end) == 0)
        end
    end
    order = sampleOrder("unknown"); controller.orders = { copy(order) }
    screens:_rechargeAttachOrder(state, order); capturePages("recharge-unknown-valid-code", true)
    order.qr_validated = false; screens:_rechargeAttachOrder(state, order); capturePages("recharge-unverified-code", true)
    order = sampleOrder("pending"); order.code_url = string.rep("x", 3000)
    screens:_rechargeAttachOrder(state, order); capturePages("recharge-code-too-long", true)
    check("unrenderable_code_never_creates_replacement", callCount("createRechargeOrder") == 0)
    order = sampleOrder("credited"); order.history_evidence, order.credited_observed_at = { product_amount = 3000 }, os.time()
    local wallet_update = os.time()
    controller.wallet = { remain_gold = 280, remain_coupon = 2, updated_at = wallet_update, stale = true }
    screens:_rechargeAttachOrder(state, order); capturePages("recharge-credited-wallet-refreshing", true)
    check("credited_before_wallet_shows_refresh_state", hasText(screens.dialog, "Balance is refreshing; return to Account to check it."))
    controller.wallet = { remain_gold = 3280, remain_coupon = 2, updated_at = wallet_update, stale = false }
    local receipt_page = screens.dialog.page
    controller.orders = { order }; screens:refresh()
    check("wallet_update_retains_receipt_page", screens.dialog.page == receipt_page)
    capturePages("I4-recharge-credited", true)
    check("open_receipt_updates_when_wallet_arrives", shownText(screens.dialog):find(string.format(T("Current balance %s manga coins"), "3280"), 1, true) ~= nil)
    check("credited_receipt_uses_matching_evidence", shownText(screens.dialog):find(string.format(T("+%s manga coins"), "3000"), 1, true) ~= nil)
    closeDialog()
end)
scenario("recharge-history-and-creation", function()
    screens:showAccount(); screens:_showRechargeOrders(); capturePages("recharge-history-empty", true)
    controller.orders = {}
    for index, phase in ipairs({ "pending", "unknown", "credited", "expired", "failed_not_submitted", "creating", "pending" }) do
        local order = sampleOrder(phase); order.id, order.local_id, order.order_id = "record-" .. index, "record-" .. index, "order-" .. index
        controller.orders[index] = order
    end
    screens:_rechargeOrdersView(screens.recharge_state); capturePages("recharge-history-page-one", true)
    screens:_rechargeOrdersView(screens.recharge_state, 2); capturePages("recharge-history-page-two", true)
    check("creating_order_blocks_new_recharge", button(screens.dialog, "New recharge").enabled == false)
    controller.orders = { sampleOrder("credited") }; controller.orders[1].persistence_pending = true
    screens:_rechargeOrdersView(screens.recharge_state); capturePages("recharge-history-unsaved", true)
    check("unsaved_order_blocks_new_recharge", button(screens.dialog, "New recharge").enabled == false)
    controller.orders = {}; screens:_rechargeOrdersView(screens.recharge_state)
    activate(flowButton("New recharge")); capturePages("recharge-new-order-notice", true)
    activate(flowButton("Choose a new amount")); finish("getRechargeConfig", copy(config))
    local state = screens.recharge_state; screens:_rechargeReviewAmount(state, "30.00", config.options[3])
    local create = button(screens.dialog, "Create payment QR"); activate(create); capturePages("recharge-creating-request", true)
    create.callback(); check("duplicate_create_callback_sends_one_order", callCount("createRechargeOrder") == 1)
    finish("createRechargeOrder", nil, { kind = "network" }); capturePages("recharge-creation-unknown", true)
    check("unknown_creation_preserves_no_resend_guard", state.submitted == true and callCount("createRechargeOrder") == 1)
    closeDialog(); rechargeConfig(); state = screens.recharge_state
    screens:_rechargeReviewAmount(state, "30.00", config.options[3]); pressDialog("Create payment QR")
    finish("createRechargeOrder", nil, { kind = "network", transmitted = false, definitive = true })
    capturePages("recharge-definitive-not-submitted", true)
    closeDialog()
end)

UIManager.scheduleIn, UIManager.unschedule = native_schedule, native_unschedule
for _, name in ipairs(forbidden_modules) do check("production_module_remains_unloaded_" .. name:gsub("/", "_"), package.loaded[name] == nil) end
report.passed = true
for _, item in ipairs(report.assertions) do if not item.passed then report.passed = false end end
local result_file = assert(io.open(output_dir .. "/all-pages-ghi-result.json", "wb"))
result_file:write(json.encode(report, { pretty = true })); result_file:close()
print(json.encode({ passed = report.passed, assertions = #report.assertions, screenshots = #report.screenshots,
    width = width, height = height, language = report.language }))
os.exit(report.passed and 0 or 1)
