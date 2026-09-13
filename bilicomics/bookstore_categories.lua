local Bookstore = require("bilicomics/bookstore")
local Util = require("bilicomics/util")

local Categories = {
    metadata_key = "bookstore_categories_v1", metadata_source = "official_categories", source = "official_category",
    metadata_ttl = 86400, ttl = 21600, page_size = 18, max_pages = 5,
}
local sorts = { [0] = true, [1] = true, [3] = true }

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

local function categoryID(value)
    if type(value) == "number" then
        if value ~= value or value % 1 ~= 0 or value < -1 or value > 2147483647 then return nil end
        value = string.format("%.0f", value)
    end
    if type(value) ~= "string" or #value > 10 then return nil end
    if value == "-1" then return value end
    if value:match("^[1-9]%d*$") and tonumber(value) <= 2147483647 then return value end
end

local function label(value)
    return type(value) == "string" and #value <= 256 and value:find("%S")
        and not value:find("[%c]") and value or nil
end

local function timestamp(value)
    return type(value) == "number" and value == value and value > 0 and value < math.huge
end

local function invalid(message)
    return nil, Util.error("invalid_request", message or "Select an available official comic category.")
end

function Categories.query(value)
    if type(value) ~= "table" then return invalid() end
    for key in pairs(value) do if key ~= "kind" and key ~= "category_id" and key ~= "sort" then return invalid() end end
    local id, sort = categoryID(value.category_id), value.sort == nil and 0 or value.sort
    if (value.kind ~= nil and value.kind ~= "category") or not id or not sorts[sort] then return invalid() end
    return { kind = "category", category_id = id, sort = sort }
end

function Categories.queryKey(query)
    return "category:" .. query.category_id .. ":sort:" .. query.sort
end

function Categories.queryFromKey(key)
    if type(key) ~= "string" then return nil end
    local id, sort = key:match("^category:(%-?%d+):sort:([013])$")
    if not id then return nil end
    return Categories.query{ category_id = id, sort = tonumber(sort) }
end

function Categories.cacheKey(query)
    return "bookstore_category_v1:" .. query.category_id .. ":" .. query.sort
end

function Categories.metadata(value)
    if type(value) ~= "table" or value.source ~= Categories.metadata_source
        or not array(value.items, 128) or not array(value.orders, 16) then
        return nil, Util.error("protocol", "The official comic categories are invalid.")
    end
    local items, orders, seen, seen_sorts = {}, {}, {}, {}
    for _, item in ipairs(value.items) do
        local id = type(item) == "table" and categoryID(item.id)
        local name = type(item) == "table" and label(item.name)
        if not id or not name or seen[id] then return nil, Util.error("protocol", "The official comic categories are invalid.") end
        seen[id] = true
        items[#items + 1] = { id = id, name = name }
    end
    for _, item in ipairs(value.orders) do
        if type(item) ~= "table" or not sorts[item.id] or not label(item.name) or seen_sorts[item.id] then
            return nil, Util.error("protocol", "The official category sorting options are invalid.")
        end
        seen_sorts[item.id] = true
        orders[#orders + 1] = { id = item.id, name = item.name }
    end
    if #items == 0 or not seen_sorts[0] then return nil, Util.error("protocol", "The official comic categories are unavailable.") end
    return { source = Categories.metadata_source, items = items, orders = orders }
end

function Categories.metadataSnapshot(value, account_key, now)
    return { schema_version = 1, account_key = account_key, source = Categories.metadata_source,
        updated_at = now, items = value.items, orders = value.orders }
end

function Categories.metadataCache(value, account_key)
    if type(value) ~= "table" or value.schema_version ~= 1 or value.account_key ~= account_key or not timestamp(value.updated_at) then return nil end
    local normalized = Categories.metadata(value)
    if not normalized then return nil end
    normalized.updated_at = value.updated_at
    return normalized
end

function Categories.available(metadata, query)
    if not metadata then return false end
    local found_category, found_sort = false, false
    for _, item in ipairs(metadata.items) do if item.id == query.category_id then found_category = true; break end end
    for _, item in ipairs(metadata.orders) do if item.id == query.sort then found_sort = true; break end end
    return found_category and found_sort
end

function Categories.pageNumber(page)
    return type(page) == "number" and page % 1 == 0 and page >= 1 and page <= Categories.max_pages
end

function Categories.arguments(arguments)
    if not array(arguments, 2) or #arguments ~= 2 or not Categories.pageNumber(arguments[2]) then return nil end
    local query = Categories.query(arguments[1])
    if query then return query, arguments[2] end
end

function Categories.page(value, query, page, now)
    local returned = type(value) == "table" and Categories.query(value.query)
    if type(value) ~= "table" or value.source ~= Categories.source or value.personalized ~= false
        or not returned or Categories.queryKey(returned) ~= Categories.queryKey(query)
        or value.page ~= page or value.page_size ~= Categories.page_size or type(value.has_more) ~= "boolean"
        or not array(value.items, Categories.page_size) or (#value.items > 0 and not value.has_more) then
        return nil, Util.error("protocol", "The official category page does not match the requested category and page.")
    end
    local items, err = Bookstore.normalize{ source = Bookstore.source, personalized = false, has_more = false, items = value.items }
    if not items then return nil, err end
    local neutral, entries = {}, {}
    for _, item in ipairs(items) do
        local editorial = Bookstore.editorial(item.extra)
        editorial.recommendation_section = nil
        neutral[#neutral + 1] = { id = item.id, title = item.title, cover_url = item.cover_url }
        entries[#entries + 1] = { id = item.id, title = item.title, cover_url = item.cover_url, editorial = editorial }
    end
    return { page = page, updated_at = now, has_more = value.has_more, entries = entries }, neutral
end

function Categories.snapshot(query, account_key, pages, now)
    return { schema_version = 1, source = Categories.source, account_key = account_key,
        query = query, page_size = Categories.page_size, pages = pages, updated_at = now,
        revision = Util.id("category-feed") }
end

function Categories.cache(value, account_key, query)
    if type(value) ~= "table" or value.schema_version ~= 1 or value.source ~= Categories.source
        or value.account_key ~= account_key or value.page_size ~= Categories.page_size or not timestamp(value.updated_at)
        or type(value.revision) ~= "string" or #value.revision == 0 or #value.revision > 128
        or not array(value.pages, Categories.max_pages) or #value.pages == 0 then return nil end
    local saved_query = Categories.query(value.query)
    if not saved_query or Categories.queryKey(saved_query) ~= Categories.queryKey(query) then return nil end
    for index, page in ipairs(value.pages) do
        if type(page) ~= "table" or page.page ~= index or not timestamp(page.updated_at)
            or type(page.has_more) ~= "boolean" or not array(page.entries, Categories.page_size)
            or (index < #value.pages and not page.has_more) then return nil end
        local seen = {}
        for _, entry in ipairs(page.entries) do
            if type(entry) ~= "table" or type(entry.id) ~= "string" or #entry.id > 15
                or not entry.id:match("^[1-9]%d*$") or seen[entry.id]
                or type(entry.title) ~= "string" or #entry.title == 0 or #entry.title > 1024
                or type(entry.cover_url) ~= "string" or #entry.cover_url > 4096 then return nil end
            seen[entry.id] = true
        end
    end
    return value
end

function Categories.entries(snapshot)
    local entries, seen = {}, {}
    for _, page in ipairs(snapshot.pages) do
        for _, entry in ipairs(page.entries) do
            if not seen[entry.id] then
                seen[entry.id] = true
                entries[#entries + 1] = entry
            end
        end
    end
    return entries
end

return Categories
