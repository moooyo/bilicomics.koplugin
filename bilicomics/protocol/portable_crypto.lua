local Errors = require("bilicomics/protocol/errors")
local Platform = require("bilicomics/protocol/platform")
local NativeLibrary = require("bilicomics/protocol/native_library")

local PortableCrypto = {}
local module_path = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."
local ffi
local library
local checked = false
local reason
local binary_target

local declarations = [[
int bili_p256_new(unsigned char private32[32], unsigned char public65[65]);
int bili_p256_public(const unsigned char private32[32], unsigned char public65[65]);
int bili_p256_derive(const unsigned char private32[32],
    const unsigned char public65[65], unsigned char secret32[32]);
int bili_aes256_ecb_encrypt(const unsigned char key32[32],
    const unsigned char *input, unsigned long length, unsigned char *output);
int bili_aes256_ecb_decrypt(const unsigned char key32[32],
    const unsigned char *input, unsigned long length, unsigned char *output);
int bili_pbkdf2_sha512(const unsigned char *password, size_t passlen,
    const unsigned char *salt, size_t saltlen, unsigned int iterations,
    unsigned char *out, size_t outlen);
int bili_aes_gcm_decrypt(const unsigned char *key, size_t keylen,
    const unsigned char *iv, size_t ivlen, const unsigned char *aad, size_t aadlen,
    const unsigned char *cipher, size_t cipherlen, const unsigned char *tag, size_t taglen,
    unsigned char *out);
]]

local required_symbols = {
    "bili_p256_new", "bili_p256_public", "bili_p256_derive",
    "bili_aes256_ecb_encrypt", "bili_aes256_ecb_decrypt",
    "bili_pbkdf2_sha512", "bili_aes_gcm_decrypt",
}

function PortableCrypto.library()
    if checked then return library, reason end
    checked = true
    local ok
    ok, ffi = pcall(require, "ffi")
    if not ok then
        ffi = nil
        reason = "LuaJIT FFI is unavailable."
        return nil, reason
    end
    if not pcall(ffi.cdef, declarations) then
        reason = "The portable crypto declarations could not be loaded."
        return nil, reason
    end
    if ffi.os ~= "Linux" then
        reason = "No portable crypto library is packaged for this operating system."
        return nil, reason
    end
    binary_target = Platform.nativeTarget()
    if not binary_target then
        reason = "No portable crypto library is packaged for this CPU ABI."
        return nil, reason
    end
    local candidate, detail = NativeLibrary.load("libbilicrypto.so", { module_dir = module_path, target = binary_target })
    if not candidate then
        reason = detail and detail.message or "The portable crypto library is unavailable for " .. binary_target .. "."
        return nil, reason
    end
    for _, symbol in ipairs(required_symbols) do
        local found, value = pcall(function() return candidate[symbol] end)
        if not found or value == nil then
            reason = "The portable crypto library does not export " .. symbol .. "."
            return nil, reason
        end
    end
    library = candidate
    return library
end

function PortableCrypto.capability()
    local native, why = PortableCrypto.library()
    return {
        available = native ~= nil,
        provider = "bilicrypto-portable",
        binary_target = binary_target,
        reason = why,
        error = not native and Errors.capability("portable_crypto", why) or nil,
    }
end

