-- Run only inside the isolated test-env KOReader runtime.
require("setupkoenv")
local source_root, output = assert(arg[1]), assert(arg[2])
package.path = source_root .. "/?.lua;" .. package.path

local json = require("rapidjson")
local bit = require("bit")
local Files = require("bilicomics/storage/files")
local assertions, temporary_paths = {}, {}
local scenario
local protocol_key = "bilicomics/protocol/client"
local original_client = package.loaded[protocol_key]
package.loaded[protocol_key] = { new = function(options)
    assert(scenario, "A client scenario is required")
    scenario.options = options
    scenario.constructions = scenario.constructions + 1
    return scenario.client
end }
local Worker = require("bilicomics/jobs/worker")
package.loaded[protocol_key] = original_client

local method_names = {
    "listFavorites", "listHistory", "recommendations", "search", "comicDetail", "imageIndex", "wallet",
    "purchaseInfo", "validateSession", "buyEpisode", "imageTokens", "downloadImage", "addHistory",
    "getRechargeConfig", "rechargeHistory", "createRechargeOrder",
}

local function check(name, condition)
    assertions[#assertions + 1] = { name = name, passed = not not condition }
end

local function run(name, callback)
    local ok, err = xpcall(callback, debug.traceback)
    if not ok then assertions[#assertions + 1] = { name = name .. " completes", passed = false, error = tostring(err) } end
end

local function client(methods, session)
    scenario = { client = { session = session }, calls = {}, constructions = 0 }
    for _, name in ipairs(method_names) do
        local method = name
        scenario.client[method] = function(self, ...)
            assert(self == scenario.client, "The protocol method must receive its client")
            local arguments = { ... }
            scenario.calls[#scenario.calls + 1] = { method = method, arguments = arguments }
            assert(methods[method], "Unexpected protocol call: " .. method)
            return methods[method](...)
        end
    end
    return scenario
end

local function temporary(name, data)
    local path = output .. "/worker-" .. name .. ".part"
    temporary_paths[#temporary_paths + 1] = path
    if data then Files.write(path, data) else os.remove(path) end
    return path
end

local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function errorValue(kind)
    return { kind = kind, message = "Synthetic protocol failure", transmitted = true, retryable = false }
end

local function fullPage(start)
    local items = {}
    for i = 1, 50 do items[i] = { id = tostring(start + i), title = "Comic " .. (start + i) } end
    return items
end

local function uint32be(value)
    return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256, value % 256)
end

local function crc32(data)
    local crc = -1
    for i = 1, #data do
        crc = bit.bxor(crc, data:byte(i))
        for _ = 1, 8 do
            crc = bit.bxor(bit.rshift(crc, 1), bit.band(crc, 1) == 1 and 0xedb88320 or 0)
        end
    end
    return bit.bnot(crc) % 4294967296
end

run("Invalid worker requests", function()
    client({})
    check("A non-table request is rejected before constructing a client", not pcall(Worker.execute, "bad")
        and scenario.constructions == 0)
    local result, err = Worker.execute({ kind = "unrecognized" })
    check("Unknown operations return invalid_request without a protocol call", result == nil
        and err.kind == "invalid_request" and #scenario.calls == 0)
end)

run("Read-only operation whitelist", function()
    for _, method in ipairs({ "buyEpisode", "addHistory", "setFavorite", "downloadImage", "imageTokens", "createRechargeOrder", "new", "missing" }) do
        client({})
        local result, err = Worker.execute({ kind = "client", method = method, arguments = { "10" } })
        check("Read workers reject " .. method, result == nil and err.kind == "invalid_request" and #scenario.calls == 0)
    end
    for _, method in ipairs({ "listFavorites", "listHistory", "recommendations", "search", "comicDetail", "imageIndex", "wallet", "purchaseInfo",
        "getRechargeConfig", "rechargeHistory" }) do
        local expected, first, second = { marker = method }, { page_num = 7 }, "second-argument"
        client({ [method] = function(a, b)
            check(method .. " preserves the request arguments", a == first and b == second)
            return expected
        end })
        local result, err = Worker.execute({ kind = "client", method = method, arguments = { first, second },
            session = { cookies = { SESSDATA = "synthetic-session" } }, asset_root = "/synthetic/protocol-assets",
            transport_options = { timeout = 9 } })
        check(method .. " returns its read result", result == expected and err == nil and #scenario.calls == 1)
        local expected_session = method == "recommendations" and scenario.options.session == nil
            or method ~= "recommendations" and scenario.options.session.cookies.SESSDATA == "synthetic-session"
        check(method .. " constructs an isolated client with the expected configuration", scenario.constructions == 1
            and expected_session
            and scenario.options.transport_options.timeout == 9 and scenario.options.asset_root == "/synthetic/protocol-assets")
    end
end)

run("Session validation result", function()
    local summary, serialized = { account_key = "account-a" }, { account_key = "account-a", cookies = {} }
    local serializations = 0
    client({ validateSession = function() return summary end }, { serialize = function()
        serializations = serializations + 1
        return serialized
    end })
    local result, err = Worker.execute({ kind = "client", method = "validateSession" })
    check("Validated sessions return both identity and the updated serialized session", result.summary == summary
        and result.session == serialized and err == nil and serializations == 1)
    local expected_error = errorValue("authentication")
    client({ validateSession = function() return nil, expected_error end })
    result, err = Worker.execute({ kind = "client", method = "validateSession" })
    check("Validation failure does not serialize a missing session", result == nil and err == expected_error)
end)

run("Read error propagation", function()
    local expected_error = errorValue("authentication")
    client({ wallet = function() return nil, expected_error end })
    local result, err = Worker.execute({ kind = "client", method = "wallet" })
    check("Read failures retain structured protocol evidence", result == nil and err == expected_error)
end)

run("Favorites pagination and deduplication", function()
    local first = fullPage(0)
    first[49], first[50] = { id = "1", title = "Repeated" }, { id = "" }
    client({ listFavorites = function(options)
        check("Favorites request page " .. options.page_num .. " has a bounded page size", options.page_size == 50)
        if options.page_num == 1 then return first end
        if options.page_num == 2 then return { { id = "48" }, { id = "49" }, {} } end
        error("Unexpected extra library page")
    end })
    local result, err = Worker.execute({ kind = "library", library = "favorites" })
    check("Favorites stop after a partial page", result and #scenario.calls == 2 and err == nil)
    check("Library duplicates and absent identifiers are removed in first-seen order", result and #result == 49
        and result[1].title == "Comic 1" and result[48].id == "48" and result[49].id == "49")
end)

run("History pagination convergence", function()
    local page = fullPage(0)
    client({ listHistory = function(options)
        check("History page numbering is sequential", options.page_num == #scenario.calls and options.page_size == 50)
        return page
    end })
    local result, err = Worker.execute({ kind = "library", library = "history" })
    check("A repeated full library page terminates without duplicates", result and #result == 50
        and #scenario.calls == 2 and err == nil)
end)

run("Empty and failed library refreshes", function()
    client({ listHistory = function() return {} end })
    local result, err = Worker.execute({ kind = "library", library = "history" })
    check("An empty library succeeds after one request", result and #result == 0 and err == nil and #scenario.calls == 1)
    local expected_error = errorValue("http")
    client({ listFavorites = function(options)
        if options.page_num == 1 then return fullPage(0) end
        return nil, expected_error
    end })
    result, err = Worker.execute({ kind = "library", library = "favorites" })
    check("A later page failure never publishes a partial library", result == nil and err == expected_error and #scenario.calls == 2)
end)

run("Library response bound", function()
    client({ listFavorites = function(options) return fullPage((options.page_num - 1) * 50) end })
    local result, err = Worker.execute({ kind = "library", library = "favorites" })
    check("Unbounded library responses stop at 200 pages with an explicit error", result == nil
        and err.kind == "response_limit" and #scenario.calls == 200)
end)

run("Invalid library selection", function()
    for _, value in ipairs({ "favorite", "unexpected", false }) do
        client({ listHistory = function() return {} end })
        local result, err = Worker.execute({ kind = "library", library = value })
        check("Invalid library selection " .. tostring(value) .. " cannot silently read history", result == nil
            and err and err.kind == "invalid_request" and #scenario.calls == 0)
    end
    client({ listHistory = function() return {} end })
    local result, err = Worker.execute({ kind = "library" })
    check("Missing library selection is rejected", result == nil and err and err.kind == "invalid_request" and #scenario.calls == 0)
end)

run("Quote composition", function()
    local info = { ep_id = "10", comic_id = "1", ep_original_gold = 25, original_gold = 100, batch_buy = {} }
    local range = { ep_id = "10", comic_id = "1", amount = 25 }
    local detail = { comic = { id = "1" }, episodes = { { id = "10", comic_id = "1", order = 1, access = "locked" } } }
    local scope = { kind = "single", order = 2 }
    client({ purchaseInfo = function(episode_id, received_scope)
        if #scenario.calls == 1 then
            check("Quote first retrieves the basic episode offer without a range", episode_id == "10" and received_scope == nil)
            return info
        end
        check("Quote retrieves the selected range through its normalized wire scope", episode_id == "10"
            and received_scope.kind == "single" and received_scope.buy_type == 1
            and received_scope.order == 2 and received_scope.batch_limit == nil)
        return range
    end, comicDetail = function(comic_id)
        check("Quote retrieves the requested comic detail", comic_id == "1")
        return detail
    end })
    local result, err = Worker.execute({ kind = "quote", episode_id = "10", comic_id = "1", scope = scope })
    check("Quote joins both source responses without a purchase call", result and result.info == info
        and result.detail == detail and err == nil and #scenario.calls == 3
        and scenario.calls[1].method == "purchaseInfo" and scenario.calls[2].method == "comicDetail"
        and scenario.calls[3].method == "purchaseInfo")
    check("Quote keeps basic and range observations associated with the copied selection", result
        and result.context.range_info == range and result.context.selection.scope ~= scope
        and result.context.selection.scope.kind == "single" and result.context.selection.scope.order == 2
        and result.context.episode_id == "10" and result.context.comic_id == "1")
end)

run("Quote failure boundaries", function()
    client({})
    local rejected, selection_error = Worker.execute({ kind = "quote", episode_id = "10", comic_id = "1",
        scope = { batch_limit = 10 } })
    check("A single quote cannot smuggle batch fields into the read collector", rejected == nil
        and selection_error.kind == "invalid_scope" and #scenario.calls == 0)
    local expected_error = errorValue("http")
    client({ purchaseInfo = function() return nil, expected_error end })
    local result, err = Worker.execute({ kind = "quote", episode_id = "10", comic_id = "1" })
    check("Quote failure skips comic detail and retains its error", result == nil and err == expected_error and #scenario.calls == 1)
    client({ purchaseInfo = function() return {} end, comicDetail = function() return nil, expected_error end })
    result, err = Worker.execute({ kind = "quote", episode_id = "10", comic_id = "1" })
    check("Comic detail failure does not publish an incomplete quote", result == nil and err == expected_error and #scenario.calls == 2)
end)

run("Purchase intent boundary", function()
    local requests = {
        { kind = "purchase_submit", payload = {} },
        { kind = "purchase_submit", intent_id = 1, payload = {} },
        { kind = "purchase_submit", intent_id = "", payload = {} },
        { kind = "purchase_submit", intent_id = "intent-a" },
        { kind = "purchase_submit", intent_id = "intent-a", payload = "not-a-payload" },
    }
    for index, request in ipairs(requests) do
        client({ buyEpisode = function() return { accepted = true } end })
        local result, err = Worker.execute(request)
        check("Malformed purchase intent " .. index .. " cannot transmit", result == nil and err
            and err.kind == "confirmation_required" and err.transmitted == false and #scenario.calls == 0)
    end
    local payload, expected = { ep_id = 10, buy_method = 3, pay_amount = 25 }, { accepted = true }
    client({ buyEpisode = function(received)
        check("Confirmed purchase payload is forwarded exactly once", received == payload)
        return expected
    end })
    local result, err = Worker.execute({ kind = "purchase_submit", intent_id = "intent-a", payload = payload })
    check("A valid intent returns the purchase response", result == expected and err == nil and #scenario.calls == 1)
    local uncertain = errorValue("timeout")
    client({ buyEpisode = function() return nil, uncertain end })
    result, err = Worker.execute({ kind = "purchase_submit", intent_id = "intent-b", payload = payload })
    check("An uncertain purchase response is propagated without retry", result == nil and err == uncertain and #scenario.calls == 1)
end)

run("Recharge intent boundary", function()
    local fingerprint = string.rep("a", 64)
    local requests = {
        { kind = "recharge", amount_cents = 500, option_fingerprint = fingerprint },
        { kind = "recharge", local_id = 1, amount_cents = 500, option_fingerprint = fingerprint },
        { kind = "recharge", local_id = "", amount_cents = 500, option_fingerprint = fingerprint },
        { kind = "recharge", local_id = "recharge-1", amount_cents = 500 },
        { kind = "recharge", local_id = "recharge-1", amount_cents = 500, option_fingerprint = 123 },
        { kind = "recharge", local_id = "recharge-1", amount_cents = 500, option_fingerprint = "" },
        { kind = "recharge", local_id = "recharge-1", amount_cents = 500, option_fingerprint = string.rep("a", 63) },
        { kind = "recharge", local_id = "recharge-1", amount_cents = 500, option_fingerprint = string.rep("a", 65) },
    }
    for index, request in ipairs(requests) do
        client({})
        local result, err = Worker.execute(request)
        check("Malformed recharge intent " .. index .. " cannot call order creation", result == nil and err
            and err.kind == "confirmation_required" and err.transmitted == false and err.definitive == true
            and #scenario.calls == 0)
    end

    local order_id = "900719925474099312345678901234567890"
    local expected = { order_id = order_id, code_url = "weixin://synthetic-only/recharge", qr_validated = true, amount_cents = 500 }
    client({ createRechargeOrder = function(cents, received_fingerprint, extra)
        check("Recharge forwards the confirmed cents and fingerprint without a local journal identifier",
            cents == 500 and received_fingerprint == fingerprint and extra == nil)
        return expected
    end })
    local result, err = Worker.execute({ kind = "recharge", local_id = "recharge-1", amount_cents = 500,
        option_fingerprint = fingerprint })
    check("A committed recharge intent invokes only one order creation", result == expected and err == nil
        and #scenario.calls == 1 and scenario.calls[1].method == "createRechargeOrder")
    check("Recharge returns the exact large order identity without numeric conversion", result
        and type(result.order_id) == "string" and result.order_id == order_id)

    local uncertain = errorValue("recharge_unknown")
    uncertain.order_id = order_id
    client({ createRechargeOrder = function() return nil, uncertain end })
    result, err = Worker.execute({ kind = "recharge", local_id = "recharge-2", amount_cents = 500,
        option_fingerprint = fingerprint })
    check("An unknown recharge result is propagated once without retry or substitute reads", result == nil
        and err == uncertain and err.order_id == order_id and #scenario.calls == 1
        and scenario.calls[1].method == "createRechargeOrder")
end)

run("Recharge cannot bypass the read-only worker kind", function()
    local fingerprint = string.rep("b", 64)
    client({})
    local result, err = Worker.execute({ kind = "client", method = "createRechargeOrder", arguments = { 500, fingerprint },
        local_id = "recharge-authorized-looking", amount_cents = 500, option_fingerprint = fingerprint })
    check("Even a complete recharge intent cannot authorize creation through a read worker", result == nil
        and err and err.kind == "invalid_request" and #scenario.calls == 0)
end)

run("Purchase reconciliation", function()
    local detail, unavailable = { episodes = { { id = "10", access = "owned" } } }, errorValue("http")
    client({ comicDetail = function() return detail end, wallet = function() return nil, unavailable end })
    local result, err = Worker.execute({ kind = "reconcile_purchase", comic_id = "1" })
    check("Wallet failure preserves independently observed episode rights", result and result.detail == detail
        and result.wallet == nil and result.wallet_error == unavailable and err == nil and #scenario.calls == 2)
    client({ comicDetail = function() return nil, unavailable end })
    result, err = Worker.execute({ kind = "reconcile_purchase", comic_id = "1" })
    check("Rights lookup failure skips wallet and preserves purchase uncertainty", result == nil and err == unavailable and #scenario.calls == 1)
end)

run("Page acquisition and bounded image headers", function()
    local fixture = Files.read(output .. "/fixtures/page-a.png")
    local path, token = temporary("page"), { url = "https://i0.hdslb.com/page", token = "synthetic-token" }
    client({ imageTokens = function(paths)
        check("Page acquisition asks for only the source image path", #paths == 1 and paths[1] == "/source/page-a")
        return { token }
    end, downloadImage = function(received, received_path, options)
        check("Page download uses its token, temporary path, index and byte limit", received == token
            and received_path == path and options.index == 7 and options.max_bytes == 12345)
        Files.write(path, fixture)
        return { temporary_path = path, width = 999, height = 999, checksum = "preserved" }
    end })
    local result, err = Worker.execute({ kind = "download_page", source_path = "/source/page-a",
        temporary_path = path, index = 7, max_bytes = 12345 })
    check("Successful page acquisition keeps the file for atomic storage commit", result and exists(path)
        and result.temporary_path == path and result.checksum == "preserved" and err == nil)
    check("Worker derives geometry from the actual PNG header", result and result.width == 40 and result.height == 80
        and result.geometry.source_width == 40 and result.geometry.source_height == 80 and result.geometry.exif_orientation == 1)
    check("Page acquisition orders token retrieval before downloading", #scenario.calls == 2
        and scenario.calls[1].method == "imageTokens" and scenario.calls[2].method == "downloadImage")
end)

run("Cover acquisition", function()
    local path, url = temporary("cover"), "https://i0.hdslb.com/cover.png"
    client({ downloadImage = function(token, received_path, options)
        check("Cover acquisition constructs a plain URL token", token.url == url and token.complete_url == nil
            and token.token == nil and token.hit_encrpyt == false)
        check("Image acquisition defaults to a bounded 32 MiB transfer", options.max_bytes == 32 * 1024 * 1024 and received_path == path)
        Files.write(path, Files.read(output .. "/fixtures/page-a.png"))
        return { temporary_path = path }
    end })
    local result, err = Worker.execute({ kind = "download_cover", url = url, temporary_path = path })
    check("Covers bypass the chapter token operation and retain parsed geometry", result and result.width == 40
        and result.height == 80 and err == nil and #scenario.calls == 1 and scenario.calls[1].method == "downloadImage")
end)

run("EXIF source and display geometry", function()
    local fixture = Files.read(output .. "/fixtures/page-a.png")
    local exif = "II\042\000\008\000\000\000\001\000\018\001\003\000\001\000\000\000\006\000\000\000\000\000\000\000"
    local chunk = "eXIf" .. exif
    local rotated = fixture:sub(1, 33) .. uint32be(#exif) .. chunk .. uint32be(crc32(chunk)) .. fixture:sub(34)
    local path = temporary("rotated")
    client({ downloadImage = function()
        Files.write(path, rotated)
        return { temporary_path = path }
    end })
    local result, err = Worker.execute({ kind = "download_cover", url = "https://i0.hdslb.com/rotated.png", temporary_path = path })
    check("EXIF rotation swaps display axes without losing source dimensions", result and result.width == 80
        and result.height == 40 and result.geometry.source_width == 40 and result.geometry.source_height == 80
        and result.geometry.exif_orientation == 6 and err == nil)
end)

run("Token acquisition failures", function()
    local unavailable, path = errorValue("token_expired"), temporary("token-failure")
    client({ imageTokens = function() return nil, unavailable end })
    local result, err = Worker.execute({ kind = "download_page", source_path = "/page", temporary_path = path })
    check("Token failure stops before file download", result == nil and err == unavailable and #scenario.calls == 1 and not exists(path))
    client({ imageTokens = function() return {} end })
    result, err = Worker.execute({ kind = "download_page", source_path = "/page", temporary_path = path })
    check("An empty token response produces a protocol error without downloading", result == nil
        and err.kind == "protocol" and #scenario.calls == 1 and not exists(path))
end)

run("Image header rejection cleanup", function()
    for _, name in ipairs({ "unsupported", "truncated" }) do
        local path = temporary(name)
        client({ downloadImage = function()
            local data = name == "unsupported" and "<html>Not an image</html>"
                or Files.read(output .. "/fixtures/page-a.png"):sub(1, 32)
            Files.write(path, data)
            return { temporary_path = path }
        end })
        local result, err = Worker.execute({ kind = "download_cover", url = "https://i0.hdslb.com/image", temporary_path = path })
        check("The worker rejects and removes " .. name .. " image data", result == nil and err.kind == "image" and not exists(path))
    end
end)

run("Failed image acquisition cleanup", function()
    local path, unavailable = temporary("download-failure"), errorValue("conversion")
    client({ downloadImage = function()
        Files.write(path, "incomplete conversion output")
        return nil, unavailable
    end })
    local result, err = Worker.execute({ kind = "download_cover", url = "https://i0.hdslb.com/image", temporary_path = path })
    check("Image acquisition failure preserves its structured error without retry", result == nil and err == unavailable and #scenario.calls == 1)
    check("A failed acquisition cannot leave an uncommitted temporary image", not exists(path))
end)

run("Mismatched image output path", function()
    local fixture = Files.read(output .. "/fixtures/page-a.png")
    local assigned = temporary("assigned-output", "incomplete assigned output")
    local foreign = temporary("foreign-output", fixture)
    local acquired = { temporary_path = foreign }
    client({ downloadImage = function(_, received_path)
        check("The mismatched-result scenario receives the assigned output path", received_path == assigned)
        return acquired
    end })
    local original_open, foreign_opens = io.open, 0
    io.open = function(path, ...)
        if path == foreign then foreign_opens = foreign_opens + 1 end
        return original_open(path, ...)
    end
    local ok, result, err = pcall(Worker.execute, { kind = "download_cover",
        url = "https://i0.hdslb.com/image", temporary_path = assigned })
    io.open = original_open
    check("An image result for another path returns worker_protocol without geometry", ok and result == nil
        and err and err.kind == "worker_protocol" and acquired.geometry == nil
        and acquired.width == nil and acquired.height == nil)
    check("A mismatched image result removes only its assigned partial output", not exists(assigned)
        and exists(foreign) and Files.read(foreign) == fixture)
    check("A mismatched foreign image is never opened for header inspection", foreign_opens == 0)
end)

for _, path in ipairs(temporary_paths) do os.remove(path) end
local failed = 0
for _, assertion in ipairs(assertions) do
    if not assertion.passed then failed = failed + 1 end
end
Files.write(output .. "/worker-result.json", json.encode({ assertions = assertions, passed = #assertions - failed,
    failed = failed, environment = "test-env", network = "injected protocol client; no live account, purchase or recharge" }, { pretty = true }))
print(json.encode({ suite = "worker", passed = #assertions - failed, failed = failed, result_path = output .. "/worker-result.json" }))
if failed > 0 then os.exit(1) end
