local root, output, assets = assert(arg[1]), assert(arg[2]), assert(arg[3])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path

local Assets = require("bilicomics/protocol/assets")
local Backend = require("bilicomics/protocol/native_backend")
local Client = require("bilicomics/protocol/client")
local Crypto = require("bilicomics/protocol/crypto")
local ECDH = require("bilicomics/protocol/ecdh")
local JSON = require("bilicomics/protocol/json")
local Session = require("bilicomics/protocol/session")
local passed = {}

local function test(name, fn)
    local ok, err = pcall(fn)
    assert(ok, name .. ": " .. tostring(err))
    passed[#passed + 1] = name
    print("PASS " .. name)
end

local backend = Backend.new({ asset_root = assets })

test("native signing bridge reproduces the official WASM golden vector", function()
    local context = {
        sign_query = "device=pc&platform=web&nov=27&eot=812", body = '{"comic_id":36215}', timestamp_ms = 1789171200000,
    }
    local signed = assert(backend:signRequest(context))
    assert(signed.ultra_sign == "dRas4960Rha0D2RL60weLdR0w6LK69ddXhkLYasGd1sKYaXf")
    assert(signed.data_sn == "1E74C20E5720FBF3BB351965D7A9DFC1")
end)

test("production response bridge decodes the official synthetic ciphertext", function()
    local decoded = assert(backend:decodeResponse({ path = "/twirp/comic.v1.Comic/ComicDetail",
        body = '{"comic_id":36215}', buvid = "SYNTHETIC-BUVID", platform = "web" },
        { code = 0, bytesData = "yHEYgHkBOklQxZUed3mFB7VmJEAMe8nOHxniUEThJGI=", trace = "fixture" }))
    assert(decoded.data.fixture == "crypto" and decoded.trace == "fixture" and decoded.bytesData == nil)
end)

test("P-256 exchange uses independent ephemeral material and validates serialized keys", function()
    local first, second = assert(ECDH.newKey()), assert(ECDH.newKey())
    assert(#first.m1 == 88 and first.m1 ~= second.m1 and first.private_key ~= second.private_key)
    local restored = assert(ECDH.deserialize(assert(ECDH.serialize(first))))
    assert(restored.m1 == first.m1 and restored.private_key == first.private_key)
    assert(not ECDH.serialize({ m1 = first.m1, private_key = second.private_key }))
end)

test("token exchange keeps private material inside the current client", function()
    local transport = { request_count = 0 }
    function transport:request(request)
        self.request_count = self.request_count + 1
        self.request_body = assert(JSON.decode(request.body))
        return { status = 200, body = '{"code":0,"data":[{"url":"https://i0.hdslb.com/fixture.jpg","token":"synthetic-token","hit_encrpyt":false}]}' }
    end
    local client = Client.new({
        session = assert(Session.parse("SESSDATA=synthetic; DedeUserID=42")), transport = transport,
        crypto = Crypto.new({ backend = backend }), clock = function() return 1789171200 end,
    })
    local tokens = assert(client:imageTokens({ "/fixture/path" }, { index = 14 }))
    assert(#tokens == 1 and tokens[1].source_index == 14)
    assert(client._token_context.private_key and not tokens[1].private_key)
    assert(transport.request_body.m1 == client._token_context.m1)
    assert(transport.request_body.urls == '["/fixture/path"]')
    assert(not transport.request_body.private_key)
end)

test("missing browser environment follows the official explicit error-report branch", function()
    local value = assert(backend:prepareIndex({ episode_id = "1", timestamp_ms = 1789171200000 }))
    assert(value.challenge_status == "environment_error_reported")
    assert(value.m2 == "error:BiliComics local reader has no browser fingerprint environment_1789171200000")
    assert(backend:capabilities().index_challenge == false and backend:capabilities().index_error_reporting == true)
end)

test("catalog and index requests sign the same m2 error report they transmit", function()
    local transport = { requests = {} }
    function transport:request(request)
        self.requests[#self.requests + 1] = request
        local body = assert(JSON.decode(request.body))
        assert(type(body.m2) == "string" and body.m2:find("^error:BiliComics local reader"))
        if body.comic_id then
            return { status = 200, body = '{"code":0,"data":{"id":36215,"ep_list":[]}}' }
        end
        assert(body.ep_id == 12)
        return { status = 200, body = '{"code":0,"data":{"images":[{"path":"/synthetic/image","x":24,"y":37}]}}' }
    end
    local client = Client.new({ session = assert(Session.parse("SESSDATA=synthetic")), transport = transport,
        crypto = Crypto.new({ backend = backend }), clock = function() return 1789171200 end })
    assert(client:comicDetail("36215").comic.id == "36215")
    local index = assert(client:imageIndex("12"))
    assert(#index.images == 1 and index.images[1].x == 24 and #index.revision == 64)
    for _, request in ipairs(transport.requests) do
        local signed = assert(backend:signRequest({ sign_query = "device=pc&platform=web&nov=27&eot=812",
            body = request.body, timestamp_ms = 1789171200000 }))
        local wire_sign = assert(request.url:match("[?&]ultra_sign=([^&]+)")):gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end)
        assert(wire_sign == signed.ultra_sign)
    end
end)

test("pinned asset acquisition rejects modified code before installation", function()
    local root_path = output .. "/bad-assets"
    local transport = {}
    function transport:request(request)
        local file = assert(io.open(request.output_path, "wb"))
        file:write("synthetic invalid module"); file:close()
        return { status = 200 }
    end
    local value, err = Assets.ensure("signing", { root = root_path, transport = transport })
    assert(value == nil and err.kind == "protocol_asset")
    assert(not io.open(root_path .. "/" .. Assets.manifest.signing.filename, "rb"))
end)

local result = assert(io.open(output .. "/crypto-result.json", "wb"))
result:write(assert(JSON.encode({ passed = #passed, cases = passed }))); result:close()
