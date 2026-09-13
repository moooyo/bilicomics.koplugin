-- Run from an official KOReader release on the remote verification environment.
local root = assert(arg[1], "research directory is required")
package.path = root .. "/?.lua;" .. package.path
package.cpath = "common/?.so;" .. package.cpath
require("ffi/loadlib")
local json = require("rapidjson")
local crypto = require("response_crypto")
local assertions = 0

local function check(value, message)
    assertions = assertions + 1
    assert(value, message)
end

local function read_json(name)
    local file = assert(io.open(root .. "/" .. name, "rb"))
    local value = file:read("*a")
    file:close()
    return json.decode(value)
end

check(crypto.available(), "AES-192-ECB must be available")
local fixtures = read_json("crypto-response-fixtures.json")
for _, fixture in ipairs(fixtures) do
    check(crypto.deriveKey(fixture.context) == fixture.key, "derived key differs from the observed WASM key")
    check(fixture.official.error == "", "official WASM did not accept the synthetic fixture")
    local result, err = crypto.decode(fixture.context, { code = 0, message = "", bytesData = fixture.bytesData, marker = 7 })
    check(result ~= nil, err and err.message)
    check(result.data.fixture == "crypto", "decoded fixture differs from official WASM")
    check(result.code == 0 and result.message == "" and result.marker == 7 and result.bytesData == nil, "envelope metadata was not preserved")
end

local context = fixtures[1].context
local plain = { code = 0, data = { valid = true } }
check(crypto.decode(context, plain) == plain, "plain response must pass through")
local business_error = { code = 1, message = "purchase required", data = json.null }
check(crypto.decode(context, business_error) == business_error, "business response must pass through")
local value, err = crypto.decode(context, { code = 0, data = json.null })
check(value == nil and err.code == "missing_response_data", "missing data must fail")
for _, encoded in ipairs({ "", "AAAAA", "AA A", "AA=A", "AA==AAAA", "AB==", "AAB=" }) do
    value, err = crypto.decrypt(context, encoded)
    check(value == nil and err.code == "invalid_base64", "non-canonical Base64 must fail")
end
value, err = crypto.decrypt(context, "AAAA")
check(value == nil and err.code == "invalid_ciphertext", "partial block must fail")
local invalid = read_json("crypto-response-invalid-fixtures.json")
for _, fixture in ipairs(invalid.fixtures) do
    value, err = crypto.decrypt(invalid.context, fixture.data)
    check(value == nil and err.code == fixture.code, "invalid content must fail with " .. fixture.code)
end
value, err = crypto.deriveKey({ url = "/twirp/comic.v1.Comic/Unknown", body = "{}" })
check(value == nil and err.code == "unsupported_endpoint", "unknown path must fail")
value, err = crypto.deriveKey({ url = context.url, body = "{}", platform = "android" })
check(value == nil and err.code == "unsupported_platform", "unverified platform must fail")
value, err = crypto.deriveKey({ url = context.url, body = "{}", buvid = "\xFF" })
check(value == nil and err.code == "invalid_buvid", "non-ASCII buvid must fail")
value, err = crypto.deriveKey({ url = context.url, body = "{\"comic_id\":1.5}" })
check(value == nil and err.code == "invalid_key_field", "fractional key field must fail")
print("PASS " .. assertions .. " response crypto assertions")
