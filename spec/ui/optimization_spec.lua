-- Exercise the optimized native UI with synthetic metadata and controlled callbacks.
-- Production business modules and all real network or purchase operations are forbidden.
require("setupkoenv")
local output_dir, plugin = assert(arg[1]), assert(arg[2])
local ffi = require("ffi")
require("ffi/posix_h")
if not pcall(function() return ffi.C.readlink end) then
    ffi.cdef[[long readlink(const char *path, char *buffer, unsigned long size);]]
end
local parent_namespace = assert(os.getenv("BILI_UI_PARENT_NETNS"), "The parent namespace is required")
local buffer = ffi.new("char[256]")
local length = tonumber(ffi.C.readlink("/proc/self/ns/net", buffer, 256))
assert(length and length > 0 and length < 256, "Cannot read the current namespace")
assert(ffi.string(buffer, length) ~= parent_namespace, "A separate network namespace is required")
local routes = assert(io.open("/proc/net/route", "rb"))
local route_count = 0
for line in routes:lines() do
    if line:match("%S") and not line:match("^Iface%s") then route_count = route_count + 1 end
end
assert(routes:close())
assert(route_count == 0, "The isolated namespace must have no network routes")

G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local prohibited_modules = { "bilicomics/controller", "bilicomics/runtime", "bilicomics/protocol/client",
    "bilicomics/protocol/transport", "bilicomics/protocol/session", "bilicomics/purchase/service",
    "bilicomics/purchase/quote_fetch", "bilicomics/purchase/quote", "bilicomics/purchase/candidate",
    "bilicomics/purchase/selection" }
for _module_index, module in ipairs(prohibited_modules) do
    assert(package.loaded[module] == nil, "A production business module was already loaded")
    package.preload[module] = function() error("Production business modules are forbidden in this synthetic UI spec") end
