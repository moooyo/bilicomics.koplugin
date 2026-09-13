local json = require("rapidjson")

local Codec = {}
local private_keys = {
    cookie = true, cookies = true, authorization = true, access_token = true,
    refresh_token = true, csrf_token = true, private_key = true, session = true,
    sessdata = true, bili_jct = true, signed_url = true,
}

function Codec.assertPublic(value, seen)
    if type(value) ~= "table" then return end
    seen = seen or {}
    assert(not seen[value], "Cyclic records cannot be persisted")
    seen[value] = true
    for key, child in pairs(value) do
        assert(type(key) ~= "string" or not private_keys[key:lower()],
            "Credentials cannot be persisted in ordinary state")
        Codec.assertPublic(child, seen)
    end
    seen[value] = nil
end

function Codec.encode(value)
    Codec.assertPublic(value)
    local encoded, err = json.encode(value)
    assert(encoded, err or "Record encoding failed")
    return encoded
end

function Codec.decode(value)
    local decoded, err = json.decode(value)
    assert(decoded, err or "Stored JSON is invalid")
    return decoded
end

function Codec.copy(value)
    return Codec.decode(Codec.encode(value))
end

function Codec.canonical(value)
    local kind = type(value)
    if kind ~= "table" then
        assert(kind == "string" or kind == "boolean" or kind == "number", "Invalid descriptor value")
        if kind == "number" then
            assert(value == value and math.abs(value) ~= math.huge, "Invalid descriptor number")
        end
        return json.encode(value)
    end
    local keys, count = {}, 0
    for key in pairs(value) do
        count = count + 1
        keys[#keys + 1] = key
    end
    if #value > 0 then
        assert(count == #value, "Sparse descriptor array")
        local parts = {}
        for i = 1, #value do parts[i] = Codec.canonical(value[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    table.sort(keys)
    local parts = {}
    for i, key in ipairs(keys) do
        assert(type(key) == "string", "Invalid descriptor object key")
        parts[i] = json.encode(key) .. ":" .. Codec.canonical(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

return Codec
