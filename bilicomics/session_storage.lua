local Files = require("bilicomics/storage/files")
local Session = require("bilicomics/protocol/session")
local Util = require("bilicomics/util")
local ffi = require("ffi")
local bit = require("bit")
local lfs = require("libs/libkoreader-lfs")
require("ffi/posix_h")
ffi.cdef[[
    int openat(int dirfd, const char *path, int flags, ...);
    int mkdirat(int dirfd, const char *path, unsigned int mode);
    int unlinkat(int dirfd, const char *path, int flags);
    int fchmod(int fd, unsigned int mode);
]]

local Storage = {}
Storage.__index = Storage
local C = ffi.C
local arm = ffi.arch == "arm" or ffi.arch == "arm64"
local nofollow, directory_flag = arm and 32768 or 131072, arm and 16384 or 65536
local read_flags = bit.bor(C.O_RDONLY, C.O_CLOEXEC, C.O_NONBLOCK, nofollow)
local directory_flags = bit.bor(read_flags, directory_flag)

local function fail(code, message)
    error(Util.error("storage", message, { code = code }), 0)
end
local function verifiedKey(key)
    return type(key) == "string" and key:match("^bili_[1-9]%d*$") and #key <= 256
end
local function normalizedRoot(path)
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("[%z\r\n\\]") then return nil end
    for component in path:gmatch("[^/]+") do if component == "." or component == ".." then return nil end end
    return path:gsub("/+$", "")
end
local function validIdentity(session, key)
    return session and session.account_key == key and type(session.identity) == "table"
        and "bili_" .. tostring(session.identity.id) == key and tonumber(session.validated_at)
        and tonumber(session.validated_at) > 0
end

function Storage.new(options)
    options = options or {}
    local android = options.android
    if android == nil then
        android = package.loaded.android
        if android == nil and (os.getenv("ANDROID_ROOT") or os.getenv("ANDROID_DATA")) then
            local ok, value = pcall(require, "android")
            android = ok and value or true
        end
    end
    local is_android = android ~= nil and android ~= false
    return setmetatable({ data_root = assert(normalizedRoot(options.data_root), "A resolved data root is required"),
        is_android = is_android, private_root = is_android and type(android) == "table" and normalizedRoot(android.dir) or nil }, Storage)
end

function Storage:path(key)
    if not verifiedKey(key) then return nil, Util.error("authentication", "A verified account is required for session storage.") end
    if self.is_android then
        if not self.private_root then return nil, Util.error("storage", "Android did not supply an app-private files directory.") end
        return self.private_root .. "/bilicomics/accounts/" .. key .. "/session.dat"
    end
    return self.data_root .. "/accounts/" .. key .. "/session.dat"
end

