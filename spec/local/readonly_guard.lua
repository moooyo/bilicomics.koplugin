-- Acceptance-only request restrictions; installed before any account Runtime exists.
local Guard = {}
local function denied()
    return { kind = "verification_guard", message = "Local acceptance permits approved authentication and read operations only.",
        transmitted = false, retryable = false }
end
local function keys(names)
    local result = {}; for name in names:gmatch("[^,]+") do result[name] = true end; return result
end
local routes = {
    ["/twirp/bookshelf.v1.Bookshelf/ListFavorite"] = keys("page_num,page_size,order,wait_free,time_limit_free,type,from,source"),
    ["/twirp/bookshelf.v1.Bookshelf/ListHistory"] = keys("page_num,page_size,type"),
    ["/twirp/comic.v1.Comic/Search"] = keys("key_word,page_num,page_size"),
    ["/twirp/comic.v1.Comic/ComicDetail"] = keys("comic_id,m2"),
    ["/twirp/comic.v1.Comic/GetImageIndex"] = keys("ep_id,m2"),
    ["/twirp/comic.v1.Comic/ImageToken"] = keys("urls,m1"),
    ["/twirp/comic.v1.Comic/GetEpisodeBuyInfo"] = keys("ep_id,buy_type,batch_limit,order"),
    ["/twirp/user.v1.User/GetWallet"] = {},
    ["/twirp/comic.v1.Comic/GetDiscountList"] = keys("comic_id,order,original_values"),
    ["/twirp/comic.v1.Comic/CalDiscountPrice"] = keys("id,original_values"),
    ["/twirp/comic.v1.Comic/GetComicFreeGoldCard"] = keys("comic_id,ep_id,buy_type,batch_limit"),
}
local query_keys = keys("device,platform,nov,a,ultra_sign,cpx,m1")
local quote_query_keys = keys("device,platform,nov,a")
local buy_info_path = "/twirp/comic.v1.Comic/GetEpisodeBuyInfo"
local quote_paths = {
    [buy_info_path] = true, ["/twirp/user.v1.User/GetWallet"] = true,
    ["/twirp/comic.v1.Comic/GetDiscountList"] = true,
    ["/twirp/comic.v1.Comic/CalDiscountPrice"] = true,
    ["/twirp/comic.v1.Comic/GetComicFreeGoldCard"] = true,
}
local resource_headers = keys("accept,referer,user-agent,accept-encoding")
local auth_headers = keys("accept,referer,user-agent,origin,cookie,content-type")
local auth_methods = keys("generateQR,pollQR,cookieInfo,refreshSession,confirmRefresh")
local function fields(text, expected)
    if type(text) ~= "string" or #text == 0 or #text > 16384 or text:sub(1, 1) == "&"
        or text:sub(-1) == "&" or text:find("&&", 1, true) then return nil end
    local result = {}
    for part in text:gmatch("[^&]+") do
        local key, value = part:match("^([%w_]+)=([%w%%%.~_-]*)$")
        if not key or not expected[key] or result[key] ~= nil then return nil end
        local malformed = value:gsub("%%%x%x", "")
        if malformed:find("%%") then return nil end
        value = value:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
        if #value == 0 or #value > 8192 or value:find("[%c%s]") then return nil end
        result[key] = value
    end
    for key in pairs(expected) do if result[key] == nil then return nil end end
    return result
