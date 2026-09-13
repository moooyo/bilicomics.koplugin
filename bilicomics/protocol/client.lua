local Crypto = require("bilicomics/protocol/crypto")
local Categories = require("bilicomics/protocol/categories")
local Errors = require("bilicomics/protocol/errors")
local Image = require("bilicomics/protocol/image")
local JSON = require("bilicomics/protocol/json")
local Normalize = require("bilicomics/protocol/normalize")
local Recommendations = require("bilicomics/protocol/recommendations")
local Session = require("bilicomics/protocol/session")
local Transport = require("bilicomics/protocol/transport")

local Client = {}
Client.__index = Client

local BASE = "https://manga.bilibili.com"
local SIGN_QUERY = "device=pc&platform=web&nov=27&eot=812"
local protected = { ComicDetail = true, ClassPage = true, GetImageIndex = true, ImageToken = true }

local function escape(value)
    return tostring(value):gsub("[^%w%-_%.~]", function(char) return string.format("%%%02X", char:byte()) end)
end

local function id(value)
    if value == nil then return nil end
    value = tostring(value)
    if not value:match("^[1-9]%d*$") or #value > 15 then return nil end
    return tonumber(value)
end

local function responseId(value)
    if type(value) == "number" then
        if value ~= value or value < 1 or value > 999999999999999 or value % 1 ~= 0 then return nil end
        return string.format("%.0f", value)
    end
    if type(value) == "string" and id(value) then return value end
end

local function invalid(message)
    return nil, Errors.new("invalid_request", message, { transmitted = false, definitive = true })
end

local function pageOptions(opts)
    opts = opts or {}
    return math.max(1, math.floor(tonumber(opts.page_num or opts.page) or 1)),
        math.max(1, math.min(100, math.floor(tonumber(opts.page_size or opts.size) or 20)))
end

function Client.new(opts)
    opts = opts or {}
    local transport = opts.transport or Transport.new(opts.transport_options)
    return setmetatable({
        session = opts.session and Session.new(opts.session),
        transport = transport,
        crypto = opts.crypto or Crypto.new({ transport = transport, asset_root = opts.asset_root }), clock = opts.clock or os.time,
        _token_context = nil,
    }, Client)
end

function Client:capabilities()
    local crypto = self.crypto:capabilities()
    return {
        session = true, library = true, search = true, recommendations = true, wallet = true, quoting = true,
        purchase = true, plain_images = true,
        protected_catalog = crypto.request_signing and crypto.response_decoding,
        image_index = crypto.request_signing and crypto.response_decoding and (crypto.index_challenge or crypto.index_error_reporting),
        image_tokens = crypto.request_signing and crypto.response_decoding and crypto.image_key_exchange,
        encrypted_images = crypto.encrypted_images,
        crypto = crypto,
    }
end

function Client:_headers(host)
    local headers = {
        ["user-agent"] = "Mozilla/5.0 (X11; Linux) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36",
        ["accept"] = "application/json, text/plain, */*",
        ["content-type"] = "application/json;charset=UTF-8",
        ["referer"] = BASE .. "/",
        ["origin"] = BASE,
    }
    if self.session then
        headers.cookie = self.session:cookieHeader(host)
        if host == "manga.bilibili.com" and self.session.cookies["XSRF-TOKEN"] then
            headers["x-xsrf-token"] = self.session.cookies["XSRF-TOKEN"]:gsub("%%(%x%x)", function(hex)
                return string.char(tonumber(hex, 16))
            end)
            if headers["x-xsrf-token"]:find("[\r\n%z]") then headers["x-xsrf-token"] = nil end
        end
    end
    return headers
end

function Client:_captureCookies(response, host)
    if not self.session then return true end
    local before = JSON.encode(self.session:serialize())
    local ok, err = self.session:applySetCookie(response.headers, host, self.clock())
    if not ok then return nil, err end
    if JSON.encode(self.session:serialize()) ~= before then self._session_changed = true end
    return true
end

