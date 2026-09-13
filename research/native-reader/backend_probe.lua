-- Run only in the authorized remote KOReader runtime directory.
require("setupkoenv")
local ffi = require("ffi")
local json = require("json")
local mupdf = require("ffi/mupdf")
local DrawContext = require("ffi/drawcontext")
local BB = require("ffi/blitbuffer")

local function memory()
    local file = assert(io.open("/proc/self/status", "r"))
    local status = file:read("*a")
    file:close()
    return {
        rss_kib = tonumber(status:match("VmRSS:%s+(%d+)")),
        peak_rss_kib = tonumber(status:match("VmHWM:%s+(%d+)")),
    }
end

local path = assert(arg[1], "image or archive path required")
local target_width = tonumber(arg[2]) or 180
local target_height = tonumber(arg[3]) or 120
local y_fraction = tonumber(arg[4]) or 0.5
local mode = arg[5] or "draw"
local result = {path = path, mode = mode, before = memory()}
local ok, err = xpcall(function()
    local doc = mupdf.openDocument(path)
    doc:setColorRendering(true)
    result.pages = doc:getPages()
    result.after_open = memory()
    result.page_results = {}
    for index = 1, result.pages do
        local page = doc:openPage(index)
        local dc = DrawContext.new()
        local width, height = page:getSize(dc)
        local zoom = target_width / width
        dc:setZoom(zoom)
        local offset_y = math.floor(height * zoom * y_fraction)
        local render_width = target_width
        local render_height = math.min(target_height, math.floor(height * zoom) - offset_y)
        local page_result = {
            index = index, native_width = width, native_height = height,
            zoom = zoom, offset_y = offset_y, render_width = render_width,
            render_height = render_height, before_draw = memory(),
        }
        local start = os.clock()
        local bb
        if mode == "draw_new" then
            bb = page:draw_new(dc, render_width, render_height, 0, offset_y)
        else
            bb = BB.new(render_width, render_height, BB.TYPE_BBRGB32)
            page:draw(dc, bb, 0, offset_y)
        end
        page_result.cpu_seconds = os.clock() - start
        page_result.after_draw = memory()
        page_result.samples = {}
        for _, pos in ipairs({
            {math.floor(render_width / 4), math.floor(render_height / 4)},
            {math.floor(render_width * 3 / 4), math.floor(render_height / 4)},
            {math.floor(render_width / 4), math.floor(render_height * 3 / 4)},
            {math.floor(render_width * 3 / 4), math.floor(render_height * 3 / 4)},
        }) do
            local pixel = bb:getPixel(pos[1], pos[2])
            table.insert(page_result.samples, {
                x = pos[1], y = pos[2], rgb = {pixel:getR(), pixel:getG(), pixel:getB()},
            })
        end
        bb:free()
        page:close()
        table.insert(result.page_results, page_result)
    end
    doc:close()
    result.after_close = memory()
end, debug.traceback)
result.ok = ok
if not ok then result.error = err end
print("BACKEND_PROBE_JSON=" .. json.encode(result))
if not ok then os.exit(1) end
