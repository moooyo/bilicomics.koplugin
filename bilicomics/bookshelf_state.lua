local ComicID = require("bilicomics/catalog/comic_id")
local Util = require("bilicomics/util")

local Bookshelf = { sync_key = "bookshelf_sync_v1", view_key = "bookshelf_view_v1", ttl = 900, retry_delay = 60,
    maximum_items = 20000 }
local filters = { all = true, reading = true, unknown = true, updated = true, completed = true }
local sorts = { source = true, title = true, recent = true }

local function validID(value)
    return type(value) == "string" and ComicID.parse(value) == value
end

local function orderedIDs(value)
    if type(value) ~= "table" or #value > Bookshelf.maximum_items then return nil end
    local count, result, seen = 0, {}, {}
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #value then return nil end
        count = count + 1
    end
    if count ~= #value then return nil end
    for _, id in ipairs(value) do
        if not validID(id) or seen[id] then return nil end
        seen[id], result[#result + 1] = true, id
    end
    return result
end

function Bookshelf.syncSnapshot(items, account_key, now)
    local ids = {}
    for _, comic in ipairs(items) do
        local id = tostring(comic.id)
        ids[#ids + 1] = id
    end
    ids = assert(orderedIDs(ids), "The synchronized bookshelf contains invalid identities")
    return { schema_version = 1, account_key = account_key, last_synced_at = now, order_ids = ids }
end

function Bookshelf.syncCache(value, account_key)
    if type(value) ~= "table" or value.schema_version ~= 1 or value.account_key ~= account_key
        or type(value.last_synced_at) ~= "number" or value.last_synced_at ~= value.last_synced_at
        or value.last_synced_at <= 0 or value.last_synced_at > 253402300799 then return nil end
    local ids = orderedIDs(value.order_ids)
    if not ids then return nil end
    return { schema_version = 1, account_key = account_key, last_synced_at = value.last_synced_at, order_ids = ids }
end

function Bookshelf.view(value, account_key)
    local result = { schema_version = 1, account_key = account_key, filter = "all", sort = "source", page = 1,
        order_ids = {}, help_seen = false }
    if type(value) ~= "table" or value.schema_version ~= 1 or value.account_key ~= account_key then return result end
    result.filter = filters[value.filter] and value.filter or result.filter
    result.sort = sorts[value.sort] and value.sort or result.sort
    if type(value.page) == "number" and value.page >= 1 and value.page <= 100000 and value.page % 1 == 0 then
        result.page = value.page
    end
    result.focused_comic_id = validID(value.focused_comic_id) and value.focused_comic_id or nil
    result.order_ids = orderedIDs(value.order_ids) or {}
    result.help_seen = value.help_seen == true
    return result
end

function Bookshelf.updateView(previous, changes, account_key)
    if type(changes) ~= "table" then return nil, Util.error("invalid_request", "The bookshelf view state is invalid.") end
    local result = Bookshelf.view(previous, account_key)
    for _, key in ipairs{ "filter", "sort", "page", "order_ids", "help_seen" } do
        if changes[key] ~= nil then result[key] = changes[key] end
    end
    if changes.focused_comic_id ~= nil then result.focused_comic_id = changes.focused_comic_id end
    return Bookshelf.view(result, account_key)
end

function Bookshelf.order(items, snapshot)
    if not snapshot then return items end
    local by_id, result = {}, {}
    for _, comic in ipairs(items) do by_id[tostring(comic.id)] = comic end
    for _, id in ipairs(snapshot.order_ids) do
        if by_id[id] then result[#result + 1], by_id[id] = by_id[id], nil end
    end
    for _, comic in ipairs(items) do
        local id = tostring(comic.id)
        if by_id[id] then result[#result + 1], by_id[id] = comic, nil end
    end
    return result
end

return Bookshelf
