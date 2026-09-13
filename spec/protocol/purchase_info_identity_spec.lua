-- Real Client response validation with exact in-memory quote envelopes only.
local root, output = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local ffi = require("ffi")
local json = require("rapidjson")
local report = { passed = false, assertions = 0, groups = {}, fake_transport_calls = 0,
    rejected_routes = 0, real_transport_attempts = 0, buy_episode_attempts = 0,
    forbidden_module_attempts = 0, synthetic_session_only = true,
    scope = "Real Client.purchaseInfo and QuoteFetch; fake quote envelopes and in-memory catalog; no real API or purchase" }
ffi.cdef[[long readlink(const char *path, char *buf, unsigned long size);]]
local buffer = ffi.new("char[128]")
local length = ffi.C.readlink("/proc/self/ns/net", buffer, 128)
assert(length > 0 and ffi.string(buffer, length) ~= assert(os.getenv("BILI_IDENTITY_PARENT_NETNS")),
    "A distinct network namespace is required")
report.network_namespace_isolated = true

package.preload["bilicomics/protocol/transport"] = function()
    local function denied()
        report.real_transport_attempts = report.real_transport_attempts + 1
        error("Real transport is forbidden in the identity spec", 0)
    end
    return { new = denied, request = denied }
end
for _, name in ipairs({ "socket.http", "socket.https", "ssl", "bilicomics/protocol/native_backend",
    "bilicomics/purchase/service", "bilicomics/jobs/worker" }) do
    package.preload[name] = function()
        report.forbidden_module_attempts = report.forbidden_module_attempts + 1
        error("Network, native acquisition and submission modules are forbidden", 0)
    end
end
local Client = require("bilicomics/protocol/client")
local JSON = require("bilicomics/protocol/json")
local Fetch = require("bilicomics/purchase/quote_fetch")
Client.buyEpisode = function()
    report.buy_episode_attempts = report.buy_episode_attempts + 1
    error("BuyEpisode is forbidden in the identity spec", 0)
end

local function check(condition, message)
    report.assertions = report.assertions + 1
    assert(condition, message or "Identity contract assertion failed")
