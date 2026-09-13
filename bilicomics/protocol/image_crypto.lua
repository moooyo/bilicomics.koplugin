local bit = require("bit")
local Errors = require("bilicomics/protocol/errors")

local ImageCrypto = {}

local MODULUS = 4294967296
local METADATA_LENGTH = 69
local MAX_IMAGE_BYTES = 16 * 1024 * 1024
local ENCRYPTED_PREFIX_BYTES = 25 * 1024
local VERSION_CONFIG = {
    [3] = { iv_start = 26, mode = "ctr" },
    [5] = { iv_start = 33, mode = "gcm" },
    [6] = { iv_start = 34, mode = "cbc" },
    [7] = { iv_start = 26, mode = "ctr" },
    [8] = { iv_start = 32, mode = "ctr" },
}

ImageCrypto.supported_versions = { 3, 5, 6, 7, 8 }

local function failure(code, message)
    return nil, Errors.new("crypto", message, {
        code = code,
        retryable = false,
        transmitted = false,
    })
end

local function loadBackends()
    local ecdh_ok, ecdh = pcall(require, "bilicomics/protocol/ecdh")
    local aes_ok, aes = pcall(require, "bilicomics/protocol/portable_crypto")
    if not ecdh_ok or type(ecdh.deriveSecret) ~= "function" then
        return nil, "The P-256 shared secret provider is unavailable."
    end
    if not aes_ok or type(aes.aes256EcbEncrypt) ~= "function"
        or type(aes.aes256EcbDecrypt) ~= "function"
        or type(aes.pbkdf2Sha512) ~= "function"
        or type(aes.aes256GcmDecrypt) ~= "function" then
        return nil, "The AES-256 encryption provider is unavailable."
    end
    local ecdh_capability = ecdh.capability()
    if not ecdh_capability.available then
        return nil, ecdh_capability.reason
    end
    local aes_capability = aes.capability()
    if not aes_capability.available then
        return nil, aes_capability.reason
    end
    return { ecdh = ecdh, aes = aes }
end

function ImageCrypto.available()
    local backends, reason = loadBackends()
    return backends ~= nil, reason
end

function ImageCrypto.capability()
    local available, reason = ImageCrypto.available()
    return {
        available = available,
        provider = "portable_image_crypto",
        versions = ImageCrypto.supported_versions,
        reason = reason,
        error = not available and Errors.capability("image_conversion", reason) or nil,
    }
end

local function percentDecode(value)
    if value:find("%%[^%x]") or value:find("%%.$") or value:find("%%$")
        or value:find("%%%x[^%x]") then
        return nil
    end
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function queryDecode(value)
    return percentDecode((value:gsub("%+", " ")))
end

