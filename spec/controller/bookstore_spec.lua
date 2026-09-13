-- Run only on test-env with synthetic accounts, real SQLite and controlled anonymous workers.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(require("datastorage"):getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. package.path
local Controller = require("bilicomics/controller")
local Bookstore = require("bilicomics/bookstore")
local Model = require("bilicomics/ui/model")
local Codec = require("bilicomics/storage/codec")
local CoverSource = require("bilicomics/cover_source")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local tests, contexts, sequence = {}, {}, 0

local function comic(id, title)
    return { id = tostring(id), title = title or "Recommended comic " .. id,
        cover_url = "https://i0.hdslb.com/bookstore-" .. id .. ".jpg",
        extra = { recommendation = "Official editorial description", evaluate = "Official editorial description",
            recommendation_section = "recommendation", tags = { "Adventure" } } }
end

local function feed(items)
    return { source = "official_homepage", personalized = false, has_more = false, items = items or { comic("101"), comic("102") } }
end

local function expandedFeed()
    local items = {}
    local function add(id, section)
        local item = comic(tostring(id))
        item.extra.recommendation_section = section
        items[#items + 1] = item
    end
    for id = 101, 107 do add(id, "recommendation") end
    for id = 108, 117 do add(id, "hot_seller") end
    add(101, "internet_hot")
    for id = 118, 126 do add(id, "internet_hot") end
    add(102, "completed"); add(108, "completed")
    for id = 127, 134 do add(id, "completed") end
    return feed(items)
end

local function fixture(root)
    sequence = sequence + 1
    local context = { now = 1000, callbacks = {}, maintenance = 0, serialized = 0, old_accounts = {} }
    local ui = { queue = {} }
    function ui:nextTick(callback) self.queue[#self.queue + 1] = callback end
    function ui:scheduleIn() end
    function ui:unschedule() end
    function ui:close() end
    function ui:drain()
        local limit = 1000
        while #self.queue > 0 do
            limit = limit - 1; assert(limit > 0, "Unbounded deferred work")
            table.remove(self.queue, 1)()
        end
    end
    local function runnerFactory()
        local runner = { tasks = {}, count = 0 }
        function runner:submit(request, options, callback)
            self.count = self.count + 1
            local task = { id = self.count, request = request, options = options, callback = callback }
            self.tasks[task.id] = task
            return task.id
        end
        function runner:find(kind, method)
            for _, task in pairs(self.tasks) do
                if task.request.kind == kind and (not method or task.request.method == method) then return task end
            end
            error("No pending worker: " .. kind .. "/" .. tostring(method))
        end
        function runner:start(task)
            local allowed, err = true
            if task.options.before_start then allowed, err = task.options.before_start() end
            if allowed ~= true then self:finish(task, nil, err); return false end
            task.started = true
            return true
        end
        function runner:finish(task, value, err)
            self.tasks[task.id] = nil
            task.callback(value, err)
            ui:drain()
        end
        function runner:cancel(task_id)
            local task = self.tasks[task_id]
            if task then self:finish(task, nil, { kind = "canceled" }) end
        end
        function runner:close() self.closed = true end
        function runner:promote() end
        function runner:suspend() self.suspended = true end
        function runner:resume() self.suspended = false end
        return runner
    end
    context.root = root or output .. "/bookstore-account-" .. sequence
    context.network = { connected = true }
    function context.network:isConnected() return self.connected end
    context.app = Controller.new{ root = context.root, ui_manager = ui, runner_factory = runnerFactory,
        network = context.network, clock = function() return context.now end }
    context.ui = ui
    function context:guardSession(state)
        self.app.account.session = state ~= "none" and { serialize = function()
            self.serialized = self.serialized + 1
            return { cookies = { SESSDATA = "synthetic-secret" } }
        end } or nil
        self.app.account.session_valid = state == "valid"
        self.app.account.authentication_invalidated = state == "invalidated"
        self.app.account.session_manager.ensure = function()
            self.maintenance = self.maintenance + 1
            error("Public bookstore requests must not maintain the account session")
        end
    end
    function context:callback(name)
        return function(value, err) self.callbacks[#self.callbacks + 1] = { name = name, value = value, error = err } end
    end
    function context:refresh(value, err)
        self.app:refreshBookstore(self:callback("refresh"))
        local runner = self.app.account.raw_runner
        local task = runner:find("client", "recommendations")
        assert(runner:start(task))
        runner:finish(task, value or (not err and feed()) or nil, err)
        return task
    end
    function context:coverResult(task)
        Files.write(task.request.temporary_path, Files.read(output .. "/fixture.png"))
        return { temporary_path = task.request.temporary_path, format = "png", width = 20, height = 40 }
    end
    context:guardSession("none")
    contexts[#contexts + 1] = context
    ui:drain()
    return context
end

local function test(name, callback)
    local ok, failure = xpcall(callback, debug.traceback)
    for _, context in ipairs(contexts) do
        pcall(context.app.close, context.app)
        for _, account in ipairs(context.old_accounts) do pcall(account.store.close, account.store) end
    end
    contexts = {}
    tests[#tests + 1] = { name = name, passed = ok, failure = not ok and tostring(failure) or nil }
end

test("Empty and cached bookstore getters never dispatch network requests", function()
    local context = fixture()
    local initial = context.app:getBookstore()
    assert(#initial.items == 0 and initial.stale and initial.updated_at == nil)
    assert(initial.source == "official_homepage" and initial.personalized == false and initial.has_more == false)
    assert(context.app.account.raw_runner.count == 0)
    context:refresh()
    local count = context.app.account.raw_runner.count
    local cached = context.app:getBookstore()
    assert(#cached.items == 2 and cached.updated_at == 1000 and cached.stale == false)
    assert(context.app.account.raw_runner.count == count)
end)

test("Anonymous valid expired and invalidated sessions all use raw anonymous recommendations", function()
    for _, state in ipairs({ "none", "valid", "expired", "invalidated" }) do
        local context = fixture()
        context:guardSession(state)
        local task = context:refresh()
        assert(task.request.session == nil and task.request.transport_options == nil)
        assert(task.request.public_bookstore == true and next(task.request.arguments) == nil)
        assert(context.maintenance == 0 and context.serialized == 0 and #context.app:getBookstore().items == 2)
        assert(next(context.app.account.read_requests) == nil)
    end
end)

test("Refresh coalesces callers into one request and retains first-seen official order", function()
    local context = fixture()
    context.app:refreshBookstore(context:callback("one"))
    context.app:refreshBookstore(context:callback("two"))
    context.app:refreshBookstore(context:callback("three"))
    local runner = context.app.account.raw_runner
    assert(runner.count == 1)
    local items = { comic("102"), comic("101"), comic("102", "Duplicate replacement") }
    for index = 103, 220 do items[#items + 1] = comic(tostring(index)) end
    runner:finish(runner:find("client", "recommendations"), feed(items))
    local saved = context.app:getBookstore()
    assert(#context.callbacks == 3 and #saved.items == 96)
    assert(saved.items[1].id == "102" and saved.items[2].id == "101" and saved.items[96].id == "196")
    assert(saved.items[1].title ~= "Duplicate replacement" and saved.has_more == false)
end)

test("Four homepage sections retain their order and first-occurrence provenance in one request", function()
    local context = fixture()
    context:guardSession("invalidated")
    context:refresh(expandedFeed())
    local saved = context.app:getBookstore()
    assert(#saved.items == 34 and context.app.account.raw_runner.count == 1)
    assert(saved.items[1].id == "101" and saved.items[34].id == "134")
    assert(saved.items[1].extra.recommendation_section == "recommendation")
    assert(saved.items[8].extra.recommendation_section == "hot_seller")
    assert(saved.items[18].extra.recommendation_section == "internet_hot")
    assert(saved.items[27].extra.recommendation_section == "completed")
    assert(saved.items[27].finished == nil and saved.items[27].favorite ~= true)
    assert(saved.items[27].reading_position == nil and not saved.personalized and not saved.has_more)
    assert(context.serialized == 0 and context.maintenance == 0)
    assert(context.app.account.store:getSetting(Bookstore.key).schema_version == 2)
end)

test("Recommendation refresh preserves favorites exact anchors and chapter state", function()
    local context = fixture()
    local account = context.app.account
    account.catalog:ingestDetail({ comic = { id = "101", title = "Owned title", favorite = true },
        episodes = { { id = "1001", comic_id = "101", order = 1, title = "Opening chapter", access = "free" } } })
    account.store:upsertComic{ id = "101", favorite = true, read = "retained-user-state" }
    local descriptor = { schema_version = 1, account_key = account.key, comic_id = "101", episode_id = "1001",
        revision = "local-version", pages = { { id = "page-1", index = 1, width = 20, height = 40 } } }
    account.pages:ensureDescriptor(descriptor)
    account.catalog:updatePosition(descriptor, { index = 1, page_id = "page-1", x = 0.2, y = 0.6, finished = false })
    local anchor = Codec.canonical(account.store:getAnchor("1001", "local-version"))
    local episode = Codec.canonical(account.store:getEpisode("1001"))
    local incoming = comic("101", "Refreshed editorial title")
    incoming.favorite, incoming.read, incoming.current_episode_id = false, false, "wrong"
    incoming.reading_position = { index = 999 }
    incoming.extra.reading_position, incoming.extra.progress_source = { index = 999 }, "server"
    incoming.extra.favorite, incoming.extra.read, incoming.extra.last_read_ep_id = false, false, "wrong"
    incoming.extra.Cookie = "SESSDATA=must-not-be-cached"
    context:refresh(feed({ incoming, comic("103") }))
    local current = account.catalog:getComic("101")
    assert(current.favorite == true and current.read == "retained-user-state")
    assert(current.current_episode_id == "1001" and current.reading_position.index == 1)
    assert(current.extra.progress_source == "local" and current.extra.read == nil and current.extra.Cookie == nil)
    assert(Codec.canonical(account.store:getAnchor("1001", "local-version")) == anchor)
    assert(Codec.canonical(account.store:getEpisode("1001")) == episode)
    assert(current.title == "Refreshed editorial title" and current.extra.tags[1] == "Adventure")
    assert(account.store:getComic("103").favorite ~= true and account.store:getComic("103").last_read_at == nil)
    local shelf = context.app:getLibrary("favorites")
    local progress = Model.comicProgress(shelf[1], context.app:getEpisodes(shelf[1].id))
    assert(#shelf == 1 and shelf[1].id == "101" and progress.state == "reading")
    assert(progress.page == 1 and progress.total_pages == 1 and progress.episode_id == "1001")
end)

test("Each editorial refresh replaces shorter tags and clears removed descriptions", function()
    local context = fixture()
    local first = comic("101")
    first.extra.tags = { "Old first tag", "Old second tag", "Old third tag" }
    context:refresh(feed({ first }))
    local stored = context.app.account.store:getComic("101")
    stored.favorite, stored.extra.user_note = true, "Retain unrelated metadata"
    context.app.account.store:upsertComic(stored)
    local second = comic("101")
    second.extra.tags, second.extra.recommendation, second.extra.evaluate = { "New tag" }, "New description", "New description"
    second.extra.recommendation_section = "hot_seller"
    context:refresh(feed({ second }))
    local current = context.app:getBookstore().items[1]
    assert(#current.extra.tags == 1 and current.extra.tags[1] == "New tag")
    assert(current.extra.recommendation == "New description" and current.extra.user_note == "Retain unrelated metadata")
    assert(current.extra.recommendation_section == "hot_seller")
    local third = comic("101")
    third.extra = "No structured editorial metadata"
    context:refresh(feed({ third }))
    current = context.app:getBookstore().items[1]
    assert(#current.extra.tags == 0 and current.extra.recommendation == nil and current.extra.evaluate == nil)
    assert(current.extra.recommendation_section == nil)
    assert(current.favorite == true and current.extra.user_note == "Retain unrelated metadata")
    stored = context.app.account.store:getComic("101")
    assert(#stored.extra.tags == 0 and stored.extra.recommendation == nil and stored.extra.evaluate == nil)
    assert(stored.extra.recommendation_section == nil)
end)

test("Malformed cached editorial fields remain safe for the UI without mutating storage", function()
    local context = fixture()
    context:refresh()
    local store = context.app.account.store
    local current = store:getComic("101")
    current.extra.tags, current.extra.recommendation, current.extra.evaluate = "Invalid tag array", { text = "Invalid type" }, false
    current.extra.recommendation_section = { name = "Forged source" }
    store:upsertComic(current)
    local before = Codec.canonical(store:getComic("101"))
    local projected = context.app:getBookstore().items[1]
    assert(type(projected.extra.tags) == "table" and #projected.extra.tags == 0)
    assert(projected.extra.recommendation == nil and projected.extra.evaluate == nil)
    assert(projected.extra.recommendation_section == nil)
    assert(Codec.canonical(store:getComic("101")) == before)
    current.extra.tags = { "Valid tag", { name = "Invalid nested tag" }, 42 }
    store:upsertComic(current)
    projected = context.app:getBookstore().items[1]
    assert(#projected.extra.tags == 1 and projected.extra.tags[1] == "Valid tag")
end)

test("Section provenance accepts only the bounded official section identifiers", function()
    local context = fixture()
    for _, invalid in ipairs({ false, {}, "completed\n", "unknown_section", string.rep("x", 1000) }) do
        local item = comic("101")
        item.extra.recommendation_section = invalid
        context:refresh(feed({ item }))
        assert(context.app:getBookstore().items[1].extra.recommendation_section == nil)
    end
end)

test("Offline and failed refreshes preserve cached content and permit a later retry", function()
    local context = fixture()
    context:refresh()
    local before = context.app.account.raw_runner.count
    context.network.connected = false
    context.app:refreshBookstore(context:callback("offline")); context.ui:drain()
    assert(context.app.account.raw_runner.count == before and context.callbacks[#context.callbacks].error.kind == "network")
    assert(#context.app:getBookstore().items == 2 and context.app:getBookstore().stale)
    context.network.connected = true
    context:refresh(nil, { kind = "timeout" })
    assert(#context.app:getBookstore().items == 2 and context.app:getBookstore().updated_at == 1000)
    context.now = 1100
    context:refresh(feed({ comic("103") }))
    local updated = context.app:getBookstore()
    assert(#updated.items == 1 and updated.items[1].id == "103" and updated.updated_at == 1100 and not updated.stale)
end)

test("An invalid response cannot replace a usable cached feed", function()
    local context = fixture()
    context:refresh()
    for _, invalid in ipairs({ {}, { source = "other", personalized = false, has_more = false, items = {} },
        feed({ { id = "bad", title = "Invalid", cover_url = "https://evil.example/a.jpg" } }),
        feed({ [2] = comic("103") }) }) do
        context:refresh(invalid)
        assert(context.callbacks[#context.callbacks].error.kind == "protocol")
        assert(context.app:getBookstore().items[1].id == "101")
    end
    local queried = comic("104")
    queried.cover_url = queried.cover_url .. "?variant=large"
    context:refresh(feed({ queried }))
    assert(context.callbacks[#context.callbacks].error.kind == "protocol")
    assert(context.app:getBookstore().items[1].id == "101")
end)

test("Catalog changes and feed order roll back together if cache persistence fails", function()
    local context = fixture()
    context:refresh()
    local store, original = context.app.account.store, context.app.account.store.putSetting
    local before = Codec.canonical(store:getComic("101"))
    store.putSetting = function(self, key, value)
        if key == Bookstore.key then error("Injected feed snapshot persistence failure") end
        return original(self, key, value)
    end
    context:refresh(feed({ comic("101", "Must roll back"), comic("104") }))
    store.putSetting = original
    assert(context.callbacks[#context.callbacks].error.kind == "storage")
    assert(Codec.canonical(store:getComic("101")) == before and store:getComic("104") == nil)
    assert(context.app:getBookstore().items[2].id == "102")
end)

test("Malformed copied and missing-comic caches are recognized without networking", function()
    local context = fixture()
    context:refresh()
    local store = context.app.account.store
    local saved = store:getSetting(Bookstore.key)
    for _, invalid in ipairs({ "corrupt", {}, Bookstore.snapshot({ comic("101") }, "other-account", 1000),
        Bookstore.snapshot({ comic("101"), comic("101") }, "anonymous", 1000),
        Bookstore.snapshot({ comic("101") }, "anonymous", 0) }) do
        store:putSetting(Bookstore.key, invalid)
        assert(#context.app:getBookstore().items == 0 and context.app:getBookstore().stale)
    end
    store:putSetting(Bookstore.key, Bookstore.snapshot({ comic("101"), comic("999") }, "anonymous", 1000))
    assert(#context.app:getBookstore().items == 1 and context.app:getBookstore().stale)
    local getter = store.getSetting
    store.getSetting = function() error("Injected corrupt JSON") end
    assert(#context.app:getBookstore().items == 0 and context.app:getBookstore().stale)
    store.getSetting = getter
    store:putSetting(Bookstore.key, saved)
    assert(context.app.account.raw_runner.count == 1)
end)

test("Cache expiry and clock rollback are stale while a valid empty snapshot remains fresh", function()
    local context = fixture()
    context:refresh()
    context.now = 1000 + Bookstore.ttl - 1
    assert(not context.app:getBookstore().stale)
    context.now = 1000 + Bookstore.ttl
    assert(context.app:getBookstore().stale and #context.app:getBookstore().items == 2)
    context.now = 999
    assert(context.app:getBookstore().stale)
    context.now = 1100
    context:refresh(feed({}))
    assert(#context.app:getBookstore().items == 0 and not context.app:getBookstore().stale)
end)

test("A restarted controller reads the ordered account cache without fetching", function()
    local context = fixture()
    context:refresh(feed({ comic("102"), comic("101") }))
    context.app:close()
    local restarted = fixture(context.root)
    local saved = restarted.app:getBookstore()
    assert(#saved.items == 2 and saved.items[1].id == "102" and saved.items[2].id == "101")
    assert(saved.updated_at == 1000 and not saved.stale and restarted.app.account.raw_runner.count == 0)
end)

test("Legacy snapshots remain browsable offline and refresh immediately into the expanded schema", function()
    local context = fixture()
    context:refresh(feed({ comic("102"), comic("101") }))
    local store = context.app.account.store
    local legacy = store:getSetting(Bookstore.key)
    legacy.schema_version = 1
    store:putSetting(Bookstore.key, legacy)
    local cached = context.app:getBookstore()
    assert(#cached.items == 2 and cached.items[1].id == "102" and cached.stale and cached.updated_at == context.now)
    context.network.connected = false
    context.app:refreshBookstore(context:callback("offline legacy")); context.ui:drain()
    assert(context.callbacks[#context.callbacks].error.kind == "network" and #context.app:getBookstore().items == 2)
    assert(store:getSetting(Bookstore.key).schema_version == 1)
    context.app:close()
    local restarted = fixture(context.root)
    local retained = restarted.app:getBookstore()
    assert(#retained.items == 2 and retained.stale and restarted.app.account.raw_runner.count == 0)
    restarted:refresh(expandedFeed())
    local updated = restarted.app:getBookstore()
    assert(#updated.items == 34 and not updated.stale and updated.updated_at == 1000)
    assert(restarted.app.account.store:getSetting(Bookstore.key).schema_version == 2)
end)

test("Queued public work rechecks connectivity suspension and account generation", function()
    for _, mutation in ipairs({ "offline", "suspended", "account" }) do
        local context = fixture()
        context.app:refreshBookstore(context:callback("queued"))
        local runner = context.app.account.raw_runner
        local task = runner:find("client", "recommendations")
        if mutation == "offline" then context.network.connected = false
        elseif mutation == "suspended" then context.app.suspended = true
        else
            context.old_accounts[#context.old_accounts + 1] = context.app.account
            context.app:_openAccount("bili_43", nil)
        end
        assert(not runner:start(task) and task.started == nil)
        assert(#context.app:getBookstore().items == 0)
        if mutation == "account" then assert(#context.callbacks == 0) end
    end
end)

test("A late recommendation response cannot write to a changed account", function()
    local context = fixture()
    context.app:refreshBookstore(context:callback("obsolete"))
    local old_account, runner = context.app.account, context.app.account.raw_runner
    local task = runner:find("client", "recommendations")
    assert(runner:start(task))
    context.old_accounts[#context.old_accounts + 1] = old_account
    context.app:_openAccount("bili_43", nil)
    runner:finish(task, feed())
    assert(#context.callbacks == 0 and #context.app:getBookstore().items == 0)
    assert(old_account.store:getSetting(Bookstore.key) == nil and context.app.account.store:getComic("101") == nil)
end)

test("Public response authentication errors never invalidate or renew an account session", function()
    local context = fixture()
    context:guardSession("valid")
    context:refresh(nil, { kind = "authentication" })
    assert(context.app.account.session_valid and not context.app.account.authentication_invalidated)
    assert(context.serialized == 0 and context.maintenance == 0)
end)

test("Unknown public methods arguments and nonfeed covers cannot bypass authentication", function()
    local context = fixture()
    context:guardSession("invalidated")
    context:refresh()
    local before = context.app.account.raw_runner.count
    context.app.account.store:upsertComic(comic("999"))
    context.app:requestBookstoreCover("999")
    context.app:requestBookstoreCover("invalid")
    for _, request in ipairs({ { kind = "client", method = "wallet", arguments = {}, public_bookstore = true },
        { kind = "client", method = "recommendations", arguments = { "private" }, public_bookstore = true },
        { kind = "purchase_submit", public_bookstore = true },
        { kind = "download_cover", comic_id = "101", url = "https://i0.hdslb.com/other.jpg", public_bookstore = true },
        { kind = "download_cover", comic_id = "101", url = CoverSource.resolve(comic("101").cover_url).url,
            temporary_path = "/var/tmp/unowned.part", public_bookstore = true } }) do
        context.app:_submit(request, {}, context:callback("rejected")); context.ui:drain()
        assert(context.callbacks[#context.callbacks].error.kind == "invalid_request")
    end
    assert(context.app.account.raw_runner.count == before and context.serialized == 0 and context.maintenance == 0)
end)

test("Public requests discard explicit transport and session credentials before raw dispatch", function()
    local context = fixture()
    context:guardSession("valid")
    context.app:_submit({ kind = "client", method = "recommendations", arguments = {}, public_bookstore = true,
        session = { cookies = { SESSDATA = "injected-secret" } }, transport_options = { headers = { Cookie = "private" } } }, {}, function() end)
    local request = context.app.account.raw_runner:find("client", "recommendations").request
    assert(request.session == nil and request.transport_options == nil and request.headers == nil)
    assert(context.serialized == 0 and context.maintenance == 0)
end)

test("Only visible feed covers download anonymously even when login is invalidated", function()
    local context = fixture()
    context:guardSession("invalidated")
    context:refresh()
    local runner, before = context.app.account.raw_runner, context.app.account.raw_runner.count
    context.app:requestCover("101")
    assert(runner.count == before)
    context.app.covers["101"] = "Unrelated authenticated request"
    context.app:requestBookstoreCover("101")
    context.app:requestBookstoreCover("101")
    local task = runner:find("download_cover")
    assert(runner.count == before + 1 and task.request.comic_id == "101" and task.request.session == nil)
    assert(task.request.url == comic("101").cover_url .. "@480w.jpg" and task.request.max_bytes == 4 * 1024 * 1024)
    assert(task.options.resource == "image" and runner:start(task))
    runner:finish(task, context:coverResult(task))
    local saved = context.app.account.store:getComic("101")
    assert(Files.exists(saved.cover_path) and not Files.exists(task.request.temporary_path))
    context.app:requestBookstoreCover("101")
    assert(runner.count == before + 1 and context.maintenance == 0 and context.serialized == 0)
end)

test("Removed recommendation covers are rejected both before start and after completion", function()
    for _, started in ipairs({ false, true }) do
        local context = fixture()
        context:refresh()
        context.app:requestBookstoreCover("101")
        local runner = context.app.account.raw_runner
        local task = runner:find("download_cover")
        if started then assert(runner:start(task)) end
        local result = context:coverResult(task)
        context:refresh(feed({ comic("102") }))
        if started then runner:finish(task, result) else assert(not runner:start(task)) end
        assert(not Files.exists(result.temporary_path) and context.app.account.store:getComic("101").cover_path == nil)
    end
end)

test("Late public cover completion after account change removes its temporary file", function()
    local context = fixture()
    context:refresh()
    context.app:requestBookstoreCover("101")
    local runner, old_account = context.app.account.raw_runner, context.app.account
    local task = runner:find("download_cover")
    assert(runner:start(task))
    local result = context:coverResult(task)
    context.old_accounts[#context.old_accounts + 1] = old_account
    context.app:_openAccount("bili_43", nil)
    runner:finish(task, result)
    assert(not Files.exists(result.temporary_path) and context.app.account.store:getComic("101") == nil)
    assert(old_account.store:getComic("101").cover_path == nil)
end)

local passed = true
for _, item in ipairs(tests) do passed = passed and item.passed end
Files.write(output .. "/bookstore-expanded-controller-result.json", json.encode({ spec = "bookstore-expanded-controller",
    host = "test-env", synthetic_data = true, network_workers_executed = false, tests = tests, passed = passed }, { pretty = true }))
print(json.encode({ spec = "bookstore-expanded-controller", tests = #tests, passed = passed }))
assert(passed, "One or more bookstore controller tests failed")
