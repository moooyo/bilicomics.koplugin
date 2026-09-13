local CoverSource = require("bilicomics/cover_source")
local Errors = require("bilicomics/protocol/errors")
local JSON = require("bilicomics/protocol/json")

local Recommendations = {
    url = "https://manga.bilibili.com/index.pageContext.json",
    max_bytes = 4 * 1024 * 1024,
    max_items = 96,
}

local function invalid()
    return nil, Errors.new("protocol", "The official homepage returned an invalid recommendation feed.")
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

local function cover(value)
    if type(value) ~= "string" then return nil end
    -- The official feed still contains HTTP CDN locators; acquisition requires TLS.
    value = value:gsub("^http://", "https://")
    return CoverSource.resolve(value) and value or nil
end

local function array(value)
    if type(value) ~= "table" then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
    end
    return count == #value
end

function Recommendations.normalize(context)
    if type(context) ~= "table" or context.pageId ~= "/pages/index" or type(context.data) ~= "table"
        or type(context.data.recommendation) ~= "table" then return invalid() end
    local comics = context.data.recommendation.comics
    if not array(comics) then return invalid() end
    local groups = { { items = comics, section = "recommendation", id_key = "id", description_key = "evaluate" } }
    -- Match the official page order and its first/second carousel groups.
    -- Older page contexts can contain only the original recommendation section.
    for _, section in ipairs({
        { key = "hotSeller", name = "hot_seller" },
        { key = "internetHot", name = "internet_hot" },
        { key = "completedComic", name = "completed" },
    }) do
        local block = context.data[section.key]
        if type(block) == "table" then
            for _, name in ipairs({ "firstGroup", "secondGroup" }) do
                if array(block[name]) then
                    groups[#groups + 1] = { items = block[name], section = section.name,
                        id_key = "comic_id", description_key = "comic_introduction" }
                end
            end
        end
    end
    local items, seen, supplied = {}, {}, 0
    for _, group in ipairs(groups) do
        supplied = supplied + #group.items
        for _, raw in ipairs(group.items) do
            if type(raw) == "table" and #items < Recommendations.max_items then
                local id, title, cover_url = identifier(raw[group.id_key]), text(raw.title, 1024), cover(raw.vertical_cover)
                if id and title and cover_url and not seen[id] then
                    seen[id] = true
                    local tags = {}
                    if array(raw.tags) then
                        for _, tag in ipairs(raw.tags) do
                            local value = text(tag, 128)
                            if value then tags[#tags + 1] = value end
                        end
                    end
                    local evaluate = text(raw[group.description_key], 16384, true)
                    items[#items + 1] = {
                        id = id, title = title, cover_url = cover_url,
                        extra = { recommendation = evaluate, evaluate = evaluate, tags = tags,
                            recommendation_section = group.section },
                    }
                end
            end
        end
    end
    if supplied > 0 and #items == 0 then return invalid() end
    return { source = "official_homepage", personalized = false, has_more = false, items = items }
end

function Recommendations.fetch(transport)
    -- This public Vike data route is the exact source used by the official homepage.
    -- Its headers are independent of Client session headers and it never captures cookies.
    local response, err = transport:request({
        url = Recommendations.url, method = "GET", max_bytes = Recommendations.max_bytes,
        headers = {
            ["user-agent"] = "Mozilla/5.0 (X11; Linux) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36",
            ["accept"] = "application/json", ["referer"] = "https://manga.bilibili.com/",
        },
    })
    if not response then return nil, err end
    if type(response.status) ~= "number" then return invalid() end
    if response.status < 200 or response.status >= 300 then
        return nil, Errors.new("http", "The official homepage could not be loaded.", {
            status = response.status, retryable = response.status == 429 or response.status >= 500,
            transmitted = response.transmitted,
        })
    end
    if type(response.body) ~= "string" or #response.body > Recommendations.max_bytes then return invalid() end
    local context
    context, err = JSON.decode(response.body)
    if not context then return nil, err end
    return Recommendations.normalize(context)
end

return Recommendations
