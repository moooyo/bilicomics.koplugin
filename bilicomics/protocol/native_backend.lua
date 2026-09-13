local Assets = require("bilicomics/protocol/assets")
local ECDH = require("bilicomics/protocol/ecdh")
local Errors = require("bilicomics/protocol/errors")
local JSON = require("bilicomics/protocol/json")
local ResponseCrypto = require("bilicomics/protocol/response_crypto")
local Platform = require("bilicomics/protocol/platform")
local NativeLibrary = require("bilicomics/protocol/native_library")

local Backend = {}
Backend.__index = Backend

local module_path = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."
local ffi = require("ffi")
ffi.cdef[[
int biliwasm_run(const char *wasm_path, const char *request_json, char **output_json);
void biliwasm_free(char *output_json);
]]

function Backend.new(opts)
    opts = opts or {}
    return setmetatable({ transport = opts.transport, asset_root = opts.asset_root,
        library_path = opts.library_path, library = nil, checked_library = false }, Backend)
end

function Backend:_library()
    if self.checked_library then return self.library end
    self.checked_library = true
    local path = self.library_path
    if not path then
        local target = Platform.nativeTarget()
        if not target then return nil end
        self.binary_target = target
        path = module_path .. "/native/bin/" .. target .. "/libbiliwasm.so"
    end
    local library, detail = NativeLibrary.load("libbiliwasm.so", {
        module_dir = module_path, target = self.binary_target or Platform.nativeTarget(), source_path = path,
    })
    if library then
        local symbols = pcall(function() return library.biliwasm_run, library.biliwasm_free end)
        if symbols then self.library = library end
    else
        self.library_error = detail and detail.message
    end
    return self.library
end

function Backend:capabilities()
    local available = self:_library() ~= nil
    local exchange = ECDH.capability()
    local image_loaded, image_crypto = pcall(require, "bilicomics/protocol/image_crypto")
    local image_available = image_loaded and image_crypto.available()
    return {
        backend = "wasm3-gojs-local", request_signing = available, response_decoding = ResponseCrypto.available() == true,
        image_key_exchange = exchange.available == true,
        index_challenge = false, index_error_reporting = true, encrypted_images = image_available == true,
        encrypted_image_versions = image_loaded and image_crypto.supported_versions or {},
        max_encrypted_image_bytes = 16 * 1024 * 1024,
        platform = ffi.os .. "-" .. ffi.arch,
        binary_target = self.binary_target,
    }
end

function Backend:_invoke(asset, name, args)
    local library = self:_library()
    if not library then return nil, Errors.capability("native_protocol", self.library_error or "No verified native protocol library is installed for this platform.") end
    local path, err = Assets.ensure(asset, { root = self.asset_root, transport = self.transport })
    if not path then return nil, err end
    local request
    request, err = JSON.encode({ ["function"] = name, args = JSON.array(args) })
    if not request then return nil, err end
    local output = ffi.new("char *[1]")
    local status = library.biliwasm_run(path, request, output)
    if output[0] == nil then return nil, Errors.new("crypto", "The local protocol module could not allocate a result.") end
    local text = ffi.string(output[0])
    library.biliwasm_free(output[0])
    local decoded
    decoded, err = JSON.decode(text)
    if not decoded then return nil, err end
    if status ~= 0 or decoded.ok ~= true or type(decoded.result) ~= "table" then
        return nil, Errors.new("crypto", "The pinned protocol module could not process this request.", { transmitted = false })
    end
    if type(decoded.result.error) == "string" and decoded.result.error ~= "" then
        return nil, Errors.new("crypto", "The pinned protocol module rejected the input.", { transmitted = false })
    end
    return decoded.result
end

function Backend:signRequest(context)
    local timestamp = context.timestamp_ms or context.timestamp * 1000
    local result, err = self:_invoke("signing", "y1_z2w2a3", { context.sign_query, context.body, timestamp })
    if not result then return nil, err end
    if type(result.sign) ~= "string" or result.sign == "" then
        return nil, Errors.new("crypto", "The pinned signing module returned no signature.", { transmitted = false })
    end
    return { ultra_sign = result.sign, data_sn = "1E74C20E5720FBF3BB351965D7A9DFC1" }
end

function Backend:decodeResponse(context, envelope)
    return ResponseCrypto.decode(context, envelope)
end

function Backend:prepareTokens()
    return ECDH.newKey()
end

function Backend:prepareIndex(context)
    local timestamp = context and context.timestamp_ms or os.time() * 1000
    -- The current official wrapper reports an actual environment error and
    -- still sends the read request. This is not a fabricated fingerprint or
    -- proof that the service accepts the browser-error branch on a device.
    return {
        m2 = "error:BiliComics local reader has no browser fingerprint environment_" .. string.format("%.0f", timestamp),
        challenge_status = "environment_error_reported",
    }
end

Backend.prepareCatalog = Backend.prepareIndex

function Backend:convertImage(request)
    local loaded, image_crypto = pcall(require, "bilicomics/protocol/image_crypto")
    if not loaded then return nil, Errors.capability("encrypted_images", "No verified encrypted image converter is installed.") end
    local available, reason = image_crypto.available()
    if not available then return nil, Errors.capability("encrypted_images", reason) end
    local exchange = request.context
    if type(exchange) ~= "table" or type(exchange.private_key) ~= "string" then
        return nil, Errors.new("crypto", "The image token has no matching private key exchange context.")
    end
    local transport = request.transport or self.transport
    if not transport then return nil, Errors.new("network", "No image transport is available.") end
    local maximum = math.min(tonumber(request.max_bytes) or 16 * 1024 * 1024, 16 * 1024 * 1024)
    local response, err = transport:request({
        url = request.url, method = "GET", output_path = request.output_path,
        max_bytes = maximum, total_timeout = request.total_timeout,
        headers = { referer = "https://manga.bilibili.com/", ["accept"] = "application/octet-stream,image/*" },
    })
    if not response then return nil, err end
    if response.status ~= 200 then
        os.remove(request.output_path)
        return nil, Errors.new("image_http", "The encrypted image service rejected the resource.", {
            status = response.status, retryable = response.status == 429 or response.status >= 500,
        })
    end
    local file = io.open(request.output_path, "rb")
    if not file then return nil, Errors.new("storage", "The encrypted image could not be opened.") end
    local encoded = file:read(maximum + 1)
    file:close()
    if not encoded or #encoded > maximum then
        os.remove(request.output_path)
        return nil, Errors.new("image_size", "The encrypted image exceeds the bounded preparation limit.")
    end
    local content_type = response.headers and (response.headers["content-type"] or response.headers["Content-Type"])
    if type(content_type) == "string" and content_type:sub(1, 6) == "image/" then
        -- The official XHR handler returns image responses before inspecting a container version.
        -- Client.downloadImage still validates the file, geometry, and checksum.
        return { temporary_path = request.output_path }
    end
    local ok, plaintext
    ok, plaintext, err = pcall(image_crypto.convert, exchange.private_key, encoded, request.url, request.index or 0)
    if not ok or type(plaintext) ~= "string" or #plaintext == 0 or #plaintext > maximum then
        os.remove(request.output_path)
        return nil, ok and err or Errors.new("crypto", "The encrypted image could not be transformed.")
    end
    file = io.open(request.output_path, "wb")
    if not file then os.remove(request.output_path); return nil, Errors.new("storage", "The prepared image could not be written.") end
    local written = file:write(plaintext)
    local closed = file:close()
    if not written or not closed then
        os.remove(request.output_path)
        return nil, Errors.new("storage", "The prepared image could not be written completely.")
    end
    return { temporary_path = request.output_path }
end

return Backend
