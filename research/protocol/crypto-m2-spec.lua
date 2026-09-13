-- Compare only the byte codec with instrumented official WASM error fixtures.
-- These fixtures contain invalid browser observations and are never request data.
local root = assert(arg[1], "research directory is required")
package.path = root .. "/?.lua;" .. package.path
package.cpath = "common/?.so;" .. package.cpath
local json = require("rapidjson")
local encode = require("crypto-m2-codec")
local file = assert(io.open(root .. "/crypto-m2-codec-fixtures.json", "rb"))
local fixtures = json.decode(file:read("*a"))
file:close()
assert(fixtures.synthetic_error_fixtures == true)
for _, fixture in ipairs(fixtures.fixtures) do
    assert(encode(fixture.report_json) == fixture.encoded, "codec differs from the official WASM output")
end
print("PASS " .. #fixtures.fixtures .. " official m2 codec vectors; browser report generation remains unsupported")
