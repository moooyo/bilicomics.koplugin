-- Mandatory network boundary for the isolated synthetic state and protocol cases.
local root, spec_root, script, output = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
local data_root, phase, purpose = arg[5], arg[6], arg[7]
assert(script == "state_machine" or script == "restart" or script == "protocol_boundary" or script == "ordinal_transaction_spec")
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local ffi = require("ffi")
local json = require("rapidjson")
ffi.cdef[[long readlink(const char *path, char *buf, unsigned long size);]]
local namespace = ffi.new("char[128]")
local count = ffi.C.readlink("/proc/self/ns/net", namespace, 128)
assert(count > 0 and ffi.string(namespace, count) ~= assert(os.getenv("BILI_NONSPENDING_PARENT_NETNS")),
    "A distinct network namespace is required")
local evidence = {
    script = script, phase = phase, purpose = purpose, passed = false,
    network_namespace_isolated = true, real_transport_attempts = 0, forbidden_module_attempts = 0,
    synthetic_read_calls = 0, synthetic_submit_calls = 0, fake_buy_route_calls = 0,
    scope = "Synthetic state and request-construction regression; actual HTTP and actual transactions are forbidden",
}
BILI_NONSPENDING_EVIDENCE = evidence
for _, name in ipairs({"socket.http", "socket.https", "ssl", "bilicomics/protocol/native_backend", "bilicomics/jobs/worker"}) do
    package.preload[name] = function()
        evidence.forbidden_module_attempts = evidence.forbidden_module_attempts + 1
        error("A real network or acquisition module is forbidden", 0)
    end
end
-- This is the production Transport class. Every real/fallback request entry is
-- replaced before Client or Service loads; the protocol case injects a separate
-- strict in-memory transport to exercise production serialization and parsing.
local Transport = require("bilicomics/protocol/transport")
Transport.request = function()
    evidence.real_transport_attempts = evidence.real_transport_attempts + 1
    error("Actual transport requests are forbidden", 0)
end
arg = {root, data_root, phase, purpose}
local ok, failure = xpcall(function() dofile(spec_root .. "/" .. script .. ".lua") end, debug.traceback)
evidence.passed = ok and evidence.real_transport_attempts == 0 and evidence.forbidden_module_attempts == 0
if not ok then evidence.failure = tostring(failure) end
local file = assert(io.open(output, "wb"))
file:write(json.encode(evidence)); file:close()
if not evidence.passed then
    print("FAIL isolated non-spending boundary")
    if failure then print(failure) end
end
os.exit(evidence.passed and 0 or 1)
