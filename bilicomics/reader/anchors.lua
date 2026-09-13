local Anchors = {}
local Geometry = require("bilicomics/reader/geometry")

local function clamp(value)
    return math.max(0, math.min(1, value))
end

function Anchors.capture(reader, dimensions)
    local document, view = reader.document, reader.view
    if not document or not view or not reader.paging then return nil end
    local state = view.page_scroll and view.page_states and view.page_states[1] or view.state
    if not state or not state.page then return nil end
    local area = view.page_scroll and state.visible_area or view.visible_area
    local page = document:getLocalPage(state.page)
    local width = dimensions and dimensions.width or page.width
    local height = dimensions and dimensions.height or page.height
    if not area or not state.zoom or state.zoom <= 0 then return nil end
    local x = area.x / state.zoom
    local y = area.y / state.zoom
    local rotation = (state.rotation or 0) % 360
    if rotation == 90 then x, y = y, height - x
    elseif rotation == 180 then x, y = width - x, height - y
    elseif rotation == 270 then x, y = width - y, x end
    local source_page = { width = width, height = height,
        geometry = dimensions and dimensions.geometry or page.geometry, extra = page.extra }
    local geometry = Geometry.new(source_page)
    local source_anchor = geometry and geometry:toSourceAnchor(x, y)
    return { schema_version = 1, page_id = page.id, index = state.page, source = source_anchor,
        x = clamp(x / width), y = clamp(y / height), rotation = rotation,
        zoom_mode = reader.zooming and reader.zooming.zoom_mode,
        zoom_ratio = view.dimen and state.zoom * width / view.dimen.w,
        mode = view.page_scroll and "continuous" or "page",
        geometry_generation = dimensions and dimensions.geometry_generation or page.geometry_generation or 0 }
end

function Anchors.restore(reader, anchor)
    if type(anchor) ~= "table" or anchor.schema_version ~= 1 then return false end
    local document, view, paging = reader.document, reader.view, reader.paging
    local index
    for number, page in ipairs(document.descriptor.pages) do
        if page.id == anchor.page_id then index = number; break end
    end
    if not index then return false end
    if type(anchor.x) ~= "number" or type(anchor.y) ~= "number"
        or anchor.x ~= anchor.x or anchor.y ~= anchor.y then return false end
    local page = document:getLocalPage(index)
    if anchor.zoom_mode == "free" and type(anchor.zoom_ratio) == "number"
        and anchor.zoom_ratio > 0 and anchor.zoom_ratio <= 64 then
        reader.zooming.zoom = anchor.zoom_ratio * view.dimen.w / page.width
        reader.zooming:onSetZoomMode("free")
        view:onZoomUpdate(reader.zooming.zoom)
    end
    local x, y = clamp(anchor.x) * page.width, clamp(anchor.y) * page.height
    if anchor.source then
        local geometry = Geometry.new(page)
        if geometry then x, y = geometry:fromSourceAnchor(anchor.source) end
    end
    local rotation = (view.state.rotation or 0) % 360
    if rotation == 90 then x, y = page.height - y, x
    elseif rotation == 180 then x, y = page.width - x, page.height - y
    elseif rotation == 270 then x, y = y, page.width - x end
    local Event = require("ui/event")
    if view.page_scroll then
        local size = document:getPageDimensions(index, 1, rotation)
        paging:setPagePosition(index, y / size.h)
        reader:handleEvent(Event:new("PageUpdate", index))
        -- Continuous mode's horizontal offsets are normally zero. Preserve source x when panned.
        local first = view.page_states and view.page_states[1]
        if first and first.page == index then
            first.visible_area:offsetWithin(first.page_area,
                x * first.zoom - first.visible_area.x, 0)
        end
    else
        paging:setPagePosition(index, 0)
        reader:handleEvent(Event:new("PageUpdate", index))
        view:PanningUpdate(x * view.state.zoom - view.visible_area.x,
            y * view.state.zoom - view.visible_area.y)
    end
    require("ui/uimanager"):setDirty(reader.dialog, "partial")
    return true
end

return Anchors
