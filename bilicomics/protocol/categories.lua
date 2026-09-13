local CoverSource = require("bilicomics/cover_source")
local Errors = require("bilicomics/protocol/errors")
local JSON = require("bilicomics/protocol/json")

local Categories = {
    metadata_url = "https://manga.bilibili.com/twirp/comic.v1.Comic/AllLabel?device=pc&platform=web&nov=27&a=810",
    device_url = "https://manga.bilibili.com/ductape/buvid",
    page_url = "https://manga.bilibili.com/twirp/comic.v1.Comic/ClassPage?device=pc&platform=web&nov=27&a=810&ultra_sign=",
    page_size = 18, max_page = 5,
}
local sorts = { [0] = true, [1] = true, [3] = true }

local function invalid(message)
    return nil, Errors.new("invalid_request", message, { transmitted = false, definitive = true })
end

local function protocol(message)
    return nil, Errors.new("protocol", message or "The official category response is invalid.")
end

local function identifier(value)
    if type(value) == "number" then
        if value ~= value or value < 1 or value > 999999999999999 or value % 1 ~= 0 then return nil end
        return string.format("%.0f", value)
    end
    if type(value) == "string" and #value <= 15 and value:match("^[1-9]%d*$") then return value end
end

local function text(value, maximum, multiline)
    if type(value) ~= "string" or #value > maximum then return nil end
    value = value:gsub("[%z\1-\8\11\12\14-\31\127]", "")
    if not multiline then value = value:gsub("%s+", " ") end
    value = value:match("^%s*(.-)%s*$")
    return value ~= "" and value or nil
end

local function array(value)
    if type(value) ~= "table" then return false end
    local metadata = getmetatable(value)
    if type(metadata) == "table" and metadata.__jsontype == "object" then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
    end
    return count == #value
end

