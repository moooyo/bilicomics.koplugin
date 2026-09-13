local ComicID = {}

function ComicID.parse(value)
    if type(value) ~= "string" or #value > 40 then return nil end
    local text = value:match("^%s*(.-)%s*$")
    local digits = text:match("^[mM][cC]([0-9]+)$") or text:match("^([0-9]+)$")
    if not digits or #digits > 15 then return nil end
    digits = digits:gsub("^0+", "")
    if digits == "" then return nil end
    return digits
end

return ComicID
