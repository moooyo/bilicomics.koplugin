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
end

function Session.new(fields)
    fields = type(fields) == "table" and fields or {}
    local session = setmetatable({
        cookies = {}, identity = fields.identity, account_key = fields.account_key,
        validated_at = fields.validated_at, imported_at = fields.imported_at or os.time(),
    }, Session)
    for name, value in pairs(type(fields.cookies) == "table" and fields.cookies or {}) do
        if validCookie(name, value) then session.cookies[name] = value end
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
    local cookies = {}
    if text:sub(1, 1) == "[" or text:sub(1, 1) == "{" then
        local decoded, err = JSON.decode(text)
        if not decoded then return nil, err end
        if decoded.cookies then decoded = decoded.cookies end
        for key, item in pairs(decoded) do
            if type(item) == "table" and item.name and acceptsDomain(item.domain) then
                if validCookie(item.name, item.value) then cookies[item.name] = item.value end
            elseif type(key) == "string" and validCookie(key, item) then
                cookies[key] = item
            end
        end
    elseif text:find("\t") then
        for line in text:gmatch("[^\r\n]+") do
            line = line:gsub("^#HttpOnly_", "")
            if line:sub(1, 1) ~= "#" then
                local domain, _, _, _, _, name, value = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(.+)$")
                if domain and acceptsDomain(domain) and validCookie(name, value) then cookies[name] = value end
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
    return Session.new({ cookies = cookies, imported_at = opts.now or os.time() })
end

Session.import = Session.parse

function Session:cookieHeader(host)
    if not acceptsDomain(host) or not host then return nil end
    local pairs_list = {}
    for name, value in pairs(self.cookies) do pairs_list[#pairs_list + 1] = name .. "=" .. value end
    table.sort(pairs_list)
    return table.concat(pairs_list, "; ")
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
        schema_version = 1, cookies = self.cookies, identity = self.identity,
        account_key = self.account_key, imported_at = self.imported_at, validated_at = self.validated_at,
    }
end

function Session:summary()
    return { identity = self.identity, account_key = self.account_key, validated_at = self.validated_at,
        imported_at = self.imported_at, has_session = self.cookies.SESSDATA ~= nil }
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
    if decoded.schema_version ~= 1 or type(decoded.cookies) ~= "table" then
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
