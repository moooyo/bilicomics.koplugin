local sha2 = require("ffi/sha2")
local Codec = require("bilicomics/storage/codec")
local Util = {}
local sequence = 0
function Util.id(prefix)
    sequence = sequence + 1
    return (prefix or "task") .. "-" .. os.time() .. "-" .. sequence .. "-"
        .. sha2.sha256(tostring({}) .. tostring(sequence)):sub(1, 10)
end
function Util.hash(value) return sha2.sha256(type(value) == "string" and value or Codec.canonical(value)) end
function Util.copy(value) return Codec.copy(value) end
function Util.error(kind, message, fields)
    local err = { kind = kind, message = message, retryable = false }
    for key, value in pairs(fields or {}) do err[key] = value end
    return err
end
function Util.callback(callback, value, err)
    if callback then
        local ok, failure = pcall(callback, value, err)
        if not ok then require("logger").warn("BiliComics callback failed", tostring(failure):gsub("https?://%S+", "[URL]")) end
    end
end
function Util.guard(callback, fn)
    local ok, value, err = pcall(fn)
    if not ok then return Util.callback(callback, nil, Util.error("storage", "The operation could not be completed safely.")) end
    return Util.callback(callback, value, err)
end
return Util