function Client:_envelope(response, endpoint, context)
    if not response or type(response.status) ~= "number" then
        return nil, Errors.new("protocol", "The transport returned an invalid HTTP result.")
    end
    if response.status < 200 or response.status >= 300 then
        local kind = (response.status == 401) and "authentication" or "http"
        return nil, Errors.new(kind, "The service returned an unsuccessful HTTP response.", {
            status = response.status, retryable = response.status == 429 or response.status >= 500,
            transmitted = response.transmitted,
        })
    end
    local envelope, err = JSON.decode(response.body)
    if not envelope then
        err.transmitted = response.transmitted
        return nil, err
    end
    if tonumber(envelope.code) and tonumber(envelope.code) ~= 0 then
        return nil, Errors.business(envelope.code, endpoint)
    end
    if envelope.bytesData and envelope.bytesData ~= "" then
        local decoded
        decoded, err = self.crypto:decodeResponse(context, envelope)
        if not decoded then return nil, err end
        envelope = decoded
    end
    local code = tonumber(envelope.code)
    if code == nil then return nil, Errors.new("protocol", "The service response has no business status.") end
    if code ~= 0 then return nil, Errors.business(code, endpoint) end
    if type(envelope.data) ~= "table" then
        if endpoint == "BuyEpisode" or endpoint == "AddHistory" or endpoint == "AddFavorite" or endpoint == "DeleteFavorite" then
            return { accepted = true, code = 0 }
        end
        return nil, Errors.new("protocol", "The service response contains no usable data.")
    end
    return envelope.data
end

