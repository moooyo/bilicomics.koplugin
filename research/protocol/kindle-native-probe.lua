-- Offline primitive acceptance for rebuilt ARM libraries in the official Kindle LuaJIT.
-- Run only on the authorized remote host; this probe never uses account APIs.
local root, assets, output, expected_glibc = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local ffi = require("ffi")
local json = require("rapidjson")
local Platform = require("bilicomics/protocol/platform")
local Backend = require("bilicomics/protocol/native_backend")
local Portable = require("bilicomics/protocol/portable_crypto")
ffi.cdef[[const char *gnu_get_libc_version(void);]]

local report = {
    scope = "Official kindlehf LuaJIT under QEMU ARM; bounded native primitives; the runner records the distinct sysroot origin",
    production_modules = true, device_verified = false, account_requests = 0,
    ffi_os = ffi.os, ffi_arch = ffi.arch, hardfp = ffi.abi("hardfp"),
    glibc = ffi.string(ffi.C.gnu_get_libc_version()), target = Platform.nativeTarget(),
    checks = {}, ok = false, passed = 0,
}

local function save()
    local file = assert(io.open(output, "wb"), "The native probe report could not be opened.")
    assert(file:write(json.encode(report), "\n"), "The native probe report could not be written.")
    assert(file:close(), "The native probe report could not be closed.")
end

if report.ffi_os ~= "Linux" or report.ffi_arch ~= "arm" or not report.hardfp
    or report.target ~= "linux-armhf" or report.glibc ~= expected_glibc then
    report.error = "The expected ARM runtime and C library were not selected."
    save()
    os.exit(1)
end

