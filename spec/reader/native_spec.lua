-- Execute only inside the isolated official runtime on test-env.
require("setupkoenv")
local plugin_root, output, mode = assert(arg[1]), assert(arg[2]), arg[3] or "render"
package.path = plugin_root .. "/?.lua;" .. package.path
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
local Device = require("device")
require("document/canvascontext"):init(Device)
local Provider = require("bilicomics/reader/document")
local Integration = require("bilicomics/reader/integration")
local Registry = require("document/documentregistry")
local Geom = require("ui/geometry")
local BB = require("ffi/blitbuffer")
local json = require("rapidjson")
local ffi = require("ffi")
local pid = ffi.C.getpid()
local report = { mode = mode, assertions = {} }
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
local function read(path)
    local file = assert(io.open(path, "rb")); local data = file:read("*a"); file:close()
    return json.decode(data)
end
local function write(path, value)
    local file = assert(io.open(path, "wb")); file:write(json.encode(value)); file:close()
end
local function unchangedOutside(buffer, left, top, right, bottom, value)
    for y = 0, buffer:getHeight() - 1 do
        for x = 0, buffer:getWidth() - 1 do
            if (x < left or x >= right or y < top or y >= bottom)
                and buffer:getPixel(x, y):getR() ~= value then return false end
        end
    end
    return true
end
local function solidPixels(buffer, value, tolerance)
    for y = 0, buffer:getHeight() - 1 do
        for x = 0, buffer:getWidth() - 1 do
            if math.abs(buffer:getPixel(x, y):getR() - value) > (tolerance or 0) then return false end
        end
    end
    return true
end
local function invertedPixels(ordinary, inverted)
    for y = 0, ordinary:getHeight() - 1 do
        for x = 0, ordinary:getWidth() - 1 do
            if inverted:getPixel(x, y):getR() ~= 255 - ordinary:getPixel(x, y):getR() then return false end
        end
    end
    return true
end
local manifest_path = output .. "/chapter.bcomic"
local records = read(output .. "/pages.json")
local hints, events, active = 0, {}, 0
local stored_anchor
if lfs.attributes(output .. "/anchor.json", "mode") == "file" then stored_anchor = read(output .. "/anchor.json") end
local services = {
    authorizeDescriptor = function(descriptor) return descriptor.account_key == "test" end,
    settings = {},
    pages = {
        getPage = function(_, _, _, index)
            assert(ffi.C.getpid() == pid, "A thumbnail child accessed the parent store")
            return records[index]
        end,
        setActiveEpisode = function(_, _, _, enabled) active = active + (enabled and 1 or -1) end,
    },
    store = {
        getEpisode = function() return { title = "Synthetic chapter" } end,
        getComic = function() return { title = "Native reader contract" } end,
        getAnchor = function() return stored_anchor end,
        putAnchor = function(_, _, _, anchor) stored_anchor = anchor; write(output .. "/anchor.json", anchor) end,
    },
    requestPage = function() hints = hints + 1 end,
    onReaderEvent = function(name) events[name] = (events[name] or 0) + 1 end,
}
Provider:setServicesResolver(function(account) assert(account == "test"); return services end)
Provider:register(Registry)

