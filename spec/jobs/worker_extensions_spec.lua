-- Run only inside the isolated test-env KOReader runtime.
require("setupkoenv")
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. package.path

local json = require("rapidjson")
local ffi = require("ffi")
local Files = require("bilicomics/storage/files")
local RealClient = require("bilicomics/protocol/client")
local tests, factory, created_options = {}, nil, {}
local evidence = {}
local protocol_key = "bilicomics/protocol/client"
package.loaded[protocol_key] = { new = function(options)
    created_options[#created_options + 1] = options
    return assert(factory, "The test must install a protocol client factory")(options)
end }
local Worker = require("bilicomics/jobs/worker")
package.loaded[protocol_key] = RealClient

local function test(name, fn)
    created_options = {}
    factory = function() error("Unexpected protocol client construction") end
    local ok, failure = xpcall(fn, debug.traceback)
    tests[#tests + 1] = { name = name, passed = ok, error = ok and nil or failure }
    print((ok and "PASS " or "FAIL ") .. name)
end

local function onlyKeys(value, allowed, label)
    assert(type(value) == "table", label .. " must be a table")
    for key in pairs(value) do assert(allowed[key], label .. " contains an unexpected field: " .. tostring(key)) end
end

local function mutationClient(callback)
    local calls = {}
    factory = function()
        return { setFavorite = function(_, comic_id, favorite)
            calls[#calls + 1] = { comic_id = comic_id, favorite = favorite }
            return callback(comic_id, favorite)
        end }
    end
    return calls
end

local function assertMutationResult(result, comic_id, favorite)
    onlyKeys(result, { accepted = true, comic_id = true, favorite = true }, "Favorite result")
    assert(result.accepted == true and result.comic_id == tostring(comic_id) and result.favorite == favorite,
        "The confirmed favorite result must preserve the requested comic and boolean state")
end

for _, favorite in ipairs({ true, false }) do
    test("Favorite worker forwards " .. tostring(favorite) .. " and returns only its confirmed state", function()
        local comic_id = favorite and "12345" or 67890
        local calls = mutationClient(function(received_id, received_favorite)
            assert(received_id == comic_id and received_favorite == favorite, "Favorite arguments must pass through without reinterpretation")
            return { cookie = "synthetic-mutation-cookie", private = { value = "synthetic-private-result" } }
        end)
        local result, err = Worker.execute({ kind = "set_favorite", comic_id = comic_id, favorite = favorite })
        assert(err == nil and #calls == 1, "A successful favorite change must call the client exactly once")
        assertMutationResult(result, comic_id, favorite)
    end)
end

test("Favorite worker accepts the client's explicit boolean success", function()
    local calls = mutationClient(function() return true end)
    local result, err = Worker.execute({ kind = "set_favorite", comic_id = "12345", favorite = true })
    assert(err == nil and #calls == 1, "Explicit client success must settle exactly once")
    assertMutationResult(result, "12345", true)
end)

test("A nil favorite result without an error cannot become a confirmation", function()
    local calls = mutationClient(function() return nil end)
    local result, err = Worker.execute({ kind = "set_favorite", comic_id = "12345", favorite = true })
    assert(result == nil and err == nil and #calls == 1, "Absent success must not be replaced by an accepted result")
end)

test("A false favorite result preserves the client failure", function()
    local rejected = { kind = "business", code = 99, retryable = false }
    local calls = mutationClient(function() return false, rejected end)
    local result, err = Worker.execute({ kind = "set_favorite", comic_id = "12345", favorite = false })
    assert(result == nil and err == rejected and #calls == 1, "False success must not confirm the requested state")
end)

test("An uncertain favorite timeout is propagated without retry or confirmation", function()
    local uncertain = { kind = "timeout", transmitted = true, retryable = true }
    local calls = mutationClient(function() return nil, uncertain end)
    local result, err = Worker.execute({ kind = "set_favorite", comic_id = "12345", favorite = true })
    assert(result == nil and err == uncertain and #calls == 1, "A timeout must retain its uncertain transmission evidence")
end)

test("Read-only client operations reject the favorite mutation method", function()
    local calls = mutationClient(function() return true end)
    local result, err = Worker.execute({ kind = "client", method = "setFavorite", arguments = { "12345", true } })
    assert(result == nil and err and err.kind == "invalid_request" and #calls == 0,
        "The read-only worker entry point must not invoke setFavorite")
end)

local function productionClient(response)
    local requests = {}
    local client = RealClient.new({ session = { cookies = { SESSDATA = "synthetic-favorite-session" } }, crypto = {},
        transport = { request = function(_, request)
            requests[#requests + 1] = request
            if type(response) == "function" then return response(request) end
            return response
        end } })
    factory = function() return client end
    return client, requests
end

for _, favorite in ipairs({ true, false }) do
    test("Production client uses the " .. (favorite and "AddFavorite" or "DeleteFavorite") .. " wire contract", function()
        local endpoint, comic_id = favorite and "AddFavorite" or "DeleteFavorite", favorite and 12345 or "67890"
        local _, requests = productionClient({ status = 200, transmitted = true,
            body = favorite and '{"code":0,"data":{}}' or '{"code":0}' })
        local result, err = Worker.execute({ kind = "set_favorite", comic_id = comic_id, favorite = favorite })
        assert(err == nil and #requests == 1, "A successful favorite mutation must send exactly one request")
        local request = requests[1]
        assert(request.method == "POST" and request.url:find("https://manga.bilibili.com/twirp/bookshelf.v1.Bookshelf/" .. endpoint .. "?", 1, true) == 1,
            "Favorite state must choose its exact bookshelf endpoint")
        local payload = assert(json.decode(request.body))
        onlyKeys(payload, { comic_ids = true }, "Favorite request payload")
        assert(type(payload.comic_ids) == "string" and payload.comic_ids == tostring(comic_id),
            "The service expects comic_ids as a string rather than an array or number")
        assertMutationResult(result, comic_id, favorite)
    end)
end

test("Production client business rejection never becomes a favorite confirmation", function()
    local _, requests = productionClient({ status = 200, transmitted = true, body = '{"code":99,"data":{}}' })
    local result, err = Worker.execute({ kind = "set_favorite", comic_id = "12345", favorite = true })
    assert(result == nil and err and err.kind == "business" and #requests == 1,
        "HTTP success without business success must not confirm the mutation")
end)

test("Production client validates identifiers and boolean favorite state before transport", function()
    local client, requests = productionClient({ status = 200, body = '{"code":0}' })
    local result, err = client:setFavorite("0", true)
    assert(result == nil and err and err.kind == "invalid_request" and err.transmitted == false,
        "An invalid comic identifier must be rejected before transmission")
    result, err = client:setFavorite("12345", "false")
    assert(result == nil and err and err.kind == "invalid_request" and err.transmitted == false and #requests == 0,
        "A string favorite state must never be interpreted as a boolean mutation")
end)

local capability_keys = {
    request_signing = true, response_decoding = true, index_challenge = true, index_error_reporting = true,
    image_key_exchange = true, encrypted_images = true, protected_catalog = true, image_index = true,
    image_tokens = true, plain_images = true,
}

local function diagnosticShape(result, checked)
    onlyKeys(result, { koreader_version = true, plugin_version = true, platform = true, capabilities = true,
        capability_check_ok = true, network_checked = true }, "Diagnostics result")
    onlyKeys(result.platform, { os = true, arch = true, target = true }, "Diagnostic platform")
    onlyKeys(result.capabilities, capability_keys, "Diagnostic capabilities")
    local count = 0
    for key in pairs(capability_keys) do
        assert(type(result.capabilities[key]) == "boolean", "Each published capability must be an explicit boolean")
        count = count + 1
    end
    assert(count == 10 and result.capability_check_ok == checked and result.network_checked == false,
        "Local diagnostics must distinguish capability inspection from live network verification")
    assert(result.platform.os == ffi.os and result.platform.arch == ffi.arch,
        "Diagnostic platform must describe the running KOReader process")
end

local private_marker = "synthetic-diagnostic-private-value"
local function diagnosticRequest()
    return { kind = "diagnostics", session = { cookies = { SESSDATA = private_marker } },
        transport_options = { proxy = "https://example.invalid/" .. private_marker },
        asset_root = "/synthetic/" .. private_marker }
end

local function assertAnonymousOptions(options)
    onlyKeys(options, { transport = true }, "Diagnostic client options")
    assert(options.session == nil and options.transport_options == nil and options.asset_root == nil,
        "Diagnostic clients must not inherit request credentials, transport configuration or asset paths")
    assert(type(options.transport) == "table" and type(options.transport.request) == "function",
        "Diagnostic clients must receive a transport that explicitly rejects network acquisition")
end

test("Diagnostic capability inspection has an anonymous offline transport and a strict public shape", function()
    local blocked_requests = 0
    factory = function(options)
        assertAnonymousOptions(options)
        return { capabilities = function()
            local result, err = options.transport:request({ url = "https://example.invalid/" .. private_marker,
                headers = { cookie = private_marker } })
            blocked_requests = blocked_requests + 1
            assert(result == nil and err and err.kind == "diagnostics_offline",
                "A capability implementation cannot use the supplied diagnostic transport to obtain network assets")
            return {
                protected_catalog = true, image_index = true, image_tokens = private_marker, plain_images = false,
                cookie = private_marker, url = "https://example.invalid/" .. private_marker,
                private = { value = private_marker }, network_checked = true,
                crypto = { request_signing = true, response_decoding = 1, index_challenge = private_marker,
                    index_error_reporting = true, image_key_exchange = false, encrypted_images = true,
                    cookie = private_marker, url = "https://example.invalid/" .. private_marker,
                    private_key = private_marker, backend = private_marker },
            }
        end }
    end
    local result, err = Worker.execute(diagnosticRequest())
    assert(err == nil and #created_options == 1 and blocked_requests == 1, "Diagnostics must inspect exactly one anonymous client")
    diagnosticShape(result, true)
    local expected = { request_signing = true, response_decoding = false, index_challenge = false,
        index_error_reporting = true, image_key_exchange = false, encrypted_images = true,
        protected_catalog = true, image_index = true, image_tokens = false, plain_images = false }
    for key, value in pairs(expected) do assert(result.capabilities[key] == value, "Only literal true may publish a supported capability") end
    assert(not json.encode(result):find(private_marker, 1, true), "Credential, URL and private capability values must not enter the result")
end)

test("Capability exceptions report only boolean failure without exception text", function()
    factory = function(options)
        assertAnonymousOptions(options)
        return { capabilities = function() error("Failed secret URL https://example.invalid/" .. private_marker) end }
    end
    local result, err = Worker.execute(diagnosticRequest())
    assert(err == nil and #created_options == 1, "A capability exception must not become a worker exception or raw error result")
    diagnosticShape(result, false)
    for key in pairs(capability_keys) do assert(result.capabilities[key] == false, "Failed inspection must not publish usable capabilities") end
    assert(not json.encode(result):find(private_marker, 1, true), "Capability exception details must stay out of diagnostics")
end)

test("Malformed capability results are unavailable without exposing their contents", function()
    factory = function(options)
        assertAnonymousOptions(options)
        return { capabilities = function() return private_marker end }
    end
    local result, err = Worker.execute(diagnosticRequest())
    assert(err == nil, "Malformed capabilities must produce structured local diagnostics")
    diagnosticShape(result, false)
    assert(not json.encode(result):find(private_marker, 1, true), "Malformed capability contents must not be echoed")
end)

test("A real diagnostic Client stays anonymous and its actual request path remains offline", function()
    local actual_client, checked
    factory = function(options)
        assertAnonymousOptions(options)
        actual_client = RealClient.new(options)
        assert(actual_client.session == nil and actual_client.transport == options.transport,
            "The real Client must retain the anonymous diagnostic configuration")
        local original = actual_client.capabilities
        actual_client.capabilities = function(self)
            local value, err = self:_post("user.v1.User", "GetWallet", {}, { auth = false })
            assert(value == nil and err and err.kind == "diagnostics_offline",
                "Even the real Client request path must be rejected by the diagnostic transport")
            checked = true
            return original(self)
        end
        return actual_client
    end
    local result, err = Worker.execute(diagnosticRequest())
    assert(err == nil and checked and #created_options == 1 and actual_client.session == nil,
        "The real capability inspection must not import the request's synthetic credentials")
    diagnosticShape(result, true)
    assert(not json.encode(result):find(private_marker, 1, true), "The real anonymous Client must not expose ignored input fields")
    evidence.real_diagnostic_client = { session_absent = true, request_error = "diagnostics_offline" }
end)

test("Diagnostic versions come from the actual KOReader runtime and complete plugin source", function()
    factory = function(options)
        assertAnonymousOptions(options)
        return { capabilities = function() return {} end }
    end
    local result, err = Worker.execute(diagnosticRequest())
    assert(err == nil, "Version diagnostics must complete with locally available metadata")
    diagnosticShape(result, true)
    local expected_koreader = require("version"):getCurrentRevision()
    local metadata = assert(loadfile(source .. "/_meta.lua"))()
    assert(type(expected_koreader) == "string" and expected_koreader ~= "" and result.koreader_version == expected_koreader,
        "The KOReader version must match the actual runtime revision")
    assert(type(metadata.version) == "string" and metadata.version ~= "" and result.plugin_version == metadata.version,
        "The plugin version must come from the staged source metadata")
    assert(result.platform.target == require("bilicomics/protocol/platform").nativeTarget(),
        "The reported native target must match the production platform detector")
    evidence.versions = { koreader = result.koreader_version, plugin = result.plugin_version, target = result.platform.target }
end)

local passed = true
for _, item in ipairs(tests) do passed = passed and item.passed end
Files.write(output .. "/extensions-result.json", json.encode({ tests = tests, passed = passed, evidence = evidence,
    scope = "Production Worker and Client with injected transports; local capability and runtime metadata inspection; no live network or account access" }, { pretty = true }))
assert(passed, "One or more worker extension contract tests failed")