local function unhex(value)
    return (value:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end

local function check(name, fn)
    local completed, result = pcall(fn)
    local passed = completed and result == true
    report.checks[#report.checks + 1] = {
        name = name, ok = passed, error = not passed and "Native primitive check failed." or nil,
    }
    if passed then report.passed = report.passed + 1 end
    -- Never serialize native errors, key objects, private material, or derived secrets.
    save()
    print((passed and "PASS " or "FAIL ") .. name)
    if not passed then os.exit(1) end
end

local function equalBuffers(left, right, size)
    for index = 0, size - 1 do if left[index] ~= right[index] then return false end end
    return true
end

local function matchesBytes(buffer, value)
    for index = 1, #value do if buffer[index - 1] ~= value:byte(index) then return false end end
    return true
end

local function allBytes(buffer, size, value)
    for index = 0, size - 1 do if buffer[index] ~= value then return false end end
    return true
end

local function withBuffers(sizes, fn)
    local buffers = {}
    for index, size in ipairs(sizes) do buffers[index] = ffi.new("unsigned char[?]", size) end
    local completed, result = pcall(fn, unpack(buffers))
    -- Keep generated scalars and secrets mutable, and clear them on every Lua return path.
    for index, size in ipairs(sizes) do ffi.fill(buffers[index], size, 0) end
    return completed and result == true
end

local backend
check("production_native_libraries_load", function()
    backend = Backend.new({asset_root = assets, transport = {
        request = function() error("Network access is forbidden in the native primitive probe.", 0) end,
    }})
    return backend:_library() ~= nil and Portable.library() ~= nil
        and Portable.capability().binary_target == "linux-armhf"
end)

check("official_signing_wasm_golden", function()
    local signed = backend:signRequest({
        sign_query = "device=pc&platform=web&nov=27&eot=812", body = "{}", timestamp_ms = 1789171200000,
    })
    return signed ~= nil and signed.ultra_sign == "Y4wKk9D0kYX0R2LGQ04edYQ0YQX4h9kDsKGXaasha1a4DsKf"
end)

check("nist_aes256_ecb_golden", function()
    local key = unhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    local plain = unhex("00112233445566778899aabbccddeeff")
    local encrypted = Portable.aes256EcbEncrypt(key, plain)
    return encrypted == unhex("8ea2b7ca516745bfeafc49904b496089")
        and Portable.aes256EcbDecrypt(key, encrypted) == plain
end)

check("portable_p256_generator_and_shared_secret_golden", function()
    local library = Portable.library()
    local generator = unhex("046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296" ..
        "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")
    return withBuffers({32, 65, 32}, function(scalar, public, secret)
        scalar[31] = 1
        if library.bili_p256_public(scalar, public) ~= 1 or not matchesBytes(public, generator)
            or library.bili_p256_derive(scalar, public, secret) ~= 1
            or not matchesBytes(secret, generator:sub(2, 33)) then return false end
        ffi.fill(scalar, 32, 0)
        return library.bili_p256_public(scalar, public) == 0
    end)
end)

-- Public mbedTLS PKCS5 answer already recorded in research/protocol/v5-verify.py.
check("public_pbkdf2_hmac_sha512_golden", function()
    local derived = Portable.pbkdf2Sha512("password", "salt", 1, 20)
    return derived == unhex("867f70cf1ade02cff3752599a3a53dc4af34c7a6")
end)

-- The public Lua GCM wrapper requires 256-bit keys. The requested NIST AES-128
-- answer therefore exercises the same library's documented multi-key-size C ABI.
local gcm128_key, gcm_iv = string.rep("\0", 16), string.rep("\0", 12)
local gcm128_cipher = unhex("0388dace60b6a392f328c2b971b2fe78")
local gcm128_tag = unhex("ab6e47d42cec13bdf53a67b21257bddf")

check("nist_aes128_gcm_decrypt_golden", function()
    local library = Portable.library()
    return withBuffers({16}, function(plain)
        return library.bili_aes_gcm_decrypt(gcm128_key, 16, gcm_iv, 12, "", 0,
            gcm128_cipher, 16, gcm128_tag, 16, plain) == 1 and allBytes(plain, 16, 0)
    end)
end)

check("nist_aes128_gcm_tampered_tag_rejected", function()
    local library = Portable.library()
    local tampered_tag = unhex("aa6e47d42cec13bdf53a67b21257bddf")
    return withBuffers({16}, function(plain)
        ffi.fill(plain, 16, 0xa5)
        return library.bili_aes_gcm_decrypt(gcm128_key, 16, gcm_iv, 12, "", 0,
            gcm128_cipher, 16, tampered_tag, 16, plain) == 0 and allBytes(plain, 16, 0xa5)
    end)
end)

check("nist_aes256_gcm_public_api_and_tag_rejection", function()
    local key = string.rep("\0", 32)
    local ciphertext_with_tag = unhex("cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919")
    local plain = Portable.aes256GcmDecrypt(key, gcm_iv, "", ciphertext_with_tag)
    if plain ~= string.rep("\0", 16) then return false end
    local tampered = ciphertext_with_tag:sub(1, -2) .. string.char((ciphertext_with_tag:byte(-1) + 1) % 256)
    local rejected, failure = Portable.aes256GcmDecrypt(key, gcm_iv, "", tampered)
    return rejected == nil and type(failure) == "table" and failure.kind == "crypto" and failure.transmitted == false
end)

check("portable_p256_fresh_keys_export_and_agreement", function()
    local library = Portable.library()
    -- Calling this ABI explicitly prevents a successful LibreSSL fallback from
    -- being mistaken for acceptance of the rebuilt portable ARM library.
    return withBuffers({32, 65, 65, 32, 65, 65, 32, 32}, function(private_a, public_a, exported_a,
            private_b, public_b, exported_b, secret_ab, secret_ba)
        if library.bili_p256_new(private_a, public_a) ~= 1
            or library.bili_p256_new(private_b, public_b) ~= 1
            or public_a[0] ~= 4 or public_b[0] ~= 4
            or equalBuffers(public_a, public_b, 65) then return false end
        if library.bili_p256_public(private_a, exported_a) ~= 1
            or library.bili_p256_public(private_b, exported_b) ~= 1
            or not equalBuffers(public_a, exported_a, 65)
            or not equalBuffers(public_b, exported_b, 65) then return false end
        return library.bili_p256_derive(private_a, public_b, secret_ab) == 1
            and library.bili_p256_derive(private_b, public_a, secret_ba) == 1
            and equalBuffers(secret_ab, secret_ba, 32) and not allBytes(secret_ab, 32, 0)
    end)
end)

report.ok = true
save()
