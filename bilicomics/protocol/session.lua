local Errors = require("bilicomics/protocol/errors")
local JSON = require("bilicomics/protocol/json")

local Session = {}
Session.__index = Session

local allowed = {
    SESSDATA = true, bili_jct = true, DedeUserID = true, DedeUserID__ckMd5 = true,
    buvid3 = true, buvid4 = true, buvid_fp = true, b_nut = true, b_lsid = true,
    ["XSRF-TOKEN"] = true,
}

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function validCookie(name, value)
    return allowed[name] and type(value) == "string" and #value <= 16384
        and not value:find("[%c%s;,]") and #value > 0
end

local function acceptsDomain(domain)
    if not domain or domain == "" then return true end
    domain = domain:lower():gsub("^%.", "")
    return domain == "bilibili.com" or domain == "manga.bilibili.com" or domain == "api.bilibili.com"
        or domain == "passport.bilibili.com" or domain == "www.bilibili.com"
end

local function timestamp(value)
    value = tonumber(value)
    return value and value == value and value > 0 and value <= 253402300799
        and value % 1 == 0 and value or nil
end

local function credential(value)
    return type(value) == "string" and #value > 0 and #value <= 16384
        and not value:find("[%c%s]") and value or nil
end

local function copy(value)
    local result = {}
    for key, item in pairs(type(value) == "table" and value or {}) do result[key] = item end
    return result
end

local function cookieDomain(value)
    if type(value) ~= "string" or not acceptsDomain(value) then return nil end
    return value:lower():gsub("^%.", "")
end

local function domainMatches(host, domain)
    return host == domain or host:sub(-#domain - 1) == "." .. domain
end

local function httpDate(value)
    local day, month, year, hour, minute, second = value:match("(%d%d?)%s+(%a+)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)%s+GMT")
    local months = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
        Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }
    month, day, year = months[month], tonumber(day), tonumber(year)
    hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
    if not month or not year or year < 1601 or not day or day < 1 or day > 31
        or hour > 23 or minute > 59 or second > 59 then return nil end
    local function beforeYear(y)
        y = y - 1
        return y * 365 + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400)
    end
    local days = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 }
    local elapsed = beforeYear(year) - beforeYear(1970) + days[month] + day - 1
    if month > 2 and year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then elapsed = elapsed + 1 end
    return elapsed * 86400 + hour * 3600 + minute * 60 + second
end

function Session.new(fields)
    fields = type(fields) == "table" and fields or {}
    local generation = tonumber(fields.credential_generation)
    generation = generation and generation == generation and generation >= 0 and generation < 9007199254740991
        and math.floor(generation) or 0
    local supplied_domains = type(fields.cookie_domains) == "table" and fields.cookie_domains or {}
    local session = setmetatable({
        cookies = {}, identity = fields.identity, account_key = fields.account_key,
        validated_at = fields.validated_at, imported_at = fields.imported_at or os.time(),
        refresh_token = credential(fields.refresh_token), pending_refresh_token = credential(fields.pending_refresh_token),
        refresh_checked_at = timestamp(fields.refresh_checked_at), last_refreshed_at = timestamp(fields.last_refreshed_at),
        cookie_expires_at = timestamp(fields.cookie_expires_at), cookie_domains = {},
        credential_generation = generation, refresh_blocked = fields.refresh_blocked == true,
        confirmation_blocked = fields.confirmation_blocked == true,
    }, Session)
    for name, value in pairs(type(fields.cookies) == "table" and fields.cookies or {}) do
        if validCookie(name, value) then
            session.cookies[name] = value
            session.cookie_domains[name] = cookieDomain(supplied_domains[name])
        end
    end
    return session
end

