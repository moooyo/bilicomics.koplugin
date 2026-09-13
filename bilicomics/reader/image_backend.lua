local Blitbuffer = require("ffi/blitbuffer")
local DrawContext = require("ffi/drawcontext")
local Geometry = require("bilicomics/reader/geometry")
local mupdf = require("ffi/mupdf")

local Backend = {}
Backend.__index = Backend

local function problem(kind, message)
    return nil, { kind = kind, message = message, retryable = false }
end

function Backend.new(owner)
    local settings = owner.services.settings or {}
    return setmetatable({ owner = owner, active = {}, policy = {
        -- Conservative safeguards, not device-specific performance claims.
        max_lossless_pixels = tonumber(settings.max_lossless_pixels) or 4000000,
        max_jpeg_pixels = tonumber(settings.max_jpeg_pixels) or 32000000,
        max_tile_bytes = tonumber(settings.max_tile_bytes) or 16 * 1024 * 1024,
        max_intermediate_pixels = tonumber(settings.max_intermediate_pixels) or 2000000,
    } }, Backend)
end

function Backend:canOpen(page)
    local format = (page.format or ""):lower():gsub("^image/", "")
    if format == "jpeg" then format = "jpg" end
    if format ~= "jpg" and format ~= "png" and format ~= "webp" then
        return problem("unsupported_image_format", "Only verified JPEG, PNG and WebP images are supported")
    end
    local geometry = page.geometry or (page.extra and page.extra.geometry) or {}
    local width = geometry.source_width or page.width
    local height = geometry.source_height or page.height
    if type(width) ~= "number" or type(height) ~= "number" or width <= 0 or height <= 0 then
        return problem("invalid_geometry", "The image has no validated source dimensions")
    end
    local limit = format == "jpg" and self.policy.max_jpeg_pixels or self.policy.max_lossless_pixels
    if width * height > limit then
        return problem("unsupported_image_size", "This image exceeds the configured decode limit; a smaller or segmented source is required")
    end
    return true
end

function Backend:openPage(index)
    local authorized, authorization_error = self.owner:checkAuthorization()
    assert(authorized, authorization_error and authorization_error.message)
    local spec = self.owner:getLocalPage(index)
    local permitted, failure = self:canOpen(spec)
    assert(permitted, failure and failure.message)
    assert(spec.state == "ready" and spec.path, "A missing image reached the native backend")
    -- Acquisition prefetch never decodes; only the current synchronous render may own a native image.
    assert(next(self.active) == nil, "Only one source image may be decoded at a time")
    local previous_color = mupdf.color
    mupdf.color = self.owner.render_color
    local ok, engine = pcall(mupdf.openDocument, spec.path)
    mupdf.color = previous_color
    if not ok then error("Cannot open the local image") end
    local opened, native = pcall(engine.openPage, engine, 1)
    if not opened then engine:close(); error("Cannot open the local image page") end
    local page = { engine = engine, native = native, owner = self, spec = spec, closed = false }
    self.active[page] = true
    function page:close()
        if self.closed then return end
        self.closed = true
        self.owner.active[self] = nil
        pcall(self.native.close, self.native)
        pcall(self.engine.close, self.engine)
    end
    function page:getSize(dc)
        local width, height = self.spec.width, self.spec.height
        if dc:getRotate() == 90 or dc:getRotate() == 270 then width, height = height, width end
        return width * dc:getZoom(), height * dc:getZoom()
    end
    function page:draw(dc, target, x, y)
        local intermediate
        local success, draw_error = pcall(function()
            local native_w, native_h = self.native:getSize(DrawContext.new())
            local metadata = self.spec.geometry or (self.spec.extra and self.spec.extra.geometry) or {}
            local geometry = assert(Geometry.new(self.spec))
            -- MuPDF's JPEG image document applies the embedded EXIF orientation.
            -- Preserve an explicit measured override for other native implementations.
            local format = (self.spec.format or ""):lower():gsub("^image/", "")
            local native_orientation = metadata.native_orientation
            if not native_orientation then
                native_orientation = (format == "jpg" or format == "jpeg")
                    and (metadata.exif_orientation or metadata.orientation or 1) or 1
            end
            local plan, mapping_error = geometry:plan({ width = native_w, height = native_h,
                orientation = native_orientation }, {
                x = x or 0, y = y or 0, w = target:getWidth(), h = target:getHeight(),
                zoom = dc:getZoom(), rotation = dc:getRotate(),
                max_intermediate_pixels = self.owner.policy.max_intermediate_pixels,
            })
            assert(plan, mapping_error and mapping_error.message or "Unsupported image geometry")
            local source = plan.intermediate
            local mapped_dc = DrawContext.new(0, source.zoom, 0, 0,
                dc:getGamma(), dc:getBackgroundCleanup(), dc:getSaturation())
            if plan.direct then
                self.native:draw(mapped_dc, target, source.x, source.y)
                return
            end
            intermediate = Blitbuffer.new(source.w, source.h, target:getType())
            self.native:draw(mapped_dc, intermediate, source.x, source.y)
            local sample = plan.sample
            -- The uncommon anisotropic/EXIF path uses bounded nearest-neighbor sampling.
            -- Equal-axis unrotated images stay in the native fast path.
            for row = 0, target:getHeight() - 1 do
                for column = 0, target:getWidth() - 1 do
                    local sx = sample.xx * (column + 0.5) + sample.xy * (row + 0.5) + sample.x0
                    local sy = sample.yx * (column + 0.5) + sample.yy * (row + 0.5) + sample.y0
                    sx = math.max(0, math.min(source.w - 1, math.floor(sx)))
                    sy = math.max(0, math.min(source.h - 1, math.floor(sy)))
                    target:setPixel(column, row, intermediate:getPixel(sx, sy))
                end
            end
        end)
        if intermediate then intermediate:free() end
        self:close()
        if not success then
            -- Inherited Document.renderPage cannot release its uncommitted tile after draw errors.
            target:free()
            error(draw_error)
        end
    end
    return page
end

function Backend:close()
    local pages = {}
    for page in pairs(self.active) do pages[#pages + 1] = page end
    for _, page in ipairs(pages) do page:close() end
end

return Backend
