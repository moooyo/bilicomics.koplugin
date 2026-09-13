local Errors = require("bilicomics/protocol/errors")

local AuthCrypto = {}
AuthCrypto.__index = AuthCrypto

-- Public key embedded in the official wasm_rsa_encrypt_bg.wasm on 2026-09-13.
-- https://s1.hdslb.com/bfs/static/jinkela/long/wasm/wasm_rsa_encrypt_bg.wasm
local MODULUS_HEX =
    "cb81dd8e02470656da04dd38544446e2a3412051cfe9adc6a330a5ef902285096849" ..
    "60970b91c3360ca29c49e1690ff8fa068cb9dfc6179d1e9585cb9424e847db1ef59f" ..
    "33e37dd4dca8ccfb7631ee9b4a92640d00c8204300152a0ab7cd802889d3445aec6" ..
    "9918fe6022b534912e7b095be3424dad1ba81145e969b533181f1"
local KEY_BYTES = #MODULUS_HEX / 2
local HASH_BYTES = 32
local BASE = 65536
local LIMBS = KEY_BYTES / 2
local MAX_TIMESTAMP = 9007199254740991
local primitives

local function fromHex(value)
    return (value:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end

local function toHex(value)
    return (value:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end

local function loadPrimitives()
    if primitives then return primitives end
    local hash_ok, sha = pcall(require, "ffi/sha2")
    local bit_ok, bit = pcall(require, "bit")
    if not hash_ok or type(sha) ~= "table" or type(sha.sha256) ~= "function"
        or not bit_ok or type(bit) ~= "table" or type(bit.bxor) ~= "function" then
        return nil, Errors.capability("auth_crypto", "SHA-256 and byte XOR are required for session refresh.")
    end
    primitives = { sha256 = sha.sha256, bxor = bit.bxor }
    return primitives
end

local function secureRandomBytes(length)
    local file = io.open("/dev/urandom", "rb")
    if not file then return nil end
    local read_ok, bytes = pcall(file.read, file, length)
    local close_ok, closed = pcall(file.close, file)
    if not read_ok or not close_ok or not closed then return nil end
    return bytes
end

local function timestampText(timestamp)
    if type(timestamp) == "number" then
        if timestamp ~= timestamp or timestamp < 0 or timestamp > MAX_TIMESTAMP
            or timestamp % 1 ~= 0 then return nil end
        if timestamp == 0 then return "0" end
        return string.format("%.0f", timestamp)
    end
    if type(timestamp) == "string" and #timestamp <= 16
        and (timestamp == "0" or timestamp:match("^[1-9]%d*$"))
        and tonumber(timestamp) <= MAX_TIMESTAMP then
        return timestamp
    end
end

local function sha256Bytes(value, crypto)
    local digest = crypto.sha256(value)
    assert(type(digest) == "string" and #digest == HASH_BYTES * 2 and not digest:find("[^a-fA-F0-9]"))
    return fromHex(digest)
end

local function xorBytes(left, right, crypto)
    local bytes = {}
    for i = 1, #left do
        bytes[i] = string.char(crypto.bxor(left:byte(i), right:byte(i)))
    end
    return table.concat(bytes)
end

local function mgf1(seed, length, crypto)
    local blocks = {}
    for counter = 0, math.ceil(length / HASH_BYTES) - 1 do
        local encoded = string.char(math.floor(counter / 16777216) % 256,
            math.floor(counter / 65536) % 256, math.floor(counter / 256) % 256, counter % 256)
        blocks[#blocks + 1] = sha256Bytes(seed .. encoded, crypto)
    end
    return table.concat(blocks):sub(1, length)
end

local function oaepEncode(message, seed, crypto)
    -- RSAES-OAEP with SHA-256, MGF1-SHA-256, and an empty label (RFC 8017).
    local padding = string.rep("\0", KEY_BYTES - #message - 2 * HASH_BYTES - 2)
    local db = sha256Bytes("", crypto) .. padding .. "\1" .. message
    local masked_db = xorBytes(db, mgf1(seed, KEY_BYTES - HASH_BYTES - 1, crypto), crypto)
    local masked_seed = xorBytes(seed, mgf1(masked_db, HASH_BYTES, crypto), crypto)
    return "\0" .. masked_seed .. masked_db
end

local function limbsFromBytes(bytes)
    local limbs = {}
    for i = 1, LIMBS do
        local at = #bytes - (i - 1) * 2
        limbs[i] = bytes:byte(at - 1) * 256 + bytes:byte(at)
    end
    return limbs
end

local modulus = limbsFromBytes(fromHex(MODULUS_HEX))

local function addMod(left, right)
    local sum, carry = left, 0
    for i = 1, LIMBS do
        local value = left[i] + right[i] + carry
        sum[i], carry = value % BASE, math.floor(value / BASE)
    end
    local subtract = carry ~= 0
    if not subtract then
        for i = LIMBS, 1, -1 do
            if sum[i] ~= modulus[i] then
                subtract = sum[i] > modulus[i]
                break
            elseif i == 1 then
                subtract = true
            end
        end
    end
    if subtract then
        local borrow = 0
        for i = 1, LIMBS do
            local value = sum[i] - modulus[i] - borrow
            borrow = value < 0 and 1 or 0
            sum[i] = value + borrow * BASE
        end
        -- Inputs are below n, so their sum is below 2n. When addition carries,
        -- this borrow cancels its extra limb and the result is still below n.
    end
    return sum
end

local function multiplyMod(left, right)
    local result, addend = {}, {}
    for i = 1, LIMBS do result[i], addend[i] = 0, left[i] end
    -- This is public-key arithmetic only. Sixteen-bit limbs keep every
    -- intermediate integer exact on LuaJIT's IEEE-754 doubles. Only the two
    -- private work arrays are mutated, including when left and right alias.
    for i = 1, LIMBS do
        local digit = right[i]
        for _ = 1, 16 do
            if digit % 2 == 1 then result = addMod(result, addend) end
            digit = math.floor(digit / 2)
            addend = addMod(addend, addend)
        end
    end
    return result
end

local function rsaEncrypt(encoded)
    local message = limbsFromBytes(encoded)
    local result = message
    -- The fixed public exponent is 65537 = 2^16 + 1.
    for _ = 1, 16 do result = multiplyMod(result, result) end
    result = multiplyMod(result, message)
    local bytes = {}
    for i = LIMBS, 1, -1 do
        bytes[#bytes + 1] = string.char(math.floor(result[i] / 256), result[i] % 256)
    end
    return table.concat(bytes)
end

function AuthCrypto.new(opts)
    opts = opts or {}
    local random_bytes = opts.random_bytes
    if random_bytes == nil then random_bytes = secureRandomBytes end
    return setmetatable({ random_bytes = random_bytes }, AuthCrypto)
end

function AuthCrypto:correspondPath(timestamp)
    local text = timestampText(timestamp)
    if not text then
        return nil, Errors.new("invalid_argument", "A non-negative integer millisecond timestamp is required.", {
            transmitted = false,
        })
    end
    local crypto, err = loadPrimitives()
    if not crypto then return nil, err end
    if type(self.random_bytes) ~= "function" then
        return nil, Errors.capability("secure_random", "A secure random source is required for session refresh.")
    end
    local random_ok, seed = pcall(self.random_bytes, HASH_BYTES)
    if not random_ok or type(seed) ~= "string" or #seed ~= HASH_BYTES then
        return nil, Errors.capability("secure_random", "Secure random bytes are unavailable for session refresh.")
    end
    local ok, result = pcall(function() return toHex(rsaEncrypt(oaepEncode("refresh_" .. text, seed, crypto))) end)
    if not ok or type(result) ~= "string" or #result ~= KEY_BYTES * 2 then
        return nil, Errors.new("crypto", "Session refresh path encryption failed.", { transmitted = false })
    end
    return result
end

return AuthCrypto
