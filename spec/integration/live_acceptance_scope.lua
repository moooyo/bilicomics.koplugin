-- Shared, read-only boundaries for the real authentication and reading harnesses.
-- Returned labels never contain request values, account identity or credentials.
local JSON = require("rapidjson")
local Scope = {}

local function keys(names)
    local result = {}
    for name in names:gmatch("[^,]+") do result[name] = true end
    return result
end
local function fields(text, expected)
    if type(text) ~= "string" or #text == 0 or #text > 16384
        or text:sub(1, 1) == "&" or text:sub(-1) == "&" or text:find("&&", 1, true) then return end
    local result = {}
    for item in text:gmatch("[^&]+") do
        local name, value = item:match("^([%w_]+)=([%w%%%.~_-]*)$")
        if not name or not expected[name] or result[name] ~= nil or value:gsub("%%%x%x", ""):find("%%") then return end
        value = value:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
        if value == "" or value:find("[%c%s]") then return end
        result[name] = value
    end
    for name in pairs(expected) do if result[name] == nil then return end end
    return result
end
local function headers(request, allowed)
    if request.headers ~= nil and type(request.headers) ~= "table" then return end
    local result = {}
    for name, value in pairs(request.headers or {}) do
        if type(name) ~= "string" or type(value) ~= "string" or #value > 32768 or value:find("[%c]") then return end
        name = name:lower()
        if not allowed[name] or result[name] ~= nil then return end
        result[name] = value
    end
    return result
end
local function integer(value, low, high)
    return type(value) == "number" and value == value and value % 1 == 0 and value >= low and value <= high
end
local auth_headers = keys("accept,referer,user-agent,origin,cookie,content-type")
local library_headers = keys("accept,referer,user-agent,origin,cookie,content-type,x-xsrf-token")
local library_keys = {
    favorites = keys("page_num,page_size,order,wait_free,time_limit_free,type,from,source"),
    history = keys("page_num,page_size,type"),
}

function Scope.transportCategory(request, phase)
    if type(request) ~= "table" or (phase ~= "login" and phase ~= "restart" and phase ~= "reading")
        or request.output_path ~= nil or type(request.url) ~= "string" or request.url:find("[%c%s#]") then return end
    local host, path, query = request.url:match("^https://([%w.-]+)(/[^?]*)(.*)$")
    if not host or request.method ~= "GET" and request.method ~= "POST" then return end
    if request.max_bytes ~= nil and not integer(request.max_bytes, 1, 1048576) then return end
    if host == "manga.bilibili.com" and path == "/ductape/buvid" then
        local values = headers(request, keys("accept,referer,user-agent"))
        if values and values.referer == "https://manga.bilibili.com/" and query == ""
            and request.method == "GET" and request.body == nil then return "site_context" end
        return
    end
    local library = path == "/twirp/bookshelf.v1.Bookshelf/ListFavorite" and "favorites"
        or path == "/twirp/bookshelf.v1.Bookshelf/ListHistory" and "history"
    if host == "manga.bilibili.com" and library then
        local values = headers(request, library_headers)
        if not values or not values.cookie or values.cookie == "" or values.referer ~= "https://manga.bilibili.com/"
            or values.origin ~= "https://manga.bilibili.com" or request.method ~= "POST"
            or query ~= "?device=pc&platform=web&nov=27&a=810" or type(request.body) ~= "string"
            or #request.body > 16384 then return end
        local ok, body = pcall(JSON.decode, request.body)
        if not ok or type(body) ~= "table" then return end
        for name in pairs(body) do if not library_keys[library][name] then return end end
        if not integer(body.page_num, 1, 200) or body.page_size ~= 50 or body.type ~= 0 then return end
        if library == "favorites" and (body.order ~= 1 or body.wait_free ~= 0 or body.time_limit_free ~= 0
            or body.from ~= "web" or body.source ~= "web") then return end
        return "library_" .. library
    end
    local values = headers(request, auth_headers)
    if not values or request.method ~= "GET" or request.body ~= nil then return end
    if host == "api.bilibili.com" and path == "/x/web-interface/nav" and query == ""
        and values.cookie and values.cookie ~= "" then return "identity_check" end
    if host ~= "passport.bilibili.com" or values.referer ~= "https://www.bilibili.com/"
        or values.origin ~= "https://www.bilibili.com" then return end
    if path == "/x/passport-login/web/qrcode/generate" and phase == "login" and not values.cookie then
        local parsed = fields(query:sub(2), keys("source,go_url"))
        if query:sub(1, 1) == "?" and parsed and parsed.source == "main_web"
            and parsed.go_url == "https://manga.bilibili.com/" then return "qr_generate" end
    elseif path == "/x/passport-login/web/qrcode/poll" and phase == "login" and not values.cookie then
        local parsed = fields(query:sub(2), keys("qrcode_key,source"))
        if query:sub(1, 1) == "?" and parsed and parsed.source == "main_web"
            and #parsed.qrcode_key <= 128 and parsed.qrcode_key:match("^[%w_-]+$") then return "qr_poll" end
    elseif path == "/x/passport-login/web/cookie/info" and values.cookie and values.cookie ~= "" then
        local parsed = fields(query:sub(2), keys("csrf"))
        if query:sub(1, 1) == "?" and parsed and #parsed.csrf <= 512 then return "cookie_info" end
    end
end

function Scope.submissionName(request, phase, checked_info)
    if type(request) ~= "table" or (phase ~= "login" and phase ~= "restart" and phase ~= "reading" and phase ~= "rehearse") then return end
    if phase ~= "rehearse" and request.kind == "library" and (request.library == "favorites" or request.library == "history") then
        return "library_" .. request.library
    end
    if request.kind ~= "auth" then return end
    local method = request.method
    if (phase == "login" or phase == "rehearse") and (method == "generateQR" or method == "pollQR") then return method end
    if phase == "rehearse" then return end
    if method == "ensureSiteContext" or method == "cookieInfo" then return method end
    if method == "refreshSession" then
        local info = request.arguments and request.arguments[1] and request.arguments[1].info
        if checked_info and checked_info.refresh == false and type(info) == "table" and info.refresh == false
            and info.timestamp == checked_info.timestamp then return method end
    end
    -- The no-refresh maintenance method remains available, but no live rotation or confirmation is admitted.
end

function Scope.rotationDeferred(value)
    return type(value) == "table" and value.refresh == true
end

function Scope.coverAllowed(request, approved)
    if type(request) ~= "table" or type(approved) ~= "table" or type(request.url) ~= "string"
        or approved[request.url] ~= request.output_path or request.output_path == nil
        or request.method ~= "GET" or request.body ~= nil or request.url:find("[%c%s#]") then return false end
    local host, path = request.url:match("^https://([%w.-]+)(/[^?]*)")
    if not host then return false end
    path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
    local account_hosts = { ["passport.bilibili.com"] = true, ["api.bilibili.com"] = true,
        ["www.bilibili.com"] = true, ["manga.bilibili.com"] = true }
    if account_hosts[host:lower()] or path:find("%%")
        or path:match("^/x/passport%-login/") or path:match("^/correspond/") then return false end
    local values = headers(request, keys("accept,referer,user-agent,accept-encoding"))
    return values ~= nil and (request.max_bytes == nil or integer(request.max_bytes, 1, 4 * 1024 * 1024))
end

return Scope
