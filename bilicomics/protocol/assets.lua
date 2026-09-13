local Errors = require("bilicomics/protocol/errors")

local Assets = {}

Assets.manifest = {
    signing = {
        filename = "efae82c96a7eef44bee5.wasm",
        url = "https://s1.hdslb.com/bfs/manga-static/manga-pc/efae82c96a7eef44bee5.wasm",
        sha256 = "39bc0676953752c461197df592e1f5894f1a7492a29400c946e560fc109a8e2e",
    },
    response = {
        filename = "e461bfa6b471a22c06fc.wasm",
        url = "https://s1.hdslb.com/bfs/manga-static/manga-pc/e461bfa6b471a22c06fc.wasm",
        sha256 = "3b499622e9a5f6181f0709d1485498f533428f9a30ae32694f6f6852ec47184c",
    },
}

local function digest(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local hash = require("ffi/sha2").sha256()
    while true do
        local chunk = file:read(65536)
        if not chunk then break end
        hash(chunk)
    end
    file:close()
    return hash()
end

function Assets.defaultRoot()
    return require("datastorage"):getDataDir() .. "/bilicomics/protocol-assets"
end

-- Only worker-side callers may acquire an absent public, digest-pinned module.
function Assets.ensure(name, opts)
    opts = opts or {}
    local asset = Assets.manifest[name]
    if not asset then return nil, Errors.capability("protocol_asset", "The requested protocol asset is not pinned.") end
    local root = opts.root or Assets.defaultRoot()
    local path = root .. "/" .. asset.filename
    if digest(path) == asset.sha256 then return path end
    if not opts.transport then return nil, Errors.capability("protocol_asset", "The pinned protocol module has not been installed.") end
    local made = require("util").makePath(root)
    if made == false then return nil, Errors.new("storage", "The protocol asset directory could not be created.") end
    local temporary = path .. ".part-" .. tostring(require("ffi").C.getpid())
    local response, err = opts.transport:request({
        url = asset.url, method = "GET", output_path = temporary,
        max_bytes = 16 * 1024 * 1024, total_timeout = 90,
        headers = { ["accept"] = "application/wasm", ["referer"] = "https://manga.bilibili.com/" },
    })
    if not response then return nil, err end
    if response.status ~= 200 or digest(temporary) ~= asset.sha256 then
        os.remove(temporary)
        return nil, Errors.new("protocol_asset", "The downloaded protocol module did not match its pinned digest.")
    end
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return nil, Errors.new("storage", "The verified protocol module could not be installed.")
    end
    return path
end

Assets.digest = digest

return Assets
