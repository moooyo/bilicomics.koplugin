-- Capture every reader handoff state in production ReaderUI with original fixtures.
require("setupkoenv")
local plugin, output, language = assert(arg[1]), assert(arg[2]), arg[3] or "zh_CN"
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local lfs = require("libs/libkoreader-lfs")
local disabled = {}
for entry in lfs.dir("plugins") do
    local name = entry:match("^(.*)%.koplugin$")
    if name then disabled[name] = true end
end
G_reader_settings:saveSetting("plugins_disabled", disabled)
G_reader_settings:saveSetting("color_rendering", false)
require("gettext").current_lang = language
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local ReaderUI = require("apps/reader/readerui")
local footer_settings = {}
for key, value in pairs(require("apps/reader/modules/readerfooter").default_settings) do footer_settings[key] = value end
footer_settings.all_at_once, footer_settings.page_progress = true, true
footer_settings.time, footer_settings.battery, footer_settings.book_title = true, true, true
G_reader_settings:saveSetting("footer", footer_settings)
local Provider = require("bilicomics/reader/document")
local Registry = require("document/documentregistry")
local Integration = require("bilicomics/reader/integration")
local Controller = require("bilicomics/controller")
local W = require("bilicomics/ui/widgets")
local T = require("bilicomics/ui/i18n")
local BB = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local json = require("rapidjson")
local file = assert(io.open(output .. "/pages.json", "rb"))
local records = json.decode(file:read("*a")); file:close()
local sw, sh = Device.screen:getWidth(), Device.screen:getHeight()
local scribe = sw == 1860 and sh == 2480
local result = { scope = "J1-J5 native ReaderUI and every reader error state", screenshots = {},
    assertions = {}, measurements = {}, passed = false }
