-- Anonymous public-thumbnail verification; never request an original cover or read an account.
require("setupkoenv")
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. package.path
local Client = require("bilicomics/protocol/client")
local CoverSource = require("bilicomics/cover_source")
local Files = require("bilicomics/storage/files")
local Policy = require("bilicomics/image_policy")
local json = require("rapidjson")
local client = Client.new{ crypto = {} }
local results = {}
-- These public covers are exposed in the anonymous official homepage HTML.
for index, url in ipairs({
    "https://i0.hdslb.com/bfs/manga-static/2c927f4c9b800d59ac06f0fcb874b53ebaa72e6f.jpg",
    "https://i0.hdslb.com/bfs/manga-static/385507104ec944f636b47537282c31e766db2056.jpg",
}) do
    local selected = assert(CoverSource.resolve(url))
    assert(selected.thumbnail and selected.url ~= url, "Live verification must only fetch the derived thumbnail")
    local path = output .. "/public-thumbnail-" .. index .. ".part"
    local result, err = client:downloadImage({ url = selected.url, hit_encrpyt = false }, path,
        { max_bytes = 4 * 1024 * 1024, max_pixels = Policy.cover_max_pixels, total_timeout = 20 })
    if not result then error(err and err.kind or "thumbnail_download_failed") end
    assert(result.width <= CoverSource.width and result.width > 0 and result.height > 0
        and result.bytes <= 4 * 1024 * 1024 and result.width * result.height <= Policy.cover_max_pixels,
        "The real thumbnail must fit the width, byte and pixel budgets")
    results[#results + 1] = { url = selected.url, width = result.width, height = result.height,
        bytes = result.bytes, format = result.format, verification = result.verification, passed = true }
    os.remove(path)
end
Files.write(output .. "/cover-thumbnail-live-result.json", json.encode({ passed = true, thumbnails = results,
    scope = "Anonymous production Client transfers and Image.inspect; public homepage covers; originals never downloaded" }, { pretty = true }))
print(json.encode({ count = #results, passed = true }))
