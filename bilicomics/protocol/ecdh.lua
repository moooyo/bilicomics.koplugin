local Errors = require("bilicomics/protocol/errors")
local Json = require("bilicomics/protocol/json")

local ECDH = {}
local backend
local backend_checked = false
local backend_reason

local declarations = [[
typedef struct ec_key_st bcm_ec_key;
typedef struct ec_group_st bcm_ec_group;
typedef struct ec_point_st bcm_ec_point;
typedef struct bignum_st bcm_bignum;
typedef struct bignum_ctx bcm_bn_ctx;
int OBJ_txt2nid(const char *s);
bcm_ec_key *EC_KEY_new_by_curve_name(int nid);
void EC_KEY_free(bcm_ec_key *key);
int EC_KEY_generate_key(bcm_ec_key *key);
int EC_KEY_check_key(const bcm_ec_key *key);
const bcm_ec_group *EC_KEY_get0_group(const bcm_ec_key *key);
const bcm_ec_point *EC_KEY_get0_public_key(const bcm_ec_key *key);
const bcm_bignum *EC_KEY_get0_private_key(const bcm_ec_key *key);
int EC_KEY_set_private_key(bcm_ec_key *key, const bcm_bignum *prv);
int EC_KEY_set_public_key(bcm_ec_key *key, const bcm_ec_point *pub);
size_t EC_POINT_point2oct(const bcm_ec_group *group, const bcm_ec_point *p,
    int form, unsigned char *buf, size_t len, bcm_bn_ctx *ctx);
bcm_ec_point *EC_POINT_new(const bcm_ec_group *group);
void EC_POINT_free(bcm_ec_point *point);
int EC_POINT_oct2point(const bcm_ec_group *group, bcm_ec_point *point,
    const unsigned char *buf, size_t len, bcm_bn_ctx *ctx);
int EC_POINT_is_on_curve(const bcm_ec_group *group, const bcm_ec_point *point,
    bcm_bn_ctx *ctx);
int EC_POINT_is_at_infinity(const bcm_ec_group *group, const bcm_ec_point *point);
int ECDH_compute_key(void *out, size_t outlen, const bcm_ec_point *pub_key,
    const bcm_ec_key *ecdh,
    void *(*kdf)(const void *in, size_t inlen, void *out, size_t *outlen));
int BN_bn2binpad(const bcm_bignum *a, unsigned char *to, int tolen);
bcm_bignum *BN_bin2bn(const unsigned char *s, int len, bcm_bignum *ret);
void BN_clear_free(bcm_bignum *a);
]]

local required_symbols = {
    "OBJ_txt2nid", "EC_KEY_new_by_curve_name", "EC_KEY_free",
    "EC_KEY_generate_key", "EC_KEY_check_key", "EC_KEY_get0_group",
    "EC_KEY_get0_public_key", "EC_KEY_get0_private_key",
    "EC_KEY_set_private_key", "EC_KEY_set_public_key",
    "EC_POINT_point2oct", "EC_POINT_new", "EC_POINT_free",
    "EC_POINT_oct2point", "EC_POINT_is_on_curve", "EC_POINT_is_at_infinity",
    "ECDH_compute_key", "BN_bn2binpad", "BN_bin2bn", "BN_clear_free",
}

