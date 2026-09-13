local Policy = { cover_max_pixels = 4000000 }

function Policy.fitsCover(header)
    if type(header) ~= "table" then return false end
    local width, height = header.width, header.height
    return type(width) == "number" and type(height) == "number"
        and width >= 1 and height >= 1 and width % 1 == 0 and height % 1 == 0
        and width * height <= Policy.cover_max_pixels
end

return Policy
