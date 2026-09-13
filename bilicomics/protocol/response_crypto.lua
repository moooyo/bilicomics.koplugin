local bit = require("bit")
local ffi = require("ffi")
local json = require("rapidjson")
local Errors = require("bilicomics/protocol/errors")

local ResponseCrypto = {}

local endpoint_fields = {
    ["/comic.v1.Comic/ComicDetail"] = "comic_id",
    ["/comic.v1.Comic/GetImageIndex"] = "ep_id",
    ["/comic.v1.Comic/ClassPage"] = "style_id",
    ["/comic.v1.Comic/ImageToken"] = "urls",
}

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local base64_values = {}
for index = 1, #alphabet do
    base64_values[alphabet:sub(index, index)] = index - 1
end

local function failure(code, message, kind)
    return nil, Errors.new(kind or "protocol", message, {
        code = code,
        retryable = false,
        capability = kind == "capability" and "response_decoding" or nil,
    })
end

local function valid_utf8(value)
    local index = 1
    while index <= #value do
        local first = value:byte(index)
        local count, lower, upper
        if first < 0x80 then
            count = 1
        elseif first >= 0xC2 and first <= 0xDF then
            count, lower, upper = 2, 0x80, 0xBF
        elseif first >= 0xE0 and first <= 0xEF then
            count = 3
            lower = first == 0xE0 and 0xA0 or 0x80
            upper = first == 0xED and 0x9F or 0xBF
        elseif first >= 0xF0 and first <= 0xF4 then
            count = 4
            lower = first == 0xF0 and 0x90 or 0x80
            upper = first == 0xF4 and 0x8F or 0xBF
        else
            return false
        end
        if index + count - 1 > #value then return false end
        if count > 1 then
            local second = value:byte(index + 1)
            if second < lower or second > upper then return false end
            for offset = 2, count - 1 do
                local byte = value:byte(index + offset)
                if byte < 0x80 or byte > 0xBF then return false end
            end
        end
        index = index + count
    end
    return true
end

