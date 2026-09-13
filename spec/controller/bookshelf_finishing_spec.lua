-- Run only on test-env with real SQLite, synthetic sessions and controlled delayed workers.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(require("datastorage"):getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. package.path
local Controller = require("bilicomics/controller")
local Bookshelf = require("bilicomics/bookshelf_state")
local Codec = require("bilicomics/storage/codec")
local Files = require("bilicomics/storage/files")
local Session = require("bilicomics/protocol/session")
local json = require("rapidjson")
local tests, contexts, sequence = {}, {}, 0

local function comic(id, fields)
    local value = { id = tostring(id), title = "Synthetic comic " .. id, updated_at = 1000 }
    for key, field in pairs(fields or {}) do value[key] = field end
    return value
end

local function ids(items)
    local result = {}
    for _, item in ipairs(items) do result[#result + 1] = item.id end
    return table.concat(result, ",")
end

local function fixture(root)
    sequence = sequence + 1
    local context = { now = 1000, callbacks = {}, old_accounts = {}, runners = {} }
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
    local function runnerFactory(options)
        local runner = { tasks = {}, count = 0, options = options, applied = {}, image_concurrency = options.image_concurrency }
        function runner:submit(request, request_options, callback)
            self.count = self.count + 1
            local task = { id = self.count, request = request, options = request_options, callback = callback }
            self.tasks[task.id] = task
            return task.id
        end
        function runner:find(kind, library_or_id)
            local found
            for _, task in pairs(self.tasks) do
                if task.request.kind == kind and (not library_or_id
                    or task.request.library == library_or_id or task.request.comic_id == library_or_id) then
                    assert(not found, "More than one matching pending worker")
                    found = task
                end
            end
            return assert(found, "No pending worker: " .. kind .. "/" .. tostring(library_or_id))
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
        function runner:setImageConcurrency(value)
            self.applied[#self.applied + 1], self.image_concurrency = value, value
            return true
        end
        context.runners[#context.runners + 1] = runner
        return runner
    end
    context.root = root or output .. "/finishing-account-" .. sequence
    context.network = { connected = true }
    function context.network:isConnected() return self.connected end
    context.app = Controller.new{ root = context.root, ui_manager = ui, runner_factory = runnerFactory,
        network = context.network, clock = function() return context.now end }
    context.ui = ui
    function context:authenticate()
        self.app.account.session = Session.new{ cookies = { SESSDATA = "synthetic-secret", DedeUserID = "42", buvid3 = "synthetic-device" } }
        self.app.account.session_valid, self.app.account.authentication_invalidated = true, false
    end
    function context:callback(name)
        return function(value, err) self.callbacks[#self.callbacks + 1] = { name = name, value = value, error = err } end
    end
    function context:last(name)
        for index = #self.callbacks, 1, -1 do
            if self.callbacks[index].name == name then return self.callbacks[index] end
        end
        error("No callback: " .. name)
    end
    function context:countCallbacks(name)
        local count = 0
        for _, callback in ipairs(self.callbacks) do if callback.name == name then count = count + 1 end end
        return count
    end
    function context:begin(name, manual)
        local method = manual and self.app.syncBookshelf or self.app.ensureBookshelfSync
        method(self.app, self:callback(name or "sync"))
        local runner = self.app.account.raw_runner
        local favorites, history = runner:find("library", "favorites"), runner:find("library", "history")
        assert(runner:start(favorites) and runner:start(history))
        return runner, favorites, history
    end
    function context:sync(favorites, history)
        local runner, first, second = self:begin("sync", true)
        runner:finish(first, favorites or {})
        runner:finish(second, history or {})
        return self:last("sync")
    end
    function context:switch(key)
        self.old_accounts[#self.old_accounts + 1] = self.app.account
        self.app:_openAccount(key, nil)
        self.ui:drain()
    end
    contexts[#contexts + 1] = context
    ui:drain()
    return context
end

local function test(name, callback)
    local ok, failure = xpcall(callback, debug.traceback)
    for _, context in ipairs(contexts) do
        context.app.integrations, context.app.active_integration, context.app.opening = {}, nil, nil
        pcall(context.app.close, context.app)
        for _, account in ipairs(context.old_accounts) do pcall(account.store.close, account.store) end
    end
    contexts = {}
    tests[#tests + 1] = { name = name, passed = ok, failure = not ok and tostring(failure) or nil }
end

test("Uncached getters and unauthenticated automatic entry never dispatch", function()
    local context = fixture()
    local state = context.app:getBookshelfSyncState()
    assert(not state.has_cache and state.stale and not state.syncing and not state.can_sync and not state.authenticated)
    assert(#context.app:getBookshelfItems() == 0 and context.app:getBookshelfViewState().page == 1)
    context.app:ensureBookshelfSync(context:callback("automatic")); context.ui:drain()
    assert(#context:last("automatic").value == 0 and not context:last("automatic").error)
    context.app:syncBookshelf(context:callback("manual")); context.ui:drain()
    assert(context:last("manual").error.kind == "authentication" and context.app.account.raw_runner.count == 0)
end)

test("A successful empty bookshelf is cached and stays distinct from no cache after restart", function()
    local context = fixture(); context:authenticate()
    assert(context:sync().value and #context.app:getBookshelfItems() == 0)
    local state = context.app:getBookshelfSyncState()
    assert(state.has_cache and state.last_synced_at == 1000 and not state.stale and not state.syncing)
    local count = context.app.account.raw_runner.count
    context.app:ensureBookshelfSync(context:callback("fresh")); context.ui:drain()
    assert(context.app.account.raw_runner.count == count and #context:last("fresh").value == 0)
    context.app:close()
    local restarted = fixture(context.root)
    restarted.network.connected = false
    state = restarted.app:getBookshelfSyncState()
    assert(state.has_cache and state.last_synced_at == 1000 and not state.stale and state.offline)
    assert(restarted.app.account.raw_runner.count == 0)
end)

test("Corrupt or cross account snapshot metadata cannot certify an empty bookshelf cache", function()
    local context = fixture()
    for _, change in ipairs{ { schema_version = 2 }, { account_key = "bili_43" }, { last_synced_at = 0 },
        { last_synced_at = "1000" }, { order_ids = { "101", "101" } }, { order_ids = { "invalid" } } } do
        local snapshot = { schema_version = 1, account_key = context.app.account.key, last_synced_at = 1000, order_ids = {} }
        for key, value in pairs(change) do snapshot[key] = value end
        context.app.account.store:putSetting(Bookshelf.sync_key, snapshot)
        local state = context.app:getBookshelfSyncState()
        assert(not state.has_cache and state.stale and state.last_synced_at == nil)
    end
    context.app.account.store:upsertComic(comic("101", { favorite = true }))
    assert(context.app:getBookshelfSyncState().has_cache and context.app:getBookshelfSyncState().stale)
    assert(ids(context.app:getBookshelfItems()) == "101")
end)

test("Legacy favorites are usable stale cache and synchronize in server order", function()
    local context = fixture(); context:authenticate()
    context.app.account.catalog:ingestLibrary("favorites", { comic("101"), comic("102") })
    local state = context.app:getBookshelfSyncState()
    assert(state.has_cache and state.stale and state.last_synced_at == nil)
    local runner, favorites, history = context:begin("initial")
    assert(runner.count == 2 and favorites.request.session.cookies.SESSDATA == "synthetic-secret")
    runner:finish(history, { comic("103", { current_episode_id = "1031", last_read_at = 900 }) })
    assert(ids(context.app:getBookshelfItems()) == "101,102" and context.app:getBookshelfSyncState().syncing)
    assert(context.app:getComic("103") == nil and context:countCallbacks("initial") == 0)
    runner:finish(favorites, { comic("102"), comic("104"), comic("101") })
    assert(ids(context.app:getBookshelfItems()) == "102,104,101" and context.app:getComic("103").current_episode_id == "1031")
    assert(context:countCallbacks("initial") == 1 and not context.app:getBookshelfSyncState().stale)
end)

test("The fifteen minute boundary refreshes once and manual refresh bypasses freshness", function()
    local context = fixture(); context:authenticate(); context:sync({ comic("101") })
    context.now = 1899
    context.app:ensureBookshelfSync(context:callback("before boundary")); context.ui:drain()
    assert(context.app.account.raw_runner.count == 2 and not context.app:getBookshelfSyncState().stale)
    context.now = 1900
    local runner, favorites, history = context:begin("boundary")
    assert(runner.count == 4 and context.app:getBookshelfSyncState().stale)
    context.app:ensureBookshelfSync(context:callback("joined"))
    context.app:syncBookshelf(context:callback("manual joined"))
    assert(runner.count == 4)
    runner:finish(favorites, { comic("102") }); runner:finish(history, {})
    assert(context:countCallbacks("boundary") == 1 and context:countCallbacks("joined") == 1)
    assert(context:countCallbacks("manual joined") == 1 and context.app:getBookshelfSyncState().last_synced_at == 1900)
    context:sync({ comic("103") })
    assert(runner.count == 6 and ids(context.app:getBookshelfItems()) == "103")
end)

for _, first_kind in ipairs{ "favorites", "history" } do
    test("Both library responses publish atomically when " .. first_kind .. " completes first", function()
        local context = fixture(); context:authenticate(); context:sync({ comic("101") }, { comic("201") })
        local before = Codec.canonical(context.app.account.store:listComics())
        local runner, favorites, history = context:begin("atomic", true)
        context.app:ensureBookshelfSync(context:callback("joined"))
        local values = { favorites = { comic("102") }, history = { comic("202") } }
        local first, last = first_kind == "favorites" and favorites or history, first_kind == "favorites" and history or favorites
        runner:finish(first, values[first.request.library])
        assert(Codec.canonical(context.app.account.store:listComics()) == before)
        assert(context.app:getBookshelfSyncState().last_synced_at == 1000 and context:countCallbacks("atomic") == 0)
        runner:finish(last, values[last.request.library])
        assert(ids(context:last("atomic").value) == "102" and ids(context:last("joined").value) == "102")
        assert(context.app:getComic("202") and context:countCallbacks("atomic") == 1)
    end)
end

for _, failed_kind in ipairs{ "favorites", "history" } do
    test("A failed " .. failed_kind .. " response retains the entire preceding snapshot", function()
        local context = fixture(); context:authenticate(); context:sync({ comic("101") }, { comic("201") })
        local before = Codec.canonical(context.app.account.store:listComics())
        local snapshot = Codec.canonical(context.app.account.store:getSetting(Bookshelf.sync_key))
        local runner, favorites, history = context:begin("failed", true)
        local failed, success = failed_kind == "favorites" and favorites or history, failed_kind == "favorites" and history or favorites
        runner:finish(failed, nil, { kind = "timeout" })
        assert(context.app:getBookshelfSyncState().syncing and context:countCallbacks("failed") == 0)
        runner:finish(success, { comic("999") })
        local state = context.app:getBookshelfSyncState()
        assert(context:last("failed").error.kind == "timeout" and state.has_cache and state.stale and not state.syncing)
        assert(state.retry_at == 1060 and Codec.canonical(context.app.account.store:listComics()) == before)
        assert(Codec.canonical(context.app.account.store:getSetting(Bookshelf.sync_key)) == snapshot)
    end)
end

test("A snapshot storage failure rolls back both libraries and their comic mutations", function()
    local context = fixture(); context:authenticate(); context:sync({ comic("101") }, { comic("201") })
    local store = context.app.account.store
    local before, snapshot = Codec.canonical(store:listComics()), Codec.canonical(store:getSetting(Bookshelf.sync_key))
    local original = store.putSetting
    store.putSetting = function(self, key, value)
        original(self, key, value)
        if key == Bookshelf.sync_key then error("Injected storage failure after snapshot write") end
    end
    local result = context:sync({ comic("102") }, { comic("202") })
    store.putSetting = original
    assert(result.error.kind == "storage" and Codec.canonical(store:listComics()) == before)
    assert(Codec.canonical(store:getSetting(Bookshelf.sync_key)) == snapshot and store:getComic("202") == nil)
end)

test("Submission exceptions finish single flight and allow a clean manual retry", function()
    for _, both in ipairs{ false, true } do
        local context = fixture(); context:authenticate(); context:sync({ comic("101") })
        local runner, original = context.app.account.raw_runner, context.app.account.raw_runner.submit
        runner.submit = function(self, request, options, callback)
            if request.library == "favorites" or both then error("Injected worker submission failure") end
            return original(self, request, options, callback)
        end
        context.app:syncBookshelf(context:callback("submission failure"))
        if not both then runner:finish(runner:find("library", "history"), { comic("999") }) end
        runner.submit = original
        local failure = context:last("submission failure")
        assert(failure.value == nil and failure.error and failure.error.transmitted == false)
        assert(not context.app:getBookshelfSyncState().syncing and ids(context.app:getBookshelfItems()) == "101")
        assert(context.app:getComic("999") == nil)
        assert(context:sync({ comic("102") }).value and ids(context.app:getBookshelfItems()) == "102")
    end
end)

test("Repeated worker completion cannot publish a partial result or invoke waiters twice", function()
    local context = fixture(); context:authenticate()
    local runner, favorites, history = context:begin("once")
    runner:finish(favorites, { comic("101") })
    favorites.callback({ comic("999") }); context.ui:drain()
    assert(not context.app:getBookshelfSyncState().has_cache and context:countCallbacks("once") == 0)
    runner:finish(history, {})
    history.callback({ comic("999") }); favorites.callback({ comic("999") }); context.ui:drain()
    assert(context:countCallbacks("once") == 1 and ids(context.app:getBookshelfItems()) == "101")
    assert(context.app:getComic("999") == nil)
end)

test("Malformed and duplicate synchronized identities never replace usable cache", function()
    local context = fixture(); context:authenticate(); context:sync({ comic("101") })
    local snapshot = Codec.canonical(context.app.account.store:getSetting(Bookshelf.sync_key))
    for _, value in ipairs{ { comic("102"), comic("102") }, { comic("invalid") }, { { title = "Missing identity" } } } do
        local result = context:sync(value)
        assert(result.error and ids(context.app:getBookshelfItems()) == "101")
        assert(Codec.canonical(context.app.account.store:getSetting(Bookshelf.sync_key)) == snapshot)
        assert(context.app.account.store:getComic("102") == nil)
    end
end)

test("Local exact anchors survive conflicting chapter level server history", function()
    local context = fixture(); context:authenticate()
    local account = context.app.account
    account.catalog:ingestDetail{ comic = comic("101"), episodes = {
        { id = "1011", comic_id = "101", order = 1, title = "Opening", access = "free" } } }
    local descriptor = { schema_version = 1, account_key = account.key, comic_id = "101", episode_id = "1011",
        revision = "local-version", pages = { { id = "page-1", index = 1, width = 20, height = 40 } } }
    account.pages:ensureDescriptor(descriptor)
    account.catalog:updatePosition(descriptor, { index = 1, page_id = "page-1", x = 0.2, y = 0.625, finished = false })
    local anchor = Codec.canonical(account.store:getAnchor("1011", "local-version"))
    context:sync({ comic("101") }, { comic("101", { current_episode_id = "9999", last_read_at = 99999,
        reading_position = { index = 999 }, extra = { progress_source = "server", reading_position = { index = 999 } } }) })
    local saved = context.app:getBookshelfItems()[1]
    assert(saved.current_episode_id == "1011" and saved.reading_position.index == 1 and saved.reading_position.y == 0.625)
    assert(saved.extra.progress_source == "local" and Codec.canonical(account.store:getAnchor("1011", "local-version")) == anchor)
end)

for _, favorite in ipairs{ false, true } do
    test("A completed concurrent following change to " .. tostring(favorite) .. " wins over old sync data", function()
        local context = fixture(); context:authenticate(); context:sync({ comic("101") })
        context.app.account.store:upsertComic(comic("102", { favorite = false }))
        local target = favorite and "102" or "101"
        local runner, favorites, history = context:begin("conflict", true)
        context.app:setFavorite(target, favorite, context:callback("follow"))
        local mutation = runner:find("set_favorite", target)
        assert(runner:start(mutation))
        runner:finish(mutation, { accepted = true, comic_id = target, favorite = favorite })
        runner:finish(favorites, { comic("101") }); runner:finish(history, {})
        assert(context.app:getComic(target).favorite == favorite and not context:last("follow").error)
        assert(ids(context.app:getBookshelfItems()) == (favorite and "101,102" or ""))
    end)
end

test("An in flight following operation preserves prior state until its confirmed completion", function()
    local context = fixture(); context:authenticate(); context:sync({ comic("101") })
    context.app:setFavorite("101", false, context:callback("follow"))
    local runner = context.app.account.raw_runner
    local mutation = runner:find("set_favorite", "101"); assert(runner:start(mutation))
    local _, favorites, history = context:begin("conflict", true)
    runner:finish(history, {}); runner:finish(favorites, {})
    assert(context.app:getComic("101").favorite and context.app:isFavoritePending("101"))
    runner:finish(mutation, { accepted = true, comic_id = "101", favorite = false })
    assert(not context.app:getComic("101").favorite and #context.app:getBookshelfItems() == 0)
end)

for _, change in ipairs{ "account", "close" } do
    test("A late library completion after " .. change .. " does not notify or publish", function()
        local context = fixture(); context:authenticate()
        local runner, favorites, history = context:begin("late")
        local old_account, before = context.app.account, #context.callbacks
        runner:finish(history, { comic("201") })
        if change == "account" then context:switch("bili_43") else context.app:close() end
        runner:finish(favorites, { comic("101") })
        assert(#context.callbacks == before)
        if change == "account" then
            assert(#context.app:getBookshelfItems() == 0 and old_account.store:getComic("101") == nil)
            assert(context.app.account.store:getComic("201") == nil)
        else assert(context.app.closed and #context.app:getBookshelfItems() == 0) end
    end)
end

test("Automatic entry respects reader activity suspension offline state and invalid authentication", function()
    for _, condition in ipairs{ "reader", "no screens", "suspended", "offline", "invalidated" } do
        local context = fixture(); context:authenticate()
        if condition == "reader" then context.app.active_integration, context.app.screens = {}, { route = "comic" }
        elseif condition == "no screens" then context.app.active_integration = {}
        elseif condition == "suspended" then context.app.suspended = true
        elseif condition == "offline" then context.network.connected = false
        else context.app.account.session_valid, context.app.account.authentication_invalidated = false, true end
        assert(not context.app:getBookshelfSyncState().can_sync)
        context.app:ensureBookshelfSync(context:callback("blocked")); context.ui:drain()
        assert(context.app.account.raw_runner.count == 0 and #context:last("blocked").value == 0)
        context.app.screens = nil
    end
end)

test("Offline cache and failure backoff stay usable while manual retry can immediately recover", function()
    local context = fixture(); context:authenticate(); context:sync({ comic("101") })
    context.now, context.network.connected = 2000, false
    context.app:ensureBookshelfSync(context:callback("offline automatic")); context.ui:drain()
    context.app:syncBookshelf(context:callback("offline manual")); context.ui:drain()
    assert(context.app.account.raw_runner.count == 2 and ids(context:last("offline automatic").value) == "101")
    assert(context:last("offline manual").error.kind == "network")
    context.network.connected = true
    local runner, favorites, history = context:begin("failed")
    runner:finish(favorites, nil, { kind = "timeout" }); runner:finish(history, {})
    context.now = 2059
    context.app:ensureBookshelfSync(context:callback("backoff")); context.ui:drain()
    assert(runner.count == 4 and ids(context:last("backoff").value) == "101")
    context:sync({ comic("102") })
    assert(runner.count == 6 and ids(context.app:getBookshelfItems()) == "102")
    assert(context.app:getBookshelfSyncState().retry_at == nil and not context.app:getBookshelfSyncState().error)
end)

test("Automatic retry begins at sixty seconds and a clock rollback makes cache stale", function()
    local context = fixture(); context:authenticate()
    local runner, favorites, history = context:begin("failed")
    runner:finish(favorites, nil, { kind = "timeout" }); runner:finish(history, {})
    context.now = 1060
    runner, favorites, history = context:begin("retry")
    assert(runner.count == 4)
    runner:finish(favorites, {}); runner:finish(history, {})
    context.now = 1059
    assert(context.app:getBookshelfSyncState().stale)
end)

test("View changes merge preserve focus and persist across a restart", function()
    local context = fixture()
    local saved = assert(context.app:saveBookshelfViewState{ filter = "reading", sort = "title", page = 3,
        focused_comic_id = "102", order_ids = { "103", "102", "101" }, help_seen = true })
    assert(saved.filter == "reading" and saved.focused_comic_id == "102")
    saved = assert(context.app:saveBookshelfViewState{ page = 4 })
    assert(saved.page == 4 and saved.filter == "reading" and saved.sort == "title" and saved.help_seen)
    assert(saved.focused_comic_id == "102" and table.concat(saved.order_ids, ",") == "103,102,101")
    context.app:close()
    local restarted = fixture(context.root)
    assert(Codec.canonical(restarted.app:getBookshelfViewState()) == Codec.canonical(saved))
    saved = assert(restarted.app:saveBookshelfViewState{ focused_comic_id = false })
    assert(saved.focused_comic_id == nil and saved.page == 4 and saved.help_seen)
end)

test("View state and sync snapshots are account scoped and reject stale account saves", function()
    local context = fixture(); context:authenticate(); context:sync({ comic("101") })
    assert(context.app:saveBookshelfViewState{ page = 3, focused_comic_id = "101", help_seen = true })
    local first_key = context.app.account.key
    context:switch("bili_43")
    local saved = context.app:getBookshelfViewState()
    assert(saved.account_key == "bili_43" and saved.page == 1 and not saved.help_seen and saved.focused_comic_id == nil)
    assert(not context.app:getBookshelfSyncState().has_cache and #context.app:getBookshelfItems() == 0)
    local value, err = context.app:saveBookshelfViewState({ page = 99 }, first_key)
    assert(value == nil and err.kind == "account_mismatch" and context.app:getBookshelfViewState().page == 1)
    assert(context.app:saveBookshelfViewState{ page = 5 })
    context:switch(first_key)
    assert(context.app:getBookshelfViewState().page == 3 and context.app:getBookshelfViewState().help_seen)
    assert(ids(context.app:getBookshelfItems()) == "101" and context.app:getBookshelfSyncState().has_cache)
end)

test("Corrupt view fields normalize safely and a failed save retains prior persistent view", function()
    local context = fixture()
    local saved = assert(context.app:saveBookshelfViewState{ filter = "wrong", sort = "wrong", page = 0,
        focused_comic_id = "not-an-id", order_ids = { "101", "101" }, help_seen = "yes", unknown = "ignored" })
    assert(saved.filter == "all" and saved.sort == "source" and saved.page == 1 and not saved.help_seen)
    assert(saved.focused_comic_id == nil and #saved.order_ids == 0 and saved.unknown == nil)
    local value, err = context.app:saveBookshelfViewState("invalid")
    assert(value == nil and err.kind == "invalid_request")
    local store, before = context.app.account.store, Codec.canonical(context.app:getBookshelfViewState())
    local original = store.putSetting
    store.putSetting = function() error("Injected view save failure") end
    value, err = context.app:saveBookshelfViewState{ page = 8 }
    store.putSetting = original
    assert(value == nil and err.kind == "storage" and Codec.canonical(context.app:getBookshelfViewState()) == before)
    store:putSetting(Bookshelf.view_key, { schema_version = 1, account_key = "bili_43", page = 88, help_seen = true })
    assert(context.app:getBookshelfViewState().page == 1 and not context.app:getBookshelfViewState().help_seen)
end)

test("Concurrency settings initialize the runner persist and notify both live schedulers", function()
    local context = fixture()
    local runner, refreshes = context.app.account.raw_runner, 0
    assert(context.app:getSetting("download_concurrency") == 2 and runner.options.image_concurrency == 2)
    context.app.account.downloads.refreshConcurrency = function() refreshes = refreshes + 1 end
    for _, value in ipairs{ 1, 4, 3 } do
        assert(context.app:setSetting("download_concurrency", value))
        assert(context.app:getSetting("download_concurrency") == value and runner.image_concurrency == value)
    end
    assert(table.concat(runner.applied, ",") == "1,4,3" and refreshes == 3)
    context.app:close()
    local restarted = fixture(context.root)
    assert(restarted.app:getSetting("download_concurrency") == 3 and restarted.app.account.raw_runner.options.image_concurrency == 3)
end)

test("Invalid concurrency values cannot change persistent settings or scheduler policy", function()
    local context = fixture()
    local runner, refreshes = context.app.account.raw_runner, 0
    context.app.account.downloads.refreshConcurrency = function() refreshes = refreshes + 1 end
    for _, value in ipairs{ 0, 5, -1, 2.5, "3", false, math.huge, 0 / 0 } do
        local ok, err = context.app:setSetting("download_concurrency", value)
        assert(not ok and err.kind == "invalid_request")
        assert(context.app:getSetting("download_concurrency") == 2 and runner.image_concurrency == 2)
    end
    assert(#runner.applied == 0 and refreshes == 0)
    context.app.settings:set("download_concurrency", "corrupt")
    assert(context.app:getSetting("download_concurrency") == 2)
    context.app:close()
    local restarted = fixture(context.root)
    assert(restarted.app:getSetting("download_concurrency") == 2 and restarted.app.account.raw_runner.options.image_concurrency == 2)
end)

test("A concurrency persistence failure cannot alter the effective setting or runtime policy", function()
    for _, state in ipairs{ "unset", "stored" } do
        local context = fixture()
        if state == "stored" then assert(context.app:setSetting("download_concurrency", 1)) end
        local expected, previous = state == "stored" and 1 or 2, context.app.settings.data:readSetting("download_concurrency")
        local runner, refreshes = context.app.account.raw_runner, 0
        context.app.account.downloads.refreshConcurrency = function() refreshes = refreshes + 1 end
        local settings_path, original = context.app.settings.data.file, Files.atomicWrite
        local before = Files.exists(settings_path) and Files.read(settings_path) or nil
        Files.atomicWrite = function(path, data, root)
            if path == settings_path then error("Injected atomic settings persistence failure") end
            return original(path, data, root)
        end
        local ok, err = context.app:setSetting("download_concurrency", 4)
        Files.atomicWrite = original
        assert(not ok and err.kind == "storage" and runner.image_concurrency == expected and refreshes == 0)
        assert(context.app:getSetting("download_concurrency") == expected, "Failed persistence changed the effective download setting")
        assert(context.app.settings.data:readSetting("download_concurrency") == previous)
        assert((Files.exists(settings_path) and Files.read(settings_path) or nil) == before)
        context.app:close()
        local restarted = fixture(context.root)
        assert(restarted.app:getSetting("download_concurrency") == expected and restarted.app.account.raw_runner.options.image_concurrency == expected)
        assert(restarted.app.settings.data:readSetting("download_concurrency") == previous)
    end
end)

test("A native settings write failure is detected even when LuaSettings flush returns normally", function()
    local context = fixture()
    assert(context.app:setSetting("download_concurrency", 1))
    local runner, refreshes = context.app.account.raw_runner, 0
    context.app.account.downloads.refreshConcurrency = function() refreshes = refreshes + 1 end
    local settings, original_path = context.app.settings.data, context.app.settings.data.file
    local blocked_path = context.root .. "/settings-write-target-directory"
    Files.mkdir(blocked_path)
    settings.file = blocked_path
    local ok, err = context.app:setSetting("download_concurrency", 4)
    settings.file = original_path
    assert(not ok and err.kind == "storage", "A native failed write was reported as a saved setting")
    assert(context.app:getSetting("download_concurrency") == 1 and runner.image_concurrency == 1 and refreshes == 0)
    context.app:close()
    local restarted = fixture(context.root)
    assert(restarted.app:getSetting("download_concurrency") == 1)
end)

test("Reader close returns on the next tick and newer reader or opening state suppresses it", function()
    for _, guard in ipairs{ "none", "active reader", "opening", "suspended", "account", "closed" } do
        local context = fixture()
        local screens = { returned = {}, refresh = function() end, close = function() end }
        function screens:onReaderClosed(event) self.returned[#self.returned + 1] = event end
        context.app:setScreens(screens)
        local integration = { generation = 7 }
        context.app.integrations[integration], context.app.active_integration = true, integration
        context.app:_readerEvent("closed", { reader_generation = 7, comic_id = "101" })
        assert(#screens.returned == 0 and context.app.active_integration == nil)
        if guard == "active reader" then context.app.active_integration = { generation = 8 }
        elseif guard == "opening" then context.app.opening = {}
        elseif guard == "suspended" then context.app.suspended = true
        elseif guard == "account" then context:switch("bili_43")
        elseif guard == "closed" then context.app:close() end
        context.ui:drain()
        assert(#screens.returned == (guard == "none" and 1 or 0))
        if guard == "none" then assert(screens.returned[1].comic_id == "101" and screens.returned[1].reader_generation == 7) end
    end
end)

test("Closing the active reader cannot return while another tracked reader is still open", function()
    local context = fixture()
    local screens = { returned = {}, refresh = function() end, close = function() end }
    function screens:onReaderClosed(event) self.returned[#self.returned + 1] = event end
    context.app:setScreens(screens)
    local older, active = { generation = 6 }, { generation = 7 }
    context.app.integrations[older], context.app.integrations[active] = true, true
    context.app.active_integration = active
    context.app:_readerEvent("closed", { reader_generation = 7, comic_id = "101" })
    context.ui:drain()
    assert(context.app.integrations[older] and #screens.returned == 0,
        "Closing the active reader returned while an older tracked reader remained open")
    context.app:_readerEvent("closed", { reader_generation = 6, comic_id = "102" })
    context.ui:drain()
    assert(#screens.returned == 1 and screens.returned[1].comic_id == "102")
end)

local passed = true
for _, item in ipairs(tests) do passed = passed and item.passed end
Files.write(output .. "/finishing-bookshelf-controller-result.json", json.encode({ spec = "finishing-bookshelf-controller",
    host = "test-env", synthetic_data = true, network_workers_executed = false,
    scheduler_scope = "Controller wiring with a controlled runner; real worker concurrency is covered separately",
    tests = tests, passed = passed }, { pretty = true }))
print(json.encode({ spec = "finishing-bookshelf-controller", tests = #tests, passed = passed }))
assert(passed, "One or more finishing bookshelf controller tests failed")
