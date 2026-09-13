local Header = {}

local function be16(data, offset)
    local a, b = data:byte(offset, offset + 1)
    return a and b and a * 256 + b
end
local function be32(data, offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    return d and ((a * 256 + b) * 256 + c) * 256 + d
end
local function le24(data, offset)
    local a, b, c = data:byte(offset, offset + 2)
    return c and a + b * 256 + c * 65536
end
local function le32(data, offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    return d and a + b * 256 + c * 65536 + d * 16777216
end

local function exifOrientation(data)
    local little = data:sub(1, 2) == "II"
    assert(little or data:sub(1, 2) == "MM", "Invalid EXIF byte order")
    local function u16(offset)
        local a, b = data:byte(offset, offset + 1)
        assert(a and b, "Truncated EXIF integer")
        return little and a + b * 256 or a * 256 + b
    end
    local function u32(offset)
        local a, b, c, d = data:byte(offset, offset + 3)
        assert(a and d, "Truncated EXIF offset")
        return little and a + b * 256 + c * 65536 + d * 16777216 or ((a * 256 + b) * 256 + c) * 256 + d
    end
    assert(u16(3) == 42, "Invalid EXIF TIFF header")
    local offset = u32(5) + 1
    local count = u16(offset)
    assert(count <= 4096 and offset + 2 + count * 12 <= #data, "Invalid EXIF directory")
    for i = 0, count - 1 do
        local entry = offset + 2 + i * 12
        if u16(entry) == 274 then
            assert(u16(entry + 2) == 3 and u32(entry + 4) == 1, "Invalid EXIF orientation field")
            local orientation = u16(entry + 8)
            assert(orientation >= 1 and orientation <= 8, "Unsupported EXIF orientation")
            return orientation
        end
    end
    return 1
end

local function chunkOrientation(path, length, format)
    local file = assert(io.open(path, "rb"))
    local ok, orientation = pcall(function()
        local offset, chunks, found = format == "png" and 8 or 12, 0, 1
        while offset + 8 <= length do
            chunks = chunks + 1
            assert(chunks <= 10000, "Image has too many metadata chunks")
            assert(file:seek("set", offset))
            local header = assert(file:read(8), "Truncated image chunk")
            local size = format == "png" and be32(header, 1) or le32(header, 5)
            local kind = format == "png" and header:sub(5, 8) or header:sub(1, 4)
            local extent = size + (format == "png" and 12 or 8 + size % 2)
            assert(size and offset + extent <= length, "Image chunk extends beyond the file")
            if kind == "eXIf" or kind == "EXIF" then
                assert(size <= 65536, "EXIF metadata exceeds the safe inspection limit")
                local exif = assert(file:read(size), "Truncated EXIF metadata")
                if exif:sub(1, 6) == "Exif\0\0" then exif = exif:sub(7) end
                found = exifOrientation(exif)
            end
            offset = offset + extent
        end
        assert(offset == length, "Image chunk table is truncated")
        return found
    end)
    file:close()
    if not ok then error(orientation, 0) end
    return orientation
end

-- This bounded header inspection complements worker-side decoding verification.
-- It never decodes a source image or allocates a source-sized pixel buffer.
function Header.read(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read(65536) or ""
    local length = file:seek("end")
    local tail
    if length and length >= 12 then file:seek("end", -12); tail = file:read(12) end
    file:close()
    if data:sub(1, 8) == "\137PNG\13\10\26\10" then
        assert(data:sub(13, 16) == "IHDR" and be32(data, 9) == 13, "Invalid PNG header")
        assert(tail and tail:sub(5, 8) == "IEND", "Truncated PNG image")
        return { format = "png", width = be32(data, 17), height = be32(data, 21),
            exif_orientation = chunkOrientation(path, length, "png") }
    elseif data:sub(1, 2) == "\255\216" then
        assert(tail and tail:sub(-2) == "\255\217", "Truncated JPEG image")
        local offset, width, height, orientation = 3, nil, nil, 1
        while offset + 8 <= #data do
            assert(data:byte(offset) == 255, "Invalid JPEG marker")
            while data:byte(offset) == 255 do offset = offset + 1 end
            local marker = data:byte(offset)
            offset = offset + 1
            if marker == 218 or marker == 217 then break end
            local segment_size = be16(data, offset)
            assert(segment_size and segment_size >= 2, "Invalid JPEG segment")
            if marker >= 192 and marker <= 207 and marker ~= 196 and marker ~= 200 and marker ~= 204 then
                width, height = be16(data, offset + 5), be16(data, offset + 3)
            elseif marker == 225 and data:sub(offset + 2, offset + 7) == "Exif\0\0" then
                assert(offset + segment_size - 1 <= #data, "EXIF exceeds the bounded header")
                orientation = exifOrientation(data:sub(offset + 8, offset + segment_size - 1))
            end
            offset = offset + segment_size
        end
        assert(width and height, "JPEG geometry is absent from the bounded header")
        return { format = "jpg", width = width, height = height, exif_orientation = orientation }
    elseif data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        local riff_length = le32(data, 5)
        assert(riff_length + 8 == length, "Truncated WebP image")
        local kind = data:sub(13, 16)
        local orientation = chunkOrientation(path, length, "webp")
        if kind == "VP8X" then
            return { format = "webp", width = assert(le24(data, 25)) + 1, height = assert(le24(data, 28)) + 1,
                exif_orientation = orientation }
        elseif kind == "VP8 " then
            assert(data:sub(24, 26) == "\157\001\042", "Invalid WebP frame")
            return { format = "webp", width = (data:byte(27) + data:byte(28) * 256) % 16384,
                height = (data:byte(29) + data:byte(30) * 256) % 16384, exif_orientation = orientation }
        elseif kind == "VP8L" then
            assert(data:byte(21) == 47 and #data >= 25, "Invalid lossless WebP frame")
            local a, b, c, d = data:byte(22, 25)
            return { format = "webp", width = 1 + a + (b % 64) * 256,
                height = 1 + math.floor(b / 64) + c * 4 + (d % 16) * 1024, exif_orientation = orientation }
        end
    end
    error("Unsupported or invalid image format")
end

return Header
