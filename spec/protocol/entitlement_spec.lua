local root, output = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path

local Client = require("bilicomics/protocol/client")
local JSON = require("bilicomics/protocol/json")
local Normalize = require("bilicomics/protocol/normalize")
local passed = {}
local zero_date = "0000-00-00 00:00:00"

local function test(name, fn)
    local ok, err = pcall(fn)
    assert(ok, name .. ": " .. tostring(err))
    passed[#passed + 1] = name
    print("PASS " .. name)
end

test("exact catalog zero date preserves permanent ownership and its raw evidence", function()
    local raw = {
        id = 101, ord = 1, pay_mode = 1, unlock_type = 1,
        is_locked = false, is_in_free = false, unlock_expire_at = zero_date,
    }
    local episode = Normalize.episode(raw, 81, 1800000000)
    assert(episode.access == "owned" and episode.expires_at == 0)
    assert(episode.extra.unlock_expire_at == zero_date)
    assert(raw.unlock_expire_at == zero_date)
    local access, expiry = Normalize.access({ unlock_type = 1, expires_at = zero_date })
    assert(access == "owned" and expiry == 0)
end)

test("zero date does not independently grant an entitlement", function()
    local access, expiry = Normalize.access({
        pay_mode = 0, unlock_type = 0, is_locked = false,
        is_in_free = false, unlock_expire_at = zero_date,
    })
    assert(access == "free" and expiry == 0)
    assert(Normalize.access({ pay_mode = 1, is_locked = false, unlock_expire_at = zero_date }) == "unknown")
    for _, unlock_type in ipairs({ 2, 3 }) do
        assert(Normalize.access({ unlock_type = unlock_type, unlock_expire_at = zero_date }) == "temporary")
    end
    assert(Normalize.access({ pay_mode = 1, is_in_free = true, unlock_expire_at = zero_date }) == "temporary")
end)

test("explicit lock overrides contradictory free owned and temporary flags", function()
    for _, locked in ipairs({ true, 1, "1" }) do
        for _, entitlement in ipairs({
            { pay_mode = 0 }, { unlock_type = 1 }, { is_purchased = true },
            { unlock_type = 2 }, { unlock_type = 3 }, { is_in_free = true },
        }) do
            entitlement.is_locked = locked
            entitlement.unlock_expire_at = zero_date
            local access, expiry = Normalize.access(entitlement)
            assert(access == "locked" and expiry == 0)
        end
        assert(Normalize.access({ unlock_type = 1, is_locked = locked,
            unlock_expire_at = "2026-09-12 08:00:00" }) == "locked")
    end
end)

test("unavailable retains precedence over explicit lock", function()
    for _, status in ipairs({ { unavailable = true }, { is_available = false }, { status = 501 } }) do
        status.is_locked = true
        status.unlock_type = 1
        status.unlock_expire_at = zero_date
        assert(Normalize.access(status) == "unavailable")
    end
end)

test("unparsed nonzero dates and near zero date variants remain unknown", function()
    for _, expiry in ipairs({
        "2026-09-12 08:00:00", "2099-12-31 23:59:59", "0000-00-00",
        "0000-00-00 00:00:00Z", "0000-00-00 00:00:00 ", " 0000-00-00 00:00:00",
    }) do
        for _, unlock_type in ipairs({ 1, 2, 3 }) do
            local access, normalized = Normalize.access({
                unlock_type = unlock_type, is_locked = false, unlock_expire_at = expiry,
            })
            assert(access == "unknown" and normalized == nil)
        end
    end
end)

test("numeric expiry and explicit false lock behavior stay intact", function()
    for _, unlocked in ipairs({ false, 0, "0" }) do
        assert(Normalize.access({ unlock_type = 1, is_locked = unlocked, unlock_expire_at = 0 }) == "owned")
        assert(Normalize.access({ pay_mode = 0, is_locked = unlocked }) == "free")
    end
    assert(Normalize.access({ unlock_type = 1, unlock_expire_at = "0" }) == "owned")
    assert(Normalize.access({ unlock_type = 1, unlock_expire_at = 200 }, 100) == "temporary")
    assert(Normalize.access({ unlock_type = 1, unlock_expire_at = 100 }, 100) == "locked")
    assert(Normalize.access({ unlock_type = 2, unlock_expire_at = 90 }, 100) == "locked")
end)

test("comic detail applies entitlement fixes through a catalog only injected transport", function()
    local raw_episodes = {
        { id = 104, ord = 4, pay_mode = 1, unlock_type = 1, is_locked = false,
            is_in_free = false, unlock_expire_at = "2026-09-12 08:00:00" },
        { id = 103, ord = 3, pay_mode = 0, unlock_type = 1, is_locked = true,
            is_in_free = false, unlock_expire_at = zero_date },
        { id = 102, ord = 1.5, pay_mode = 1, unlock_type = 1, is_locked = false,
            is_in_free = false, unlock_expire_at = zero_date },
        { id = 101, ord = 1, pay_mode = 0, unlock_type = 0, is_locked = false,
            is_in_free = false, unlock_expire_at = zero_date },
    }
    local calls, signed_body = 0
    local transport = {}
    function transport:request(request)
        assert(request.method == "POST")
        assert(request.url == "https://manga.bilibili.com/twirp/comic.v1.Comic/ComicDetail?device=pc&platform=web&nov=27&a=810&ultra_sign=synthetic")
        assert(request.headers.cookie == nil and request.body == signed_body)
        local body = assert(JSON.decode(request.body))
        assert(body.comic_id == 81)
        for key in pairs(body) do assert(key == "comic_id") end
        calls = calls + 1
        return { status = 200, transmitted = true, body = assert(JSON.encode({
            code = 0, data = { id = 81, title = "Synthetic catalog", ep_list = raw_episodes },
        })) }
    end
    local client = Client.new({
        transport = transport, clock = function() return 1800000000 end,
        crypto = {
            signRequest = function(_, context)
                assert(context.endpoint == "ComicDetail")
                signed_body = context.body
                return { ultra_sign = "synthetic", data_sn = "synthetic" }
            end,
        },
    })
    local detail = assert(client:comicDetail("81"))
    assert(calls == 1 and detail.comic.id == "81" and #detail.episodes == 4)
    for index, access in ipairs({ "free", "owned", "locked", "unknown" }) do
        assert(detail.episodes[index].id == tostring(100 + index))
        assert(detail.episodes[index].access == access)
    end
    assert(detail.episodes[2].order == 1.5 and detail.episodes[2].expires_at == 0)
    assert(detail.episodes[2].extra.unlock_expire_at == zero_date)
    assert(detail.episodes[4].expires_at == nil)
end)

local file = assert(io.open(output .. "/entitlement-result.json", "wb"))
file:write(assert(JSON.encode({ passed = #passed, tests = passed, network_requests = 0,
    scope = "Synthetic entitlement normalization and injected ComicDetail response only" })))
file:close()
