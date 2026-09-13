local Client = require("bilicomics/protocol/client")
local Header = require("bilicomics/storage/image_header")
local ImagePolicy = require("bilicomics/image_policy")
local Util = require("bilicomics/util")
local Budget = require("bilicomics/jobs/storage_budget")
local Worker = {}
local reads = { listFavorites = true, listHistory = true, recommendations = true, search = true, comicDetail = true,
    bookstoreCategories = true, bookstoreCategoryPage = true,
    imageIndex = true, wallet = true, purchaseInfo = true, validateSession = true }
local unpack = unpack or table.unpack

local function referenceChanged()
    return nil, Util.error("reference_changed", "The cached reference page changed or failed verification.")
end

local function hashReference(reference, expected, maximum, refresh)
    local before, err = refresh.fileIdentity(reference.path, reference.root)
    if not before then return nil, err end
    if not refresh.sameFileIdentity(before, reference.identity) then return referenceChanged() end
    if before.size <= 0 or before.size > maximum then
        return nil, Util.error("image_size", "The cached reference exceeds the image verification byte limit.")
    end
    local ffi, bit = require("ffi"), require("bit")
    local lfs = require("libs/libkoreader-lfs")
    require("ffi/posix_h")
    local nofollow = ffi.arch == "arm" and 32768 or 131072
    local fd = ffi.C.open(reference.path, bit.bor(ffi.C.O_RDONLY, ffi.C.O_CLOEXEC, ffi.C.O_NONBLOCK, nofollow))
    if fd < 0 then return nil, Util.error("storage", "The cached reference could not be opened safely.") end
    local ok, identity, failure = pcall(function()
        local function openedIdentity()
            local stat = lfs.attributes("/proc/self/fd/" .. fd)
            if not stat or stat.mode ~= "file" then return nil end
            return { dev = stat.dev, ino = stat.ino, size = stat.size,
                modification = stat.modification, change = stat.change }
        end
        if not refresh.sameFileIdentity(before, openedIdentity()) then return referenceChanged() end
        local update, size = require("ffi/sha2").sha256(), 0
        local buffer = ffi.new("uint8_t[65536]")
        while size <= maximum do
            local count = tonumber(ffi.C.read(fd, buffer, math.min(65536, maximum + 1 - size)))
            if count < 0 then return nil, Util.error("storage", "The cached reference could not be read.") end
            if count == 0 then break end
            size = size + count
            if size > maximum then return nil, Util.error("image_size", "The cached reference exceeds the image verification byte limit.") end
            update(ffi.string(buffer, count))
        end
        local after = refresh.fileIdentity(reference.path, reference.root)
        if size ~= before.size or not refresh.sameFileIdentity(before, openedIdentity())
            or not refresh.sameFileIdentity(before, after) or update() ~= expected then
            return referenceChanged()
        end
        return before
    end)
    ffi.C.close(fd)
    if not ok then return nil, Util.error("storage", "The cached reference could not be verified safely.") end
    return identity, failure
end

