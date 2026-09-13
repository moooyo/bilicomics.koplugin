-- Research harness calling the current production modules without replacing their loader.
local ffi = require("ffi")
local json = require("rapidjson")
local mime = require("mime")
local DataStorage = require("datastorage")
local android = require("android")
local lfs = require("libs/libkoreader-lfs")
local source = debug.getinfo(1, "S").source
local plugin_root = assert(source:match("^@(.+)/main%.lua$"))
local report = {
    research_only = true,
    production_modules = true,
    phase = "started",
    plugin_root = plugin_root,
    android_private_dir = android.dir,
    ffi_arch = ffi.arch,
    checks = {},
}
local output_path = DataStorage:getDataDir() .. "/bili-native-probe.json"
local function save()
    local file = assert(io.open(output_path, "wb"))
    file:write(json.encode(report), "\n")
    file:close()
end
local function explanation(err)
    if type(err) == "table" then
        return json.encode({kind = err.kind, code = err.code, message = err.message})
    end
    return tostring(err)
end
local function expect(value, err)
    assert(value ~= nil, explanation(err))
    return value
end
local function check(name, fn)
    report.phase = name
    save()
    local ok, result = pcall(fn)
    report.checks[#report.checks + 1] = {
        name = name, ok = ok, detail = ok and (result or "passed") or explanation(result),
    }
    save()
    return ok
end
save()

