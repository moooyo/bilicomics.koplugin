-- Pure geometry for a logical comic page backed by a native image page.
-- Coordinates describe continuous pixel boundaries, not integer pixel indices.
-- Native orientation must be supplied explicitly; dimensions cannot prove it.
local Geometry = {}
Geometry.__index = Geometry

Geometry.DEFAULT_MAX_INTERMEDIATE_PIXELS = 4 * 1024 * 1024
Geometry.BOUNDARY_EPSILON = 1e-7

local inverse = { 1, 2, 3, 4, 5, 8, 7, 6 }
local rotation_orientation = { [0] = 1, [90] = 6, [180] = 3, [270] = 8 }

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function positive(value)
    return finite(value) and value > 0
end

local function valid_orientation(value)
    return type(value) == "number" and value >= 1 and value <= 8
        and value == math.floor(value)
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function snap_boundary(value)
    local nearest = math.floor(value + 0.5)
    if math.abs(value - nearest) <= Geometry.BOUNDARY_EPSILON then
        return nearest
    end
    return value
end

local function transform(orientation, u, v)
    if orientation == 1 then return u, v end
    if orientation == 2 then return 1 - u, v end
    if orientation == 3 then return 1 - u, 1 - v end
    if orientation == 4 then return u, 1 - v end
    if orientation == 5 then return v, u end
    if orientation == 6 then return 1 - v, u end
    if orientation == 7 then return 1 - v, 1 - u end
    return v, 1 - u
end

-- Apply EXIF orientation to normalized source coordinates. Values outside
-- [0, 1] remain valid so a viewport may include the page's white margins.
function Geometry.transformPoint(orientation, u, v)
    assert(valid_orientation(orientation), "invalid_orientation")
    assert(finite(u) and finite(v), "invalid_point")
    return transform(orientation, u, v)
end

function Geometry.inverseOrientation(orientation)
    assert(valid_orientation(orientation), "invalid_orientation")
    return inverse[orientation]
end

function Geometry.orientedDimensions(width, height, orientation)
    assert(positive(width) and positive(height), "invalid_dimensions")
    assert(valid_orientation(orientation), "invalid_orientation")
    if orientation >= 5 then return height, width end
    return width, height
end

-- Composition order is explicit: apply 'before', then apply 'after'.
function Geometry.composeOrientations(after, before)
    assert(valid_orientation(after) and valid_orientation(before), "invalid_orientation")
    local points = { { 0, 0 }, { 1, 0 }, { 0, 1 } }
    for candidate = 1, 8 do
        local matches = true
        for _, point in ipairs(points) do
            local u, v = transform(before, point[1], point[2])
            u, v = transform(after, u, v)
            local x, y = transform(candidate, point[1], point[2])
            if u ~= x or v ~= y then
                matches = false
                break
            end
        end
        if matches then return candidate end
    end
    error("invalid_orientation_composition")
end

function Geometry.relativeOrientation(desired, native)
    assert(valid_orientation(desired) and valid_orientation(native), "invalid_orientation")
    return Geometry.composeOrientations(desired, inverse[native])
end

