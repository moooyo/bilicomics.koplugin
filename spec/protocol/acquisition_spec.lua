local root, output = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local Client = require("bilicomics/protocol/client")
local JSON = require("bilicomics/protocol/json")
local mime = require("mime")
local passed = {}

local function read(path)
    local file = assert(io.open(path, "rb"))
    local bytes = file:read("*a"); file:close()
    return bytes
end

local legacy = assert(JSON.decode(read(root .. "/research/protocol/image-legacy-fixtures.json")))
local fixtures = {}
for _, fixture in ipairs(legacy) do
    local expected = mime.unb64(fixture.expectedBase64)
    if expected:sub(1, 8) == "\137PNG\r\n\026\n" then fixtures[#fixtures + 1] = fixture end
end
local modern = assert(JSON.decode(read(root .. "/research/protocol/image-v8-fixtures.json")))
for _, fixture in ipairs(modern.cases) do
    local expected = mime.unb64(fixture.expectedBase64)
    if expected:sub(1, 8) == "\137PNG\r\n\026\n" then fixtures[#fixtures + 1] = fixture end
end
local png_fixture = root .. "/research/protocol/image-v8-png-fixture.json"
local png_file = io.open(png_fixture, "rb")
if png_file then
    local fixture = assert(JSON.decode(png_file:read("*a")))
    png_file:close()
    fixtures[#fixtures + 1] = fixture
end

for number, fixture in ipairs(fixtures) do
    local expected = mime.unb64(fixture.expectedBase64)
    local transport = { calls = 0 }
    function transport:request(request)
        self.calls = self.calls + 1
        assert(request.method == "GET" and not request.headers.cookie)
        assert(request.output_path)
        local file = assert(io.open(request.output_path, "wb"))
        local body = mime.unb64(fixture.bodyBase64)
        file:write(body); file:close()
        return { status = 200 }
    end
    local client = Client.new({ transport = transport })
    client._token_context = { private_key = fixture.privateKey }
    local url = "https://i0.hdslb.com/synthetic.png?" .. assert(fixture.url:match("%?(.*)$"))
    local path = output .. "/acquired-" .. number .. ".part"
    local result, err = client:downloadImage({ complete_url = url, hit_encrpyt = true }, path, { index = fixture.index or 0 })
    assert(result, "Encrypted acquisition failed: " .. tostring(err and err.message))
    assert(transport.calls == 1 and result.temporary_path == path and result.format == "png")
    assert(result.width > 0 and result.height > 0 and result.verification == "container")
    assert(read(path) == expected, "The committed candidate differs from the official plaintext.")
    assert(result.checksum == require("ffi/sha2").sha256(expected))
    passed[#passed + 1] = "encrypted acquisition version " .. fixture.version .. " fixture " .. number
end

local malformed_path = output .. "/malformed-encrypted.part"
local transport = {}
function transport:request(request)
    local file = assert(io.open(request.output_path, "wb"))
    file:write("not an encrypted container"); file:close()
    return { status = 200 }
end
local client = Client.new({ transport = transport })
client._token_context = { private_key = fixtures[1].privateKey }
local value, err = client:downloadImage({ complete_url = "https://i0.hdslb.com/synthetic?ts=0", hit_encrpyt = true }, malformed_path)
assert(value == nil and err and not io.open(malformed_path, "rb"), "Failed conversion must remove the unusable temporary file.")
passed[#passed + 1] = "failed conversion removes its temporary file"

local file = assert(io.open(output .. "/acquisition-result.json", "wb"))
file:write(assert(JSON.encode({ passed = #passed, cases = passed }))); file:close()
print("PASS encrypted acquisition integration: " .. #passed)
