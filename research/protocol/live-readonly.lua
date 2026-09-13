-- Run only on the explicitly selected remote verification environment.
-- This probe sends no account session, purchase, coupon, or image requests.
local root, output = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local Client = require("bilicomics/protocol/client")
local JSON = require("bilicomics/protocol/json")
local Transport = require("bilicomics/protocol/transport")
local transport = Transport.new()
local navigation, navigation_error = transport:request({
    url = "https://api.bilibili.com/x/web-interface/nav", method = "GET",
    headers = { ["user-agent"] = "Mozilla/5.0", referer = "https://manga.bilibili.com/" },
})
local nav_data = navigation and JSON.decode(navigation.body)
local client = Client.new({ transport = transport, asset_root = output .. "/assets" })
local detail, err = client:comicDetail("36215")
local result = {
    probe = "anonymous-current-pc-signed-comic-detail-with-m2-error-report", account_session_used = false,
    native_capabilities = client:capabilities(),
    navigation = { status = navigation and navigation.status, code = nav_data and nav_data.code, error = navigation_error },
    detail = detail and { id = detail.comic.id, episode_count = #detail.episodes } or nil,
    error = err,
}
local file = assert(io.open(output .. "/live-readonly-result.json", "wb"))
file:write(assert(JSON.encode(result))); file:close()
print(assert(JSON.encode(result)))