local function decode_base64(value)
    if type(value) ~= "string" or #value == 0 or #value % 4 ~= 0 then
        return failure("invalid_base64", "Encrypted response must contain padded Base64.")
    end
    local output = {}
    for index = 1, #value, 4 do
        local a, b, c, d = value:sub(index, index), value:sub(index + 1, index + 1),
            value:sub(index + 2, index + 2), value:sub(index + 3, index + 3)
        local av, bv, cv, dv = base64_values[a], base64_values[b], base64_values[c], base64_values[d]
        if not av or not bv then return failure("invalid_base64", "Invalid Base64 alphabet.") end
        if c == "=" then
            if d ~= "=" or index + 3 ~= #value or bv % 16 ~= 0 then
                return failure("invalid_base64", "Invalid Base64 padding.")
            end
            output[#output + 1] = string.char(av * 4 + math.floor(bv / 16))
        elseif not cv then
            return failure("invalid_base64", "Invalid Base64 alphabet.")
        elseif d == "=" then
            if index + 3 ~= #value or cv % 4 ~= 0 then
                return failure("invalid_base64", "Invalid Base64 padding.")
            end
            output[#output + 1] = string.char(av * 4 + math.floor(bv / 16), (bv % 16) * 16 + math.floor(cv / 4))
        elseif not dv then
            return failure("invalid_base64", "Invalid Base64 alphabet.")
        else
            output[#output + 1] = string.char(av * 4 + math.floor(bv / 16), (bv % 16) * 16 + math.floor(cv / 4), (cv % 4) * 64 + dv)
        end
    end
    return table.concat(output)
end

local function parse_object(value, description)
    if type(value) ~= "string" or not valid_utf8(value) then
        return failure("invalid_utf8", description .. " is not valid UTF-8.")
    end
    local ok, result = pcall(json.decode, value)
    if not ok or type(result) ~= "table" then
        return failure("invalid_json", description .. " must be a JSON object or array.")
    end
    return result
end

local function normalize_path(context)
    local value = context.url or context.path or context.endpoint
    if type(value) ~= "string" or value:find("[%z\r\n]") then return nil end
    if value:match("^https?://") then
        value = value:match("^https?://[^/]+(/.*)$")
        if not value then return nil end
    elseif not value:match("^/") then
        value = "/comic.v1.Comic/" .. value
    end
    value = value:match("^[^?#]*")
    value = value:gsub("^/twirp/", "/")
    return endpoint_fields[value] and value or nil
end

function ResponseCrypto.deriveKey(context)
    if type(context) ~= "table" then return failure("invalid_context", "Response context is required.") end
    local path = normalize_path(context)
    if not path then return failure("unsupported_endpoint", "Encrypted response endpoint is unsupported.") end
    local platform = context.platform or "web"
    if platform ~= "web" then
        return failure("unsupported_platform", "Only the verified web response contract is supported.", "capability")
    end
    local buvid = context.buvid or ""
    if type(buvid) ~= "string" or buvid:find("[^\x20-\x7E]") then
        return failure("invalid_buvid", "Response buvid must be an ASCII string.")
    end
    local body, err = parse_object(context.body or context.body_json, "Request body")
    if not body then return nil, err end
    local selected = body[endpoint_fields[path]]
    local suffix = ""
    if selected ~= nil and selected ~= json.null then
        if type(selected) == "number" then
            if selected ~= math.floor(selected) or math.abs(selected) >= 9007199254740992 then
                return failure("invalid_key_field", "Response key field must be an exact integer or string.")
            end
            suffix = string.format("%.0f", selected)
        elseif type(selected) == "string" and not selected:find("[^\x20-\x7E]") then
            suffix = selected
        else
            return failure("invalid_key_field", "Response key field must be an ASCII string or exact integer.")
        end
    end
    local even_bytes = {}
    for index = 1, math.min(#buvid, 36), 2 do
        even_bytes[#even_bytes + 1] = buvid:sub(index, index)
    end
    local key = table.concat(even_bytes) .. platform .. suffix:sub(-3)
    return key .. string.rep("=", 24 - #key)
end

function ResponseCrypto.available()
    local ok, crypto = pcall(require, "ffi/crypto")
    if not ok then return false, "KOReader's bundled crypto binding is unavailable." end
    local supported, cipher = pcall(crypto.get_aes_ecb_cipher, 24)
    if supported and cipher ~= nil then return true end
    return false, "AES-192-ECB is unavailable."
end

function ResponseCrypto.decrypt(context, encoded)
    local key, err = ResponseCrypto.deriveKey(context)
    if not key then return nil, err end
    local ciphertext
    ciphertext, err = decode_base64(encoded)
    if not ciphertext then return nil, err end
    if #ciphertext % 16 ~= 0 then
        return failure("invalid_ciphertext", "Encrypted response length is not a multiple of the AES block size.")
    end
    local ok, crypto = pcall(require, "ffi/crypto")
    if not ok then return failure("crypto_unavailable", "KOReader's crypto binding is unavailable.", "capability") end
    local succeeded, decoded, length = pcall(function()
        return crypto.evp_decrypt(crypto.get_aes_ecb_cipher(24), ciphertext, key, nil)
    end)
    if not succeeded or not decoded or length ~= #ciphertext then
        return failure("decrypt_failed", "AES-192 response decryption failed.")
    end

    -- CBC is assembled over KOReader's existing ECB export, including monolibtic builds.
    local previous, plaintext = key:sub(1, 16), {}
    local bytes = ffi.cast("const uint8_t*", decoded)
    for offset = 0, length - 1, 16 do
        local block = {}
        for index = 1, 16 do
            block[index] = string.char(bit.bxor(tonumber(bytes[offset + index - 1]), previous:byte(index)))
        end
        plaintext[#plaintext + 1] = table.concat(block)
        previous = ciphertext:sub(offset + 1, offset + 16)
    end
    plaintext = table.concat(plaintext)
    local padding = plaintext:byte(-1)
    if not padding or padding < 1 or padding > 16 or plaintext:sub(-padding) ~= string.rep(string.char(padding), padding) then
        return failure("invalid_padding", "Encrypted response contains invalid PKCS#7 padding.")
    end
    return parse_object(plaintext:sub(1, #plaintext - padding), "Decrypted response data")
end

function ResponseCrypto.decode(context, envelope)
    if type(envelope) ~= "table" then return failure("invalid_envelope", "Response envelope must be an object.") end
    if envelope.code ~= 0 then return envelope end
    if envelope.bytesData == nil or envelope.bytesData == json.null then
        if type(envelope.data) ~= "table" then
            return failure("missing_response_data", "Successful response is missing object data.")
        end
        return envelope
    end
    local data, err = ResponseCrypto.decrypt(context, envelope.bytesData)
    if not data then return nil, err end
    local result = {}
    for name, value in pairs(envelope) do
        if name ~= "bytesData" then result[name] = value end
    end
    result.data = data
    return result
end

return ResponseCrypto
