local Source = { width = 480, strategy = "official-width-480-v1" }

-- Match the width transform used by the official manga site's image component.
-- Keep its JPEG/PNG fallback because both formats are supported by KOReader.
function Source.resolve(url)
    if type(url) ~= "string" or #url > 4096 or url:find("[%s%c]") then return nil end
    local host, path = url:match("^https://([%w%.%-]+)(/.*)$")
    if not host then return nil end
    host = host:lower()
    if not (host:match("%.hdslb%.com$") or host:match("%.biliimg%.com$")
        or host:match("%.bilibili%.com$")) then return nil end
    local extension = path:match("%.([%a]+)$")
    extension = extension and extension:lower()
    local thumbnail = false
    if not url:find("@", 1, true) and not url:find("?", 1, true) and not url:find("#", 1, true)
        and (extension == "jpg" or extension == "jpeg" or extension == "png"
            or extension == "webp" or extension == "avif") then
        local format = (extension == "jpg" or extension == "jpeg") and "jpg" or "png"
        url = url .. "@" .. Source.width .. "w." .. format
        thumbnail = true
    end
    return { url = url, identity = Source.strategy .. ":" .. url, thumbnail = thumbnail }
end

return Source