local function render()
    require("spec/reader/geometry_spec")(check)
    local authorize = services.authorizeDescriptor
    local original_get = services.pages.getPage
    local reads = 0
    services.pages.getPage = function(...) reads = reads + 1; return original_get(...) end
    services.authorizeDescriptor = function()
        return nil, { kind = "locked", message = "Synthetic expired entitlement", retryable = false }
    end
    local denied = pcall(Provider.new, Provider, { file = manifest_path, services = services })
    check("unauthorized descriptor is rejected before page reads", not denied and reads == 0)
    services.authorizeDescriptor = nil
    denied = pcall(Provider.new, Provider, { file = manifest_path, services = services })
    check("missing authorization service fails closed", not denied and reads == 0)
    services.authorizeDescriptor = authorize
    services.pages.getPage = original_get
    local document = assert(Registry:openDocument(manifest_path, Provider))
    check("provider page count", document:getPageCount() == #records)
    check("missing geometry is local", document:getNativePageDimensions(2).h == 1600 and hints == 0)
    local target = BB.new(600, 400)
    local loading_background, unavailable_background = 245, 235
    document:drawPage(target, 0, 0, Geom:new{ x = 0, y = 650, w = 600, h = 400 }, 1, 1, 0, 1, 1)
    check("native crop", math.abs(target:getPixel(300, 100):getR() - 100) <= 2)
    check("ready image is not decorated with placeholder content", solidPixels(target, 100, 2))
    check("native owners closed after rendering", next(document._document.active) == nil)
    services.authorizeDescriptor = function()
        return nil, { kind = "entitlement", message = "Synthetic permission expiry", retryable = false }
    end
    document:drawPage(target, 0, 0, Geom:new{ x = 0, y = 650, w = 600, h = 400 }, 1, 1, 0, 1, 1)
    check("permission expiry blocks even an existing rendered tile", target:getPixel(300, 100):getR() == unavailable_background
        and next(document._document.active) == nil)
    document:drawPageInverted(target, 0, 0, Geom:new{ x = 0, y = 650, w = 600, h = 400 }, 1, 1, 0, 1, 1)
    check("expired permission also blocks inverted cached pixels", target:getPixel(300, 100):getR() == 255 - unavailable_background
        and next(document._document.active) == nil)
    check("expired permission cannot expose a cover", document:getCoverPageImage() == nil)
    services.authorizeDescriptor = authorize
    local missing = Geom:new{ x = 70, y = 600, w = 600, h = 400 }
    document:drawPage(target, 0, 0, missing, 2, 1, 0, 1, 1)
    check("missing ordinary draw", target:getPixel(300, 100):getR() == loading_background)
    document:drawPageInverted(target, 0, 0, missing, 2, 1, 0, 1, 1)
    check("missing inverted draw", target:getPixel(300, 100):getR() == 255 - loading_background)
    local tiny, tiny_inverted = BB.new(8, 8), BB.new(8, 8)
    local tiny_region = Geom:new{ x = 70, y = 600, w = 8, h = 8 }
    local hints_before_tiny = hints
    document:drawPage(tiny, 0, 0, tiny_region, 2, 1, 0, 1, 1)
    check("tiny missing region is drawable without acquiring twice", tiny:getPixel(4, 7):getR() == loading_background
        and tiny:getPixel(4, 0):getR() < loading_background and hints == hints_before_tiny + 1
        and next(document._document.active) == nil)
    document:drawPageInverted(tiny_inverted, 0, 0, tiny_region, 2, 1, 0, 1, 1)
    check("tiny inverted region complements its entire edge and background", invertedPixels(tiny, tiny_inverted))
    tiny:free(); tiny_inverted:free()
    local sentinel = 37
    local clipped = BB.new(320, 200)
    clipped:fill(BB.Color8(sentinel))
    document:drawPage(clipped, 12, 10, tiny_region, 2, 1, 0, 1, 1)
    check("tiny positioned placeholder leaves neighboring pixels unchanged",
        clipped:getPixel(16, 17):getR() == loading_background and unchangedOutside(clipped, 12, 10, 20, 18, sentinel))
    clipped:fill(BB.Color8(sentinel))
    local clipped_region = Geom:new{ x = 0, y = 400, w = 240, h = 160 }
    document:drawPage(clipped, -80, -40, clipped_region, 2, 1, 0, 1, 1)
    check("negative offset clips background and text to the visible intersection",
        clipped:getPixel(159, 119):getR() == loading_background and unchangedOutside(clipped, 0, 0, 160, 120, sentinel))
    clipped:fill(BB.Color8(sentinel))
    document:drawPageInverted(clipped, -80, -40, clipped_region, 2, 1, 0, 1, 1)
    check("negative offset inverted placeholder preserves pixels outside its region",
        clipped:getPixel(159, 119):getR() == 255 - loading_background and unchangedOutside(clipped, 0, 0, 160, 120, sentinel))
    clipped:fill(BB.Color8(sentinel))
    document:drawPage(clipped, 10, -7, tiny_region, 2, 1, 0, 1, 1)
    check("one row intersection does not overrun its clipped height",
        clipped:getPixel(14, 0):getR() ~= sentinel and unchangedOutside(clipped, 10, 0, 18, 1, sentinel))
    clipped:fill(BB.Color8(sentinel))
    document:drawPage(clipped, -16, -16, tiny_region, 2, 1, 0, 1, 1)
    check("fully offscreen missing region leaves the destination unchanged", solidPixels(clipped, sentinel))
    clipped:free()
    check("missing full-page unavailable", document:renderPage(2, nil, 1, 0, 1, 1) == nil)
    local part = Geom:new{ x = 50, y = 100, w = 30, h = 50 }
    part.scaled_rect = Geom:new{ x = 100, y = 200, w = 60, h = 100 }
    local transient = document:renderPage(2, part, 2, 0, 1, 1)
    check("scaled missing region shape", transient.comic_transient and not transient.persistent
        and transient.bb:getWidth() == 60 and transient.excerpt.x == 100)
    transient:onFree()
    check("missing selection is unavailable", document:drawPagePart(2, part, 0) == nil)
    local before = document:getFullPageHash(2, 1, 0, 1, 1)
    records[2].path = output .. "/fixtures/page-2.png"
    records[2].state = "ready"; records[2].content_generation = 2
    document:drawPage(target, 0, 0, Geom:new{ x = 0, y = 0, w = 600, h = 400 }, 2, 1, 0, 1, 1)
    check("missing image completion", math.abs(target:getPixel(300, 100):getR() - 60) <= 2)
    check("completed image replaces every placeholder pixel", solidPixels(target, 60, 2))
    check("persistent generation participates in hash", before ~= document:getFullPageHash(2, 1, 0, 1, 1))
    for index = 3, 7 do
        local page = records[index]
        local region = Geom:new{ x = 0, y = 360, w = 180, h = 100 }
        document:drawPage(target, 0, 0, region, index, 0.5, 0, 1, 1)
        check("format DPI crop " .. page.id, math.abs(target:getPixel(90, 50):getR() - 160) <= 4,
            target:getPixel(90, 50):getR())
    end
    -- The four source quadrants are 40, 100, 160, 220 in reading order.
    local transforms = require("bilicomics/reader/geometry")
    for index = 8, 15 do
        local page = records[index]
        local bb = BB.new(page.width, page.height)
        document:drawPage(bb, 0, 0, Geom:new{ x = 0, y = 0, w = page.width, h = page.height }, index, 1, 0, 1, 1)
        for _, point in ipairs({ { 0.25, 0.25, 40 }, { 0.75, 0.25, 100 },
            { 0.25, 0.75, 160 }, { 0.75, 0.75, 220 } }) do
            local x, y = transforms.transformPoint(index - 7, point[1], point[2])
            local pixel = bb:getPixel(math.floor(x * page.width), math.floor(y * page.height)):getR()
            check("native EXIF " .. (index - 7) .. " pixel " .. point[3], math.abs(pixel - point[3]) <= 4, pixel)
        end
        bb:free()
    end
    for index = 18, 33 do
        local page = records[index]
        local orientation = page.geometry.exif_orientation
        local bb = BB.new(page.width, page.height)
        document:drawPage(bb, 0, 0, Geom:new{ x = 0, y = 0, w = page.width, h = page.height }, index, 1, 0, 1, 1)
        for _, point in ipairs({ { 0.25, 0.25, 40 }, { 0.75, 0.25, 100 },
            { 0.25, 0.75, 160 }, { 0.75, 0.75, 220 } }) do
            local x, y = transforms.transformPoint(orientation, point[1], point[2])
            local pixel = bb:getPixel(math.floor(x * page.width), math.floor(y * page.height)):getR()
            check(page.id .. " oriented pixel " .. point[3], math.abs(pixel - point[3]) <= 4, pixel)
        end
        bb:free()
    end
    document:drawPageInverted(target, 0, 0, Geom:new{ x = 0, y = 650, w = 600, h = 400 }, 1, 1, 0, 1, 1)
    check("ready inverted crop", math.abs(target:getPixel(300, 100):getR() - 155) <= 2)
    local fragment = document:drawPagePart(1, { x = 50, y = 650, w = 150, h = 100 }, 0)
    check("ready scaled fragment", fragment and math.abs(fragment:getPixel(100, 100):getR() - 100) <= 2)
    local ready = document:isPageReady(16)
    check("oversized lossless blocked before native decode", not ready and next(document._document.active) == nil)
    document:drawPage(target, 0, 0, Geom:new{ x = 0, y = 0, w = 600, h = 400 }, 16, 1, 0, 1, 1)
    check("oversized input gets explicit unavailable state", target:getPixel(100, 100):getR() == unavailable_background)
    document:drawPage(target, 0, 0, Geom:new{ x = 0, y = 0, w = 600, h = 400 }, 17, 1, 0, 1, 1)
    check("corrupt image guarded", target:getPixel(100, 100):getR() == unavailable_background and document._render_errors[17] ~= nil)
    check("corrupt image handles released", next(document._document.active) == nil)
    local cover = document:getCoverPageImage()
    check("ready cover is independently owned", cover and cover:getHeight() <= 800)
    if cover then cover:free() end
    local same = assert(Registry:openDocument(manifest_path, Provider))
    check("registry shared reference", same == document and document:close() == false and same.is_open)
    local standalone = Provider:new{ file = manifest_path, services = services }
    standalone:close()
    check("standalone close preserves registered document", Registry:getReferenceCount(manifest_path) == 1 and same.is_open)
    same:close()
    check("registry final reference released", Registry:getReferenceCount(manifest_path) == nil)
    target:free()
end

local function nativeUI()
    local UIManager = require("ui/uimanager")
    local ReaderUI = require("apps/reader/readerui")
    local Event = require("ui/event")
    ReaderUI:showReader(manifest_path, Provider)
    local reader, integration
    UIManager:scheduleIn(0.15, function()
        reader = assert(ReaderUI.instance)
        local protect = services.pages.setActiveEpisode
        services.pages.setActiveEpisode = function() error("Synthetic storage failure") end
        local attached, failure = Integration.attach(reader)
        check("failed attachment leaves no partial integration", attached == nil and failure.kind == "storage"
            and reader.bilicomics_integration == nil and active == 0)
        services.pages.setActiveEpisode = protect
        integration = Integration.attach(reader)
    end)
    local function close()
        reader:onClose()
        check("reader active protection released", active == 0)
        check("reader closed", ReaderUI.instance == nil and integration.closed)
        check("native document released", Registry:getReferenceCount(manifest_path) == nil)
        UIManager:quit()
    end
    UIManager:scheduleIn(0.4, function()
        check("native ReaderUI attachment", reader.document.provider == Provider.provider and active == 1)
        if mode == "ui-reopen" or mode == "page-reopen" or mode == "pan-reopen" then
            local expected = read(output .. "/expected.json")
            local actual = require("bilicomics/reader/anchors").capture(reader)
            check("normalized position survives process restart", actual.page_id == expected.page_id
                and math.abs(actual.y - expected.y) < 0.005 and math.abs(actual.x - expected.x) < 0.005,
                { expected = expected, actual = actual })
            close(); return
        elseif mode == "ui-online" then
            reader.zooming:onSetZoomMode("pagewidth")
            reader.view:onSetScrollMode(true)
            reader.paging:_gotoPage(2)
            reader.paging:onGotoViewRel(1)
            local before = reader.paging:getTopPosition()
            records[2].path = output .. "/fixtures/page-2.png"
            records[2].state = "ready"; records[2].content_generation = 2
            integration:notifyPageReady(records[2])
            check("arrival preserves continuous viewport", before > 0
                and math.abs(reader.paging:getTopPosition() - before) < 0.0001)
            records[2].height = 2400; records[2].geometry_generation = 2
            integration:notifyPageReady(records[2])
            check("geometry correction preserves normalized viewport", math.abs(reader.paging:getTopPosition() - before) < 0.005)
        elseif mode == "thumbnail" then
            local callback_result, callback_count = nil, 0
            local thumbnail = reader.thumbnail
            check("native thumbnail integration exists", thumbnail and thumbnail.thumbnails_requests ~= nil)
            local missing_callbacks, hints_before_thumbnail = 0, hints
            local cache_slots = thumbnail.tile_cache and thumbnail.tile_cache.cache.used_slots() or 0
            local missing_queued = thumbnail:getPageThumbnail(2, 100, 100, "missing", function(tile)
                missing_callbacks = missing_callbacks + 1
                check("missing thumbnail callback unavailable", tile == nil)
            end)
            check("missing thumbnail completes exactly once without queued work", missing_callbacks == 1
                and missing_queued == false and thumbnail.thumbnails_requests.missing == nil and hints == hints_before_thumbnail)
            check("missing thumbnail never enters the native cache",
                (thumbnail.tile_cache and thumbnail.tile_cache.cache.used_slots() or 0) == cache_slots)
            thumbnail:getPageThumbnail(1, 100, 100, "stale", function(tile)
                callback_result = tile; callback_count = callback_count + 1
            end)
            UIManager:unschedule(thumbnail._ensureTileGeneration_action)
            local request = table.remove(thumbnail.thumbnails_requests.stale, 1)
            thumbnail.thumbnails_requests.stale = nil
            check("native thumbnail child launched", thumbnail:startTileGeneration(request))
            records[1].content_generation = records[1].content_generation + 1
            local function collect()
                local running = thumbnail:checkTileGeneration(request)
                if running then UIManager:scheduleIn(0.1, collect); return end
                check("stale child never enters cache", thumbnail.tile_cache.cache.used_slots() == 0)
                check("stale callback never exposes pixels", callback_count == 1 and callback_result == nil)
                thumbnail:getPageThumbnail(1, 100, 100, "ready", function(tile)
                    check("ready child uses local snapshot", tile and tile.bb:getHeight() == 100)
                    thumbnail:getPageThumbnail(17, 100, 100, "corrupt", function(corrupt)
                        check("corrupt child never exposes a placeholder thumbnail", corrupt == nil)
                        check("corrupt child never enters thumbnail cache", thumbnail.tile_cache.cache.used_slots() == 1)
                        close()
                    end)
                end)
            end
            UIManager:scheduleIn(0.2, collect)
            return
        else
            reader.zooming:onSetZoomMode("pagewidth")
            reader.view:onSetScrollMode(mode ~= "page" and mode ~= "pan")
            reader.paging:_gotoPage(1)
            reader.paging:onGotoViewRel(1)
            if mode == "pan" then
                reader.zooming:onZoom("in")
                integration:saveAnchor()
                local initial_ratio = stored_anchor.zoom_ratio
                reader.zooming:onZoom("in")
                integration:saveAnchor()
                check("zoom-only change persists anchor", stored_anchor.zoom_ratio > initial_ratio)
                reader.view:PanningUpdate(160, 540)
                local before = require("bilicomics/reader/anchors").capture(reader)
                records[2].geometry_generation = records[2].geometry_generation + 1
                integration:notifyPageReady(records[2])
                local after = require("bilicomics/reader/anchors").capture(reader)
                check("adjacent geometry update preserves panned viewport",
                    math.abs(before.x - after.x) < 0.005 and math.abs(before.y - after.y) < 0.005)
            end
            local anchor = require("bilicomics/reader/anchors").capture(reader)
            check("native viewport advances in source image", anchor.index == 1 and anchor.y > 0)
            integration:saveAnchor()
            write(output .. "/expected.json", anchor)
            reader:handleEvent(Event:new("EndOfBook"))
            reader:handleEvent(Event:new("EndOfBook"))
        end
        UIManager:scheduleIn(0.1, function()
            if mode == "ui" or mode == "page" or mode == "pan" then
                check("chapter ending is one shot", events.end_of_book == 1)
            end
            close()
        end)
    end)
    UIManager:scheduleIn(15, function() error("Native reader test timeout") end)
    UIManager:run()
end

local ok, failure = xpcall(function()
    if mode == "render" then render() else nativeUI() end
end, debug.traceback)
report.success, report.failure = ok, not ok and failure or nil
write(output .. "/" .. mode .. "-results.json", report)
print(json.encode(report))
if not ok then os.exit(1) end
