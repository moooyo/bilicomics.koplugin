-- Research-only native ReaderUI integration probe. Run on test-env only.
require("setupkoenv")
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
G_reader_settings:saveSetting("kopt_zoom_mode_genus", 4)
G_reader_settings:saveSetting("kopt_zoom_mode_type", 1)
G_reader_settings:saveSetting("kopt_page_scroll", 1)
local Device = require("device")
require("document/canvascontext"):init(Device)
local Document = require("document/document")
local Registry = require("document/documentregistry")
local Geom = require("ui/geometry")
local DrawContext = require("ffi/drawcontext")
local BB = require("ffi/blitbuffer")
local json = require("rapidjson")
local mupdf = require("ffi/mupdf")
local root, mode = assert(arg[1]), arg[2] or "render"
local manifest_path = root .. "/episode.bcomic"
local result = { mode = mode, assertions = {}, backend_opens = 0, missing_draws = 0, hints = 0 }
local function check(name, condition, data)
    result.assertions[#result.assertions + 1] = { name = name, passed = not not condition, data = data }
    assert(condition, name)
end
local function read_json(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return json.decode(data)
end
local function save_result()
    local file = assert(io.open(root .. "/" .. mode .. "-result.json", "wb"))
    file:write(json.encode(result, { pretty = true }))
    file:close()
end
local Provider = Document:extend{
    provider = "bilicomics_research",
    provider_name = "Bilibili Comics Research",
    is_pic = true,
    dc_null = DrawContext.new(),
}
function Provider:init()
    self.manifest = read_json(self.file)
    self.info.has_pages = true
    self.info.configurable = false
    self.info.number_of_pages = #self.manifest.pages
    self.render_mode = 0
    self.mod_time = lfs.attributes(self.file, "modification")
    self.generation = {}
    self.configurable.text_wrap = 0
    self.configurable.writing_direction = 0
    self.configurable.trim_page = 0
    self.configurable.page_margin = 0
    self.configurable.background_cleanup = 0
    self.configurable.page_scroll = 1
    self:updateColorRendering()
    local owner = self
    self._document = {
        openPage = function(_, number)
            local spec = assert(owner.manifest.pages[number])
            assert(lfs.attributes(spec.path, "mode") == "file", "Missing image reached native backend")
            result.backend_opens = result.backend_opens + 1
            local engine = mupdf.openDocument(spec.path)
            local page = engine:openPage(1)
            return {
                getSize = function(_, ...) return page:getSize(...) end,
                draw = function(_, ...) return page:draw(...) end,
                close = function() page:close(); engine:close() end,
            }
        end,
        close = function() end,
    }
    self.is_open = true
end
function Provider:getDocumentProps() return { title = "Native Reader Research", authors = "Synthetic fixture" } end
function Provider:getToc() return {} end
function Provider:getNativePageDimensions(number)
    local page = assert(self.manifest.pages[number])
    return Geom:new{ w = page.width, h = page.height }
end
function Provider:getUsedBBox(number)
    local page = assert(self.manifest.pages[number])
    return { x0 = 0, y0 = 0, x1 = page.width, y1 = page.height }
end
function Provider:getFullPageHash(number, ...)
    return Document.getFullPageHash(self, number, ...) .. "|generation=" .. (self.generation[number] or 0)
end
function Provider:getPagePartHash(number, ...)
    return Document.getPagePartHash(self, number, ...) .. "|generation=" .. (self.generation[number] or 0)
end
function Provider:ready(number)
    return lfs.attributes(self.manifest.pages[number].path, "mode") == "file"
end
function Provider:drawPage(target, x, y, rect, number, ...)
    if not self:ready(number) then
        result.missing_draws = result.missing_draws + 1
        target:paintRect(x, y, rect.w, rect.h, BB.Color8(235))
        return
    end
    return Document.drawPage(self, target, x, y, rect, number, ...)
end
function Provider:hintPage()
    result.hints = result.hints + 1
end
function Provider:getWordFromPosition() return nil end
function Provider:getOCRText() return nil end
function Provider:getPanelFromPage() return nil end
function Provider:getPageBlock() return nil end
function Provider:getPageBoxesFromPositions() return nil end
function Provider:getSelectedWordContext() return nil, nil end
function Provider:getPageText() return {} end
function Provider:findText() return nil, 0 end
Registry:addProvider("bcomic", "application/x-bilicomics-research", Provider, 100)

local function render_probe()
    local doc = assert(Registry:openDocument(manifest_path, Provider))
    check("stable_page_count", doc:getPageCount() == 2)
    local opens = result.backend_opens
    check("missing_geometry_is_local", doc:getNativePageDimensions(2).h == 1600 and result.backend_opens == opens)
    local rect = Geom:new{ x = 0, y = 650, w = 600, h = 400 }
    local bb = BB.new(600, 400)
    doc:drawPage(bb, 0, 0, rect, 1, 1, 0, 1, 1)
    check("native_mid_image_crop", math.abs(bb:getPixel(300, 100):getR() - 100) <= 1, bb:getPixel(300, 100):getR())
    bb:writePNG(root .. "/native-crop.png")
    local waiting = BB.new(600, 400)
    doc:drawPage(waiting, 0, 0, Geom:new{ x = 0, y = 0, w = 600, h = 400 }, 2, 1, 0, 1, 1)
    check("missing_page_does_not_open_backend", result.backend_opens == opens + 1 and waiting:getPixel(100,100):getR() == 235)
    assert(os.rename(root .. "/fixtures/page-2.ready.png", root .. "/fixtures/page-2.png"))
    doc.generation[2] = 1
    doc:drawPage(waiting, 0, 0, Geom:new{ x = 0, y = 0, w = 600, h = 400 }, 2, 1, 0, 1, 1)
    check("same_document_missing_page_becomes_ready", math.abs(waiting:getPixel(300,100):getR() - 60) <= 1)
    waiting:writePNG(root .. "/native-page-ready.png")
    local full1 = doc:getFullPageHash(2, 1, 0, 1, 1)
    doc.generation[2] = 2
    check("same_second_generation_changes_cache_key", full1 ~= doc:getFullPageHash(2, 1, 0, 1, 1))
    waiting:free(); bb:free()
    doc:close()
    check("registry_reference_released", Registry:getReferenceCount(manifest_path) == nil)
end

local function ui_probe()
    local UIManager = require("ui/uimanager")
    local ReaderUI = require("apps/reader/readerui")
    local Event = require("ui/event")
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    ReaderUI:showReader(manifest_path, Provider)
    UIManager:scheduleIn(0.2, function()
        local reader = assert(ReaderUI.instance, "Native ReaderUI did not open")
        check("native_readerui_opened", reader.document.provider == Provider.provider)
        check("native_paging_and_zooming", reader.paging ~= nil and reader.zooming ~= nil)
        reader.zooming:onSetZoomMode("pagewidth")
        reader.view:onSetScrollMode(true)
        if mode == "ui-online" then
            reader.paging:_gotoPage(2)
            reader.paging:onGotoViewRel(1)
            local waiting_position = reader.paging:getTopPosition()
            UIManager:setDirty(reader.dialog, "full")
            UIManager:scheduleIn(0.1, function()
                check("native_ui_can_display_and_pan_missing_page", result.missing_draws > 0 and waiting_position > 0)
                Device.screen.bb:writePNG(root .. "/ui-waiting.png")
                result.event_loop_callback_while_missing = true
                assert(os.rename(root .. "/fixtures/page-2.pending.png", root .. "/fixtures/page-2.png"))
                reader.document.generation[2] = (reader.document.generation[2] or 0) + 1
                UIManager:setDirty(reader.dialog, "partial")
                UIManager:scheduleIn(0.1, function()
                    local current = reader.paging:getTopPosition()
                    local pixel = Device.screen.bb:getPixel(300, 100):getR()
                    check("native_ui_completion_preserves_viewport", reader.paging:getTopPage() == 2 and math.abs(current - waiting_position) < 0.0001,
                        { before = waiting_position, after = current })
                    check("native_ui_completion_replaces_loading_pixels", math.abs(pixel - 180) <= 1, pixel)
                    Device.screen.bb:writePNG(root .. "/ui-online.png")
                    reader:onClose()
                    UIManager:quit()
                end)
            end)
            return
        end
        if mode == "ui-reopen" then
            local expected = read_json(root .. "/saved-position.json")
            local actual = reader.paging:getTopPosition()
            check("native_scroll_position_survives_restart", reader.paging:getTopPage() == expected.page and math.abs(actual - expected.position) < 0.02,
                { expected = expected.position, actual = actual })
        else
            reader.paging:onGotoViewRel(1)
            local position = reader.paging:getTopPosition()
            check("native_viewport_advances_inside_long_image", reader.paging:getTopPage() == 1 and position > 0,
                { page = reader.paging:getTopPage(), position = position })
            local intercepted = 0
            local interceptor = WidgetContainer:new{}
            function interceptor:onEndOfBook() intercepted = intercepted + 1; return true end
            table.insert(reader.status, 1, interceptor)
            local before = #UIManager._window_stack
            reader:handleEvent(Event:new("EndOfBook"))
            check("instance_scoped_end_of_book_interception", intercepted == 1 and #UIManager._window_stack == before)
            local saved = { page = reader.paging:getTopPage(), position = position }
            local file = assert(io.open(root .. "/saved-position.json", "wb"))
            file:write(json.encode(saved)); file:close()
        end
        UIManager:setDirty(reader.dialog, "full")
        UIManager:scheduleIn(0.1, function()
            Device.screen.bb:writePNG(root .. "/" .. mode .. ".png")
            reader:onClose()
            check("native_reader_closed_cleanly", ReaderUI.instance == nil)
            UIManager:quit()
        end)
    end)
    UIManager:scheduleIn(8, function() error("Native ReaderUI probe timeout") end)
    UIManager:run()
end

local ok, failure = xpcall(function()
    if mode == "render" then render_probe() else ui_probe() end
end, debug.traceback)
result.success = ok
result.failure = ok and nil or failure
save_result()
print(json.encode(result))
if not ok then os.exit(1) end
