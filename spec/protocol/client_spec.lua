local root, output = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path

local Client = require("bilicomics/protocol/client")
local Errors = require("bilicomics/protocol/errors")
local Image = require("bilicomics/protocol/image")
local JSON = require("bilicomics/protocol/json")
local Normalize = require("bilicomics/protocol/normalize")
local Session = require("bilicomics/protocol/session")
local Transport = require("bilicomics/protocol/transport")
local passed = {}

local function test(name, fn)
    local ok, err = pcall(fn)
    assert(ok, name .. ": " .. tostring(err))
    passed[#passed + 1] = name
    print("PASS " .. name)
end

local function fixture()
    local transport = { requests = {}, data = {} }
    function transport:request(request)
        self.requests[#self.requests + 1] = request
        if self.failure then return nil, self.failure end
        return { status = 200, body = self.raw or assert(JSON.encode({ code = self.code or 0, data = self.data })), transmitted = true }
    end
    local session = assert(Session.parse("SESSDATA=synthetic-session; DedeUserID=42; bili_jct=synthetic-csrf; buvid3=SYNTHETIC-BUVID"))
    return Client.new({ session = session, transport = transport, clock = function() return 1800000000 end }), transport
end

test("cookie imports reject header injection and isolate supported names", function()
    assert(not Session.parse("SESSDATA=value\r\nAuthorization: bad"))
    assert(not Session.parse("SESSDATA=a; SESSDATA=b"))
    local session = assert(Session.parse('Cookie: SESSDATA=a%2Cb; unknown=discard; DedeUserID=42'))
    assert(session.cookies.SESSDATA == "a%2Cb" and session.cookies.unknown == nil)
    assert(session:cookieHeader("example.com") == nil)
    assert(session:cookieHeader("api.bilibili.com"):find("SESSDATA=a%%2Cb"))
    local exported = assert(Session.parse('[{"name":"SESSDATA","value":"good","domain":".bilibili.com"},{"name":"bili_jct","value":"bad","domain":"example.com"}]'))
    assert(exported.cookies.SESSDATA == "good" and exported.cookies.bili_jct == nil)
    local bom_header = assert(Session.parse("\239\187\191SESSDATA=synthetic; DedeUserID=42"))
    assert(bom_header.cookies.SESSDATA == "synthetic")
    local bom_json = assert(Session.parse('\239\187\191[{"name":"SESSDATA","value":"synthetic","domain":".bilibili.com"}]'))
    assert(bom_json.cookies.SESSDATA == "synthetic")
end)

test("stable account identity is server-validated before persistence", function()
    local client, transport = fixture()
    assert(not client.session:save(output .. "/unvalidated.dat"))
    transport.data = { isLogin = true, mid = 43, uname = "Wrong account" }
    local value, err = client:validateSession()
    assert(value == nil and err.kind == "account_mismatch")
    transport.data.mid = 42
    assert(client:validateSession().account_key == "bili_42")
    assert(client.session:save(output .. "/session.dat"))
    local restored = assert(Session.load(output .. "/session.dat"))
    assert(restored.account_key == "bili_42" and restored.cookies.SESSDATA == "synthetic-session")
    assert(JSON.encode(restored:summary()):find("synthetic-session", 1, true) == nil)
end)

test("plain wrappers retain real endpoint and empty-object request shape", function()
    local client, transport = fixture()
    transport.data = { gold = 12, remain_coupon = 3 }
    assert(client:wallet().gold == 12)
    assert(transport.requests[1].body == "{}")
    assert(transport.requests[1].url:find("/twirp/user.v1.User/GetWallet?device=pc&platform=web&nov=27&a=810", 1, true))
    transport.data = { { id = 999, comic_id = 81, title = "Synthetic", vcover = "https://i0.hdslb.com/cover.jpg" } }
    local favorites = assert(client:listFavorites({ page_num = 2 }))
    assert(favorites[1].id == "81" and favorites[1].cover_url == "https://i0.hdslb.com/cover.jpg")
    local body = assert(JSON.decode(transport.requests[2].body))
    assert(body.page_num == 2 and body.type == 0 and body.source == "web")
end)

test("protected catalog never silently falls back to unsigned legacy requests", function()
    local client, transport = fixture()
    client.crypto = require("bilicomics/protocol/crypto").new({ native = false })
    local value, err = client:comicDetail("81")
    assert(value == nil and err.kind == "capability")
    assert(#transport.requests == 0)
end)

test("signed body and protected plain response preserve fractional chapter order", function()
    local client, transport = fixture()
    local signed_context
    client.crypto = {
        signRequest = function(_, context) signed_context = context; return { ultra_sign = "fixture-sign", data_sn = "fixture-sn" } end,
        decodeResponse = function() error("Plain data must not be decrypted") end,
    }
    transport.data = { id = 81, title = "Synthetic", ep_list = {
        { id = 13, ord = 2, title = "Second", is_locked = true },
        { id = 12, ord = 1.5, title = "Special", pay_mode = 0 },
    } }
    local detail = assert(client:comicDetail("81"))
    assert(detail.episodes[1].id == "12" and detail.episodes[1].order == 1.5)
    assert(detail.episodes[2].access == "locked")
    assert(signed_context.body == transport.requests[1].body)
    assert(transport.requests[1].headers["x-bili-data-sn"] == "fixture-sn")
    assert(transport.requests[1].url:find("ultra_sign=fixture-sign", 1, true))
end)

test("access normalization does not mistake unlock flags or unparsed expiry for ownership", function()
    assert(Normalize.access({ is_locked = false, pay_mode = 1 }) == "unknown")
    assert(Normalize.access({ unlock_type = 1, unlock_expire_at = 0 }) == "owned")
    assert(Normalize.access({ unlock_type = 1, unlock_expire_at = 200 }, 100) == "temporary")
    assert(Normalize.access({ unlock_type = 2, unlock_expire_at = 90 }, 100) == "locked")
    assert(Normalize.access({ unlock_type = 2, unlock_expire_at = "2026-09-12 08:00:00" }) == "unknown")
    assert(Normalize.episode({ id = 1, read = true }, 8).read == true)
    assert(Normalize.episode({ id = 1, is_read = false, read = true }, 8).read == false)
end)

test("encrypted success and plain errors use separate response branches", function()
    local client, transport = fixture()
    client.crypto = {
        signRequest = function() return { ultra_sign = "fixture-sign", data_sn = "fixture-sn" } end,
        decodeResponse = function(_, _, envelope) assert(envelope.bytesData == "fixture"); return { code = 0, data = { id = 81 } } end,
    }
    transport.raw = '{"code":0,"data":null,"bytesData":"fixture"}'
    assert(client:comicDetail(81).comic.id == "81")
    transport.raw = '{"code":1,"data":null,"bytesData":"unused"}'
    local value, err = client:_post("comic.v1.Comic", "GetImageIndex", { ep_id = 1 })
    assert(value == nil and err.kind == "locked")
    transport.raw = '{"code":0,"data":null}'
    value, err = client:comicDetail(81)
    assert(value == nil and err.kind == "protocol")
end)

test("purchase rejects automatic settings and accepts explicit coupon payload without currency amount", function()
    local client, transport = fixture()
    local value, err = client:buyEpisode({ ep_id = 12, buy_method = 1 })
    assert(value == nil and err.transmitted == false and #transport.requests == 0)
    value, err = client:buyEpisode({ ep_id = 12, buy_method = 3, pay_amount = 20, auto_pay_gold_status = 1 })
    assert(value == nil and err.transmitted == false)
    transport.raw = '{"code":0,"data":null}'
    assert(client:buyEpisode({ ep_id = "12", buy_method = 2, coupon_ids = { "501" } }))
    local body = assert(JSON.decode(transport.requests[1].body))
    assert(body.pay_amount == nil and body.buy_method == 2 and body.ep_id == 12)
    assert(client:buyEpisode({ ep_id = "12", buy_method = 3 }))
end)

test("purchase unknown results and transport loss cannot become definitive rejection or retry", function()
    local client, transport = fixture()
    transport.code = 99
    local value, err = client:buyEpisode({ ep_id = 12, buy_method = 3, pay_amount = 20 })
    assert(value == nil and err.kind == "purchase_unknown" and err.definitive == false)
    assert(#transport.requests == 1)
    transport.code = 2
    value, err = client:buyEpisode({ ep_id = 12, buy_method = 3, pay_amount = 20 })
    assert(value == nil and err.kind == "purchase_rejected" and err.definitive == true)
    transport.failure = Errors.new("timeout", "Synthetic response loss", { transmitted = true })
    value, err = client:buyEpisode({ ep_id = 12, buy_method = 3, pay_amount = 20 })
    assert(value == nil and err.kind == "timeout" and err.transmitted and #transport.requests == 3)
end)

test("image headers are inspected independently of URL extension", function()
    for _, format in ipairs({ "jpg", "png", "webp" }) do
        local info = assert(Image.inspect(output .. "/fixture." .. format))
        assert(info.format == format and info.width == 24 and info.height == 37 and #info.checksum == 64)
    end
    local value, err = Image.inspect(output .. "/truncated.png")
    assert(value == nil and err.kind == "invalid_image")
    value, err = Image.inspect(output .. "/corrupt.png")
    assert(value == nil and err.kind == "invalid_image")
end)

test("ordinary snapshots redact acquisition credentials", function()
    local safe = Normalize.safeExtra({ token = "secret", cookies = {}, title = "Book", child = { private_key = "secret" }, url = "https://example.com/img?token=secret" })
    assert(safe.token == nil and safe.cookies == nil and safe.url == nil and safe.child.private_key == nil and safe.title == "Book")
end)

test("TLS names support exact and single-label wildcard matches only", function()
    assert(Transport.matchesHost("*.bilibili.com", "api.bilibili.com"))
    assert(not Transport.matchesHost("*.bilibili.com", "a.api.bilibili.com"))
    assert(not Transport.matchesHost("*.bilibili.com", "bilibili.com"))
    assert(not Transport.matchesHost("api.bilibili.com\000.example.com", "api.bilibili.com"))
    local cert = { extensions = function() return { ["2.5.29.17"] = { dNSName = { "wrong.example" } } } end,
        subject = function() return { { oid = "2.5.4.3", value = "api.bilibili.com" } } end }
    assert(not Transport.verifiesHost(cert, "api.bilibili.com"))
end)

local result = assert(io.open(output .. "/client-result.json", "wb"))
result:write(assert(JSON.encode({ passed = #passed, cases = passed })))
result:close()
