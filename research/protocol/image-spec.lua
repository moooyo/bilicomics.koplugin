-- Run from the KOReader directory on test-env, never implicitly on a workstation:
-- ./luajit /checkout/research/protocol/image-spec.lua /checkout
require("setupkoenv")

local root = assert(arg[1], "The plugin checkout path is required.")
local fixture_directory = arg[2] or root .. "/research/protocol"
package.path = root .. "/?.lua;" .. package.path

local json = require("rapidjson")
local mime = require("mime")
local bit = require("bit")
local ImageCrypto = require("bilicomics/protocol/image_crypto")

local function read(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return data
end

local passed = 0
local function check(value, message)
    assert(value, message)
    passed = passed + 1
end

check(ImageCrypto.available(), "The image converter is available.")

local vectors = json.decode(read(fixture_directory .. "/image-v8-fixtures.json"))
for number, fixture in ipairs(vectors.cases) do
    local actual, err = ImageCrypto.convert(fixture.privateKey,
        mime.unb64(fixture.bodyBase64), fixture.url, fixture.index)
    check(actual == mime.unb64(fixture.expectedBase64),
        "Official WASM version 8 vector " .. number .. (err and ": " .. err.message or ""))
end

local fixture = vectors.cases[1]
local body = mime.unb64(fixture.bodyBase64)
local invalid_inputs = {
    { fixture.privateKey, "", fixture.url, 0 },
    { fixture.privateKey, body:sub(1, 138), fixture.url, 0 },
    { fixture.privateKey, body, fixture.url:gsub("ts=[^&]+", "ts=ffffffffffffffff"), 0 },
    { fixture.privateKey, body, fixture.url:gsub("ts=[^&]+", "ts=badz"), 0 },
    { fixture.privateKey, body, fixture.url:gsub("cpx=.*", "cpx=AAAA"), 0 },
    { fixture.privateKey, body, fixture.url .. "&x=%A", 0 },
    { fixture.privateKey, body, fixture.url .. "&x=%QZ", 0 },
    { fixture.privateKey, body, "file:///synthetic", 0 },
    { fixture.privateKey, body, "https://example.invalid/#?ts=0&cpx=AAAA", 0 },
    { fixture.privateKey, body, fixture.url, -1 },
    { fixture.privateKey, body, fixture.url, 0.5 },
    { "", body, fixture.url, 0 },
    { "AAAA", body, fixture.url, 0 },
}
for number, arguments in ipairs(invalid_inputs) do
    local actual, err = ImageCrypto.convert(unpack(arguments))
    check(actual == nil and type(err) == "table" and err.retryable == false,
        "Malformed input " .. number .. " is rejected.")
end

local function alteredByte(value, position)
    return value:sub(1, position - 1)
        .. string.char(bit.bxor(value:byte(position), 1))
        .. value:sub(position + 1)
end

local legacy = json.decode(read(fixture_directory .. "/image-legacy-fixtures.json"))
local counter_vectors = json.decode(read(fixture_directory .. "/image-legacy-counter-fixtures.json"))
for _, sample in ipairs(counter_vectors) do legacy[#legacy + 1] = sample end
for _, sample in ipairs(legacy) do
    local encrypted = mime.unb64(sample.bodyBase64)
    local expected = mime.unb64(sample.expectedBase64)
    local actual, err = ImageCrypto.convert(sample.privateKey, encrypted, sample.url, 0)
    check(actual == expected,
        "Official legacy vector " .. sample.id .. (err and ": " .. err.message or ""))

    local encoded_again = sample.url:gsub("(cpx=)([^&]*)", function(prefix, value)
        return prefix .. value:gsub("%%", function() return "%25" end)
    end)
    check(ImageCrypto.convert(sample.privateKey, encrypted, encoded_again, 0) == expected,
        "Legacy decodeURIComponent compatibility " .. sample.id)

    if sample.version == 5 then
        local position = 5 + math.min(sample.payloadLength, 30 * 1024 + 16)
        local result, invalid = ImageCrypto.convert(sample.privateKey,
            alteredByte(encrypted, position), sample.url, 0)
        check(result == nil and invalid.kind == "crypto", "GCM rejects an altered authentication tag.")
    elseif sample.version == 6 then
        local prefix_length = math.min(sample.payloadLength, 21 * 1024 + 16)
        local position = 5 + prefix_length - 16
        local result, invalid = ImageCrypto.convert(sample.privateKey,
            alteredByte(encrypted, position), sample.url, 0)
        check(result == nil and invalid.code == "invalid_image_padding", "CBC rejects altered PKCS#7 padding.")
    end
end

print(json.encode({
    passed = passed,
    official_wasm_vectors = #vectors.cases,
    official_legacy_vectors = #legacy,
    private_values_logged = false,
}))
