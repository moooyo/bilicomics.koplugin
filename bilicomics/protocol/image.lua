local Errors = require("bilicomics/protocol/errors")

local Image = {}
local crc_table

local function be16(data, offset)
    local a, b = data:byte(offset, offset + 1)
    return b and a * 256 + b or nil
end

local function be32(data, offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    return d and ((a * 256 + b) * 256 + c) * 256 + d or nil
end

local function le24(data, offset)
    local a, b, c = data:byte(offset, offset + 2)
    return c and (c * 256 + b) * 256 + a or nil
end

local function le32(data, offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    return d and ((d * 256 + c) * 256 + b) * 256 + a or nil
end

local function verifyPNG(path, size)
    local bit = require("bit")
    if not crc_table then
        crc_table = {}
        for byte = 0, 255 do
            local value = byte
            for _ = 1, 8 do
                value = bit.bxor(bit.rshift(value, 1), value % 2 == 1 and 0xedb88320 or 0)
            end
            crc_table[byte] = value
        end
    end
    local function update(crc, bytes)
        for index = 1, #bytes do
            crc = bit.bxor(bit.rshift(crc, 8), crc_table[bit.band(bit.bxor(crc, bytes:byte(index)), 255)])
        end
        return crc
    end
    local file = io.open(path, "rb")
    if not file then return false end
    file:seek("set", 8)
    local offset, saw_data, complete = 8, false, false
    while offset + 12 <= size do
        local header = file:read(8)
        if not header or #header ~= 8 then break end
        local length, kind = be32(header, 1), header:sub(5, 8)
        if not length or length > size - offset - 12 or not kind:match("^%a%a%a%a$") then break end
        if (offset == 8 and (kind ~= "IHDR" or length ~= 13)) or (offset > 8 and kind == "IHDR") then break end
        local crc, remaining = update(-1, kind), length
        while remaining > 0 do
            local bytes = file:read(math.min(remaining, 65536))
            if not bytes or #bytes == 0 then file:close(); return false end
            remaining, crc = remaining - #bytes, update(crc, bytes)
        end
        local checksum = file:read(4)
        if not checksum or #checksum ~= 4 or be32(checksum, 1) ~= bit.bnot(crc) % 4294967296 then break end
        offset = offset + length + 12
        if kind == "IDAT" then saw_data = true end
        if kind == "IEND" then complete = length == 0 and offset == size and saw_data; break end
    end
    file:close()
    return complete
end

function Image.header(data, file_size)
    if data:sub(1, 8) == "\137PNG\r\n\026\n" then
        if be32(data, 9) ~= 13 or data:sub(13, 16) ~= "IHDR" then return nil end
        return { format = "png", width = be32(data, 17), height = be32(data, 21) }
    end
    if data:sub(1, 2) == "\255\216" then
        local offset = 3
        while offset + 3 <= #data do
            if data:byte(offset) ~= 255 then return nil end
            while data:byte(offset) == 255 do offset = offset + 1 end
            local marker = data:byte(offset)
            offset = offset + 1
            if not marker or marker == 217 or marker == 218 then return nil end
            if marker ~= 1 and not (marker >= 208 and marker <= 215) then
                local length = be16(data, offset)
                if not length or length < 2 then return nil end
                if (marker >= 192 and marker <= 195) or (marker >= 197 and marker <= 199)
                    or (marker >= 201 and marker <= 203) or (marker >= 205 and marker <= 207) then
                    if length < 8 then return nil end
                    return { format = "jpg", width = be16(data, offset + 5), height = be16(data, offset + 3) }
                end
                offset = offset + length
            end
        end
        return nil
    end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        local declared = le32(data, 5)
        if not declared or (file_size and declared + 8 ~= file_size) then return nil end
        local chunk = data:sub(13, 16)
        if chunk == "VP8X" and #data >= 30 then
            local flags = data:byte(21)
            if flags % 4 >= 2 then return nil end -- Animated WebP is outside the page contract.
            return { format = "webp", width = le24(data, 25) + 1, height = le24(data, 28) + 1 }
        elseif chunk == "VP8L" and #data >= 25 and data:byte(21) == 47 then
            local bits = le32(data, 22)
            return { format = "webp", width = bits % 16384 + 1, height = math.floor(bits / 16384) % 16384 + 1 }
        elseif chunk == "VP8 " and #data >= 30 and data:sub(24, 26) == "\157\001\042" then
            local width = data:byte(27) + data:byte(28) * 256
            local height = data:byte(29) + data:byte(30) * 256
            return { format = "webp", width = width % 16384, height = height % 16384 }
        end
    end
    return nil
end

-- Headers and container bounds are checked without decoding the image into RAM.
-- The native reader applies its pixel/format budget before MuPDF opens the file.
function Image.inspect(path, opts)
    opts = opts or {}
    local file = io.open(path, "rb")
    if not file then return nil, Errors.new("storage", "The acquired image file is missing.") end
    local size = file:seek("end")
    file:seek("set", 0)
    local data = file:read(math.min(size or 0, 1024 * 1024)) or ""
    local info = Image.header(data, size)
    local tail
    if size and size >= 12 then file:seek("end", -12); tail = file:read(12) end
    file:close()
    if not info or not info.width or not info.height or info.width < 1 or info.height < 1
        or info.width > 1000000 or info.height > 1000000 then
        return nil, Errors.new("invalid_image", "The acquired resource is not a supported comic image.")
    end
    if (info.format == "png" and tail ~= "\000\000\000\000IEND\174\066\096\130")
        or (info.format == "jpg" and (not tail or tail:sub(-2) ~= "\255\217")) then
        return nil, Errors.new("invalid_image", "The image container is incomplete.")
    end
    if info.format == "png" and not verifyPNG(path, size) then
        return nil, Errors.new("invalid_image", "The PNG image contains invalid chunks or checksums.")
    end
    if opts.max_pixels and info.width * info.height > opts.max_pixels then
        return nil, Errors.new("image_size", "This image exceeds the configured image preparation limit.")
    end
    info.bytes, info.temporary_path = size, path
    info.verification = "container"
    local update = require("ffi/sha2").sha256()
    file = io.open(path, "rb")
    if not file then return nil, Errors.new("storage", "The acquired image could not be verified.") end
    while true do
        local chunk = file:read(65536)
        if not chunk then break end
        update(chunk)
    end
    file:close()
    info.checksum = update()
    return info
end

return Image