local function aes256Ecb(key, blocks, decrypt)
    if type(key) ~= "string" or #key ~= 32 or type(blocks) ~= "string"
        or #blocks % 16 ~= 0 then
        return nil, Errors.new("crypto", "Invalid AES-256 key or block length.", { transmitted = false })
    end
    local native, why = PortableCrypto.library()
    if not native then return nil, Errors.capability("portable_crypto", why) end
    if #blocks == 0 then return "" end
    local key_buffer = ffi.new("unsigned char[32]")
    local output = ffi.new("unsigned char[?]", #blocks)
    ffi.copy(key_buffer, key, 32)
    local ok, result = pcall(function()
        local transform = decrypt and native.bili_aes256_ecb_decrypt or native.bili_aes256_ecb_encrypt
        if transform(key_buffer, blocks, #blocks, output) ~= 1 then return nil end
        return ffi.string(output, #blocks)
    end)
    ffi.fill(key_buffer, 32, 0)
    ffi.fill(output, #blocks, 0)
    if not ok or not result then
        return nil, Errors.new("crypto", "The portable AES-256 operation failed.", { transmitted = false })
    end
    return result
end

function PortableCrypto.aes256EcbEncrypt(key, blocks)
    return aes256Ecb(key, blocks, false)
end

function PortableCrypto.aes256EcbDecrypt(key, blocks)
    return aes256Ecb(key, blocks, true)
end

function PortableCrypto.pbkdf2Sha512(password, salt, iterations, key_length)
    if type(password) ~= "string" or #password > 1024 or type(salt) ~= "string" or #salt > 1024
        or type(iterations) ~= "number" or iterations % 1 ~= 0 or iterations < 1 or iterations > 1000000
        or type(key_length) ~= "number" or key_length % 1 ~= 0 or key_length < 1 or key_length > 1024
        or iterations * math.ceil(key_length / 64) > 1000000 then
        return nil, Errors.new("crypto", "Invalid PBKDF2-SHA512 parameters.", { transmitted = false })
    end
    local native, why = PortableCrypto.library()
    if not native then return nil, Errors.capability("portable_crypto", why) end
    local password_buffer = ffi.new("unsigned char[?]", math.max(1, #password))
    local output = ffi.new("unsigned char[?]", key_length)
    ffi.copy(password_buffer, password, #password)
    local ok, result = pcall(function()
        if native.bili_pbkdf2_sha512(password_buffer, #password, salt, #salt,
            iterations, output, key_length) ~= 1 then return nil end
        return ffi.string(output, key_length)
    end)
    ffi.fill(password_buffer, math.max(1, #password), 0)
    ffi.fill(output, key_length, 0)
    if not ok or not result then
        return nil, Errors.new("crypto", "The PBKDF2-SHA512 operation failed.", { transmitted = false })
    end
    return result
end

function PortableCrypto.aes256GcmDecrypt(key, iv, aad, ciphertext_with_tag)
    if type(key) ~= "string" or #key ~= 32 or type(iv) ~= "string" or #iv < 1 or #iv > 1024
        or type(aad) ~= "string" or #aad > 1048576 or type(ciphertext_with_tag) ~= "string"
        or #ciphertext_with_tag < 16 or #ciphertext_with_tag > 67108864 + 16 then
        return nil, Errors.new("crypto", "Invalid AES-256-GCM parameters.", { transmitted = false })
    end
    local native, why = PortableCrypto.library()
    if not native then return nil, Errors.capability("portable_crypto", why) end
    local cipher_length = #ciphertext_with_tag - 16
    local key_buffer = ffi.new("unsigned char[32]")
    local output_size = math.max(1, cipher_length)
    local output = ffi.new("unsigned char[?]", output_size)
    ffi.copy(key_buffer, key, 32)
    local ok, result = pcall(function()
        local tag = ciphertext_with_tag:sub(cipher_length + 1)
        if native.bili_aes_gcm_decrypt(key_buffer, 32, iv, #iv, aad, #aad,
            ciphertext_with_tag, cipher_length, tag, 16, output) ~= 1 then return nil end
        return ffi.string(output, cipher_length)
    end)
    ffi.fill(key_buffer, 32, 0)
    ffi.fill(output, output_size, 0)
    if not ok or not result then
        return nil, Errors.new("crypto", "The AES-256-GCM authentication failed.", { transmitted = false })
    end
    return result
end

PortableCrypto.encryptECB = PortableCrypto.aes256EcbEncrypt
PortableCrypto.decryptECB = PortableCrypto.aes256EcbDecrypt

return PortableCrypto