function Session.parse(text, opts)
    opts = opts or {}
    if type(text) ~= "string" or #text == 0 or #text > 131072 then
        return nil, Errors.new("invalid_session", "Import a cookie header or a browser cookie export.")
    end
    text = text:gsub("^\239\187\191", "", 1)
    text = trim(text)
    local cookies, domains, expires, refresh_token = {}, {}
    if text:sub(1, 1) == "[" or text:sub(1, 1) == "{" then
        local decoded, err = JSON.decode(text)
        if not decoded then return nil, err end
        if type(decoded) ~= "table" then return nil, Errors.new("invalid_session", "The session export must contain cookies.") end
        refresh_token = credential(decoded.refresh_token)
        if decoded.cookies then decoded = decoded.cookies end
        if type(decoded) ~= "table" then return nil, Errors.new("invalid_session", "The session export must contain cookies.") end
        for key, item in pairs(decoded) do
            if type(item) == "table" and item.name and acceptsDomain(item.domain) then
                if validCookie(item.name, item.value) then
                    cookies[item.name] = item.value
                    domains[item.name] = cookieDomain(item.domain)
                    if item.name == "SESSDATA" then expires = timestamp(item.expirationDate or item.expires) end
                end
            elseif type(key) == "string" and validCookie(key, item) then
                cookies[key] = item
            end
        end
    elseif text:find("\t") then
        for line in text:gmatch("[^\r\n]+") do
            line = line:gsub("^#HttpOnly_", "")
            if line:sub(1, 1) ~= "#" then
                local domain, _, _, _, expiry, name, value = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(.+)$")
                if domain and acceptsDomain(domain) and validCookie(name, value) then
                    cookies[name], domains[name] = value, cookieDomain(domain)
                    if name == "SESSDATA" then expires = timestamp(expiry) end
                end
            end
        end
    else
        text = text:gsub("^[Cc][Oo][Oo][Kk][Ii][Ee]:%s*", "")
        if text:find("[\r\n]") then
            return nil, Errors.new("invalid_session", "A cookie header must be a single line.")
        end
        for entry in text:gmatch("[^;]+") do
            local name, value = trim(entry):match("^([^=]+)=(.*)$")
            if name and allowed[name] then
                if not validCookie(name, value) then
                    return nil, Errors.new("invalid_session", "The cookie header contains an invalid value.")
                end
                if cookies[name] and cookies[name] ~= value then
                    return nil, Errors.new("invalid_session", "The cookie header contains conflicting values.")
                end
                cookies[name] = value
            end
        end
    end
    if not cookies.SESSDATA then
        return nil, Errors.new("authentication", "The imported cookies do not contain a web session.")
    end
    if cookies.DedeUserID and not cookies.DedeUserID:match("^%d+$") then
        return nil, Errors.new("invalid_session", "The imported account identifier is invalid.")
    end
    return Session.new({ cookies = cookies, cookie_domains = domains, cookie_expires_at = expires,
        refresh_token = refresh_token, imported_at = opts.now or os.time() })
end

Session.import = Session.parse

function Session:sameCredentials(other)
    return type(other) == "table" and type(other.cookies) == "table"
        and self.account_key == other.account_key and self.cookies.SESSDATA == other.cookies.SESSDATA
        and self.cookies.bili_jct == other.cookies.bili_jct and self.refresh_token == other.refresh_token
end