local function getBackend()
    if backend_checked then
        return backend, backend_reason
    end
    backend_checked = true
    local ok, ffi = pcall(require, "ffi")
    if not ok then
        backend_reason = "LuaJIT FFI is unavailable."
        return nil, backend_reason
    end
    local codec_ok, mime = pcall(require, "mime")
    if not codec_ok or type(mime.b64) ~= "function" or type(mime.unb64) ~= "function" then
        backend_reason = "The KOReader Base64 codec is unavailable."
        return nil, backend_reason
    end
    local declared = pcall(ffi.cdef, declarations)
    if type(ffi.loadlib) ~= "function" then
        pcall(require, "ffi/loadlib")
    end
    if declared and type(ffi.loadlib) == "function" then
        local loaded, lib = pcall(ffi.loadlib, "crypto", "57")
        if loaded then
            for _, name in ipairs(required_symbols) do
                local found, value = pcall(function() return lib[name] end)
                if not found or value == nil then
                    backend_reason = "The KOReader libcrypto library does not export " .. name .. "."
                    lib = nil
                    break
                end
            end
            if lib then
                local nid = lib.OBJ_txt2nid("prime256v1")
                if nid > 0 then
                    backend = { ffi = ffi, lib = lib, mime = mime, nid = nid, provider = "libcrypto" }
                    return backend
                end
                backend_reason = "The KOReader libcrypto library does not support P-256."
            end
        else
            backend_reason = "The KOReader libcrypto library is unavailable."
        end
    else
        backend_reason = "The KOReader P-256 native binding is unavailable."
    end

    local module_ok, portable = pcall(require, "bilicomics/protocol/portable_crypto")
    if module_ok and type(portable) == "table" and type(portable.library) == "function" then
        local loaded, lib, reason = pcall(portable.library)
        if loaded and lib then
            for _, name in ipairs({ "bili_p256_new", "bili_p256_public", "bili_p256_derive" }) do
                local found, value = pcall(function() return lib[name] end)
                if not found or value == nil then
                    lib = nil
                    reason = "The portable P-256 library does not export " .. name .. "."
                    break
                end
            end
            if lib then
                backend = { ffi = ffi, lib = lib, mime = mime, provider = "libbilicrypto" }
                return backend
            end
        end
        if type(reason) == "string" then backend_reason = backend_reason .. " " .. reason end
    end
    return nil, backend_reason
end

local function cryptoError(message)
    return Errors.new("crypto", message, { transmitted = false })
end

local function availableBackend()
    local native, reason = getBackend()
    if not native then
        return nil, Errors.capability("image_key_exchange", reason)
    end
    return native
end

function ECDH.capability()
    local native, reason = getBackend()
    if native then
        return { available = true, provider = native.provider, curve = "P-256" }
    end
    return {
        available = false,
        provider = "libcrypto",
        reason = reason,
        error = Errors.capability("image_key_exchange", reason),
    }
end

local function encodeBase64(native, value)
    return (native.mime.b64(value))
end

local function decodeBase64(native, value, limit)
    if type(value) ~= "string" or #value == 0 or #value > limit or #value % 4 ~= 0
        or value:find("[^A-Za-z0-9+/=]") then
        return nil
    end
    local decoded = native.mime.unb64(value)
    if type(decoded) ~= "string" or encodeBase64(native, decoded) ~= value then
        return nil
    end
    return decoded
end