local function parseParameters(url, version)
    if type(url) ~= "string" or #url > 16384 or url:find("[%z\r\n]")
        or not url:match("^https?://[^/?#]+") then
        return failure("invalid_image_url", "The image URL is invalid.")
    end
    local query = url:match("^[^#]*"):match("%?([^#]*)")
    if not query then
        return failure("missing_image_parameters", "The image URL has no encryption parameters.")
    end
    local parameters = {}
    for pair in query:gmatch("[^&]+") do
        local name, value = pair:match("^([^=]*)=(.*)$")
        if not name then name, value = pair, "" end
        name, value = queryDecode(name), queryDecode(value)
        if not name or not value or pair:find(";", 1, true) then
            return failure("invalid_image_parameters", "The image URL query is malformed.")
        end
        if parameters[name] == nil then parameters[name] = value end
    end
    local timestamp = parameters.ts
    if version == 8 and (type(timestamp) ~= "string" or #timestamp == 0
        or #timestamp > 16 or timestamp:find("[^%x]")
        or (#timestamp == 16 and tonumber(timestamp:sub(1, 1), 16) > 7)) then
        return failure("invalid_image_timestamp", "The image timestamp must be a nonnegative hexadecimal int64.")
    end
    local encoded = parameters.cpx
    -- Legacy JS calls decodeURIComponent after URLSearchParams has decoded it.
    if version ~= 8 and type(encoded) == "string" then encoded = percentDecode(encoded) end
    if type(encoded) ~= "string" or #encoded == 0 or #encoded > 4096
        or #encoded % 4 ~= 0 or encoded:find("[^A-Za-z0-9+/=]") then
        return failure("invalid_image_parameters", "The image encryption parameters are not valid Base64.")
    end
    local mime_ok, mime = pcall(require, "mime")
    if not mime_ok then
        return nil, Errors.capability("image_conversion", "The Base64 codec is unavailable.")
    end
    local decoded = mime.unb64(encoded)
    local iv_start = VERSION_CONFIG[version].iv_start
    local minimum_length = version == 5 and 64 or iv_start + 15
    if type(decoded) ~= "string" or mime.b64(decoded) ~= encoded or #decoded < minimum_length then
        return failure("invalid_image_parameters", "The image encryption parameters are malformed or truncated.")
    end
    -- Only the low 32 bits affect the documented LCG, even for int64 timestamps.
    return {
        timestamp = version == 8 and tonumber(timestamp:sub(-8), 16) or nil,
        iv = decoded:sub(iv_start, iv_start + 15),
        salt = version == 5 and decoded:sub(49, 64) or nil,
    }
end

local function unpackContainer(bytes, timestamp, version)
    if version ~= 8 then
        if #bytes < 71 then
            return failure("truncated_image_container", "The image container is too short.")
        end
        local a, b, c, d = bytes:byte(2, 5)
        local length = ((a * 256 + b) * 256 + c) * 256 + d
        if length <= 0 or length + 70 ~= #bytes then
            return failure("invalid_image_length", "The declared image payload length is invalid.")
        end
        local public_key = bytes:sub(length + 6)
        if public_key:byte(1) ~= 4 then
            return failure("invalid_image_public_key", "The image container has an invalid P-256 public key.")
        end
        return { payload = bytes:sub(6, length + 5), public_key = public_key }
    end
    local payload_length = #bytes - METADATA_LENGTH - 1
    if payload_length < METADATA_LENGTH then
        return failure("truncated_image_container", "The image container is too short.")
    end
    local state = (timestamp - payload_length - METADATA_LENGTH) % MODULUS
    local positions, seen = {}, {}
    -- The official format samples unique positions, then sorts the complete set.
    while #positions < METADATA_LENGTH do
        state = (state * 1664525 + 1013904223) % MODULUS
        local position = math.floor(state / MODULUS * payload_length)
        if not seen[position] then
            positions[#positions + 1] = position
            seen[position] = true
        end
    end
    table.sort(positions)
    local public_key, payload, previous = {}, {}, 2
    for index, position in ipairs(positions) do
        local offset = position + 2
        payload[#payload + 1] = bytes:sub(previous, offset - 1)
        if index > 4 then
            public_key[#public_key + 1] = bytes:sub(offset, offset)
        end
        previous = offset + 1
    end
    payload[#payload + 1] = bytes:sub(previous)
    public_key = table.concat(public_key)
    if #public_key ~= 65 or public_key:byte(1) ~= 4 then
        return failure("invalid_image_public_key", "The image container has an invalid P-256 public key.")
    end
    return { payload = table.concat(payload), public_key = public_key }
end

local function decryptPrefix(aes, key, iv, payload, counter_start)
    local length = math.min(#payload, ENCRYPTED_PREFIX_BYTES)
    local counter, blocks = { iv:byte(1, 16) }, {}
    for _ = 1, math.ceil(length / 16) do
        blocks[#blocks + 1] = string.char(unpack(counter))
        for index = 16, counter_start, -1 do
            counter[index] = (counter[index] + 1) % 256
            if counter[index] ~= 0 then break end
        end
    end
    local stream, err = aes.aes256EcbEncrypt(key, table.concat(blocks))
    if not stream then return nil, err end
    if #stream ~= #blocks * 16 then
        return failure("invalid_aes_output", "The AES provider returned an invalid output length.")
    end
    local plaintext = {}
    for index = 1, length do
        plaintext[index] = string.char(bit.bxor(payload:byte(index), stream:byte(index)))
    end
    return table.concat(plaintext) .. payload:sub(length + 1)
end

local function decryptCbcPrefix(aes, key, iv, payload)
    if type(aes.aes256EcbDecrypt) ~= "function" then
        return nil, Errors.capability("image_conversion", "The AES-256 CBC provider is unavailable.")
    end
    local length = math.min(#payload, 21 * 1024 + 16)
    if length == 0 or length % 16 ~= 0 then
        return failure("invalid_cbc_length", "The encrypted image prefix is not a whole number of AES blocks.")
    end
    local ciphertext = payload:sub(1, length)
    local decoded, err = aes.aes256EcbDecrypt(key, ciphertext)
    if not decoded then return nil, err end
    if #decoded ~= length then
        return failure("invalid_aes_output", "The AES provider returned an invalid output length.")
    end
    local plaintext, previous = {}, iv
    for offset = 1, length, 16 do
        for index = 0, 15 do
            plaintext[offset + index] = string.char(bit.bxor(decoded:byte(offset + index), previous:byte(index + 1)))
        end
        previous = ciphertext:sub(offset, offset + 15)
    end
    plaintext = table.concat(plaintext)
    local padding = plaintext:byte(-1)
    if not padding or padding < 1 or padding > 16
        or plaintext:sub(-padding) ~= string.rep(string.char(padding), padding) then
        return failure("invalid_image_padding", "The encrypted image has invalid PKCS#7 padding.")
    end
    return plaintext:sub(1, #plaintext - padding) .. payload:sub(length + 1)
end

local function decryptGcmPrefix(aes, secret, parameters, payload)
    local length = math.min(#payload, 30 * 1024 + 16)
    if length < 16 then
        return failure("invalid_gcm_length", "The encrypted image is missing its GCM authentication tag.")
    end
    local key, err = aes.pbkdf2Sha512(secret, parameters.salt, 100000, 32)
    if not key then return nil, err end
    if type(key) ~= "string" or #key ~= 32 then
        return failure("invalid_derived_key", "The PBKDF2 provider returned an invalid key.")
    end
    local plaintext
    plaintext, err = aes.aes256GcmDecrypt(key, parameters.iv, parameters.salt, payload:sub(1, length))
    if not plaintext then return nil, err end
    if #plaintext ~= length - 16 then
        return failure("invalid_aes_output", "The GCM provider returned an invalid output length.")
    end
    return plaintext .. payload:sub(length + 1)
end

-- Inputs and the shared secret are transient. This converter never performs
-- network calls or sends the official WASM module's optional telemetry.
function ImageCrypto.convert(private_key, bytes, url, index)
    if type(bytes) ~= "string" or #bytes > MAX_IMAGE_BYTES or #bytes == 0 then
        return failure("invalid_image_container", "The image container is empty or exceeds the size limit.")
    end
    local version = bytes:byte(1)
    if not VERSION_CONFIG[version] then
        return nil, Errors.capability("image_conversion", "This image container version is not supported.")
    end
    if type(private_key) ~= "string" or #private_key == 0 or #private_key > 1024 then
        return failure("invalid_image_private_key", "The transient image private key is invalid.")
    end
    if index ~= nil and (type(index) ~= "number" or index < 0
        or index > 2147483647 or index ~= math.floor(index)) then
        return failure("invalid_image_index", "The image index must be a nonnegative integer.")
    end
    local parameters, err = parseParameters(url, version)
    if not parameters then return nil, err end
    local container
    container, err = unpackContainer(bytes, parameters.timestamp, version)
    if not container then return nil, err end
    local backends, reason = loadBackends()
    if not backends then return nil, Errors.capability("image_conversion", reason) end
    local key
    key, err = backends.ecdh.deriveSecret(private_key, container.public_key)
    if not key then return nil, err end
    if type(key) ~= "string" or #key ~= 32 then
        return failure("invalid_shared_secret", "The P-256 provider returned an invalid shared secret.")
    end
    if VERSION_CONFIG[version].mode == "cbc" then
        return decryptCbcPrefix(backends.aes, key, parameters.iv, container.payload)
    elseif VERSION_CONFIG[version].mode == "gcm" then
        return decryptGcmPrefix(backends.aes, key, parameters, container.payload)
    end
    -- The Go version uses a 128-bit counter; legacy WebCrypto uses 64 bits.
    return decryptPrefix(backends.aes, key, parameters.iv, container.payload, version == 8 and 1 or 9)
end

return ImageCrypto
