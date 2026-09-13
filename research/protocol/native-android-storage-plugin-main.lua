-- Research-only permission facts; no account files or real credentials are read.
local ffi = require("ffi")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local android = require("android")
ffi.cdef[[
int open(const char *path, int flags, ...);
long write(int fd, const void *data, unsigned long count);
int close(int fd);
int chmod(const char *path, unsigned int mode);
int fchmod(int fd, unsigned int mode);
]]

local report = {
    research_only = true,
    synthetic_only = true,
    phase = "started",
    data_dir = DataStorage:getDataDir(),
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
local function attributes(path)
    local value = assert(lfs.attributes(path))
    local mask = 0
    for index = 1, 9 do
        if value.permissions:sub(index, index) ~= "-" then
            mask = mask + 2 ^ (9 - index)
        end
    end
    return {
        path = path, mode = value.mode, permissions = value.permissions,
        octal_permissions = string.format("%04o", mask),
        uid = value.uid, gid = value.gid, dev = value.dev, ino = value.ino,
    }
end
save()
local status_file = assert(io.open("/proc/self/status", "r"))
report.process_uid = status_file:read("*a"):match("Uid:%s*(%d+)")
status_file:close()

local content = "Synthetic permission probe; no credentials.\n"
for _, target in ipairs({
    {name = "shared_data_storage", directory = DataStorage:getDataDir()},
    {name = "private_android_files", directory = android.dir},
}) do
    local item = {name = target.name, directory = attributes(target.directory)}
    report.checks[#report.checks + 1] = item
    local path = target.directory .. "/bili-synthetic-mode-probe.txt"
    -- Android x86 flags: O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC.
    local fd = ffi.C.open(path, 1 + 64 + 512 + 524288, ffi.new("unsigned int", 384))
    assert(fd >= 0, "Synthetic file open failed: errno " .. ffi.errno())
    assert(ffi.C.write(fd, content, #content) == #content)
    item.open_requested_mode = "0600"
    item.after_open = attributes(path)
    item.fd_after_open = attributes("/proc/self/fd/" .. tonumber(fd))
    item.fchmod_0600_return = ffi.C.fchmod(fd, 384)
    if item.fchmod_0600_return ~= 0 then item.fchmod_0600_errno = ffi.errno() end
    item.after_fchmod_0600 = attributes(path)
    assert(ffi.C.close(fd) == 0)
    item.chmod_0400_return = ffi.C.chmod(path, 256)
    if item.chmod_0400_return ~= 0 then item.chmod_0400_errno = ffi.errno() end
    item.after_chmod_0400 = attributes(path)
    item.chmod_0600_return = ffi.C.chmod(path, 384)
    if item.chmod_0600_return ~= 0 then item.chmod_0600_errno = ffi.errno() end
    item.after_chmod_0600 = attributes(path)
    item.permission_changes_enforced = item.after_open.octal_permissions == "0600"
        and item.after_chmod_0400.octal_permissions == "0400"
        and item.after_chmod_0600.octal_permissions == "0600"
    item.synthetic_file_removed = os.remove(path) and true or false
    save()
end
report.phase = "complete"
report.ok = true
save()
return {disabled = true}
