-- Run only in test-env with the official KOReader runtime.
local root, output, live_fixture, result_name = assert(arg[1]), assert(arg[2]), arg[3], arg[4] or "recommendations-result.json"
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path

local network_attempts = 0
package.loaded["bilicomics/protocol/transport"] = { new = function()
    network_attempts = network_attempts + 1
    error("The recommendation contract spec cannot create a real transport")
end }
local Client = require("bilicomics/protocol/client")
local JSON = require("bilicomics/protocol/json")
local Recommendations = require("bilicomics/protocol/recommendations")
local cases, assertions, requests = {}, 0, 0

local function check(condition, message)
    assertions = assertions + 1
    assert(condition, message or "Recommendation contract assertion failed")
end

local function test(name, callback)
    local ok, err = pcall(callback)
    cases[#cases + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    print((ok and "PASS " or "FAIL ") .. name .. (not ok and ": " .. tostring(err) or ""))
end

local function comic(id, title)
    return { id = id, title = title or "Synthetic comic", evaluate = "Official recommendation text.\nSecond line.",
        vertical_cover = "https://i0.hdslb.com/bfs/manga-static/synthetic.png", tags = { "Adventure", "Magic" } }
end

local function context(items)
    return { pageId = "/pages/index", data = { recommendation = { comics = items } } }
end

local function fixture(body, status)
    local transport = { calls = 0 }
    function transport:request(request)
        self.calls = self.calls + 1
        requests = requests + 1
        self.request_value = request
        check(request.url == "https://manga.bilibili.com/index.pageContext.json", "Only the observed official data route is allowed")
        check(request.method == "GET" and request.body == nil, "Recommendations must use an anonymous GET without a body")
        check(request.max_bytes == 4 * 1024 * 1024, "The response must remain bounded")
        check(request.headers.cookie == nil and request.headers["x-xsrf-token"] == nil and request.headers.authorization == nil)
        check(request.headers["x-bili-data-sn"] == nil and request.url:find("?", 1, true) == nil)
        return { status = status or 200, body = body, transmitted = true,
            headers = { ["set-cookie"] = "SESSDATA=untrusted-response-cookie; Path=/" } }
    end
    local client = Client.new{ transport = transport, crypto = {}, session = { cookies = {
        SESSDATA = "synthetic-recommendation-session", bili_jct = "synthetic-csrf", ["XSRF-TOKEN"] = "synthetic-xsrf",
    } } }
    client._headers = function() error("The public recommendation request must not access session headers") end
    client._captureCookies = function() error("The public recommendation request must not capture cookies") end
    client._post = function() error("The public recommendation request must not use a Twirp endpoint") end
    return client, transport
end

test("The official route remains anonymous even when Client has a session", function()
    local client, transport = fixture(assert(JSON.encode(context({ comic(81) }))))
    local before = assert(JSON.encode(client.session:serialize()))
    local feed = assert(client:recommendations())
    check(feed.source == "official_homepage" and feed.personalized == false and feed.has_more == false)
    check(transport.calls == 1 and #feed.items == 1)
    check(client._session_changed == nil and JSON.encode(client.session:serialize()) == before)
end)

test("Recommendations preserve official order and public display metadata", function()
    local first, second = comic(91, "First"), comic("12", "Second")
    second.vertical_cover = "http://i0.hdslb.com/bfs/manga-static/second.jpg"
    first.favorite, first.is_fav, first.read = true, true, true
    first.cookies, first.token, first.private_key = "discard", "discard", "discard"
    local feed = assert(Recommendations.normalize(context({ first, second, comic(91, "Duplicate") })))
    check(#feed.items == 2 and feed.items[1].id == "91" and feed.items[2].id == "12")
    check(feed.items[1].title == "First" and feed.items[2].title == "Second")
    check(feed.items[2].cover_url == "https://i0.hdslb.com/bfs/manga-static/second.jpg")
    check(feed.items[1].extra.recommendation == first.evaluate and feed.items[1].extra.evaluate == first.evaluate)
    check(#feed.items[1].extra.tags == 2 and feed.items[1].extra.tags[1] == "Adventure")
    check(feed.items[1].favorite == nil and feed.items[1].read == nil and feed.items[1].finished == nil)
    check(feed.items[1].extra.cookies == nil and feed.items[1].extra.token == nil and feed.items[1].extra.private_key == nil)
end)

test("Invalid items cannot introduce malformed identifiers titles or cover sources", function()
    local entries = { comic(51) }
    for _, id in ipairs({ 0, -1, 1.5, 1000000000000000, "01", "1e1", "bad", false }) do
        entries[#entries + 1] = comic(id)
    end
    local missing_title, unsafe_cover, injected_cover, large_title = comic(61), comic(62), comic(63), comic(64)
    missing_title.title = "  "
    unsafe_cover.vertical_cover = "https://example.com/cover.jpg"
    injected_cover.vertical_cover = "https://i0.hdslb.com@localhost/cover.jpg"
    large_title.title = string.rep("x", 1025)
    entries[#entries + 1], entries[#entries + 2], entries[#entries + 3], entries[#entries + 4] =
        missing_title, unsafe_cover, injected_cover, large_title
    local feed = assert(Recommendations.normalize(context(entries)))
    check(#feed.items == 1 and feed.items[1].id == "51")
    local value, err = Recommendations.normalize(context({ unsafe_cover }))
    check(value == nil and err.kind == "protocol", "An entirely unusable feed must surface a response error")
end)

test("Missing malformed and redirected page contexts do not become empty success", function()
    for _, raw in ipairs({ {}, { pageId = "/pages/detail", data = { recommendation = { comics = {} } } },
        { pageId = "/pages/index", data = {} }, { pageId = "/pages/index", data = { recommendation = {} } },
        context(false), context({ unexpected = comic(1) }), context({ [1] = comic(1), [3] = comic(3) }) }) do
        local value, err = Recommendations.normalize(raw)
        check(value == nil and err.kind == "protocol")
    end
    local empty = assert(Recommendations.normalize(context({})))
    check(#empty.items == 0 and empty.has_more == false)
end)

test("Optional descriptions and tags are bounded and sanitized independently", function()
    local raw = comic(81, " A\nTitle\0 ")
    raw.evaluate = string.rep("x", 16385)
    raw.tags = { " One\nTag ", false, {}, string.rep("x", 129), "Valid\0" }
    local item = assert(Recommendations.normalize(context({ raw }))).items[1]
    check(item.title == "A Title" and item.extra.evaluate == nil)
    check(#item.extra.tags == 2 and item.extra.tags[1] == "One Tag" and item.extra.tags[2] == "Valid")
end)

test("Transport HTTP and malformed JSON errors remain actionable", function()
    for _, status in ipairs({ 301, 401, 429, 500 }) do
        local client, transport = fixture("{}", status)
        local value, err = client:recommendations()
        check(value == nil and err.kind == "http" and err.status == status and transport.calls == 1)
        check(err.retryable == (status == 429 or status >= 500))
    end
    for _, body in ipairs({ "<html>Unavailable</html>", "null", "[]", string.rep(" ", Recommendations.max_bytes + 1) }) do
        local client = fixture(body)
        local value, err = client:recommendations()
        check(value == nil and err.kind == "protocol")
    end
    local expected = { kind = "network", retryable = true, message = "Synthetic offline state" }
    local value, err = Recommendations.fetch({ request = function() return nil, expected end })
    check(value == nil and err == expected)
end)

local function groupedComic(id, title)
    local value = comic(nil, title)
    value.comic_id, value.comic_introduction = id, "Official section introduction."
    value.evaluate = "An unrelated field must not replace the observed section introduction."
    return value
end

test("Expanded homepage sections retain official section and group order", function()
    local raw = context({ comic(90, "Original recommendation") })
    raw.data.hotSeller = { firstGroup = { groupedComic(40, "First bestseller") }, secondGroup = { groupedComic(10) } }
    raw.data.internetHot = { firstGroup = { groupedComic(70) }, secondGroup = { groupedComic(30) } }
    raw.data.completedComic = { firstGroup = { groupedComic(60) }, secondGroup = { groupedComic(20) } }
    local feed = assert(Recommendations.normalize(raw))
    local expected_ids = { "90", "40", "10", "70", "30", "60", "20" }
    local expected_sections = { "recommendation", "hot_seller", "hot_seller", "internet_hot", "internet_hot", "completed", "completed" }
    check(#feed.items == #expected_ids)
    for index, item in ipairs(feed.items) do
        check(item.id == expected_ids[index])
        check(item.extra.recommendation_section == expected_sections[index])
    end
    check(feed.items[2].extra.evaluate == "Official section introduction.")
    check(feed.items[2].extra.recommendation == feed.items[2].extra.evaluate)
    check(feed.items[6].finished == nil, "Editorial placement cannot infer stored comic completion state")
end)

test("Duplicates retain their first valid occurrence across every selected section", function()
    local raw = context({ comic(90, "Original title") })
    local invalid = groupedComic(12, " ")
    raw.data.hotSeller = { firstGroup = { groupedComic(90, "Later title"), invalid }, secondGroup = { groupedComic(40, "First title") } }
    raw.data.internetHot = { firstGroup = { groupedComic(12, "Recovered title"), groupedComic(40, "Duplicate title") }, secondGroup = {} }
    raw.data.completedComic = { firstGroup = { groupedComic(12) }, secondGroup = { groupedComic(30) } }
    local feed = assert(Recommendations.normalize(raw))
    check(#feed.items == 4)
    check(feed.items[1].id == "90" and feed.items[1].title == "Original title" and feed.items[1].extra.recommendation_section == "recommendation")
    check(feed.items[2].id == "40" and feed.items[2].title == "First title" and feed.items[2].extra.recommendation_section == "hot_seller")
    check(feed.items[3].id == "12" and feed.items[3].title == "Recovered title" and feed.items[3].extra.recommendation_section == "internet_hot")
    check(feed.items[4].id == "30" and feed.items[4].extra.recommendation_section == "completed")
end)

test("Optional missing or malformed groups preserve the compatible original feed", function()
    local raw = context({ comic(5) })
    local legacy = assert(Recommendations.normalize(raw))
    check(#legacy.items == 1 and legacy.items[1].extra.recommendation_section == "recommendation")
    raw.data.hotSeller = false
    raw.data.internetHot = { firstGroup = { unexpected = groupedComic(1) }, secondGroup = { groupedComic(6) } }
    raw.data.completedComic = { firstGroup = false }
    local feed = assert(Recommendations.normalize(raw))
    check(#feed.items == 2 and feed.items[1].id == "5" and feed.items[2].id == "6")
    local empty_original = context({})
    empty_original.data.hotSeller = { firstGroup = { groupedComic(8) }, secondGroup = {} }
    check(assert(Recommendations.normalize(empty_original)).items[1].id == "8")
end)

test("Advertisement cards rankings and unobserved section aliases never enter the feed", function()
    local raw = context({ comic(5) })
    raw.data.banner = { { list = { { type = 0, card = { title = "Advertisement", jump_url = "https://example.com/" } },
        { type = 1, comic = groupedComic(8) } } } }
    raw.data.ranking = { JP = { groupedComic(9) }, CN = { groupedComic(10) }, KO = { groupedComic(11) } }
    raw.data.newComics = { groupedComic(12) }
    raw.data.hotSeller = { firstGroup = { comic(13), groupedComic("bad") }, secondGroup = {} }
    local feed = assert(Recommendations.normalize(raw))
    check(#feed.items == 1 and feed.items[1].id == "5")
    check(feed.personalized == false and feed.has_more == false and feed.source == "official_homepage")
end)

test("The expanded response limit counts distinct valid comics without changing order", function()
    local first, second = {}, {}
    for index = 1, 120 do
        first[#first + 1] = groupedComic(index)
        second[#second + 1] = groupedComic(index)
    end
    local raw = context({ comic(200) })
    raw.data.hotSeller = { firstGroup = first, secondGroup = second }
    local feed = assert(Recommendations.normalize(raw))
    check(Recommendations.max_items == 96 and #feed.items == 96)
    check(feed.items[1].id == "200" and feed.items[2].id == "1" and feed.items[96].id == "95")
end)

test("The larger response still uses exactly one anonymous request", function()
    local raw = context({ comic(90) })
    raw.data.hotSeller = { firstGroup = { groupedComic(40) }, secondGroup = { groupedComic(10) } }
    local client, transport = fixture(assert(JSON.encode(raw)))
    local feed = assert(client:recommendations())
    check(#feed.items == 3 and transport.calls == 1)
    check(client._session_changed == nil and client.session.cookies.SESSDATA == "synthetic-recommendation-session")
end)

if live_fixture then
    test("The anonymously captured official response matches the implemented contract", function()
        local handle = assert(io.open(live_fixture, "rb"))
        local body = handle:read("*a")
        handle:close()
        local raw = assert(JSON.decode(body))
        local feed = assert(Recommendations.normalize(raw))
        local ordered, seen, selected = {}, {}, { raw.data.recommendation.comics }
        for _, name in ipairs({ "hotSeller", "internetHot", "completedComic" }) do
            local block = raw.data[name]
            if type(block) == "table" then
                selected[#selected + 1], selected[#selected + 2] = block.firstGroup, block.secondGroup
            end
        end
        for _, group in ipairs(selected) do
            for _, item in ipairs(group) do
                local id = tostring(item.id or item.comic_id)
                if not seen[id] then seen[id] = true; ordered[#ordered + 1] = id end
            end
        end
        check(#feed.items > 0 and #feed.items == math.min(#ordered, Recommendations.max_items))
        for index, item in ipairs(feed.items) do
            check(item.id == ordered[index])
        end
    end)
end

local passed = true
for _, case in ipairs(cases) do passed = passed and case.passed end
check(network_attempts == 0)
local handle = assert(io.open(output .. "/" .. result_name, "wb"))
handle:write(assert(JSON.encode({ passed = passed, assertions = assertions, cases = cases,
    fake_transport_calls = requests, real_transport_attempts = network_attempts,
    live_fixture_checked = live_fixture ~= nil })))
handle:close()
assert(passed, "Recommendation protocol contract checks failed")
