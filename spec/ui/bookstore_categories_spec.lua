-- Exercise native category discovery with isolated synthetic caches and controlled asynchronous responses.
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
local json = require("rapidjson")
local _ = require("bilicomics/ui/i18n")
local width, height = Device.screen:getWidth(), Device.screen:getHeight()
local expected_columns = width >= 900 and 4 or width >= 600 and 3 or 2
local expected_capacity = expected_columns * 2
local result = { assertions = {}, screenshots = {}, language = arg[3], width = width, height = height,
    scope = "Native category picker and bookstore widgets; original synthetic covers; query-isolated anonymous caches; no HTTP, account, purchase or reader" }
local function check(name, value, detail)
    result.assertions[#result.assertions + 1] = { name = name, passed = not not value, detail = detail }
end
local function contains(widget, message)
    if widget.text == _(message) then return true end
    for _index, child in ipairs(widget) do
        if type(child) == "table" and contains(child, message) then return true end
    end
    return false
end
local category_names = { "Adventure", "Fantasy", "Science Fiction", "Mystery", "Drama", "Comedy", "Romance", "Action",
    "History Fiction", "Sports", "School", "Slice of Life", "Supernatural", "Martial Arts", "Suspense", "Graphic Essays" }
local function directory(stale, renamed)
    local value = { items = {}, stale = stale == true, source = "official_categories", updated_at = 1234567890 }
    for index, name in ipairs(category_names) do
        value.items[index] = { id = tostring(100 + index), name = renamed and index == 4 and "Updated Mystery" or name }
    end
    return value
end
local categories = directory().items
local function categoryQuery(category)
    return category and { kind = "category", category_id = tostring(category.id), sort = 0 } or nil
end
local function queryKey(query)
    if query == nil then return "homepage" end
    assert(type(query) == "table" and query.kind == "category" and type(query.category_id) == "string"
        and query.category_id:match("^[1-9]%d*$") and query.sort == 0, "Expected a canonical category query")
    return "category:" .. query.category_id .. ":0"
end
local function copyQuery(query)
    if not query then return nil end
    return { kind = query.kind, category_id = query.category_id, sort = query.sort }
end
local synopsis = "This original synthetic story follows a traveler across an imagined landscape. "
    .. "The complete synopsis belongs in a detail viewer, leaving the discovery grid compact. "
    .. string.rep("The journey continues through quiet valleys and unfamiliar skies. ", 6)
local titles = { "Moonlit Observatory", "The Last Paper Crane", "A Lighthouse Beyond the Clouds",
    "The Garden of Quiet Stars", "Across the Silver Mountain", "A Quiet Harbor", "The First Morning" }
local sections = { "recommendation", "hot_seller", "internet_hot", "completed" }
local revision = 0
local function snapshot(query, count, options)
    options = options or {}
    revision = revision + 1
    local category = query ~= nil
    local value = { items = {}, stale = options.stale == true, updated_at = 1234567890 + revision,
        source = category and "official_category" or "official_homepage", personalized = false,
        identity = { account_key = "anonymous", query_key = queryKey(query), revision = revision },
        has_more = category and options.has_more ~= false or false, can_load_more = false,
        limit_reached = category and options.limit_reached == true or false }
    if category then
        value.loaded_pages = options.loaded_pages or (count == 0 and 0 or math.ceil(count / 18))
        value.next_page = value.loaded_pages + 1
        value.can_load_more = value.has_more and not value.limit_reached
    end
    local base = category and tonumber(query.category_id) * 1000 or 1000
    for index = 1, count do
        value.items[index] = { id = tostring(base + index), title = titles[(index - 1) % #titles + 1] .. " " .. index,
            authors = { "Synthetic example author" }, favorite = false,
            cover_path = output .. "/fixtures/synthetic-cover-" .. ((index - 1) % 5 + 1) .. ".png",
            latest_episode_title = "A New Horizon", latest_order = 12,
            extra = { recommendation = synopsis, tags = { "Adventure", "Example" },
                recommendation_section = sections[(index - 1) % #sections + 1] } }
    end
    return value
end
local controller = { snapshots = {}, directory = directory(), calls = {}, waiting = {}, covers = {}, invalid_covers = {},
    forbidden = {}, catalog_covers = {}, comics = {} }
function controller:getAccount() return { account_key = "anonymous" } end
function controller:getLibrary() return {} end
function controller:getSetting(_key, default) return default end
function controller:cancelPendingRead() end
function controller:getBookstore(query)
    local key = queryKey(query)
    if not self.snapshots[key] then self.snapshots[key] = snapshot(query, 0, { stale = true, has_more = false }) end
    return self.snapshots[key]
end
function controller:getBookstoreCategories() return self.directory end
function controller:saveSnapshot(query, value)
    assert(value.identity.query_key == queryKey(query), "The fixture must never publish a response into another query cache")
    self.snapshots[queryKey(query)] = value
    for _index, comic in ipairs(value.items) do self.comics[comic.id] = comic end
end
function controller:getComic(id) return self.comics[tostring(id)] end
function controller:getEpisodes(id)
    return { { id = "episode-1", comic_id = tostring(id), title = "Opening", short_title = "1", order = 1, access = "free" },
        { id = "episode-2", comic_id = tostring(id), title = "The Far Shore", short_title = "2", order = 2, access = "locked" } }
end
function controller:requestBookstoreCover(id, identity)
    id = tostring(type(id) == "table" and id.id or id)
    local cached = type(identity) == "table" and self.snapshots[identity.query_key]
    local member = false
    for _index, comic in ipairs(cached and cached.items or {}) do if comic.id == id then member = true end end
    local accepted = member and identity.account_key == "anonymous" and identity.revision == cached.identity.revision
    local call = { id = id, identity = identity, accepted = not not accepted }
    self.covers[#self.covers + 1] = call
    if not accepted then self.invalid_covers[#self.invalid_covers + 1] = call end
end
function controller:requestCover(id) self.catalog_covers[#self.catalog_covers + 1] = tostring(id) end
function controller:enqueue(method, query, callback)
    local request = { method = method, query = copyQuery(query), key = queryKey(query), callback = callback }
    self.calls[#self.calls + 1] = request
    self.waiting[#self.waiting + 1] = request
    return request
end
function controller:refreshBookstore(query, callback)
    if type(query) == "function" then callback, query = query, nil end
    return self:enqueue("refreshBookstore", query, callback)
end
function controller:loadMoreBookstore(query, callback) return self:enqueue("loadMoreBookstore", query, callback) end
function controller:refreshBookstoreCategories(callback) return self:enqueue("refreshBookstoreCategories", nil, callback) end
function controller:refreshComic(id, callback)
    local request = self:enqueue("refreshComic", nil, callback)
    request.comic_id = tostring(id)
    return request
end
for _index, method in ipairs({ "readEpisode", "resolveReadingEpisode", "quotePurchase", "purchase", "downloadEpisodes",
    "getWallet", "refreshWallet", "importSession", "beginQRLogin", "setFavorite", "getCategories", "getRankings", "getPersonalized" }) do
    controller[method] = function()
        controller.forbidden[#controller.forbidden + 1] = method
        error("This anonymous category check forbids " .. method)
    end
end
local function pending(method, query)
    for _index, request in ipairs(controller.waiting) do
        if request.method == method and request.key == queryKey(query) then return request end
    end
    error("Expected controlled callback: " .. method .. " " .. queryKey(query))
end
local function finish(request, value, err)
    local found
    for index, waiting in ipairs(controller.waiting) do
        if waiting == request then found = table.remove(controller.waiting, index); break end
    end
    assert(found, "The controlled response must be pending")
    if request.method == "refreshBookstore" or request.method == "loadMoreBookstore" then
        if value then controller:saveSnapshot(request.query, value)
        else controller:getBookstore(request.query).stale = true end
    elseif request.method == "refreshBookstoreCategories" and value then controller.directory = value end
    request.callback(value, err)
end
local function requestCount(method)
    local count = 0
    for _index, request in ipairs(controller.calls) do if request.method == method then count = count + 1 end end
    return count
end
local screens = Screens.new{ controller = controller }
local function button(message)
    for _index, row in ipairs(screens.focus) do for _index, control in ipairs(row) do
        if control.text == _(message) and control.callback then return control end
    end end
end
local function press(message)
    local control = assert(button(message), "Expected visible bookstore control: " .. message)
    assert(control.enabled ~= false, "Expected enabled bookstore control: " .. message)
    control.callback()
end
local function dialogOption(message)
    for _index, row in ipairs(assert(screens.dialog).buttons) do for _index, control in ipairs(row) do
        local label = control.text and control.text:gsub("^%[x%] ", ""):gsub("^%[ %] ", "")
        if label == _(message) then return control end
    end end
    error("Expected category picker option: " .. message)
end
local function dialogTitleContains(message)
    return screens.dialog and type(screens.dialog.title) == "string"
        and screens.dialog.title:find(_(message), 1, true) ~= nil
end
local function openPicker()
    local control = assert(screens.bookstore_category_button, "Expected the native category toolbar control")
    assert(control.enabled ~= false, "The category picker must remain available")
    control.callback()
    return assert(screens.dialog)
end
local function choose(category)
    screens:_selectBookstoreCategory(category)
end
local function cardIDs()
    local ids = {}
    for _index, card in ipairs(screens.cards or {}) do ids[#ids + 1] = tostring(card.comic.id) end
    return ids
end
local function firstID(query, index) return tostring((query and tonumber(query.category_id) * 1000 or 1000) + (index or 1)) end
local function capture(name)
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
local function coverImage(widget, file)
    if widget.file == file then return widget end
    for _index, child in ipairs(widget) do
        if type(child) == "table" then local found = coverImage(child, file); if found then return found end end
    end
end
local function checkGrid(name)
    UIManager:forceRePaint()
    check(name .. "_native_two_row_capacity", #screens.cards == expected_capacity
        and screens.grid_columns == expected_columns and screens.grid_rows == 2)
    if width == 600 and height == 800 then check(name .. "_six_visible_cards_at_600x800", #screens.cards == 6) end
    local index, rows, bottom = 0, {}, 0
    for _index, row in ipairs(screens.focus) do if row[1] and row[1].comic then rows[#rows + 1] = row end end
    for row_index, row in ipairs(rows) do
        for column, card in ipairs(row) do
            index = index + 1
            bottom = math.max(bottom, card.dimen.y + card.dimen.h)
            check(name .. "_card_bounds_" .. index, card.dimen.x >= 0 and card.dimen.y >= 0
                and card.dimen.x + card.dimen.w <= width and card.dimen.y + card.dimen.h <= height)
            check(name .. "_focus_order_" .. index, screens.cards[index] == card)
            local image = coverImage(card, card.comic.cover_path)
            local size = image and image:getSize()
            check(name .. "_portrait_cover_" .. index, size and size.h > size.w and math.abs(size.h / size.w - 4 / 3) <= 0.08)
            check(name .. "_compact_synopsis_" .. index, not contains(card, synopsis))
            if column > 1 then
                local previous = row[column - 1].dimen
                check(name .. "_column_alignment_" .. index, card.dimen.y == previous.y and card.dimen.x >= previous.x + previous.w)
            elseif row_index > 1 then
                local previous = rows[row_index - 1][1].dimen
                check(name .. "_row_alignment_" .. row_index, card.dimen.x == previous.x and card.dimen.y >= previous.y + previous.h)
            end
        end
    end
    check(name .. "_all_cards_focusable", index == #screens.cards)
    local controls = {}
    for _index, row in ipairs(screens.focus) do for _index, control in ipairs(row) do
        if not control.comic and control.dimen.y >= bottom then controls[#controls + 1] = control end
    end end
    check(name .. "_one_bottom_navigation_row", #controls == 4 and controls[1].text == _("Bookshelf")
        and controls[2].text == _("Bookstore") and controls[3].text == _("Search") and controls[4].text == _("Downloads")
        and controls[1].dimen.y == controls[4].dimen.y)
end
local function checkCoverScope(name, query)
    controller.covers = {}
    screens:refresh()
    local ids, feed = cardIDs(), controller:getBookstore(query)
    local valid = #controller.covers == #ids
    for index, call in ipairs(controller.covers) do
        valid = valid and call.id == ids[index] and call.accepted and call.identity.query_key == feed.identity.query_key
            and call.identity.account_key == feed.identity.account_key and call.identity.revision == feed.identity.revision
    end
    check(name .. "_visible_cover_scope_matches_query_identity", valid)
end
local function lastCachedPage()
    while screens.page < screens.pages do
        local control = assert(screens.pagination and screens.pagination.next)
        assert(control.enabled ~= false)
        local previous = screens.page
        control.callback()
        assert(screens.page == previous + 1, "A cached-page navigation must advance without waiting for another response")
    end
end

screens:showBookstore()
local initial = pending("refreshBookstore")
check("homepage_initial_load_is_anonymous", initial.query == nil and #screens.cards == 0)
finish(initial, snapshot(nil, 19))
check("homepage_toolbar_identifies_all_and_count", screens.bookstore_category_button.text == _("All recommendations") .. " ▾"
    and contains(screens.widget.content, string.format(_("%d comics"), 19)))
checkGrid("homepage")
checkCoverScope("homepage", nil)
screens.pagination.next.callback()
check("homepage_reaches_a_second_local_page", screens.page == 2)
local home_page_two = table.concat(cardIDs(), ",")
local calls_before_picker = #controller.calls
local picker = openPicker()
local expected_index, category_rows = 1, {}
for _index, row in ipairs(picker.buttons) do
    local count = 0
    for _index, control in ipairs(row) do
        local label = control.text and control.text:gsub("^%[x%] ", ""):gsub("^%[ %] ", "")
        if categories[expected_index] and label == categories[expected_index].name then count = count + 1; expected_index = expected_index + 1 end
    end
    if count > 0 then category_rows[#category_rows + 1] = count end
end
local three_columns = #category_rows == 6
for index, count in ipairs(category_rows) do three_columns = three_columns and count == (index == 6 and 1 or 3) end
check("picker_uses_all_sixteen_official_options_in_three_columns", expected_index == 17 and three_columns)
check("picker_has_the_category_selection_title", dialogTitleContains("Choose a category"))
check("picker_first_row_is_the_all_recommendations_option", picker.buttons[1][1] == dialogOption("All recommendations"))
check("picker_marks_the_selected_all_option", dialogOption("All recommendations").text:find("[x] ", 1, true) == 1)
capture("synthetic-bookstore-categories-picker")
dialogOption("Cancel").callback()
check("cancel_keeps_the_existing_page_and_selection", screens.dialog == nil and screens.bookstore_query == nil
    and screens.page == 2 and table.concat(cardIDs(), ",") == home_page_two and #controller.calls == calls_before_picker)

local query_a, query_b, query_c = categoryQuery(categories[1]), categoryQuery(categories[2]), categoryQuery(categories[3])
openPicker(); dialogOption(categories[1].name).callback()
check("switching_category_resets_local_page_without_borrowing_homepage_cards", screens.page == 1
    and queryKey(screens.bookstore_query) == queryKey(query_a) and #screens.cards == 0)
check("uncached_category_explains_its_loading_state", contains(screens.widget.content, "Loading comics…"))
finish(pending("refreshBookstore", query_a), snapshot(query_a, 18))
check("category_toolbar_counts_loaded_comics", screens.bookstore_category_button.text == categories[1].name .. " ▾"
    and contains(screens.widget.content, string.format(_("Loaded: %d comics"), 18)))
check("category_page_counter_does_not_claim_a_total", screens.pagination.counter.text == string.format(_("Page %d"), 1))
checkGrid("category_a")
checkCoverScope("category_a", query_a)
capture("synthetic-bookstore-categories-loaded")
openPicker()
check("picker_marks_the_current_official_category", dialogOption(categories[1].name).text:find("[x] ", 1, true) == 1)
dialogOption("All recommendations").callback()
check("all_recommendations_restores_its_own_cache_at_page_one", screens.bookstore_query == nil and screens.page == 1
    and cardIDs()[1] == firstID(nil) and #controller.waiting == 0)

controller:getBookstore(query_a).stale = true
choose(categories[1]); local old_a_success = pending("refreshBookstore", query_a)
choose(categories[2]); local current_b_success = pending("refreshBookstore", query_b)
check("uncached_b_never_displays_a_while_its_request_is_pending", #screens.cards == 0 and screens.bookstore_loading)
finish(current_b_success, snapshot(query_b, 18))
local b_visible, b_widget = table.concat(cardIDs(), ","), screens.widget
finish(old_a_success, snapshot(query_a, 18))
check("older_a_success_cannot_replace_b_or_its_loading_state", queryKey(screens.bookstore_query) == queryKey(query_b)
    and table.concat(cardIDs(), ",") == b_visible and screens.widget == b_widget and not screens.bookstore_loading
    and screens.bookstore_error == nil and screens.dialog == nil)
controller:getBookstore(query_a).stale, controller:getBookstore(query_b).stale = true, true
choose(categories[1]); local old_a_error = pending("refreshBookstore", query_a)
choose(categories[2]); local current_b = pending("refreshBookstore", query_b)
finish(current_b, snapshot(query_b, 18))
b_visible, b_widget = table.concat(cardIDs(), ","), screens.widget
finish(old_a_error, nil, { kind = "network" })
check("older_a_error_cannot_attach_to_b", queryKey(screens.bookstore_query) == queryKey(query_b)
    and table.concat(cardIDs(), ",") == b_visible and screens.widget == b_widget and screens.bookstore_error == nil and screens.dialog == nil)
checkCoverScope("category_b_after_out_of_order_callbacks", query_b)

choose(categories[1])
check("stale_category_uses_only_its_own_cached_cards", cardIDs()[1] == firstID(query_a) and screens.bookstore_loading)
check("cached_category_explains_its_refresh_state", contains(screens.widget.content, "Refreshing comics…"))
finish(pending("refreshBookstore", query_a), nil, { kind = "network" })
check("offline_category_failure_retains_its_own_cache", cardIDs()[1] == firstID(query_a)
    and screens.bookstore_error and screens.bookstore_error.kind == "network")
check("cached_category_failure_identifies_the_saved_data", contains(screens.widget.content, "Could not refresh. Showing saved comics."))
checkGrid("category_cached_offline")
capture("synthetic-bookstore-categories-cached-offline")
choose(categories[3])
check("uncached_category_does_not_borrow_the_previous_category", #screens.cards == 0 and screens.bookstore_loading)
finish(pending("refreshBookstore", query_c), nil, { kind = "network" })
check("offline_uncached_category_remains_empty", #screens.cards == 0 and queryKey(screens.bookstore_query) == queryKey(query_c))
check("uncached_category_failure_explains_the_connection_requirement", contains(screens.widget.content, "Connect to load this category."))
capture("synthetic-bookstore-categories-uncached-offline")
press("Retry")
finish(pending("refreshBookstore", query_c), snapshot(query_c, 18))
check("retry_stays_scoped_to_the_selected_category", cardIDs()[1] == firstID(query_c))

controller.directory.stale = true
local old_picker = openPicker()
local directory_request = pending("refreshBookstoreCategories")
check("category_directory_loading_is_visible", dialogTitleContains("Loading categories…"))
local stale_option = dialogOption(categories[4].name).callback
local picker_base = screens.widget
screens:refresh()
check("picker_defers_asynchronous_base_repaints", screens.widget == picker_base and screens.dialog == old_picker
    and UIManager:getTopmostVisibleWidget() == old_picker)
finish(directory_request, nil, { kind = "network" })
check("category_directory_failure_keeps_saved_choices_and_explains_retry",
    dialogTitleContains("Could not update categories. Choose a saved category.")
    and dialogOption(categories[4].name) and dialogOption("Retry").enabled ~= false
    and screens.widget == picker_base and UIManager:getTopmostVisibleWidget() == screens.dialog)
local directory_retry_count = requestCount("refreshBookstoreCategories")
local retry_directory = dialogOption("Retry").callback
retry_directory()
local directory_retry = pending("refreshBookstoreCategories")
retry_directory()
check("category_directory_retry_is_visible_and_does_not_duplicate_requests", dialogTitleContains("Loading categories…")
    and requestCount("refreshBookstoreCategories") == directory_retry_count + 1 and #controller.waiting == 1)
finish(directory_retry, directory(false, true))
check("directory_refresh_keeps_the_picker_above_the_unchanged_base", screens.dialog and screens.widget == picker_base
    and UIManager:getTopmostVisibleWidget() == screens.dialog and dialogOption("Updated Mystery"))
local refreshed_picker, calls_before_stale_option = screens.dialog, #controller.calls
stale_option()
check("replaced_picker_callbacks_cannot_change_the_category", screens.dialog == refreshed_picker
    and queryKey(screens.bookstore_query) == queryKey(query_c) and #controller.calls == calls_before_stale_option)
capture("synthetic-bookstore-categories-picker-refreshed")
dialogOption("Cancel").callback()
check("closing_picker_applies_the_deferred_base_repaint", screens.dialog == nil and screens.widget ~= picker_base
    and UIManager:getTopmostVisibleWidget() == screens.widget)
controller.directory = { items = {}, stale = true, source = "official_categories" }
openPicker()
check("an_empty_category_directory_shows_loading_without_invented_choices", dialogTitleContains("Loading categories…")
    and #screens.dialog.buttons == 2)
finish(pending("refreshBookstoreCategories"), nil, { kind = "network" })
check("an_empty_category_directory_failure_explains_how_to_retry",
    dialogTitleContains("Categories could not be loaded. Retry to choose a category.")
    and #screens.dialog.buttons == 3 and dialogOption("Retry").enabled ~= false)
dialogOption("Retry").callback()
finish(pending("refreshBookstoreCategories"), directory())
check("retry_populates_only_the_returned_category_directory", dialogTitleContains("Choose a category")
    and not dialogTitleContains("Categories could not be loaded. Retry to choose a category.")
    and dialogOption(categories[1].name) and dialogOption(categories[16].name))
dialogOption("Cancel").callback()
controller.directory.stale = true
openPicker(); local obsolete_directory = pending("refreshBookstoreCategories")
screens:showSearch(); local search_widget = screens.widget
finish(obsolete_directory, directory())
check("navigation_retires_an_old_category_directory_response", screens.route == "search" and screens.dialog == nil
    and screens.widget == search_widget and UIManager:getTopmostVisibleWidget() == search_widget)

controller:saveSnapshot(query_a, snapshot(query_a, 18))
screens:showBookstore(); choose(categories[1])
local append_count = requestCount("loadMoreBookstore")
lastCachedPage()
check("cached_category_pages_do_not_fetch_more_early", requestCount("loadMoreBookstore") == append_count)
local old_page, old_count = screens.page, #controller:getBookstore(query_a).items
local next_control = assert(screens.pagination.next)
check("the_last_cached_page_offers_the_next_server_page", next_control.enabled ~= false)
next_control.callback()
local append = pending("loadMoreBookstore", query_a)
check("append_loading_uses_the_existing_grid_and_next_arrow", contains(screens.widget.content, "Loading more comics…")
    and screens.page == old_page and #controller:getBookstore(query_a).items == old_count)
next_control.callback()
check("repeated_next_clicks_share_one_append_request", requestCount("loadMoreBookstore") == append_count + 1
    and #controller.waiting == 1 and screens.page == old_page)
finish(append, snapshot(query_a, 36, { loaded_pages = 2 }))
local first_new_page = math.floor(old_count / expected_capacity) + 1
local first_visible = (first_new_page - 1) * expected_capacity + 1
local new_item_visible = false
for _index, id in ipairs(cardIDs()) do if id == firstID(query_a, 19) then new_item_visible = true end end
check("append_lands_on_the_page_containing_the_first_new_comic", screens.page == first_new_page
    and cardIDs()[1] == firstID(query_a, first_visible) and new_item_visible,
    { old_page = old_page, new_page = screens.page, capacity = expected_capacity, first_new_index = 19 })
check("append_keeps_partial_last_page_in_place_or_advances_a_full_page",
    screens.page == old_page + (old_count % expected_capacity == 0 and 1 or 0))
checkGrid("category_appended")
checkCoverScope("category_appended", query_a)
capture("synthetic-bookstore-categories-appended")
lastCachedPage()
local terminal_page = screens.page
local terminal_cards = table.concat(cardIDs(), ",")
screens.pagination.next.callback()
finish(pending("loadMoreBookstore", query_a), nil, { kind = "network" })
check("append_failure_preserves_loaded_cards_and_explains_next_arrow_retry", screens.page == terminal_page
    and #controller:getBookstore(query_a).items == 36 and table.concat(cardIDs(), ",") == terminal_cards
    and contains(screens.widget.content, "Could not load more. Tap the next arrow to retry.")
    and screens.pagination.next.enabled ~= false)
local append_retry_count = requestCount("loadMoreBookstore")
local retry_append = screens.pagination.next
retry_append.callback()
retry_append.callback()
check("repeated_append_retry_clicks_dispatch_only_one_request", requestCount("loadMoreBookstore") == append_retry_count + 1
    and #controller.waiting == 1 and screens.page == terminal_page
    and table.concat(cardIDs(), ",") == terminal_cards and contains(screens.widget.content, "Loading more comics…"))
finish(pending("loadMoreBookstore", query_a), snapshot(query_a, 36, { loaded_pages = 3, has_more = false }))
check("an_empty_server_page_marks_the_real_end_without_losing_loaded_comics", screens.page == terminal_page
    and #controller:getBookstore(query_a).items == 36 and controller:getBookstore(query_a).has_more == false
    and controller:getBookstore(query_a).limit_reached == false and screens.pagination.next.enabled == false)
check("server_end_is_identified_as_complete", contains(screens.widget.content, "All available comics are loaded.")
    and not contains(screens.widget.content, "Browsing limit reached. Use Search to find more comics."))
capture("synthetic-bookstore-categories-server-end")
choose(nil)
controller:saveSnapshot(query_a, snapshot(query_a, 90, { loaded_pages = 5, limit_reached = true }))
choose(categories[1]); lastCachedPage()
local limited_count = requestCount("loadMoreBookstore")
check("the_ninety_comic_limit_disables_append_without_claiming_server_end", #controller:getBookstore(query_a).items == 90
    and controller:getBookstore(query_a).has_more == true and controller:getBookstore(query_a).limit_reached == true
    and screens.pagination.next.enabled == false)
check("the_browsing_limit_is_distinct_from_the_server_end",
    contains(screens.widget.content, "Browsing limit reached. Use Search to find more comics.")
    and not contains(screens.widget.content, "All available comics are loaded."))
screens.pagination.next.callback()
check("disabled_limit_navigation_cannot_dispatch_another_request", requestCount("loadMoreBookstore") == limited_count)
capture("synthetic-bookstore-categories-cache-limit")

choose(nil)
local synopsis_card, calls_before_synopsis = screens.cards[1], #controller.calls
synopsis_card:onHoldSelect()
check("hold_keeps_the_full_synopsis_out_of_the_grid_and_never_reads", screens.route == "bookstore" and screens.dialog
    and screens.dialog.text == synopsis and #controller.calls == calls_before_synopsis and #controller.forbidden == 0)
capture("synthetic-bookstore-categories-synopsis")
local synopsis_dialog, synopsis_base = screens.dialog, screens.widget
screens:refresh()
check("synopsis_still_defers_base_repaint", screens.dialog == synopsis_dialog and screens.widget == synopsis_base
    and UIManager:getTopmostVisibleWidget() == synopsis_dialog)
synopsis_dialog:onClose()
check("synopsis_close_restores_the_refreshed_grid", screens.dialog == nil and screens.widget ~= synopsis_base
    and UIManager:getTopmostVisibleWidget() == screens.widget)
screens.cards[1]:onHoldSelect()
local old_synopsis_close = assert(screens.dialog.close_callback)
screens:showSearch(); search_widget = screens.widget
old_synopsis_close()
check("obsolete_synopsis_close_cannot_restore_the_bookstore", screens.route == "search" and screens.dialog == nil and screens.widget == search_widget)
screens:showBookstore(); choose(nil)
local selected = screens.cards[1]
selected:onTapSelect()
local catalog = pending("refreshComic")
check("tap_opens_only_the_selected_chapter_catalog", screens.route == "comic" and screens.comic_id == firstID(nil)
    and catalog.comic_id == firstID(nil))
finish(catalog, true)
capture("synthetic-bookstore-categories-chapters")
screens:showBookstore(); choose(nil)
local obsolete_card, calls_before_navigation = screens.cards[1], #controller.calls
screens:showSearch()
obsolete_card.callback(); obsolete_card.hold_callback()
check("obsolete_grid_callbacks_cannot_open_catalog_or_synopsis", screens.route == "search" and screens.dialog == nil
    and #controller.calls == calls_before_navigation)
check("all_cover_requests_respect_their_query_revision", #controller.invalid_covers == 0, controller.invalid_covers)
check("all_category_scenarios_preserve_reader_purchase_and_account_isolation", #controller.forbidden == 0, controller.forbidden)
check("all_controlled_requests_have_completed", #controller.waiting == 0)
screens:close()
result.passed = true
for _index, assertion in ipairs(result.assertions) do if not assertion.passed then result.passed = false end end
local file = assert(io.open(output .. "/bookstore-categories-result.json", "wb"))
file:write(json.encode(result, { pretty = true })); file:close()
print(json.encode({ passed = result.passed, assertions = #result.assertions, width = width, height = height, language = arg[3] }))
os.exit(result.passed and 0 or 1)
