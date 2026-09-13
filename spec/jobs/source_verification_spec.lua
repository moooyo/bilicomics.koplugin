-- Run only on test-env. All image and API response bytes are synthetic.
require("setupkoenv")
local source, output, assets = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = source .. "/?.lua;" .. package.path
local bit = require("bit")
local ffi = require("ffi")
require("ffi/posix_h")
ffi.cdef[[
int link(const char *oldpath, const char *newpath);
int symlink(const char *target, const char *linkpath);
]]
local Files = require("bilicomics/storage/files")
local Refresh = require("bilicomics/storage/source_refresh")
local JSON = require("bilicomics/protocol/json")
local RealClient = require("bilicomics/protocol/client")
local sha = require("ffi/sha2").sha256
local factory
local client_key = "bilicomics/protocol/client"
package.loaded[client_key] = {new = function(options) return assert(factory)(options) end}
local Worker = require("bilicomics/jobs/worker")
package.loaded[client_key] = RealClient

local roots = {references = output .. "/references", temporary = output .. "/temporary", outside = output .. "/outside"}
for _, path in pairs(roots) do Files.mkdir(path) end
local passed, sequence, request_count = {}, 0, 0
local function u32(value)
    return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256, value % 256)
end
local function crc32(value)
    local crc = -1
    for index = 1, #value do
        crc = bit.bxor(crc, value:byte(index))
        for _ = 1, 8 do crc = bit.bxor(bit.rshift(crc, 1), bit.band(crc, 1) == 1 and 0xedb88320 or 0) end
    end
    return bit.bnot(crc) % 4294967296
