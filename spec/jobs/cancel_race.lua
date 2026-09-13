-- Execute only inside the isolated test-env KOReader runtime.
require("setupkoenv")
package.path = assert(arg[1]) .. "/?.lua;" .. package.path
local ffiutil = require("ffi/util")
local socket = require("socket")
local Runner = require("bilicomics/jobs/runner")
local json = require("rapidjson")
local ui = { held = 0 }
function ui:scheduleIn() end
function ui:unschedule() end
function ui:preventStandby() self.held = self.held + 1 end
function ui:allowStandby() self.held = self.held - 1 end
ffiutil.addRunInSubProcessAfterForkFunc("bilicomics-race-probe", function() socket.sleep(0.2) end)
local runner = Runner.new({ ui = ui, worker = function() socket.sleep(0.5); return true end })
runner:submit({})
local start = socket.gettime()
runner:close()
local elapsed = socket.gettime() - start
ffiutil.removeRunInSubProcessAfterForkFunc("bilicomics-race-probe")
print(json.encode({ elapsed_seconds = elapsed, standby_holds = ui.held, prompt_close = elapsed < 0.15 }))
assert(elapsed < 0.15, "Closing before child setpgid must terminate promptly")
