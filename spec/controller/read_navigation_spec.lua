-- Run only on test-env with synthetic records, real Controller methods and real SQLite lease metadata.
-- Preparation, entitlement refresh and native reader completion are deliberately delayed.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(require("datastorage"):getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. package.path
local Controller = require("bilicomics/controller")
local Codec = require("bilicomics/storage/codec")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local tests, contexts, sequence = {}, {}, 0
local original_integration = package.loaded["bilicomics/reader/integration"]

-- Keep the real Controller attachment/release ordering while replacing the native view adapter.
package.loaded["bilicomics/reader/integration"] = { attach = function(reader)
    if reader.bilicomics_integration then return reader.bilicomics_integration end
    local context, descriptor = reader.context, reader.document.descriptor
    local app, account = context.app, context.app.account
    account.pages:setActiveEpisode(descriptor.episode_id, descriptor.revision, true)
    local integration = { reader = reader, document = reader.document, generation = context.reader_sequence }
    function integration:isCurrent() return not self.closed and not reader.closed and app.account == account end
    function integration:requestVisible() context.visible_requests = context.visible_requests + 1 end
    function integration:saveAnchor() end
    function integration:close()
        if self.closed then return end
        self.closed = true
        account.pages:setActiveEpisode(descriptor.episode_id, descriptor.revision, false)
        app:_readerEvent("closed", { descriptor = descriptor, reader_generation = self.generation })
    end
    reader.bilicomics_integration = integration
    context.attachments = context.attachments + 1
    return integration
end }

local function fixture()
    sequence = sequence + 1
    local context = { prepared = {}, refreshed = {}, openers = {}, callbacks = {},
        attachments = 0, visible_requests = 0, reader_sequence = 0, canceled_workers = 0 }
    local ui = { queue = {}, timers = {} }
    function ui:nextTick(callback) self.queue[#self.queue + 1] = callback end
    function ui:scheduleIn(_seconds, callback) self.timers[callback] = true end
    function ui:unschedule(callback) self.timers[callback] = nil end
    function ui:drain()
        local remaining = 100
        while #self.queue > 0 do
            remaining = remaining - 1; assert(remaining > 0, "Unbounded deferred work")
            table.remove(self.queue, 1)()
        end
    end
    function ui:close() end
    local function runnerFactory()
        local runner = {}
        function runner:submit() error("Network and purchase workers are prohibited in this spec") end
        function runner:cancel() context.canceled_workers = context.canceled_workers + 1 end
        function runner:close() end
        function runner:promote() end
        return runner
    end
    local app = Controller.new{ root = output .. "/read-navigation-account-" .. sequence,
        ui_manager = ui, runner_factory = runnerFactory, network = { isConnected = function() return true end },
        reader_opener = function(path, _provider, callback)
            context.openers[#context.openers + 1] = { path = path, callback = callback }
        end }
    context.app, context.ui = app, ui
    contexts[#contexts + 1] = context
    app.account.session, app.account.session_valid = {}, true
    app.account.store:upsertComic{ id = "1", title = "Synthetic reading navigation" }
    context.descriptors = {}
    for _, episode_id in ipairs({ "101", "102" }) do
        local descriptor = { schema_version = 1, account_key = "anonymous", comic_id = "1", episode_id = episode_id,
            revision = "revision-" .. episode_id, pages = { { id = "page-" .. episode_id, index = 1, width = 20, height = 40 } } }
        app.account.store:upsertEpisodes("1", { { id = episode_id, comic_id = "1", order = tonumber(episode_id),
            title = "Synthetic chapter " .. episode_id, access = "free", extra = { current_revision = descriptor.revision } } })
        context.descriptors[episode_id] = { descriptor = descriptor, path = app.account.pages:ensureDescriptor(descriptor) }
    end
    -- Native view drawing is outside this spec; the real PageStore still owns active lease transactions.
    app.account.pages.isComplete = function() return true end
    function app:prepareEpisode(comic_id, episode_id, callback)
        context.prepared[#context.prepared + 1] = { comic_id = comic_id, episode_id = episode_id, callback = callback }
    end
    function app:refreshComic(comic_id, callback)
        context.refreshed[#context.refreshed + 1] = { comic_id = comic_id, callback = callback }
    end
    function context:callback(name)
        return function(value, err)
            self.callbacks[#self.callbacks + 1] = { name = name, value = value, error = err }
        end
    end
    function context:finishPrepare(index, err)
        local pending = assert(self.prepared[index])
        pending.callback(not err and self.descriptors[pending.episode_id] or nil, err)
    end
    function context:active(episode_id)
        return self.app.account.pages.active[episode_id .. "/revision-" .. episode_id] or 0
    end
    function context:reader(index)
        local opener = assert(self.openers[index])
        local prepared
        for _, item in pairs(self.descriptors) do if item.path == opener.path then prepared = item end end
        assert(prepared, "The opener must retain a prepared descriptor path")
        self.reader_sequence = self.reader_sequence + 1
        local reader = { context = self, document = { provider = "bilicomics_document", file = opener.path,
            descriptor = prepared.descriptor }, close_count = 0 }
        function reader:onClose()
            if self.closed then return end
            self.closed, self.close_count = true, self.close_count + 1
            if self.bilicomics_integration then self.bilicomics_integration:close() end
        end
        return reader
    end
    function context:temporary(episode_id)
        local episode = app.account.store:getEpisode(episode_id)
        episode.access, episode.expires_at = "temporary", os.time() + 3600
        app.account.store:upsertEpisodes("1", { episode })
    end
    ui:drain()
    return context
end

local function test(name, callback)
    local ok, failure = xpcall(callback, debug.traceback)
    for _, context in ipairs(contexts) do pcall(context.app.close, context.app) end
    contexts = {}
    tests[#tests + 1] = { name = name, passed = ok, failure = not ok and tostring(failure) or nil }
end

test("Navigation during delayed chapter preparation never opens the obsolete reader", function()
    local context = fixture()
    context.app:readEpisode("1", "101", context:callback("obsolete"))
    context.app:cancelPendingRead()
    context:finishPrepare(1)
    assert(#context.openers == 0 and #context.callbacks == 0 and context:active("101") == 0)
    assert(context.canceled_workers == 0 and next(context.ui.timers) == nil)
end)

test("An obsolete preparation failure cannot show an error after navigation", function()
    local context = fixture()
    context.app:readEpisode("1", "101", context:callback("obsolete"))
    context.app:cancelPendingRead()
    context:finishPrepare(1, { kind = "network" })
    assert(#context.callbacks == 0 and #context.openers == 0)
end)

test("A newer reading request supersedes earlier preparation without canceling shared workers", function()
    local context = fixture()
    context.app:readEpisode("1", "101", context:callback("older"))
    context.app:readEpisode("1", "102", context:callback("newer"))
    context:finishPrepare(1)
    assert(#context.openers == 0)
    context:finishPrepare(2)
    assert(#context.openers == 1 and context.app.opening.descriptor.episode_id == "102")
    assert(context:active("101") == 0 and context:active("102") == 1 and context.canceled_workers == 0)
    context.openers[1].callback(context:reader(1))
    assert(#context.callbacks == 1 and context.callbacks[1].name == "newer" and context.callbacks[1].value)
end)

test("An already dispatched native opener retains the existing busy contract", function()
    local context = fixture()
    context.app:readEpisode("1", "101", context:callback("first"))
    context:finishPrepare(1)
    local opening, generation = context.app.opening, context.app.read_generation
    context.app:readEpisode("1", "102", context:callback("duplicate"))
    context.ui:drain()
    assert(#context.prepared == 1 and #context.openers == 1 and context.app.opening == opening)
    assert(context.app.read_generation == generation and context:active("101") == 1)
    assert(#context.callbacks == 1 and context.callbacks[1].name == "duplicate" and context.callbacks[1].error.kind == "busy")
    context.openers[1].callback(context:reader(1))
    assert(#context.callbacks == 2 and context.callbacks[2].name == "first" and context.callbacks[2].value)
end)

test("Explicit navigation releases an in-flight opener lease and closes its late native reader", function()
    local context = fixture()
    context.app:readEpisode("1", "101", context:callback("obsolete"))
    context:finishPrepare(1)
    local timeout = context.app.opening.timeout
    assert(context:active("101") == 1 and context.ui.timers[timeout])
    context.app:cancelPendingRead()
    context.app:cancelPendingRead()
    assert(context.app.opening == nil and context:active("101") == 0 and next(context.ui.timers) == nil)
    local late = context:reader(1)
    context.openers[1].callback(late)
    timeout()
    assert(late.close_count == 1 and context.attachments == 0 and #context.callbacks == 0 and context:active("101") == 0)
end)

test("A canceled opener cannot claim a replacement opening for the same path", function()
    local context = fixture()
    context.app:readEpisode("1", "101", context:callback("older"))
    context:finishPrepare(1)
    local timeout = context.app.opening.timeout
    context.app:cancelPendingRead()
    context.app:readEpisode("1", "101", context:callback("replacement"))
    context:finishPrepare(2)
    local replacement = context.app.opening
    local late = context:reader(1)
    context.openers[1].callback(late)
    timeout()
    assert(late.closed and context.app.opening == replacement and context:active("101") == 1)
    assert(#context.callbacks == 0 and context.attachments == 0)
    context.openers[2].callback(context:reader(2))
    assert(#context.callbacks == 1 and context.callbacks[1].name == "replacement" and context:active("101") == 1)
end)

test("Navigation during temporary-access refresh cannot grant or open the obsolete chapter", function()
    local context = fixture()
    context:temporary("101")
    context.app:readEpisode("1", "101", context:callback("obsolete"))
    context:finishPrepare(1)
    assert(#context.refreshed == 1 and #context.openers == 0)
    context.app:cancelPendingRead()
    context.refreshed[1].callback({ comic = { id = "1" } })
    assert(context.app.account.online_read_grants["101"] == nil)
    assert(#context.openers == 0 and #context.callbacks == 0 and context:active("101") == 0)
end)

test("An obsolete temporary-access failure remains silent after navigation", function()
    local context = fixture()
    context:temporary("101")
    context.app:readEpisode("1", "101", context:callback("obsolete"))
    context:finishPrepare(1)
    context.app:cancelPendingRead()
    context.refreshed[1].callback(nil, { kind = "authentication" })
    assert(#context.callbacks == 0 and #context.openers == 0)
end)

test("A newer request retires earlier temporary-access refresh", function()
    local context = fixture()
    context:temporary("101")
    context.app:readEpisode("1", "101", context:callback("older"))
    context:finishPrepare(1)
    context.app:readEpisode("1", "102", context:callback("newer"))
    context.refreshed[1].callback({ comic = { id = "1" } })
    assert(#context.openers == 0 and context.app.account.online_read_grants["101"] == nil)
    context:finishPrepare(2)
    assert(#context.openers == 1 and context.app.opening.descriptor.episode_id == "102")
end)

test("A current temporary-access request still confirms the grant before opening", function()
    local context = fixture()
    context:temporary("101")
    context.app:readEpisode("1", "101", context:callback("current"))
    context:finishPrepare(1)
    context.refreshed[1].callback({ comic = { id = "1" } })
    assert(context.app.account.online_read_grants["101"] > os.time() and #context.openers == 1)
    context.openers[1].callback(context:reader(1))
    assert(#context.callbacks == 1 and context.callbacks[1].value and context:active("101") == 1)
end)

test("Normal opening transfers the lease to the reader and later navigation leaves it open", function()
    local context = fixture()
    context.app:readEpisode("1", "101", context:callback("current"))
    context:finishPrepare(1)
    assert(#context.callbacks == 0 and context:active("101") == 1)
    local reader = context:reader(1)
    context.openers[1].callback(reader)
    assert(context.app.opening == nil and #context.callbacks == 1 and context.callbacks[1].value)
    assert(context.attachments == 1 and context:active("101") == 1 and next(context.ui.timers) == nil)
    context.app:cancelPendingRead()
    assert(not reader.closed and reader.close_count == 0 and context:active("101") == 1)
    reader:onClose()
    assert(context:active("101") == 0 and context.app.active_integration == nil)
end)

test("Reusing an existing reader preserves its active lease and needs no second native opener", function()
    local context = fixture()
    context.app:readEpisode("1", "101", context:callback("first"))
    context:finishPrepare(1)
    local reader = context:reader(1)
    context.openers[1].callback(reader)
    context.app:readEpisode("1", "101", context:callback("existing"))
    context:finishPrepare(2)
    assert(#context.openers == 1 and #context.callbacks == 2 and context.callbacks[2].name == "existing")
    assert(context.visible_requests == 1 and context:active("101") == 1 and not reader.closed)
end)

test("Canceling foreground reading does not alter durable downloads or pending purchase records", function()
    local context = fixture()
    local store = context.app.account.store
    store:putJob{ id = "synthetic-download", kind = "episode_download", comic_id = "1", episode_id = "102",
        revision = "revision-102", state = "paused", total = 1, completed = 0, payload = { purpose = "download" } }
    store:putPurchase{ id = "synthetic-purchase", state = "quoted", comic_id = "1", episode_id = "102",
        amount = 1, method = "coin", purpose = "download" }
    local job, purchase = Codec.canonical(store:getJob("synthetic-download")), Codec.canonical(store:getPurchase("synthetic-purchase"))
    local shared_finished = false
    context.app:readEpisode("1", "101", context:callback("obsolete"))
    context.app:prepareEpisode("1", "102", function() shared_finished = true end)
    context.app:cancelPendingRead()
    context:finishPrepare(1)
    context:finishPrepare(2)
    assert(shared_finished and context.canceled_workers == 0 and #context.openers == 0)
    assert(Codec.canonical(store:getJob("synthetic-download")) == job)
    assert(Codec.canonical(store:getPurchase("synthetic-purchase")) == purchase)
end)

test("The optional opener generation preserves other native-opening callers", function()
    local context = fixture()
    context.app:_openPrepared(context.descriptors["101"], context:callback("independent"), context.app.account, context.app.generation)
    local opening = context.app.opening
    context.app:cancelPendingRead()
    assert(opening and context.app.opening == opening and context:active("101") == 1)
    context.openers[1].callback(context:reader(1))
    assert(#context.callbacks == 1 and context.callbacks[1].name == "independent" and context.callbacks[1].value)
end)

package.loaded["bilicomics/reader/integration"] = original_integration
local passed = true
for _, item in ipairs(tests) do passed = passed and item.passed end
local result = { spec = "read-navigation", host = "test-env", synthetic_data = true,
    controlled_async_boundaries = { "prepareEpisode", "refreshComic", "reader_opener" },
    native_reader_rendered = false, tests = tests, passed = passed }
Files.write(output .. "/read-navigation-result.json", json.encode(result, { pretty = true }))
print(json.encode({ spec = result.spec, passed = passed, tests = #tests }))
assert(passed, "One or more read navigation tests failed")
