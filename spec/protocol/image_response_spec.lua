local root, output, jpeg_path = assert(arg[1]), assert(arg[2]), assert(arg[3])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path

local Client = require("bilicomics/protocol/client")
local JSON = require("bilicomics/protocol/json")
local mime = require("mime")
local passed, requests = {}, 0

local function read(path)
    local file = assert(io.open(path, "rb"))
    local bytes = file:read("*a")
    assert(file:close())
    return bytes
end

local fixture = assert(JSON.decode(read(root .. "/research/protocol/image-v8-png-fixture.json")))
local png, container = mime.unb64(fixture.expectedBase64), mime.unb64(fixture.bodyBase64)
local jpeg = read(jpeg_path)
assert(jpeg:sub(1, 2) == "\255\216")
local url = "https://i0.hdslb.com/synthetic.png?" .. assert(fixture.url:match("%?(.*)$"))

local function test(name, fn)
    local ok, err = pcall(fn)
    assert(ok, name .. ": " .. tostring(err))
    passed[#passed + 1] = name
    print("PASS " .. name)
end

local function responseCase(body, headers, expected, options)
    options = options or {}
    requests = requests + 1
    local path = output .. "/response-" .. requests .. ".part"
    local calls = 0
    local transport = {}
    function transport:request(request)
        calls = calls + 1
        assert(request.method == "GET" and request.url == url .. "&code=DanmakuInfo")
        assert(request.output_path == path)
        assert(request.max_bytes <= 16 * 1024 * 1024)
        assert(not request.headers.cookie and not request.headers.authorization)
        local file = assert(io.open(path, "wb"))
        assert(file:write(body))
        assert(file:close())
        return { status = options.status or 200, headers = headers }
    end
    local client = Client.new({ transport = transport })
    client._token_context = { private_key = fixture.privateKey }
    local value, err = client:downloadImage({ complete_url = url, hit_encrpyt = true }, path,
        {index = fixture.index or 0, max_bytes = options.max_bytes, max_pixels = options.max_pixels})
    assert(calls == 1)
    if expected then
        assert(value, err and err.message)
        assert(read(path) == expected.bytes and value.format == expected.format)
        assert(value.width > 0 and value.height > 0)
        assert(value.checksum == require("ffi/sha2").sha256(expected.bytes))
        assert(os.remove(path))
    else
        assert(value == nil and err)
        assert(err.kind == options.error_kind, err.kind .. ": " .. tostring(err.message))
        assert(io.open(path, "rb") == nil, "A rejected response left a temporary candidate")
        if options.status == 400 then assert(err.status == 400 and err.retryable == false) end
    end
end

test("encrypted token with image JPEG response preserves and validates the original JPEG", function()
    responseCase(jpeg, {["content-type"] = "image/jpeg"}, {bytes = jpeg, format = "jpg"})
end)

test("encrypted token with image PNG response preserves and validates the original PNG", function()
    responseCase(png, {["content-type"] = "image/png; charset=binary"}, {bytes = png, format = "png"})
    responseCase(png, {["Content-Type"] = "image/png"}, {bytes = png, format = "png"})
end)

test("image headers cannot admit malformed or truncated image bytes", function()
    responseCase("synthetic invalid image", {["content-type"] = "image/jpeg"}, nil, {error_kind = "invalid_image"})
    responseCase(jpeg:sub(1, 16), {["content-type"] = "image/jpeg"}, nil, {error_kind = "invalid_image"})
    responseCase(png:sub(1, 24), {["content-type"] = "image/png"}, nil, {error_kind = "invalid_image"})
    responseCase(container, {["content-type"] = "image/png"}, nil, {error_kind = "invalid_image"})
end)

test("plain bytes without the official image header stay in the container rejection path", function()
    responseCase(jpeg, nil, nil, {error_kind = "capability"})
    responseCase(jpeg, {["content-type"] = "application/octet-stream"}, nil, {error_kind = "capability"})
    responseCase(jpeg, {["content-type"] = "Image/jpeg"}, nil, {error_kind = "capability"})
end)

test("image pass-through still enforces the bounded response size", function()
    responseCase(jpeg, {["content-type"] = "image/jpeg"}, nil, {max_bytes = 64, error_kind = "image_size"})
end)

test("image pass-through still uses Client geometry limits", function()
    responseCase(png, {["content-type"] = "image/png"}, nil, {max_pixels = 100, error_kind = "image_size"})
end)

test("image header does not bypass HTTP failure handling or cleanup", function()
    responseCase(jpeg, {["content-type"] = "image/jpeg"}, nil, {status = 400, error_kind = "image_http"})
end)

test("supported encrypted containers retain actual conversion with nonimage or missing headers", function()
    responseCase(container, {["content-type"] = "application/octet-stream"}, {bytes = png, format = "png"})
    responseCase(container, nil, {bytes = png, format = "png"})
end)

local file = assert(io.open(output .. "/image-response-result.json", "wb"))
assert(file:write(assert(JSON.encode({passed = #passed, cases = passed, injected_cdn_requests = requests,
    real_network_requests = 0, scope = "Official header branch, actual image inspection, crypto, limits, and cleanup"}))))
assert(file:close())
