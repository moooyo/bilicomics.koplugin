-- This isolated parent intentionally exits without calling Runner:close().
-- Execute only under the remote Python child-subreaper supervisor.
require("setupkoenv")
local source, output, mode = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = source .. "/?.lua;" .. package.path
local Runner = require("bilicomics/jobs/runner")
local ffiutil = require("ffi/util")
local ffi = require("ffi")
local socket = require("socket")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local screen = {}
function screen:scheduleIn() end
function screen:unschedule() end
function screen:preventStandby() end
function screen:allowStandby() end
if mode == "before_registration" then
    ffiutil.addRunInSubProcessAfterForkFunc("bilicomics-parent-exit-race", function()
        socket.sleep(0.2)
    end)
else assert(mode == "registered", "Unknown parent-exit mode") end
local runner = Runner.new({ ui = screen, worker = function()
    Files.write(output .. "/worker-started", tostring(tonumber(ffi.C.getpid())))
    socket.sleep(1.2)
    Files.write(output .. "/late-write", "A worker outlived its reader parent")
    return true
end })
local id = runner:submit({})
local task = assert(runner.tasks[id], "The fixture must fork a real worker")
Files.write(output .. "/processes.json", json.encode({ parent_pid = tonumber(ffi.C.getpid()),
    child_pid = tonumber(task.pid), mode = mode }))
if mode == "registered" then
    local deadline = socket.gettime() + 2
    while not Files.exists(output .. "/worker-started") and socket.gettime() < deadline do socket.sleep(0.002) end
    if not Files.exists(output .. "/worker-started") then
        runner:close()
        ffi.C._exit(72)
    end
end
-- Bypass UI shutdown broadcasts, Lua finalizers and the runner's normal reaper.
ffi.C._exit(71)