local function names(value, maximum)
    local result, seen = {}, {}
    if array(value) then
        for _, raw in ipairs(value) do
            local item = text(raw, 256)
            if item and not seen[item] and #result < maximum then
                seen[item] = true
                result[#result + 1] = item
            end
        end
    end
    return result
end

local function headers(json_body)
    local value = {
        ["user-agent"] = "Mozilla/5.0 (X11; Linux) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36",
        accept = "application/json", referer = "https://manga.bilibili.com/",
    }
    if json_body then
        value["content-type"] = "application/json;charset=UTF-8"
        value.origin = "https://manga.bilibili.com"
    end
    return value
end

local function responseData(response, limit)
    if type(response) ~= "table" or type(response.status) ~= "number" then return protocol() end
    if response.status < 200 or response.status >= 300 then
        return nil, Errors.new("http", "The official category service could not be loaded.", {
            status = response.status, retryable = response.status == 429 or response.status >= 500,
            transmitted = response.transmitted,
        })
    end
    if type(response.body) ~= "string" or #response.body > limit then return protocol() end
    local envelope, err = JSON.decode(response.body)
    if not envelope then return nil, err end
    if type(envelope) ~= "table" then return protocol() end
    if type(envelope.code) ~= "number" then return protocol() end
    if envelope.code ~= 0 then return nil, Errors.business(envelope.code, "AllLabel") end
    if type(envelope.data) ~= "table" then return protocol() end
    return envelope.data
end

function Categories.metadata(transport)
    local response, err = transport:request({ url = Categories.metadata_url, method = "POST", body = "{}",
        headers = headers(true), max_bytes = 1024 * 1024 })
    if not response then return nil, err end
    local data
    data, err = responseData(response, 1024 * 1024)
    if not data then return nil, err end
    if not array(data.styles) or not array(data.orders) then return protocol() end
    local items, orders, seen = {}, {}, {}
    for _, raw in ipairs(data.styles) do
        local id = type(raw) == "table" and identifier(raw.id)
        local name = type(raw) == "table" and text(raw.name, 128)
        if id and name and not seen[id] and #items < 128 then
            seen[id] = true
            items[#items + 1] = { id = id, name = name }
        end
    end
    seen = {}
    for _, raw in ipairs(data.orders) do
        local id = type(raw) == "table" and raw.id
        local name = type(raw) == "table" and text(raw.name, 128)
        if sorts[id] and name and not seen[id] then
            seen[id] = true
            orders[#orders + 1] = { id = id, name = name }
        end
    end
    if #items == 0 or not seen[0] then return protocol() end
    return { source = "official_categories", items = items, orders = orders }
end

function Categories.query(query, page)
    if type(query) ~= "table" then return invalid("Select an official comic category.") end
    for key in pairs(query) do
        if key ~= "kind" and key ~= "category_id" and key ~= "sort" then return invalid("The category query contains an unsupported field.") end
    end
    local id, sort = identifier(query.category_id), query.sort == nil and 0 or query.sort
    page = page == nil and 1 or page
    if not id or query.kind ~= nil and query.kind ~= "category" or not sorts[sort] then
        return invalid("Select an official category and a supported category order.")
    end
    if type(page) ~= "number" or page % 1 ~= 0 or page < 1 or page > Categories.max_page then
        return invalid("The requested category page is outside the supported range.")
    end
    return { kind = "category", category_id = id, sort = sort }, page
end

local function deviceCookie(transport)
    local response, err = transport:request({ url = Categories.device_url, method = "GET",
        headers = headers(false), max_bytes = 65536 })
    if not response then return nil, err end
    if type(response) ~= "table" then return protocol() end
    if type(response.status) ~= "number" or response.status ~= 200 then
        return nil, Errors.new("http", "The anonymous category device context could not be initialized.", {
            status = response.status, retryable = response.status == 429 or type(response.status) == "number" and response.status >= 500,
        })
    end
    local buvid
    for key, values in pairs(type(response.headers) == "table" and response.headers or {}) do
        if type(key) == "string" and key:lower() == "set-cookie" then
            if type(values) == "string" then values = { values } end
            if type(values) ~= "table" then return protocol() end
            for _, value in ipairs(values) do
                if type(value) ~= "string" or #value > 16384 or value:find("[\r\n%z]") then return protocol() end
                local candidate = value:match("^%s*buvid3=([^;]*)")
                if candidate then
                    if #candidate == 0 or #candidate > 256 or not candidate:match("^[%w_-]+$")
                        or buvid and candidate ~= buvid then return protocol("The anonymous category device cookie is invalid.") end
                    buvid = candidate
                end
            end
        end
    end
    if not buvid then return protocol("The official service did not provide an anonymous category device context.") end
    return buvid
end

function Categories.normalizePage(data, query, page)
    if not array(data) or #data > Categories.page_size then return protocol() end
    local items, seen = {}, {}
    for _, raw in ipairs(data) do
        if type(raw) == "table" and raw.type == 0 then
            local id, title = identifier(raw.season_id), text(raw.title, 1024)
            local cover = type(raw.vertical_cover) == "string" and raw.vertical_cover:gsub("^http://", "https://")
            if id and title and cover and not cover:find("[?#]") and CoverSource.resolve(cover) and not seen[id] then
                seen[id] = true
                local tags = names(raw.bottom_info_v2, 12)
                local tag = text(raw.rd_tag, 128)
                local exists = false
                for _, value in ipairs(tags) do if value == tag then exists = true end end
                if tag and not exists and #tags < 12 then tags[#tags + 1] = tag end
                local evaluate = text(raw.evaluate, 16384, true)
                local finished
                if raw.is_finish == 0 or raw.is_finish == 1 then finished = raw.is_finish == 1 end
                items[#items + 1] = { id = id, title = title, cover_url = cover, authors = names(raw.author, 20), finished = finished,
                    extra = { recommendation = text(raw.introduction, 16384, true) or evaluate, evaluate = evaluate,
                        tags = tags, category_id = query.category_id, category_names = names(raw.styles, 16) } }
            end
        end
    end
    if #data > 0 and #items == 0 then return protocol("The official category page contains no usable comics.") end
    -- Comic.total counts chapters; the official page ends only after an empty result array.
    return { source = "official_category", personalized = false, query = query, page = page,
        page_size = Categories.page_size, has_more = #data > 0, items = items }
end

function Categories.page(parent, query, page)
    local selected, value = Categories.query(query, page)
    if not selected then return nil, value end
    page = value
    local preparation, err = parent.crypto:prepareCatalog({ timestamp_ms = parent.clock() * 1000 })
    if not preparation then return nil, err end
    local buvid
    buvid, err = deviceCookie(parent.transport)
    if not buvid then return nil, err end
    local transport = {}
    function transport:request(request)
        local signature = type(request) == "table" and type(request.url) == "string"
            and request.url:sub(#Categories.page_url + 1)
        if type(request) ~= "table" or request.method ~= "POST" or type(request.url) ~= "string"
            or request.url:sub(1, #Categories.page_url) ~= Categories.page_url or request.output_path ~= nil
            or not signature or not signature:match("^[%w%%_.~%-]+$") or type(request.headers) ~= "table"
            or request.headers.cookie ~= "buvid3=" .. buvid then
            return invalid("The anonymous category context cannot be used outside its category request.")
        end
        request.max_bytes = 4 * 1024 * 1024
        return parent.transport:request(request)
    end
    -- This guest exists only within this one read. The parent session is never inspected.
    local guest = require("bilicomics/protocol/client").new{ transport = transport, crypto = parent.crypto,
        clock = parent.clock, session = { cookies = { buvid3 = buvid } } }
    guest._captureCookies = function() return true end
    local data
    data, err = guest:_post("comic.v1.Comic", "ClassPage", {
        style_id = tonumber(selected.category_id), area_id = -1, is_finish = -1, order = selected.sort,
        special_tag = 0, page_num = page, page_size = Categories.page_size, is_free = -1, m2 = preparation.m2,
    })
    if not data then return nil, err end
    return Categories.normalizePage(data, selected, page)
end

return Categories
