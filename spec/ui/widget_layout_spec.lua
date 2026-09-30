-- Render only synthetic data in an isolated, authorized native KOReader runtime.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
require("gettext").current_lang = "zh_CN"
local W = require("bilicomics/ui/widgets")
local BB = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local json = require("rapidjson")
local report = { scope = "Synthetic shared-widget and reader-overlay layout", assertions = {}, screenshots = {} }
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
end
local sw, sh = Device.screen:getWidth(), Device.screen:getHeight()
local bb = Device.screen.bb
local function capture(widget, filename)
    bb:fill(BB.COLOR_WHITE)
    widget:paintTo(bb, 0, 0)
    bb:writePNG(output .. "/" .. filename)
    report.screenshots[#report.screenshots + 1] = filename
end
local function bodyFits(dialog)
    return dialog.body[1][1]:getSize().h <= dialog.body_height
end
local header = W.header("Shared header", sw, { offline = true,
    back_callback = function() end, more_callback = function() end })
check("header_reference_dimensions", header:getSize().w == sw and header:getSize().h == W.dp(116), header:getSize())
local nav, nav_buttons = W.navigation({
    { text = "Shelf", selected = true, callback = function() end },
    { text = "Store", callback = function() end },
    { text = "Search", callback = function() end },
    { text = "Downloads", badge = 12, callback = function() end },
}, sw)
check("navigation_reference_dimensions", nav:getSize().w == sw and nav:getSize().h == W.dp(88), nav:getSize())
local marker = W.box(nil, sw - W.dp(112), W.dp(72), { background = BB.Color8(0xAA) })
local sheet = W.sheetDialog(W.inset(W.column{ W.text("Sheet", sw - W.dp(112), W.fontSize(26)), marker },
    W.dp(56), W.dp(56), W.dp(30), W.dp(36)), {}, {})
capture(sheet, "bottom-sheet.png")
check("bottom_sheet_fits_screen", sheet.panel_dimen.x == 0 and sheet.panel_dimen.w == sw
    and sheet.panel_dimen.y + sheet.panel_dimen.h == sh, sheet.panel_dimen)
local shell = W.Panel:new{ content = W.column{ header,
    W.box(nil, sw, sh - W.dp(116) - W.dp(88)), nav }, layout = { nav_buttons }, close_callback = function() end }
capture(shell, "shared-shell.png")

local primary = W.button("Primary", W.dp(300), function() end, { primary = true, height_px = W.dp(68) })
primary:paintTo(bb, W.dp(56), W.dp(120))
primary:_doFeedbackHighlight()
primary:_undoFeedbackHighlight(false)
check("primary_keeps_fill_after_native_tap_feedback", primary.frame.invert == true)
primary:onFocus(); primary:onUnfocus()
check("primary_keeps_fill_after_focus_moves", primary.frame.invert == true)
local label_css = W.text("Line height", W.dp(300), W.fontSize(20), { line_height = 1.7 })
local label_legacy = W.text("Line height", W.dp(300), W.fontSize(20), { line_height = 0.7 })
check("css_and_legacy_line_height_share_the_intended_baseline", label_css.line_height_px == label_legacy.line_height_px
    and math.abs(label_css.line_height_px / label_css.face.size - 1.7) <= 1 / label_css.face.size,
    { css_px = label_css.line_height_px, legacy_px = label_legacy.line_height_px, em_px = label_css.face.size })
local focus_stroke = math.max(1, W.dp(2))
local focused_row = W.ActionRow:new{ width = W.dp(300),
    content = W.box(nil, W.dp(300), W.dp(72), { background = W.paper }), callback = function() end }
bb:fill(W.paper); focused_row:onFocus(); focused_row:paintTo(bb, 20, 20)
check("row_focus_is_a_two_dp_inner_outline", bb:getPixel(20 + focus_stroke - 1, 30):getR() == 0x11
    and bb:getPixel(20 + focus_stroke, 30):getR() == 0xFF)
local focused_card = W.CoverCard:new{ comic = { title = "Synthetic comic" }, text = "Synthetic comic",
    width = W.dp(146), cover_height = W.dp(195), redesign = true, bookshelf = true, progress = "No position" }
bb:fill(W.paper); focused_card:onFocus(); focused_card:paintTo(bb, 20, 20)
check("cover_focus_is_a_two_dp_inner_outline", bb:getPixel(20 + focus_stroke - 1, 50):getR() == 0x11
    and bb:getPixel(20 + focus_stroke, 50):getR() == 0xFF)

local owner, close_calls, rows = {}, 0, {}
for index = 1, 24 do
    rows[#rows + 1] = { widget = W.box(W.text("Row " .. index, sw - W.dp(112), W.fontSize(20)),
        sw - W.dp(112), W.dp(80)) }
