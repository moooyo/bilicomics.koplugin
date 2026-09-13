-- Research-only synthetic credential test in the official APK's ordinary app process.
local source = debug.getinfo(1, "S").source
local plugin = assert(source:match("^@(.+)/main%.lua$"))
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local json = require("rapidjson")
local DataStorage = require("datastorage")
local android = require("android")
local ffi = require("ffi")
require("ffi/posix_h")
local report = { phase = "started", synthetic_only = true, android_private_root = android.dir,
    data_storage = DataStorage:getDataDir(), process_uid = tonumber(ffi.C.getuid()), process_pid = tonumber(ffi.C.getpid()), ffi_arch = ffi.arch }
local output = DataStorage:getDataDir() .. "/bili-native-probe.json"
local function save()
    local file = assert(io.open(output, "wb")); file:write(json.encode(report)); file:close()
end
save()
local token = tostring(os.time()) .. "-" .. tostring(ffi.C.getpid())
local ok, result = xpcall(function()
    local reopen = io.open(plugin .. "/session-reopen.json", "rb")
    if reopen then
        local state = json.decode(reopen:read("*a")); reopen:close()
        assert(state.root:sub(1, #(DataStorage:getDataDir() .. "/bili-session-storage-probe-")) == DataStorage:getDataDir() .. "/bili-session-storage-probe-")
        assert(state.account_key:match("^bili_987650%d+$"))
        local checks = {}
        local function check(name, passed) checks[#checks + 1] = { name = name, passed = not not passed }; assert(passed, name) end
        local sent = 0
        local ui = { nextTick = function() end, scheduleIn = function() end, unschedule = function() end }
        local controller = require("bilicomics/controller").new{ root = state.root, ui_manager = ui,
            runner_factory = function() return { submit = function() sent = sent + 1 end, cancel = function() end, close = function() end } end }
        check("fresh_app_process_loads_private_session", controller.account.session_valid and controller.account.key == state.account_key)
        check("fresh_app_process_does_not_adopt_shared_legacy_cookie", controller.account.session.cookies.SESSDATA == "synthetic-private-verified")
        check("fresh_app_process_uses_android_private_path", controller.session_storage:path(state.account_key) == state.private_path)
        check("fresh_app_process_keeps_cached_content_in_data_storage", controller.account.store.root == state.root .. "/accounts/" .. state.account_key
            and controller.account.pages:isComplete("10", "private-test"))
        check("fresh_app_process_sends_no_session_validation", sent == 0)
        controller:close()
        return { count = #checks, assertions = checks, process_restart = true }
    end
    report.synthetic_data_root = DataStorage:getDataDir() .. "/bili-session-storage-probe-" .. token
    return require("spec/controller/session_storage_cases"){
        root = report.synthetic_data_root,
        private_root = android.dir, native_android = true, fixture = plugin .. "/fixture.png",
        mid = "987650" .. tostring(os.time()) .. tostring(ffi.C.getpid()) }
end, debug.traceback)
report.phase, report.passed = "complete", ok
if ok then report.result = result else report.error = result end
save()
return { disabled = true }
