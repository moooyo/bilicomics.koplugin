-- Run only on the authorized Linux host; never print private inputs or responses.
require("setupkoenv")
local source, work, session_path, mode = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
local JSON = require("rapidjson")
local Session = require("bilicomics/protocol/session")
local Client = require("bilicomics/protocol/client")
local Transport = require("bilicomics/protocol/transport")
local Assets = require("bilicomics/protocol/assets")
local Files = require("bilicomics/storage/files")
local report = { passed = false, checks = {}, counts = { requests = 0, page_count = 0 } }
local comic_id, episode_id
local selected = false
local asset_urls = {}
for _, asset in pairs(Assets.manifest) do asset_urls[asset.url] = true end
local routes = {
    ["/x/web-interface/nav"] = { host = "api.bilibili.com", method = "GET", maximum = 1 },
    ["/twirp/bookshelf.v1.Bookshelf/ListFavorite"] = { host = "manga.bilibili.com", method = "POST", maximum = 1,
        keys = { page_num=true, page_size=true, order=true, wait_free=true, time_limit_free=true, type=true, from=true, source=true } },
    ["/twirp/bookshelf.v1.Bookshelf/ListHistory"] = { host = "manga.bilibili.com", method = "POST", maximum = 1,
        keys = { page_num=true, page_size=true, type=true } },
    ["/twirp/comic.v1.Comic/ComicDetail"] = { host = "manga.bilibili.com", method = "POST", maximum = 1,
        keys = { comic_id=true, m2=true } },
    ["/twirp/comic.v1.Comic/GetImageIndex"] = { host = "manga.bilibili.com", method = "POST", maximum = 1,
        keys = { ep_id=true, m2=true } },
}
local query_keys = { device=true, platform=true, nov=true, a=true, ultra_sign=true, cpx=true, m1=true }
local original = Transport.request
local counts = {}
function Transport:request(request)
    local host, path = (request.url or ""):match("^https://([^/?#]+)(/[^?#]*)")
    local route = routes[path]
    local allowed = host ~= nil and not request.url:find("#", 1, true)
    if route then
        allowed = allowed and host == route.host and request.method == route.method
        if path ~= "/x/web-interface/nav" then allowed = allowed and mode == "select" end
        local query, seen = request.url:match("%?([^#]*)"), {}
        for pair in (query or ""):gmatch("[^&]+") do
            local key = pair:match("^([^=]+)=")
            if not key or not query_keys[key] or seen[key] then allowed = false end
            seen[key or ""] = true
        end
        if route.method == "GET" then
            allowed = allowed and not query and not request.body and not request.output_path
        else
            local decoded, body = pcall(JSON.decode, request.body or "")
            allowed = allowed and decoded and type(body) == "table" and not request.output_path
            if allowed then
                for key in pairs(body) do if not route.keys[key] then allowed = false end end
                if path:find("/List", 1, true) then
                    allowed = allowed and body.page_num == 1 and body.page_size == 1
                elseif path:find("/ComicDetail", 1, true) then
                    allowed = allowed and comic_id and tostring(body.comic_id) == comic_id
                elseif path:find("/GetImageIndex", 1, true) then
                    allowed = allowed and episode_id and tostring(body.ep_id) == episode_id
                end
            end
        end
        counts[path] = (counts[path] or 0) + 1
        allowed = allowed and counts[path] <= route.maximum
    else
        allowed = allowed and mode == "select" and asset_urls[request.url]
            and request.method == "GET" and not request.body
            and request.output_path and Files.within(request.output_path, work .. "/assets")
        for key in pairs(request.headers or {}) do
            local lower = tostring(key):lower()
            if lower == "cookie" or lower == "authorization" or lower == "proxy-authorization"
                or lower == "x-xsrf-token" then allowed = false end
        end
    end
    report.counts.requests = report.counts.requests + 1
    allowed = allowed and report.counts.requests <= 8
    if not allowed then
        report.checks.readonly_transport_guard = false
        return nil, { kind = "verification_guard", transmitted = false, retryable = false }
    end
    return original(self, request)
end

local function check(name, condition)
    report.checks[name] = not not condition
    assert(condition, name)
end
local ok = pcall(function()
    check("known_mode", mode == "validate" or mode == "select")
    check("linux_runtime", require("ffi").os == "Linux")
    report.checks.readonly_transport_guard = true
    local session = Session.parse(Files.read(session_path, 131072))
    check("session_parsed", session ~= nil)
    local client = Client.new({ session = session:serialize(), asset_root = work .. "/assets" })
    local value = client:validateSession()
    check("session_valid", value ~= nil)
    if mode == "validate" then return end
    local favorites = client:listFavorites({ page = 1, page_size = 1 })
    check("favorite_read_succeeded", favorites ~= nil)
    local comics = favorites
    if #comics == 0 then
        comics = client:listHistory({ page = 1, page_size = 1 })
        check("history_read_succeeded", comics ~= nil)
    end
    check("first_library_comic_exists", #comics > 0)
    comic_id = tostring(comics[1].id)
    check("comic_identifier_valid", comic_id:match("^[1-9]%d*$") ~= nil)
    local detail = client:comicDetail(comic_id)
    check("first_comic_detail_received", detail ~= nil and detail.comic.id == comic_id)
    for _, episode in ipairs(detail.episodes) do
        if episode.access == "free" then
            episode_id = tostring(episode.id)
            break
        end
    end
    check("first_explicitly_free_episode_exists", episode_id ~= nil)
    local index = client:imageIndex(episode_id)
    check("selected_index_received", index ~= nil and index.episode_id == episode_id)
    check("complete_chapter_has_bounded_page_count", #index.images >= 6 and #index.images <= 64)
    local paths, seen = {}, {}
    for number, image in ipairs(index.images) do
        check("complete_index_is_ordered_unique", image.index == number and type(image.path) == "string"
            and #image.path > 0 and #image.path <= 8192 and not seen[image.path])
        seen[image.path] = true
        paths[number] = image.path
    end
    local selection = { comic_id = comic_id, episode_id = episode_id,
        approved_source_paths = paths, approved_cover_url = detail.comic.cover_url }
    Files.atomicWrite(work .. "/selection.json", JSON.encode(selection))
    report.counts.page_count = #paths
    selected = true
end)
report.passed = ok and report.checks.readonly_transport_guard == true
if mode == "select" then report.checks.selection_created = selected end
Files.atomicWrite(work .. "/preflight-observations.json", JSON.encode(report))
os.exit(report.passed and 0 or 1)