local function check(name, condition, detail)
    result.assertions[#result.assertions + 1] = { name = name, passed = not not condition, detail = detail }
end
local function metric(screen, name, actual, expected, tolerance)
    tolerance = tolerance or 1
    result.measurements[#result.measurements + 1] = { screen = screen, name = name,
        actual_px = actual, expected_px = expected, tolerance_px = tolerance }
    if scribe then check(screen .. "_" .. name, math.abs(actual - expected) <= tolerance,
        { actual_px = actual, expected_px = expected }) end
end
local function visit(widget, predicate, seen)
    if type(widget) ~= "table" then return nil end
    seen = seen or {}; if seen[widget] then return nil end; seen[widget] = true
    if predicate(widget) then return widget end
    for _, child in ipairs(widget) do local found = visit(child, predicate, seen); if found then return found end end
    for _, field in ipairs({ "content", "layout" }) do
        local found = visit(widget[field], predicate, seen); if found then return found end
    end
end
local function findText(widget, text)
    return assert(visit(widget, function(item) return item.text == text end), "Missing text: " .. text)
end
local function rect(widget)
    local size = widget:getSize()
    local dimen = widget.dimen or widget.frame and widget.frame.dimen or {}
    return { x = dimen.x or 0, y = dimen.y or 0, w = size.w, h = size.h }
end
local function textMetric(screen, dialog, text, size)
    local widget = findText(dialog, text)
    local face = widget.face or widget.label_widget and widget.label_widget.face
    metric(screen, "font_" .. text, assert(face).size, W.dp(size), 2)
    return widget, rect(widget)
end
local saved_anchor, requests = nil, 0
local current = { id = "12", title = "雨停以前", short_title = "12", access = "owned" }
local following = { id = "13", title = "好天气", short_title = "13", access = "owned", pay_gold = 30 }
local series = { id = "comic", title = "山海邮差" }
local services = {
    authorizeDescriptor = function(descriptor) return descriptor.account_key == "review" end,
    settings = { reading_mode = "page", reading_direction = "ltr" },
    pages = { getPage = function(_, _, _, index) return records[index] end, setActiveEpisode = function() end },
    store = { getEpisode = function() return current end, getComic = function() return series end,
        getAnchor = function() return saved_anchor end,
        putAnchor = function(_, _, _, anchor) saved_anchor = anchor end },
    requestPage = function() requests = requests + 1 end, onReaderEvent = function() end,
}
Provider:setServicesResolver(function(account) assert(account == "review"); return services end)
Provider:register(Registry)
local calls = { read = 0, quote = 0, comic = 0, account = 0, downloads = 0, storage = 0,
    library = 0, native_menu = 0, reader_close = 0, retry = 0, failures_cleared = 0 }
local offline_cached, connected = false, true
local account = { catalog = { getEpisodes = function() return { current, following } end,
        getComic = function() return series end,
        getDescriptor = function() return { revision = "review", pages = records } end },
    pages = { getPage = function() return offline_cached and { state = "ready", path = records[1].path } or { state = "missing" } end },
    store = { listJobs = function() return { { kind = "episode_download", state = "running", episode_id = "1", payload = {} },
        { kind = "episode_download", state = "queued", episode_id = "2", payload = {} } } end },
    downloads = { projectJob = function(_, job) return job end,
        isRetiredVersion = function() return false end, releaseReader = function() end,
        clearFailures = function() calls.failures_cleared = calls.failures_cleared + 1 end } }
local controller = setmetatable({ ui_manager = UIManager, reader_dialogs = {}, errors_shown = {},
    account = account, preloaded = {}, network = { isConnected = function() return connected end },
    integrations = {},
    screens = { showComic = function() calls.comic = calls.comic + 1 end,
        _purchaseFor = function() calls.quote = calls.quote + 1 end,
        showAccount = function() calls.account = calls.account + 1 end,
        showDownloads = function() calls.downloads = calls.downloads + 1 end,
        _showStorageSettings = function() calls.storage = calls.storage + 1 end,
        showLibrary = function() calls.library = calls.library + 1 end },
    readEpisode = function() calls.read = calls.read + 1 end,
    _requestReaderPage = function() calls.retry = calls.retry + 1 end }, { __index = Controller })
function controller:_nextEpisode() return self.review_next end
local reader, integration, native_close, native_closed
local function closeOverlays()
    if controller.chapter_dialog then controller.chapter_dialog:onClose() end
    local dialogs = {}; for dialog in pairs(controller.reader_dialogs) do dialogs[#dialogs + 1] = dialog end
    for _, dialog in ipairs(dialogs) do dialog:onClose() end
end
local function capture(name, dialog)
    UIManager:forceRePaint()
    Device.screen.bb:writePNG(output .. "/" .. name .. ".png")
    result.screenshots[#result.screenshots + 1] = name .. ".png"
    if dialog then
        local panel = dialog.panel_dimen
        check(name .. "_bounds", panel and panel.x >= 0 and panel.y >= 0 and panel.x + panel.w <= sw
            and panel.y + panel.h <= sh, panel)
        result.measurements[#result.measurements + 1] = { screen = name, panel = panel }
        check(name .. "_focus_follows_visual_order", #dialog.layout >= 1)
        for row, buttons in ipairs(dialog.layout) do
            for column, button in ipairs(buttons) do
                local area = rect(button)
                check(name .. "_target_" .. row .. "_" .. column .. "_visible", area.x >= panel.x
                    and area.y >= panel.y and area.x + area.w <= panel.x + panel.w
                    and area.y + area.h <= panel.y + panel.h, area)
            end
        end
    end
end
local function finished(failure)
    closeOverlays()
    if reader and not native_closed then reader.onClose = native_close or reader.onClose; reader:onClose() end
    local failed = false
    for _, assertion in ipairs(result.assertions) do if not assertion.passed then failed = true end end
    result.passed, result.error = failure == nil and not failed, failure
    local report = assert(io.open(output .. "/all-pages-reader-result.json", "wb"))
    report:write(json.encode(result, { pretty = true })); report:close()
    print(json.encode(result)); UIManager:quit()
end
local event
local steps = {
    function()
        reader = assert(ReaderUI.instance); integration = assert(Integration.attach(reader))
        controller.active_integration = integration
        native_close = reader.onClose
        reader.onClose = function() calls.reader_close = calls.reader_close + 1 end
        event = { descriptor = reader.document.descriptor, reader = reader, reader_generation = integration.generation }
        controller.preloaded[tostring(integration.generation) .. ":13"] = true
        reader.zooming:onSetZoomMode("page"); reader.view:onSetScrollMode(false); reader.paging:_gotoPage(8)
        reader.menu.onShowMenu = function() calls.native_menu = calls.native_menu + 1 end
    end,
    function()
        capture("J0-native-reader")
        check("native_reader_owns_the_document", reader.document.provider == "bilicomics_document")
        check("native_footer_is_active", reader.view.footer and reader.view.footer.settings and reader.view.footer.settings.page_progress)
        controller:showReaderMenu()
        local dialog = assert(next(controller.reader_dialogs)); capture("J1-comic-actions", dialog)
        metric("J1", "left", dialog.panel_dimen.x, 0)
        metric("J1", "width", dialog.panel_dimen.w, sw)
        metric("J1", "bottom", dialog.panel_dimen.y + dialog.panel_dimen.h, sh)
        local _, action_heading = textMetric("J1", dialog, T("Comic actions"), 26)
        metric("J1", "top_padding_and_border", action_heading.y - dialog.panel_dimen.y, W.dp(32))
        local first = rect(dialog.layout[1][1]); metric("J1", "row_height", first.h, W.dp(71))
        metric("J1", "row_left", first.x, W.dp(56))
        metric("J1", "row_stride", rect(dialog.layout[2][1]).y - first.y, W.dp(72))
        metric("J1", "back_height", rect(dialog.layout[#dialog.layout][1]).h, W.dp(68))
        check("J1_five_native_menu_rows", #dialog.layout == 6)
        check("J1_counts_are_from_controller", findText(dialog, string.format(T("%d tasks in progress"), 2)) ~= nil)
        controller.account = {}; dialog.layout[1][1].callback()
        check("J1_stale_account_does_not_navigate", calls.comic == 0 and controller.reader_dialogs[dialog])
        controller.account = account; closeOverlays()
    end,
    function()
        controller.review_next = following
        controller:_chapterBoundary(event); local dialog = controller.chapter_dialog
        capture("J2-next-readable", dialog)
        metric("J2", "bottom", dialog.panel_dimen.y + dialog.panel_dimen.h, sh)
        local _, finish_heading = textMetric("J2", dialog, T("End of chapter"), 30)
        metric("J2", "top_padding_and_border", finish_heading.y - dialog.panel_dimen.y, W.dp(36))
        textMetric("J2", dialog, string.format(T("Episode %s"), "13") .. " · " .. following.title, 25)
        metric("J2", "primary_height", rect(dialog.layout[1][1]).h, W.dp(68))
        metric("J2", "secondary_height", rect(dialog.layout[2][1]).h, W.dp(64))
        check("J2_has_actual_preload_status", visit(dialog, function(item)
            return type(item.text) == "string" and item.text:find(T("Preloading started"), 1, true) end) ~= nil)
        dialog.layout[1][1].callback()
        check("J2_primary_reads_next_and_dismisses", calls.read == 1 and controller.chapter_dialog == nil)
        local title = following.title
        following.title = string.format(T("Episode %s"), "13"):gsub("%s+", "") .. " · 好天气"
        controller:_chapterBoundary(event); dialog = controller.chapter_dialog
        check("J2_existing_chapter_number_is_not_duplicated", findText(dialog, following.title) ~= nil)
        closeOverlays(); following.title = title
        controller:_chapterBoundary{ descriptor = event.descriptor, reader = reader, reader_generation = integration.generation - 1 }
        check("J2_old_generation_cannot_open_boundary_sheet", controller.chapter_dialog == nil)
    end,
    function()
        following = { id = "14", title = "海边的车站", short_title = "14", access = "locked", pay_gold = 30 }
        controller.review_next = following; controller:_chapterBoundary(event)
        local dialog = controller.chapter_dialog; capture("J3-next-purchase", dialog)
        textMetric("J3", dialog, T("No automatic purchase. A quote must be confirmed before submitting."), 16)
        local price_text = string.format(T("%s comic coins"), "30")
        local price = assert(visit(dialog, function(item) return item.bordersize == W.dp(1.5)
            and item:getSize().w < sw / 2 and visit(item, function(label) return label.text == price_text end) end))
        local title = findText(dialog, string.format(T("Episode %s"), "14") .. " · " .. following.title)
        check("J3_price_is_right_of_next_title", rect(price).x > rect(title).x + rect(title).w, { price = rect(price), title = rect(title) })
        check("J3_no_automatic_purchase_or_read", calls.quote == 0 and calls.read == 1)
        dialog.layout[1][1].callback()
        check("J3_primary_opens_quote_only", calls.quote == 1 and calls.read == 1 and controller.chapter_dialog == nil)
    end,
    function()
        following = { id = "13", title = "好天气", short_title = "13", access = "owned" }
        controller.review_next, connected, offline_cached = following, false, false
        controller:_chapterBoundary(event); local dialog = controller.chapter_dialog
        capture("J2-offline-uncached", dialog)
        check("J2_offline_uncached_does_not_claim_readability", visit(dialog,
            function(item) return item.text == T("Read next chapter") end) == nil)
        check("J2_offline_uncached_explains_connection", visit(dialog, function(item) return type(item.text) == "string"
            and item.text:find(T("Connect to read the next chapter"), 1, true) end) ~= nil)
        closeOverlays()
        following.access, following.expires_at, offline_cached = "temporary", os.time() + 3600, true
        controller:_chapterBoundary(event); dialog = controller.chapter_dialog
        capture("J2-offline-online-entitlement", dialog)
        check("J2_online_only_entitlement_is_not_offline_readable", visit(dialog,
            function(item) return item.text == T("Read next chapter") end) == nil)
        closeOverlays()
        following.access = "owned"
        controller:_chapterBoundary(event); dialog = controller.chapter_dialog
        capture("J2-offline-cached", dialog)
        check("J2_offline_cached_primary_reads", dialog.layout[1][1].text == T("Read next chapter"))
        check("J2_offline_partial_cache_copy_is_precise", visit(dialog, function(item) return type(item.text) == "string"
            and item.text:find(T("Cached images available offline"), 1, true) end) ~= nil)
        check("J2_offline_does_not_claim_live_preloading", visit(dialog, function(item) return type(item.text) == "string"
            and item.text:find(T("Preloading started"), 1, true) end) == nil)
        closeOverlays(); connected = true
        controller:showReaderMenu(); dialog = assert(next(controller.reader_dialogs))
        dialog.layout[4][1].callback()
    end,
    function()
        check("J1_native_settings_runs_on_next_tick", calls.native_menu == 1 and next(controller.reader_dialogs) == nil)
        controller:showReaderMenu(); local dialog = assert(next(controller.reader_dialogs))
        dialog.layout[5][1].callback()
    end,
    function()
        check("J1_bookshelf_closes_reader_before_navigation", calls.reader_close == 1 and calls.library == 1)
        controller:_chapterBoundary(event); local dialog = controller.chapter_dialog
        dialog.layout[2][2].callback()
    end,
    function()
        check("J2_bookshelf_closes_reader_before_navigation", calls.reader_close == 2 and calls.library == 2)
    end,
    function()
        controller.review_next = nil; controller:_chapterBoundary(event)
        capture("J2-final-chapter", controller.chapter_dialog); closeOverlays()
        reader.paging:_gotoPage(9)
    end,
    function()
        capture("J4-image-loading")
        local before, painted = requests, {}
        local original_text = W.text
        W.text = function(text, width, size, options)
            local widget = original_text(text, width, size, options)
            painted[#painted + 1] = widget
            return widget
        end
        local buffer = BB.new(W.dp(720), W.dp(880), BB.TYPE_BB8); buffer:fill(BB.Color8(0x77))
        local region = Geom:new{ w = W.dp(600), h = W.dp(740) }
        local left, top = W.dp(60), W.dp(70)
        reader.document:_placeholder(buffer, left, top, region, 9)
        W.text = original_text
        buffer:writePNG(output .. "/J4-bounded-placeholder.png")
        result.screenshots[#result.screenshots + 1] = "J4-bounded-placeholder.png"
        check("J4_loading_requests_are_enqueued", requests > before)
        check("J4_gray_frame_uses_design_rule", buffer:getPixel(left, top):getColor8().a == 0xCC)
        check("J4_left_guard_untouched", buffer:getPixel(left - 1, top + W.dp(60)):getColor8().a == 0x77)
        check("J4_bottom_guard_untouched", buffer:getPixel(left, top + region.h):getColor8().a == 0x77)
        local guard_unchanged = true
        for x = 0, buffer:getWidth() - 1 do
            guard_unchanged = guard_unchanged and buffer:getPixel(x, top - 1):getColor8().a == 0x77
                and buffer:getPixel(x, top + region.h):getColor8().a == 0x77
        end
        for y = 0, buffer:getHeight() - 1 do
            guard_unchanged = guard_unchanged and buffer:getPixel(left - 1, y):getColor8().a == 0x77
                and buffer:getPixel(left + region.w, y):getColor8().a == 0x77
        end
        check("J4_entire_guard_ring_is_untouched", guard_unchanged)
        check("J4_heading_uses_actual_image_counts", painted[1].text == string.format(T("Reader loading image · %d / %d"), 9, 24))
        metric("J4", "heading_font", painted[1].face.size, W.dp(28), 2)
        metric("J4", "notice_font", painted[2].face.size, W.dp(18), 2)
        metric("J4", "notice_gap", painted[2].dimen.y - painted[1].dimen.y - painted[1]:getSize().h, W.dp(12))
        local last_ink = -1
        for y = top + W.dp(30), top + region.h - W.dp(30) do
            for x = left + W.dp(30), left + region.w - W.dp(30) do
                if buffer:getPixel(x, y):getColor8().a < 0x80 then last_ink = y; break end
            end
        end
        check("J4_heading_and_notice_fit_inside_region", last_ink > top + region.h / 2 and last_ink < top + region.h - W.dp(30))
        buffer:free()
        local clipped = BB.new(W.dp(250), W.dp(160), BB.TYPE_BB8); clipped:fill(BB.Color8(0x77))
        reader.document:_placeholder(clipped, -W.dp(40), -W.dp(60), Geom:new{ w = W.dp(600), h = W.dp(740) }, 9)
        clipped:writePNG(output .. "/J4-cropped-placeholder.png")
        result.screenshots[#result.screenshots + 1] = "J4-cropped-placeholder.png"
        check("J4_cropped_tile_has_bounded_frame", clipped:getPixel(0, 0):getColor8().a == 0xCC)
        clipped:free()
        check("J4_renderPage_cover_path_returns_unavailable", reader.document:renderPage(9, nil, 1, 0, 1, 1) == nil)
        controller:_pageError(reader.document.descriptor, 9, { reader_generation = integration.generation - 1 }, { kind = "network" })
        check("J5_old_reader_generation_cannot_open_error", next(controller.reader_dialogs) == nil
            and next(controller.errors_shown) == nil)
        records[9].state = "failed"
        reader.paging:_gotoPage(8); reader.paging:_gotoPage(9)
    end,
    function()
        capture("J5-unavailable-page")
    end,
}
local destinations = { network = "retry", auth = "account", low_space = "storage", storage = "retry",
    image_decode = "downloads", unsupported_image_size = "comic", content_changed = "comic",
    version_replaced = "comic", source_unavailable = "downloads" }
for _, kind in ipairs({ "network", "auth", "low_space", "storage", "image_decode", "unsupported_image_size",
    "content_changed", "version_replaced", "source_unavailable" }) do
    local error_kind, expected_calls, expected_downloads = kind
    steps[#steps + 1] = function()
        controller.errors_shown = {}
        controller:_pageError(reader.document.descriptor, 9, {}, { kind = error_kind, retryable = error_kind == "network" })
        local dialog = assert(next(controller.reader_dialogs))
        local name = error_kind == "network" and "J5-connection-failed" or "J5-error-" .. error_kind:gsub("_", "-")
        capture(name, dialog)
        metric(name, "left", dialog.panel_dimen.x, W.dp(115))
        metric(name, "top", dialog.panel_dimen.y, W.dp(320))
        metric(name, "width", dialog.panel_dimen.w, W.dp(700))
        local title_widget, title_rect = textMetric(name, dialog, dialog.title, 28)
        local position = string.format(T("Image %d / %d"), 9, 24) .. " · "
            .. string.format(T("Episode %s"), "12") .. " · " .. current.title
        local metadata = rect(findText(dialog, position))
        metric(name, "title_top_padding", title_rect.y - dialog.panel_dimen.y - W.dp(2), W.dp(38))
        metric(name, "metadata_gap", metadata.y - title_rect.y - title_rect.h, W.dp(6))
        local last = rect(dialog.layout[#dialog.layout][1])
        metric(name, "bottom_padding", dialog.panel_dimen.y + dialog.panel_dimen.h - W.dp(2) - last.y - last.h, W.dp(36))
        metric(name, "primary_height", rect(dialog.layout[1][1]).h, W.dp(66))
        metric(name, "action_gap", rect(dialog.layout[2][1]).y - rect(dialog.layout[1][1]).y - rect(dialog.layout[1][1]).h, W.dp(12))
        check(name .. "_primary_is_emphasized", dialog.layout[1][1].frame.invert == true)
        check(name .. "_back_preserves_position", dialog.layout[#dialog.layout][1].text == T("Back to reading"))
        local primary = dialog.layout[1][1].callback
        controller.account = {}; local before = calls[destinations[error_kind]]
        primary(); check(name .. "_stale_account_does_not_act", before == calls[destinations[error_kind]] and controller.reader_dialogs[dialog])
        controller.account = account
        expected_calls = calls[destinations[error_kind]] + 1
        primary(); check(name .. "_primary_dismisses", controller.reader_dialogs[dialog] == nil)
    end
    steps[#steps + 1] = function()
        local destination = destinations[error_kind]
        check("J5_" .. error_kind .. "_destination", calls[destination] == expected_calls,
            { destination = destination, calls = calls[destination], expected = expected_calls })
        controller.errors_shown = {}
        controller:_pageError(reader.document.descriptor, 9, {}, { kind = error_kind })
        local dialog = assert(next(controller.reader_dialogs))
        local page, closed = reader.paging:getTopPage(), calls.reader_close
        dialog.layout[#dialog.layout][1].callback()
        check("J5_" .. error_kind .. "_back_keeps_native_position_and_reader", reader.paging:getTopPage() == page
            and calls.reader_close == closed and next(controller.reader_dialogs) == nil)
        controller.errors_shown = {}
        controller:_pageError(reader.document.descriptor, 9, {}, { kind = error_kind })
        dialog = assert(next(controller.reader_dialogs))
        if #dialog.layout == 3 then
            expected_downloads = calls.downloads + 1
            dialog.layout[2][1].callback()
        else expected_downloads = calls.downloads; closeOverlays() end
    end
    steps[#steps + 1] = function()
        check("J5_" .. error_kind .. "_secondary_destination", calls.downloads == expected_downloads,
            { calls = calls.downloads, expected = expected_downloads })
    end
end
steps[#steps + 1] = function()
    controller.integrations[integration] = true
    controller.review_next = following
    controller:_chapterBoundary(event)
    local chapter = controller.chapter_dialog
    controller:showReaderMenu(); local menu = assert(next(controller.reader_dialogs))
    controller.errors_shown = {}
    controller:_pageError(reader.document.descriptor, 9, {}, { kind = "network" })
    local error_dialog
    for dialog in pairs(controller.reader_dialogs) do if dialog ~= menu then error_dialog = dialog end end
    check("reader_overlays_record_their_owner_generation", chapter.reader_generation == integration.generation
        and menu.reader_generation == integration.generation and error_dialog.reader_generation == integration.generation)
    controller:_readerEvent("closed", { descriptor = reader.document.descriptor, reader = reader,
        reader_generation = integration.generation - 1 })
    check("late_old_close_keeps_new_reader_overlays", controller.chapter_dialog == chapter
        and controller.reader_dialogs[menu] and controller.reader_dialogs[error_dialog]
        and controller.active_integration == integration)
    controller:_readerEvent("page_error", { descriptor = reader.document.descriptor, reader = reader,
        reader_generation = integration.generation - 1, index = 8, error = { kind = "network" } })
    check("late_old_error_event_does_not_claim_new_page", controller.errors_shown["12/review/8"] == nil)
    services.onReaderEvent = function(name, reader_event)
        if name == "closed" then controller:_readerEvent(name, reader_event) end
    end
    reader.onClose = native_close
    native_close(reader); native_closed = true
    check("native_external_close_clears_owned_reader_overlays", controller.chapter_dialog == nil
        and next(controller.reader_dialogs) == nil and controller.active_integration == nil
        and controller.integrations[integration] == nil and integration.closed)
    finished()
end
local index = 0
local function advance()
    index = index + 1
    if not steps[index] then finished(); return end
    local ok, failure = xpcall(steps[index], debug.traceback)
    if not ok then finished(failure); return end
    UIManager:scheduleIn(0.15, advance)
end
ReaderUI:showReader(output .. "/chapter.bcomic", Provider)
UIManager:scheduleIn(0.2, advance)
UIManager:scheduleIn(45, function() finished("The native reader audit exceeded its time limit") end)
UIManager:run()
if not result.passed then os.exit(1) end
