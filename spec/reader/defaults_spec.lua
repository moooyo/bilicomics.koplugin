-- Execute only in the official runtime on the authorized remote test-env host.
require("setupkoenv")
local plugin_root, output, case, phase = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
package.path = plugin_root .. "/?.lua;" .. package.path
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
G_reader_settings:saveSetting("color_rendering", false)
G_reader_settings:saveSetting("page_turns_tap_zones", "left_right")
-- Ordinary PDF defaults must not change BiliComics auto or absolute direction.
G_reader_settings:saveSetting("kopt_zoom_mode_genus", 1)
G_reader_settings:saveSetting("kopt_zoom_mode_type", 1)
G_reader_settings:saveSetting("kopt_page_scroll", 0)
G_reader_settings:saveSetting("inverse_reading_order", true)
local BD = require("ui/bidi")
BD.setup(case:find("mirrored") and "ar" or "en")
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local DocSettings = require("docsettings")
local Integration = require("bilicomics/reader/integration")
local Anchors = require("bilicomics/reader/anchors")
local Provider = require("bilicomics/reader/document")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local report = { case = case, phase = phase, assertions = {} }
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
local function read(path)
    local file = assert(io.open(path, "rb")); local data = file:read("*a"); file:close()
    return json.decode(data)
end
local function write(path, data)
    local file = assert(io.open(path, "wb")); file:write(json.encode(data)); file:close()
end
local file = output .. "/chapter.bcomic"
local records = read(output .. "/pages.json")
local stored_anchor
if lfs.attributes(output .. "/anchor.json", "mode") == "file" then stored_anchor = read(output .. "/anchor.json") end
local preference = { reading_mode = "auto", reading_direction = "ltr" }
local expected = { zoom = "page", scroll = false, rtl = false }
if case == "auto_strip" or case == "legacy_anchor" or case == "forced_strip" then
    expected.zoom, expected.scroll = "pagewidth", true
end
if case == "forced_page" or case == "rtl_mirrored" or case == "rtl_pan" then
    preference.reading_mode, preference.reading_direction, expected.rtl = "page", "rtl", true
elseif case == "ltr_mirrored" then preference.reading_mode = "page"
elseif case == "free_pan" then preference.reading_mode = "page"
elseif case == "forced_strip" then preference.reading_mode = "strip"
elseif case == "saved_native" or case == "stale_free_anchor" then
    preference.reading_mode, preference.reading_direction = "strip", "rtl"
elseif case == "anchor_only" then
    preference.reading_mode, preference.reading_direction = "strip", "rtl"
    expected.rtl = true -- Native global direction is retained for a previously read chapter.
elseif case == "changed_native" then
    preference.reading_mode = "strip"
    if phase == "open" then expected.zoom, expected.scroll = "pagewidth", true else expected.rtl = true end
end
if case == "rtl_pan" and phase == "reopen" then
    preference.reading_direction, expected.zoom = "ltr", "pageheight"
end
if case == "free_pan" and phase == "reopen" then expected.zoom = "free" end
if phase == "reopen" and case == "auto_strip" then
    preference.reading_mode, preference.reading_direction = "page", "rtl"
end
if phase == "open" then
    local config = DocSettings:open(file)
    if case == "saved_native" or case == "stale_free_anchor" then
        if case == "saved_native" then config:saveSetting("zoom_mode", "page") else
            config:saveSetting("kopt_zoom_mode_genus", 4)
            config:saveSetting("kopt_zoom_mode_type", 2)
        end
        config:saveSetting("kopt_page_scroll", 0)
        config:saveSetting("inverse_reading_order", false)
        config:saveSetting("kopt_writing_direction", 0)
    elseif case == "legacy_anchor" then
        config:saveSetting("bilicomics_reader_initialized", true)
        config:saveSetting("zoom_mode", "pagewidth")
        config:saveSetting("inverse_reading_order", false)
    end
    if case == "legacy_anchor" or case == "anchor_only" or case == "stale_free_anchor" then
        stored_anchor = { schema_version = 1, page_id = "p2", index = 2, x = 0, y = 0.2,
            mode = case == "legacy_anchor" and "continuous" or "page",
            zoom_mode = case == "stale_free_anchor" and "free" or case == "legacy_anchor" and "pagewidth" or "page",
            zoom_ratio = 2, geometry_generation = 1 }
        write(output .. "/anchor.json", stored_anchor)
    end
    config:flush()
