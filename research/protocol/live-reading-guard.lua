-- Test-only transport boundary for an explicitly authorized complete-chapter read.
-- It never enables payment, wallet, quotation or account-mutating requests.
local ffi = require("ffi")
require("ffi/posix_h")
ffi.cdef[[int flock(int fd, int operation);]]
local bit = require("bit")
local json = require("rapidjson")

local routes = {
    ["/x/web-interface/nav"] = { host = "api.bilibili.com", method = "GET", label = "session" },
    ["/twirp/bookshelf.v1.Bookshelf/ListFavorite"] = { host = "manga.bilibili.com", method = "POST", label = "favorites",
        keys = { page_num=true, page_size=true, order=true, wait_free=true, time_limit_free=true, type=true, from=true, source=true } },
    ["/twirp/bookshelf.v1.Bookshelf/ListHistory"] = { host = "manga.bilibili.com", method = "POST", label = "history",
        keys = { page_num=true, page_size=true, type=true } },
    ["/twirp/comic.v1.Comic/ComicDetail"] = { host = "manga.bilibili.com", method = "POST", label = "catalog",
        keys = { comic_id=true, m2=true } },
    ["/twirp/comic.v1.Comic/GetImageIndex"] = { host = "manga.bilibili.com", method = "POST", label = "index",
        keys = { ep_id=true, m2=true } },
    ["/twirp/comic.v1.Comic/ImageToken"] = { host = "manga.bilibili.com", method = "POST", label = "token",
        keys = { urls=true, m1=true } },
}
local query_keys = { device=true, platform=true, nov=true, a=true, ultra_sign=true, cpx=true, m1=true }
local function decode(text)
    if type(text) ~= "string" or #text > 65536 then return nil end
    local ok, value = pcall(json.decode, text)
    return ok and type(value) == "table" and value or nil
