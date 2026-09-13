-- A single separately authorized wallet read. Run only through its private launcher.
local source, session_path, basic_path, output = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
assert(arg[5] == "approved-readonly-wallet-observation", "Explicit read-only wallet authorization is required")
require("setupkoenv")
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local Client = require("bilicomics/protocol/client")
local Session = require("bilicomics/protocol/session")
local Transport = require("bilicomics/protocol/transport")
local JSON = require("bilicomics/protocol/json")
local json = require("rapidjson")
local ffi = require("ffi")
require("ffi/posix_h")
local bit = require("bit")
local allowed_url = "https://manga.bilibili.com/twirp/user.v1.User/GetWallet?device=pc&platform=web&nov=27&a=810"
local report = { schema_version = 1, completed = false, request_count = 0, blocked_requests = 0,
    wallet_returned = false, response_received = false, production_client_used = true,
    production_transport_used = true, tls_verification_retained = true, redirects_disabled = true,
    purchase_submitted = false, account_mutation_requested = false, image_requested = false,
    session_validation_requested = false, automatic_retry_used = false, fields = {}, comparisons = {} }
local function write(name, value)
    assert(name:match("^[a-z0-9%-]+%.json$"))
    local file = assert(io.open(output .. "/" .. name, "wb"))
    assert(file:write(assert(JSON.encode(value)), "\n")); assert(file:close())
end
local function read(path, limit)
    local file = assert(io.open(path, "rb"), "A private input is unavailable")
    local text = file:read(limit + 1); file:close()
    assert(text and #text <= limit, "The private input exceeds its bound")
    return text
end
local function shape(value, key)
    local item
    if type(value) == "table" then item = value[key] end
    if json.null ~= nil and item == json.null then return { present = true, type = "null" } end
    return { present = item ~= nil, type = type(item) }
end
local function compare(left, right, key)
    local a, b = left[key], right[key]
    local kind = type(a)
    local scalar = (kind == "number" or kind == "string" or kind == "boolean") and kind == type(b)
    if kind == "number" then scalar = scalar and a == a and b == b and math.abs(a) < math.huge and math.abs(b) < math.huge end
    local result = { comparison_evaluated = not not scalar }
    if scalar then result.equal = a == b end
    return result
end
local original_request = Transport.request
local http = Transport.new{ timeout = 15, total_timeout = 40, max_json_bytes = 2 * 1024 * 1024 }
function Transport:request(request)
    if report.request_count ~= 0 or type(request) ~= "table" or request.method ~= "POST"
        or request.url ~= allowed_url or request.body ~= "{}" or request.output_path ~= nil or request.ca_file ~= nil then
        report.blocked_requests = report.blocked_requests + 1
        write("wallet-public.json", report)
        return nil, { kind = "observation_guard", message = "The request is outside the single wallet-read scope.", transmitted = false }
    end
    -- Persist the consumed allowance before invoking the real transport.
    local fd = ffi.C.open(output .. "/wallet-request-used", bit.bor(ffi.C.O_WRONLY, ffi.C.O_CREAT, 128), ffi.cast("unsigned int", 384))
    if fd < 0 then
        report.blocked_requests = report.blocked_requests + 1
        write("wallet-public.json", report)
        return nil, { kind = "observation_guard", message = "The wallet-read allowance has already been consumed.", transmitted = false }
    end
    assert(ffi.C.fsync(fd) == 0); ffi.C.close(fd)
    report.request_count = 1
    write("wallet-public.json", report)
    local response, err = original_request(self, request)
    report.response_received = response ~= nil
    report.transport_reported_transmitted = (response and response.transmitted or err and err.transmitted) == true
    if response then write("wallet-wire-private.json", { status = response.status, body = response.body }) end
    return response, err
end

local ok, failure = pcall(function()
    local text = read(session_path, 131072)
    local session = assert(Session.parse(text), "The private session input is invalid")
    text = nil
    local basic = assert(JSON.decode(read(basic_path, 8 * 1024 * 1024)))
    assert(type(basic) == "table", "The private comparison baseline is invalid")
    local client = Client.new{ session = session:serialize(), transport = http, asset_root = output .. "/assets" }
    local wallet, err = client:wallet()
    if not wallet then
        if type(err) == "table" and type(err.kind) == "string" and #err.kind <= 64 and err.kind:match("^[a-z_]+$") then
            report.failure_kind = err.kind
        else report.failure_kind = "unclassified" end
        return
    end
    assert(type(wallet) == "table")
    write("wallet-normalized-private.json", wallet)
    for _, key in ipairs({ "remain_gold", "remain_coupon" }) do
        report.fields[key] = { wallet = shape(wallet, key), basic = shape(basic, key) }
        report.comparisons[key] = compare(wallet, basic, key)
    end
    report.wallet_returned = true
    report.completed = report.request_count == 1 and report.blocked_requests == 0
end)
if not ok then
    write("wallet-error-private.json", { error = tostring(failure) })
    report.failure_kind = "observer_error"
end
write("wallet-public.json", report)
if not report.completed then os.exit(1) end
