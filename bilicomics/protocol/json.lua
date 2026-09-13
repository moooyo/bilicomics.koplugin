local json = require("rapidjson")
local Errors = require("bilicomics/protocol/errors")

local JSON = {}

function JSON.encode(value)
    if type(value) == "table" and next(value) == nil then return "{}" end
    local ok, result = pcall(json.encode, value)
    if not ok or not result then
        return nil, Errors.new("invalid_request", "The request could not be encoded.", { transmitted = false })
    end
    return result
end

function JSON.decode(text)
    if type(text) ~= "string" then
        return nil, Errors.new("protocol", "The service returned an invalid response.")
    end
    local ok, result = pcall(json.decode, text)
    if not ok or type(result) ~= "table" then
        return nil, Errors.new("protocol", "The service returned invalid JSON.")
    end
    return result
end

function JSON.array(values)
    if json.array then return json.array(values or {}) end
    return values or {}
end

return JSON