function Storage:_privateAccount(key, create, operation)
    local descriptors = {}
    local function own(fd)
        if fd >= 0 then descriptors[#descriptors + 1] = fd end
        return fd
    end
    local uid = tonumber(C.getuid())
    local function attributes(fd)
        local value = lfs.attributes("/proc/self/fd/" .. fd)
        if not value then fail("inspect", "The private session path could not be inspected.") end
        return value
    end
    local function child(parent, name)
        local fd = own(C.openat(parent, name, directory_flags))
        if fd < 0 and ffi.errno() == 2 and create then
            if C.mkdirat(parent, name, 448) ~= 0 and ffi.errno() ~= 17 then
                fail("mkdir", "The private session directory could not be created.")
            end
            if C.fsync(parent) ~= 0 then fail("sync", "The private session directory could not be synchronized.") end
            fd = own(C.openat(parent, name, directory_flags))
        end
        if fd < 0 then fail("directory", "The private session directory is missing, linked, or inaccessible.") end
        local value = attributes(fd)
        if value.mode ~= "directory" or tonumber(value.uid) ~= uid then
            fail("directory_owner", "The private session directory does not belong to this app.")
        end
        if create and value.permissions ~= "rwx------" then
            if C.fchmod(fd, 448) ~= 0 then fail("directory_mode", "The session directory could not be restricted to mode 0700.") end
            value = attributes(fd)
        end
        if value.permissions ~= "rwx------" then fail("directory_mode", "The private session directory must have mode 0700.") end
        return fd
    end
    local function file(parent, required, exact_mode)
        local fd = own(C.openat(parent, "session.dat", read_flags))
        if fd < 0 then
            if not required and ffi.errno() == 2 then return nil end
            fail("session_open", "The private session file is missing, linked, or inaccessible.")
        end
        local value = attributes(fd)
        if value.mode ~= "file" or tonumber(value.uid) ~= uid or tonumber(value.nlink) ~= 1 then
            fail("session_owner", "The private session file has unsafe ownership, type, or links.")
        end
        if exact_mode and value.permissions ~= "rw-------" then fail("session_mode", "The private session file must have mode 0600.") end
        return fd
    end
    local ok, value, err = pcall(function()
        if not self.private_root then fail("private_root", "Android did not supply an app-private files directory.") end
        local base = own(C.open(self.private_root, directory_flags))
        if base < 0 then fail("private_root", "The Android private files directory is inaccessible or linked.") end
        local base_attributes = attributes(base)
        if base_attributes.mode ~= "directory" or tonumber(base_attributes.uid) ~= uid then
            fail("private_root_owner", "The Android private files directory does not belong to this app.")
        end
        local app = child(base, "bilicomics")
        local accounts = child(app, "accounts")
        local account = child(accounts, key)
        return operation(account, file)
    end)
    for index = #descriptors, 1, -1 do C.close(descriptors[index]) end
    if not ok then
        return nil, type(value) == "table" and value.kind and value
            or Util.error("storage", "The private session operation could not be completed safely.")
    end
    return value, err
end

function Storage:load(key)
    local path, path_error = self:path(key)
    if not path then return nil, path_error end
    if not self.is_android then
        if not Files.exists(path) then return nil, Util.error("authentication", "No saved session is available.") end
        local ok, session, err = pcall(function()
            Files.assertRegular(path, self.data_root)
            return Session.load(path)
        end)
        if not ok then return nil, Util.error("storage", "The saved session path is unsafe.") end
        if session and not validIdentity(session, key) then return nil, Util.error("account_mismatch", "The saved session does not match this account.") end
        return session, err
    end
    -- Never look for or import an old session in shared DataStorage during a read.
    return self:_privateAccount(key, false, function(account, file)
        local fd = file(account, true, true)
        local session, err = Session.load("/proc/self/fd/" .. fd)
        if session and not validIdentity(session, key) then return nil, Util.error("account_mismatch", "The private session does not match this account.") end
        return session, err
    end)
end

function Storage:save(session)
    local key = session and session.account_key
    local path, path_error = self:path(key)
    if not path then return nil, path_error end
    if not validIdentity(session, key) then return nil, Util.error("authentication", "Validate this account before storing its session.") end
    if not self.is_android then
        Files.mkdir(Files.parent(path))
        Files.assertContained(path, self.data_root)
        local saved, err = session:save(path)
        if saved then Files.syncDirectory(Files.parent(path)) end
        return saved, err
    end
    return self:_privateAccount(key, true, function(account, file)
        file(account, false, false)
        -- A held directory descriptor prevents an ancestor rename/link race.
        -- /proc/self/fd is a kernel reference to that verified directory.
        local saved, err = session:save("/proc/self/fd/" .. account .. "/session.dat")
        if not saved then return nil, err end
        local fd = file(account, true, true)
        local verified, verify_error = Session.load("/proc/self/fd/" .. fd)
        if not validIdentity(verified, key) then return nil, verify_error or Util.error("storage", "The saved private session could not be verified.") end
        if C.fsync(account) ~= 0 then fail("sync", "The saved private session directory could not be synchronized.") end
        return true
    end)
end

function Storage:removeLegacy(key)
    if not self.is_android then return true end
    local private = self:path(key)
    if not private then return nil, Util.error("authentication", "A verified account is required for legacy cleanup.") end
    local legacy = self.data_root .. "/accounts/" .. key .. "/session.dat"
    if private == legacy then return true end
    local descriptors = {}
    local function own(fd) if fd >= 0 then descriptors[#descriptors + 1] = fd end; return fd end
    local ok, value = pcall(function()
        local parent = own(C.open(self.data_root, directory_flags))
        if parent < 0 then fail("legacy_directory", "The legacy session directory is unsafe or inaccessible.") end
        for _, component in ipairs({ "accounts", key }) do
            parent = own(C.openat(parent, component, directory_flags))
            if parent < 0 then
                if ffi.errno() == 2 then return true end
                fail("legacy_directory", "The legacy session directory is linked or inaccessible.")
            end
        end
        local fd = own(C.openat(parent, "session.dat", read_flags))
        if fd < 0 then
            if ffi.errno() == 2 then return true end
            fail("legacy_file", "The legacy session file is linked or inaccessible.")
        end
        local attributes = lfs.attributes("/proc/self/fd/" .. fd)
        if not attributes or attributes.mode ~= "file" then fail("legacy_file", "The legacy session entry is not a regular file.") end
        if C.unlinkat(parent, "session.dat", 0) ~= 0 then fail("legacy_cleanup", "The legacy session file could not be removed.") end
        if C.fsync(parent) ~= 0 then fail("legacy_sync", "Legacy session cleanup could not be synchronized.") end
        return true
    end)
    for index = #descriptors, 1, -1 do C.close(descriptors[index]) end
    if not ok then return nil, type(value) == "table" and value or Util.error("storage", "Legacy session cleanup failed.") end
    return value
end

return Storage