end
local active, requests, events = 0, 0, {}
local services = {
    settings = { get = function(_, key, fallback) local value = preference[key]; if value ~= nil then return value end; return fallback end,
        flush = function() end },
    authorizeDescriptor = function() return true end,
    pages = { getPage = function(_, _, _, index) return records[index] end,
        setActiveEpisode = function(_, _, _, enabled) active = active + (enabled and 1 or -1) end },
    store = { getEpisode = function() return { title = "Synthetic defaults chapter" } end,
        getComic = function() return { title = "Default reader contract" } end,
        getAnchor = function() return stored_anchor end,
        putAnchor = function(_, _, _, anchor) stored_anchor = anchor; write(output .. "/anchor.json", anchor) end },
    requestPage = function() requests = requests + 1 end,
    onReaderEvent = function(name) events[name] = (events[name] or 0) + 1 end,
}
local integration
local app = { account = { key = "test", reader_services = services }, settings = services.settings,
    attachReader = function(_, reader) integration = assert(Integration.attach(reader)) end }
-- Keep the actual plugin hooks and native ReaderUI; replace only account construction.
package.loaded["bilicomics/runtime"] = { get = function() return app end, peek = function() return app end, close = function() end }
local Plugin = dofile(plugin_root .. "/main.lua")
require("pluginloader").loaded_plugins = {}
require("pluginloader").loadPlugins = function() return { Plugin } end
Provider:setServicesResolver(function() return services end)
Provider:register(require("document/documentregistry"))
local ReaderUI = require("apps/reader/readerui")
local function run()
    ReaderUI:showReader(file, Provider)
    UIManager:scheduleIn(0.35, function()
        local reader = assert(ReaderUI.instance)
        check("production ReaderReady attaches", integration and reader.bilicomics_integration == integration and active == 1)
        check("production DocSettingsLoad captures initial settings", reader.bilicomics_initial_settings ~= nil)
        if case == "auto_strip" and phase == "open" then
            local initial = reader.bilicomics_initial_settings
            check("native default population is not mistaken for saved document preferences", not initial.visited and not initial.zoom and not initial.scroll)
        end
        check("requested native zoom is active", reader.zooming.zoom_mode == expected.zoom, reader.zooming.zoom_mode)
        check("requested native scroll is active", reader.view.page_scroll == expected.scroll, reader.view.page_scroll)
        check("requested absolute direction is active", (reader.view.inverse_reading_order ~= BD.mirroredUILayout()) == expected.rtl)
        if case == "rtl_pan" or case == "forced_page" or case == "rtl_mirrored" then
            check("native page traversal starts from the right", reader.document.configurable.writing_direction == 1)
        end
        check("descriptor page order remains unchanged", reader.document.descriptor.pages[1].id == "p1"
            and reader.document.descriptor.pages[3].id == "p3")
        check("normal visible requests still run", requests > 0 and events.opened == 1)
        if phase == "reopen" then
            local previous = read(output .. "/expected-anchor.json")
            local actual = Anchors.capture(reader)
            check("saved source position survives native process restart", actual.page_id == previous.page_id
                and math.abs(actual.y - previous.y) < 0.005 and math.abs(actual.x - previous.x) < 0.005,
                { previous = previous, actual = actual })
        elseif case == "forced_page" or case:find("mirrored") then
            local forward, backward = reader.view:getTapZones()
            check("native touch zones follow absolute direction", expected.rtl and forward.ratio_x < backward.ratio_x
                or not expected.rtl and forward.ratio_x > backward.ratio_x)
            reader.paging:_gotoPage(1)
            reader.paging:onSwipe(nil, { direction = expected.rtl and "east" or "west" })
            check("native swipe advances in the selected direction", reader.paging:getTopPage() == 2)
            reader.paging:onSwipe(nil, { direction = expected.rtl and "west" or "east" })
            check("opposite native swipe returns to previous page", reader.paging:getTopPage() == 1)
            reader._zones.tap_forward.handler()
            check("registered native forward tap advances", reader.paging:getTopPage() == 2)
            reader._zones.tap_backward.handler()
            check("registered native backward tap returns", reader.paging:getTopPage() == 1)
        end
        if case == "free_pan" and phase == "open" then
            reader.zooming:onSetZoomMode("pagewidth")
            reader.zooming:onZoom("in")
            reader.zooming:onZoom("in")
            reader.view:PanningUpdate(200, 700)
            expected.zoom = "free"
        elseif case == "rtl_pan" and phase == "open" then
            reader.zooming:onSetZoomMode("pageheight")
            reader.paging:_gotoPage(1)
            local right = reader.view.visible_area.x
            check("native page-height zoom starts at the right edge", right > 600
                and math.abs(right + reader.view.visible_area.w - reader.view.page_area.w) < 1, right)
            reader.paging:onGotoViewRel(1)
            check("native next viewport progresses from right to left within the page", reader.paging:getTopPage() == 1
                and reader.view.visible_area.x < right and reader.view.visible_area.x > 0, reader.view.visible_area.x)
            expected.zoom = "pageheight"
        elseif case == "changed_native" and phase == "open" then
            reader.view:onSetScrollMode(false)
            reader.zooming:onSetZoomMode("page")
            reader.view:onToggleReadingOrder(true)
            expected.zoom, expected.scroll, expected.rtl = "page", false, true
        elseif case == "auto_strip" and phase == "open" then
            reader.paging:onTogglePageFlipping()
            reader:saveSettings()
            check("temporary native page flipping does not replace continuous setting", reader.doc_settings:readSetting("kopt_page_scroll") == 1)
            reader.paging:onTogglePageFlipping()
            reader.paging:enterSkimMode()
            reader:saveSettings()
            check("temporary native skim mode does not replace continuous setting", reader.doc_settings:readSetting("kopt_page_scroll") == 1)
            reader.paging:exitSkimMode()
            reader.paging:_gotoPage(2)
            reader.paging:onGotoViewRel(1)
        end
        integration:saveAnchor()
        write(output .. "/expected-anchor.json", Anchors.capture(reader))
        reader:onClose()
        check("native close releases active chapter", integration.closed and active == 0 and ReaderUI.instance == nil)
        local saved = DocSettings:open(file)
        check("native document stores selected scroll mode", saved:readSetting("kopt_page_scroll") == (expected.scroll and 1 or 0))
        check("native document stores selected zoom", saved:readSetting("zoom_mode") == expected.zoom)
        check("native document stores selected reading order", (saved:isTrue("inverse_reading_order") ~= BD.mirroredUILayout()) == expected.rtl)
        if case == "rtl_pan" then check("native document persists RTL page traversal", saved:readSetting("kopt_writing_direction") == 1) end
        check("native document stores initialized marker", saved:isTrue("bilicomics_reader_initialized"))
        UIManager:quit()
    end)
    UIManager:scheduleIn(15, function() error("Native defaults test timeout") end)
    UIManager:run()
end
local ok, failure = xpcall(run, debug.traceback)
report.success, report.failure = ok, not ok and failure or nil
write(output .. "/" .. phase .. "-results.json", report)
print(json.encode(report))
if not ok then os.exit(1) end
