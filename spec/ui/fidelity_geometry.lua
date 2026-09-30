-- Compare native painted geometry with explicit handoff coordinates.
local Device = require("device")
local T = require("bilicomics/ui/i18n")
local Audit = {}
local function visit(widget, predicate, seen)
    if type(widget) ~= "table" then return nil end
    seen = seen or {}
    if seen[widget] then return nil end
    seen[widget] = true
    if predicate(widget) then return widget end
    for _, child in ipairs(widget) do local found = visit(child, predicate, seen); if found then return found end end
    for _, field in ipairs({ "content", "layout", "header", "body", "footer" }) do
        local found = visit(widget[field], predicate, seen); if found then return found end
    end
end
local function rect(widget)
    local size = widget:getSize()
    local dimen = widget.dimen or widget.frame and widget.frame.dimen or {}
    return { x = dimen.x or 0, y = dimen.y or 0, w = size.w, h = size.h }
end
function Audit.check(screens, name, W, check, report)
    if Device.screen:getWidth() ~= 1860 or Device.screen:getHeight() ~= 2480 then return end
    report.fidelity_measurements = report.fidelity_measurements or {}
    local function measure(key, actual, expected, tolerance)
        report.fidelity_measurements[#report.fidelity_measurements + 1] = {
            screen = name, metric = key, actual_px = actual, design_px = expected, tolerance_px = tolerance or 1 }
        check("fidelity_" .. name .. "_" .. key, math.abs(actual - expected) <= (tolerance or 1),
            { actual_px = actual, design_px = expected })
    end
    if name == "bookshelf-resume" then
        local cover = rect(assert(screens.resume_card))
        measure("resume_cover_left", cover.x, W.dp(56))
        measure("resume_cover_top", cover.y, W.dp(150))
        measure("resume_cover_width", cover.w, W.dp(216))
        measure("resume_cover_height", cover.h, W.dp(288))
        local first = rect(assert(screens.cards[1]))
        measure("first_grid_top", first.y, W.dp(555))
        local resume = visit(screens.widget, function(item) return item.callback and item.text == T("Continue reading") end)
        local button = rect(assert(resume))
        measure("resume_action_height", button.h, W.dp(66))
        measure("resume_action_bottom", button.y + button.h, cover.y + cover.h)
    elseif name == "bookstore-default" then
        local first = assert(screens.cards[1])
        measure("cover_top", first.dimen.y, W.dp(204))
        measure("cover_height", first.cover_height, W.dp(240))
        local last = rect(assert(screens.cards[#screens.cards]))
        check("fidelity_bookstore_metadata_stays_above_navigation", last.y + last.h <= W.dp(1152), last)
    elseif name == "search-results" then
        measure("result_row_height", assert(screens.search_cards[1]):getSize().h, W.dp(130))
    elseif name == "purchase-confirmation" then
        local surface = screens.dialog
        local cover = visit(surface.body, function(item) return item.outer_width == W.dp(84) and item.outer_height == W.dp(112) end)
        measure("summary_cover_top", rect(assert(cover)).y, W.dp(144))
        measure("cancel_width", surface.footer_buttons[1]:getSize().w, W.dp(200))
        measure("action_height", surface.footer_buttons[2]:getSize().h, W.dp(68))
    elseif name == "account-signed-in" then
        check("fidelity_account_groups_fit_one_scribe_page", screens.pages == 1, { pages = screens.pages })
    elseif name == "qr-waiting" then
        local qr = visit(screens.dialog.body, function(item) return item.image and item.text and item.text:find("bilibili", 1, true) end)
        check("fidelity_qr_uses_native_image", qr ~= nil)
    end
end
return Audit