local function encodeBase64Url(native, value)
    return (encodeBase64(native, value):gsub("%+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

local function decodeCoordinate(native, value)
    if type(value) ~= "string" or #value ~= 43 or value:find("[^A-Za-z0-9_-]") then
        return nil
    end
    local decoded = decodeBase64(native, value:gsub("%-", "+"):gsub("_", "/") .. "=", 44)
    if not decoded or #decoded ~= 32 then
        return nil
    end
    return decoded
end

local function closeHandle(native, handle, free)
    if handle ~= nil then
        native.ffi.gc(handle, nil)
        free(handle)
    end
end

local function createJwk(native, raw, scalar)
    -- These values use the same encodings as WebCrypto's private JWK export.
    local x = encodeBase64Url(native, raw:sub(2, 33))
    local y = encodeBase64Url(native, raw:sub(34, 65))
    local d = encodeBase64Url(native, scalar)
    return string.format(
        '{"key_ops":["deriveKey","deriveBits"],"ext":true,"kty":"EC","x":"%s","y":"%s","crv":"P-256","d":"%s"}',
        x, y, d)
end

-- Return only strings. Keep this object in transient worker messages; never
-- persist it in a database, descriptor, job journal, settings file, or log.
function ECDH.newKey()
    local native, err = availableBackend()
    if not native then
        return nil, err
    end
    local ffi, lib = native.ffi, native.lib
    if native.provider == "libbilicrypto" then
        local scalar, public = ffi.new("unsigned char[32]"), ffi.new("unsigned char[65]")
        local ok, result = pcall(function()
            if lib.bili_p256_new(scalar, public) ~= 1 or public[0] ~= 4 then return nil end
            local raw = ffi.string(public, 65)
            return {
                m1 = encodeBase64(native, raw),
                private_key = encodeBase64(native, createJwk(native, raw, ffi.string(scalar, 32))),
            }
        end)
        ffi.fill(scalar, 32, 0)
        if not ok or not result then
            return nil, cryptoError("Could not generate or export a P-256 key.")
        end
        return result
    end
    local key = lib.EC_KEY_new_by_curve_name(native.nid)
    if key == nil then
        return nil, cryptoError("Could not allocate a P-256 key.")
    end
    key = ffi.gc(key, lib.EC_KEY_free)
    local scalar = ffi.new("unsigned char[32]")
    local ok, result = pcall(function()
        if lib.EC_KEY_generate_key(key) ~= 1 or lib.EC_KEY_check_key(key) ~= 1 then
            return nil
        end
        local raw = ffi.new("unsigned char[65]")
        if lib.EC_POINT_point2oct(lib.EC_KEY_get0_group(key), lib.EC_KEY_get0_public_key(key),
            4, raw, 65, nil) ~= 65 or raw[0] ~= 4 then
            return nil
        end
        if lib.BN_bn2binpad(lib.EC_KEY_get0_private_key(key), scalar, 32) ~= 32 then
            return nil
        end
        local public_bytes = ffi.string(raw, 65)
        local private_json = createJwk(native, public_bytes, ffi.string(scalar, 32))
        return {
            m1 = encodeBase64(native, public_bytes),
            private_key = encodeBase64(native, private_json),
        }
    end)
    ffi.fill(scalar, 32, 0)
    closeHandle(native, key, lib.EC_KEY_free)
    if not ok or not result then
        return nil, cryptoError("Could not generate or export a P-256 key.")
    end
    return result
end

local function checkFields(value, allowed)
    if type(value) ~= "table" then
        return false
    end
    for name in pairs(value) do
        if not allowed[name] then
            return false
        end
    end
    return true
end

local function decodePrivateKey(native, value)
    local private_json = decodeBase64(native, value, 1024)
    if not private_json then return nil end
    local jwk = Json.decode(private_json)
    if not checkFields(jwk, { key_ops = true, ext = true, kty = true, crv = true, x = true, y = true, d = true })
        or jwk.ext ~= true or jwk.kty ~= "EC" or jwk.crv ~= "P-256"
        or not checkFields(jwk.key_ops, { [1] = true, [2] = true })
        or not ((jwk.key_ops[1] == "deriveKey" and jwk.key_ops[2] == "deriveBits")
            or (jwk.key_ops[1] == "deriveBits" and jwk.key_ops[2] == "deriveKey")) then
        return nil
    end
    local x, y, d = decodeCoordinate(native, jwk.x), decodeCoordinate(native, jwk.y), decodeCoordinate(native, jwk.d)
    if not x or not y or not d then return nil end
    return { raw = "\004" .. x .. y, scalar = d }
end

local function importPrivateKey(native, material)
    local ffi, lib = native.ffi, native.lib
    local key, point, number, scalar
    local ok, valid = pcall(function()
        key = lib.EC_KEY_new_by_curve_name(native.nid)
        if key == nil then return false end
        key = ffi.gc(key, lib.EC_KEY_free)
        local group = lib.EC_KEY_get0_group(key)
        point = lib.EC_POINT_new(group)
        if point == nil then return false end
        point = ffi.gc(point, lib.EC_POINT_free)
        scalar = ffi.new("unsigned char[32]")
        ffi.copy(scalar, material.scalar, 32)
        number = lib.BN_bin2bn(scalar, 32, nil)
        if number == nil then return false end
        number = ffi.gc(number, lib.BN_clear_free)
        return lib.EC_POINT_oct2point(group, point, material.raw, 65, nil) == 1
            and lib.EC_KEY_set_public_key(key, point) == 1
            and lib.EC_KEY_set_private_key(key, number) == 1
            and lib.EC_KEY_check_key(key) == 1
    end)
    if scalar then ffi.fill(scalar, 32, 0) end
    closeHandle(native, number, lib.BN_clear_free)
    closeHandle(native, point, lib.EC_POINT_free)
    if ok and valid then return key end
    closeHandle(native, key, lib.EC_KEY_free)
    return nil
end

local function validatePortablePair(native, material)
    local ffi, lib = native.ffi, native.lib
    local scalar, public = ffi.new("unsigned char[32]"), ffi.new("unsigned char[65]")
    ffi.copy(scalar, material.scalar, 32)
    local ok, valid = pcall(function()
        return lib.bili_p256_public(scalar, public) == 1 and ffi.string(public, 65) == material.raw
    end)
    ffi.fill(scalar, 32, 0)
    return ok and valid
end

local function validateKey(native, value)
    if not checkFields(value, { m1 = true, private_key = true }) then return false end
    local raw = decodeBase64(native, value.m1, 88)
    local material = decodePrivateKey(native, value.private_key)
    if not raw or not material or raw ~= material.raw then return false end
    if native.provider == "libbilicrypto" then return validatePortablePair(native, material) end
    local key = importPrivateKey(native, material)
    if not key then return false end
    closeHandle(native, key, native.lib.EC_KEY_free)
    return true
end

-- Derive the raw P-256 shared x-coordinate. This does not apply a KDF.
function ECDH.deriveSecret(private_key, peer_raw)
    local native, err = availableBackend()
    if not native then return nil, err end
    local material = decodePrivateKey(native, private_key)
    if not material or type(peer_raw) ~= "string" or #peer_raw ~= 65 or peer_raw:byte(1) ~= 4 then
        return nil, cryptoError("Invalid P-256 key agreement material.")
    end
    if native.provider == "libbilicrypto" then
        if not validatePortablePair(native, material) then
            return nil, cryptoError("Invalid P-256 private key.")
        end
        local ffi, lib = native.ffi, native.lib
        local scalar, secret = ffi.new("unsigned char[32]"), ffi.new("unsigned char[32]")
        ffi.copy(scalar, material.scalar, 32)
        local ok, result = pcall(function()
            if lib.bili_p256_derive(scalar, peer_raw, secret) ~= 1 then return nil end
            return ffi.string(secret, 32)
        end)
        ffi.fill(scalar, 32, 0)
        ffi.fill(secret, 32, 0)
        if not ok or not result then
            return nil, cryptoError("Could not derive a P-256 shared secret.")
        end
        return result
    end
    local key = importPrivateKey(native, material)
    if not key then
        return nil, cryptoError("Invalid P-256 private key.")
    end
    local ffi, lib = native.ffi, native.lib
    local peer, secret
    local ok, result = pcall(function()
        local group = lib.EC_KEY_get0_group(key)
        peer = lib.EC_POINT_new(group)
        if peer == nil then return nil end
        peer = ffi.gc(peer, lib.EC_POINT_free)
        if lib.EC_POINT_oct2point(group, peer, peer_raw, 65, nil) ~= 1
            or lib.EC_POINT_is_on_curve(group, peer, nil) ~= 1
            or lib.EC_POINT_is_at_infinity(group, peer) ~= 0 then
            return nil
        end
        secret = ffi.new("unsigned char[32]")
        if lib.ECDH_compute_key(secret, 32, peer, key, nil) ~= 32 then return nil end
        return ffi.string(secret, 32)
    end)
    if secret then ffi.fill(secret, 32, 0) end
    closeHandle(native, peer, lib.EC_POINT_free)
    closeHandle(native, key, lib.EC_KEY_free)
    if not ok or not result then
        return nil, cryptoError("Could not derive a P-256 shared secret.")
    end
    return result
end

-- The serialized form contains private material and is intended only for IPC.
function ECDH.serialize(value)
    local native, err = availableBackend()
    if not native then return nil, err end
    if not validateKey(native, value) then
        return nil, cryptoError("Invalid P-256 key exchange material.")
    end
    return string.format('{"m1":"%s","private_key":"%s"}', value.m1, value.private_key)
end

function ECDH.deserialize(value)
    local native, err = availableBackend()
    if not native then return nil, err end
    if type(value) ~= "string" or #value > 2048 then
        return nil, cryptoError("Invalid serialized P-256 key exchange material.")
    end
    local decoded = Json.decode(value)
    if not validateKey(native, decoded) then
        return nil, cryptoError("Invalid serialized P-256 key exchange material.")
    end
    return { m1 = decoded.m1, private_key = decoded.private_key }
end

return ECDH
