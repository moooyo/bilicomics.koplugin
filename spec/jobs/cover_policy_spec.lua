-- Run only inside the isolated test-env KOReader runtime.
-- These checks inspect compressed containers and headers without loading an image decoder.
require("setupkoenv")
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. package.path

local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local Files = require("bilicomics/storage/files")
local Header = require("bilicomics/storage/image_header")
local Image = require("bilicomics/protocol/image")
local Policy = require("bilicomics/image_policy")
local RealClient = require("bilicomics/protocol/client")
local tests, temporary_paths, factory = {}, {}, nil
local protocol_key = "bilicomics/protocol/client"
package.loaded[protocol_key] = { new = function(options)
    return assert(factory, "The test must install a protocol client factory")(options)
end }
local Worker = require("bilicomics/jobs/worker")
package.loaded[protocol_key] = RealClient

local compressed_limit = 256 * 1024
local function exists(path) return lfs.attributes(path, "mode") == "file" end
local function temporary(name)
    local path = output .. "/cover-policy-" .. name .. ".part"
    assert(lfs.attributes(path) == nil, "The isolated temporary image path must not already exist")
    temporary_paths[#temporary_paths + 1] = path
    return path
end
local function fixture(name) return output .. "/fixtures/" .. name .. ".png" end
local function copyFixture(name, path)
    -- Only the small compressed PNG bytes enter Lua memory.
    Files.write(path, Files.read(fixture(name), compressed_limit))
end
local function test(name, fn)
    factory = function() error("Unexpected client construction") end
    local ok, failure = xpcall(fn, debug.traceback)
    for _, path in ipairs(temporary_paths) do os.remove(path) end
    temporary_paths = {}
    tests[#tests + 1] = { name = name, passed = ok, error = ok and nil or failure }
    print((ok and "PASS " or "FAIL ") .. name)
end
local function request(kind, path)
    return { kind = kind, temporary_path = path, url = "https://i0.hdslb.com/synthetic-cover.png",
        source_path = "/synthetic/chapter-page", index = 3, minimum_free_bytes = 0, max_bytes = compressed_limit }
end

test("Large grayscale fixtures are complete PNG containers with the intended geometry", function()
    assert(Policy.cover_max_pixels == 4000000, "The cover pixel budget must remain four million source pixels")
    for _, item in ipairs({ { name = "cover-6mp", width = 3000, height = 2000 },
        { name = "cover-4mp", width = 2000, height = 2000 } }) do
        local path = fixture(item.name)
        local header = Header.read(path)
        assert(header.format == "png" and header.width == item.width and header.height == item.height,
            "The test fixture must expose its real source dimensions")
        local inspected, err = Image.inspect(path)
        assert(inspected and not err and inspected.verification == "container" and inspected.format == "png",
            "The generated fixture must pass production container and checksum inspection")
        assert(inspected.bytes < compressed_limit and inspected.width * inspected.height >= 4000000,
            "The fixture must stay small on disk while retaining its intended source-pixel count")
    end
end)

test("Worker rejects an oversized cover even when its client ignores the budget and lies about geometry", function()
    local path, calls = temporary("worker-reject-six-million"), 0
    local acquired = { temporary_path = path, width = 40, height = 80, format = "png" }
    factory = function()
        return { downloadImage = function(_, token, received_path, options)
            calls = calls + 1
            assert(received_path == path and token.hit_encrpyt == false, "The worker must use its assigned plain-cover output")
            assert(options.max_pixels == 4000000 and options.max_pixels == Policy.cover_max_pixels,
                "Cover acquisition must pass the production source-pixel budget to its client")
            copyFixture("cover-6mp", path)
            return acquired
        end }
    end
    local result, err = Worker.execute(request("download_cover", path))
    assert(result == nil and err and err.kind == "image_size" and calls == 1,
        "The worker must reject the real six-million-pixel header rather than trusting small claimed dimensions")
    assert(not exists(path), "An oversized cover must remove its assigned partial output")
    assert(acquired.geometry == nil, "Rejected cover geometry must not be published as a successful acquisition")
end)

test("Worker accepts a cover exactly at the four-million-pixel boundary", function()
    local path, calls = temporary("worker-accept-four-million"), 0
    factory = function()
        return { downloadImage = function(_, _, received_path, options)
            calls = calls + 1
            assert(received_path == path and options.max_pixels == Policy.cover_max_pixels,
                "The inclusive cover boundary must still be passed to the client")
            copyFixture("cover-4mp", path)
            return { temporary_path = path, width = 40, height = 80, format = "png" }
        end }
    end
    local result, err = Worker.execute(request("download_cover", path))
    assert(result and not err and calls == 1 and exists(path), "A cover at the source-pixel boundary must remain available for commit")
    assert(result.width == 2000 and result.height == 2000 and result.geometry.source_width == 2000
        and result.geometry.source_height == 2000, "Successful geometry must come from the actual PNG header")
end)

test("Worker does not apply the cover budget to a six-million-pixel chapter page", function()
    local path, token_calls, image_calls = temporary("worker-chapter-six-million"), 0, 0
    local token = { url = "https://i0.hdslb.com/synthetic-page.png", hit_encrpyt = false }
    factory = function()
        return {
            imageTokens = function(_, paths)
                token_calls = token_calls + 1
                assert(#paths == 1 and paths[1] == "/synthetic/chapter-page", "Chapter acquisition must preserve its source-image request")
                return { token }
            end,
            downloadImage = function(_, received_token, received_path, options)
                image_calls = image_calls + 1
                assert(received_token == token and received_path == path and options.max_pixels == nil,
                    "A chapter page must not inherit the independent cover source-pixel limit")
                copyFixture("cover-6mp", path)
                return { temporary_path = path, width = 40, height = 80, format = "png" }
            end,
        }
    end
    local result, err = Worker.execute(request("download_page", path))
    assert(result and not err and token_calls == 1 and image_calls == 1 and exists(path),
        "A valid large chapter page must complete without the cover-only rejection")
    assert(result.width == 3000 and result.height == 2000 and result.geometry.source_width == 3000
        and result.geometry.source_height == 2000, "Chapter geometry must preserve the actual large source dimensions")
end)

local function downloadWithRealClient(name, path, maximum)
    local requests = {}
    local client = RealClient.new({ crypto = {}, transport = { request = function(_, item)
        requests[#requests + 1] = item
        assert(item.method == "GET" and item.output_path == path and item.max_bytes == compressed_limit,
            "The production client must stream the requested image into the assigned output")
        copyFixture(name, item.output_path)
        return { status = 200, transmitted = true }
    end } })
    local result, err = client:downloadImage({ url = "https://i0.hdslb.com/synthetic-image.png", hit_encrpyt = false },
        path, { max_pixels = maximum, max_bytes = compressed_limit })
    assert(#requests == 1, "Container inspection must not trigger a retry or another transfer")
    return result, err
end

test("Production client rejects and removes a six-million-pixel image under the cover budget", function()
    local path = temporary("client-reject-six-million")
    local result, err = downloadWithRealClient("cover-6mp", path, Policy.cover_max_pixels)
    assert(result == nil and err and err.kind == "image_size", "Production Image.inspect must enforce the supplied pixel budget")
    assert(not exists(path), "Production Client must remove the rejected image after container inspection")
end)

test("Production client retains a complete cover exactly at the pixel budget", function()
    local path = temporary("client-accept-four-million")
    local result, err = downloadWithRealClient("cover-4mp", path, Policy.cover_max_pixels)
    assert(result and not err and exists(path) and result.width == 2000 and result.height == 2000,
        "The exact cover-pixel boundary must be inclusive")
    assert(result.verification == "container" and result.format == "png" and #result.checksum == 64
        and result.bytes == Files.size(path), "Accepted covers must keep real container and checksum evidence")
end)

test("Production client accepts the same six-million-pixel image without a cover budget", function()
    local path = temporary("client-chapter-six-million")
    local result, err = downloadWithRealClient("cover-6mp", path)
    assert(result and not err and exists(path) and result.width == 3000 and result.height == 2000,
        "A normal chapter acquisition must remain independent of the cover pixel budget")
    assert(result.verification == "container" and result.format == "png" and #result.checksum == 64,
        "Large chapter pages must still pass production container inspection")
end)

test("Worker keeps direct cover URLs unchanged through the production client", function()
    for index, url in ipairs({ "https://i0.hdslb.com/synthetic-cover.png",
        "https://i0.hdslb.com/synthetic-cover.png?width=800&format=png" }) do
        local path, calls = temporary("direct-cover-url-" .. index), 0
        factory = function()
            return RealClient.new({ crypto = {}, transport = { request = function(_, item)
                calls = calls + 1
                assert(item.url == url, "Direct cover URLs must not acquire chapter-token parameters")
                assert(item.method == "GET" and item.output_path == path,
                    "A direct cover must use its assigned anonymous image transfer")
                for name in pairs(item.headers or {}) do
                    assert(name:lower() ~= "cookie" and name:lower() ~= "authorization",
                        "Cover transfers must not carry account credentials")
                end
                copyFixture("cover-4mp", path)
                return { status = 200, transmitted = true }
            end } })
        end
        local input = request("download_cover", path)
        input.url = url
        local result, err = Worker.execute(input)
        assert(result and not err and calls == 1 and result.verification == "container",
            "The production worker and client must accept an unchanged valid cover URL")
    end
end)

local passed = true
for _, item in ipairs(tests) do passed = passed and item.passed end
Files.write(output .. "/cover-result.json", json.encode({ tests = tests, passed = passed,
    scope = "Real compressed PNG containers and headers; production Worker and Client with injected transfers; no image decoding or live network" }, { pretty = true }))
assert(passed, "One or more cover pixel-budget contract tests failed")