function Client:_post(service, endpoint, body, opts)
    opts = opts or {}
    if opts.auth and (not self.session or not self.session.cookies.SESSDATA) then
        return nil, Errors.new("authentication", "Import a valid web session to continue.", { transmitted = false })
    end
    local encoded, err = JSON.encode(body or {})
    if not encoded then return nil, err end
    local path = "/twirp/" .. service .. "/" .. endpoint
    local params = { "device=pc", "platform=web", "nov=27", "a=810" }
    if opts.flag then params[#params + 1] = opts.flag end
    for _, key in ipairs({ "cpx", "m1" }) do
        if opts.query and opts.query[key] ~= nil then params[#params + 1] = key .. "=" .. escape(opts.query[key]) end
    end
    local headers = self:_headers("manga.bilibili.com")
    local context = {
        endpoint = endpoint, path = path, body = encoded, sign_query = SIGN_QUERY,
        platform = "web", buvid = self.session and (self.session.cookies.buvid3 or self.session.cookies.buvid4) or "",
        timestamp = self.clock(),
    }
    if protected[endpoint] then
        local signed
        signed, err = self.crypto:signRequest(context)
        if not signed then return nil, err end
        if type(signed.ultra_sign) ~= "string" or not signed.data_sn then
            return nil, Errors.new("protocol", "The signing adapter returned an invalid result.", { transmitted = false })
        end
        params[#params + 1] = "ultra_sign=" .. escape(signed.ultra_sign)
        headers["x-bili-data-sn"] = tostring(signed.data_sn)
    end
    context.url = BASE .. path .. "?" .. table.concat(params, "&")
    local response
    response, err = self.transport:request({ url = context.url, method = "POST", headers = headers, body = encoded })
    if not response then return nil, err end
    local value, business_error = self:_envelope(response, endpoint, context)
    local captured, cookie_error = self:_captureCookies(response, "manga.bilibili.com")
    -- A received mutation receipt remains authoritative even if its optional cookie headers are malformed.
    if not captured and value and endpoint ~= "BuyEpisode" and endpoint ~= "AddFavorite" and endpoint ~= "DeleteFavorite" then
        return nil, cookie_error
    end
    return value, business_error
end

function Client:validateSession()
    if not self.session or not self.session.cookies.SESSDATA then
        return nil, Errors.new("authentication", "No imported web session is available.", { transmitted = false })
    end
    local response, err = self.transport:request({
        url = "https://api.bilibili.com/x/web-interface/nav", method = "GET", headers = self:_headers("api.bilibili.com"),
    })
    if not response then return nil, err end
    local captured
    captured, err = self:_captureCookies(response, "api.bilibili.com")
    if not captured then return nil, err end
    local data
    data, err = self:_envelope(response, "Nav", {})
    if not data then return nil, err end
    if data.isLogin ~= true then return nil, Errors.new("authentication", "The imported session has expired.") end
    local session
    session, err = self.session:withIdentity(data, self.clock())
    if not session then return nil, err end
    return session:summary()
end

function Client:listFavorites(opts)
    local page, size = pageOptions(opts)
    local data, err = self:_post("bookshelf.v1.Bookshelf", "ListFavorite", {
        page_num = page, page_size = size, order = tonumber(opts and opts.order) or 1,
        wait_free = 0, time_limit_free = 0, type = 0, from = "web", source = "web",
    }, { auth = true })
    if not data then return nil, err end
    return Normalize.comicList(data)
end

function Client:listHistory(opts)
    local page, size = pageOptions(opts)
    local data, err = self:_post("bookshelf.v1.Bookshelf", "ListHistory", {
        page_num = page, page_size = size, type = 0,
    }, { auth = true })
    if not data then return nil, err end
    return Normalize.comicList(data)
end

function Client:recommendations()
    return Recommendations.fetch(self.transport)
end

function Client:bookstoreCategories()
    return Categories.metadata(self.transport)
end

function Client:bookstoreCategoryPage(query, page)
    return Categories.page(self, query, page)
end

function Client:search(query, opts)
    if type(query) ~= "string" or query == "" or #query > 300 then return invalid("Enter a search term.") end
    local page, size = pageOptions(opts)
    local data, err = self:_post("comic.v1.Comic", "Search", { key_word = query, page_num = page, page_size = size })
    if not data then return nil, err end
    return Normalize.comicList(data)
end

function Client:comicDetail(comic_id)
    if not id(comic_id) then return invalid("A comic identifier is required.") end
    local body = { comic_id = id(comic_id) }
    if self.crypto.prepareCatalog then
        local preparation, err = self.crypto:prepareCatalog({ comic_id = tostring(comic_id), timestamp_ms = self.clock() * 1000 })
        if not preparation then return nil, err end
        body.m2 = preparation.m2
    end
    local data, err = self:_post("comic.v1.Comic", "ComicDetail", body)
    if not data then return nil, err end
    local episodes = {}
    for _, raw in ipairs(data.ep_list or data.episodes or {}) do
        episodes[#episodes + 1] = Normalize.episode(raw, comic_id, self.clock())
    end
    table.sort(episodes, function(a, b) if a.order == b.order then return a.id < b.id end; return a.order < b.order end)
    local comic = Normalize.comic(data)
    if comic.id == "" then comic.id = tostring(comic_id) end
    return { comic = comic, episodes = episodes, extra = Normalize.safeExtra(data) }
end

function Client:imageIndex(episode_id)
    if not id(episode_id) then return invalid("An episode identifier is required.") end
    local preparation, err = self.crypto:prepareIndex({ episode_id = tostring(episode_id), session = self.session, timestamp_ms = self.clock() * 1000 })
    if not preparation then return nil, err end
    local data
    data, err = self:_post("comic.v1.Comic", "GetImageIndex", {
        ep_id = id(episode_id), m2 = preparation.m2,
    }, { query = preparation.query, auth = true })
    if not data then return nil, err end
    if type(data.images) ~= "table" or #data.images == 0 then
        return nil, Errors.new("protocol", "The episode has no supported ordered image index.")
    end
    local images, revision_parts = {}, {}
    for index, raw in ipairs(data.images) do
        local width, height = tonumber(raw.x or raw.width), tonumber(raw.y or raw.height)
        if type(raw.path) ~= "string" or raw.path == "" or not width or not height or width < 1 or height < 1 then
            return nil, Errors.new("protocol", "The image index contains invalid geometry or paths.")
        end
        local source_id = require("ffi/sha2").sha256(raw.path)
        images[index] = { id = source_id, index = index, path = raw.path, x = width, y = height, width = width, height = height }
        revision_parts[index] = source_id .. ":" .. width .. ":" .. height
    end
    return {
        episode_id = tostring(episode_id), images = images, pages = images,
        revision = require("ffi/sha2").sha256(table.concat(revision_parts, "\n")),
        extra = Normalize.safeExtra(data),
    }
end

function Client:imageTokens(paths, opts)
    if type(paths) ~= "table" or #paths < 1 or #paths > 20 then return invalid("A bounded image path list is required.") end
    for _, path in ipairs(paths) do
        if type(path) ~= "string" or path == "" or #path > 8192 then return invalid("An image path is invalid.") end
    end
    local preparation, err = self.crypto:prepareTokens(opts or {})
    if not preparation then return nil, err end
    local encoded_paths = require("rapidjson").encode(JSON.array(paths))
    local data
    data, err = self:_post("comic.v1.Comic", "ImageToken", { urls = encoded_paths, m1 = preparation.m1 }, { auth = true })
    if not data then return nil, err end
    local tokens = data.tokens or data
    if type(tokens) ~= "table" or #tokens ~= #paths then
        return nil, Errors.new("protocol", "The image token response does not match the requested images.")
    end
    self._token_context = preparation
    for index, token in ipairs(tokens) do
        token.source_path = paths[index]
        token.source_index = opts and opts.index or index
    end
    return tokens
end

local function imageURL(token)
    local function absolute(url) return url:sub(1, 2) == "//" and "https:" .. url or url end
    if type(token.complete_url) == "string" and token.complete_url ~= "" then
        -- Match ReaderImage.loadToken: its HTTP upgrade replaces the marker-bearing URL.
        if token.complete_url:sub(1, 7) == "http://" then
            return "https://" .. token.complete_url:sub(8)
        end
        return absolute(token.complete_url) .. "&code=DanmakuInfo"
    end
    if type(token.url) ~= "string" or token.url == "" then return nil end
    if type(token.token) == "string" and token.token ~= "" then
        return absolute(token.url) .. (token.url:find("?", 1, true) and "&" or "?") .. "token=" .. escape(token.token)
    end
    return absolute(token.url)
end

function Client:downloadImage(token, temporary_path, opts)
    opts = opts or {}
    if type(token) ~= "table" or type(temporary_path) ~= "string" or temporary_path == "" then
        return invalid("An image token and temporary output path are required.")
    end
    local url = imageURL(token)
    local host = url and url:match("^https://([%w%.%-]+)/")
    if not host or not (host:match("%.hdslb%.com$") or host:match("%.biliimg%.com$") or host:match("%.bilibili%.com$")) then
        return invalid("The image token does not contain a supported HTTPS image resource.")
    end
    local encrypted = token.hit_encrpyt == true or token.hit_encrpyt == 1
    if encrypted then
        local converted, err = self.crypto:convertImage({ token = token, url = url, context = self._token_context,
            output_path = temporary_path, index = opts.index or token.source_index, transport = self.transport,
            max_bytes = opts.max_bytes, total_timeout = opts.total_timeout })
        if not converted then return nil, err end
    else
        local response, err = self.transport:request({ url = url, method = "GET", output_path = temporary_path,
            headers = { referer = BASE .. "/", ["user-agent"] = self:_headers("manga.bilibili.com")["user-agent"] },
            max_bytes = opts.max_bytes, total_timeout = opts.total_timeout })
        if not response then return nil, err end
        if response.status ~= 200 then
            os.remove(temporary_path)
            -- A generic 403 can mean permission, signing or token expiry. It must not trigger blind token refresh.
            return nil, Errors.new("image_http", "The image service rejected the resource.", {
                status = response.status, retryable = response.status == 429 or response.status >= 500,
            })
        end
    end
    local result, err = Image.inspect(temporary_path, opts)
    if not result then os.remove(temporary_path); return nil, err end
    return result
end

function Client:wallet()
    local data, err = self:_post("user.v1.User", "GetWallet", {}, { auth = true })
    if not data then return nil, err end
    return Normalize.safeExtra(data)
end

function Client:purchaseInfo(episode_id, scope)
    if not id(episode_id) then return invalid("An episode identifier is required for a quote.") end
    local body, opts = { ep_id = id(episode_id) }, { auth = true }
    if scope ~= nil then
        if scope == "single" then scope = { kind = "single" } end
        if type(scope) ~= "table" then return invalid("The quote scope must be a supported scope object.") end
        local allowed = { kind = true, buy_type = true, batch_limit = true, order = true, start_ord = true }
        for key in pairs(scope) do
            if not allowed[key] then return invalid("The quote scope contains an unsupported field.") end
        end
        if scope.kind ~= nil and scope.kind ~= "single" and scope.kind ~= "batch" then
            return invalid("The quote scope kind is unsupported.")
        end
        local buy_type
        if scope.buy_type ~= nil then
            buy_type = tonumber(scope.buy_type)
            if buy_type ~= 1 and buy_type ~= 2 and buy_type ~= 3 then
                return invalid("The quote purchase type is unsupported.")
            end
        end
        if scope.kind == "batch" then
            if buy_type and buy_type ~= 2 then return invalid("The batch quote scope conflicts with its purchase type.") end
            buy_type = 2
        elseif scope.kind == "single" and buy_type and buy_type ~= 1 then
            return invalid("The single quote scope conflicts with its purchase type.")
        end
        if buy_type then
            local order = scope.order == nil and 1 or tonumber(scope.order)
            if order ~= 1 and order ~= 2 then return invalid("Select a supported discount sort order.") end
            local limit = scope.batch_limit ~= nil and tonumber(scope.batch_limit) or nil
            if (scope.batch_limit ~= nil and (not limit or limit < 0 or limit > 2147483647 or limit % 1 ~= 0))
                or (buy_type == 2 and limit == nil) then
                return invalid("A batch quote limit must be a nonnegative bounded integer.")
            end
            if scope.start_ord ~= nil then
                local start = tonumber(scope.start_ord)
                if buy_type ~= 2 or not start or start ~= start or math.abs(start) == math.huge then
                    return invalid("The quote chapter ordinal is invalid for this scope.")
                end
            end
            -- Chapter ordinals are not discount sorting; zero is a read-only remaining-offer query.
            body.buy_type, body.batch_limit, body.order = buy_type, limit, order
            opts.flag = "getEpisodeDiscounts"
        elseif scope.batch_limit ~= nil or scope.order ~= nil or scope.start_ord ~= nil then
            return invalid("Range fields require an explicit supported quote scope.")
        end
    end
    local data, err = self:_post("comic.v1.Comic", "GetEpisodeBuyInfo", body, opts)
    if not data then return nil, err end
    if data.ep_id ~= nil and responseId(data.ep_id) ~= responseId(episode_id) then
        return nil, Errors.new("protocol", "The quote response contains an invalid or different episode identity.")
    end
    if data.comic_id ~= nil and not responseId(data.comic_id) then
        return nil, Errors.new("protocol", "The quote response contains an invalid comic identity.")
    end
    data = Normalize.safeExtra(data)
    data.ep_id = tostring(episode_id)
    if data.comic_id ~= nil then data.comic_id = responseId(data.comic_id) end
    return data
end

function Client:discountList(comic_id, order, original_values)
    if not id(comic_id) then return invalid("A comic identifier is required.") end
    return self:_post("comic.v1.Comic", "GetDiscountList", {
        comic_id = id(comic_id), order = order, original_values = original_values,
    }, { auth = true })
end

function Client:discountPrice(discount_id, original_values)
    if not id(discount_id) then return invalid("A discount identifier is required.") end
    return self:_post("comic.v1.Comic", "CalDiscountPrice", { id = id(discount_id), original_values = original_values }, { auth = true })
end

function Client:freeGoldCardInfo(comic_id, episode_id, scope)
    if not id(comic_id) or not id(episode_id) or type(scope) ~= "table" then
        return invalid("A comic, episode and explicit free-gold-card query scope are required.")
    end
    for key in pairs(scope) do
        if key ~= "buy_type" and key ~= "batch_limit" then return invalid("Unsupported free-gold-card query scope.") end
    end
    local buy_type, count = tonumber(scope.buy_type), tonumber(scope.batch_limit)
    if (buy_type ~= 1 and buy_type ~= 2 and buy_type ~= 3) or not count
        or count < 0 or count > 2147483647 or count % 1 ~= 0 then
        return invalid("A supported purchase type and bounded chapter count are required.")
    end
    local data, err = self:_post("comic.v1.Comic", "GetComicFreeGoldCard", {
        comic_id = id(comic_id), ep_id = id(episode_id), buy_type = buy_type, batch_limit = count,
    }, { auth = true })
    if not data then return nil, err end
    return Normalize.safeExtra(data)
end

function Client:buyEpisode(payload)
    if type(payload) ~= "table" then return invalid("A confirmed purchase payload is required.") end
    if payload.buy_method ~= 2 and payload.buy_method ~= 3 then return invalid("Only an explicit currency or coupon purchase is supported.") end
    local allowed = { ep_id = true, comic_id = true, buy_method = true, pay_amount = true,
        coupon_id = true, coupon_ids = true, free_gold_card_id = true, free_gold_amount = true,
        with_ord_scope = true, start_ord = true, limit = true }
    for key in pairs(payload) do
        if not allowed[key] then return invalid("The purchase payload contains an unsupported option.") end
    end
    local body = {}
    for key, value in pairs(payload) do body[key] = value end
    if body.ep_id then
        if not id(body.ep_id) or body.with_ord_scope or body.start_ord or body.limit then return invalid("The single-episode scope is invalid.") end
        body.ep_id = id(body.ep_id)
        if body.comic_id then body.comic_id = id(body.comic_id) end
    else
        if not id(body.comic_id) or body.with_ord_scope ~= true or type(body.start_ord) ~= "number"
            or body.start_ord ~= body.start_ord or math.abs(body.start_ord) == math.huge
            or type(body.limit) ~= "number" or body.limit < 0 or body.limit > 2147483647 or body.limit % 1 ~= 0 then
            return invalid("A verified server-supported ordinal range is required.")
        end
        if body.buy_method ~= 3 then return invalid("Batch coupon purchases are not supported.") end
        body.comic_id = id(body.comic_id)
    end
    if body.pay_amount ~= nil and (type(body.pay_amount) ~= "number" or body.pay_amount < 0
        or body.pay_amount ~= body.pay_amount or body.pay_amount == math.huge) then
        return invalid("A current server-quoted purchase amount is required.")
    end
    if body.buy_method == 2 and not body.coupon_id and not body.coupon_ids then
        return invalid("Eligible coupon identifiers are required.")
    end
    -- No retry wrapper surrounds this call. The caller owns a durable, explicitly confirmed intent.
    return self:_post("comic.v1.Comic", "BuyEpisode", body, { auth = true })
end

function Client:addHistory(comic_id, episode_id)
    if not id(comic_id) or not id(episode_id) then return invalid("Comic and episode identifiers are required.") end
    return self:_post("bookshelf.v1.Bookshelf", "AddHistory", { comic_id = id(comic_id), ep_id = id(episode_id) }, { auth = true })
end

function Client:setFavorite(comic_id, favorite)
    if not id(comic_id) or type(favorite) ~= "boolean" then return invalid("A comic and a following state are required.") end
    return self:_post("bookshelf.v1.Bookshelf", favorite and "AddFavorite" or "DeleteFavorite", {
        comic_ids = tostring(comic_id),
    }, { auth = true })
end

return Client