-- page.width/height are stable, already-oriented logical dimensions.
-- Optional page.geometry (or page.extra.geometry) describes the raw raster:
-- { source_width, source_height, exif_orientation = <EXIF 1..8>,
--   native_orientation = <EXIF already applied by native> }.
-- 'orientation' is accepted as an alias for 'exif_orientation'.
-- Constructors and render planning return nil, error_code on invalid input.
function Geometry.new(page)
    if type(page) ~= "table" or not positive(page.width) or not positive(page.height) then
        return nil, "invalid_logical_dimensions"
    end
    if page.extra ~= nil and type(page.extra) ~= "table" then
        return nil, "invalid_geometry_metadata"
    end
    local metadata = page.geometry
    if metadata == nil then metadata = page.extra and page.extra.geometry or {} end
    if type(metadata) ~= "table" then return nil, "invalid_geometry_metadata" end
    local orientation = metadata.exif_orientation
    if orientation == nil then orientation = metadata.orientation end
    if orientation == nil then orientation = 1 end
    if not valid_orientation(orientation) then return nil, "invalid_source_orientation" end
    if metadata.native_orientation ~= nil and not valid_orientation(metadata.native_orientation) then
        return nil, "invalid_native_orientation"
    end
    local source_width, source_height = metadata.source_width, metadata.source_height
    if source_width ~= nil or source_height ~= nil then
        if not positive(source_width) or not positive(source_height) then
            return nil, "invalid_source_dimensions"
        end
    end
    local object = setmetatable({
        width = page.width,
        height = page.height,
        orientation = orientation,
        native_orientation = metadata.native_orientation,
        source_width = source_width,
        source_height = source_height,
    }, Geometry)
    if source_width then
        object.oriented_source_width, object.oriented_source_height =
            Geometry.orientedDimensions(source_width, source_height, orientation)
    end
    return object
end

-- Anchors use normalized, un-oriented source coordinates and survive a
-- different logical resolution or a change in the declared orientation.
function Geometry:toSourceAnchor(x, y)
    assert(finite(x) and finite(y), "invalid_point")
    local u, v = transform(inverse[self.orientation],
        clamp(x / self.width, 0, 1), clamp(y / self.height, 0, 1))
    return { x = u, y = v }
end

function Geometry:fromSourceAnchor(anchor)
    assert(type(anchor) == "table" and finite(anchor.x) and finite(anchor.y), "invalid_anchor")
    local u, v = transform(self.orientation,
        clamp(anchor.x, 0, 1), clamp(anchor.y, 0, 1))
    return u * self.width, v * self.height
end

