local Normalize = {}

local private_fields = {
    cookie = true, cookies = true, sessdata = true, bili_jct = true, token = true,
    private_key = true, privatekey = true, complete_url = true, ultra_sign = true,
    bytesdata = true, m1 = true, m2 = true,
    refresh_token = true, pending_refresh_token = true, refresh_csrf = true, qrcode_key = true, longtoken = true,
}

function Normalize.safeExtra(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do
        local lower = tostring(key):lower()
        if not private_fields[lower] then
            if type(item) == "string" and item:find("[?&]token=") then
                -- Temporary acquisition credentials do not belong in catalog snapshots.
            else result[key] = Normalize.safeExtra(item, seen) end
        end
    end
    seen[value] = nil
    return result
end

local function boolean(value)
    if value == nil then return nil end
    return value == true or value == 1 or value == "1"
end

local function first(...)
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if value ~= nil then return value end
    end
end

function Normalize.access(raw, now)
    local pay_mode = tonumber(raw.pay_mode)
    local unlock_type = tonumber(raw.unlock_type)
    local raw_expiry = raw.unlock_expire_at or raw.expires_at
    -- The catalog uses this exact zero date for an entitlement without expiry.
    local expiry = raw_expiry == "0000-00-00 00:00:00" and 0 or tonumber(raw_expiry)
    local unknown_expiry = raw_expiry ~= nil and raw_expiry ~= "" and not expiry
    if raw.unavailable == true or raw.is_available == false or tonumber(raw.status) == 501 then return "unavailable", expiry end
    if boolean(raw.is_locked) == true then return "locked", expiry end
    if unlock_type == 2 or unlock_type == 3 then
        if unknown_expiry then return "unknown", nil end
        if expiry and expiry > 0 and expiry <= (now or os.time()) then return "locked", expiry end
        return "temporary", expiry
    end
    if unlock_type == 1 or boolean(raw.is_purchased) == true then
        if unknown_expiry then return "unknown", nil end
        if expiry and expiry > 0 then
            return expiry <= (now or os.time()) and "locked" or "temporary", expiry
        end
        return "owned", expiry
    end
    if pay_mode == 0 then return "free", expiry end
    -- An unlocked flag alone does not establish permanent ownership.
    if boolean(raw.is_in_free) == true then return "temporary", expiry end
    return "unknown", expiry
end

function Normalize.comic(raw)
    raw = raw or {}
    return {
        id = tostring(raw.comic_id or raw.id or raw.season_id or ""),
        title = raw.title or raw.comic_title or "",
        authors = raw.author_name or raw.authors or raw.author_names,
        cover_url = raw.vertical_cover or raw.vcover or raw.hcover or raw.cover or raw.cover_url,
        latest_episode_id = raw.latest_ep_id and tostring(raw.latest_ep_id) or nil,
        latest_order = tonumber(raw.latest_ord or raw.latest_order),
        favorite = boolean(first(raw.is_fav, raw.is_favorite)),
        finished = boolean(first(raw.is_finish, raw.finished)),
        updated_at = raw.last_update_time or raw.update_time,
        extra = Normalize.safeExtra(raw),
    }
end

function Normalize.episode(raw, comic_id, now)
    local access, expiry = Normalize.access(raw, now)
    return {
        id = tostring(raw.id or raw.ep_id or raw.episode_id or ""),
        comic_id = tostring(raw.comic_id or comic_id or ""),
        order = tonumber(raw.ord or raw.order) or 0,
        title = raw.title or raw.ep_title or "",
        short_title = raw.short_title or raw.ep_short_title,
        access = access, expires_at = expiry, pay_gold = tonumber(raw.pay_gold),
        read = boolean(first(raw.is_read, raw.read)), extra = Normalize.safeExtra(raw),
    }
end

function Normalize.comicList(data)
    local items = data.list or data.comics or data.result or data
    if type(items) ~= "table" then return nil end
    local result = {}
    for _, raw in ipairs(items) do
        if type(raw) == "table" then result[#result + 1] = Normalize.comic(raw) end
    end
    return result
end

return Normalize