local function prepareSourceVerification(request)
    local expected = request.expected_checksum
    if type(expected) ~= "string" or #expected ~= 64 or expected:find("[^0-9a-f]") then
        return nil, Util.error("invalid_request", "A canonical SHA-256 checksum is required for source verification.")
    end
    if type(request.source_path) ~= "string" or request.source_path == "" or #request.source_path > 8192 then
        return nil, Util.error("invalid_request", "A bounded source locator is required for source verification.")
    end
    local maximum = request.max_bytes or Budget.default_image_limit
    if type(maximum) ~= "number" or maximum < 1 or maximum > Budget.default_image_limit or maximum % 1 ~= 0 then
        return nil, Util.error("invalid_request", "The source verification byte limit is invalid.")
    end
    local path, root = request.temporary_path, request.temporary_root
    if type(path) ~= "string" or type(root) ~= "string" or root:sub(1, 1) ~= "/"
        or root:find("[%c]") or path:find("[%c]") or not path:match("%.part$") then
        return nil, Util.error("invalid_request", "A contained temporary candidate path is required.")
    end
    local Files = require("bilicomics/storage/files")
    local lfs = require("libs/libkoreader-lfs")
    local ancestor = ""
    for component in root:gmatch("[^/]+") do
        ancestor = ancestor .. "/" .. component
        if component == "." or component == ".." or lfs.symlinkattributes(ancestor, "mode") ~= "directory" then
            return nil, Util.error("invalid_request", "The temporary storage root must contain existing directories without symbolic links.")
        end
    end
    if not pcall(Files.assertContained, path, root) then
        return nil, Util.error("invalid_request", "The candidate must remain inside its temporary storage root.")
    end
    local refresh = require("bilicomics/storage/source_refresh")
    local candidate
    if lfs.symlinkattributes(path) then
        local err
        candidate, err = refresh.fileIdentity(path, root)
        if not candidate then return nil, err end
    end
    local reference_identity
    if request.reference ~= nil then
        local reference = request.reference
        if type(reference) ~= "table" or type(reference.path) ~= "string" or type(reference.root) ~= "string"
            or not refresh.sameFileIdentity(reference.identity, reference.identity) then
            return nil, Util.error("invalid_request", "A complete cached-reference identity is required.")
        end
        if path == reference.path or (candidate and candidate.dev == reference.identity.dev and candidate.ino == reference.identity.ino) then
            return nil, Util.error("invalid_request", "A verification candidate must not alias its cached reference.")
        end
        local err
        reference_identity, err = hashReference(reference, expected, maximum, refresh)
        if not reference_identity then return nil, err end
    end
    if candidate then
        local current = refresh.fileIdentity(path, root)
        if not refresh.sameFileIdentity(candidate, current) then
            return nil, Util.error("storage", "The assigned partial file changed before source verification.")
        end
        -- A preempted worker may leave its own partial candidate at this assigned path.
        if not os.remove(path) then return nil, Util.error("storage", "The old verification candidate could not be cleared.") end
    end
    return { refresh = refresh, maximum = maximum, reference_identity = reference_identity }
end

local function localDiagnostics()
    -- Diagnostics cannot inherit credentials or acquire missing network assets.
    local client = Client.new{ transport = { request = function()
        return nil, Util.error("diagnostics_offline", "Local diagnostics do not make network requests.")
    end } }
    local checked, supplied = pcall(function() return client:capabilities() end)
    checked = checked and type(supplied) == "table"
    supplied = checked and supplied or {}
    local crypto = type(supplied.crypto) == "table" and supplied.crypto or {}
    local capabilities = {}
    for _, key in ipairs({ "request_signing", "response_decoding", "index_challenge", "index_error_reporting",
        "image_key_exchange", "encrypted_images" }) do capabilities[key] = crypto[key] == true end
    for _, key in ipairs({ "protected_catalog", "image_index", "image_tokens", "plain_images" }) do
        capabilities[key] = supplied[key] == true
    end
    local version_ok, version = pcall(function() return require("version"):getCurrentRevision() end)
    local source = debug.getinfo(1, "S").source
    local root = source:match("^@(.+)/bilicomics/jobs/worker%.lua$")
    local metadata_ok, metadata = pcall(function()
        return assert(loadfile(assert(root) .. "/_meta.lua"))()
    end)
    local function short(value)
        return type(value) == "string" and value:gsub("[%c]", ""):sub(1, 128) or nil
    end
    local ffi = require("ffi")
    return {
        koreader_version = version_ok and short(version) or nil,
        plugin_version = metadata_ok and type(metadata) == "table" and short(metadata.version) or nil,
        platform = { os = ffi.os, arch = ffi.arch, target = require("bilicomics/protocol/platform").nativeTarget() },
        capabilities = capabilities, capability_check_ok = checked == true, network_checked = false,
    }
