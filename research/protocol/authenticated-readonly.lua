-- Run only on test-env with the user's explicit session authorization.
-- The current task prohibits purchase testing, including quotation in this probe.
-- Keep input, raw captures, images and process logs in a private remote directory.
local root, session_path, output = assert(arg[1]), assert(arg[2]), assert(arg[3])
local mode = arg[4] or "metadata"
local page_limit = tonumber(arg[5]) or 1
local start_page = tonumber(arg[6]) or 1
local sample_access = arg[7] or "both"
local image_agent_override = arg[8] == "standard-agent"
local image_code_comparison = arg[8] == "official-code"
local diagnostic_code_active = false
assert(mode == "metadata" or mode == "images" or mode == "prepare", "Unsupported read-only probe mode")
assert(page_limit >= 1 and page_limit <= 3 and page_limit % 1 == 0, "The probe samples at most three pages per episode")
assert(start_page >= 1 and start_page <= 64 and start_page % 1 == 0, "Unsupported sample page")
assert(sample_access == "both" or sample_access == "free" or sample_access == "owned", "Unsupported access sample")
assert(arg[8] == nil or image_agent_override or image_code_comparison, "Unsupported diagnostic override")
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local Client = require("bilicomics/protocol/client")
local Errors = require("bilicomics/protocol/errors")
local JSON = require("bilicomics/protocol/json")
local Session = require("bilicomics/protocol/session")
local Transport = require("bilicomics/protocol/transport")

local routes = {
    ["/x/web-interface/nav"] = { host = "api.bilibili.com", method = "GET" },
    ["/twirp/bookshelf.v1.Bookshelf/ListFavorite"] = { host = "manga.bilibili.com", method = "POST",
        keys = { page_num = true, page_size = true, order = true, wait_free = true, time_limit_free = true,
            type = true, from = true, source = true } },
    ["/twirp/bookshelf.v1.Bookshelf/ListHistory"] = { host = "manga.bilibili.com", method = "POST",
        keys = { page_num = true, page_size = true, type = true } },
    ["/twirp/comic.v1.Comic/ComicDetail"] = { host = "manga.bilibili.com", method = "POST",
        keys = { comic_id = true, m2 = true } },
    ["/twirp/comic.v1.Comic/GetImageIndex"] = { host = "manga.bilibili.com", method = "POST",
        keys = { ep_id = true, m2 = true } },
    ["/twirp/comic.v1.Comic/ImageToken"] = { host = "manga.bilibili.com", method = "POST",
        keys = { urls = true, m1 = true } },
}
local report = { probe = "authorized-reading-only", mode = mode, page_limit = page_limit, start_page = start_page,
    diagnostic_image_agent_override = image_agent_override, diagnostic_official_code_comparison = image_code_comparison,
    requests = {}, session_validated = false,
    library = {}, catalogs = {}, images = {}, errors = {}, blocked_requests = 0,
    purchase_testing = false, quote_testing = false, wallet_testing = false }
local approved_episodes, approved_paths = {}, {}
local query_keys = { device = true, platform = true, nov = true, a = true,
    ultra_sign = true, cpx = true, m1 = true }
local http = Transport.new({ total_timeout = 40 })
local standard_agent = Client.new():_headers("manga.bilibili.com")["user-agent"]
local guarded = {}
local stage = "initialize"
local function publicError(err)
    if type(err) ~= "table" then return { kind = "unclassified" } end
    local kind = type(err.kind) == "string" and err.kind:match("^[%w_]+$") and #err.kind <= 64 and err.kind or "unclassified"
    return { kind = kind, code = type(err.code) == "number" and err.code or nil,
        status = type(err.status) == "number" and err.status or nil, retryable = err.retryable == true }
end
local function blocked()
    report.blocked_requests = report.blocked_requests + 1
    return nil, Errors.new("verification_guard", "This request is outside the authorized reading-only scope.", { transmitted = false })