end
local function authRequest(request, host, path, query)
    if request.output_path ~= nil or request.max_bytes ~= nil
        and (type(request.max_bytes) ~= "number" or request.max_bytes <= 0 or request.max_bytes > 1048576) then return false end
    local headers = {}
    for key, value in pairs(request.headers or {}) do
        key = tostring(key):lower()
        if not auth_headers[key] or headers[key] ~= nil or type(value) ~= "string" or #value > 32768
            or value:find("[%c]") then return false end
        headers[key] = value
    end
    if headers.referer ~= "https://www.bilibili.com/" or headers.origin ~= "https://www.bilibili.com" then return false end
    local credential = type(headers.cookie) == "string" and #headers.cookie > 0
    local parsed
    if host == "passport.bilibili.com" then
        if path == "/x/passport-login/web/qrcode/generate" then
            parsed = fields(query:sub(2), keys("source,go_url"))
            return request.method == "GET" and request.body == nil and not headers.cookie and parsed
                and parsed.source == "main_web" and parsed.go_url == "https://manga.bilibili.com/"
        elseif path == "/x/passport-login/web/qrcode/poll" then
            parsed = fields(query:sub(2), keys("qrcode_key,source"))
            return request.method == "GET" and request.body == nil and not headers.cookie and parsed
                and parsed.source == "main_web" and #parsed.qrcode_key <= 128 and parsed.qrcode_key:match("^[%w_-]+$") ~= nil
        elseif path == "/x/passport-login/web/cookie/info" then
            parsed = fields(query:sub(2), keys("csrf"))
            return request.method == "GET" and request.body == nil and credential and parsed and #parsed.csrf <= 512
        elseif path == "/x/passport-login/web/cookie/refresh" then
            parsed = fields(request.body, keys("csrf,refresh_csrf,source,refresh_token"))
            return request.method == "POST" and query == "" and credential and parsed
                and headers["content-type"] == "application/x-www-form-urlencoded" and parsed.source == "main_web"
                and #parsed.csrf <= 512 and #parsed.refresh_csrf <= 512 and #parsed.refresh_token <= 4096
        elseif path == "/x/passport-login/web/confirm/refresh" then
            parsed = fields(request.body, keys("csrf,refresh_token"))
            return request.method == "POST" and query == "" and credential and parsed
                and headers["content-type"] == "application/x-www-form-urlencoded"
                and #parsed.csrf <= 512 and #parsed.refresh_token <= 4096
        end
    elseif host == "www.bilibili.com" then
        local challenge = path:match("^/correspond/1/([0-9a-f]+)$")
        return request.method == "GET" and query == "" and request.body == nil and credential and challenge and #challenge == 256
    end
    return false
end
local function safePath(path, encoded)
    if encoded then
        path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
        -- Nested/malformed escapes make the resource directory ambiguous.
        if path:find("%%") then return false end
    end
    if path:find("[%c\\]") then return false end
    for component in path:gmatch("[^/]+") do if component == "." or component == ".." then return false end end
    return true
end
local function integer(value, minimum, maximum)
    return type(value) == "number" and value == value and value % 1 == 0 and value >= minimum and value <= maximum
