-- Research-only plugin loaded by the unmodified official KOReader Android APK.
-- All inputs are public or synthetic. This file is never a production plugin.
local ffi = require("ffi")
local json = require("rapidjson")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local android = require("android")
local source = debug.getinfo(1, "S").source
local plugin_root = assert(source:match("^@(.+)/main%.lua$"))
local output_path = DataStorage:getDataDir() .. "/bili-native-probe.json"
local report = {
    research_only = true,
    phase = "started",
    plugin_root = plugin_root,
    data_dir = DataStorage:getDataDir(),
    package_dir = lfs.currentdir(),
    android_private_dir = android.dir,
    apk_native_library_dir = android.nativeLibraryDir,
    ffi_os = ffi.os,
    ffi_arch = ffi.arch,
    checks = {},
}

local function save()
    local file = assert(io.open(output_path, "wb"))
    file:write(json.encode(report), "\n")
    file:close()
end
save()

local function check(name, fn)
    report.phase = name
    save()
    local ok, detail = pcall(fn)
    report.checks[#report.checks + 1] = {
        name = name, ok = ok, detail = ok and (detail or "passed") or tostring(detail),
    }
    save()
    return ok
end

ffi.cdef[[
int biliwasm_run(const char *wasm_path, const char *request_json, char **output_json);
void biliwasm_free(char *output_json);
int bili_aes256_ecb_encrypt(const unsigned char key32[32], const unsigned char *input,
    unsigned long length, unsigned char *output);
int bili_aes256_ecb_decrypt(const unsigned char key32[32], const unsigned char *input,
    unsigned long length, unsigned char *output);
int bili_p256_public(const unsigned char private32[32], unsigned char public65[65]);
int bili_p256_derive(const unsigned char private32[32], const unsigned char public65[65],
    unsigned char secret32[32]);
]]

