-- Exercise the production native bookshelf with synthetic art and controlled callbacks.
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
local Model = require("bilicomics/ui/model")
local W = require("bilicomics/ui/widgets")
local json = require("rapidjson")
local _ = require("bilicomics/ui/i18n")
local width, height = Device.screen:getWidth(), Device.screen:getHeight()
local result = { assertions = {}, screenshots = {}, language = arg[3], width = width, height = height,
    scope = "Native KOReader widgets; original synthetic cover illustrations; controlled controller; no account or HTTP" }
local function check(name, value, detail)
    result.assertions[#result.assertions + 1] = { name = name, passed = not not value, detail = detail }
end
local function findText(widget, message)
    for _index, child in ipairs(widget) do
        if type(child) == "table" then local found = findText(child, message); if found then return found end end
    end
    if widget.text == _(message) then return widget end
end
local function contains(widget, message) return findText(widget, message) ~= nil end
local titles = { "Moonlit Observatory", "The Last Paper Crane", "A Lighthouse Beyond the Clouds",
    "The Garden of Quiet Stars", "Across the Silver Mountain" }
local controller = { calls = {}, waiting = {}, covers = {}, comics = {}, history = {}, library_kinds = {}, canceled_reads = 0, account_key = "synthetic-a" }
local function populate(amount)
    controller.comics = {}
    for index = 1, amount do
        local known = index % 3 ~= 0
        controller.comics[index] = { id = tostring(index), title = titles[(index - 1) % #titles + 1],
            cover_path = output .. "/fixtures/synthetic-cover-" .. ((index - 1) % #titles + 1) .. ".png",
            current_episode_id = known and "2" or nil, progress_source = index == 1 and "local" or nil,
            reading_position = index == 1 and { episode_id = "2", index = 7, revision = "synthetic-r1" } or nil,
            latest_episode_title = "Special festival", finished = index % 4 == 0, has_update = index % 2 == 1,
            favorite = true }
    end
end
populate(19)
function controller:getAccount() return { id = self.account_key, account_key = self.account_key } end
function controller:getLibrary(kind)
    self.library_kinds[#self.library_kinds + 1] = kind
    return kind == "favorites" and self.comics or self.history
end
function controller:getComic(id) return self.comics[tonumber(id)] end
function controller:getEpisodes(id)
    return { { id = "1", comic_id = tostring(id), title = "Opening", short_title = "1", access = "free", order = 1 },
        { id = "2", comic_id = tostring(id), title = "A New Horizon", short_title = "2", access = "owned", order = 2,
            total_pages = 45, current_revision = "synthetic-r1" },
        { id = "3", comic_id = tostring(id), title = "The Far Shore", short_title = "3", access = "locked", order = 3 } }
end
function controller:requestCover(id) self.covers[#self.covers + 1] = tostring(id) end
function controller:cancelPendingRead() self.canceled_reads = self.canceled_reads + 1 end
function controller:getPendingPurchases() return {} end
function controller:getWallet() return {} end
function controller:getSetting(_key, default) return default end
function controller:getStorageSummary() return {} end
function controller:enqueue(method, args, callback)
    self.calls[#self.calls + 1] = { method = method, args = args }
    self.waiting[#self.waiting + 1] = { method = method, args = args, callback = callback }
end
function controller:resolveReadingEpisode(id, callback) self:enqueue("resolveReadingEpisode", { id }, callback) end
function controller:readEpisode(comic_id, episode_id, callback) self:enqueue("readEpisode", { comic_id, episode_id }, callback) end
function controller:refreshComic(id, callback) self:enqueue("refreshComic", { id }, callback) end
function controller:refreshLibrary(kind, callback) self:enqueue("refreshLibrary", { kind }, callback) end
function controller:quotePurchase(id, scope, payment, callback) self:enqueue("quotePurchase", { id, scope, payment }, callback) end
function controller:purchase() error("Purchases are forbidden in this synthetic bookshelf check") end
local function finish(value, err)
    local request = assert(table.remove(controller.waiting, 1), "Expected a controlled callback")
    request.callback(value, err)
end
local screens = Screens.new{ controller = controller }
local function press(message)
    for _index, row in ipairs(screens.focus) do for _index, button in ipairs(row) do
        if button.text == _(message) and button.callback and button.enabled ~= false then return button.callback() end
    end end
    error("Expected visible control: " .. message)
end
local function dialogPress(message)
    for _index, row in ipairs(assert(screens.dialog).buttons) do for _index, button in ipairs(row) do
        local label = type(button.text) == "string" and button.text:gsub("^%[x%] ", ""):gsub("^%[ %] ", "")
        if label == _(message) and button.callback and button.enabled ~= false then return button.callback() end
    end end
    error("Expected dialog control: " .. message)
end
local function pagerPress(direction)
    local button = assert(assert(screens.pagination)[direction], "Expected compact pagination control")
    assert(button.enabled ~= false, "Expected an enabled compact pagination control")
    return button.callback()
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
local function gridGeometry(name)
    UIManager:forceRePaint()
    local expected_columns = width >= 900 and 4 or width >= 600 and 3 or 2
    check(name .. "_responsive_columns", screens.grid_columns == expected_columns)
    check(name .. "_standard_screen_uses_two_bookshelf_rows", screens.grid_rows == 2)
    local card_rows, positions = {}, {}
    for _index, row in ipairs(screens.focus) do
        if row[1] and row[1].comic then card_rows[#card_rows + 1] = row end
    end
    local index = 0
    for row_index, row in ipairs(card_rows) do
        check(name .. "_focus_row_width_" .. row_index, #row == math.min(expected_columns, #screens.cards - index))
        for column, card in ipairs(row) do
            index = index + 1
            local dimen = card.dimen
            positions[index] = { id = card.comic.id, x = dimen.x, y = dimen.y, w = dimen.w, h = dimen.h }
            check(name .. "_focus_identity_" .. index, screens.cards[index] == card)
            check(name .. "_card_bounds_" .. index, dimen.x >= 0 and dimen.y >= 0
                and dimen.x + dimen.w <= width and dimen.y + dimen.h <= height)
            local title_widget, progress_widget = findText(card, card.comic.title), findText(card, card.progress_label)
            check(name .. "_readable_title_and_position_" .. index, title_widget and progress_widget
                and title_widget.height == W.scale(40) and progress_widget.height == W.scale(20)
                and title_widget.face.size >= Font:getFace("cfont", W.font.card).size
                and progress_widget.face.size >= Font:getFace("cfont", W.font.meta).size)
            local updated = card.comic.has_update == true
            check(name .. "_update_uses_an_explicit_compact_badge_" .. index, card.updated == updated
                and (updated and card.update_badge and contains(card.update_badge, "Updated")
                    or not updated and card.update_badge == nil)
                and not contains(card, card.comic.latest_episode_title) and not contains(card, Model.comicUpdate(card.comic)))
            check(name .. "_badge_does_not_change_card_height_" .. index, card:getSize().h == card.frame:getSize().h
                and card.dimen.h == card.frame:getSize().h
                and (not card.update_badge or card.update_badge:getSize().w <= card.card_cover_width
                    and card.update_badge:getSize().h <= card.cover_height))
            if column > 1 then
                local previous = row[column - 1].dimen
                check(name .. "_horizontal_gap_" .. index, dimen.x >= previous.x + previous.w + W.scale(8)
                    and dimen.y == previous.y and dimen.h == previous.h)
            elseif row_index > 1 then
                local previous = card_rows[row_index - 1][1].dimen
                check(name .. "_row_alignment_" .. row_index, dimen.x == previous.x and dimen.y >= previous.y + previous.h + W.scale(8))
            end
        end
    end
    check(name .. "_every_card_has_one_focus_slot", index == #screens.cards)
    result[name] = positions
end
local function toolbarGeometry(name)
    UIManager:forceRePaint()
    local controls = assert(screens.bookshelf_toolbar_buttons, "Bookshelf controls must share one toolbar")
    local expected = { assert(screens.bookshelf_filter_button), assert(screens.bookshelf_sort_button) }
    if screens.pagination then
        expected[#expected + 1], expected[#expected + 2], expected[#expected + 3] =
            screens.pagination.previous, screens.pagination.counter, screens.pagination.next
    end
    check(name .. "_one_toolbar_contains_only_filter_sort_and_pagination", #controls == #expected
        and screens.bookshelf_toolbar:getSize().w <= screens.width)
    local focus_rows = 0
    for _row_index, row in ipairs(screens.focus) do
        for _control_index, control in ipairs(controls) do
            for _item_index, item in ipairs(row) do
                if item == control then
                    if _control_index == 1 then focus_rows = focus_rows + 1 end
                    check(name .. "_toolbar_focus_is_not_split_" .. _control_index, row == controls)
                end
            end
        end
    end
    check(name .. "_toolbar_has_one_native_focus_row", focus_rows == 1)
    local center = controls[1].dimen.y + controls[1].dimen.h / 2
    for index, control in ipairs(controls) do
        check(name .. "_toolbar_order_and_geometry_" .. index, control == expected[index] and control.bordersize == 0
            and math.abs(control.dimen.y + control.dimen.h / 2 - center) <= 1
            and control.dimen.x >= 0 and control.dimen.x + control.dimen.w <= width
            and (index == 1 or control.dimen.x >= controls[index - 1].dimen.x + controls[index - 1].dimen.w))
    end
    check(name .. "_toolbar_has_no_stacked_filter_or_refresh_row", not contains(screens.widget.content, "Refresh bookshelf")
        and not contains(screens.widget.content, "Clear filter")
        and not contains(screens.widget.content, string.format(_("Filter: %s"), _("Currently reading"))))
end
local function onlyNavigationBelowCards(name)
    UIManager:forceRePaint()
    local bottom = 0
    for _index, card in ipairs(screens.cards) do bottom = math.max(bottom, card.dimen.y + card.dimen.h) end
    local controls = {}
    for _row_index, row in ipairs(screens.focus) do for _button_index, button in ipairs(row) do
        if not button.comic and button.dimen.y >= bottom then controls[#controls + 1] = button.text end
    end end
    check(name .. "_has_only_navigation_below_covers", #controls == 4 and controls[1] == _("Bookshelf")
        and controls[2] == _("Bookstore") and controls[3] == _("Search") and controls[4] == _("Downloads"), controls)
end
local function pagerGeometry(name)
    UIManager:forceRePaint()
    local pager = assert(screens.pagination, "Multiple bookshelf pages require compact pagination")
    local previous, next_button, counter = assert(pager.previous), assert(pager.next), assert(pager.counter)
    local top = math.huge
    for _index, card in ipairs(screens.cards) do top = math.min(top, card.dimen.y) end
    check(name .. "_pager_is_above_the_first_cover", previous.dimen.y + previous.dimen.h <= top
        and next_button.dimen.y + next_button.dimen.h <= top and counter.dimen.y + counter.dimen.h <= top)
    check(name .. "_compact_counter_shows_the_current_page", counter.text == string.format(_("%d / %d"), screens.page, screens.pages))
    local counter_focused = false
    for _index, row in ipairs(screens.focus) do
        if row == screens.bookshelf_toolbar_buttons and row[3] == previous and row[4] == counter and row[5] == next_button then
            counter_focused = true
        end
    end
    check(name .. "_page_counter_is_an_actionable_focus_target", counter_focused and type(counter.callback) == "function"
        and counter.enabled ~= false and counter.text_font_size >= W.font.meta)
    local counter_center = counter.dimen.y + counter.dimen.h / 2
    check(name .. "_page_counter_and_arrows_share_a_center_line",
        math.abs(counter_center - previous.dimen.y - previous.dimen.h / 2) <= 1
        and math.abs(counter_center - next_button.dimen.y - next_button.dimen.h / 2) <= 1)
    local navigation = screens.focus[#screens.focus][1]
    check(name .. "_pager_is_compact_and_borderless", previous.bordersize == 0 and next_button.bordersize == 0
        and previous.dimen.h < navigation.dimen.h and next_button.dimen.h < navigation.dimen.h)
    onlyNavigationBelowCards(name)
    toolbarGeometry(name)
end

local Main = dofile(plugin .. "/main.lua")
Main.onShowBiliComics({ _open = function(_self, callback) callback(controller, screens) end })
check("main_entry_defaults_to_bookshelf", screens.route == "favorites")
local tabs = screens.focus[#screens.focus]
check("bookshelf_is_the_first_tab", tabs[1].text == _("Bookshelf") and tabs[2].text == _("Bookstore")
    and tabs[3].text == _("Search") and tabs[4].text == _("Downloads"))
check("navigation_has_no_separate_history_tab", not contains(screens.widget.content, "History"))
check("default_bookshelf_is_selected", tabs[1].selected == true and tabs[1].text_font_bold == true
    and tabs[2].selected == false and tabs[2].text_font_bold == false
    and tabs[1][1].invert ~= true and tabs[2][1].invert ~= true)
capture("synthetic-bookshelf")
gridGeometry("first_page")
pagerGeometry("first_page")
check("first_page_meets_the_compact_bookshelf_capacity", #screens.cards >= (width >= 900 and 8 or width >= 600 and 6 or 4), #screens.cards)
check("first_page_disables_previous_but_keeps_next", screens.pagination.previous.enabled == false
    and screens.pagination.next.enabled ~= false)
check("chapter_and_local_page_are_visible", screens.cards[1].progress == string.format(_("Read to: %s · %d/%d"), string.format(_("Chapter %s"), "2"), 7, 45))
check("compact_position_keeps_chapter_and_verified_page_ratio", screens.cards[1].progress_label == string.format(_("Ch. %s"), "2") .. " · 7/45"
    and contains(screens.cards[1], screens.cards[1].progress_label))
check("latest_update_is_not_reading_progress", screens.cards[1].update == string.format(_("Latest: %s"), "Special festival")
    and not screens.cards[1].progress:find("Special festival", 1, true)
    and not contains(screens.cards[1], screens.cards[1].update) and screens.cards[1].update_badge ~= nil)
local capacity = #screens.cards
check("only_visible_covers_are_requested", #controller.covers == capacity)
local selected_card = screens.cards[2]
for row_index, row in ipairs(screens.focus) do
    if row[2] == selected_card then screens.widget:moveFocusTo(2, row_index, 4); break end
end
check("panel_moves_native_focus_to_cover", screens.widget:getFocusItem() == selected_card and selected_card.frame.color == W.ink)
screens:refresh()
local restored_card = screens.widget:getFocusItem()
check("repaint_preserves_focused_comic_and_border", restored_card ~= selected_card
    and restored_card.comic.id == selected_card.comic.id and restored_card.frame.color == W.ink)
populate(capacity * 2 + 1)
screens:refresh()
local old_page_card = screens.cards[1]
local canceled_reads = controller.canceled_reads
pagerPress("next")
check("page_change_cancels_pending_reader_handoff", controller.canceled_reads == canceled_reads + 1)
local before = #controller.calls
old_page_card.callback(); old_page_card.hold_callback()
check("previous_page_card_callbacks_are_retired", #controller.calls == before and screens.route == "favorites" and screens.page == 2)
-- Recover the intended route so a failed retirement assertion cannot contaminate subsequent geometry checks.
if screens.route ~= "favorites" then screens:showLibrary(); screens.page = 2; screens:refresh(); controller.waiting = {} end
check("second_page_starts_after_previous_capacity", screens.cards[1].comic.id == tostring(capacity + 1))
gridGeometry("second_page")
pagerPress("next")
check("last_page_contains_the_remainder", screens.page == 3 and #screens.cards == 1
    and screens.cards[1].comic.id == tostring(capacity * 2 + 1))
capture("synthetic-bookshelf-last-page")
gridGeometry("last_page")
pagerGeometry("last_page")
check("last_page_disables_next_but_keeps_previous", screens.pagination.next.enabled == false
    and screens.pagination.previous.enabled ~= false)
check("short_last_row_stays_left_aligned", result.last_page[1].x == result.first_page[1].x)
screens.widget:onNextPage()
check("page_key_clamps_at_last_page", screens.page == 3)
screens.widget:onPreviousPage()
check("page_key_moves_one_grid_page", screens.page == 2)
screens.pagination.counter.callback()
local jump_dialog = assert(screens.dialog, "Expected the page selection dialog")
check("page_counter_opens_explicit_page_selection", jump_dialog.title == _("Go to page"))
jump_dialog._input_widget:setText("0")
dialogPress("Go")
check("invalid_page_keeps_the_existing_grid_and_dialog", screens.page == 2 and screens.dialog == jump_dialog)
jump_dialog._input_widget:setText("1")
dialogPress("Go")
check("valid_page_selection_opens_the_requested_grid_page", screens.page == 1 and screens.dialog == nil
    and screens.cards[1].comic.id == "1")
local resized_focus_id = tostring(capacity + 1)
screens.bookshelf_focused_comic_id, screens.bookshelf_grid_capacity = resized_focus_id, 1
screens:refresh()
local resized_focus = screens.widget:getFocusItem()
check("capacity_change_locates_the_remembered_comic_in_its_new_page", screens.page == 2
    and screens.cards[1].comic.id == resized_focus_id and resized_focus and resized_focus.comic
    and resized_focus.comic.id == resized_focus_id)

screens:showLibrary()
local old_filter_card = screens.cards[1]
press(_("All") .. " ▾"); capture("synthetic-bookshelf-filters")
canceled_reads = controller.canceled_reads
dialogPress("No reading record")
check("filter_change_cancels_pending_reader_handoff", controller.canceled_reads == canceled_reads + 1)
check("unknown_progress_filter_is_not_labeled_unread", screens.filter == "unknown"
    and screens.cards[1] and Model.comicProgress(screens.cards[1].comic, controller:getEpisodes(screens.cards[1].comic.id)).state == "unknown")
before = #controller.calls
old_filter_card.callback()
check("previous_filter_card_callback_is_retired", #controller.calls == before)
controller.waiting = {}
capture("synthetic-bookshelf-no-record")
toolbarGeometry("active_filter")
press(_("No reading record") .. " ▾"); dialogPress("Currently reading")
check("reading_is_a_bookshelf_filter", screens.route == "favorites" and screens.filter == "reading"
    and Model.comicProgress(screens.cards[1].comic, controller:getEpisodes(screens.cards[1].comic.id)).state == "reading")

screens:showLibrary()
local card = screens.cards[1]
card:onFocus()
check("native_card_focus_border_is_visible", card.frame.color == W.ink)
card:onUnfocus()
check("native_card_unfocus_clears_border", card.frame.color == W.paper)
card:onTapSelect()
check("tap_resolves_the_reading_target", controller.waiting[1].method == "resolveReadingEpisode" and controller.waiting[1].args[1] == "1")
finish({ comic = controller.comics[1], episode = controller:getEpisodes("1")[2] })
check("owned_target_dispatches_read", controller.waiting[1].method == "readEpisode" and controller.waiting[1].args[2] == "2")
finish(true)
check("successful_reader_handoff_closes_bookshelf", screens.route == nil and screens.widget == nil)

screens:showLibrary()
canceled_reads = controller.canceled_reads
screens.cards[1]:onTapSelect()
local earlier_target = assert(table.remove(controller.waiting, 1))
screens.cards[2]:onTapSelect()
local latest_target = assert(table.remove(controller.waiting, 1))
check("successive_same_page_taps_retire_prior_read_work", controller.canceled_reads == canceled_reads + 2
    and earlier_target.args[1] == "1" and latest_target.args[1] == "2")
latest_target.callback({ comic = controller.comics[2], episode = controller:getEpisodes("2")[2] })
check("latest_out_of_order_resolution_prepares_the_last_selected_comic", #controller.waiting == 1
    and controller.waiting[1].method == "readEpisode" and controller.waiting[1].args[1] == "2")
before = #controller.calls
earlier_target.callback({ comic = controller.comics[1], episode = controller:getEpisodes("1")[2] })
check("older_resolution_cannot_replace_the_latest_read", #controller.calls == before and #controller.waiting == 1
    and controller.waiting[1].args[1] == "2")
finish(true)

screens:showLibrary()
screens.cards[1]:onTapSelect()
finish({ comic = controller.comics[1], episode = controller:getEpisodes("1")[2] })
local earlier_prepare = assert(table.remove(controller.waiting, 1))
assert(earlier_prepare.method == "readEpisode", "The first comic must have reached reader preparation")
canceled_reads = controller.canceled_reads
screens.cards[2]:onTapSelect()
check("new_same_page_selection_cancels_earlier_reader_preparation", controller.canceled_reads == canceled_reads + 1)
earlier_prepare.callback(true)
check("obsolete_reader_completion_does_not_close_the_new_selection", screens.route == "favorites" and screens.widget ~= nil
    and #controller.waiting == 1 and controller.waiting[1].method == "resolveReadingEpisode" and controller.waiting[1].args[1] == "2")
finish({ comic = controller.comics[2], episode = controller:getEpisodes("2")[2] })
check("replacement_selection_prepares_only_its_own_comic", #controller.waiting == 1
    and controller.waiting[1].method == "readEpisode" and controller.waiting[1].args[1] == "2")
finish(true)

screens:showLibrary()
screens.cards[1]:onTapSelect()
finish({ comic = controller.comics[1], episode = controller:getEpisodes("1")[3] })
check("locked_target_only_requests_a_quote", controller.waiting[1].method == "quotePurchase"
    and controller.calls[#controller.calls].method == "quotePurchase")
finish(nil, { kind = "capability" }); screens:_closeDialog()
screens:showLibrary()
screens.cards[1]:onHoldSelect()
check("hold_opens_chapters_without_reading", screens.route == "comic" and screens.comic_id == "1"
    and controller.waiting[1].method == "refreshComic")
finish(true)
capture("synthetic-chapters-after-hold")

screens:showLibrary()
local navigation_card = screens.cards[1]
canceled_reads = controller.canceled_reads
screens:showSearch()
check("navigation_cancels_pending_reader_handoff", controller.canceled_reads == canceled_reads + 1)
before = #controller.calls
navigation_card.callback(); navigation_card.hold_callback()
check("navigation_retires_card_callbacks", #controller.calls == before and screens.route == "search")
screens:showLibrary()
local account_card = screens.cards[1]
controller.account_key = "synthetic-b"
before = #controller.calls
account_card.callback(); account_card.hold_callback()
check("account_change_retires_card_callbacks", #controller.calls == before and screens.route == "favorites")
controller.account_key = "synthetic-a"
screens:showLibrary()
screens.cards[1].callback()
screens:showSearch()
before = #controller.calls
finish({ comic = controller.comics[1], episode = controller:getEpisodes("1")[2] })
check("navigation_retires_pending_target_resolution", #controller.calls == before and screens.route == "search" and screens.dialog == nil)
screens:showLibrary()
screens.cards[1].callback()
controller.account_key = "synthetic-b"
before = #controller.calls
finish({ comic = controller.comics[1], episode = controller:getEpisodes("1")[2] })
check("account_change_retires_pending_target_resolution", #controller.calls == before and screens.dialog == nil)
controller.account_key = "synthetic-a"; controller.waiting = {}

local full_bookshelf = controller.comics
controller.comics = { full_bookshelf[1], full_bookshelf[2] }
screens:showLibrary()
capture("synthetic-bookshelf-single-page")
check("single_page_hides_compact_pagination", screens.pages == 1 and screens.pagination == nil)
check("single_page_omits_the_redundant_page_count", not contains(screens.widget.content, string.format(_("%d / %d"), 1, 1)))
onlyNavigationBelowCards("single_page")
toolbarGeometry("single_page")
controller.comics = full_bookshelf

controller.history = { controller.comics[1] }
screens:showLibrary("history")
check("legacy_history_entry_opens_bookshelf", screens.route == "favorites" and #screens.cards > 0)
press("More"); dialogPress("Refresh bookshelf")
check("legacy_history_refresh_dispatches_the_bookshelf_collection", controller.waiting[1].method == "refreshLibrary"
    and controller.waiting[1].args[1] == "favorites")
finish(true)
capture("synthetic-legacy-history-entry")
screens:showLibrary("continue")
check("legacy_continue_entry_also_opens_bookshelf", screens.route == "favorites" and #screens.cards > 0)
check("legacy_entries_do_not_render_obsolete_history_messages", not contains(screens.widget.content, "No reading history yet. Open a comic from your bookshelf.")
    and not contains(screens.widget.content, "Nothing here yet. Refresh your library or search for a comic."))
controller.comics = {}
screens:showLibrary()
capture("synthetic-empty-bookshelf")
check("empty_bookshelf_has_its_own_message", #screens.cards == 0
    and contains(screens.widget.content, "Your bookshelf is empty. Find a comic in Bookstore or Search."))
check("empty_bookshelf_also_hides_pagination", screens.pagination == nil)
toolbarGeometry("empty_bookshelf")
controller.history = {}
screens:showLibrary("history")
check("empty_legacy_history_entry_uses_bookshelf_empty_state", screens.route == "favorites"
    and contains(screens.widget.content, "Your bookshelf is empty. Find a comic in Bookstore or Search."))
local library_only = true
for _index, kind in ipairs(controller.library_kinds) do if kind ~= "favorites" then library_only = false end end
check("library_ui_never_requests_a_history_collection", library_only)
canceled_reads = controller.canceled_reads
screens:close()
check("closing_cancels_pending_reader_handoff", controller.canceled_reads == canceled_reads + 1)
result.passed = true
for _index, assertion in ipairs(result.assertions) do if not assertion.passed then result.passed = false end end
local file = assert(io.open(output .. "/bookshelf-grid-result.json", "wb"))
file:write(json.encode(result, { pretty = true })); file:close()
print(json.encode({ passed = result.passed, assertions = #result.assertions, width = width, height = height, language = arg[3] }))
os.exit(result.passed and 0 or 1)
