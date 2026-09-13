-- Exercise bookshelf finishing behavior through native widgets and controlled account-scoped state.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
require("gettext").current_lang = arg[3] or "zh_CN"
local UIManager = require("ui/uimanager")
local Screens = require("bilicomics/ui/screens")
local Model = require("bilicomics/ui/model")
local W = require("bilicomics/ui/widgets")
local json = require("rapidjson")
local _ = require("bilicomics/ui/i18n")
local width, height = Device.screen:getWidth(), Device.screen:getHeight()
local result = { assertions = {}, screenshots = {}, language = arg[3], width = width, height = height,
    scope = "Native bookshelf synchronization, menu, view persistence, category and navigation widgets; synthetic data; no HTTP, account credentials or purchases" }
local function check(name, value, detail)
    result.assertions[#result.assertions + 1] = { name = name, passed = not not value, detail = detail }
end
local queue, native_next_tick = {}, UIManager.nextTick
UIManager.nextTick = function(_manager, callback, ...)
    local arguments, length = { ... }, select("#", ...)
    queue[#queue + 1] = function() return callback(unpack(arguments, 1, length)) end
end
local function flush()
    local remaining = 1000
    while #queue > 0 do
        remaining = remaining - 1
        assert(remaining > 0, "Deferred native UI work must settle")
        table.remove(queue, 1)()
    end
end
local function clone(value)
    if type(value) ~= "table" then return value end
    local copied = {}
    for key, item in pairs(value) do copied[key] = clone(item) end
    return copied
end
local function findText(widget, message)
    for _index, child in ipairs(widget) do
        if type(child) == "table" then local found = findText(child, message); if found then return found end end
    end
    if widget.text == _(message) then return widget end
end
local function contains(widget, message) return findText(widget, message) ~= nil end
local function parentOf(widget, target)
    for _index, child in ipairs(widget) do
        if child == target then return widget end
        if type(child) == "table" then local found = parentOf(child, target); if found then return found end end
    end
end
local ids = { "9", "2", "30", "14", "7", "55", "101", "3", "42", "87", "20", "63", "17", "75", "4", "36", "98", "21", "60", "19", "45", "6", "83", "11" }
local titles = { "Zinnia", "A Lighthouse Beyond the Clouds and Across the Quiet Sea", "Moonlit Observatory",
    "The Last Paper Crane", "Across the Silver Mountain" }
local function comicsFor(prefix, count)
    local comics = {}
    for index = 1, count or #ids do
        local known = index % 3 ~= 0
        comics[index] = { id = tostring((prefix or 0) + tonumber(ids[index])),
            title = titles[(index - 1) % #titles + 1] .. (index > #titles and " " .. index or ""),
            cover_path = output .. "/fixtures/synthetic-cover-" .. ((index - 1) % 5 + 1) .. ".png",
            current_episode_id = known and "2" or nil, progress_source = known and "local" or nil,
            reading_position = known and { episode_id = "2", index = 7, revision = "synthetic-r1" } or nil,
            last_read_at = known and 1700000000 + index or nil,
            latest_episode_title = "Latest chapter must stay outside the bookshelf", latest_order = 77,
            favorite = true, finished = index % 4 == 0, has_update = index % 2 == 1,
            extra = { recommendation = "An original synthetic synopsis for native UI checks.", tags = { "Adventure" } } }
    end
    return comics
end
local function account(options)
    options = options or {}
    return { comics = options.comics or comicsFor(options.prefix), settings = {},
        sync = { has_cache = options.has_cache ~= false, syncing = false,
            last_synced_at = options.has_cache ~= false and 1700000100 or nil,
            stale = options.stale == true, can_sync = options.can_sync ~= false, error = options.error },
        view = { filter = "all", sort = "source", page = 1, order_ids = {}, help_seen = options.help_seen ~= false } }
end
local controller = { account_key = "synthetic-a", accounts = {}, calls = {}, waiting = {}, saves = {}, covers = {},
    setting_calls = {}, forbidden = {}, bookstore_covers = {}, canceled_reads = 0 }
controller.accounts["synthetic-a"] = account()
controller.accounts["synthetic-b"] = account{ prefix = 2000 }
controller.accounts["synthetic-help"] = account{ prefix = 3000, help_seen = false }
controller.accounts["synthetic-empty"] = account{ comics = {}, has_cache = false, stale = true }
controller.accounts.anonymous = account{ comics = {}, has_cache = false, stale = true, can_sync = false }
local screens
function controller:active() return assert(self.accounts[self.account_key]) end
function controller:getAccount()
    return { id = self.account_key, account_key = self.account_key, name = "Synthetic account",
        session_valid = self.account_key ~= "anonymous" }
end
function controller:getBookshelfItems() return self:active().comics end
function controller:getBookshelfSyncState()
    local state = clone(self:active().sync)
    state.authenticated, state.offline = self.account_key ~= "anonymous", state.offline == true
    return state
end
function controller:getBookshelfViewState()
    local state = clone(self:active().view)
    state.schema_version, state.account_key = 1, self.account_key
    return state
end
function controller:saveBookshelfViewState(changes, expected_account)
    if expected_account and expected_account ~= self.account_key then return nil, { kind = "account_mismatch" } end
    local state = self:getBookshelfViewState()
    for key, value in pairs(changes) do state[key] = clone(value) end
    self:active().view = state
    self.saves[#self.saves + 1] = { account_key = self.account_key, state = clone(state) }
    return clone(state)
end
function controller:getLibrary(kind) return kind == "favorites" and self:active().comics or {} end
function controller:getSetting(key, default)
    local value = self:active().settings[key]
    if value == nil then return default end
    return value
end
function controller:setSetting(key, value)
    self.setting_calls[#self.setting_calls + 1] = { key = key, value = value, account_key = self.account_key }
    if self.setting_failure then return nil, { kind = "storage" } end
    if key == "download_concurrency" then assert(type(value) == "number" and value % 1 == 0 and value >= 1 and value <= 4) end
    self:active().settings[key] = value
    return true
end
function controller:enqueue(method, args, callback)
    local request = { method = method, args = args, callback = callback, account_key = self.account_key,
        view_at_dispatch = self:getBookshelfViewState() }
    self.calls[#self.calls + 1] = request
    self.waiting[#self.waiting + 1] = request
    return request
end
function controller:ensureBookshelfSync(callback)
    local state = self:active().sync
    if not state.stale or not state.can_sync then
        if callback then UIManager:nextTick(callback, clone(self:getBookshelfItems())) end
        return
    end
    if state.syncing then return end
    state.syncing = true
    return self:enqueue("ensureBookshelfSync", {}, callback)
end
function controller:syncBookshelf(callback)
    local state = self:active().sync
    if state.syncing then return end
    state.syncing = true
    return self:enqueue("syncBookshelf", {}, callback)
end
function controller:cancelPendingRead() self.canceled_reads = self.canceled_reads + 1 end
function controller:requestCover(id) self.covers[#self.covers + 1] = tostring(id) end
function controller:getEpisodes(id)
    return { { id = "1", comic_id = tostring(id), title = "Opening", short_title = "1", access = "free", order = 1 },
        { id = "2", comic_id = tostring(id), title = "A New Horizon", short_title = "2", access = "owned", order = 2,
            total_pages = 45, current_revision = "synthetic-r1" },
        { id = "3", comic_id = tostring(id), title = "The Far Shore", short_title = "3", access = "locked", order = 3 } }
end
function controller:getComic(id)
    for _index, comic in ipairs(self:active().comics) do if comic.id == tostring(id) then return comic end end
    for _index, comic in ipairs(self.bookstore_items or {}) do if comic.id == tostring(id) then return comic end end
end
function controller:resolveReadingEpisode(id, callback) return self:enqueue("resolveReadingEpisode", { tostring(id) }, callback) end
function controller:readEpisode(comic_id, episode_id, callback) return self:enqueue("readEpisode", { tostring(comic_id), tostring(episode_id) }, callback) end
function controller:refreshComic(id, callback) return self:enqueue("refreshComic", { tostring(id) }, callback) end
function controller:getPendingPurchases() return {} end
function controller:getWallet() return {} end
function controller:getDownloads() return {} end
function controller:getStorageSummary() return { automatic_bytes = 0, pinned_bytes = 0 } end
function controller:getBookstore(query)
    self.bookstore_items = self.bookstore_items or comicsFor(9000, 18)
    return { items = self.bookstore_items, stale = false, source = query and "official_category" or "official_homepage",
        personalized = false, updated_at = 1700000000, loaded_pages = 1, next_page = 2,
        has_more = false, can_load_more = false, limit_reached = false,
        identity = { account_key = self.account_key, query_key = query and "category:101:0" or "homepage", revision = 1 } }
end
function controller:getBookstoreCategories()
    return { items = { { id = "101", name = "Adventure" } }, stale = false, source = "official_categories" }
end
function controller:requestBookstoreCover(id, identity)
    self.bookstore_covers[#self.bookstore_covers + 1] = { id = tostring(id), identity = clone(identity) }
end
for _index, method in ipairs({ "purchase", "quotePurchase", "downloadEpisodes", "setFavorite", "importSession", "beginQRLogin",
    "refreshLibrary", "refreshBookstore", "refreshBookstoreCategories", "loadMoreBookstore" }) do
    controller[method] = function()
        controller.forbidden[#controller.forbidden + 1] = method
        error("This finishing fixture forbids " .. method)
    end
end
local function pending(method)
    for _index, request in ipairs(controller.waiting) do if request.method == method then return request end end
    error("Expected controlled callback: " .. method)
end
local function finish(request, value, err)
    local found
    for index, waiting in ipairs(controller.waiting) do if waiting == request then found = table.remove(controller.waiting, index); break end end
    assert(found, "The controlled request must still be pending")
    local current = controller.accounts[request.account_key]
    local callback_value = value
    if request.method == "syncBookshelf" or request.method == "ensureBookshelfSync" then
        current.sync.syncing, current.sync.error = false, err
        if value then
            current.comics = value.items or current.comics
            current.sync.has_cache, current.sync.stale, current.sync.last_synced_at = true, false, value.last_synced_at or 1700000200
            callback_value = clone(current.comics)
        else current.sync.stale = true end
    end
    if request.callback then request.callback(callback_value, err) end
    if request.method == "syncBookshelf" or request.method == "ensureBookshelfSync" then
        if screens and screens.route and request.account_key == controller.account_key then screens:refresh() end
    end
    flush()
end
local function button(message)
    for _row_index, row in ipairs(screens.focus) do for _button_index, control in ipairs(row) do
        if control.text == _(message) and control.callback then return control end
    end end
end
local function press(message)
    local control = assert(button(message), "Expected native control: " .. message)
    assert(control.enabled ~= false, "Expected enabled native control: " .. message)
    control.callback()
end
local function dialogOption(message)
    for _row_index, row in ipairs(assert(screens.dialog).buttons) do for _button_index, control in ipairs(row) do
        local label = control.text and control.text:gsub("^%[x%] ", ""):gsub("^%[ %] ", "")
        if label == _(message) then return control end
    end end
    error("Expected dialog choice: " .. message)
end
local function dialogPress(message)
    local control = dialogOption(message)
    assert(control.enabled ~= false, "Expected enabled dialog choice: " .. message)
    control.callback()
end
local function dialogTitleContains(message)
    return screens.dialog and type(screens.dialog.title) == "string" and screens.dialog.title:find(_(message), 1, true) ~= nil
end
local function openMore() press("More"); return assert(screens.dialog) end
local function closeDialog() screens:_closeDialog() end
local function cardIDs()
    local found = {}
    for _index, card in ipairs(screens.cards or {}) do found[#found + 1] = tostring(card.comic.id) end
    return found
end
local function capture(name)
    flush()
    UIManager:forceRePaint()
    local size = screens.widget.content:getSize()
    check(name .. "_screen_bounds", size.w <= width and size.h <= height, { w = size.w, h = size.h })
    if screens.dialog then
        local modal = screens.dialog.movable and screens.dialog.movable:getSize() or screens.dialog:getSize()
        check(name .. "_dialog_bounds", modal.w <= width and modal.h <= height, { w = modal.w, h = modal.h })
    end
    Device.screen.bb:writePNG(output .. "/" .. name .. ".png")
    result.screenshots[#result.screenshots + 1] = name .. ".png"
end
local function checkNavigation(name, selected)
    UIManager:forceRePaint()
    local tabs = screens.focus[#screens.focus]
    local labels = { "Bookshelf", "Bookstore", "Search", "Downloads" }
    check(name .. "_four_native_navigation_buttons", #tabs == 4)
    for index, tab in ipairs(tabs) do
        check(name .. "_navigation_label_" .. index, tab.text == _(labels[index]))
        check(name .. "_navigation_state_" .. index, tab.selected == (index == selected) and tab.bordersize == 0
            and tab.text_font_bold == (index == selected) and tab[1].invert ~= true)
        check(name .. "_navigation_touch_height_" .. index, tab.dimen.h >= W.scale(30))
        local cell = parentOf(screens.widget.content, tab)
        local marker = cell and cell[2] and cell[2][1]
        local size = marker and marker:getSize()
        check(name .. "_static_selection_underline_" .. index, marker and (index == selected
            and marker.background == W.ink and size.w > 0 and size.h > 0 and size.h <= W.scale(3)
            or index ~= selected and (type(marker.background) == "nil" or marker.background ~= W.ink)))
        if index > 1 then
            check(name .. "_navigation_single_row_" .. index, tab.dimen.y == tabs[1].dimen.y
                and tab.dimen.x >= tabs[index - 1].dimen.x + tabs[index - 1].dimen.w)
        end
    end
end
local function checkShelfCards(name)
    UIManager:forceRePaint()
    local previous
    for index, card in ipairs(screens.cards) do
        local title = findText(card, card.comic.title)
        local progress = findText(card, card.progress)
        check(name .. "_bookshelf_card_mode_" .. index, card.bookshelf == true and not card.compact)
        check(name .. "_fixed_title_and_single_position_" .. index, title and progress
            and title.height == W.scale(42) and progress.height == W.scale(20))
        check(name .. "_no_latest_chapter_metadata_" .. index,
            not contains(card, string.format(_("Latest: %s"), "Latest chapter must stay outside the bookshelf")))
        check(name .. "_card_bounds_" .. index, card.dimen.x >= 0 and card.dimen.y >= 0
            and card.dimen.x + card.dimen.w <= width and card.dimen.y + card.dimen.h <= height)
        if previous and card.dimen.y == previous.dimen.y then
            check(name .. "_equal_row_baselines_" .. index, card.dimen.h == previous.dimen.h
                and card.dimen.x >= previous.dimen.x + previous.dimen.w)
        end
        previous = card
    end
end
local function focusCard(card)
    for row_index, row in ipairs(screens.focus) do for column, control in ipairs(row) do
        if control == card then screens.widget:moveFocusTo(column, row_index, 4); return end
    end end
    error("Expected a native focus slot for the selected comic")
end
local function showAccount(key)
    controller.account_key = key
    screens:showLibrary()
    flush()
end

screens = Screens.new{ controller = controller }
local Main = dofile(plugin .. "/main.lua")
Main.onShowBiliComics({ _open = function(_self, callback) callback(controller, screens) end })
flush()
check("main_entry_opens_the_remembered_bookshelf", screens.route == "favorites" and screens.dialog == nil)
check("default_bookshelf_has_a_quiet_header", button("Back") and button("More")
    and not button("Refresh bookshelf") and not button("All") and not button("Clear filter")
    and not contains(screens.widget.content, "Tap to read · Hold for chapters"))
checkShelfCards("default")
checkNavigation("default", 1)
capture("synthetic-bookshelf-finishing-default")
local initial_ids = table.concat(cardIDs(), ",")
local ordered = controller:active().comics
ordered[1], ordered[2] = ordered[2], ordered[1]
ordered[1].cover_path = output .. "/fixtures/synthetic-cover-5.png"
screens:refresh()
check("background_source_and_cover_repaint_preserve_the_visible_order", table.concat(cardIDs(), ",") == initial_ids)

openMore()
check("more_preserves_the_last_confirmed_sync_time",
    dialogTitleContains(string.format(_("Last synced: %s"), os.date("%Y-%m-%d %H:%M", 1700000100))))
for _index, message in ipairs({ "Refresh bookshelf", "Filter bookshelf", "Sort bookshelf", "Open chapter catalog",
    "Account and settings", "Bookshelf help" }) do
    check("more_exposes_" .. message:gsub("%s", "_"), dialogOption(message) ~= nil)
end
capture("synthetic-bookshelf-finishing-more")
dialogPress("Refresh bookshelf")
finish(pending("syncBookshelf"), { items = ordered, last_synced_at = 1700000300 })
check("manual_sync_explicitly_adopts_the_new_official_order", cardIDs()[1] == ordered[1].id)
openMore(); dialogPress("Filter bookshelf"); dialogPress("Currently reading")
check("active_filter_is_visible_with_a_direct_clear_action", screens.filter == "reading" and button("Clear filter")
    and contains(screens.widget.content, string.format(_("Filter: %s"), _("Currently reading"))))
capture("synthetic-bookshelf-finishing-filter")
press("Clear filter")
check("clearing_filter_returns_to_the_quiet_default", screens.filter == "all" and not button("Clear filter") and not button("Refresh bookshelf"))

local selected = screens.cards[2]
focusCard(selected)
check("native_card_focus_keeps_its_border", screens.widget:getFocusItem() == selected and selected.frame.color == W.ink)
local more_control = assert(button("More"))
focusCard(more_control)
check("more_can_take_native_focus_before_opening_its_menu", screens.widget:getFocusItem() == more_control)
openMore(); dialogPress("Open chapter catalog")
local catalog = pending("refreshComic")
check("more_opens_the_last_focused_comic_after_taking_focus", screens.route == "comic" and screens.comic_id == selected.comic.id
    and catalog.args[1] == selected.comic.id)
finish(catalog, true)
screens:showLibrary()

openMore(); dialogPress("Filter bookshelf"); dialogPress("Currently reading")
openMore(); dialogPress("Sort bookshelf"); dialogPress("Title")
assert(screens.pagination and screens.pagination.next.enabled ~= false, "The synthetic reading shelf must contain multiple pages")
screens.pagination.next.callback()
local remembered = screens.cards[1]
focusCard(remembered)
local remembered_page, remembered_ids = screens.page, table.concat(cardIDs(), ",")
screens:showSearch()
local view_a = controller.accounts["synthetic-a"].view
check("leaving_saves_filter_sort_page_focus_and_order", view_a.filter == "reading" and view_a.sort == "title"
    and view_a.page == remembered_page and view_a.focused_comic_id == remembered.comic.id and #view_a.order_ids > 0)
screens:showLibrary()
check("returning_from_another_route_restores_the_same_view", screens.filter == "reading" and screens.page == remembered_page
    and table.concat(cardIDs(), ",") == remembered_ids)
local read_card = screens.cards[1]
focusCard(read_card)
read_card.callback()
local resolve = pending("resolveReadingEpisode")
check("reading_dispatch_saves_the_current_bookshelf_view", resolve.view_at_dispatch.page == remembered_page
    and resolve.view_at_dispatch.focused_comic_id == read_card.comic.id and resolve.view_at_dispatch.filter == "reading")
finish(resolve, { comic = controller:getComic(read_card.comic.id), episode = controller:getEpisodes(read_card.comic.id)[2] })
finish(pending("readEpisode"), true)
check("successful_reader_handoff_closes_the_plugin", screens.route == nil and screens.widget == nil)
screens:onReaderClosed({ comic_id = read_card.comic.id })
flush()
check("native_reader_close_automatically_restores_the_saved_bookshelf", screens.route == "favorites"
    and screens.page == remembered_page and screens.filter == "reading"
    and table.concat(cardIDs(), ",") == remembered_ids)
local returned_focus = screens.widget and screens.widget:getFocusItem()
check("native_reader_return_restores_the_selected_comic_focus", returned_focus and returned_focus.comic
    and returned_focus.comic.id == read_card.comic.id)
press("Back")
check("back_returns_from_the_plugin_and_keeps_its_view", screens.route == nil
    and controller.accounts["synthetic-a"].view.page == remembered_page)
screens:onReaderClosed({ comic_id = read_card.comic.id })
check("back_does_not_reopen_the_plugin_on_a_later_reader_event", screens.route == nil and screens.widget == nil)
screens:showLibrary()
local saved_a = clone(controller.accounts["synthetic-a"].view)
local account_read_card = screens.cards[1]
focusCard(account_read_card)
account_read_card.callback()
finish(pending("resolveReadingEpisode"), { comic = controller:getComic(account_read_card.comic.id),
    episode = controller:getEpisodes(account_read_card.comic.id)[2] })
finish(pending("readEpisode"), true)
screens:close()
screens:onReaderClosed({ comic_id = account_read_card.comic.id })
check("explicit_close_retires_a_ready_reader_return_intent", screens.route == nil and screens.widget == nil)
screens:showLibrary()
account_read_card = screens.cards[1]
focusCard(account_read_card)
account_read_card.callback()
finish(pending("resolveReadingEpisode"), { comic = controller:getComic(account_read_card.comic.id),
    episode = controller:getEpisodes(account_read_card.comic.id)[2] })
finish(pending("readEpisode"), true)
controller.account_key = "synthetic-b"
screens:onReaderClosed({ comic_id = account_read_card.comic.id })
check("an_account_change_retires_the_reader_return_intent", screens.route == nil and screens.widget == nil)
screens:showLibrary()
check("switching_account_loads_its_own_default_view", screens.filter == "all" and screens.page == 1
    and cardIDs()[1] == controller.accounts["synthetic-b"].comics[1].id and screens.dialog == nil)
local recent_items = controller:active().comics
recent_items[1].progress_source, recent_items[1].last_read_at = "server", 9999999999
recent_items[2].progress_source, recent_items[2].extra.progress_source, recent_items[2].last_read_at = nil, "local", 1800000000
local recent_order = {}
for index, comic in ipairs(recent_items) do recent_order[index] = { comic = comic, source_index = index } end
local function trustedTime(comic)
    local source = comic.progress_source or (comic.extra or {}).progress_source
    local value = comic.last_read_at
    return source == "local" and type(value) == "number" and value > 0 and value < math.huge and value or 0
end
table.sort(recent_order, function(a, b)
    local left, right = trustedTime(a.comic), trustedTime(b.comic)
    if left ~= right then return left > right end
    return a.source_index < b.source_index
end)
local recent_expected = {}
for index, entry in ipairs(recent_order) do recent_expected[index] = entry.comic.id end
openMore(); dialogPress("Sort bookshelf"); dialogPress("Recently read")
check("recent_sort_uses_trusted_local_time_instead_of_server_time", cardIDs()[1] == recent_items[2].id)
screens:showSearch()
check("recent_sort_preserves_source_order_for_unknown_times", controller:active().view.sort == "recent"
    and table.concat(controller:active().view.order_ids, ",") == table.concat(recent_expected, ","))
check("another_account_does_not_overwrite_the_first_view", controller.accounts["synthetic-a"].view.filter == saved_a.filter
    and controller.accounts["synthetic-a"].view.page == saved_a.page
    and controller.accounts["synthetic-a"].view.focused_comic_id == saved_a.focused_comic_id)
showAccount("synthetic-a")
check("switching_back_restores_the_first_account_view", screens.filter == saved_a.filter and screens.page == saved_a.page)

showAccount("synthetic-help")
check("first_visit_explains_bookshelf_controls", screens.dialog and dialogOption("Got it"))
dialogPress("Got it")
check("acknowledging_help_is_saved_for_this_account", controller:active().view.help_seen == true and screens.dialog == nil)
screens:showSearch(); screens:showLibrary()
check("acknowledged_help_does_not_repeat_on_entry", screens.dialog == nil)
openMore(); dialogPress("Bookshelf help")
check("help_remains_available_from_more", screens.dialog and dialogOption("Got it"))
capture("synthetic-bookshelf-finishing-help")
dialogPress("Got it")
controller:active().sync.stale = true
screens:showSearch(); screens:showLibrary()
local cached_ids = table.concat(cardIDs(), ",")
finish(pending("ensureBookshelfSync"), nil, { kind = "network" })
check("offline_sync_failure_keeps_all_cached_cards", #screens.cards > 0 and table.concat(cardIDs(), ",") == cached_ids
    and controller:active().sync.has_cache and controller:active().sync.error.kind == "network")
openMore()
local network_heading = Model.error({ kind = "network" })
check("more_retains_the_last_sync_failure", dialogTitleContains(network_heading))
closeDialog()
capture("synthetic-bookshelf-finishing-offline-cache")

showAccount("synthetic-empty")
check("never_synced_empty_cache_starts_an_automatic_sync", #screens.cards == 0 and controller:active().sync.syncing
    and contains(screens.widget.content, "Loading your bookshelf…")
    and not contains(screens.widget.content, "Your bookshelf is empty. Find a comic in Bookstore or Search."))
capture("synthetic-bookshelf-finishing-initial-sync")
finish(pending("ensureBookshelfSync"), nil, { kind = "network" })
check("failed_initial_sync_does_not_claim_an_empty_server_bookshelf", not controller:active().sync.has_cache
    and contains(screens.widget.content, "Your bookshelf has not been synced yet.") and button("Retry sync")
    and not contains(screens.widget.content, "Your bookshelf is empty. Find a comic in Bookstore or Search."))
press("Retry sync")
finish(pending("syncBookshelf"), { items = {} })
check("confirmed_empty_bookshelf_is_distinct_from_missing_cache", #screens.cards == 0 and controller:active().sync.has_cache
    and not controller:active().sync.syncing
    and contains(screens.widget.content, "Your bookshelf is empty. Find a comic in Bookstore or Search."))
capture("synthetic-bookshelf-finishing-confirmed-empty")
controller:active().comics = comicsFor(5000, 6)
for _index, comic in ipairs(controller:active().comics) do comic.finished = false end
screens:refresh()
openMore(); dialogPress("Filter bookshelf"); dialogPress("Completed series")
check("empty_filter_keeps_a_clear_action_and_does_not_change_the_cache", #screens.cards == 0 and button("Clear filter")
    and #controller:active().comics == 6 and controller:active().sync.has_cache
    and contains(screens.widget.content, "No comics match this filter.")
    and not contains(screens.widget.content, "Your bookshelf is empty. Find a comic in Bookstore or Search."))
capture("synthetic-bookshelf-finishing-filter-empty")
showAccount("anonymous")
check("anonymous_empty_bookshelf_exposes_qr_sign_in", #screens.cards == 0 and button("Sign in with QR code")
    and contains(screens.widget.content, "Sign in to load your bookshelf."))
capture("synthetic-bookshelf-finishing-anonymous")

showAccount("synthetic-b")
screens:showBookstore()
screens:_selectBookstoreCategory({ id = "101", name = "Adventure" })
local store_columns = width >= 900 and 4 or width >= 600 and 3 or 2
check("category_keeps_two_compact_rows_after_navigation_changes", #screens.cards == store_columns * 2 and screens.grid_rows == 2)
if width == 600 and height == 800 then check("category_still_shows_six_cards_at_600x800", #screens.cards == 6) end
checkNavigation("category", 2)
capture("synthetic-bookshelf-finishing-category")
screens:showLibrary()
openMore(); dialogPress("Account and settings")
check("more_account_action_opens_settings", screens.route == "account")
press(string.format(_("Concurrent images: %d"), 2))
check("concurrency_dialog_explains_active_image_behavior", dialogTitleContains("Concurrent image downloads")
    and dialogTitleContains("Applies to online cache and downloads. Images already downloading will finish."))
local choices = {}
for _row_index, row in ipairs(screens.dialog.buttons) do for _button_index, control in ipairs(row) do
    local label = control.text and control.text:gsub("^%[x%] ", ""):gsub("^%[ %] ", "")
    local value = tonumber(label)
    if value then choices[#choices + 1] = value end
end end
check("concurrency_options_are_exactly_one_through_four", table.concat(choices, ",") == "1,2,3,4")
for value = 1, 4 do
    dialogPress(tostring(value))
    check("concurrency_selection_persists_" .. value, controller:getSetting("download_concurrency", 2) == value
        and dialogOption(tostring(value)).text:find("[x] ", 1, true) == 1)
end
controller.setting_failure = true
dialogPress("3")
local storage_heading = Model.error({ kind = "storage" })
check("failed_concurrency_storage_keeps_the_previous_setting_and_reports_recovery", controller:getSetting("download_concurrency", 2) == 4
    and dialogTitleContains(storage_heading))
controller.setting_failure = false
dialogPress("Close")
press(string.format(_("Concurrent images: %d"), 4))
check("reopening_after_storage_failure_retains_the_confirmed_selection", dialogOption("4").text:find("[x] ", 1, true) == 1)
capture("synthetic-bookshelf-finishing-concurrency")
dialogPress("Close")
check("all_controlled_requests_complete", #controller.waiting == 0)
check("all_scenarios_preserve_network_purchase_and_authentication_boundaries", #controller.forbidden == 0, controller.forbidden)
screens:close()
flush()
UIManager.nextTick = native_next_tick
result.passed = true
for _index, assertion in ipairs(result.assertions) do if not assertion.passed then result.passed = false end end
local file = assert(io.open(output .. "/bookshelf-finishing-result.json", "wb"))
file:write(json.encode(result, { pretty = true })); file:close()
print(json.encode({ passed = result.passed, assertions = #result.assertions, width = width, height = height, language = arg[3] }))
os.exit(result.passed and 0 or 1)