local mode_file = io.open(plugin_root .. "/probe-cache-mode.txt", "rb")
report.cache_mode = mode_file and mode_file:read("*a") or "reuse"
if mode_file then mode_file:close() end
if report.cache_mode == "cold" then
    report.cold_cache_removed = {}
    for _, manifest_path in ipairs({"native/manifest.json", "native/portable/manifest.json"}) do
        local manifest_file = assert(io.open(plugin_root .. "/bilicomics/protocol/" .. manifest_path, "rb"))
        local manifest = json.decode(manifest_file:read("*a")); manifest_file:close()
        local entry = assert(manifest.libraries["android-x86"])
        assert(entry.sha256:match("^[a-f0-9]+$") and #entry.sha256 == 64)
        local name = assert(entry.path:match("/(libbili[%w]+%.so)$"))
        local path = android.dir .. "/bilicomics-native/android-x86/" .. entry.sha256 .. "/" .. name
        local mode = lfs.symlinkattributes(path, "mode")
        assert(mode == nil or mode == "file", "The research cache reset encountered an unexpected file type")
        if mode then assert(os.remove(path)) end
        assert(lfs.attributes(path, "mode") == nil)
        report.cold_cache_removed[#report.cold_cache_removed + 1] = path
    end
end

local Backend = require("bilicomics/protocol/native_backend")
local Portable = require("bilicomics/protocol/portable_crypto")
local ECDH = require("bilicomics/protocol/ecdh")
local NativeLibrary = require("bilicomics/protocol/native_library")
local backend = Backend.new({asset_root = plugin_root .. "/assets"})
report.source_sha256 = {}
for _, name in ipairs({"native_library.lua", "native_backend.lua", "portable_crypto.lua",
        "platform.lua", "ecdh.lua", "image_crypto.lua", "assets.lua"}) do
    local file = assert(io.open(plugin_root .. "/bilicomics/protocol/" .. name, "rb"))
    report.source_sha256[name] = require("ffi/sha2").sha256(file:read("*a"))
    file:close()
end
report.loaded_backend_source = debug.getinfo(Backend.new, "S").source
report.loaded_crypto_source = debug.getinfo(Portable.library, "S").source

check("production_capabilities", function()
    local capability = backend:capabilities()
    report.capabilities = capability
    assert(capability.binary_target == "android-x86")
    assert(capability.request_signing == true, backend.library_error)
    assert(capability.image_key_exchange == true)
    assert(capability.encrypted_images == true)
    return "Both production native backends are available"
end)

check("production_sign_golden", function()
    local result, err = backend:signRequest({
        sign_query = "device=pc&platform=web&nov=27&eot=812",
        body = "{}", timestamp_ms = 1789171200000,
    })
    result = expect(result, err)
    assert(result.ultra_sign == "Y4wKk9D0kYX0R2LGQ04edYQ0YQX4h9kDsKGXaasha1a4DsKf")
    return "Production Backend signing matches the official oracle"
end)

local function from_hex(value)
    return (value:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end
local function to_hex(value)
    return (value:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end
check("production_aes256_golden", function()
    local key = from_hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    local plain = from_hex("00112233445566778899aabbccddeeff")
    local cipher = expect(Portable.aes256EcbEncrypt(key, plain))
    assert(to_hex(cipher) == "8ea2b7ca516745bfeafc49904b496089")
    assert(expect(Portable.aes256EcbDecrypt(key, cipher)) == plain)
    return "Production PortableCrypto passes the AES-256 vector"
end)

check("production_ecdh_round_trip", function()
    local alice = expect(backend:prepareTokens())
    local bob = expect(backend:prepareTokens())
    local left = expect(ECDH.deriveSecret(alice.private_key, mime.unb64(bob.m1)))
    local right = expect(ECDH.deriveSecret(bob.private_key, mime.unb64(alice.m1)))
    assert(#left == 32 and left == right)
    return "Production key generation and ECDH agree; no key material is logged"
end)

check("production_backend_v8_image_golden", function()
    local input = assert(io.open(plugin_root .. "/image-golden-fixture.json", "rb"))
    local fixture = json.decode(input:read("*a"))
    input:close()
    local encrypted, expected = mime.unb64(fixture.body), mime.unb64(fixture.expected)
    local temporary = plugin_root .. "/synthetic-image.part"
    local transport = {request = function(_, request)
        assert(request.url == fixture.url and request.method == "GET")
        local file = assert(io.open(request.output_path, "wb"))
        assert(file:write(encrypted)); assert(file:close())
        return {status = 200}
    end}
    local converted, err = backend:convertImage({
        url = fixture.url, context = {private_key = fixture.privateKey},
        index = fixture.index, output_path = temporary, transport = transport, max_bytes = 65536,
    })
    converted = expect(converted, err)
    local file = assert(io.open(converted.temporary_path, "rb"))
    local actual = file:read("*a"); file:close()
    os.remove(converted.temporary_path)
    assert(actual == expected and #actual == 49363)
    return "Production v8 transform matches all 49363 PNG bytes using an offline synthetic response"
end)

check("production_private_library_records", function()
    report.private_libraries = {}
    for _, name in ipairs({"libbiliwasm.so", "libbilicrypto.so"}) do
        local library, detail = NativeLibrary.load(name, {
            module_dir = plugin_root .. "/bilicomics/protocol", target = "android-x86",
        })
        expect(library, detail)
        assert(detail.path:sub(1, #android.dir) == android.dir)
        local attributes = assert(lfs.attributes(detail.path))
        assert(attributes.permissions == "rw-------" and attributes.nlink == 1)
        report.private_libraries[#report.private_libraries + 1] = {
            name = name, path = detail.path, sha256 = detail.sha256,
            bytes = detail.bytes, permissions = attributes.permissions, uid = attributes.uid,
        }
    end
    return "Production loader returns digest-specific app-private paths"
end)

check("production_retained_library_descriptors", function()
    local function census()
        local result = {total = 0, libraries = {}}
        local identity = {}
        for _, item in ipairs(report.private_libraries) do
            local attr = assert(lfs.attributes(item.path))
            identity[item.name] = attr
            result.libraries[item.name] = {}
        end
        for name in lfs.dir("/proc/self/fd") do
            if tonumber(name) then
                result.total = result.total + 1
                local attr = lfs.attributes("/proc/self/fd/" .. name)
                if attr and attr.mode == "file" then
                    for library_name, expected in pairs(identity) do
                        if attr.dev == expected.dev and attr.ino == expected.ino then
                            local list = result.libraries[library_name]
                            list[#list + 1] = tonumber(name)
                        end
                    end
                end
            end
        end
        for _, list in pairs(result.libraries) do table.sort(list) end
        return result
    end
    local before = census()
    assert(#before.libraries["libbiliwasm.so"] == 1)
    assert(#before.libraries["libbilicrypto.so"] == 1)
    assert(before.libraries["libbiliwasm.so"][1] ~= before.libraries["libbilicrypto.so"][1])
    for _ = 1, 20 do
        for _, name in ipairs({"libbiliwasm.so", "libbilicrypto.so"}) do
            expect(NativeLibrary.load(name, {
                module_dir = plugin_root .. "/bilicomics/protocol", target = "android-x86",
            }))
        end
    end
    local after = census()
    for name, list in pairs(before.libraries) do
        assert(table.concat(after.libraries[name], ",") == table.concat(list, ","))
    end
    report.descriptors = {before = before, after = after, repeated_load_calls = 40}
    assert(after.total == before.total, "Repeated cached loads grew the descriptor count")
    return "Exactly two distinct retained library descriptors; 40 repeated loads leave FD counts unchanged"
end)

report.ok = true
for _, result in ipairs(report.checks) do if not result.ok then report.ok = false end end
report.phase = "complete"
save()
return {disabled = true}