end
owner.dialog = W.flowDialog("Flow", {}, { { { text = "Close", callback = function()
    close_calls = close_calls + 1; UIManager:close(owner.dialog)
end } } }, { body_rows = rows, close_callback = function()
    close_calls = close_calls + 1; UIManager:close(owner.dialog)
end })
local original = owner.dialog
UIManager:show(original)
original:onNextPage()
local visible = UIManager:getTopmostVisibleWidget()
check("flow_pagination_preserves_owner_identity", visible == owner.dialog and original.page == 2)
check("flow_page_keeps_content_above_footer", bodyFits(original))
visible:onClose()
check("flow_close_removes_visible_page", UIManager:getTopmostVisibleWidget() ~= visible and close_calls == 1)
if UIManager:getTopmostVisibleWidget() then UIManager:close(UIManager:getTopmostVisibleWidget()) end

local replace_owner, replacement_previous = {}, {}
local replace_options = { body_rows = rows }
replace_options.on_replace = function(replacement, previous)
    replacement_previous[#replacement_previous + 1] = previous == replace_owner.dialog
    UIManager:close(previous); replace_owner.dialog = replacement; UIManager:show(replacement)
end
replace_owner.dialog = W.flowDialog("Replacement flow", {}, { { { text = "Close", callback = function() end } } }, replace_options)
UIManager:show(replace_owner.dialog)
replace_owner.dialog:onNextPage(); replace_owner.dialog:onNextPage()
check("flow_on_replace_receives_current_previous", replacement_previous[1] and replacement_previous[2])
UIManager:close(replace_owner.dialog)
check("flow_replacement_does_not_leave_an_old_page", UIManager:getTopmostVisibleWidget() == nil)
if UIManager:getTopmostVisibleWidget() then UIManager:close(UIManager:getTopmostVisibleWidget()) end
local mutable_rows = { { widget = W.box(nil, sw - W.dp(112), W.dp(80)) } }
W.flowDialog("Input ownership", {}, { { { text = "Inline", callback = function() end } },
    { { text = "Close", callback = function() end } } }, { body_rows = mutable_rows })
check("flow_does_not_mutate_caller_body_rows", #mutable_rows == 1)

local actions = {}
for index = 1, 24 do actions[#actions + 1] = { { text = "Action " .. index, callback = function() end } } end
local menu = W.menuDialog("Menu", {}, actions, { placement = "center", width = W.dp(700) })
UIManager:show(menu); menu:onNextPage()
check("menu_pagination_preserves_identity", UIManager:getTopmostVisibleWidget() == menu and menu.page == 2)
capture(menu, "menu-page-2.png")
check("menu_page_fits_screen", menu.panel_dimen.y >= 0 and menu.panel_dimen.y + menu.panel_dimen.h <= sh)
UIManager:close(menu)

local long_column = {}
for index = 1, 32 do
    long_column[#long_column + 1] = W.text("Synthetic item " .. index, sw - W.dp(112), W.fontSize(22))
    long_column[#long_column + 1] = W.spacePixels(W.dp(20))
end
local tall = W.flowDialog("Long column", {}, { { { text = "Close", callback = function() end } } },
    { body = W.column(long_column) })
local column_fits, column_heights = bodyFits(tall), { tall.body[1][1]:getSize().h }
for page = 2, tall.pages do
    tall:onNextPage(); column_fits = column_fits and bodyFits(tall)
    column_heights[#column_heights + 1] = tall.body[1][1]:getSize().h
end
check("flow_splits_a_long_column_without_covering_footer", tall.pages > 1 and column_fits,
    { pages = tall.pages, body_height = tall.body_height, page_heights = column_heights })
local prose = W.text(string.rep("Synthetic paragraph with a retained sentence. ", 600), sw - W.dp(112),
    W.fontSize(20), { line_height = 1.7, align = "center" })
local prose_flow = W.flowDialog("Long prose", {}, { { { text = "Close", callback = function() end } } },
    { body_rows = { { widget = prose } } })
local prose_fits, prose_grid, prose_heights = bodyFits(prose_flow), true, { prose_flow.body[1][1]:getSize().h }
local function textGridMatches(widget)
    if widget.line_height_px and widget.face and type(widget.text) == "string" then
        if widget.line_height_px ~= prose.line_height_px or widget.alignment ~= prose.alignment then return false end
    end
    for _, child in ipairs(widget) do if type(child) == "table" and not textGridMatches(child) then return false end end
    return true
end
prose_grid = textGridMatches(prose_flow.body)
for page = 2, prose_flow.pages do
    prose_flow:onNextPage(); prose_fits = prose_fits and bodyFits(prose_flow)
    prose_grid = prose_grid and textGridMatches(prose_flow.body)
    prose_heights[#prose_heights + 1] = prose_flow.body[1][1]:getSize().h
end
check("flow_splits_long_text_without_covering_footer", prose_flow.pages > 1 and prose_fits,
    { pages = prose_flow.pages, body_height = prose_flow.body_height, page_heights = prose_heights })
check("split_prose_preserves_line_height_and_alignment", prose_grid)
local fixed_ok, fixed_error = pcall(W.flowDialog, "Oversized fixed graphic", {},
    { { { text = "Close", callback = function() end } } },
    { body_rows = { { widget = W.box(nil, sw - W.dp(112), sh, { background = BB.Color8(0xAA) }) } } })
check("oversized_fixed_graphic_is_rejected_before_paint", not fixed_ok
    and tostring(fixed_error):find("exceeds the available page height", 1, true) ~= nil)
local focus_column, focus_layout = {}, {}
for index = 1, 26 do
    local button = W.button("Focus row " .. index, sw - W.dp(112), function() end, { height_px = W.dp(68) })
    focus_column[#focus_column + 1], focus_layout[#focus_layout + 1] = button, { button }
    focus_column[#focus_column + 1] = W.spacePixels(W.dp(20))
end
local focus_flow = W.flowDialog("Paged focus", {}, { { { text = "Close", callback = function() end } } },
    { body = W.column(focus_column), layout = focus_layout })
local function contains(widget, wanted)
    if widget == wanted then return true end
    for _, child in ipairs(widget) do if type(child) == "table" and contains(child, wanted) then return true end end
    return false
end
local focus_visible = true
for page = 1, focus_flow.pages do
    if page > 1 then focus_flow:onNextPage() end
    for _, row in ipairs(focus_flow.layout) do
        for _, button in ipairs(row) do
            if type(button.text) == "string" and button.text:match("^Focus row ") then
                focus_visible = focus_visible and contains(focus_flow.body, button)
            end
        end
    end
end
check("paged_focus_only_targets_visible_body_controls", focus_flow.pages > 1 and focus_visible)
check("paged_flow_initial_focus_keeps_the_close_action", focus_flow:getFocusItem().text == "Close")

local Controller = require("bilicomics/controller")
local current_episode = { id = "12", title = "Synthetic current chapter", access = "owned" }
local next_episode = { id = "13", title = "Synthetic next chapter", access = "owned", pay_gold = 30 }
local account = { catalog = { getEpisodes = function() return { current_episode, next_episode } end,
    getComic = function() return { id = "comic", title = "Synthetic series" } end },
    store = { listJobs = function() return {} end } }
local descriptor = { comic_id = "comic", episode_id = "12", revision = "synthetic", pages = {} }
for index = 1, 24 do descriptor.pages[index] = { id = "image-" .. index } end
local transitions, read_calls, quote_calls = 0, 0, 0
local document = { descriptor = descriptor, getDocumentProps = function()
    return { series = "Synthetic series", title = current_episode.title }
end, getLocalPage = function(_, index) return { state = index <= 14 and "ready" or "missing", path = index <= 14 and "synthetic" or nil } end }
local integration = { generation = 7, document = document, isCurrent = function() return true end,
    finishTransition = function() transitions = transitions + 1 end,
    reader = { paging = { getTopPage = function() return 8 end }, menu = { onShowMenu = function() end } } }
integration.reader.document, integration.reader.bilicomics_integration = document, integration
local controller = setmetatable({ account = account, active_integration = integration, ui_manager = UIManager,
    preloaded = { ["7:13"] = true }, reader_dialogs = {}, errors_shown = {}, network = { isConnected = function() return true end },
    screens = { showComic = function() end, _purchaseFor = function() quote_calls = quote_calls + 1 end },
    readEpisode = function() read_calls = read_calls + 1 end }, { __index = Controller })
local event = { descriptor = descriptor, reader = integration.reader, reader_generation = 7 }
controller:_chapterBoundary(event)
capture(controller.chapter_dialog, "reader-next-readable.png")
check("reader_boundary_sheet_fits_screen", controller.chapter_dialog:getSize().w <= sw
    and controller.chapter_dialog:getSize().h <= sh)
controller.chapter_dialog.layout[1][1].callback()
check("readable_next_action_reads_and_releases_transition", read_calls == 1 and transitions == 1 and controller.chapter_dialog == nil)
next_episode.access = "locked"
controller:_chapterBoundary(event)
capture(controller.chapter_dialog, "reader-next-locked.png")
check("locked_next_does_not_automatically_purchase", quote_calls == 0 and read_calls == 1)
controller.chapter_dialog.layout[1][1].callback()
check("locked_next_action_only_opens_a_quote", quote_calls == 1 and transitions == 2)
controller:showReaderMenu()
local reader_menu = UIManager:getTopmostVisibleWidget()
capture(reader_menu, "reader-actions.png")
check("reader_action_sheet_fits_screen", reader_menu:getSize().w <= sw and reader_menu:getSize().h <= sh)
local catalog_callback = reader_menu.layout[1][1].callback
controller.account = {}
catalog_callback()
check("reader_menu_callback_rejects_a_stale_account", UIManager:getTopmostVisibleWidget() == reader_menu)
controller.account = account; reader_menu:onClose()
controller:_pageError(descriptor, 9, {}, { kind = "network" })
local reader_error = UIManager:getTopmostVisibleWidget()
capture(reader_error, "reader-image-error.png")
check("reader_error_is_a_bounded_framed_dialog", reader_error.panel_dimen.w == W.dp(700)
    and reader_error.panel_dimen.x == W.dp(115) and reader_error.panel_dimen.y >= 0
    and reader_error.panel_dimen.y + reader_error.panel_dimen.h <= sh)
reader_error:onClose()

local file = assert(io.open(output .. "/widget-layout-results.json", "w"))
file:write(json.encode(report)); file:close()
print(json.encode(report))
