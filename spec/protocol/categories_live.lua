-- One production metadata read and one category page, using only a fresh anonymous device context.
require("setupkoenv")
local root, output = assert(arg[1]), assert(arg[2])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(require("datastorage"):getDataDir() .. "/settings.reader.lua")
local JSON = require("bilicomics/protocol/json")
local Categories = require("bilicomics/protocol/categories")
local Assets = require("bilicomics/protocol/assets")
local Transport = require("bilicomics/protocol/transport")
local Client = require("bilicomics/protocol/client")
assert(assert(loadfile(root .. "/spec/local/readonly_guard.lua"))().install(output))
local guarded_request = Transport.request
local counts, requests = {}, {}
function Transport:request(request)
    local route
    if request.url == Categories.metadata_url and request.method == "POST" and request.body == "{}" then route = "AllLabel"
    elseif request.url == Categories.device_url and request.method == "GET" and request.body == nil then route = "AnonymousDevice"
    elseif request.url:sub(1, #Categories.page_url) == Categories.page_url and request.method == "POST" then
        route = "ClassPage"
        local body = assert(JSON.decode(request.body))
        assert(body.style_id == 999 and body.order == 0 and body.page_num == 1 and body.page_size == 18)
        assert(body.area_id == -1 and body.is_finish == -1 and body.is_free == -1 and body.special_tag == 0)
    elseif request.url == Assets.manifest.signing.url and request.method == "GET" and request.body == nil then route = "PinnedSigningAsset"
    else error("An unrelated live request was blocked") end
    counts[route] = (counts[route] or 0) + 1
    assert(counts[route] == 1, "Each approved live route is limited to one request")
    local device_cookie = false
    for key, value in pairs(request.headers or {}) do
        local lower = key:lower()
        assert(lower ~= "authorization" and lower ~= "x-xsrf-token")
        if lower == "cookie" then
            assert(route == "ClassPage" and value:match("^buvid3=[%w_-]+$"))
            device_cookie = true
        end
    end
    assert(route ~= "ClassPage" or device_cookie)
    local response, err = guarded_request(self, request)
    local record = { route = route, method = request.method, status = response and response.status,
        bytes = response and response.bytes, anonymous_device_cookie_only = device_cookie,
        account_credentials_absent = true, error_kind = err and err.kind }
    if route == "AllLabel" or route == "ClassPage" then
        local envelope = response and JSON.decode(response.body)
        record.code = envelope and envelope.code
        record.encrypted_response = envelope and type(envelope.bytesData) == "string" and #envelope.bytesData > 0
    end
    requests[#requests + 1] = record
    return response, err
end
local client = Client.new{ asset_root = output .. "/assets" }
local metadata, err = client:bookstoreCategories()
assert(metadata, err and err.kind or "Category metadata failed")
local present = false
for _, item in ipairs(metadata.items) do if item.id == "999" then present = true end end
assert(present, "The live category must be a member of the current official metadata")
local page
page, err = client:bookstoreCategoryPage({kind="category",category_id="999",sort=0},1)
assert(page, err and err.kind or "Category page failed")
assert(#page.items > 0 and #page.items <= 18 and page.has_more)
assert(client.session == nil and client._session_changed == nil)
local result = { passed = true, official_metadata = metadata, official_page = page, requests = requests,
    readonly_guard_installed = true, parent_session_absent = true, parent_session_update_absent = true,
    account_credentials_used = false, device_cookie_persisted = false }
local file = assert(io.open(output .. "/bookstore-categories-live-result.json", "wb"))
file:write(assert(JSON.encode(result)));file:close()
print(assert(JSON.encode({passed=true,categories=#metadata.items,comics=#page.items,requests=#requests,
    readonly_guard_installed=true,account_credentials_used=false})))
