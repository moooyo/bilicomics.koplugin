-- Exercise the expanded compact bookstore with synthetic recommendations and delayed callbacks.
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
local Font = require("ui/font")
local Screens = require("bilicomics/ui/screens")
local W = require("bilicomics/ui/widgets")
local json = require("rapidjson")
local _ = require("bilicomics/ui/i18n")
local width, height = Device.screen:getWidth(), Device.screen:getHeight()
local expected_columns = width >= 900 and 4 or width >= 600 and 3 or 2
local expected_rows = width > height and 1 or 2
local expected_capacity = expected_columns * expected_rows
local result = { assertions = {}, screenshots = {}, language = arg[3], width = width, height = height,
    scope = "Native bookstore widgets; original synthetic illustrations; anonymous injected data; no HTTP, account, purchase or reader" }
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
local function textWidget(widget, text)
    if widget.text == text and widget.face then return widget end
    for _index, child in ipairs(widget) do
        if type(child) == "table" then
            local found = textWidget(child, text)
            if found then return found end
        end
    end
end
local ids = { "71", "4", "303", "18", "99", "5", "42", "207", "12", "68", "444", "56", "17", "802", "35", "11", "206", "97", "23" }
local titles = { "Moonlit Observatory", "The Last Paper Crane", "A Lighthouse Beyond the Clouds",
    "The Garden of Quiet Stars", "Across the Silver Mountain", "A Quiet Harbor", "The First Morning" }
local sections = { "recommendation", "hot_seller", "internet_hot", "completed" }
local synopsis = "This original synthetic story follows a traveler across an imagined landscape. "
    .. "The complete synopsis belongs in a detail viewer, leaving the discovery grid compact. "
    .. string.rep("The journey continues through quiet valleys and unfamiliar skies. ", 6)
local revision = 0
local function feedIdentity()
    revision = revision + 1
    return { account_key = "anonymous", query_key = "homepage", revision = revision }
