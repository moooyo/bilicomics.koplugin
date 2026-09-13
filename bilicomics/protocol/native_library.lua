local Errors = require("bilicomics/protocol/errors")
local Platform = require("bilicomics/protocol/platform")

local NativeLibrary = {}
local temporary_sequence = 0
local loaded = {}
local manifests = {
    ["libbiliwasm.so"] = { manifest = "/native/manifest.json", prefix = "bin/" },
    ["libbilicrypto.so"] = { manifest = "/native/portable/manifest.json", prefix = "../bin/" },
}

local function failure(code, message)
    error(Errors.new("native_library", message, { code = code, retryable = false }), 0)
end

-- Android's classloader namespace rejects libraries on shared storage. Stage
-- a verified snapshot in Context.getFilesDir(), then dlopen the held file
-- descriptor rather than reopening a replaceable pathname.
local function loadAndroid(name, opts)
    local ffi = require("ffi")
    local bit = require("bit")
    local JSON = require("bilicomics/protocol/json")
    local sha256 = require("ffi/sha2").sha256
    local lfs = require("libs/libkoreader-lfs")
    local android = require("android")
    require("ffi/posix_h")
    ffi.cdef[[
        int openat(int dirfd, const char *path, int flags, ...);
        int mkdirat(int dirfd, const char *path, unsigned int mode);
        int renameat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath);
        int unlinkat(int dirfd, const char *path, int flags);
        int fchmod(int fd, unsigned int mode);
        int flock(int fd, int operation);
    ]]
    local C = ffi.C
    -- These flags follow the NDK r27c target headers. Android ARM and AArch64
    -- deliberately retain the ARM fcntl values, unlike the x86 targets.
    local arm = ffi.arch == "arm" or ffi.arch == "arm64"
    local NOFOLLOW, DIRECTORY = arm and 32768 or 131072, arm and 16384 or 65536
    local READ = bit.bor(C.O_RDONLY, C.O_CLOEXEC, C.O_NONBLOCK, NOFOLLOW)
    local DIR = bit.bor(READ, DIRECTORY)
    local descriptors, temporary = {}, nil
    local uid = tonumber(C.getuid())
    local target = opts.target or Platform.nativeTarget()
    local definition = manifests[name]
    local module_dir = opts.module_dir

    local function own(fd)
        if fd >= 0 then descriptors[fd] = true end
        return fd
    end
    local function close(fd)
        if descriptors[fd] then descriptors[fd] = nil; C.close(fd) end
    end
    local function attributes(fd)
        local attr = lfs.attributes("/proc/self/fd/" .. fd)
        if not attr then failure("attributes", "The native library descriptor could not be inspected.") end
        return attr
    end
    local function readFile(fd, limit, exact_size, private)
        local attr = attributes(fd)
        if attr.mode ~= "file" or attr.size > limit or exact_size and attr.size ~= exact_size then
            failure("file_type", "The native resource is not a regular file of the expected size.")
        end
        if private and (attr.uid ~= uid or attr.permissions ~= "rw-------" or attr.nlink ~= 1) then
            failure("file_permissions", "The private native library has unsafe ownership, permissions, or links.")
        end
        local chunks, size = {}, 0
        local buffer = ffi.new("unsigned char[65536]")
        while true do
            local count = tonumber(C.read(fd, buffer, 65536))
            if count == 0 then break end
            if count < 0 then
                if ffi.errno() ~= 4 then failure("read", "The native resource could not be read.") end
            else
                size = size + count
                if size > limit then failure("size", "The native resource exceeded its size limit.") end
                chunks[#chunks + 1] = ffi.string(buffer, count)
            end
        end
        if exact_size and size ~= exact_size then failure("size", "The native resource changed while being read.") end
        return table.concat(chunks), attr
    end
    local function readPath(path, limit)
        local fd = own(C.open(path, READ))
        if fd < 0 then failure("source_open", "The packaged native resource is missing or is a symbolic link.") end
        local bytes = readFile(fd, limit)
        close(fd)
        return bytes
    end
    local function directory(parent, component)
        local fd = own(C.openat(parent, component, DIR))
        if fd < 0 then
            if ffi.errno() ~= 2 then failure("directory", "The private native directory is unsafe or inaccessible.") end
            if C.mkdirat(parent, component, 448) ~= 0 and ffi.errno() ~= 17 then
                failure("directory", "The private native directory could not be created.")
            end
            if C.fsync(parent) ~= 0 then failure("sync", "The native cache directory could not be synchronized.") end
            fd = own(C.openat(parent, component, DIR))
        end
        if fd < 0 then failure("directory", "The private native directory is not a real directory.") end
        local attr = attributes(fd)
        if attr.mode ~= "directory" or attr.uid ~= uid or attr.permissions ~= "rwx------" then
            failure("directory_permissions", "The private native directory must belong to the app with mode 0700.")
        end
        return fd
    end

    local ok, library_or_error, detail = pcall(function()
        if not definition or type(module_dir) ~= "string" or not target
            or not target:match("^android%-[%w_-]+$") then
            failure("configuration", "The Android native library target is invalid.")
        end
        local manifest, json_error = JSON.decode(readPath(module_dir .. definition.manifest, 131072))
        if not manifest then failure("manifest", json_error.message) end
        local entry = type(manifest.libraries) == "table" and manifest.libraries[target]
        if type(entry) ~= "table" or type(entry.sha256) ~= "string" or #entry.sha256 ~= 64
            or entry.sha256:find("[^a-f0-9]") or type(entry.bytes) ~= "number"
            or entry.bytes % 1 ~= 0 or entry.bytes < 16 or entry.bytes > 16 * 1024 * 1024
            or entry.path ~= definition.prefix .. target .. "/" .. name then
            failure("manifest", "The package has no valid integrity record for this native library.")
        end
        local source = opts.source_path or module_dir .. "/native/bin/" .. target .. "/" .. name
        local source_fd = own(C.open(source, READ))
        if source_fd < 0 then failure("source_open", "The packaged native library is missing or is a symbolic link.") end
        local bytes = readFile(source_fd, entry.bytes, entry.bytes)
        close(source_fd)
        if sha256(bytes) ~= entry.sha256 then
            failure("source_integrity", "The packaged native library does not match its manifest digest.")
        end
        local cache_key = target .. "/" .. entry.sha256 .. "/" .. name
        if loaded[cache_key] then return loaded[cache_key].library, loaded[cache_key].detail end

        local private_root = android.dir
        if type(private_root) ~= "string" or private_root:sub(1, 1) ~= "/"
            or private_root:find("[%z\r\n]") then
            failure("private_root", "Android did not supply an app-private files directory.")
        end
        local base = own(C.open(private_root, DIR))
        if base < 0 then failure("private_root", "The Android private files directory is inaccessible or linked.") end
        local base_attr = attributes(base)
        if base_attr.mode ~= "directory" or base_attr.uid ~= uid then
            failure("private_root", "The Android private files directory does not belong to this app.")
        end
        local cache = directory(base, "bilicomics-native")
        local abi = directory(cache, target)
        local version = directory(abi, entry.sha256)
        -- Serialize first publication and dlopen for this content hash. A
        -- competing publisher must reuse the winner instead of unlinking its
        -- still-open inode between verification and loading. Closing this
        -- directory descriptor releases the process lock on every exit path.
        while C.flock(version, 2) ~= 0 do
            if ffi.errno() ~= 4 then failure("lock", "The private native library cache could not be locked.") end
        end
        local destination = private_root .. "/bilicomics-native/" .. cache_key
        local fd = own(C.openat(version, name, READ))
        if fd < 0 then
            if ffi.errno() ~= 2 then failure("cache_open", "The native cache entry is unsafe or inaccessible.") end
            for _ = 1, 32 do
                temporary_sequence = temporary_sequence + 1
                local temp_name = ".part-" .. tonumber(C.getpid()) .. "-" .. os.time() .. "-" .. temporary_sequence
                fd = own(C.openat(version, temp_name,
                    bit.bor(C.O_RDWR, C.O_CREAT, C.O_CLOEXEC, NOFOLLOW, 128), ffi.cast("unsigned int", 384)))
                if fd >= 0 then temporary = { directory = version, name = temp_name }; break end
                if ffi.errno() ~= 17 then failure("cache_create", "A private native staging file could not be created.") end
            end
            if fd < 0 then failure("cache_create", "No unused private native staging filename is available.") end
            if C.fchmod(fd, 384) ~= 0 then failure("file_permissions", "Native staging file permissions could not be secured.") end
            local written = 0
            while written < #bytes do
                local count = tonumber(C.write(fd, bytes:sub(written + 1), #bytes - written))
                if count < 0 and ffi.errno() == 4 then
                    -- Retry only an interrupted local write, never a network operation.
                elseif count <= 0 then failure("write", "The private native library could not be written.")
                else written = written + count end
            end
            if C.fsync(fd) ~= 0 then failure("sync", "The staged native library could not be synchronized.") end
            if C.lseek(fd, 0, 0) ~= 0 then failure("seek", "The staged native library could not be verified.") end
            local staged = readFile(fd, entry.bytes, entry.bytes, true)
            if sha256(staged) ~= entry.sha256 then failure("staging_integrity", "The staged native library failed integrity verification.") end
            if C.renameat(version, temporary.name, version, name) ~= 0 then
                failure("publish", "The verified native library could not be published atomically.")
            end
            temporary = nil
            if C.fsync(version) ~= 0 then failure("sync", "The published native library could not be synchronized.") end
        else
            local existing = readFile(fd, entry.bytes, entry.bytes, true)
            if sha256(existing) ~= entry.sha256 then
                failure("cache_integrity", "The private native cache entry failed integrity verification.")
            end
        end
        -- This descriptor pins exactly the verified inode across dlopen, even
        -- when another process renames or replaces the published cache path.
        local file_attr = attributes(fd)
        if file_attr.mode ~= "file" or file_attr.uid ~= uid or file_attr.permissions ~= "rw-------"
            or file_attr.nlink ~= 1 or file_attr.size ~= entry.bytes then
            failure("file_identity", "The verified native library identity changed before loading.")
        end
        local library = ffi.load("/proc/self/fd/" .. fd)
        local result = { path = destination, sha256 = entry.sha256, bytes = entry.bytes, target = target }
        -- API 21/22 can cache dlopen by the original name, including an FD
        -- number. Retain this CLOEXEC descriptor with the loaded handle so a
        -- later library cannot accidentally reuse that dlopen name. There is
        -- at most one retained descriptor per loaded library/content hash.
        loaded[cache_key] = { library = library, detail = result, descriptor = fd }
        descriptors[fd] = nil
        return library, result
    end)
    if temporary then C.unlinkat(temporary.directory, temporary.name, 0) end
    for fd in pairs(descriptors) do C.close(fd) end
    if not ok then
        if type(library_or_error) == "table" and library_or_error.kind then return nil, library_or_error end
        return nil, Errors.new("native_library", "The verified Android native library could not be loaded.", { retryable = false })
    end
    return library_or_error, detail
end

function NativeLibrary.load(name, opts)
    opts = opts or {}
    local target = opts.target or Platform.nativeTarget()
    if target and target:match("^android%-") then return loadAndroid(name, opts) end
    -- Preserve the previously verified Linux loading path and behavior.
    local path = opts.source_path or opts.module_dir .. "/native/bin/" .. target .. "/" .. name
    local ok, library = pcall(require("ffi").load, path)
    if not ok then return nil, Errors.new("native_library", "The native library is unavailable for this platform.") end
    return library, { path = path, target = target }
end

return NativeLibrary
