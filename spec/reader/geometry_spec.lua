local Geometry = require("bilicomics/reader/geometry")

return function(check)
    local count = 0
    local function verify(name, condition)
        count = count + 1
        if check then check(name, condition) else assert(condition, name) end
    end
    local function close(a, b)
        return math.abs(a - b) < 1e-6
    end

    local expected = {
        { 0.2, 0.3 }, { 0.8, 0.3 }, { 0.8, 0.7 }, { 0.2, 0.7 },
        { 0.3, 0.2 }, { 0.7, 0.2 }, { 0.7, 0.8 }, { 0.3, 0.8 },
    }
    for orientation = 1, 8 do
        local x, y = Geometry.transformPoint(orientation, 0.2, 0.3)
        verify("exif_forward_" .. orientation, close(x, expected[orientation][1]) and close(y, expected[orientation][2]))
        x, y = Geometry.transformPoint(Geometry.inverseOrientation(orientation), x, y)
        verify("exif_inverse_" .. orientation, close(x, 0.2) and close(y, 0.3))
        local w, h = Geometry.orientedDimensions(400, 900, orientation)
        verify("exif_dimensions_" .. orientation,
            w == (orientation >= 5 and 900 or 400) and h == (orientation >= 5 and 400 or 900))
        verify("already_oriented_" .. orientation, Geometry.relativeOrientation(orientation, orientation) == 1)
    end

    local page = assert(Geometry.new({ width = 360, height = 1200 }))
    local plan = assert(page:plan({ width = 86.4, height = 288, orientation = 1 },
        { x = 0, y = 650, w = 360, h = 200 }))
    verify("dpi_normalization_uses_native_units", close(plan.intermediate.zoom, 300 / 72))
    verify("dpi_crop_stays_in_display_pixels", plan.direct and plan.intermediate.y == 650
        and plan.intermediate.w == 360 and plan.intermediate.h == 200)
    local sx, sy = Geometry.sample(plan, 100, 50)
    verify("dpi_sample_keeps_crop_origin", sx == 100 and sy == 50)

    plan = assert(page:plan({ width = 180, height = 1200, orientation = 1 },
        { x = 30, y = 650, w = 120, h = 200 }))
    verify("anisotropic_plan_uses_largest_scale", not plan.direct and plan.intermediate.zoom == 2
        and plan.intermediate.x == 30 and plan.intermediate.y == 1300
        and plan.intermediate.w == 120 and plan.intermediate.h == 400)
    sx, sy = Geometry.sample(plan, 0, 0)
    verify("anisotropic_pixel_centers", sx == 0 and sy == 1)
    sx, sy = Geometry.sample(plan, 119, 199)
    verify("anisotropic_crop_end", sx == 119 and sy == 399)

    -- Each source/native orientation pair must reconstruct the same source
    -- point, including square-page cases where dimensions reveal nothing.
    for desired = 1, 8 do
        local logical_w, logical_h = Geometry.orientedDimensions(400, 900, desired)
        local geometry = assert(Geometry.new({
            width = logical_w, height = logical_h,
            extra = { geometry = { source_width = 400, source_height = 900, orientation = desired } },
        }))
        local anchor = geometry:toSourceAnchor(logical_w * 0.2, logical_h * 0.3)
        local x, y = geometry:fromSourceAnchor(anchor)
        verify("anchor_round_trip_" .. desired, close(x, logical_w * 0.2) and close(y, logical_h * 0.3))
        for native_orientation = 1, 8 do
            local nw, nh = Geometry.orientedDimensions(200, 450, native_orientation)
            local rendered = assert(geometry:plan({ width = nw, height = nh, orientation = native_orientation },
                { x = 13, y = 27, w = 50, h = 70 }))
            local local_x, local_y = 11.5, 19.5
            local matrix = rendered.sample
            local native_x = matrix.xx * local_x + matrix.xy * local_y + matrix.x0 + rendered.intermediate.x
            local native_y = matrix.yx * local_x + matrix.yy * local_y + matrix.y0 + rendered.intermediate.y
            native_x = native_x / (nw * rendered.intermediate.zoom)
            native_y = native_y / (nh * rendered.intermediate.zoom)
            local source_u, source_v = Geometry.transformPoint(Geometry.inverseOrientation(native_orientation), native_x, native_y)
            local display_u, display_v = Geometry.transformPoint(desired, source_u, source_v)
            verify("orientation_crop_" .. desired .. "_" .. native_orientation,
                close(display_u * logical_w, 24.5) and close(display_v * logical_h, 46.5))
        end
    end

    local rotated = assert(Geometry.new({ width = 400, height = 900 }))
    local rotations = { 0, 90, 180, 270 }
    local orientations = { 1, 6, 3, 8 }
    for index, rotation in ipairs(rotations) do
        plan = assert(rotated:plan({ width = 200, height = 450, orientation = 1 },
            { x = 20, y = 30, w = 100, h = 120, zoom = 1.5, rotation = rotation }))
        verify("reader_rotation_" .. rotation, plan.residual_orientation == orientations[index])
        local rw, rh = Geometry.orientedDimensions(400, 900, orientations[index])
        verify("reader_rotation_dimensions_" .. rotation, plan.display.w == rw * 1.5 and plan.display.h == rh * 1.5)
    end

    local precise = assert(Geometry.new({ width = 300, height = 1000 }))
    plan = assert(precise:plan({ width = 100, height = 1000 / 3, orientation = 1 },
        { x = 0, y = 600, w = 300, h = 200 }))
    verify("double_boundaries_do_not_add_rows", plan.intermediate.y == 600 and plan.intermediate.h == 200)
    plan = assert(precise:plan({ width = 100, height = 1000 / 3, orientation = 1 },
        { x = 0.25, y = 600.25, w = 100, h = 100 }))
    verify("fractional_crop_is_not_direct", not plan.direct and plan.intermediate.x == 0
        and plan.intermediate.y == 600 and plan.intermediate.w == 101 and plan.intermediate.h == 101)
    verify("fractional_crop_retains_sample_offset", close(plan.sample.x0, 0.25) and close(plan.sample.y0, 0.25))

    local failed, reason = page:plan({ width = 180, height = 1200 }, { w = 10, h = 10 })
    verify("native_orientation_is_explicit", failed == nil and reason == "native_orientation_unknown")
    failed, reason = page:plan({ width = 180, height = 1200, orientation = 1 },
        { w = 100, h = 100, max_intermediate_pixels = 1000 })
    verify("anisotropic_allocation_is_bounded", failed == nil and reason == "intermediate_too_large")
    failed, reason = page:plan({ width = 180, height = 600, orientation = 1 },
        { w = 100, h = 100, max_intermediate_pixels = 1 })
    verify("direct_draw_needs_no_extra_allocation", failed ~= nil and failed.direct)
    failed, reason = Geometry.new({ width = 360, height = 1200,
        extra = { geometry = { source_width = 360 } } })
    verify("source_dimensions_are_paired", failed == nil and reason == "invalid_source_dimensions")
    local anchor = page:toSourceAnchor(-20, 1400)
    verify("anchors_clamp_to_source_bounds", anchor.x == 0 and anchor.y == 1)
    local metadata = assert(Geometry.new({ width = 900, height = 400,
        geometry = { exif_orientation = 6, native_orientation = 6, source_width = 400, source_height = 900 },
        extra = { geometry = { orientation = 2 } },
    }))
    plan = assert(metadata:plan({ width = 450, height = 200, orientation = 1 }, { w = 50, h = 70 }))
    verify("stored_geometry_has_priority", metadata.orientation == 6 and metadata.oriented_source_width == 900)
    verify("stored_native_orientation_overrides_backend_default", plan.direct and plan.residual_orientation == 1)
    return count
end
