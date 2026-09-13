local Value = {}

function Value.error(kind, message, extra)
    local result = {kind = kind, message = message, retryable = false}
    for key, value in pairs(extra or {}) do result[key] = value end
    return result
end

function Value.copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = Value.copy(item) end
    return result
end

function Value.id(value)
    if type(value) ~= "string" and type(value) ~= "number" then return nil end
    local result = tostring(value)
    if result == "" or result:find("[%c]") then return nil end
    return result
end

function Value.amount(value)
    local result = tonumber(value)
    if not result or result ~= result or result < 0 or result == math.huge then return nil end
    return result
end

function Value.ids(values)
    if type(values) ~= "table" or #values == 0 then return nil end
    local result, seen = {}, {}
    for _, value in ipairs(values) do
        local id = Value.id(value)
        if not id or seen[id] then return nil end
        seen[id] = true
        result[#result + 1] = id
    end
    for key in pairs(values) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #result then return nil end
    end
    return result
end

-- Length-prefixed, sorted encoding provides collision-free structural equality.
-- This fingerprint is an integrity comparison, not a server idempotency key.
function Value.encode(value)
    local kind = type(value)
    if kind == "nil" then return "z" end
    if kind == "boolean" then return value and "t" or "f" end
    if kind == "number" then
        assert(value == value and math.abs(value) ~= math.huge, "Invalid fingerprint number")
        return "n" .. string.format("%.17g", value) .. ";"
    end
    if kind == "string" then return "s" .. #value .. ":" .. value end
    assert(kind == "table", "Unsupported fingerprint value")
    local keys, parts = {}, {"{"}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return Value.encode(a) < Value.encode(b) end)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = Value.encode(key)
        parts[#parts + 1] = Value.encode(value[key])
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

function Value.publicError(err, fallback)
    if type(err) ~= "table" then
        return Value.error(fallback or "internal", "The operation failed.")
    end
    -- Arbitrary transport exceptions and bodies may contain private request data.
    local messages = {
        authentication = "The session needs to be replaced.",
        capability = "The protocol adapter does not support this operation.",
        purchase_rejected = "The server rejected the purchase.",
        timeout = "The purchase response was not received in time.",
        connectivity = "The server could not be reached.",
    }
    local transmitted
    if type(err.transmitted) == "boolean" then transmitted = err.transmitted end
    return Value.error(err.kind or fallback or "internal", messages[err.kind] or "The operation failed.", {
        code = type(err.code) == "number" and err.code or nil,
        definitive = err.definitive == true,
        transmitted = transmitted,
    })
end

return Value
