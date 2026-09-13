-- Run only in the remote KOReader runtime with an isolated network namespace.
require("setupkoenv")
local root, output = assert(arg[1]), assert(arg[2])
package.path = root .. "/?.lua;" .. package.path
local JSON = require("bilicomics/protocol/json")
local current_transport, encrypted_data
local report = { passed = false, assertions = 0, cases = {}, fake_transport_calls = 0,
    account_sessions_read = 0, real_transport_attempts = 0 }
local data_sn = "1E74C20E5720FBF3BB351965D7A9DFC1"
local m2 = "error:BiliComics local reader has no browser fingerprint environment_1800000000000"
local crypto = {
    prepareCatalog = function() return { m2 = m2 } end,
    signRequest = function(_, context)
        assert(context.endpoint == "ClassPage" and context.buvid:match("^issued_"))
        assert(JSON.decode(context.body).m2 == m2)
        return { ultra_sign = "synthetic-signature", data_sn = data_sn }
    end,
    decodeResponse = function(_, context)
        assert(context.buvid:match("^issued_") and encrypted_data)
        return { code = 0, data = encrypted_data }
    end,
}
package.loaded["bilicomics/protocol/crypto"] = { new = function() return crypto end }
package.loaded["bilicomics/protocol/transport"] = { new = function()
    if not current_transport then report.real_transport_attempts = report.real_transport_attempts + 1; error("A fake transport is required") end
    return current_transport
end }
local Client = require("bilicomics/protocol/client")
local Categories = require("bilicomics/protocol/categories")
local Worker = require("bilicomics/jobs/worker")

local function check(condition, message)
    report.assertions = report.assertions + 1
    assert(condition, message or "Category contract assertion failed")
