local Errors = require("bilicomics/protocol/errors")

local Crypto = {}
Crypto.__index = Crypto

function Crypto.new(opts)
    opts = opts or {}
    local backend = opts.backend
    if backend == nil and opts.native ~= false then
        backend = require("bilicomics/protocol/native_backend").new(opts)
    end
    return setmetatable({ backend = backend }, Crypto)
end

function Crypto:capabilities()
    local supplied = self.backend and self.backend:capabilities() or {}
    return {
        request_signing = supplied.request_signing == true,
        response_decoding = supplied.response_decoding == true,
        index_challenge = supplied.index_challenge == true,
        index_error_reporting = supplied.index_error_reporting == true,
        image_key_exchange = supplied.image_key_exchange == true,
        encrypted_images = supplied.encrypted_images == true,
        encrypted_image_versions = supplied.encrypted_image_versions or {},
        max_encrypted_image_bytes = supplied.max_encrypted_image_bytes,
        plain_images = true,
        backend = supplied.backend or "unavailable",
    }
end

local methods = {
    signRequest = "request_signing", decodeResponse = "response_decoding",
    prepareTokens = "image_key_exchange",
    convertImage = "encrypted_images",
}

for method, capability in pairs(methods) do
    Crypto[method] = function(self, ...)
        if self.backend and self.backend[method] and self:capabilities()[capability] then
            return self.backend[method](self.backend, ...)
        end
        return nil, Errors.capability(capability)
    end
end

function Crypto:prepareIndex(context)
    local caps = self:capabilities()
    if self.backend and self.backend.prepareIndex and (caps.index_challenge or caps.index_error_reporting) then
        return self.backend:prepareIndex(context)
    end
    return nil, Errors.capability("index_challenge")
end

function Crypto:prepareCatalog(context)
    local caps = self:capabilities()
    if self.backend and self.backend.prepareCatalog and (caps.index_challenge or caps.index_error_reporting) then
        return self.backend:prepareCatalog(context)
    end
    return nil, Errors.capability("catalog_request_context")
end

return Crypto