end
local function identifier(value) return integer(value, 1, 999999999999999) end
local function buyType(value) return value == 1 or value == 2 or value == 3 end
local function order(value) return value == 1 or value == 2 end
local function originalValues(values)
    -- The quote UI uses two base amounts followed by at most 512 original offers.
    if type(values) ~= "table" or #values < 2 or #values > 514 then return false end
    local count = 0
    for index, value in pairs(values) do
        if not integer(index, 1, #values) or type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then return false end
        count = count + 1
    end
    return count == #values
end
local function quoteBody(path, body, discounts)
    if path == buy_info_path then
        if not identifier(body.ep_id) then return false end
        if body.buy_type == nil then return not discounts and body.batch_limit == nil and body.order == nil end
        return discounts == true and buyType(body.buy_type) and order(body.order)
            and (body.batch_limit == nil and body.buy_type ~= 2 or integer(body.batch_limit, 0, 2147483647))
    elseif path == "/twirp/user.v1.User/GetWallet" then
        return next(body) == nil
    elseif path == "/twirp/comic.v1.Comic/GetDiscountList" then
        return identifier(body.comic_id) and order(body.order) and originalValues(body.original_values)
    elseif path == "/twirp/comic.v1.Comic/CalDiscountPrice" then
        return identifier(body.id) and originalValues(body.original_values)
    elseif path == "/twirp/comic.v1.Comic/GetComicFreeGoldCard" then
        return identifier(body.comic_id) and identifier(body.ep_id) and buyType(body.buy_type)
            and integer(body.batch_limit, 0, 2147483647)
    end
    return false
end
local function resourceURL(token)
    local function absolute(value) return value:sub(1, 2) == "//" and "https:" .. value or value end
    if type(token.complete_url) == "string" and token.complete_url ~= "" then
        if token.complete_url:sub(1, 7) == "http://" then return "https://" .. token.complete_url:sub(8) end
        return absolute(token.complete_url) .. "&code=DanmakuInfo"
    end
    if type(token.url) ~= "string" or token.url == "" then return nil end
    local url = absolute(token.url)
    if type(token.token) == "string" and token.token ~= "" then
        local value = token.token:gsub("[^%w%-_%.~]", function(char) return string.format("%%%02X", char:byte()) end)
        url = url .. (url:find("?", 1, true) and "&" or "?") .. "token=" .. value
    end
    return url
end

function Guard.install(profile)
    local Transport = require("bilicomics/protocol/transport")
    local original_request = Transport.request
    -- Leave the transport closed if subsequent guard setup fails.
    Transport.request = function() return nil, denied() end
    local JSON = require("bilicomics/protocol/json")
    local Client = require("bilicomics/protocol/client")
    local Runner = require("bilicomics/jobs/runner")
    local UIManager = require("ui/uimanager")
    local pinned, active_images = {}, {}
    for _name, asset in pairs(require("bilicomics/protocol/assets").manifest) do pinned[asset.url] = true end
    local original_download = Client.downloadImage
    function Client:downloadImage(token, ...)
        local url = type(token) == "table" and resourceURL(token)
        if not url then return nil, denied() end
        active_images[url] = true
        local value, err = original_download(self, token, ...)
        active_images[url] = nil
        return value, err
    end
    local original_submit = Runner.submit
    local client_reads = keys("validateSession,listFavorites,listHistory,search,comicDetail,imageIndex,imageTokens,wallet,purchaseInfo,discountList,discountPrice,freeGoldCardInfo")
    function Runner:submit(request, options, callback)
        local allowed = type(request) == "table" and ((request.kind == "client" and client_reads[request.method])
            or request.kind == "library" or request.kind == "download_page" or request.kind == "download_cover"
            or request.kind == "source_index" or request.kind == "verify_source_page"
            or request.kind == "quote" or request.kind == "reconcile_purchase"
            or request.kind == "auth" and auth_methods[request.method]
            or request.kind == "diagnostics")
        if not allowed then
            if callback then UIManager:nextTick(callback, nil, denied()) end
            return nil, denied()
        end
        return original_submit(self, request, options, callback)
    end
    function Transport:request(request)
        if type(request) ~= "table" or type(request.url) ~= "string" or request.url:find("[%c%s#]") then return nil, denied() end
        local host, path, query = request.url:match("^https://([%w%.%-]+)(/[^?]*)(.*)$")
        if not host or not safePath(path, true) or (query ~= "" and query:sub(1, 1) ~= "?") then return nil, denied() end
        if request.output_path and (type(request.output_path) ~= "string" or request.output_path:sub(1, #profile + 1) ~= profile .. "/"
            or not safePath(request.output_path, false)) then return nil, denied() end
        if host == "passport.bilibili.com" or host == "www.bilibili.com" then
            if not authRequest(request, host, path, query) then return nil, denied() end
        elseif host == "api.bilibili.com" and path == "/x/web-interface/nav" then
            if request.method ~= "GET" or request.body or query ~= "" then return nil, denied() end
        elseif host == "manga.bilibili.com" and routes[path] then
            if request.method ~= "POST" or type(request.body) ~= "string" or #request.body > 262144 then return nil, denied() end
            local seen, discounts = {}, false
            local query_text = query:sub(2)
            if query_text == "" or query_text:sub(1, 1) == "&" or query_text:sub(-1) == "&" or query_text:find("&&", 1, true) then return nil, denied() end
            local permitted_query_keys = quote_paths[path] and quote_query_keys or query_keys
            for part in query_text:gmatch("[^&]+") do
                local key, value = part:match("^([^=]+)=(.*)$")
                if not key then
                    if part ~= "getEpisodeDiscounts" or path ~= buy_info_path or discounts then return nil, denied() end
                    discounts = true
                else
                    if not permitted_query_keys[key] or seen[key] then return nil, denied() end
                    seen[key] = value
                end
            end
            if seen.device ~= "pc" or seen.platform ~= "web" or seen.nov ~= "27" or seen.a ~= "810" then return nil, denied() end
            local body = JSON.decode(request.body)
            if type(body) ~= "table" then return nil, denied() end
            for key in pairs(body) do if not routes[path][key] then return nil, denied() end end
            if quote_paths[path] then
                if request.output_path ~= nil or not request.body:match("^%s*{") or not request.body:match("}%s*$")
                    or not quoteBody(path, body, discounts) then return nil, denied() end
            end
            if body.wait_free and body.wait_free ~= 0 or body.time_limit_free and body.time_limit_free ~= 0
                or body.type and body.type ~= 0 then return nil, denied() end
        else
            if request.method ~= "GET" or request.body then return nil, denied() end
            if not pinned[request.url] then
                local cdn = host:match("%.hdslb%.com$") or host:match("%.biliimg%.com$") or host:match("%.bilibili%.com$")
                if not active_images[request.url] or not cdn or path:sub(1, 5) ~= "/bfs/" then return nil, denied() end
            end
            for key in pairs(request.headers or {}) do
                if not resource_headers[tostring(key):lower()] then return nil, denied() end
            end
        end
        return original_request(self, request)
    end
    return true
end
return Guard
