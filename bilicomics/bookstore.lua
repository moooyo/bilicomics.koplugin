local ComicID = require("bilicomics/catalog/comic_id")
local CoverSource = require("bilicomics/cover_source")
local Util = require("bilicomics/util")

-- Keep the account storage key stable so the previous seven-comic feed remains available offline.
local Bookstore = { key = "bookstore_feed_v1", source = "official_homepage", schema_version = 2, limit = 96, ttl = 21600 }
local sections = { recommendation = true, hot_seller = true, internet_hot = true, completed = true }

local function array(value, maximum)
    if type(value) ~= "table" or #value > maximum then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #value then return false end
        count = count + 1
        if count > maximum then return false end
    end
    return count == #value
end

local function text(value, maximum)
    if type(value) ~= "string" or #value > maximum or value:find("[%z\1-\8\11\12\14-\31\127]") then return nil end
    return value:find("%S") and value or nil
end

local function identifier(value)
    if type(value) == "number" then
        if value ~= value or value <= 0 or value > 999999999999999 or value % 1 ~= 0 then return nil end
        value = string.format("%.0f", value)
    end
    return ComicID.parse(value)
end

function Bookstore.editorial(extra)
    extra = type(extra) == "table" and extra or {}
    local tags = {}
    if array(extra.tags, 256) then
        for _, tag in ipairs(extra.tags) do
            local label = text(tag, 128)
            if label then tags[#tags + 1] = label end
            if #tags >= 8 then break end
        end
    end
    local section = type(extra.recommendation_section) == "string" and sections[extra.recommendation_section]
        and extra.recommendation_section or nil
    return { recommendation = text(extra.recommendation, 16384), evaluate = text(extra.evaluate, 16384),
        recommendation_section = section, tags = tags }
end

function Bookstore.normalize(feed)
    if type(feed) ~= "table" or feed.source ~= Bookstore.source or feed.personalized ~= false
        or feed.has_more ~= false or not array(feed.items, 256) then
        return nil, Util.error("protocol", "The public recommendation feed is invalid.")
    end
    local items, seen = {}, {}
    for _, comic in ipairs(feed.items) do
        if type(comic) == "table" then
            local id, title = identifier(comic.id), text(comic.title, 1024)
            local cover = type(comic.cover_url) == "string" and not comic.cover_url:find("?", 1, true)
                and CoverSource.resolve(comic.cover_url)
            if id and title and cover and not seen[id] then
                seen[id] = true
                -- Recommendation metadata cannot import favorites, reading history or page anchors.
                items[#items + 1] = { id = id, title = title, cover_url = comic.cover_url,
                    extra = Bookstore.editorial(comic.extra) }
                if #items >= Bookstore.limit then break end
            end
        end
    end
    if #feed.items > 0 and #items == 0 then
        return nil, Util.error("protocol", "The public recommendation feed has no usable comics.")
    end
    return items
end

function Bookstore.snapshot(items, account_key, fetched_at)
    local ids = {}
    for _, comic in ipairs(items) do ids[#ids + 1] = comic.id end
    return { schema_version = Bookstore.schema_version, account_key = account_key, source = Bookstore.source,
        personalized = false, has_more = false, ids = ids, fetched_at = fetched_at, revision = Util.id("homepage-feed") }
end

function Bookstore.cache(value, account_key)
    if type(value) ~= "table" or (value.schema_version ~= 1 and value.schema_version ~= Bookstore.schema_version)
        or value.account_key ~= account_key
        or value.source ~= Bookstore.source or value.personalized ~= false or value.has_more ~= false
        or not array(value.ids, value.schema_version == 1 and 32 or Bookstore.limit) or type(value.fetched_at) ~= "number"
        or value.fetched_at ~= value.fetched_at or value.fetched_at <= 0 or value.fetched_at == math.huge then return nil end
    if value.revision ~= nil and (type(value.revision) ~= "string" or #value.revision == 0 or #value.revision > 128) then return nil end
    local seen = {}
    for _, id in ipairs(value.ids) do
        if type(id) ~= "string" or identifier(id) ~= id or seen[id] then return nil end
        seen[id] = true
    end
    return value
end

return Bookstore