function Session:cookieHeader(host)
    if not acceptsDomain(host) or not host then return nil end
    local pairs_list = {}
    for name, value in pairs(self.cookies) do
        local domain = self.cookie_domains[name]
        if (not domain or domainMatches(host, domain)) and (name ~= "XSRF-TOKEN" or host == "manga.bilibili.com") then
            pairs_list[#pairs_list + 1] = name .. "=" .. value
        end
    end
    table.sort(pairs_list)
    return table.concat(pairs_list, "; ")
end

function Session:applySetCookie(headers, host, now)
    if not host or not acceptsDomain(host) then
        return nil, Errors.new("invalid_session", "The cookie response origin is not supported.")
    end
    local lines = {}
    for key, value in pairs(type(headers) == "table" and headers or {}) do
        if type(key) == "string" and key:lower() == "set-cookie" then
            if type(value) == "table" then
                for _, line in ipairs(value) do lines[#lines + 1] = line end
            else lines[#lines + 1] = value end
        end
    end
    local cookies, domains, changes = copy(self.cookies), copy(self.cookie_domains), {}
    local expiry, count = self.cookie_expires_at, 0
    for _, line in ipairs(lines) do
        if type(line) ~= "string" or #line > 131072 or line:find("[%c]") then
            return nil, Errors.new("invalid_session", "The service returned invalid cookie headers.")
        end
        -- LuaSocket joins repeated fields with commas; an Expires date has no name=value after its comma.
        line = line:gsub(",%s*([!#$%%&'*+%.%^_`|~%w%-]+)%s*=", "\n%1=")
        for entry in line:gmatch("[^\n]+") do
            count = count + 1
            if count > 128 then return nil, Errors.new("invalid_session", "The service returned too many cookies.") end
            local name, value, attributes = trim(entry):match("^([^=;%s]+)=([^;]*)(.*)$")
            if name and allowed[name] then
                local domain, path, max_age, expires = host, "/"
                for attribute in attributes:gmatch(";([^;]+)") do
                    local field, data = trim(attribute):match("^([^=]+)=(.*)$")
                    if field then
                        field, data = trim(field):lower(), trim(data)
                        if field == "domain" then domain = cookieDomain(data)
                        elseif field == "path" then path = data
                        elseif field == "max-age" then max_age = tonumber(data)
                        elseif field == "expires" then expires = httpDate(data) end
                    end
                end
                if domain and domainMatches(host, domain) and path == "/" then
                    if value ~= "" and not validCookie(name, value) then
                        return nil, Errors.new("invalid_session", "The service returned an invalid session cookie.")
                    end
                    if max_age and (max_age ~= max_age or math.abs(max_age) == math.huge or max_age % 1 ~= 0) then
                        return nil, Errors.new("invalid_session", "The service returned an invalid cookie lifetime.")
                    end
                    local deadline = max_age and (now or os.time()) + max_age or expires
                    local removed = value == "" or (deadline and deadline <= (now or os.time()))
                    cookies[name], domains[name], changes[name] = not removed and value or nil, not removed and domain or nil, true
                    if name == "SESSDATA" then expiry = not removed and timestamp(deadline) or nil end
                end
            end
        end
    end
    self.cookies, self.cookie_domains, self.cookie_expires_at = cookies, domains, expiry
    return true, nil, changes
end

function Session:withIdentity(identity, now)
    local mid = identity and tostring(identity.id or identity.mid or "")
    if not mid or not mid:match("^[1-9]%d*$") or identity.isLogin == false then
        return nil, Errors.new("authentication", "The service did not confirm a logged-in account.")
    end
    if self.cookies.DedeUserID and self.cookies.DedeUserID ~= mid then
        return nil, Errors.new("account_mismatch", "The imported session belongs to a different account identifier.")
    end
    self.identity = { id = mid, name = identity.name or identity.uname or "", avatar = identity.avatar or identity.face }
    self.account_key = "bili_" .. mid
    self.validated_at = now or os.time()
    return self
end

function Session:serialize()
    return {
        schema_version = 2, cookies = self.cookies, cookie_domains = self.cookie_domains, identity = self.identity,
        account_key = self.account_key, imported_at = self.imported_at, validated_at = self.validated_at,
        refresh_token = self.refresh_token, pending_refresh_token = self.pending_refresh_token,
        refresh_checked_at = self.refresh_checked_at, last_refreshed_at = self.last_refreshed_at,
        cookie_expires_at = self.cookie_expires_at, credential_generation = self.credential_generation,
        refresh_blocked = self.refresh_blocked,
        confirmation_blocked = self.confirmation_blocked,
    }
end

function Session:summary()
    return { identity = self.identity, account_key = self.account_key, validated_at = self.validated_at,
        imported_at = self.imported_at, has_session = self.cookies.SESSDATA ~= nil,
        renewable = self.refresh_token ~= nil and not self.refresh_blocked and not self.confirmation_blocked,
        cookie_expires_at = self.cookie_expires_at,
        last_refreshed_at = self.last_refreshed_at }
end

function Session:save(path)
    if not self.account_key or not self.validated_at then
        return nil, Errors.new("authentication", "Validate the account before saving its session.")
    end
    local payload, err = JSON.encode(self:serialize())
    if not payload then return nil, err end
    local ffi = require("ffi")
    require("ffi/posix_h")
    ffi.cdef[[int fchmod(int fd, unsigned int mode);]]
    local bit = require("bit")
    local C = ffi.C
    -- O_EXCL is 128 on the Linux and Android targets used by KOReader.
    if ffi.os ~= "Linux" then return nil, Errors.capability("private_session_storage") end
    local temporary = path .. ".new-" .. tostring(os.time()) .. "-" .. tostring(C.getpid())
    local fd = C.open(temporary, bit.bor(C.O_WRONLY, C.O_CREAT, 128), ffi.cast("unsigned int", 384))
    if fd < 0 then return nil, Errors.new("storage", "A private session file could not be created.") end
    local success = C.fchmod(fd, 384) == 0
    local written = 0
    while success and written < #payload do
        local n = tonumber(C.write(fd, payload:sub(written + 1), #payload - written))
        if n <= 0 then success = false else written = written + n end
    end
    if success then success = C.fsync(fd) == 0 end
    C.close(fd)
    if not success then os.remove(temporary); return nil, Errors.new("storage", "The session could not be saved safely.") end
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return nil, Errors.new("storage", "The saved session could not be replaced.")
    end
    return true
end

function Session.load(path)
    local file = io.open(path, "rb")
    if not file then return nil, Errors.new("authentication", "No saved session is available.") end
    local text = file:read(131073)
    file:close()
    if not text or #text > 131072 then return nil, Errors.new("invalid_session", "The saved session is invalid.") end
    local decoded, err = JSON.decode(text)
    if not decoded then return nil, err end
    if type(decoded) ~= "table" or (decoded.schema_version ~= 1 and decoded.schema_version ~= 2) or type(decoded.cookies) ~= "table" then
        return nil, Errors.new("invalid_session", "The saved session format is unsupported.")
    end
    local session = Session.new(decoded)
    if not session.cookies.SESSDATA then return nil, Errors.new("authentication", "The saved session is empty.") end
    local identity_id = type(session.identity) == "table" and tostring(session.identity.id or "")
    local expected = identity_id and identity_id:match("^[1-9]%d*$") and "bili_" .. identity_id
    if not expected or expected ~= session.account_key then
        return nil, Errors.new("invalid_session", "The saved session identity is inconsistent.")
    end
    if session.cookies.DedeUserID and session.cookies.DedeUserID ~= identity_id then
        return nil, Errors.new("account_mismatch", "The saved session contains conflicting account identities.")
    end
    return session
end

return Session
