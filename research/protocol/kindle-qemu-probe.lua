-- Offline research using the official Kindle LuaJIT and unmodified production libraries.
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
    scope = "Official kindlehf LuaJIT under QEMU ARM; the runner records the distinct sysroot origin",
    production_modules = true, device_verified = false, account_requests = 0,
    ffi_os = ffi.os, ffi_arch = ffi.arch, hardfp = ffi.abi("hardfp"),
    glibc = ffi.string(ffi.C.gnu_get_libc_version()), target = Platform.nativeTarget(), checks = {},
}
assert(report.ffi_arch == "arm" and report.hardfp and report.target == "linux-armhf")
assert(report.glibc == expected_glibc)
local function hex(value)
    return (value:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end
local function unhex(value)
    return (value:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end
local function check(name, fn)
    local ok, err = pcall(fn)
    report.checks[#report.checks + 1] = {name = name, ok = ok, error = not ok and tostring(err) or nil}
    assert(ok, name .. ": " .. tostring(err))
    print("PASS " .. name)
end
local backend = Backend.new({asset_root = assets, transport = {
    request = function() error("Network access is forbidden in the Kindle fixture probe") end,
}})

check("production_native_libraries_load", function()
    assert(backend:_library(), backend.library_error)
    assert(Portable.library())
    assert(Portable.capability().binary_target == "linux-armhf")
end)

check("official_signing_wasm_golden", function()
    local signed, err = backend:signRequest({
        sign_query = "device=pc&platform=web&nov=27&eot=812", body = "{}", timestamp_ms = 1789171200000,
    })
    assert(signed, err and err.message)
    assert(signed.ultra_sign == "Y4wKk9D0kYX0R2LGQ04edYQ0YQX4h9kDsKGXaasha1a4DsKf")
end)

check("nist_aes256_ecb_golden", function()
    local key = unhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    local plain = unhex("00112233445566778899aabbccddeeff")
    local encrypted = assert(Portable.aes256EcbEncrypt(key, plain))
    assert(hex(encrypted) == "8ea2b7ca516745bfeafc49904b496089")
    assert(Portable.aes256EcbDecrypt(key, encrypted) == plain)
end)

check("portable_p256_generator_and_shared_secret_golden", function()
    local library = assert(Portable.library())
    local scalar = ffi.new("unsigned char[32]")
    scalar[31] = 1
    local public = ffi.new("unsigned char[65]")
    local secret = ffi.new("unsigned char[32]")
    local generator = "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296" ..
        "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
    assert(library.bili_p256_public(scalar, public) == 1)
    assert(hex(ffi.string(public, 65)) == generator)
    assert(library.bili_p256_derive(scalar, public, secret) == 1)
    assert(hex(ffi.string(secret, 32)) == generator:sub(3, 66))
    ffi.fill(scalar, 32, 0)
    assert(library.bili_p256_public(scalar, public) == 0)
    ffi.fill(public, 65, 0)
    ffi.fill(secret, 32, 0)
end)

report.ok = true
report.passed = #report.checks
local file = assert(io.open(output, "wb"))
assert(file:write(json.encode(report), "\n"))
assert(file:close())