end
local function test(name, callback)
    local ok, err = pcall(callback)
    report.cases[#report.cases + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    print((ok and "PASS " or "FAIL ") .. name .. (not ok and ": " .. tostring(err) or ""))
end
local function comic(id)
    return { season_id = id, type = 0, title = "Official example", vertical_cover = "http://i0.hdslb.com/bfs/manga-static/example.jpg",
        introduction = "A short introduction.", evaluate = "The complete public description.", author = { "Example author" },
        is_finish = 1, styles = { "Official genre" }, bottom_info_v2 = { "Tag", "Tag" }, rd_tag = "Second tag", total = 99999 }
end
local function metadata()
    return { styles = { { id = 999, name = "Genre A" }, { id = 1015, name = "Genre B" } },
        orders = { { id = 0, name = "Popularity recommendations" }, { id = 1, name = "Updated" }, { id = 3, name = "Added" } } }
end
local function fixture()
    local transport = { requests = {}, device_count = 0, page_count = 0, data = { comic(51) }, metadata = metadata() }
    function transport:request(request)
        report.fake_transport_calls = report.fake_transport_calls + 1
        self.requests[#self.requests + 1] = request
        for key in pairs(request.headers or {}) do
            local lower = key:lower()
            check(lower ~= "authorization" and lower ~= "x-xsrf-token")
        end
        if self.failure then return nil, self.failure end
        if request.url == Categories.metadata_url then
            check(request.method == "POST" and request.body == "{}" and request.headers.cookie == nil and request.output_path == nil)
            check(request.max_bytes == 1024 * 1024)
            return { status = self.status or 200, body = self.raw or assert(JSON.encode({ code = self.code or 0, data = self.metadata })),
                headers = { ["set-cookie"] = "SESSDATA=ignored" } }
        elseif request.url == Categories.device_url then
            self.device_count = self.device_count + 1
            check(request.method == "GET" and request.body == nil and request.headers.cookie == nil and request.output_path == nil)
            check(request.max_bytes == 65536)
            local cookies = self.device_cookies or { "SESSDATA=ignored; Path=/", "buvid3=issued_" .. self.device_count .. "; Path=/" }
            return { status = self.device_status or 200, body = "{}", headers = { ["set-cookie"] = cookies } }
        end
        self.page_count = self.page_count + 1
        check(request.url == Categories.page_url .. "synthetic-signature" and request.method == "POST")
        check(request.headers.cookie == "buvid3=issued_" .. self.device_count and request.headers["x-bili-data-sn"] == data_sn)
        check(request.output_path == nil and request.max_bytes == 4 * 1024 * 1024)
        local body = assert(JSON.decode(request.body))
        for key in pairs(body) do
            check(({style_id=true,area_id=true,is_finish=true,order=true,special_tag=true,page_num=true,page_size=true,is_free=true,m2=true})[key])
        end
        check(body.area_id == -1 and body.is_finish == -1 and body.is_free == -1 and body.special_tag == 0)
        check(body.page_size == 18 and body.m2 == m2 and body.style_id == (self.style_id or 999))
        check(body.order == (self.sort or 0) and body.page_num == (self.page or 1))
        return { status = self.page_status or 200, body = self.page_raw or assert(JSON.encode({ code = self.page_code or 0, data = self.data })),
            headers = { ["set-cookie"] = { "SESSDATA=ignored", "buvid3=replaced_cookie" } } }
    end
    current_transport = transport
    local client = Client.new{ transport = transport, crypto = crypto, clock = function() return 1800000000 end }
    local poison = setmetatable({}, { __index = function()
        report.account_sessions_read = report.account_sessions_read + 1
        error("Parent account session access is forbidden")
    end })
    client.session = poison
    client._headers = function() error("Parent headers are forbidden") end
    client._captureCookies = function() error("Parent cookie capture is forbidden") end
    client._post = function() error("The parent cannot perform the guest ClassPage request") end
    return client, transport, poison
end

test("Official metadata remains anonymous and preserves its actual category order", function()
    local client, transport, poison = fixture()
    transport.metadata.styles[#transport.metadata.styles + 1] = { id = 999, name = "Duplicate" }
    transport.metadata.styles[#transport.metadata.styles + 1] = { id = 0, name = "Invalid" }
    local value = assert(client:bookstoreCategories())
    check(value.source == "official_categories" and #value.items == 2 and #value.orders == 3)
    check(value.items[1].id == "999" and value.items[2].id == "1015" and value.items[1].name == "Genre A")
    check(value.orders[1].id == 0 and value.orders[2].id == 1 and value.orders[3].id == 3)
    check(client.session == poison and client._session_changed == nil and #transport.requests == 1)
end)

test("Malformed metadata and scalar JSON return protocol errors without throwing", function()
    for _, raw in ipairs({ "false", "42", '"text"', "null", "[]", "{}", '{"code":0,"data":{"styles":[],"orders":[]}}',
        '{"code":0,"data":{"styles":[{"id":999,"name":"Example"}],"orders":[{"id":2,"name":"Unsupported"}]}}' }) do
        local client = fixture(); current_transport.raw = raw
        local value, err = client:bookstoreCategories()
        check(value == nil and err.kind == "protocol")
    end
end)

test("Invalid query fields and page bounds are rejected before device initialization", function()
    for _, value in ipairs({ {query=false}, {query={}}, {query={category_id="0999"}}, {query={category_id="999",kind="history"}},
        {query={category_id="999",sort=2}}, {query={category_id="999",sort="0"}}, {query={category_id="999",area_id=1}},
        {query={category_id="999"},page=0}, {query={category_id="999"},page=6}, {query={category_id="999"},page=1.5},
        {query={category_id="999"},page="1"} }) do
        local client, transport = fixture()
        local result, err = client:bookstoreCategoryPage(value.query, value.page)
        check(result == nil and err.kind == "invalid_request" and err.transmitted == false and #transport.requests == 0)
    end
end)

test("Each supported official sort uses a canonical query and fixed noncategory dimensions", function()
    for _, sort in ipairs({0,1,3}) do
        local client, transport = fixture(); transport.sort = sort
        local page = assert(client:bookstoreCategoryPage({category_id=999,sort=sort},1))
        check(page.source == "official_category" and page.personalized == false)
        check(page.query.kind == "category" and page.query.category_id == "999" and page.query.sort == sort)
        check(page.page == 1 and page.page_size == 18 and page.has_more == true and #page.items == 1)
        check(transport.device_count == 1 and transport.page_count == 1)
    end
end)

test("Each page creates a fresh guest device cookie without reading or changing the parent", function()
    local client, transport, poison = fixture()
    assert(client:bookstoreCategoryPage({category_id="999"}))
    transport.page = 2
    assert(client:bookstoreCategoryPage({kind="category",category_id="999",sort=0},2))
    check(transport.device_count == 2 and transport.page_count == 2 and #transport.requests == 4)
    check(transport.requests[2].headers.cookie == "buvid3=issued_1" and transport.requests[4].headers.cookie == "buvid3=issued_2")
    check(client.session == poison and client._session_changed == nil and report.account_sessions_read == 0)
end)

test("Missing conflicting and malformed anonymous cookies stop before ClassPage", function()
    for _, cookies in ipairs({ {}, {"SESSDATA=ignored"}, {"buvid3="}, {"buvid3=bad value"}, {"buvid3=bad,other=1"},
        {"buvid3=issued_1\r\nSESSDATA=bad"}, {"buvid3=" .. string.rep("x",257)},
        {"buvid3=issued_1", "buvid3=issued_2"}, { false } }) do
        local client, transport = fixture(); transport.device_cookies = cookies
        local result, err = client:bookstoreCategoryPage({category_id="999"},1)
        check(result == nil and err.kind == "protocol" and transport.device_count == 1 and transport.page_count == 0)
    end
end)

test("Category metadata retains public display fields and rejects query-bearing covers", function()
    local client, transport = fixture()
    local duplicate, wrong_type, bad_cover = comic(51), comic(52), comic(53)
    duplicate.title = "Later duplicate"; wrong_type.type = 1; bad_cover.vertical_cover = bad_cover.vertical_cover .. "?token=discard"
    transport.data = { comic(51), duplicate, wrong_type, bad_cover }
    local page = assert(client:bookstoreCategoryPage({category_id="999"},1))
    local item = page.items[1]
    check(#page.items == 1 and item.id == "51" and item.title == "Official example")
    check(item.cover_url == "https://i0.hdslb.com/bfs/manga-static/example.jpg" and item.authors[1] == "Example author" and item.finished == true)
    check(item.extra.recommendation == "A short introduction." and item.extra.evaluate == "The complete public description.")
    check(#item.extra.tags == 2 and item.extra.tags[1] == "Tag" and item.extra.tags[2] == "Second tag")
    check(item.extra.category_id == "999" and item.extra.category_names[1] == "Official genre")
    check(item.favorite == nil and item.read == nil and item.total == nil and item.extra.cookie == nil)
end)

test("Pagination follows raw array emptiness rather than comic chapter totals or short pages", function()
    local client, transport = fixture(); transport.data[1].total = 0
    check(assert(client:bookstoreCategoryPage({category_id="999"},1)).has_more == true)
    transport.data = JSON.array({}); transport.page = 2
    local page = assert(client:bookstoreCategoryPage({category_id="999"},2))
    check(page.has_more == false and #page.items == 0 and page.page == 2)
    transport.data = {}; for index=1,19 do transport.data[index]=comic(index) end
    local result, err = client:bookstoreCategoryPage({category_id="999"},2)
    check(result == nil and err.kind == "protocol")
    transport.page_raw = '{"code":0,"data":{}}'
    result, err = client:bookstoreCategoryPage({category_id="999"},2)
    check(result == nil and err.kind == "protocol", "A JSON object must not masquerade as an empty result array")
end)

test("Encrypted pages use the issued device context and never persist response cookies", function()
    local client, transport, poison = fixture()
    encrypted_data = { comic(72) }; transport.page_raw = '{"code":0,"data":null,"bytesData":"synthetic-encrypted-page"}'
    local page = assert(client:bookstoreCategoryPage({category_id="999"},1))
    check(page.items[1].id == "72" and client.session == poison and client._session_changed == nil)
    encrypted_data = nil
end)

test("Transport and service failures remain explicit without account fallback", function()
    local client, transport = fixture(); transport.device_status = 503
    local value, err = client:bookstoreCategoryPage({category_id="999"},1)
    check(value == nil and err.kind == "http" and err.retryable == true and transport.page_count == 0)
    client, transport = fixture(); transport.page_code = 99
    value, err = client:bookstoreCategoryPage({category_id="999"},1)
    check(value == nil and err.kind == "business" and err.code == 99 and transport.device_count == 1 and transport.page_count == 1)
    client, transport = fixture(); transport.failure = {kind="network",retryable=true}
    value, err = client:bookstoreCategories()
    check(value == nil and err == transport.failure)
end)

test("Production Worker discards supplied login sessions and returns no guest session update", function()
    fixture()
    local value, err, update = Worker.execute({kind="client",method="bookstoreCategories",arguments={},
        session={cookies={SESSDATA="synthetic-account-session",bili_jct="synthetic-csrf"}}})
    check(value and not err and update == nil and value.source == "official_categories")
    fixture()
    value, err, update = Worker.execute({kind="client",method="bookstoreCategoryPage",arguments={{category_id="999"},1},
        session={cookies={SESSDATA="synthetic-account-session",bili_jct="synthetic-csrf"}}})
    check(value and not err and update == nil and value.items[1].id == "51")
    check(current_transport.requests[1].headers.cookie == nil and current_transport.requests[2].headers.cookie == "buvid3=issued_1")
end)

report.passed = true
for _, case in ipairs(report.cases) do report.passed = report.passed and case.passed end
check(report.real_transport_attempts == 0 and report.account_sessions_read == 0)
local file = assert(io.open(output .. "/bookstore-categories-result.json","wb"))
file:write(assert(JSON.encode(report)));file:close()
assert(report.passed, "Category protocol checks failed")