end
function guarded:request(request)
    if #report.requests >= 45 then return blocked() end
    local host, path = (request.url or ""):match("^https://([^/?#]+)(/[^?#]*)")
    local route = path and routes[path]
    if route then
        if host ~= route.host or request.method ~= route.method then return blocked() end
        local query, seen_keys = (request.url or ""):match("%?([^#]*)"), {}
        if request.url:find("#", 1, true) then return blocked() end
        for pair in (query or ""):gmatch("[^&]+") do
            local key = pair:match("^([^=]+)=")
            if not key or not query_keys[key] or seen_keys[key] then return blocked() end
            seen_keys[key] = true
        end
        if route.method == "GET" and query then return blocked() end
        local body
        if route.keys then
            body = request.body and JSON.decode(request.body)
            if type(body) ~= "table" then return blocked() end
            for key in pairs(body) do if not route.keys[key] then return blocked() end end
        elseif request.body then return blocked() end
        if path == "/twirp/comic.v1.Comic/GetImageIndex" then
            if (mode ~= "images" and mode ~= "prepare") or not approved_episodes[tostring(body.ep_id)] then return blocked() end
        elseif path == "/twirp/comic.v1.Comic/ImageToken" then
            local paths = type(body.urls) == "string" and JSON.decode(body.urls)
            if mode ~= "images" or type(paths) ~= "table" or #paths ~= 1 or not approved_paths[paths[1]] then return blocked() end
        end
    else
        if not host or not (host:match("%.hdslb%.com$") or host:match("%.biliimg%.com$"))
            or request.method ~= "GET" or request.body then return blocked() end
        for key in pairs(request.headers or {}) do
            local lower = tostring(key):lower()
            if lower == "cookie" or lower == "authorization" or lower == "proxy-authorization" or lower == "x-xsrf-token" then return blocked() end
        end
    end
    if request.output_path and (request.output_path:sub(1, #output + 1) ~= output .. "/"
        or request.output_path:find("/../", 1, true) or request.output_path:find("\\", 1, true)) then return blocked() end
    local audit = { path = route and path or "[anonymous CDN resource]", method = request.method }
    report.requests[#report.requests + 1] = audit
    if not route then
        audit.explicit_user_agent = request.headers and request.headers["user-agent"] ~= nil
        if image_agent_override and (request.headers or {}).accept == "application/octet-stream,image/*" then
            local original = request
            request = {}
            for key, value in pairs(original) do request[key] = value end
            request.headers = {}
            for key, value in pairs(original.headers or {}) do request.headers[key] = value end
            request.headers["user-agent"] = standard_agent
            audit.diagnostic_agent_added = true
        end
        if diagnostic_code_active and (request.headers or {}).accept == "application/octet-stream,image/*" then
            local original = request
            request = {}
            for key, value in pairs(original) do request[key] = value end
            request.url = original.url .. (original.url:find("?", 1, true) and "&" or "?") .. "code=DanmakuInfo"
            audit.diagnostic_official_code_added = true
        end
    end
    local response, err = http:request(request)
    audit.status = response and response.status
    if not route and response then
        for key, value in pairs(response.headers or {}) do
            if tostring(key):lower() == "content-type" and type(value) == "string" then
                audit.content_type = value:match("^([%w%+%.%-]+/[%w%+%.%-]+)")
            end
        end
    end
    if not route and response and response.status == 200 and request.output_path
        and (request.headers or {}).accept == "application/octet-stream,image/*" then
        local source = io.open(request.output_path, "rb")
        if source then
            local wire = source:read(16 * 1024 * 1024 + 1); source:close()
            if wire and #wire <= 16 * 1024 * 1024 then
                audit.container_first_byte = wire:byte(1)
                audit.container_bytes = #wire
                audit.jpeg_magic = wire:sub(1, 2) == "\255\216"
                audit.png_magic = wire:sub(1, 8) == "\137PNG\r\n\026\n"
                if image_code_comparison then
                    local capture = assert(io.open(output .. "/image-wire-private.bin", "wb"))
                    capture:write(wire); capture:close()
                end
            end
        end
    end
    if not route and response and response.status ~= 200 and request.output_path then
        local source = io.open(request.output_path, "rb")
        if source then
            local body = source:read(8192); source:close()
            local capture = assert(io.open(output .. "/http-error-" .. #report.requests .. "-private.bin", "wb"))
            capture:write(body or ""); capture:close()
            audit.private_error_capture = true
        end
    end
    if not response then audit.error = publicError(err) end
    return response, err
end
local function save()
    local file = assert(io.open(output .. "/authenticated-readonly-result.json", "wb"))
    assert(file:write(assert(JSON.encode(report))))
    assert(file:close())
    print(assert(JSON.encode(report)))
end
local function trueValue(value) return value == true or value == 1 or value == "1" end
local function falseValue(value) return value == false or value == 0 or value == "0" end
local function eligible(episode)
    local raw = episode.extra or {}
    if not falseValue(raw.is_locked) or not falseValue(raw.is_in_free)
        or trueValue(raw.unavailable) or falseValue(raw.is_available) or tonumber(raw.status) == 501 then return nil end
    if tonumber(raw.unlock_type) ~= 0 and tonumber(raw.unlock_type) ~= 1 then return nil end
    for _, value in ipairs({ raw.unlock_expire_at or 0, raw.expires_at or 0 }) do
        if value ~= "" and value ~= "0000-00-00 00:00:00" and (not tonumber(value) or tonumber(value) ~= 0) then return nil end
    end
    if episode.access == "free" and tonumber(raw.pay_mode) == 0 and tonumber(raw.unlock_type) == 0
        and not trueValue(raw.is_purchased) then return "free" end
    if episode.access == "owned" and tonumber(raw.pay_mode) == 1 and tonumber(raw.unlock_type) == 1 then return "owned" end
end
local access_keys = { "pay_mode", "unlock_type", "is_purchased", "is_locked", "is_in_free",
    "unlock_expire_at", "expires_at", "unavailable", "is_available", "status" }
local function main()
    stage = "session_import"
    local input = assert(io.open(session_path, "rb"))
    local text = input:read(131073); input:close()
    local session, err = Session.parse(text); text = nil
    if not session then report.errors.import = publicError(err); return end
    local client = Client.new({ session = session, transport = guarded, asset_root = output .. "/assets" })
    stage = "session_validation"
    local identity
    identity, err = client:validateSession()
    if not identity then report.errors.session = publicError(err); return end
    report.session_validated = true
    local ids, seen = {}, {}
    local function addID(value)
        local id = tostring(value or "")
        if #ids < 8 and id:match("^[1-9]%d*$") and #id <= 15 and not seen[id] then
            seen[id] = true; ids[#ids + 1] = id
        end
    end
    stage = "library"
    for _, operation in ipairs({ { "favorites", "listFavorites" }, { "history", "listHistory" } }) do
        local items
        items, err = client[operation[2]](client, { page_num = 1, page_size = 20 })
        report.library[operation[1]] = { received = items ~= nil, count = items and #items or nil }
        if not items then report.library[operation[1]].error = publicError(err)
        else for _, comic in ipairs(items) do addID(comic.id) end end
    end
    if #ids == 0 then addID("36215") end
    local selected = {}
    stage = "catalog"
    for number, id in ipairs(ids) do
        local detail
        detail, err = client:comicDetail(id)
        local entry = { alias = "comic_" .. number, received = detail ~= nil }
        report.catalogs[#report.catalogs + 1] = entry
        if not detail then
            entry.error = publicError(err)
            -- Do not repeat an unclassified protected-protocol rejection across a library.
            if err and (err.kind == "authentication" or err.kind == "business" or err.kind == "capability" or err.kind == "crypto") then break end
        else
            entry.episode_count, entry.access_counts, entry.access_fields = #detail.episodes, {}, {}
            for _, episode in ipairs(detail.episodes) do
                local access = episode.access or "unknown"
                entry.access_counts[access] = (entry.access_counts[access] or 0) + 1
                for _, key in ipairs(access_keys) do
                    if (episode.extra or {})[key] ~= nil then entry.access_fields[key] = true end
                end
                local kind = eligible(episode)
                if kind and not selected[kind] then
                    selected[kind] = { episode = episode, alias = entry.alias,
                        comic_id = detail.comic.id, cover_url = detail.comic.cover_url }
                end
            end
            -- Preserve private input evidence for debugging, outside the repository/report.
            local raw = assert(io.open(output .. "/" .. entry.alias .. "-private-detail.json", "wb"))
            raw:write(assert(JSON.encode(detail))); raw:close()
            if selected.free and selected.owned then break end
        end
    end
    if mode == "prepare" then
        local candidate = selected.free
        if not candidate then report.errors.selection = { kind = "no_eligible_free_chapter" }; return end
        approved_episodes[tostring(candidate.episode.id)] = true
        stage = "prepare_complete_chapter"
        local index
        index, err = client:imageIndex(candidate.episode.id)
        if not index then report.errors.selection = publicError(err); return end
        if #index.images < 6 or #index.images > 64 then
            report.errors.selection = { kind = "chapter_outside_probe_bounds" }; return
        end
        local paths, pixels = {}, 0
        for number, page in ipairs(index.images) do
            paths[number] = page.path
            pixels = pixels + page.width * page.height
        end
        local selection = { comic_id = candidate.comic_id, episode_id = candidate.episode.id,
            approved_source_paths = paths, approved_cover_url = candidate.cover_url,
            access = "free", page_count = #paths, revision = index.revision }
        local file = assert(io.open(output .. "/selection-private.json", "wb"))
        file:write(assert(JSON.encode(selection))); file:close()
        report.prepared_chapter = { access = "free", page_count = #paths, total_source_pixels = pixels }
    end
    for _, access in ipairs(sample_access == "both" and { "free", "owned" } or { sample_access }) do
        local candidate = selected[access]
        report.images[access] = { eligible = candidate ~= nil, acquired = false }
        if candidate and mode == "images" then
            local episode = candidate.episode
            approved_episodes[tostring(episode.id)] = true
            stage = "index_" .. access
            local index
            index, err = client:imageIndex(episode.id)
            report.images[access].catalog_alias = candidate.alias
            report.images[access].index_received = index ~= nil
            if index then
                report.images[access].page_count = #index.images
                local index_file = assert(io.open(output .. "/index-" .. access .. "-private.json", "wb"))
                index_file:write(assert(JSON.encode(index))); index_file:close()
                report.images[access].pages = {}
                for page_number = start_page, math.min(start_page + page_limit - 1, #index.images) do
                    local page = index.images[page_number]
                    local result = { index = page_number, acquired = false }
                    report.images[access].pages[#report.images[access].pages + 1] = result
                    approved_paths[page.path] = true
                    stage = "token_" .. access .. "_" .. page_number
                    local tokens
                    tokens, err = client:imageTokens({ page.path }, { index = page_number })
                    result.token_received = tokens ~= nil
                    if tokens then
                        stage = "image_" .. access .. "_" .. page_number
                        local image
                        local suffix = page_number == 1 and "" or "-" .. page_number
                        local complete_url = tokens[1].complete_url
                        result.uses_complete_url = type(complete_url) == "string" and complete_url ~= ""
                        result.complete_url_https = result.uses_complete_url and complete_url:match("^https://") ~= nil
                        result.query_fields = {}
                        for pair in ((complete_url or ""):match("%?([^#]*)") or ""):gmatch("[^&]+") do
                            local key = pair:match("^([^=]+)=")
                            if key and #key <= 32 and key:match("^[%w_]+$") then result.query_fields[key] = true end
                        end
                        if image_code_comparison and trueValue(tokens[1].hit_encrpyt) then
                            local context = assert(io.open(output .. "/image-context-private.json", "wb"))
                            context:write(assert(JSON.encode({ private_key = client._token_context.private_key,
                                url = complete_url, index = page_number }))); context:close()
                            local baseline, baseline_error = client:downloadImage(tokens[1],
                                output .. "/image-" .. access .. suffix .. "-baseline.part",
                                { index = page_number, max_bytes = 16 * 1024 * 1024, max_pixels = 32000000, total_timeout = 40 })
                            result.same_token_baseline = { acquired = baseline ~= nil,
                                error = baseline_error and publicError(baseline_error) or nil }
                            diagnostic_code_active = true
                        end
                        image, err = client:downloadImage(tokens[1], output .. "/image-" .. access .. suffix .. ".part",
                            { index = page_number, max_bytes = 16 * 1024 * 1024, max_pixels = 32000000, total_timeout = 40 })
                        diagnostic_code_active = false
                        result.encrypted = trueValue(tokens[1].hit_encrpyt)
                        if image then
                            result.acquired = true
                            result.format, result.bytes = image.format, image.bytes
                            result.width, result.height = image.width, image.height
                            result.verification = image.verification
                            local native_limit = image.format == "jpg" and 32000000 or 4000000
                            result.within_native_pixel_budget = image.width * image.height <= native_limit
                        end
                    end
                    if err then result.error = publicError(err) end
                    if page_number == start_page then
                        for key, value in pairs(result) do report.images[access][key] = value end
                    end
                    -- Stop a failed acquisition rather than retrying a protected operation blindly.
                    if not result.acquired then break end
                end
            end
            if err then report.images[access].error = publicError(err) end
        end
    end
    stage = "complete"
end
local ok = pcall(main)
if not ok then report.errors.probe = { kind = "internal", stage = stage } end
report.finished_stage = stage
report.completed_without_exception = ok
save()
