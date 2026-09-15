-- Capture production ReaderUI and controller-owned overlays with synthetic pages.
require("setupkoenv")
local plugin, output = assert(arg[1]), assert(arg[2])
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
require("gettext").current_lang = "zh_CN"
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local ReaderUI = require("apps/reader/readerui")
local Provider = require("bilicomics/reader/document")
local Registry = require("document/documentregistry")
local Integration = require("bilicomics/reader/integration")
local Controller = require("bilicomics/controller")
local json = require("rapidjson")
local file = assert(io.open(output .. "/pages.json", "rb"))
local records = json.decode(file:read("*a")); file:close()
local saved_anchor
local services = {
    authorizeDescriptor = function(descriptor) return descriptor.account_key == "review" end,
    settings = { reading_mode = "page", reading_direction = "ltr" },
    pages = {
        getPage = function(_, _, _, index) return records[index] end,
        setActiveEpisode = function() end,
    },
    store = {
        getEpisode = function() return { title = "Synthetic review chapter" } end,
        getComic = function() return { title = "Original review panels" } end,
        getAnchor = function() return saved_anchor end,
        putAnchor = function(_, _, _, anchor) saved_anchor = anchor end,
    },
    requestPage = function() end,
    onReaderEvent = function() end,
}
Provider:setServicesResolver(function(account) assert(account == "review"); return services end)
Provider:register(Registry)
local controller = setmetatable({ ui_manager = UIManager, reader_dialogs = {}, errors_shown = {}, account = {} }, { __index = Controller })
function controller:_nextEpisode() return self.review_next end
local reader, integration
local result = { scope = "Production ReaderUI and controller overlays; synthetic pages; no HTTP or account",
    screens = {}, assertions = {}, passed = false }
local function closeOverlays()
    if controller.chapter_dialog then
        UIManager:close(controller.chapter_dialog); controller.chapter_dialog = nil
    end
    local dialogs = {}
    for dialog in pairs(controller.reader_dialogs) do dialogs[#dialogs + 1] = dialog end
    for _, dialog in ipairs(dialogs) do UIManager:close(dialog); controller.reader_dialogs[dialog] = nil end
end
local function capture(name)
    UIManager:forceRePaint()
    Device.screen.bb:writePNG(output .. "/" .. name .. ".png")
    result.screens[#result.screens + 1] = name .. ".png"
    local dialog = controller.chapter_dialog or next(controller.reader_dialogs)
    if dialog and dialog.movable then
        local size = dialog.movable:getSize()
        local fits = size.w <= Device.screen:getWidth() and size.h <= Device.screen:getHeight()
        result.assertions[#result.assertions + 1] = { name = name .. "_fits_screen", passed = fits }
        assert(fits, name .. " exceeds the screen")
    end
end
local function finish(failure)
    closeOverlays()
    if reader then reader:onClose() end
    result.passed, result.error = failure == nil, failure
    local report = assert(io.open(output .. "/review-reader-result.json", "wb"))
    report:write(json.encode(result, { pretty = true })); report:close()
    print(json.encode(result))
    UIManager:quit()
end
local steps = {
    function()
        reader = assert(ReaderUI.instance)
        integration = assert(Integration.attach(reader))
        controller.active_integration = integration
    end,
    function() reader.zooming:onSetZoomMode("page"); reader.view:onSetScrollMode(false); reader.paging:_gotoPage(1) end,
    function() capture("reader-page-fit") end,
    function() controller:showReaderMenu(); capture("reader-menu"); closeOverlays() end,
    function()
        controller.review_next = { id = "next", access = "free", free = true }
        controller:_chapterBoundary{ descriptor = reader.document.descriptor, reader = reader }
        capture("reader-next-free"); closeOverlays()
    end,
    function()
        controller.review_next = { id = "next", access = "locked" }
        controller:_chapterBoundary{ descriptor = reader.document.descriptor, reader = reader }
        capture("reader-next-locked"); closeOverlays()
    end,
    function()
        controller.review_next = nil
        controller:_chapterBoundary{ descriptor = reader.document.descriptor, reader = reader }
        capture("reader-final-chapter"); closeOverlays()
    end,
    function() reader.zooming:onSetZoomMode("pagewidth"); reader.view:onSetScrollMode(true); reader.paging:_gotoPage(2) end,
    function() capture("reader-long-strip") end,
    function() reader.view:onSetScrollMode(false); reader.paging:_gotoPage(1); reader.zooming:onZoom("in") end,
    function() capture("reader-zoom") end,
    function() reader.zooming:onSetZoomMode("page"); reader.paging:_gotoPage(3) end,
    function() capture("reader-image-loading") end,
}
for _, kind in ipairs({ "network", "auth", "low_space", "image_decode", "unsupported_image_size", "content_changed", "version_replaced", "source_unavailable" }) do
    local error_kind = kind
    steps[#steps + 1] = function()
        controller.errors_shown = {}
        controller:_pageError(reader.document.descriptor, 3, {}, { kind = error_kind, retryable = error_kind == "network" })
        capture("reader-error-" .. error_kind:gsub("_", "-")); closeOverlays()
    end
end
local index = 0
local function advance()
    index = index + 1
    if not steps[index] then finish(); return end
    local ok, failure = xpcall(steps[index], debug.traceback)
    if not ok then finish(failure); return end
    UIManager:scheduleIn(0.15, advance)
end
ReaderUI:showReader(output .. "/chapter.bcomic", Provider)
UIManager:scheduleIn(0.2, advance)
UIManager:scheduleIn(30, function() finish("The reader capture exceeded its time limit") end)
UIManager:run()
if not result.passed then os.exit(1) end