end
local function test(name, fn)
    local ok, failure = pcall(fn)
    report.groups[#report.groups + 1] = { name = name, passed = ok, failure = not ok and tostring(failure) or nil }
    print((ok and "PASS " or "FAIL ") .. name .. (not ok and (": " .. tostring(failure)) or ""))
end
local base_url = "https://manga.bilibili.com/twirp/comic.v1.Comic/GetEpisodeBuyInfo?device=pc&platform=web&nov=27&a=810"
local function fixture(envelopes, requested_id, scopes)
    local transport = { calls = 0 }
    function transport:request(request)
        self.calls = self.calls + 1
        report.fake_transport_calls = report.fake_transport_calls + 1
        local scoped = scopes and scopes[self.calls] == true
        local expected_url = base_url .. (scoped and "&getEpisodeDiscounts" or "")
        local body = type(request.body) == "string" and JSON.decode(request.body)
        local expected = { ep_id = tonumber(requested_id or "10") }
        if scoped then expected.buy_type, expected.order = 1, 1 end
        local allowed = request.method == "POST" and request.url == expected_url
            and request.output_path == nil and type(body) == "table" and envelopes[self.calls] ~= nil
            and request.headers and request.headers.cookie == "SESSDATA=synthetic-identity-only"
        if allowed then
            for key, value in pairs(expected) do if body[key] ~= value then allowed = false end end
            for key, value in pairs(body) do if expected[key] ~= value then allowed = false end end
        end
        if not allowed then
            report.rejected_routes = report.rejected_routes + 1
            error("Only the exact planned GetEpisodeBuyInfo envelope is available", 0)
        end
        return { status = 200, body = '{"code":0,"data":' .. envelopes[self.calls] .. '}', transmitted = true }
    end
    return Client.new{ transport = transport, crypto = {},
        session = {cookies = {SESSDATA = "synthetic-identity-only"}}, clock = function() return 1800000000 end }, transport
end
local function rejectEnvelope(data, scope)
    local client, transport = fixture({data}, "10", scope and {true} or nil)
    local value, err = client:purchaseInfo("10", scope)
    check(value == nil and type(err) == "table" and err.kind == "protocol", "Malformed response identity must be rejected")
    check(transport.calls == 1, "The rejection must follow exactly one fake response")
end

test("absent episode identity retains the observed fallback behavior", function()
    local client, transport = fixture({'{"pay_gold":100,"remain_gold":300}'})
    local value, err = client:purchaseInfo("10")
    check(value and not err and value.ep_id == "10")
    check(value.comic_id == nil and value.pay_gold == 100 and value.remain_gold == 300)
    check(transport.calls == 1)
    client, transport = fixture({'{"comic_id":1}'}, "10", {true})
    value, err = client:purchaseInfo("10", {kind = "single", buy_type = 1, order = 1})
    check(value and not err and value.ep_id == "10" and value.comic_id == "1")
    check(transport.calls == 1)
end)

test("present malformed episode identities cannot use the absent-field fallback", function()
    for _, value in ipairs({ "false", "0", '""', "{}", "[]", "null", "-1", "1.5", '"01"', '"1e1"', '"10 "',
        "true", "1000000000000000", '"1000000000000000"', "NaN", "Infinity", "-Infinity" }) do
        rejectEnvelope('{"ep_id":' .. value .. ',"comic_id":1}')
    end
end)

test("a valid but different server episode is rejected", function()
    rejectEnvelope('{"ep_id":11,"comic_id":1}')
    rejectEnvelope('{"ep_id":"11","comic_id":"1"}')
    rejectEnvelope('{"ep_id":false,"comic_id":1}', {kind = "single", buy_type = 1, order = 1})
end)

test("present malformed comic identities cannot bypass normalization", function()
    for _, value in ipairs({ "false", "0", '""', "{}", "[]", "null", "-1", "1.5", '"01"', '"1 "',
        "true", "1000000000000000", '"1000000000000000"', "NaN", "Infinity", "-Infinity" }) do
        rejectEnvelope('{"ep_id":10,"comic_id":' .. value .. '}')
    end
end)

test("valid numeric and string identities are normalized to strings", function()
    for _, entry in ipairs({ { '{"ep_id":10,"comic_id":1}', "10", "1" },
        { '{"ep_id":"10","comic_id":"123456789012345"}', "10", "123456789012345" },
        { '{"ep_id":"123456789012345","comic_id":"1"}', "123456789012345", "1" } }) do
        local client, transport = fixture({entry[1]}, entry[2])
        local value, err = client:purchaseInfo(entry[2])
        check(value and not err and value.ep_id == entry[2] and value.comic_id == entry[3])
        check(type(value.ep_id) == "string" and type(value.comic_id) == "string" and transport.calls == 1)
    end
end)

test("a valid fifteen-digit JSON episode number matches its string request", function()
    for _, id in ipairs({"123456789012345", "999999999999999"}) do
        for _, raw in ipairs({id, '"' .. id .. '"'}) do
            local client, transport = fixture({'{"ep_id":' .. raw .. ',"comic_id":1}'}, id)
            local value, err = client:purchaseInfo(id)
            check(transport.calls == 1)
            check(value and not err and value.ep_id == id, "A valid numeric episode identity must retain all decimal digits")
        end
    end
end)

test("a valid fifteen-digit JSON comic number is stringified exactly", function()
    for _, id in ipairs({"123456789012345", "999999999999999"}) do
        for _, raw in ipairs({id, '"' .. id .. '"'}) do
            local client, transport = fixture({'{"ep_id":10,"comic_id":' .. raw .. '}'})
            local value, err = client:purchaseInfo("10")
            check(transport.calls == 1)
            check(value and not err and value.comic_id == id, "A valid numeric comic identity must retain all decimal digits")
        end
    end
end)

local function fetchedCatalog(mode)
    local data = '{"pay_gold":100,"ep_original_gold":100,"original_gold":1000,"remain_gold":300}'
    local client, transport = fixture({data, data}, "10", {false, true})
    local catalogs = 0
    client.comicDetail = function(_, comic_id)
        catalogs = catalogs + 1
        check(comic_id == "1", "The requested comic identity must reach catalog validation")
        return {comic = {id = mode == "wrong-comic" and "2" or "1"}, episodes = {
            { id = "10", comic_id = mode == "wrong-episode-comic" and "2" or "1", order = 1, access = "locked" },
        }}
    end
    local result, err = Fetch.run(client, {episode_id = "10", comic_id = "1"})
    return result, err, transport, catalogs
end

test("missing response comic ID still requires the matching requested catalog", function()
    local result, err, transport, catalogs = fetchedCatalog("matching")
    check(result and not err and result.info.comic_id == nil and result.info.ep_id == "10")
    check(result.context.comic_id == "1" and result.context.episode_id == "10")
    check(result.context.range_info.comic_id == nil and result.context.range_info.ep_id == "10")
    check(transport.calls == 2 and catalogs == 1)
    for _, mode in ipairs({"wrong-comic", "wrong-episode-comic"}) do
        result, err, transport, catalogs = fetchedCatalog(mode)
        check(result == nil and err and err.kind == "invalid_quote")
        check(transport.calls == 1 and catalogs == 1)
    end
end)

test("missing response and request comic identity cannot fabricate a catalog", function()
    local data = '{"ep_id":10,"pay_gold":100}'
    local client, transport = fixture({data})
    local catalogs = 0
    client.comicDetail = function() catalogs = catalogs + 1; error("No comic identity was available", 0) end
    local result, err = Fetch.run(client, {episode_id = "10"})
    check(result == nil and err and err.kind == "access_unknown")
    check(transport.calls == 1 and catalogs == 0)
end)

test("the focused run cannot access real transport or BuyEpisode", function()
    check(report.real_transport_attempts == 0 and report.buy_episode_attempts == 0)
    check(report.rejected_routes == 0 and report.forbidden_module_attempts == 0)
    check(package.loaded["bilicomics/purchase/service"] == nil and package.loaded["bilicomics/protocol/native_backend"] == nil)
end)

report.passed = true
for _, group in ipairs(report.groups) do if not group.passed then report.passed = false end end
local file = assert(io.open(output, "wb")); file:write(json.encode(report)); file:close()
os.exit(report.passed and 0 or 1)