end
require("gettext").current_lang = "zh_CN"
local UIManager = require("ui/uimanager")
local json = require("rapidjson")
local Screens = require("bilicomics/ui/screens")
local Model = require("bilicomics/ui/model")
local W = require("bilicomics/ui/widgets")
local _ = require("bilicomics/ui/i18n")
local report = { spec = "native-ui-optimization", synthetic_only = true, actual_purchase_executed = false,
    network_namespace_isolated = true, no_network_routes = true,
    width = Device.screen:getWidth(), height = Device.screen:getHeight(), assertions = {}, screens = {} }
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
local function contains(text, value) return type(text) == "string" and text:find(value, 1, true) ~= nil end
local function visibleText(widget, result, seen)
    result, seen = result or {}, seen or {}
    if type(widget) ~= "table" or seen[widget] then return table.concat(result, "\n") end
    seen[widget] = true
    for _field_index, key in ipairs({ "text", "title", "purchase_text" }) do
        if type(widget[key]) == "string" then result[#result + 1] = widget[key] end
    end
    for _child_index, child in ipairs(widget) do visibleText(child, result, seen) end
    return table.concat(result, "\n")
end
local function findButton(widget, text, seen)
    if type(widget) ~= "table" then return nil end
    seen = seen or {}; if seen[widget] then return nil end; seen[widget] = true
    if type(widget.text) == "string" and type(widget.callback) == "function" then
        local label = widget.text:gsub("^%[[x ]%] ", ""):gsub(" ▾$", "")
        if widget.text == text or label == text then return widget end
    end
    for _child_index, child in ipairs(widget) do
        local button = findButton(child, text, seen); if button then return button end
    end
end
local controller = { generation = 1, account_key = "bili_optimization_fixture", calls = {}, waiting = {}, forbidden = {},
    settings = { search_history = { "Earlier search" } }, comics = {}, episodes = {}, jobs = {}, purchases = {} }
local allowed = { search = true, quotePurchase = true, reconcilePurchase = true, setSetting = true, cancelPendingRead = true }
local function record(method, args)
    assert(allowed[method], "Unexpected synthetic operation")
    local call = { method = method, args = copy(args or {}) }
    controller.calls[#controller.calls + 1] = call; return call
end
local function enqueue(method, args, callback)
    local call = record(method, args); call.callback = callback
    controller.waiting[#controller.waiting + 1] = call
end
function controller:getAccount() return { id = "optimization_fixture", account_key = self.account_key, session_valid = true } end
function controller:getSetting(key, default) local value = self.settings[key]; if value == nil then return default end; return copy(value) end
function controller:setSetting(key, value) record("setSetting", { key, value }); self.settings[key] = copy(value); return true end
function controller:getComic(id) return self.comics[tostring(id)] end
function controller:getEpisodes(id) return self.episodes[tostring(id)] or {} end
function controller:getEpisode(id)
    for _comic_id, items in pairs(self.episodes) do
        for _episode_index, episode in ipairs(items) do if episode.id == tostring(id) then return episode end end
    end
end
function controller:getDownloads() return self.jobs end
function controller:getStorageSummary() return { automatic_bytes = 0, pinned_bytes = 0 } end
function controller:getPendingPurchases() return self.purchases end
function controller:cancelPendingRead() record("cancelPendingRead") end
function controller:isFavoritePending() return false end
function controller:search(query, callback) enqueue("search", { query }, callback) end
function controller:quotePurchase(id, scope, payment, callback) enqueue("quotePurchase", { id, scope, payment }, callback) end
function controller:reconcilePurchase(id, callback) enqueue("reconcilePurchase", { id }, callback) end
setmetatable(controller, { __index = function(_controller, key)
    if key == "requestCover" then return nil end
    controller.forbidden[#controller.forbidden + 1] = tostring(key)
    error("Controller member is outside the synthetic UI allowlist: " .. tostring(key))
end })
local screens = Screens.new{ controller = controller }
screens:_ensureRouteViews()
local function callCount(method)
    local count = 0
    for _call_index, call in ipairs(controller.calls) do if call.method == method then count = count + 1 end end
    return count
end
local function finish(method, value, err)
    for index, request in ipairs(controller.waiting) do
        if request.method == method then
            table.remove(controller.waiting, index)
            local delivered = copy(value); request.callback(delivered, copy(err)); return delivered, request
        end
    end
    error("No synthetic callback is waiting for " .. method)
end
local function screenButton(message)
    for _row_index, row in ipairs(screens.focus or {}) do
        for _button_index, button in ipairs(row) do
            if type(button.text) == "string" and button.text:gsub(" ▾$", "") == _(message) then return button end
        end
    end
end
local function activate(button)
    assert(button and button.enabled ~= false and type(button.callback) == "function", "The requested visible control is unavailable")
    button.callback()
end
local function press(message) activate(assert(screenButton(message), "Missing screen control: " .. message)) end
local function pressDialog(message)
    assert(screens.dialog and UIManager:getTopmostVisibleWidget() == screens.dialog, "The dialog must be topmost")
    activate(assert(findButton(screens.dialog, _(message)), "Missing native dialog control: " .. message))
end
local function capture(name)
    UIManager:forceRePaint()
    local size = assert(screens.widget).content:getSize()
    check(name .. "_screen_fits", size.w <= report.width and size.h <= report.height, { width = size.w, height = size.h })
    if screens.dialog then
        local box = screens.dialog.movable and screens.dialog.movable:getSize() or screens.dialog:getSize()
        check(name .. "_dialog_fits", box.w <= report.width and box.h <= report.height, { width = box.w, height = box.h })
    end
    Device.screen.bb:writePNG(output_dir .. "/" .. name .. ".png")
    report.screens[#report.screens + 1] = name .. ".png"
end
local function selectedIDs()
    local ids = {}; for id, value in pairs(screens.selected) do if value then ids[#ids + 1] = id end end
    table.sort(ids); return table.concat(ids, ","), #ids
end
local function downloadableIDs(items)
    local ids = {}
    for _index, episode in ipairs(items) do if Model.downloadable(episode) then ids[#ids + 1] = tostring(episode.id) end end
    table.sort(ids); return table.concat(ids, ","), #ids
end
local function hasConfirm()
    local prefix = assert(_("Confirm purchase · %s %s"):match("^(.-)%%"))
    return contains(visibleText(screens.dialog), prefix)
end

local function run()
    local callbacks, holds = 0, 0
    local text = W.text("Short row", W.scale(180), W.font.body)
    local target = W.ActionRow:new{ width = W.scale(180), content = text,
        callback = function() callbacks = callbacks + 1 end, hold_callback = function() holds = holds + 1 end }
    local initial = target:getSize().h
    text:setText("A longer synthetic row label that wraps across multiple lines and keeps the same touch target.")
    target:paintTo(Device.screen.bb, W.scale(8), W.scale(8))
    check("updated_row_text_expands_its_real_touch_bounds", target:getSize().h > initial
        and target.dimen.h == target:getSize().h and target.dimen.w == target.width
        and target.ges_events.TapSelect[1].range == target.dimen)
    target:onTapSelect(); target:onHoldSelect()
    target.enabled = false; target:onTapSelect(); target:onHoldSelect()
    check("row_touch_and_hold_use_distinct_guarded_callbacks", callbacks == 1 and holds == 1)
    local disabled = W.button("Disabled primary", W.scale(220), function() callbacks = callbacks + 1 end,
        { primary = true, enabled = false })
    local enabled = W.button("Enabled primary", W.scale(220), function() end, { primary = true })
    check("disabled_primary_keeps_the_paper_background", disabled.enabled == false and not disabled[1].invert and enabled[1].invert == true)

    screens:showSearch()
    check("initial_search_uses_its_own_empty_state_without_pagination", screens.pagination == nil
        and contains(visibleText(screens.widget), _("Recent searches")))
    press("Search by title or author")
    screens.dialog._input_widget:setText("  Synthetic search  "); pressDialog("Search")
    check("search_waiting_state_is_explicit_and_has_no_pagination", contains(visibleText(screens.widget), _("Searching…"))
        and screens.pagination == nil and controller.waiting[1].args[1] == "Synthetic search")
    local results = {}
    for index = 1, 30 do
        local id = "search-" .. index
        local comic = { id = id, title = "Synthetic result " .. index, authors = { "Fixture author" }, finished = index % 2 == 0,
            latest_episode_title = "A visible update " .. index }
        controller.comics[id], controller.episodes[id] = comic, {}
        screens.loaded["comic:" .. id] = true; results[#results + 1] = comic
    end
    finish("search", results)
    local searches = callCount("search")
    press("All")
    check("search_filter_picker_does_not_cycle_on_open", screens.filter == "all" and callCount("search") == searches)
    pressDialog("Completed")
    check("search_filter_selects_one_explicit_option_without_network", screens.filter == "completed" and callCount("search") == searches)
    check("filtered_search_retains_native_multi_page_navigation", screens.pages > 1 and screens.pagination.next.enabled ~= false)
    screens.pagination.next.callback()
    local origin_page, card = screens.page, assert(screens.search_cards[1])
    UIManager:forceRePaint()
    check("search_result_touch_target_covers_the_full_card", card.dimen.w == screens.width and card.dimen.h == card:getSize().h
        and contains(visibleText(card), card.comic.latest_episode_title))
    local selected_comic = tostring(card.comic.id)
    card:onTapSelect()
    check("search_result_opens_the_selected_catalog_without_researching", screens.route == "comic"
        and screens.comic_id == selected_comic and callCount("search") == searches)
    press("Back")
    check("catalog_back_restores_query_filter_page_and_focused_comic", screens.route == "search"
        and screens.query == "Synthetic search" and screens.filter == "completed" and screens.page == origin_page
        and screens.focused_comic_id == selected_comic and callCount("search") == searches)
    capture("search-return-context")
    press("Clear search")
    check("clear_search_returns_to_history_without_requesting", screens.query == "" and screens.filter == "all"
        and screens.page == 1 and screens.pagination == nil and callCount("search") == searches)
    local history_count = #controller.settings.search_history
    press("Clear history")
    if screens.dialog and screens.dialog.ok_callback then pressDialog(screens.dialog.ok_text) end
    check("search_history_can_be_cleared_and_saved", history_count > 0 and #controller.settings.search_history == 0
        and contains(visibleText(screens.widget), _("Find your next comic")) and callCount("search") == searches)
    capture("search-history-cleared")
    press("Search by title or author"); screens.dialog._input_widget:setText("No matches"); pressDialog("Search")
    finish("search", {})
    check("empty_search_has_recovery_without_bookshelf_copy_or_pagination", screens.pagination == nil
        and contains(visibleText(screens.widget), _("No matching comics"))
        and contains(visibleText(screens.widget), _("Try a shorter title or an author name."))
        and screenButton("Change search") ~= nil)
    capture("empty-search")

    controller.comics.catalog = { id = "catalog", title = "Synthetic catalog", authors = { "Fixture author" }, current_episode_id = "chapter-2" }
    local chapters = {}
    for index = 1, 23 do
        chapters[index] = { id = "chapter-" .. index, comic_id = "catalog", order = index,
            title = "Synthetic chapter " .. index, access = (index == 3 or index == 6) and "temporary" or "owned",
            total_pages = 12, cached_pages = index == 2 and 3 or 0 }
    end
    chapters[3].access, chapters[3].offline_allowed = "temporary", false
    chapters[4].access, chapters[4].offline_allowed = "locked", false
    chapters[5].access, chapters[5].offline_allowed = "owned", false
    chapters[6].access, chapters[6].offline_allowed = "temporary", true
    controller.episodes.catalog = chapters
    screens.loaded["comic:catalog"] = true; screens:showComic("catalog")
    check("catalog_has_a_primary_reading_action_and_jump_control", screenButton("Continue reading") ~= nil
        and screenButton("Jump…") ~= nil and screenButton("Current chapter") == nil)
    press("All"); check("chapter_filter_picker_does_not_cycle", screens.filter == "all"); pressDialog("Cancel")
    press("Select downloads")
    local empty_selection, empty_count = selectedIDs()
    local disabled_submit = assert(screenButton(string.format(_("Download selected (%d)"), 0)))
    disabled_submit.callback()
    check("entering_selection_never_preselects_or_submits", empty_selection == "" and empty_count == 0
        and disabled_submit.enabled == false and not disabled_submit[1].invert and #controller.waiting == 0)
    local page_ids, page_count = downloadableIDs(screens.catalog_visible_items)
    press("Select scope…"); pressDialog("Select downloadable on this page")
    local actual_ids, selected_count = selectedIDs()
    check("select_this_page_uses_only_visible_downloadable_ids", actual_ids == page_ids and selected_count == page_count)
    check("selection_fixture_spans_multiple_pages", screens.pagination and screens.pagination.next.enabled ~= false)
    screens.pagination.next.callback()
    local visible_selected = 0
    for _index, episode in ipairs(screens.catalog_visible_items) do if screens.selected[episode.id] then visible_selected = visible_selected + 1 end end
    check("cross_page_selection_is_counted_and_explained", selectedIDs() == actual_ids
        and contains(visibleText(screens.widget), string.format(_("Selected: %d · Outside this page: %d"), selected_count, selected_count - visible_selected)))
    press("Select scope…"); pressDialog("Select all downloadable matches")
    local all_ids, all_count = downloadableIDs(chapters)
    local selected_all, selected_total = selectedIDs()
    check("select_all_matches_preserves_offline_rights_as_a_separate_axis", selected_all == all_ids and selected_total == all_count
        and not screens.selected["chapter-3"] and not screens.selected["chapter-4"] and not screens.selected["chapter-5"]
        and screens.selected["chapter-6"] == true)
    capture("cross-page-download-selection")
    press("Clear")
    check("clear_selection_removes_visible_and_other_page_ids", selectedIDs() == ""
        and screenButton(string.format(_("Download selected (%d)"), 0)).enabled == false)
    press("Done")
    controller.episodes.catalog = { chapters[1] }; screens.page = 1; screens:refresh()
    check("one_chapter_omits_pagination", screens.pages == 1 and screens.pagination == nil)
    controller.episodes.catalog = {}; screens:refresh()
    check("empty_catalog_omits_pagination_and_disables_reading", screens.pagination == nil
        and screenButton("Continue reading").enabled == false and not screenButton("Continue reading")[1].invert)
    screens:showDownloads()
    check("empty_downloads_explain_the_download_entry_point", screens.pagination == nil
        and contains(visibleText(screens.widget), _("No downloads yet"))
        and contains(visibleText(screens.widget), _("Open a comic's chapter catalog and choose chapters to download for offline reading."))
        and screenButton("Choose a comic") ~= nil)
    capture("empty-downloads")

    controller.comics.quote = { id = "quote", title = "Synthetic quote context" }
    controller.episodes.quote = { { id = "locked-quote", comic_id = "quote", title = "Synthetic locked chapter", access = "locked", order = 1 } }
    screens.loaded["comic:quote"] = true; screens:showComic("quote"); press("Synthetic locked chapter")
    local request = assert(controller.waiting[1])
    local quote = { id = "fixture-quote", comic_id = "quote", episode_id = "locked-quote", episode_ids = { "locked-quote" },
        scope = copy(request.args[2]), payment = copy(request.args[3]), method = "coin", amount = 12, balance = 40,
        can_afford = true, submittable = true, fingerprint = "synthetic-ui-only", expected_access = { ["locked-quote"] = { access = "owned" } } }
    finish("quotePurchase", quote, { kind = "network", message = "SDK_SECRET" })
    check("quote_value_with_error_cannot_expose_a_submit_action", screens.purchase_state.quote ~= nil and screens.purchase_state.error.kind == "network"
        and not hasConfirm() and contains(visibleText(screens.dialog), _("The quote could not be loaded. Check the connection, then refresh the quote."))
        and not contains(visibleText(screens.dialog), "SDK_SECRET"))
    pressDialog("Refresh quote")
    finish("quotePurchase", nil, { kind = "quote_expired", message = "SDK_SECRET" })
    local heading, message = Model.error({ kind = "quote_expired" })
    check("expired_quote_has_typed_recovery_and_never_reuses_confirmation", heading == _("Purchase quote expired")
        and contains(visibleText(screens.dialog), heading) and contains(visibleText(screens.dialog), message)
        and findButton(screens.dialog, _("Refresh quote")) ~= nil and not hasConfirm())
    capture("expired-quote")
    screens:_closeDialog()
    local intent = { id = "pending-fixture", comic_id = "quote", episode_ids = { "locked-quote" }, quote = copy(quote),
        state = "outcome_unknown", purpose = "read", transaction_evidence = "none" }
    controller.purchases = { intent }; press("Synthetic locked chapter"); pressDialog("Refresh result")
    local returned = finish("reconcilePurchase", intent, { kind = "network", message = "SDK_SECRET" })
    check("pending_result_and_error_are_both_retained", screens.purchase_state.intent == returned
        and screens.purchase_state.result_error.kind == "network" and not hasConfirm()
        and contains(visibleText(screens.dialog), _("The purchase is still unresolved. Check the connection, then check its result again."))
        and not contains(visibleText(screens.dialog), "SDK_SECRET"))
    capture("pending-result-network-recovery")
    check("no_real_or_fake_purchase_or_download_was_submitted", callCount("purchase") == 0 and callCount("downloadEpisodes") == 0
        and #controller.forbidden == 0 and #controller.waiting == 0, controller.forbidden)
    for _module_index, module in ipairs(prohibited_modules) do
        check("business_module_stays_unloaded_" .. _module_index, package.loaded[module] == nil)
    end
end

local ok, failure = pcall(run)
report.passed, report.error, report.count = ok, not ok and tostring(failure) or nil, #report.assertions
report.calls = {}
for _call_index, call in ipairs(controller.calls) do report.calls[call.method] = (report.calls[call.method] or 0) + 1 end
pcall(screens.close, screens)
local file = assert(io.open(output_dir .. "/optimization-result.json", "wb"))
assert(file:write(json.encode(report, { pretty = true }))); assert(file:close())
print(json.encode(report, { pretty = true }))
if not ok then error(failure) end
