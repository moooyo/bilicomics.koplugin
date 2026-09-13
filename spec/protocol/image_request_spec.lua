local root, output = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path

local Client = require("bilicomics/protocol/client")
local JSON = require("bilicomics/protocol/json")
local Session = require("bilicomics/protocol/session")
local mime = require("mime")
local passed = {}

local function read(path)
    local file = assert(io.open(path, "rb"))
    local bytes = file:read("*a")
    assert(file:close())
    return bytes
end

local fixture = assert(JSON.decode(read(root .. "/research/protocol/image-v8-png-fixture.json")))
local plaintext, encrypted = mime.unb64(fixture.expectedBase64), mime.unb64(fixture.bodyBase64)
local query = assert(fixture.url:match("%?(.*)$")) .. "&token=synthetic%2B%2f+value%253D&opaque=%2F%2f%252F"
local path_and_query = "/synthetic%2Fsegment.png?" .. query
local session = assert(Session.parse("SESSDATA=synthetic-only; DedeUserID=42; bili_jct=synthetic-csrf; XSRF-TOKEN=synthetic-xsrf"))
local next_file = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    assert(ok, name .. ": " .. tostring(err))
    passed[#passed + 1] = name
    print("PASS " .. name)
end

local function requestCase(token, expected_url, status)
    next_file = next_file + 1
    local path = output .. "/request-" .. next_file .. ".part"
    local calls = 0
    local original_url, original_token = token.complete_url, token.token
    local transport = {}
    function transport:request(request)
        calls = calls + 1
        assert(request.method == "GET" and request.url == expected_url)
        assert(request.output_path == path)
        for name in pairs(request.headers) do
            local lower = name:lower()
            assert(lower ~= "cookie" and lower ~= "authorization" and lower ~= "proxy-authorization"
                and lower ~= "x-xsrf-token", "Account credentials reached the CDN boundary")
        end
        local file = assert(io.open(path, "wb"))
        assert(file:write(token.hit_encrpyt and encrypted or plaintext))
        assert(file:close())
        return { status = status or 200 }
    end
    local client = Client.new({ session = session, transport = transport })
    client._token_context = { private_key = fixture.privateKey }
    local result, err = client:downloadImage(token, path, { index = fixture.index or 0 })
    assert(calls == 1 and token.complete_url == original_url and token.token == original_token)
    if status == 400 then
        assert(result == nil and err.kind == "image_http" and err.status == 400 and err.retryable == false)
        assert(io.open(path, "rb") == nil, "An HTTP failure left a temporary candidate")
    else
        assert(result, err and err.message)
        assert(result.format == "png" and result.width == 128 and result.height == 128)
        assert(read(path) == plaintext, "The actual image preparation changed the golden plaintext")
        assert(result.checksum == require("ffi/sha2").sha256(plaintext))
        assert(os.remove(path))
    end
end

test("HTTPS complete URLs preserve every parameter byte and use the official marker in both paths", function()
    for _, is_encrypted in ipairs({ false, true }) do
        local url = "https://i0.hdslb.com" .. path_and_query
        requestCase({ complete_url = url, hit_encrpyt = is_encrypted }, url .. "&code=DanmakuInfo")
    end
end)

test("protocol relative complete URLs resolve HTTPS and retain the official marker in both paths", function()
    for _, is_encrypted in ipairs({ false, true }) do
        local url = "//i0.hdslb.com" .. path_and_query
        requestCase({ complete_url = url, hit_encrpyt = is_encrypted }, "https:" .. url .. "&code=DanmakuInfo")
    end
end)

test("original HTTP complete URLs upgrade without the marker exactly as the reader does", function()
    for _, is_encrypted in ipairs({ false, true }) do
        requestCase({ complete_url = "http://i0.hdslb.com" .. path_and_query, hit_encrpyt = is_encrypted },
            "https://i0.hdslb.com" .. path_and_query)
    end
end)

test("complete URL handling does not deduplicate or rewrite an existing code parameter", function()
    local url = "https://i0.hdslb.com" .. path_and_query .. "&code=existing"
    requestCase({ complete_url = url }, url .. "&code=DanmakuInfo")
end)

test("legacy URL and token fallback keeps its existing encoding contract", function()
    local url = "https://i0.hdslb.com" .. path_and_query
    requestCase({ url = url, token = "a+b/c==&x=1" }, url .. "&token=a%2Bb%2Fc%3D%3D%26x%3D1")
    requestCase({ url = "//i0.hdslb.com/synthetic.png", token = "opaque" },
        "https://i0.hdslb.com/synthetic.png?token=opaque")
end)

test("HTTP 400 remains nonretryable and removes candidates in both image paths", function()
    for _, is_encrypted in ipairs({ false, true }) do
        local url = "https://i0.hdslb.com" .. path_and_query
        requestCase({ complete_url = url, hit_encrpyt = is_encrypted }, url .. "&code=DanmakuInfo", 400)
    end
end)

local file = assert(io.open(output .. "/image-request-result.json", "wb"))
assert(file:write(assert(JSON.encode({passed = #passed, cases = passed, injected_cdn_requests = next_file,
    real_network_requests = 0, scope = "Image URL, credential isolation, real synthetic conversion, and HTTP cleanup"}))))
assert(file:close())
