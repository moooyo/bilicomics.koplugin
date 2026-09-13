-- Run only in an isolated official KOReader runtime on test-env.
local root, output = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path

local AuthCrypto = require("bilicomics/protocol/auth_crypto")
local JSON = require("bilicomics/protocol/json")
local passed = {}
local started = os.clock()

local function test(name, fn)
    local ok, err = pcall(fn)
    assert(ok, name .. ": " .. tostring(err))
    passed[#passed + 1] = name
    print("PASS " .. name)
end

local function fromHex(value)
    return (value:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end

local function isolatedModule(overrides)
    local chunk = assert(loadfile(root .. "/bilicomics/protocol/auth_crypto.lua"))
    setfenv(chunk, setmetatable(overrides or {}, { __index = _G }))
    return chunk()
end

local function capability(value, err, name)
    assert(value == nil and err.kind == "capability" and err.capability == name)
    assert(err.transmitted == false and err.retryable == false)
end

-- The first vector was reproduced directly with the official JS/WASM and a
-- fixed getRandomValues implementation on test-env on 2026-09-13. The remaining
-- vectors were calculated independently with Python hashlib and integer pow.
local vectors = {
    {
        timestamp = "1700000000000",
        seed = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        ciphertext = "ba7125952a10520b948f6f64ab5a24ddc09b9cfa0c5590e404ec24c5c42e6c098c30d27d6c023d5438f3955eb3cc7411a1994f03ec9175d3031958f42d20d0f123bbd5a4ad35b72fb2dbf7aefbff69f5c3dde0349c31254345db8b385cb7285a6fb9b4d070f4f523545aea4a11fd1c4bccfb468ae5116545deb070ca4f24a568",
    },
    {
        timestamp = "0",
        seed = string.rep("00", 32),
        ciphertext = "6c7d8f98cdb55664d73b80de057d25feb3678098c94c56f0ebdea19daf86d95fcadbd3ddb16490225e6709495077ccadb91a427f9d0525543242920eeccb195d36f99fafb14f790ce39a162538799dcd3fe948600abb3d86466fa525a820ebd591acbec8431ff2e2c6e0a7fa2cc694c30a5e433ef924070738264693c742829d",
    },
    {
        timestamp = "9007199254740991",
        seed = string.rep("ff", 32),
        ciphertext = "7e9a3ab2e313eb58a0d6b10510cc68ab8c387a2d7f846cc67efddfadc291cd0cd85f8f845abc86f05820027d6283fad1ceda8eb25a858287e23d70d776756102d90e17c8ef68b3e4a7f6a2fb2c1d2893bdb6486c5e697a84a39bd1865b05f107b065b5c3d6c4457180c0f4b6ff5e57b689010572ee4e68f8ae363ba5a6800cf0",
    },
    {
        timestamp = "1789257600000",
        seed = string.rep("80", 32),
        ciphertext = "ae5fd1b491e1ece519c0f4f41bb46d2e649dd0c5ba0d63a5059af21211027bd1685f0e03f1a0b85e8d83edbd493b60afdf9170c5643784fdd3fcdcb0f9047b828db65e2dbc8be62547e79113c5018270a680a56e84e23bcb77302ce8249e9e3fb364ab1837d6d370974c846a122e885eb492814d58af34a44eec9ad3b2293840",
    },
    {
        timestamp = "1700000000000",
        seed = "670671cd97404156226e507973f2ab8330d3022ca96e0c93bdbdb320c41adcaf",
        ciphertext = "00f3c95a4113ed600b6867141c26a070db1161da15a832d2a36037fb9edd92b904627b45fd7ae533e37e92166133aa34631b8fc58f06b97b791b5feafbb96c6c8938957772221b66b5f1d8e4880d92b1e43338fb1e68b990b3789a31bd401ff9105415721e7c8bd4d04c4551838c3a1c727b6abd49e736e309d903f69f1ff957",
    },
}

test("refresh encryption matches the official fixed-seed WASM vector", function()
    local calls = 0
    local vector = vectors[1]
    local crypto = AuthCrypto.new({ random_bytes = function(length)
        assert(length == 32)
        calls = calls + 1
        return fromHex(vector.seed)
    end })
    assert(crypto:correspondPath(tonumber(vector.timestamp)) == vector.ciphertext)
    assert(calls == 1)
end)

test("independent OAEP vectors cover carry chains and timestamp bounds", function()
    for _, vector in ipairs(vectors) do
        local crypto = AuthCrypto.new({ random_bytes = function() return fromHex(vector.seed) end })
        local value = assert(crypto:correspondPath(vector.timestamp))
        assert(value == vector.ciphertext and #value == 256 and not value:find("[^a-f0-9]"))
    end
end)

test("ciphertext retains its leading zero byte", function()
    local vector = vectors[5]
    local crypto = AuthCrypto.new({ random_bytes = function() return fromHex(vector.seed) end })
    local value = assert(crypto:correspondPath(tonumber(vector.timestamp)))
    assert(value == vector.ciphertext and value:sub(1, 2) == "00" and #value == 256)
end)

test("numeric timestamps use canonical decimal text", function()
    for _, index in ipairs({ 2, 3 }) do
        local vector = vectors[index]
        local crypto = AuthCrypto.new({ random_bytes = function() return fromHex(vector.seed) end })
        assert(crypto:correspondPath(tonumber(vector.timestamp)) == vector.ciphertext)
    end
    local crypto = AuthCrypto.new({ random_bytes = function() return string.rep("\0", 32) end })
    assert(crypto:correspondPath(-0) == vectors[2].ciphertext)
end)

test("invalid timestamps fail before accessing randomness", function()
    local crypto = AuthCrypto.new({ random_bytes = function() error("Randomness must not be requested.") end })
    local invalid = {
        false, true, {}, -1, 0.5, math.huge, -math.huge, 0 / 0, 9007199254740992,
        "", "01", "-1", "+1", "1.0", "1e12", " 1700000000000", "1700000000000\n",
        "9007199254740992", string.rep("1", 1000), "refresh_1700000000000",
    }
    local value, err = crypto:correspondPath(nil)
    assert(value == nil and err.kind == "invalid_argument" and err.transmitted == false)
    for _, timestamp in ipairs(invalid) do
        value, err = crypto:correspondPath(timestamp)
        assert(value == nil and err.kind == "invalid_argument" and err.transmitted == false)
    end
end)

test("injected random failures never fall back to another source", function()
    local random_sources = {
        false, 12, "invalid",
        function() return nil end,
        function() return 123 end,
        function() return string.rep("a", 31) end,
        function() return string.rep("a", 33) end,
        function() error("Synthetic random failure with private diagnostic.") end,
    }
    for _, source in ipairs(random_sources) do
        local crypto = AuthCrypto.new({ random_bytes = source })
        local value, err = crypto:correspondPath(1700000000000)
        capability(value, err, "secure_random")
        assert(not err.message:find("private diagnostic", 1, true))
    end
end)

test("default randomness fails closed if urandom cannot be opened", function()
    local calls = 0
    local module = isolatedModule({ io = { open = function(path, mode)
        assert(path == "/dev/urandom" and mode == "rb")
        calls = calls + 1
        return nil
    end } })
    local value, err = module.new():correspondPath(1700000000000)
    capability(value, err, "secure_random")
    assert(calls == 1)
end)

test("urandom read errors and short reads close the file and fail", function()
    local readers = {
        function() error("Synthetic read error.") end,
        function() return string.rep("a", 31) end,
        function() return nil end,
    }
    for _, read in ipairs(readers) do
        local closed = false
        local module = isolatedModule({ io = { open = function()
            return { read = read, close = function() closed = true; return true end }
        end } })
        local value, err = module.new():correspondPath(1700000000000)
        capability(value, err, "secure_random")
        assert(closed)
    end
end)

test("missing hash or XOR support returns a typed capability error", function()
    for _, unavailable in ipairs({ "ffi/sha2", "bit" }) do
        local module = isolatedModule({ require = function(name)
            if name == unavailable then error("Synthetic missing primitive.") end
            return require(name)
        end })
        local value, err = module.new():correspondPath(1700000000000)
        capability(value, err, "auth_crypto")
    end
end)

test("unexpected hash failure is contained without exposing diagnostics", function()
    local module = isolatedModule({ require = function(name)
        if name == "ffi/sha2" then
            return { sha256 = function() error("Synthetic private hash diagnostic.") end }
        end
        return require(name)
    end })
    local value, err = module.new({ random_bytes = function() return string.rep("a", 32) end })
        :correspondPath(1700000000000)
    assert(value == nil and err.kind == "crypto" and err.transmitted == false)
    assert(not err.message:find("private hash diagnostic", 1, true))
end)

test("the operating system random source produces independent valid ciphertexts", function()
    local crypto = AuthCrypto.new()
    local first = assert(crypto:correspondPath(1700000000000))
    local second = assert(crypto:correspondPath(1700000000000))
    assert(#first == 256 and #second == 256 and first ~= second)
    assert(not first:find("[^a-f0-9]") and not second:find("[^a-f0-9]"))
end)

local result = assert(io.open(output .. "/auth-crypto-result.json", "wb"))
result:write(assert(JSON.encode({ passed = #passed, cases = passed, cpu_seconds = os.clock() - started,
    official_ciphertext_bytes = 128, public_exponent = 65537, oaep_digest = "SHA256", mgf1_digest = "SHA256" })))
result:close()