ffi.cdef[[
int open(const char *path, int flags, ...);
int close(int fd);
]]
local function load_from_fd(path)
    local nofollow = (ffi.arch == "arm" or ffi.arch == "arm64") and 32768 or 131072
    local fd = ffi.C.open(path, nofollow + 524288)
    assert(fd >= 0, "Private library open failed: errno " .. ffi.errno())
    local descriptor_path = "/proc/self/fd/" .. tonumber(fd)
    local attributes = assert(lfs.attributes(descriptor_path))
    report.fd_loads = report.fd_loads or {}
    local entry = {
        path = path, descriptor_path = descriptor_path,
        ino = attributes.ino, dev = attributes.dev, size = attributes.size,
        mode = attributes.mode, permissions = attributes.permissions, uid = attributes.uid,
    }
    report.fd_loads[#report.fd_loads + 1] = entry
    local file = assert(io.open(path, "rb"))
    local handle_ok, handle_result = pcall(lfs.attributes, file)
    file:close()
    report.lfs_filehandle_attributes_supported = handle_ok
    if not handle_ok then report.lfs_filehandle_attributes_error = tostring(handle_result) end
    local ok, library = pcall(ffi.load, descriptor_path)
    ffi.C.close(fd)
    assert(ok, library)
    entry.loaded_after_fd_closed = true
    return library
end
local wasm, crypto
local source_native_dir = plugin_root .. "/native"
local native_dir = android.dir .. "/bili-native-probe"
report.staging = "android_private_files"
report.native_staging_dir = native_dir
check("stage_libraries_in_private_files", function()
    if lfs.attributes(native_dir, "mode") ~= "directory" then
        assert(lfs.mkdir(native_dir))
    end
    report.staging_directory_permissions = lfs.attributes(native_dir, "permissions")
    report.staging_directory_uid = lfs.attributes(native_dir, "uid")
    report.staged_libraries = {}
    for _, name in ipairs({"libbiliwasm.so", "libbilicrypto.so"}) do
        local source_file = assert(io.open(source_native_dir .. "/" .. name, "rb"))
        local content = source_file:read("*a")
        source_file:close()
        local destination = native_dir .. "/" .. name
        local temporary = destination .. ".part"
        local output_file = assert(io.open(temporary, "wb"))
        assert(output_file:write(content))
        assert(output_file:close())
        local verify_file = assert(io.open(temporary, "rb"))
        assert(verify_file:read("*a") == content, "Staged bytes differ from the verified input")
        verify_file:close()
        assert(os.rename(temporary, destination))
        report.staged_libraries[#report.staged_libraries + 1] = {
            name = name, bytes = #content, identical_bytes = true,
            path = destination, permissions = lfs.attributes(destination, "permissions"),
            uid = lfs.attributes(destination, "uid"),
        }
    end
    local status_file = io.open("/proc/self/status", "r")
    if status_file then
        report.process_uid = status_file:read("*a"):match("Uid:%s*(%d+)")
        status_file:close()
    end
    local context_file = io.open("/proc/self/attr/current", "r")
    if context_file then
        report.selinux_context = context_file:read("*a")
        context_file:close()
    end
    return "Copied and byte-verified both libraries before atomic rename"
end)
local wasm_loaded = check("dlopen_wasm_from_held_fd", function()
    wasm = load_from_fd(native_dir .. "/libbiliwasm.so")
    return true
end)
local crypto_loaded = check("dlopen_crypto_from_held_fd", function()
    crypto = load_from_fd(native_dir .. "/libbilicrypto.so")
    return true
end)

if wasm_loaded then
    local function run_wasm(request)
        local output = ffi.new("char *[1]")
        local status = wasm.biliwasm_run(plugin_root .. "/sign.wasm", json.encode(request), output)
        assert(output[0] ~= nil, "Native host returned no output")
        local text = ffi.string(output[0])
        wasm.biliwasm_free(output[0])
        assert(status == 0, "Native host failed: " .. text)
        return json.decode(text)
    end
    check("official_wasm_sign_golden", function()
        local result = run_wasm({
            ["function"] = "y1_z2w2a3",
            args = {"device=pc&platform=web&nov=27&eot=812", "{}", 1789171200000},
        })
        assert(result.ok == true)
        assert(result.result.sign == "Y4wKk9D0kYX0R2LGQ04edYQ0YQX4h9kDsKGXaasha1a4DsKf")
        return "Official deterministic signature matched"
    end)
    check("official_wasm_argument_error", function()
        local result = run_wasm({["function"] = "y1_z2w2a3", args = json.array()})
        assert(result.ok == true)
        assert(result.result.error == "Invalid number of arguments. Expected 3 arguments (query, body, timestamp)")
        return "Official argument error matched"
    end)
end

local function from_hex(hex)
    return (hex:gsub("..", function(pair) return string.char(assert(tonumber(pair, 16))) end))
end
local function to_hex(bytes)
    return (bytes:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end
if crypto_loaded then
    check("aes256_ecb_fips_golden", function()
        local key = from_hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        local plain = from_hex("00112233445566778899aabbccddeeff")
        local cipher = ffi.new("unsigned char[16]")
        local decoded = ffi.new("unsigned char[16]")
        assert(crypto.bili_aes256_ecb_encrypt(key, plain, 16, cipher) == 1)
        assert(to_hex(ffi.string(cipher, 16)) == "8ea2b7ca516745bfeafc49904b496089")
        assert(crypto.bili_aes256_ecb_decrypt(key, cipher, 16, decoded) == 1)
        assert(ffi.string(decoded, 16) == plain)
        return "FIPS AES-256 encrypt/decrypt matched"
    end)
    check("p256_public_and_ecdh_golden", function()
        local private = from_hex(string.rep("00", 31) .. "01")
        local public = ffi.new("unsigned char[65]")
        local secret = ffi.new("unsigned char[32]")
        local expected_x = "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
        local expected_y = "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
        assert(crypto.bili_p256_public(private, public) == 1)
        assert(to_hex(ffi.string(public, 65)) == "04" .. expected_x .. expected_y)
        assert(crypto.bili_p256_derive(private, public, secret) == 1)
        assert(to_hex(ffi.string(secret, 32)) == expected_x)
        return "P-256 generator public key and ECDH matched"
    end)
end

report.phase = "complete"
report.ok = true
for _, result in ipairs(report.checks) do
    if not result.ok then report.ok = false end
end
save()
logger.info("BiliNativeProbe", json.encode(report))
return {disabled = true}