-- native = { width, height, orientation = <EXIF already applied by native> }.
-- request = { x, y, w, h, zoom = 1, rotation = 0,
--             max_intermediate_pixels = 4194304 }.
-- The requested rectangle is in the scaled, reader-rotated logical page.
-- Native drawing must use intermediate.zoom, rotation 0 and context offset 0,
-- then render the intermediate pixel bbox. Gamma/saturation remain unchanged.
-- 'sample' maps output-local continuous coordinates into that native buffer:
-- source_x = xx * output_x + xy * output_y + x0
-- source_y = yx * output_x + yy * output_y + y0
-- Evaluate at output pixel centers, then floor to obtain nearest pixel indices.
-- This handles all eight EXIF transforms without assuming BB mirror support.
function Geometry:plan(native, request)
    if type(native) ~= "table" or not positive(native.width) or not positive(native.height) then
        return nil, "invalid_native_dimensions"
    end
    local native_orientation = self.native_orientation or native.orientation
    if native_orientation == nil then return nil, "native_orientation_unknown" end
    if not valid_orientation(native_orientation) then return nil, "invalid_native_orientation" end
    if type(request) ~= "table" or not finite(request.x or 0) or not finite(request.y or 0)
        or not positive(request.w) or not positive(request.h)
        or request.w ~= math.floor(request.w) or request.h ~= math.floor(request.h) then
        return nil, "invalid_render_rect"
    end
    local zoom = request.zoom or 1
    if not positive(zoom) then return nil, "invalid_zoom" end
    local rotation = request.rotation or 0
    if not finite(rotation) or rotation % 90 ~= 0 then return nil, "invalid_rotation" end
    rotation = rotation % 360
    local limit = request.max_intermediate_pixels or Geometry.DEFAULT_MAX_INTERMEDIATE_PIXELS
    if not positive(limit) then return nil, "invalid_intermediate_limit" end

    local reader_orientation = rotation_orientation[rotation]
    local display_width, display_height =
        Geometry.orientedDimensions(self.width, self.height, reader_orientation)
    display_width, display_height = display_width * zoom, display_height * zoom
    if not positive(display_width) or not positive(display_height) then
        return nil, "invalid_display_dimensions"
    end
    local desired = Geometry.composeOrientations(reader_orientation, self.orientation)
    local residual = Geometry.relativeOrientation(desired, native_orientation)
    local scale_x, scale_y
    if residual >= 5 then
        scale_x, scale_y = display_height / native.width, display_width / native.height
    else
        scale_x, scale_y = display_width / native.width, display_height / native.height
    end
    local uniform_zoom = math.max(scale_x, scale_y)
    if not positive(uniform_zoom) then return nil, "invalid_native_scale" end
    local rect_x, rect_y = request.x or 0, request.y or 0

    local function native_point(x, y)
        local u, v = transform(inverse[residual], x / display_width, y / display_height)
        return u * native.width * uniform_zoom, v * native.height * uniform_zoom
    end
    local x1, y1 = native_point(rect_x, rect_y)
    local x2, y2 = native_point(rect_x + request.w, rect_y + request.h)
    if not finite(x1) or not finite(y1) or not finite(x2) or not finite(y2) then
        return nil, "invalid_intermediate_bounds"
    end
    local left = math.floor(snap_boundary(math.min(x1, x2)))
    local top = math.floor(snap_boundary(math.min(y1, y2)))
    local right = math.ceil(snap_boundary(math.max(x1, x2)))
    local bottom = math.ceil(snap_boundary(math.max(y1, y2)))
    local width, height = right - left, bottom - top
    if width < 1 or height < 1 then return nil, "empty_intermediate" end
    local uniform = math.abs(scale_x - scale_y) <= 1e-9 * math.max(scale_x, scale_y)
    local direct = residual == 1 and uniform
        and snap_boundary(rect_x) == math.floor(snap_boundary(rect_x))
        and snap_boundary(rect_y) == math.floor(snap_boundary(rect_y))
        and left == snap_boundary(rect_x) and top == snap_boundary(rect_y)
        and width == request.w and height == request.h
    -- A direct draw uses the already allocated target, so the cap only limits
    -- additional intermediate buffers needed by orientation or anisotropy.
    if not direct and width * height > limit then return nil, "intermediate_too_large" end

    local origin_x, origin_y = native_point(rect_x, rect_y)
    -- Derive the signed basis independently of the viewport origin. Taking
    -- differences of large page coordinates would lose subpixel precision.
    local base_u, base_v = transform(inverse[residual], 0, 0)
    local x_u, x_v = transform(inverse[residual], 1, 0)
    local y_u, y_v = transform(inverse[residual], 0, 1)
    return {
        direct = direct,
        residual_orientation = residual,
        scale_x = scale_x,
        scale_y = scale_y,
        display = { w = display_width, h = display_height },
        output = { x = rect_x, y = rect_y, w = request.w, h = request.h },
        intermediate = { x = left, y = top, w = width, h = height, zoom = uniform_zoom },
        intermediate_pixels = width * height,
        sample = {
            xx = (x_u - base_u) * native.width * uniform_zoom / display_width,
            xy = (y_u - base_u) * native.width * uniform_zoom / display_height,
            x0 = origin_x - left,
            yx = (x_v - base_v) * native.height * uniform_zoom / display_width,
            yy = (y_v - base_v) * native.height * uniform_zoom / display_height,
            y0 = origin_y - top,
        },
    }
end

-- Convenience for fallback nearest-neighbor sampling. The input is an
-- integer pixel index in the output. Clamping absorbs boundary round-off.
function Geometry.sample(plan, x, y)
    local matrix = plan.sample
    x, y = x + 0.5, y + 0.5
    local source_x = math.floor(snap_boundary(matrix.xx * x + matrix.xy * y + matrix.x0))
    local source_y = math.floor(snap_boundary(matrix.yx * x + matrix.yy * y + matrix.y0))
    return clamp(source_x, 0, plan.intermediate.w - 1),
        clamp(source_y, 0, plan.intermediate.h - 1)
end

return Geometry
