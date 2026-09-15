local Document = require("document/document")
local DrawContext = require("ffi/drawcontext")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local TileCacheItem = require("document/tilecacheitem")
local lfs = require("libs/libkoreader-lfs")
local json = require("rapidjson")

local ComicDocument = Document:extend{
    provider = "bilicomics_document",
    provider_name = "Bilibili Comics",
    is_pic = true,
    is_pdf = false,
    is_djvu = false,
    is_reflowable = false,
    dc_null = DrawContext.new(),
}

local resolver
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

function ComicDocument.setServicesResolver(self, fn)
    -- Accept both Provider:setServicesResolver(fn) and Provider.setServicesResolver(fn).
    resolver = fn or self
    assert(type(resolver) == "function", "A services resolver is required")
end

function ComicDocument:register(registry)
    (registry or require("document/documentregistry")):addProvider(
        "bcomic", "application/x-bilicomics", self, 100)
end

local function readDescriptor(path)
    local file = assert(io.open(path, "rb"), "Cannot open comic descriptor")
    local data = file:read(4 * 1024 * 1024 + 1)
    file:close()
    assert(#data <= 4 * 1024 * 1024, "Comic descriptor is too large")
    local descriptor = assert(json.decode(data), "Invalid comic descriptor")
    assert(descriptor.schema_version == 1 and type(descriptor.pages) == "table"
        and #descriptor.pages > 0, "Unsupported comic descriptor")
    for _, key in ipairs({ "account_key", "comic_id", "episode_id", "revision" }) do
        assert(type(descriptor[key]) == "string" and descriptor[key] ~= "", "Invalid descriptor identity")
    end
    for index, page in ipairs(descriptor.pages) do
        assert(page.index == index and type(page.id) == "string"
            and type(page.width) == "number" and page.width > 0 and page.width < 1000000
            and type(page.height) == "number" and page.height > 0 and page.height < 1000000,
            "Invalid descriptor page geometry")
    end
    return descriptor
end

function ComicDocument:init()
    self.descriptor = readDescriptor(self.file)
    self.services = self.services or (resolver and resolver(self.descriptor.account_key))
    assert(self.services and self.services.pages and self.services.store,
        "The comic account is not available locally")
    assert(type(self.services.authorizeDescriptor) == "function",
        "The comic account has no local authorization service")
    local authorized, authorization_error = self.services.authorizeDescriptor(self.descriptor)
    assert(authorized == true, authorization_error and authorization_error.message or "The chapter is not authorized for reading")
    self.info.has_pages = true
    self.info.configurable = false
    self.info.number_of_pages = #self.descriptor.pages
    self.is_locked = false
    self.render_mode = 0
    self.mod_time = lfs.attributes(self.file, "modification") or 0
    self._known_geometry = {}
    self._render_errors = {}
    self._reported_errors = {}
    self._allow_hints = true
    self._reader_generation = 0
    for key, value in pairs({ text_wrap = 0, writing_direction = 0, trim_page = 0,
        page_margin = 0, background_cleanup = 0, page_scroll = 0, auto_straighten = 0 }) do
        self.configurable[key] = value
    end
    self:updateColorRendering()
    self._document = require("bilicomics/reader/image_backend").new(self)
    self.is_open = true
    for index = 1, #self.descriptor.pages do
        local page = self:getLocalPage(index)
        self._known_geometry[index] = { width = page.width, height = page.height,
            geometry_generation = page.geometry_generation or 0,
            geometry = copy(page.geometry or (page.extra and page.extra.geometry)) }
    end
end

function ComicDocument:getLocalPage(index)
    local spec = assert(self.descriptor.pages[index], "Invalid comic page number")
    local page
    if self._local_snapshot then
        page = self._local_snapshot[index]
    else
        page = self.services.pages:getPage(self.descriptor.episode_id, self.descriptor.revision, index)
    end
    if page then return page end
    return { key = self.descriptor.episode_id .. "/" .. self.descriptor.revision .. "/" .. index,
        id = spec.id, index = index, episode_id = self.descriptor.episode_id,
        revision = self.descriptor.revision, width = spec.width, height = spec.height,
        state = "missing", content_generation = 0, geometry_generation = 0 }
end

function ComicDocument:localSnapshot()
    local pages = {}
    for index = 1, self:getPageCount() do pages[index] = copy(self:getLocalPage(index)) end
    local episode = self.services.store:getEpisode(self.descriptor.episode_id)
    if episode and episode.access == "temporary" then pages.authorization_expires_at = episode.expires_at end
    return pages
end

function ComicDocument:enterThumbnailMode(snapshot)
    self._local_snapshot = assert(snapshot, "Thumbnail rendering requires a parent snapshot")
    self._allow_hints = false
    self._thumbnail_mode = true
    self._authorization_expires_at = snapshot.authorization_expires_at
    self.services = nil
end

function ComicDocument:checkAuthorization()
    if self._thumbnail_mode then
        if self._authorization_expires_at and self._authorization_expires_at <= os.time() then
            return nil, { kind = "entitlement", message = "The temporary reading permission has expired", retryable = false }
        end
        return true
    end
    if not self.services or type(self.services.authorizeDescriptor) ~= "function" then
        return nil, { kind = "entitlement", message = "The reading permission is unavailable", retryable = false }
    end
    local ok, allowed, err = pcall(self.services.authorizeDescriptor, self.descriptor)
    if not ok or allowed ~= true then
        return nil, err or { kind = "entitlement", message = "The chapter is not authorized for reading", retryable = false }
    end
    return true
end

function ComicDocument:getPageGeneration(index)
    local page = self:getLocalPage(index)
    return table.concat({ self.descriptor.revision, page.content_generation or 0,
        page.geometry_generation or 0, page.state or "missing" }, ":")
end

function ComicDocument:getNativePageDimensions(index)
    local page = self:getLocalPage(index)
    return Geom:new{ w = page.width, h = page.height }
end

function ComicDocument:getUsedBBox(index)
    local size = self:getNativePageDimensions(index)
    return { x0 = 0, y0 = 0, x1 = size.w, y1 = size.h }
end

function ComicDocument:getFullPageHash(index, ...)
    return Document.getFullPageHash(self, index, ...) .. "|comic=" .. self:getPageGeneration(index)
end

function ComicDocument:getPagePartHash(index, ...)
    return Document.getPagePartHash(self, index, ...) .. "|comic=" .. self:getPageGeneration(index)
end

function ComicDocument:getDocumentProps()
    if not self.services then return {} end
    local episode = self.services.store:getEpisode(self.descriptor.episode_id)
    local comic = self.services.store:getComic(self.descriptor.comic_id)
    return { title = episode and episode.title or self.descriptor.episode_id,
        series = comic and comic.title or nil,
        authors = comic and (type(comic.authors) == "table" and table.concat(comic.authors, ", ") or comic.authors) or nil }
end

function ComicDocument:getToc() return {} end
function ComicDocument:getTextBoxes() return nil end
function ComicDocument:getWordFromPosition() return nil end
function ComicDocument:getOCRText() return nil end
function ComicDocument:getPanelFromPage() return nil end
function ComicDocument:getPageBlock() return nil end
function ComicDocument:getPageBoxesFromPositions() return nil end
function ComicDocument:getSelectedWordContext() return nil, nil end
function ComicDocument:getPageText() return {} end
function ComicDocument:findText() return nil, 0 end

function ComicDocument:requestPage(index, prefetch)
    if not self._allow_hints or not self.is_open or not self.descriptor.pages[index] then return end
    if self.services.requestPage then
        local ok = pcall(self.services.requestPage, self.descriptor, index,
            { prefetch = prefetch == true, reader_generation = self._reader_generation })
        if not ok then require("logger").warn("Bilibili reader acquisition hint failed") end
    end
end

function ComicDocument:hintPage(index)
    -- Native hinting may run during layout. Only enqueue acquisition; never decode here.
    self:requestPage(index, true)
end

function ComicDocument:isPageReady(index)
    local authorized, authorization_error = self:checkAuthorization()
    if not authorized then return false, authorization_error end
    local page = self:getLocalPage(index)
    if page.state ~= "ready" or not page.path or lfs.attributes(page.path, "mode") ~= "file" then
        return false, { kind = page.state == "failed" and "page_failed" or "page_missing",
            message = "The image is not available locally", retryable = true }
    end
    local generation = self:getPageGeneration(index)
    local failure = self._render_errors[index]
    if failure and failure.generation == generation then return false, failure.error end
    return self._document:canOpen(page)
end

function ComicDocument:_placeholder(target, x, y, rect, index, inverted)
    local _, failure = self:isPageReady(index)
    local unavailable = failure and failure.kind ~= "page_missing"
    local gray = unavailable and 235 or 245
    if inverted then gray = 255 - gray end
    local left, top = math.max(0, math.floor(x)), math.max(0, math.floor(y))
    local right = math.min(target:getWidth(), math.ceil(x + rect.w))
    local bottom = math.min(target:getHeight(), math.ceil(y + rect.h))
    local width, height = right - left, bottom - top
    if width > 0 and height > 0 then
        target:paintRect(left, top, width, height, Blitbuffer.Color8(gray))
        target:paintRect(left, top, width, math.min(3, height), Blitbuffer.Color8(inverted and 175 or 80))
        -- A bounded temporary buffer keeps glyph painting inside even cropped native tiles.
        -- Unavailable thumbnails still return nil through the dedicated thumbnail paths.
        if not self._thumbnail_mode and width >= 160 and height >= 64 then
            local heading, detail, notice
            pcall(function()
                local Font = require("ui/font")
                local TextWidget = require("ui/widget/textwidget")
                local W = require("bilicomics/ui/widgets")
                local _ = require("bilicomics/ui/i18n")
                local text_width = math.min(width - 24, 540)
                local ink = inverted and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
                heading = TextWidget:new{
                    text = string.format(unavailable and _("Image unavailable · %d / %d") or _("Loading image · %d / %d"),
                        index, #self.descriptor.pages),
                    face = Font:getFace("cfont", W.font and W.font.body or 18),
                    bold = true, fgcolor = ink, padding = 0, max_width = text_width,
                }
                detail = TextWidget:new{
                    text = unavailable and _("Open comic actions for recovery.") or _("Waiting for the image to load."),
                    face = Font:getFace("cfont", W.font and W.font.meta or 14),
                    fgcolor = ink, padding = 0, max_width = text_width,
                }
                local heading_size, detail_size = heading:getSize(), detail:getSize()
                local show_detail = heading_size.h + detail_size.h + 16 <= height
                local notice_height = heading_size.h + (show_detail and detail_size.h + 8 or 0)
                if notice_height > height - 8 then return end
                notice = Blitbuffer.new(text_width, notice_height, target:getType())
                notice:fill(Blitbuffer.Color8(gray))
                heading:paintTo(notice, math.floor((text_width - heading_size.w) / 2), 0)
                if show_detail then detail:paintTo(notice, math.floor((text_width - detail_size.w) / 2), heading_size.h + 8) end
                target:blitFrom(notice, left + math.floor((width - text_width) / 2),
                    top + math.floor((height - notice_height) / 2), 0, 0, text_width, notice_height)
            end)
            if notice then notice:free() end
            if heading then heading:free() end
            if detail then detail:free() end
        end
    end
    if not failure or failure.retryable then self:requestPage(index, false) end
    if failure and failure.kind ~= "page_missing" and self.services and self.services.onReaderEvent then
        local signature = self:getPageGeneration(index) .. ":" .. failure.kind
        if self._reported_errors[index] ~= signature then
            self._reported_errors[index] = signature
            pcall(self.services.onReaderEvent, "page_error", { descriptor = self.descriptor, index = index, error = failure })
        end
    end
end

function ComicDocument:renderPage(index, rect, zoom, rotation, gamma, saturation, hinting)
    local full_size = self:getPageDimensions(index, zoom, rotation)
    local bytes_per_pixel = self.render_color and 4 or 1
    local limit = self._document.policy.max_tile_bytes
    local requested = rect and (rect.scaled_rect or rect)
    if requested and requested.w * requested.h * bytes_per_pixel > limit then
        error("The requested image region exceeds the render buffer limit")
    end
    if full_size.w * full_size.h * bytes_per_pixel > limit and not (rect and rect.scaled_rect) then
        if not rect then return nil end
        rect = rect:copy()
        rect.scaled_rect = rect:copy()
    end
    if not self:isPageReady(index) then
        -- Full-page/cover callers receive an unavailable result, never a successful cached placeholder.
        if not rect then return nil end
        local size = rect.scaled_rect or rect
        local max_bytes = self._document.policy.max_tile_bytes
        if size.w * size.h * (self.render_color and 4 or 1) > max_bytes then return nil end
        local tile = TileCacheItem:new{ bb = Blitbuffer.new(size.w, size.h,
            self.render_color and self.color_bb_type or nil), excerpt = size,
            pageno = index, persistent = false, comic_transient = true }
        self:_placeholder(tile.bb, 0, 0, size, index)
        tile.size = tonumber(tile.bb.stride) * tile.bb.h
        return tile
    end
    -- Inherited rendering owns completed tiles. The backend closes native handles even after draw errors.
    local ok, tile = pcall(Document.renderPage, self, index, rect, zoom, rotation, gamma, saturation, hinting)
    if not ok then
        if hinting then require("document/canvascontext"):enableCPUCores(1) end
        error(tile)
    end
    return tile
end

function ComicDocument:_draw(target, x, y, rect, index, inverted, ...)
    if not self:isPageReady(index) then return self:_placeholder(target, x, y, rect, index, inverted) end
    local args = { ... }
    local method = inverted and Document.drawPageInverted or Document.drawPage
    local ok, failure = pcall(method, self, target, x, y, rect, index, unpack(args))
    if not ok then
        self._render_errors[index] = { generation = self:getPageGeneration(index),
            error = { kind = "image_decode", message = "The local image could not be rendered", retryable = false } }
        self:_placeholder(target, x, y, rect, index, inverted)
    end
end

function ComicDocument:drawPage(target, x, y, rect, index, ...)
    return self:_draw(target, x, y, rect, index, false, ...)
end

function ComicDocument:drawPageInverted(target, x, y, rect, index, ...)
    return self:_draw(target, x, y, rect, index, true, ...)
end

function ComicDocument:drawPagePart(index, native_rect, rotation)
    if not self:isPageReady(index) then return nil, false end
    return Document.drawPagePart(self, index, native_rect, rotation)
end

function ComicDocument:getCoverPageImage()
    if not self:isPageReady(1) then return nil end
    local size = self:getNativePageDimensions(1)
    local zoom = math.min(600 / size.w, 800 / size.h, 1)
    local ok, tile = pcall(self.renderPage, self, 1, nil, zoom, 0, 1, 1)
    if ok and tile then return tile.bb:copy() end
    return nil
end

function ComicDocument:close()
    if not self.is_open then return nil end
    local registry = require("document/documentregistry")
    local registered = registry.registry[self.file]
    if registered and registered.doc == self then return Document.close(self) end
    self.is_open = false
    self._document:close()
    self._document = nil
    return true
end

return ComicDocument