end
local function execute(request, context)
    assert(type(request) == "table", "Invalid worker request")
    if request.kind == "diagnostics" then return localDiagnostics() end
    local verification
    if request.kind == "verify_source_page" then
        local err
        verification, err = prepareSourceVerification(request)
        if not verification then return nil, err end
    end
    if request.kind == "download_page" or request.kind == "download_cover" or verification then
        local directory = type(request.temporary_path) == "string" and request.temporary_path:match("^(.+)/[^/]+$")
        if not directory then return nil, Util.error("invalid_request", "The image output path is invalid.") end
        local enough_space, err = Budget.check(directory, request.minimum_free_bytes, request.max_bytes or Budget.default_image_limit)
        if not enough_space then return nil, err end
    end
    local session = request.session
    if request.kind == "client" and (request.method == "recommendations" or request.method == "bookstoreCategories"
        or request.method == "bookstoreCategoryPage") then session = nil end
    local client = Client.new{ session = session, asset_root = request.asset_root,
        transport_options = request.transport_options }
    context.client = client
    if request.kind == "client" then
        if not reads[request.method] then return nil, Util.error("invalid_request", "This operation is not a read-only worker operation.") end
        local result, err = client[request.method](client, unpack(request.arguments or {}))
        if result and request.method == "validateSession" then
            return { summary = result, session = client.session:serialize() }
        end
        return result, err
    elseif request.kind == "library" then
        if request.library ~= "favorites" and request.library ~= "history" then
            return nil, Util.error("invalid_request", "The library category is not supported.")
        end
        local method = request.library == "favorites" and "listFavorites" or "listHistory"
        local output, seen = {}, {}
        for page = 1, 200 do
            local items, err = client[method](client, { page_num = page, page_size = 50 })
            if not items then return nil, err end
            local new_items = 0
            for _, item in ipairs(items) do
                if item.id and item.id ~= "" and not seen[item.id] then
                    output[#output + 1], seen[item.id], new_items = item, true, new_items + 1
                end
            end
            if #items < 50 or new_items == 0 then return output end
        end
        return nil, Util.error("response_limit", "The library is too large for one refresh.")
    elseif request.kind == "source_index" then
        local function identifier(value)
            if type(value) ~= "string" and type(value) ~= "number" then return nil end
            value = tostring(value)
            if #value > 15 or not value:match("^[1-9]%d*$") then return nil end
            return value
        end
        local comic_id, episode_id = identifier(request.comic_id), identifier(request.episode_id)
        if not comic_id or not episode_id then
            return nil, Util.error("invalid_request", "Comic and episode identities are required for a source refresh.")
        end
        local detail, err = client:comicDetail(comic_id)
        if not detail then return nil, err end
        if type(detail) ~= "table" or type(detail.comic) ~= "table"
            or tostring(detail.comic.id) ~= comic_id or type(detail.episodes) ~= "table" then
            return nil, Util.error("protocol", "The refreshed catalog does not match the requested comic.")
        end
        local selected
        for _, episode in ipairs(detail.episodes) do
            if type(episode) == "table" and tostring(episode.id) == episode_id then
                if selected or tostring(episode.comic_id) ~= comic_id then
                    return nil, Util.error("protocol", "The refreshed catalog has an inconsistent chapter identity.")
                end
                selected = episode
            end
        end
        if not require("bilicomics/jobs/download_service").isReadable(selected, true) then
            return nil, Util.error("entitlement", "Offline access for this chapter is not confirmed in the refreshed catalog.")
        end
        local index
        index, err = client:imageIndex(episode_id)
        if not index then return nil, err end
        if type(index) ~= "table" or tostring(index.episode_id) ~= episode_id then
            return nil, Util.error("protocol", "The refreshed image index does not match the requested chapter.")
        end
        return { detail = detail, index = index }
    elseif request.kind == "quote" then
        return require("bilicomics/purchase/quote_fetch").run(client, request)
    elseif request.kind == "set_favorite" then
        local accepted, err = client:setFavorite(request.comic_id, request.favorite)
        if not accepted then return nil, err end
        return { accepted = true, comic_id = tostring(request.comic_id), favorite = request.favorite }
    elseif request.kind == "purchase_submit" then
        if type(request.intent_id) ~= "string" or request.intent_id == "" or type(request.payload) ~= "table" then
            return nil, Util.error("confirmation_required", "A persisted purchase intent is required.", { transmitted = false })
        end
        return client:buyEpisode(request.payload)
    elseif request.kind == "reconcile_purchase" then
        local detail, err = client:comicDetail(request.comic_id)
        if not detail then return nil, err end
        local wallet, wallet_error = client:wallet()
        return { detail = detail, wallet = wallet, wallet_error = wallet_error }
    elseif request.kind == "download_page" or request.kind == "download_cover" or verification then
        local token, err
        if request.kind == "download_cover" then token = { url = request.url, hit_encrpyt = false }
        else
            local tokens
            tokens, err = client:imageTokens({ assert(request.source_path) })
            if not tokens then return nil, err end
            token = tokens[1]
            if not token then return nil, Util.error("protocol", "The page did not receive an image token.") end
        end
        local result
        result, err = client:downloadImage(token, request.temporary_path, { index = request.index,
            max_bytes = request.max_bytes or 32 * 1024 * 1024,
            max_pixels = request.kind == "download_cover" and ImagePolicy.cover_max_pixels or nil })
        if not result then os.remove(request.temporary_path); return nil, err end
        if result.temporary_path ~= request.temporary_path then
            os.remove(request.temporary_path)
            return nil, Util.error("worker_protocol", "The image result did not match its assigned output path.")
        end
        local ok, header = pcall(Header.read, result.temporary_path)
        if not ok then os.remove(result.temporary_path); return nil, Util.error("image", "The downloaded image header is unsupported.") end
        if request.kind == "download_cover" and not ImagePolicy.fitsCover(header) then
            os.remove(result.temporary_path)
            return nil, Util.error("image_size", "The cover exceeds the supported source-image pixel limit.")
        end
        local orientation = header.exif_orientation or 1
        result.geometry = { source_width = header.width, source_height = header.height, exif_orientation = orientation }
        result.width, result.height = header.width, header.height
        if orientation >= 5 then result.width, result.height = result.height, result.width end
        if verification then
            if result.checksum ~= request.expected_checksum then
                os.remove(request.temporary_path)
                return nil, Util.error("content_changed", "The refreshed source page does not match the expected content.")
            end
            local candidate, err = verification.refresh.fileIdentity(request.temporary_path, request.temporary_root)
            if not candidate or candidate.size <= 0 or candidate.size > verification.maximum then
                os.remove(request.temporary_path)
                return nil, err or Util.error("image_size", "The verification candidate exceeds the image byte limit.")
            end
            if request.reference then
                local current = verification.refresh.fileIdentity(request.reference.path, request.reference.root)
                if not verification.refresh.sameFileIdentity(verification.reference_identity, current) then
                    os.remove(request.temporary_path)
                    return referenceChanged()
                end
            end
            result.reference_identity = verification.reference_identity
        end
        return result
    end
    return nil, Util.error("invalid_request", "The background operation is not supported.")
end

function Worker.execute(request)
    assert(type(request) == "table", "Invalid worker request")
    if request.kind == "diagnostics" then return localDiagnostics() end
    if request.kind == "auth" then
        local methods = { generateQR = true, pollQR = true, cookieInfo = true, refreshSession = true, confirmRefresh = true,
            ensureSiteContext = true }
        if not methods[request.method] then return nil, Util.error("invalid_request", "The sign-in operation is not supported.") end
        local auth = require("bilicomics/protocol/auth").new{ session = request.session,
            transport_options = request.transport_options }
        return auth[request.method](auth, unpack(request.arguments or {}))
    end
    local context = {}
    local value, err = execute(request, context)
    local client = context.client
    -- This third result travels only over the private worker pipe, outside ordinary business records.
    return value, err, client and client._session_changed == true and type(client.session) == "table"
        and client.session:serialize() or nil
end
return Worker