end
local function recommendations(stale)
    local value = { items = {}, updated_at = 1234567890, stale = stale or false,
        source = "official_homepage", personalized = false, has_more = false, identity = feedIdentity() }
    for index, id in ipairs(ids) do
        value.items[index] = { id = id, title = titles[(index - 1) % #titles + 1] .. (index > #titles and " " .. index or ""),
            authors = { "Synthetic example author" },
            cover_path = output .. "/fixtures/synthetic-cover-" .. ((index - 1) % 5 + 1) .. ".png",
            latest_episode_title = "A New Horizon", latest_order = 12, favorite = false,
            extra = { recommendation = synopsis, tags = index % 3 == 0 and {} or { "Adventure", "Example" },
                recommendation_section = sections[(index - 1) % #sections + 1] } }
    end
    return value
end
local function emptySnapshot()
    return { items = {}, stale = true, source = "official_homepage", personalized = false, has_more = false,
        identity = feedIdentity() }
end
local controller = { snapshot = emptySnapshot(), calls = {}, waiting = {}, covers = {}, forbidden = {}, catalog_covers = {} }
function controller:getAccount() return { account_key = "anonymous" } end
function controller:getLibrary() return {} end
function controller:getBookstore() return self.snapshot end
function controller:getSetting(_key, default) return default end
function controller:cancelPendingRead() end
function controller:getComic(id)
    for _index, comic in ipairs(recommendations().items) do if comic.id == tostring(id) then return comic end end
end
function controller:getEpisodes(id)
    return { { id = "episode-1", comic_id = tostring(id), title = "Opening", short_title = "1", order = 1, access = "free" },
        { id = "episode-2", comic_id = tostring(id), title = "The Far Shore", short_title = "2", order = 2, access = "locked" } }
end
function controller:requestBookstoreCover(comic)
    self.covers[#self.covers + 1] = tostring(type(comic) == "table" and comic.id or comic)
end
function controller:requestCover(id) self.catalog_covers[#self.catalog_covers + 1] = tostring(id) end
function controller:enqueue(method, args, callback)
    local request = { method = method, args = args, callback = callback }
    self.calls[#self.calls + 1] = request
    self.waiting[#self.waiting + 1] = request
end
function controller:refreshBookstore(callback) self:enqueue("refreshBookstore", {}, callback) end
function controller:refreshComic(id, callback) self:enqueue("refreshComic", { tostring(id) }, callback) end
for _index, method in ipairs({ "readEpisode", "resolveReadingEpisode", "quotePurchase", "purchase", "downloadEpisodes",
    "getWallet", "refreshWallet", "importSession", "beginQRLogin", "setFavorite", "getCategories", "getRankings", "getPersonalized" }) do
    controller[method] = function()
        controller.forbidden[#controller.forbidden + 1] = method
        error("This anonymous bookstore check forbids " .. method)
    end
end
local function finish(value, err)
    local request = assert(table.remove(controller.waiting, 1), "Expected a controlled bookstore callback")
    if request.method == "refreshBookstore" and value then controller.snapshot = value end
    request.callback(value, err)
end
local function requestCount(method)
    local count = 0
    for _index, request in ipairs(controller.calls) do if request.method == method then count = count + 1 end end
    return count
end
local screens = Screens.new{ controller = controller }
local function button(message)
    for _row_index, row in ipairs(screens.focus) do for _button_index, control in ipairs(row) do
        if control.text == _(message) and control.callback then return control end
    end end
end
local function press(message)
    local control = assert(button(message), "Expected visible bookstore control: " .. message)
    assert(control.enabled ~= false, "Expected enabled bookstore control: " .. message)
    control.callback()
end
local function dialogButton(message)
    for _index, row in ipairs(assert(screens.dialog).buttons) do for _index, control in ipairs(row) do
        if control.text == _(message) and control.callback then return control end
    end end
    error("Expected page dialog control: " .. message)
end
local function refreshControl()
    return assert(button("Refresh"), "Expected recommendation refresh control")
end
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
local function cardIDs()
    local found = {}
    for _index, card in ipairs(screens.cards or {}) do found[#found + 1] = tostring(card.comic.id) end
    return found
end
local function coverImage(widget, file)
    if widget.file == file then return widget end
    for _index, child in ipairs(widget) do
        if type(child) == "table" then
            local found = coverImage(child, file)
            if found then return found end
        end
    end
end
local function checkGrid(name)
    UIManager:forceRePaint()
    check(name .. "_has_native_cover_cards", #screens.cards > 0 and screens.grid_columns == expected_columns)
    check(name .. "_uses_the_orientation_capacity", #screens.cards == expected_capacity and screens.grid_rows == expected_rows)
    local index, rows = 0, {}
    for _index, row in ipairs(screens.focus) do if row[1] and row[1].comic then rows[#rows + 1] = row end end
    for row_index, row in ipairs(rows) do
        for column, card in ipairs(row) do
            index = index + 1
            check(name .. "_card_bounds_" .. index, card.dimen.x >= 0 and card.dimen.y >= 0
                and card.dimen.x + card.dimen.w <= width and card.dimen.y + card.dimen.h <= height)
            check(name .. "_focus_matches_visual_order_" .. index, screens.cards[index] == card)
            local title, metadata = textWidget(card, card.text), textWidget(card, card.update)
            check(name .. "_readable_card_fonts_" .. index, title and metadata
                and title.face.size >= Font:getFace("cfont", 16).size
                and metadata.face.size >= Font:getFace("cfont", 14).size)
            local image = coverImage(card, card.comic.cover_path)
            local image_size = image and image:getSize()
            check(name .. "_portrait_cover_ratio_" .. index, image_size and image_size.h > image_size.w
                and math.abs(image_size.h / image_size.w - 4 / 3) <= 0.08)
            check(name .. "_synopsis_is_not_rendered_inside_the_grid_" .. index, not contains(card, synopsis))
            local source_labels = { recommendation = _("Recommended"), hot_seller = _("Bestsellers"),
                internet_hot = _("Trending"), completed = _("Completed picks") }
            local label = source_labels[card.comic.extra.recommendation_section]
            check(name .. "_compact_metadata_identifies_its_section_" .. index,
                type(card.update) == "string" and card.update:find(label, 1, true) == 1)
            if column > 1 then
                local previous = row[column - 1].dimen
                check(name .. "_aligned_card_" .. index, card.dimen.y == previous.y and card.dimen.x >= previous.x + previous.w)
            elseif row_index > 1 then
                local previous = rows[row_index - 1][1].dimen
                check(name .. "_aligned_row_" .. row_index, card.dimen.x == previous.x and card.dimen.y >= previous.y + previous.h)
            end
        end
    end
    check(name .. "_every_card_is_focusable", index == #screens.cards)
    local pagination, focusable = screens.pagination, false
    for _index, row in ipairs(screens.focus) do
        if row[1] == pagination.previous and row[2] == pagination.counter and row[3] == pagination.next then focusable = true end
    end
    check(name .. "_page_counter_is_a_readable_focusable_action", focusable
        and type(pagination.counter.callback) == "function" and pagination.counter.enabled ~= false
        and pagination.counter.text_font_size >= W.font.meta)
    local bottom, controls = 0, {}
    for _index, card in ipairs(screens.cards) do bottom = math.max(bottom, card.dimen.y + card.dimen.h) end
    for _row_index, row in ipairs(screens.focus) do for _button_index, control in ipairs(row) do
        if not control.comic and control.dimen.y >= bottom then controls[#controls + 1] = control.text end
    end end
    check(name .. "_has_only_the_bottom_navigation_row", #controls == 4 and controls[1] == _("Bookshelf")
        and controls[2] == _("Bookstore") and controls[3] == _("Search") and controls[4] == _("Downloads"))
    for index, tab in ipairs(screens.focus[#screens.focus]) do
        check(name .. "_quiet_navigation_state_" .. index, tab.selected == (index == 2)
            and tab.bordersize == 0 and tab.text_font_bold == (index == 2) and tab[1].invert ~= true)
    end
end
local function noFalseControls(name)
    local absent = true
    for _index, message in ipairs({ "History", "Categories", "Browse categories", "Rankings", "For you", "Load more",
        "Buy", "Buy now", "Confirm purchase", "Sign in to see recommendations" }) do
        if contains(screens.widget.content, message) then absent = false end
    end
    check(name .. "_has_no_history_or_unsupported_store_actions", absent)
end

screens:showLibrary()
local tabs = screens.focus[#screens.focus]
check("bookstore_replaces_the_second_tab", #tabs == 4 and tabs[1].text == _("Bookshelf") and tabs[2].text == _("Bookstore")
    and tabs[3].text == _("Search") and tabs[4].text == _("Downloads"))
tabs[2].callback()
check("entering_an_empty_bookstore_loads_anonymously", screens.route == "bookstore" and #controller.waiting == 1
    and controller.waiting[1].method == "refreshBookstore" and #controller.waiting[1].args == 0)
check("initial_load_has_visible_loading_feedback", contains(screens.widget.content, "Loading recommendations…")
    and refreshControl().enabled == false)
screens:refresh(); screens:refresh()
check("repaints_do_not_duplicate_the_initial_refresh", requestCount("refreshBookstore") == 1 and #controller.waiting == 1)
capture("synthetic-bookstore-expanded-loading")
finish(recommendations())
check("recommendations_load_without_a_session", screens.route == "bookstore" and #screens.cards > 0
    and controller.snapshot.personalized == false and controller.snapshot.source == "official_homepage")
check("the_store_identifies_recommendations_count_and_catalog_activation",
    contains(screens.widget.content, _("All recommendations") .. " ▾")
    and contains(screens.widget.content, string.format(_("%d comics"), #ids))
    and contains(screens.widget.content, "Tap: chapters · Hold: synopsis"))
capture("synthetic-bookstore-expanded-recommendations")
checkGrid("loaded")
noFalseControls("loaded")
local visible = cardIDs()
controller.covers = {}
screens:refresh()
local only_visible = #controller.covers == #visible
for index, id in ipairs(controller.covers) do if id ~= visible[index] then only_visible = false end end
check("cover_acquisition_is_limited_to_visible_recommendations", only_visible)
local calls_before_jump, page_before_jump = #controller.calls, screens.page
assert(screens.pagination.counter.callback, "Expected a directly accessible page picker")()
local jump_dialog = assert(screens.dialog)
local jump = dialogButton("Go")
check("page_counter_opens_the_page_picker", jump_dialog.title == _("Go to page"))
for _index, input in ipairs({ "0", "1.5", tostring(screens.pages + 1) }) do
    jump_dialog.getInputText = function() return input end
    jump.callback()
    check("page_picker_rejects_invalid_page_" .. input, screens.dialog == jump_dialog and screens.page == page_before_jump
        and #controller.calls == calls_before_jump)
end
jump_dialog.getInputText = function() return "2" end
jump.callback()
check("page_picker_jumps_to_the_requested_cached_page", screens.dialog == nil and screens.page == 2
    and cardIDs()[1] == ids[expected_capacity + 1] and #controller.calls == calls_before_jump)
local jumped_widget = screens.widget
jump.callback()
check("a_closed_page_picker_cannot_navigate_again", screens.widget == jumped_widget and screens.page == 2
    and #controller.calls == calls_before_jump)
screens.pagination.counter.callback()
local return_dialog = assert(screens.dialog)
return_dialog.getInputText = function() return "1" end
dialogButton("Go").callback()
check("page_picker_can_return_to_the_first_cached_page", screens.dialog == nil and screens.page == 1
    and cardIDs()[1] == ids[1] and #controller.calls == calls_before_jump)
local ordered, page_count = {}, screens.pages
local seen, duplicated = {}, false
for _page = 1, page_count do
    for _index, id in ipairs(cardIDs()) do
        if seen[id] then duplicated = true end
        seen[id], ordered[#ordered + 1] = true, id
    end
    if screens.page == 2 then capture("synthetic-bookstore-expanded-second-page"); checkGrid("second_page") end
    if screens.page < screens.pages then assert(screens.pagination.next.enabled ~= false); screens.pagination.next.callback() end
end
check("pagination_preserves_official_recommendation_order", table.concat(ordered, ",") == table.concat(ids, ","))
check("expanded_feed_has_no_duplicate_or_missing_comics_across_pages", #ids >= 12 and #ordered == #ids and not duplicated)
capture("synthetic-bookstore-expanded-last-page")
check("the_last_local_page_does_not_fetch_another_feed", requestCount("refreshBookstore") == 1
    and (screens.pagination == nil or screens.pagination.next.enabled == false))

screens:showLibrary()
local refresh_count = requestCount("refreshBookstore")
screens:showBookstore()
check("fresh_cached_recommendations_restore_the_previous_page_without_a_new_request",
    requestCount("refreshBookstore") == refresh_count and #screens.cards > 0 and screens.page == page_count)
local synopsis_card = screens.cards[1]
local calls_before_synopsis = #controller.calls
synopsis_card:onHoldSelect()
check("hold_shows_the_full_synopsis_without_reading_or_requests", screens.route == "bookstore" and screens.dialog
    and screens.dialog.text == synopsis and #controller.calls == calls_before_synopsis and #controller.forbidden == 0)
capture("synthetic-bookstore-expanded-synopsis")
local synopsis_dialog, synopsis_base = screens.dialog, screens.widget
screens:refresh()
check("asynchronous_repaint_keeps_the_synopsis_above_the_unchanged_grid", screens.dialog == synopsis_dialog
    and screens.widget == synopsis_base and UIManager:getTopmostVisibleWidget() == synopsis_dialog)
synopsis_dialog:onClose()
check("native_synopsis_close_applies_the_deferred_grid_repaint", screens.dialog == nil and screens.route == "bookstore"
    and screens.widget ~= synopsis_base and UIManager:getTopmostVisibleWidget() == screens.widget)
screens.cards[1]:onHoldSelect()
local stale_synopsis_close = assert(screens.dialog.close_callback)
screens:refresh()
screens:showSearch()
local search_widget = screens.widget
stale_synopsis_close()
check("navigation_retires_an_obsolete_synopsis_close_callback", screens.route == "search" and screens.widget == search_widget
    and screens.dialog == nil and UIManager:getTopmostVisibleWidget() == search_widget)
screens:showBookstore()
local selected = screens.cards[1]
local selected_id = tostring(selected.comic.id)
selected:onTapSelect()
check("recommendation_tap_opens_the_chapter_catalog_only", screens.route == "comic" and screens.comic_id == selected_id
    and #controller.waiting == 1 and controller.waiting[1].method == "refreshComic" and controller.waiting[1].args[1] == selected_id)
finish(true)
capture("synthetic-bookstore-expanded-chapters")
check("opening_recommendations_never_reads_or_buys", #controller.forbidden == 0)

screens:showBookstore()
local obsolete_card = screens.cards[1]
screens:showSearch()
local calls_before = #controller.calls
obsolete_card.callback()
if obsolete_card.hold_callback then obsolete_card.hold_callback() end
check("navigation_retires_old_recommendation_callbacks", #controller.calls == calls_before and screens.route == "search")

controller.snapshot = recommendations(true)
screens:showBookstore()
check("stale_saved_recommendations_remain_visible_during_refresh", #screens.cards > 0 and #controller.waiting == 1)
check("refreshing_keeps_the_same_orientation_capacity", #screens.cards == expected_capacity and screens.grid_rows == expected_rows)
checkGrid("refreshing")
finish(nil, { kind = "network" })
check("offline_refresh_retains_the_saved_recommendations", screens.route == "bookstore" and #screens.cards > 0
    and cardIDs()[1] == ids[1] and #controller.forbidden == 0)
check("offline_cache_feedback_is_explicit", contains(screens.widget.content, "Could not refresh. Showing saved recommendations."))
checkGrid("cached_offline")
capture("synthetic-bookstore-expanded-cached-offline")
screens:_closeDialog()
local refresh = refreshControl()
refresh.callback()
local pending_count = requestCount("refreshBookstore")
refresh.callback()
screens:refresh()
check("repeated_refresh_actions_queue_only_one_request", #controller.waiting == 1 and requestCount("refreshBookstore") == pending_count)
finish(recommendations())

controller.snapshot = emptySnapshot()
screens:showBookstore()
finish(nil, { kind = "network" })
check("first_load_failure_has_no_invented_recommendations", screens.route == "bookstore" and #screens.cards == 0)
check("first_load_failure_explains_connectivity", contains(screens.widget.content, "Connect to load recommendations."))
capture("synthetic-bookstore-expanded-load-error")
screens:_closeDialog()
check("failed_initial_load_can_be_retried", button("Retry") and button("Retry").enabled ~= false)
press("Retry")
check("retry_requests_anonymous_recommendations", #controller.waiting == 1 and controller.waiting[1].method == "refreshBookstore")
finish(recommendations())
check("retry_replaces_the_error_with_recommendations", screens.route == "bookstore" and #screens.cards > 0)
capture("synthetic-bookstore-expanded-retry-loaded")

refreshControl().callback()
screens:showSearch()
finish(nil, { kind = "network" })
check("navigation_retires_delayed_refresh_errors", screens.route == "search" and screens.dialog == nil)
screens:showBookstore()
refreshControl().callback()
screens:showLibrary()
finish(recommendations())
check("navigation_retires_delayed_refresh_success", screens.route == "favorites" and screens.dialog == nil)
screens:showBookstore()
check("returning_after_an_obsolete_refresh_is_usable", #screens.cards > 0 and refreshControl().enabled ~= false)
noFalseControls("returned")
check("all_scenarios_preserve_read_payment_and_account_isolation", #controller.forbidden == 0, controller.forbidden)
screens:close()
result.passed = true
for _index, assertion in ipairs(result.assertions) do if not assertion.passed then result.passed = false end end
local file = assert(io.open(output .. "/bookstore-expanded-result.json", "wb"))
file:write(json.encode(result, { pretty = true })); file:close()
print(json.encode({ passed = result.passed, assertions = #result.assertions, width = width, height = height, language = arg[3] }))
os.exit(result.passed and 0 or 1)
