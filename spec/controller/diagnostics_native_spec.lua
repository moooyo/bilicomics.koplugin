-- Exercise the real fork/pipe diagnostics worker while the network queue stays suspended.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local Controller = require("bilicomics/controller")
local UIManager = require("ui/uimanager")
local Files = require("bilicomics/storage/files")
local Worker = require("bilicomics/jobs/worker")
local ffi = require("ffi")
local json = require("rapidjson")
local results = { assertions = {}, real_fork_worker = true, scope = "Local capabilities only; no Bilibili network or account request" }
local function mark(phase)
    results.phase = phase
    Files.write(output .. "/diagnostics-progress.json", json.encode(results, { pretty = true }))
end
local function check(name, value)
    results.assertions[#results.assertions + 1] = { name = name, passed = not not value }
    assert(value, name)
end
local app = Controller.new{ root = output .. "/data", ui_manager = UIManager, network = { isConnected = function() return false end } }
mark("controller-created")
app:suspend()
mark("network-suspended")
app.runner.worker = function()
    Files.write(output .. "/network-queue-executed", "Unexpected local sentinel execution")
    return nil, { kind = "test_sentinel" }
end
app.runner:submit({ kind = "client", method = "wallet" }, {}, function() end)
app:resume()
mark("offline-resume")
check("offline_resume_keeps_network_runner_suspended", app.runner.suspended and #app.runner.queue == 1)
local diagnostics_runner = app:_diagnosticsRunner()
diagnostics_runner.worker = function(request)
    assert(request.kind == "diagnostics" and request.session == nil, "Diagnostics must not receive account credentials")
    return Worker.execute(request)
end
UIManager:show(require("ui/widget/infomessage"):new{ text = "Synthetic local diagnostics verification" })
local completed
mark("before-diagnostics-submit")
app:getDiagnostics(function(snapshot, err)
    mark("diagnostics-callback")
    local ok, failure = pcall(function()
        check("real_diagnostics_worker_returns_local_snapshot", snapshot ~= nil and err == nil)
        check("diagnostics_never_claims_server_verification", snapshot.server_checked == false)
        check("real_local_versions_and_capabilities_are_reported", snapshot.plugin_version == "0.1.0-dev"
            and snapshot.koreader_version ~= "unknown" and type(snapshot.capabilities.request_signing) == "boolean")
        check("local_diagnostics_does_not_resume_or_execute_network_queue", app.runner.suspended and #app.runner.queue == 1
            and not Files.exists(output .. "/network-queue-executed"))
    end)
    if not ok then results.error = tostring(failure) end
    completed = true
    mark("local-checks-complete")
    app:close()
    mark("controller-closed")
    check("local_worker_runner_is_closed_with_controller", diagnostics_runner.stopped and not next(diagnostics_runner.tasks))
    UIManager:quit()
end)
mark("diagnostics-submitted")
local child_pid
for _, task in pairs(diagnostics_runner.tasks) do child_pid = task.pid end
check("diagnostics_executes_in_a_real_child_process", child_pid and child_pid ~= tonumber(ffi.C.getpid()))
UIManager:scheduleIn(10, function()
    results.error = "Local diagnostics did not complete while the network queue was paused"
    app:close(); UIManager:quit()
end)
local ran, failure = xpcall(function() UIManager:run() end, debug.traceback)
mark("event-loop-returned")
if not ran then results.error = failure; if not app.closed then app:close() end end
results.passed = completed and ran and results.error == nil
results.count = #results.assertions
Files.write(output .. "/diagnostics-native-result.json", json.encode(results, { pretty = true }))
print(json.encode(results, { pretty = true }))
if not results.passed then os.exit(1) end
