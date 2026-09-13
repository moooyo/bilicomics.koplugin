local Errors = require("bilicomics/protocol/errors")

local Transport = {}
Transport.__index = Transport

local function matchesHost(pattern, host)
    pattern, host = pattern:lower(), host:lower()
    if pattern:find("\000", 1, true) then return false end
    if pattern == host then return true end
    if pattern:sub(1, 2) == "*." and not pattern:sub(3):find("*", 1, true) then
        local first_dot = host:find(".", 1, true)
        return first_dot ~= nil and host:sub(first_dot + 1) == pattern:sub(3)
    end
    return false
end

local function verifiesHost(certificate, host)
    if not certificate then return false end
    local extensions = certificate:extensions() or {}
    local san = extensions["2.5.29.17"]
    if san then
        for _, name in ipairs(san.dNSName or {}) do
            if matchesHost(name, host) then return true end
        end
        return false
    end
    for _, attribute in ipairs(certificate:subject() or {}) do
        if attribute.oid == "2.5.4.3" and matchesHost(attribute.value, host) then return true end
    end
    return false
end

function Transport.new(opts)
    opts = opts or {}
    return setmetatable({
        ca_file = opts.ca_file or "data/ca-bundle.crt",
        timeout = opts.timeout or 15,
        total_timeout = opts.total_timeout or 60,
        max_json_bytes = opts.max_json_bytes or 8 * 1024 * 1024,
        max_image_bytes = opts.max_image_bytes or 64 * 1024 * 1024,
        clock = opts.clock or os.time,
    }, Transport)
end

-- This is deliberately synchronous and may only run in an acquisition worker.
function Transport:request(request)
    local http = require("socket.http")
    local socket = require("socket")
    local ssl = require("ssl")
    local ltn12 = require("ltn12")
    if http.PROXY then
        return nil, Errors.capability("direct_tls", "This client requires a direct verified TLS connection.")
    end
    local parse = require("socket.url").parse
    local parsed = parse(request.url or "")
    if not parsed or parsed.scheme ~= "https" or not parsed.host or parsed.user or parsed.password
        or (parsed.port and tostring(parsed.port) ~= "443") then
        return nil, Errors.new("invalid_request", "Only a direct HTTPS resource is supported.", { transmitted = false })
    end
    if parsed.host:find("[^%w%.%-]") then
        return nil, Errors.new("invalid_request", "The resource host is invalid.", { transmitted = false })
    end
    local limit = request.max_bytes or (request.output_path and self.max_image_bytes or self.max_json_bytes)
    local parts, count, sink_failure = {}, 0, nil
    local file
    if request.output_path then
        file = io.open(request.output_path, "wb")
        if not file then return nil, Errors.new("storage", "The download file could not be created.", { transmitted = false }) end
    end
    local started = self.clock()
    local function sink(chunk)
        if not chunk then return 1 end
        count = count + #chunk
        if count > limit then sink_failure = "response_size"; return nil, "response limit" end
        if self.clock() - started > (request.total_timeout or self.total_timeout) then
            sink_failure = "timeout"; return nil, "total timeout"
        end
        if file then
            if not file:write(chunk) then sink_failure = "storage"; return nil, "write failed" end
        else parts[#parts + 1] = chunk end
        return 1
    end
    local transmitted = false
    local timeout = request.timeout or self.timeout
    local ca_file = request.ca_file or self.ca_file
    local function create()
        local connection = { sock = assert(socket.tcp()) }
        function connection:settimeout()
            return self.sock:settimeout(timeout)
        end
        function connection:connect(host, port)
            self.sock:settimeout(timeout)
            local ok, err = self.sock:connect(host, port)
            if not ok then self.sock:close(); return nil, err end
            local wrapped, wrap_err = ssl.wrap(self.sock, {
                mode = "client", protocol = "any", verify = "peer",
                options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
                cafile = ca_file,
            })
            if not wrapped then self.sock:close(); return nil, wrap_err end
            self.sock = wrapped
            self.sock:sni(host)
            self.sock:settimeout(timeout)
            ok, err = self.sock:dohandshake()
            if not ok then self.sock:close(); return nil, err end
            if not verifiesHost(self.sock:getpeercertificate(), host) then
                self.sock:close()
                return nil, "certificate hostname mismatch"
            end
            return 1
        end
        function connection:send(...)
            -- Once any request bytes may have left this process, a lost purchase response is uncertain.
            transmitted = true
            return self.sock:send(...)
        end
        function connection:receive(...) return self.sock:receive(...) end
        function connection:close(...) return self.sock:close(...) end
        function connection:getfd(...) return self.sock:getfd(...) end
        function connection:dirty(...) return self.sock:dirty(...) end
        return connection
    end
    local headers = {}
    for key, value in pairs(request.headers or {}) do headers[key] = value end
    headers["accept-encoding"] = "identity"
    if request.body then headers["content-length"] = tostring(#request.body) end
    -- Avoid LuaSec's default verify=none and its missing hostname verification.
    local ok, result, code, response_headers = pcall(http.request, {
        url = request.url, method = request.method or "GET", headers = headers,
        source = request.body and ltn12.source.string(request.body) or nil,
        sink = sink, create = create, redirect = false,
    })
    if file then
        local closed = file:close()
        if not closed then sink_failure = "storage" end
    end
    if not ok or not result or sink_failure then
        if request.output_path then os.remove(request.output_path) end
        local kind = sink_failure or (tostring(code):find("timeout", 1, true) and "timeout" or "network")
        return nil, Errors.new(kind, kind == "storage" and "The download could not be written." or "The secure request did not complete.", {
            retryable = kind == "timeout" or kind == "network", transmitted = transmitted,
        })
    end
    return { status = tonumber(code), headers = response_headers or {},
        body = not request.output_path and table.concat(parts) or nil,
        path = request.output_path, bytes = count, transmitted = transmitted }
end

Transport.matchesHost = matchesHost
Transport.verifiesHost = verifiesHost

return Transport
