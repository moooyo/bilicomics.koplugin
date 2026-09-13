local Errors = require("bilicomics/protocol/errors")
local Session = require("bilicomics/protocol/session")

local SiteContext = { url = "https://manga.bilibili.com/ductape/buvid", host = "manga.bilibili.com" }

local function valid(value)
    return type(value) == "string" and #value > 0 and #value <= 256 and value:match("^[%w_-]+$") ~= nil
end

function SiteContext.hasDevice(session)
    if type(session) ~= "table" or type(session.cookies) ~= "table" or not valid(session.cookies.buvid3) then return false end
    local domain = type(session.cookie_domains) == "table" and session.cookie_domains.buvid3
    return not domain or domain == "bilibili.com" or domain == SiteContext.host
end

function SiteContext.needed(session)
    return type(session) == "table" and type(session.cookies) == "table"
        and type(session.cookies.SESSDATA) == "string" and session.cookies.SESSDATA ~= "" and not SiteContext.hasDevice(session)
end

local function invalid()
    return nil, Errors.new("protocol", "The official site did not provide a valid manga device context.", { retryable = false })
end

function SiteContext.parse(headers, now)
    local selected, seen, count = {}, nil, 0
    for key, lines in pairs(type(headers) == "table" and headers or {}) do
        if type(key) == "string" and key:lower() == "set-cookie" then
            if type(lines) == "string" then lines = { lines } end
            if type(lines) ~= "table" then return invalid() end
            for _, line in ipairs(lines) do
                if type(line) ~= "string" or #line > 131072 or line:find("[%c]") then return invalid() end
                -- Preserve Expires commas while splitting LuaSocket's repeated-header representation.
                line = line:gsub(",%s*([!#$%%&'*+%.%^_`|~%w%-]+)%s*=", "\n%1=")
                for entry in line:gmatch("[^\n]+") do
                    count = count + 1
                    if count > 128 then return invalid() end
                    local name, value = entry:match("^%s*([^=;%s]+)=([^;]*)")
                    if name == "buvid3" then
                        if not valid(value) or seen and seen ~= value then return invalid() end
                        seen = value
                        selected[#selected + 1] = entry
                    end
                end
            end
        end
    end
    if not seen then return invalid() end
    -- Never apply unrelated response cookies to a login or renewal candidate.
    local scratch = Session.new({ imported_at = now })
    local ok = scratch:applySetCookie({ ["set-cookie"] = selected }, SiteContext.host, now)
    if not ok or not SiteContext.hasDevice(scratch) then return invalid() end
    return { value = scratch.cookies.buvid3, domain = scratch.cookie_domains.buvid3 }
end

function SiteContext.ensure(session, transport, clock)
    if type(session) ~= "table" or type(session.serialize) ~= "function" then
        return nil, Errors.new("invalid_session", "A valid session candidate is required for site initialization.", { transmitted = false })
    end
    local candidate = Session.new(session:serialize())
    if SiteContext.hasDevice(candidate) then return candidate end
    local response, err = transport:request({ url = SiteContext.url, method = "GET", max_bytes = 65536,
        headers = { ["user-agent"] = "Mozilla/5.0 (X11; Linux) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36",
            accept = "application/json", referer = "https://manga.bilibili.com/" } })
    if not response then return nil, err or Errors.new("network", "The manga site initialization did not complete.", { retryable = true }) end
    if type(response) ~= "table" or type(response.status) ~= "number" then return invalid() end
    if response.status ~= 200 then
        return nil, Errors.new("http", "The manga site initialization did not complete.", {
            status = response.status, retryable = response.status == 429 or response.status >= 500,
            transmitted = response.transmitted,
        })
    end
    local cookie
    cookie, err = SiteContext.parse(response.headers, (clock or os.time)())
    if not cookie then return nil, err end
    candidate.cookies.buvid3, candidate.cookie_domains.buvid3 = cookie.value, cookie.domain
    return candidate
end

local function equal(first, second, depth)
    if type(first) ~= type(second) then return false end
    if type(first) ~= "table" then return first == second end
    if depth > 8 then return false end
    for key, value in pairs(first) do if not equal(value, second[key], depth + 1) then return false end end
    for key in pairs(second) do if first[key] == nil then return false end end
    return true
end

function SiteContext.preservesSession(before, after)
    if not before or not after or not SiteContext.hasDevice(after) then return false end
    local first, second = Session.new(before:serialize()), Session.new(after:serialize())
    first.cookies.buvid3, second.cookies.buvid3 = nil, nil
    first.cookie_domains.buvid3, second.cookie_domains.buvid3 = nil, nil
    return equal(first:serialize(), second:serialize(), 0)
end

return SiteContext