end
local function png(gray)
    local raw = string.char(0, gray, gray, 0, gray, gray)
    local a, b = 1, 0
    for index = 1, #raw do a = (a + raw:byte(index)) % 65521; b = (b + a) % 65521 end
    local compressed = string.char(120, 1, 1, #raw, 0, 255 - #raw, 255) .. raw .. u32(b * 65536 + a)
    local function chunk(kind, value) return u32(#value) .. kind .. value .. u32(crc32(kind .. value)) end
    return string.char(137, 80, 78, 71, 13, 10, 26, 10)
        .. chunk("IHDR", u32(2) .. u32(2) .. string.char(8, 0, 0, 0, 0))
        .. chunk("IDAT", compressed) .. chunk("IEND", "")
end
local original, changed = png(35), png(190)
assert(#original == #changed and sha(original) ~= sha(changed))

local function test(name, fn)
    local ok, failure = xpcall(fn, debug.traceback)
    assert(ok, name .. ": " .. tostring(failure))
    passed[#passed + 1] = name
    print("PASS " .. name)
end
local function reference(bytes)
    sequence = sequence + 1
    local path = roots.references .. "/reference-" .. sequence .. ".png"
    Files.write(path, bytes or original)
    return {path = path, root = roots.references, identity = assert(Refresh.fileIdentity(path, roots.references))}
end
local function request(ref)
    sequence = sequence + 1
    return {kind = "verify_source_page", source_path = "/synthetic/source-page", index = 2,
        expected_checksum = sha(original), reference = ref,
        temporary_path = roots.temporary .. "/candidate-" .. sequence .. ".part", temporary_root = roots.temporary,
        max_bytes = 65536, minimum_free_bytes = 0, asset_root = assets,
        session = {cookies = {SESSDATA = "synthetic-only", DedeUserID = "42"}}}
end
local function detail(episode, comic_id)
    return {id = comic_id or 81, ep_list = {episode or
        {id = 101, comic_id = 81, pay_mode = 0, is_locked = false, unlock_type = 0}}}
end
local function execute(item, settings)
    settings = settings or {}
    local calls, constructions = {}, 0
    factory = function(options)
        constructions = constructions + 1
        return RealClient.new({session = options.session, asset_root = options.asset_root, transport = {
            request = function(_, wire)
                request_count = request_count + 1
                local endpoint = wire.url:match("^https://manga%.bilibili%.com/twirp/comic%.v1%.Comic/(%w+)%?")
                if endpoint then
                    assert(wire.method == "POST")
                    calls[#calls + 1] = endpoint
                    local body = assert(JSON.decode(wire.body))
                    if endpoint == "ImageToken" then
                        assert(item.kind == "verify_source_page")
                        local paths = assert(JSON.decode(body.urls))
                        assert(#paths == 1 and paths[1] == item.source_path and type(body.m1) == "string")
                        for key in pairs(body) do assert(key == "urls" or key == "m1") end
                        if settings.on_token then settings.on_token() end
                        return {status = 200, body = '{"code":0,"data":[{"complete_url":"https://i0.hdslb.com/synthetic.png?token=synthetic","hit_encrpyt":false}]}'}
                    elseif endpoint == "ComicDetail" then
                        assert(item.kind == "source_index" and body.comic_id == tonumber(item.comic_id))
                        return {status = settings.detail_status or 200, body = assert(JSON.encode({code = 0,
                            data = settings.detail or detail()}))}
                    elseif endpoint == "GetImageIndex" then
                        assert(item.kind == "source_index" and body.ep_id == tonumber(item.episode_id))
                        return {status = settings.index_status or 200,
                            body = '{"code":0,"data":{"images":[{"path":"/synthetic/refreshed-page","x":2,"y":2}]}}'}
                    end
                    error("Only the three source-reading APIs are allowed in this suite")
                end
                assert(item.kind == "verify_source_page" and wire.method == "GET")
                assert(wire.url == "https://i0.hdslb.com/synthetic.png?token=synthetic&code=DanmakuInfo")
                assert(wire.output_path == item.temporary_path and wire.max_bytes == item.max_bytes)
                for name in pairs(wire.headers) do
                    name = name:lower()
                    assert(name ~= "cookie" and name ~= "authorization" and name ~= "x-xsrf-token")
                end
                calls[#calls + 1] = "CDN"
                Files.write(wire.output_path, settings.bytes or original)
                if settings.after_cdn then settings.after_cdn() end
                return {status = settings.cdn_status or 200}
            end,
        }})
    end
    local value, err = Worker.execute(item)
    return value, err, calls, constructions
end
local function rejected(item, settings, expected_kind, expected_calls)
    local value, err, calls = execute(item, settings)
    assert(value == nil and err and err.kind == expected_kind, tostring(err and err.kind))
    assert(#calls == expected_calls)
    return err
end
local function absent(path) return not require("libs/libkoreader-lfs").symlinkattributes(path) end
local function sourceRequest()
    local item = request()
    item.kind, item.comic_id, item.episode_id = "source_index", "81", "101"
    return item
end

test("Reference and candidate bytes are verified through the actual Worker and Client", function()
    local ref = reference()
    local item = request(ref)
    local value, err, calls = execute(item)
    assert(value and not err and #calls == 2 and calls[1] == "ImageToken" and calls[2] == "CDN")
    assert(value.checksum == item.expected_checksum and value.width == 2 and value.height == 2)
    assert(Refresh.sameFileIdentity(value.reference_identity, ref.identity))
    assert(Files.read(ref.path) == original and Files.read(item.temporary_path) == original)
    assert(Refresh.sameFileIdentity(Refresh.fileIdentity(ref.path, ref.root), ref.identity))
    os.remove(item.temporary_path)
end)

test("A historical checksum can verify a candidate without an existing reference file", function()
    local item = request()
    local value, err = execute(item)
    assert(value and not err and value.reference_identity == nil and value.checksum == sha(original))
    os.remove(item.temporary_path)
end)

test("Reference corruption is detected from bytes before any API request", function()
    local ref = reference(changed)
    local item = request(ref)
    rejected(item, nil, "reference_changed", 0)
    assert(Files.read(ref.path) == changed and absent(item.temporary_path))
end)

test("A stale reference identity is rejected before any API request", function()
    local ref = reference()
    ref.identity.size = ref.identity.size + 1
    rejected(request(ref), nil, "reference_changed", 0)
    assert(Files.read(ref.path) == original)
end)

test("Same-size same-geometry candidate content changes are rejected and cleaned", function()
    local ref, item = reference(), request()
    item.reference = ref
    rejected(item, {bytes = changed}, "content_changed", 2)
    assert(absent(item.temporary_path) and Files.read(ref.path) == original)
end)

test("Reference replacement during acquisition invalidates an otherwise matching candidate", function()
    local ref = reference()
    local item = request(ref)
    rejected(item, {after_cdn = function()
        local replacement = roots.references .. "/replacement-" .. sequence .. ".png"
        Files.write(replacement, original)
        assert(os.rename(replacement, ref.path))
    end}, "reference_changed", 2)
    assert(absent(item.temporary_path) and Files.read(ref.path) == original)
end)

test("Missing nonregular linked and outside-root references never reach the API", function()
    local ref = reference()
    assert(os.remove(ref.path))
    rejected(request(ref), nil, "storage", 0)
    local target = reference()
    local linked = reference()
    assert(os.remove(linked.path) and ffi.C.symlink(target.path, linked.path) == 0)
    rejected(request(linked), nil, "storage", 0)
    assert(Files.read(target.path) == original)
    local outside = roots.outside .. "/reference.png"
    Files.write(outside, original)
    local external = {path = outside, root = roots.references,
        identity = assert(Refresh.fileIdentity(outside, roots.outside))}
    rejected(request(external), nil, "storage", 0)
    local directory = {path = roots.references, root = roots.references, identity = target.identity}
    rejected(request(directory), nil, "storage", 0)
end)

test("An existing own partial can be cleared and retried at the same assigned path", function()
    local ref = reference()
    local item = request(ref)
    Files.write(item.temporary_path, "synthetic interrupted partial")
    local value, err = execute(item)
    assert(value and not err and Files.read(item.temporary_path) == original and Files.read(ref.path) == original)
    os.remove(item.temporary_path)
end)

test("Candidates cannot alias references through a path or a hard link", function()
    local ref = reference()
    local item = request(ref)
    assert(ffi.C.link(ref.path, item.temporary_path) == 0)
    rejected(item, nil, "invalid_request", 0)
    assert(Files.read(ref.path) == original)
    os.remove(item.temporary_path)
    local shared = roots.temporary .. "/reference.part"
    Files.write(shared, original)
    item = request({path = shared, root = roots.temporary, identity = assert(Refresh.fileIdentity(shared, roots.temporary))})
    item.temporary_path = shared
    rejected(item, nil, "invalid_request", 0)
    assert(Files.read(shared) == original)
end)

test("Candidate paths reject outside roots and symbolic links without touching their targets", function()
    local item = request()
    item.temporary_path = roots.outside .. "/candidate.part"
    rejected(item, nil, "invalid_request", 0)
    local target = reference()
    item = request()
    assert(ffi.C.symlink(target.path, item.temporary_path) == 0)
    rejected(item, nil, "invalid_request", 0)
    assert(Files.read(target.path) == original)
    os.remove(item.temporary_path)
    local linked_root = output .. "/linked-temporary"
    assert(ffi.C.symlink(roots.temporary, linked_root) == 0)
    item = request()
    item.temporary_root, item.temporary_path = linked_root, linked_root .. "/candidate.part"
    rejected(item, nil, "invalid_request", 0)
    assert(os.remove(linked_root))
end)

test("Reference and candidate byte limits and storage reserve remain enforced", function()
    local ref = reference()
    local item = request(ref)
    item.max_bytes = 32
    rejected(item, nil, "image_size", 0)
    assert(Files.read(ref.path) == original)
    item = request()
    item.max_bytes = 32
    rejected(item, nil, "image_size", 2)
    assert(absent(item.temporary_path))
    item = request()
    item.minimum_free_bytes = math.huge
    rejected(item, nil, "low_space", 0)
end)

test("Acquisition and container errors remove only the assigned candidate", function()
    local ref = reference()
    local item = request(ref)
    rejected(item, {cdn_status = 400}, "image_http", 2)
    assert(absent(item.temporary_path) and Files.read(ref.path) == original)
    item = request(ref)
    rejected(item, {bytes = original:sub(1, 24)}, "invalid_image", 2)
    assert(absent(item.temporary_path) and Files.read(ref.path) == original)
end)

test("Malformed verification requests fail locally", function()
    local item = request()
    item.expected_checksum = "not-a-checksum"
    rejected(item, nil, "invalid_request", 0)
    item = request()
    item.temporary_root = nil
    rejected(item, nil, "invalid_request", 0)
    item = request()
    item.source_path = nil
    rejected(item, nil, "invalid_request", 0)
end)

test("Source index obtains fresh free and owned access before requesting an index", function()
    for _, raw in ipairs({
        {id = 101, comic_id = 81, pay_mode = 0, is_locked = false, unlock_type = 0},
        {id = 101, comic_id = 81, pay_mode = 1, is_locked = false, unlock_type = 1, unlock_expire_at = "0000-00-00 00:00:00"},
    }) do
        local value, err, calls = execute(sourceRequest(), {detail = detail(raw)})
        assert(value and not err and #calls == 2 and calls[1] == "ComicDetail" and calls[2] == "GetImageIndex")
        assert(value.detail.comic.id == "81" and value.index.episode_id == "101")
    end
end)

test("Unavailable locked unknown and expired access stop before an index request", function()
    for _, raw in ipairs({
        {id = 101, comic_id = 81, unavailable = true},
        {id = 101, comic_id = 81, is_locked = true, pay_mode = 0},
        {id = 101, comic_id = 81, is_locked = false, pay_mode = 1},
        {id = 101, comic_id = 81, unlock_type = 2, unlock_expire_at = 1, is_locked = false},
        {id = 101, comic_id = 81, unlock_type = 2, unlock_expire_at = os.time() + 3600, is_locked = false},
    }) do rejected(sourceRequest(), {detail = detail(raw)}, "entitlement", 1) end
end)

test("Catalog identity mismatches and missing chapters stop before an index request", function()
    rejected(sourceRequest(), {detail = detail(nil, 82)}, "protocol", 1)
    rejected(sourceRequest(), {detail = detail({id = 101, comic_id = 82, pay_mode = 0})}, "protocol", 1)
    rejected(sourceRequest(), {detail = detail({id = 102, comic_id = 81, pay_mode = 0})}, "entitlement", 1)
    local duplicated = detail()
    duplicated.ep_list[2] = duplicated.ep_list[1]
    rejected(sourceRequest(), {detail = duplicated}, "protocol", 1)
end)

test("Source index API errors propagate without an extra request", function()
    rejected(sourceRequest(), {detail_status = 503}, "http", 1)
    rejected(sourceRequest(), {index_status = 503}, "http", 2)
end)

local file = assert(io.open(output .. "/source-verification-result.json", "wb"))
assert(file:write(assert(JSON.encode({passed = #passed, cases = passed, injected_requests = request_count,
    real_network_requests = 0, scope = "Reading-only source index and checksum verification through production Worker and Client"}))))
assert(file:close())