end
local function within(path, root)
    return type(path) == "string" and path:sub(1, #root + 1) == root .. "/"
        and not path:find("/../", 1, true) and not path:find("\\", 1, true) and not path:find("%z")
end
return function(selection, context)
    assert(context.phase == "online" or context.phase == "offline", "A known test phase is required")
    assert(type(context.work) == "string" and context.work:sub(1,1) == "/", "An isolated absolute work root is required")
    assert(type(selection.approved_source_paths) == "table" and #selection.approved_source_paths >= 6
        and #selection.approved_source_paths <= 64, "A bounded complete multi-page chapter is required")
    local allowed_paths = {}
    local allowed_cdn_paths = {}
    local original_paths = {}
    for _, path in ipairs(selection.approved_source_paths) do
        assert(type(path) == "string" and #path > 0 and #path <= 8192, "Invalid approved source path")
        allowed_paths[path] = true
        original_paths[#original_paths + 1] = path
    end
    local asset_urls = {}
    for _, asset in pairs(require("bilicomics/protocol/assets").manifest) do asset_urls[asset.url] = true end
    local maximum = math.min(300, (#selection.approved_source_paths + 4) * 4)
    local counter_path = context.work .. "/transport-count"
    local guard = { current = nil }
    local auth_scope = context.auth_scope
    local selected_cover = require("bilicomics/cover_source").resolve(selection.approved_cover_url)
    local approved_covers = {}
    local function audit(record)
        local path = context.work .. "/transport-" .. tostring(ffi.C.getpid()) .. ".jsonl"
        local file = assert(io.open(path, "ab"))
        file:write(json.encode(record), "\n")
        assert(file:close())
    end
    local function sequence()
        local C = ffi.C
        local fd = C.open(counter_path, bit.bor(C.O_RDWR, C.O_CREAT), ffi.cast("unsigned int", 384))
        if fd < 0 then return nil end
        local ok, value = pcall(function()
            assert(C.flock(fd, 2) == 0, "Cannot lock transport counter")
            local buffer = ffi.new("char[16]")
            local count = tonumber(C.read(fd, buffer, 16))
            assert(count >= 0, "Cannot read transport counter")
            local previous = count > 0 and tonumber(ffi.string(buffer, count)) or 0
            assert(previous and previous >= 0, "Invalid transport counter")
            local current = previous + 1
            local bytes = string.format("%015d\n", current)
            assert(C.lseek(fd, 0, 0) == 0 and C.write(fd, bytes, #bytes) == #bytes, "Cannot save transport counter")
            return current
        end)
        C.flock(fd, 8)
        C.close(fd)
        return ok and value or nil
    end
    local function reject()
        audit({ event="blocked", phase=context.phase })
        return nil, { kind="verification_guard", retryable=false, transmitted=false,
            message="The request is outside the authorized reading-only test." }
    end
    function guard:updateIndex(index)
        if type(index) ~= "table" or tostring(index.episode_id) ~= tostring(selection.episode_id)
            or type(index.images) ~= "table" or #index.images ~= #original_paths then return reject() end
        local next_paths, changed = {}, 0
        for number, page in ipairs(index.images) do
            if type(page.path) ~= "string" or #page.path == 0 or #page.path > 8192
                or next_paths[page.path] then return reject() end
            next_paths[page.path] = true
            if page.path ~= original_paths[number] then changed = changed + 1 end
        end
        allowed_paths, allowed_cdn_paths = next_paths, {}
        local function fields(value)
            local result = {}
            for key in pairs(type(value) == "table" and value or {}) do
                if type(key) == "string" and #key <= 64 and key:match("^[%a_][%w_]*$") then result[key] = true end
            end
            return result
        end
        local raw = index.extra or {}
        local first = index.images[1].path
        local summary = {
            path_count = #index.images, paths_changed_since_preflight = changed,
            raw_index_fields = fields(raw),
            raw_image_fields = fields(type(raw.images) == "table" and raw.images[1]),
            first_path_shape = { length = #first, absolute_url = first:match("^https?://") ~= nil,
                starts_slash = first:sub(1, 1) == "/", has_query = first:find("?", 1, true) ~= nil,
                base64_characters_only = first:match("^[%w%+/%=_%-]+$") ~= nil,
                known_image_suffix = first:match("%.jpe?g$") ~= nil or first:match("%.png$") ~= nil or first:match("%.webp$") ~= nil },
        }
        local file = assert(io.open((context.private_root or context.work) .. "/index-shape.json", "wb"))
        file:write(json.encode(summary)); assert(file:close())
        return true
    end
    function guard:approveTokens(paths, tokens)
        if type(paths) ~= "table" or #paths ~= 1 or not allowed_paths[paths[1]]
            or type(tokens) ~= "table" or #tokens ~= 1 or tokens[1].source_path ~= paths[1] then return reject() end
        local token = tokens[1]
        local url = type(token.complete_url) == "string" and token.complete_url ~= "" and token.complete_url or token.url
        if type(url) ~= "string" then return reject() end
        if url:sub(1, 2) == "//" then url = "https:" .. url end
        local host, path = url:match("^https://([^/?#]+)(/[^?#]*)")
        if not host or not (host:match("%.hdslb%.com$") or host:match("%.biliimg%.com$")) then return reject() end
        allowed_cdn_paths[host .. path] = true
        return true
    end
    function guard:approveCover(url, temporary_path)
        if type(url) ~= "string" or not within(temporary_path, context.private_root or context.work)
            or not require("bilicomics/cover_source").resolve(url) then return reject() end
        approved_covers[url] = temporary_path
        return true
    end
    function guard:before(request)
        if context.phase ~= "online" then return reject() end
        local host, path = (request.url or ""):match("^https://([^/?#]+)(/[^?#]*)")
        if not host or request.url:find("#", 1, true) then return reject() end
        local route, category = routes[path], "metadata"
        local maintenance = auth_scope and auth_scope.transportCategory(request, "reading")
        if maintenance == "site_context" or maintenance == "cookie_info"
            or maintenance == "library_favorites" or maintenance == "library_history" then
            route = { label = maintenance }
        elseif auth_scope and auth_scope.coverAllowed(request, approved_covers) then
            category = "cover_image"
        elseif route then
            if host ~= route.host or request.method ~= route.method then return reject() end
            local query, seen = request.url:match("%?([^#]*)"), {}
            for pair in (query or ""):gmatch("[^&]+") do
                local key = pair:match("^([^=]+)=")
                if not key or not query_keys[key] or seen[key] then return reject() end
                seen[key] = true
            end
            if route.method == "GET" and (query or request.body) then return reject() end
            if route.keys then
                local body = decode(request.body)
                if not body then return reject() end
                for key in pairs(body) do if not route.keys[key] then return reject() end end
                if route.label == "catalog" and tostring(body.comic_id) ~= tostring(selection.comic_id) then return reject() end
                if route.label == "index" and tostring(body.ep_id) ~= tostring(selection.episode_id) then return reject() end
                if route.label == "token" then
                    local paths = decode(body.urls)
                    if not paths or #paths ~= 1 or not allowed_paths[paths[1]] then return reject() end
                end
                if route.label == "favorites" or route.label == "history" then
                    if body.page_num ~= 1 or not tonumber(body.page_size) or body.page_size > 50 then return reject() end
                end
            end
        else
            if not (host:match("%.hdslb%.com$") or host:match("%.biliimg%.com$"))
                or request.method ~= "GET" or request.body then return reject() end
            for key in pairs(request.headers or {}) do
                local lower = tostring(key):lower()
                if lower == "cookie" or lower == "authorization" or lower == "proxy-authorization" or lower == "x-xsrf-token" then return reject() end
            end
            if asset_urls[request.url] then
                category = "metadata"
            elseif request.url == selection.approved_cover_url or selected_cover and request.url == selected_cover.url then
                category = "cover_image"
            elseif allowed_cdn_paths[host .. path] and not (request.output_path and request.output_path:find("/covers/", 1, true)) then
                category = "page_image"
            else return reject() end
        end
        if request.output_path and not within(request.output_path, context.private_root or context.work) then return reject() end
        local serial = sequence()
        if not serial or serial > maximum then return reject() end
        self.current = { serial=serial, category=category, operation=route and route.label or "resource" }
        audit({ event="start", serial=serial, category=category, operation=self.current.operation })
        return true, category
    end
    function guard:after(_request, response, err)
        local current = assert(self.current, "A guarded transport completion is required")
        audit({ event="finish", serial=current.serial, category=current.category,
            operation=current.operation, status=response and response.status or nil,
            transport_succeeded=response ~= nil, transport_failed=err ~= nil })
        self.current = nil
        return true
    end
    return guard
end
