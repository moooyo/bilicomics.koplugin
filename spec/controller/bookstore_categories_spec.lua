-- Run only on test-env with real SQLite, synthetic accounts and controlled anonymous workers.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(require("datastorage"):getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. package.path
local Controller = require("bilicomics/controller")
local Codec = require("bilicomics/storage/codec")
local CoverSource = require("bilicomics/cover_source")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local tests, contexts, sequence = {}, {}, 0

local function query(category_id, sort)
    return { kind = "category", category_id = category_id or "999", sort = sort or 0 }
end

local function metadata(items)
    return { source = "official_categories", items = items or {
        { id = "999", name = "Hot blood" }, { id = "1000", name = "Adventure" },
    }, orders = { { id = 0, name = "Popularity" }, { id = 1, name = "Latest updates" }, { id = 3, name = "Latest releases" } } }
end

local function comic(id, label)
    return { id = tostring(id), title = label or "Category comic " .. id,
        cover_url = "https://i0.hdslb.com/category-" .. id .. ".jpg",
        extra = { recommendation = label or "Category editorial description", evaluate = label or "Category editorial description",
            tags = { "Adventure" } } }
end

local function page(selected, number, items, has_more)
    items = items or { comic("101"), comic("102") }
    if has_more == nil then has_more = #items > 0 end
    return { source = "official_category", personalized = false, query = selected, page = number,
        page_size = 18, has_more = has_more, items = items }
end

local function homepage(items)
    return { source = "official_homepage", personalized = false, has_more = false, items = items }
end

local function ids(value)
    local result = {}
    for _, item in ipairs(value.items) do result[#result + 1] = item.id end
    return table.concat(result, ",")
end

local function sameIdentity(first, second)
    return first and second and first.account_key == second.account_key
        and first.query_key == second.query_key and first.revision == second.revision
end

local function copyIdentity(value)
    return { account_key = value.account_key, query_key = value.query_key, revision = value.revision }
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
        function runner:find(kind, method, selected, number)
            local found
            for _, task in pairs(self.tasks) do
                local request = task.request
                local actual = request.arguments and request.arguments[1]
                if request.kind == kind and (not method or request.method == method)
                    and (not selected or (type(actual) == "table" and actual.category_id == selected.category_id
                        and actual.sort == selected.sort))
                    and (not number or request.arguments[2] == number) then
                    assert(not found, "More than one matching pending worker")
                    found = task
                end
            end
            return assert(found, "No pending worker: " .. kind .. "/" .. tostring(method))
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
    context.root = root or output .. "/category-account-" .. sequence
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
            error("Public category requests must not maintain the account session")
        end
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
    function context:categories(value, err)
        self.app:refreshBookstoreCategories(self:callback("metadata"))
        local runner = self.app.account.raw_runner
        local task = runner:find("client", "bookstoreCategories")
        assert(runner:start(task))
        runner:finish(task, value or (not err and metadata()) or nil, err)
        return task
    end
    function context:refresh(selected, value, err)
        self.app:refreshBookstore(selected, self:callback("refresh"))
        local runner = self.app.account.raw_runner
        local task = runner:find("client", "bookstoreCategoryPage", selected, 1)
        assert(runner:start(task))
        runner:finish(task, value or (not err and page(selected, 1)) or nil, err)
        return task
    end
    function context:append(selected, value, err)
        local next_page = self.app:getBookstore(selected).next_page
        self.app:loadMoreBookstore(selected, self:callback("append"))
        local runner = self.app.account.raw_runner
        local task = runner:find("client", "bookstoreCategoryPage", selected, next_page)
        assert(runner:start(task))
        runner:finish(task, value or (not err and page(selected, next_page)) or nil, err)
        return task
    end
    function context:home(items)
        self.app:refreshBookstore(self:callback("homepage"))
        local runner = self.app.account.raw_runner
        local task = runner:find("client", "recommendations")
        assert(runner:start(task))
        runner:finish(task, homepage(items))
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

test("Metadata and feed getters never dispatch anonymous workers", function()
    local context = fixture()
    local empty = context.app:getBookstoreCategories()
    assert(empty.source == "official_categories" and #empty.items == 0 and empty.stale and empty.updated_at == nil)
    local initial = context.app:getBookstore(query())
    assert(initial.source == "official_category" and #initial.items == 0 and initial.stale and not initial.personalized)
    assert(context.app.account.raw_runner.count == 0)
    context:categories()
    context:refresh(query())
    local count = context.app.account.raw_runner.count
    local saved = context.app:getBookstoreCategories()
    assert(#saved.items == 2 and saved.items[1].id == "999" and saved.items[2].id == "1000")
    assert(saved.orders[1].id == 0 and saved.orders[2].id == 1 and saved.orders[3].id == 3)
    assert(saved.updated_at == 1000 and not saved.stale)
    local feed = context.app:getBookstore(query())
    assert(ids(feed) == "101,102" and feed.updated_at == 1000 and not feed.stale)
    assert(feed.loaded_pages == 1 and feed.next_page == 2 and feed.has_more and feed.can_load_more and not feed.limit_reached)
    assert(feed.identity.account_key == context.app.account.key and feed.identity.query_key and feed.identity.revision)
    assert(context.app.account.raw_runner.count == count)
end)

test("Metadata and pages remain anonymous for every account session state", function()
    for _, state in ipairs({ "none", "valid", "expired", "invalidated" }) do
        local context = fixture()
        context:guardSession(state)
        local category_task = context:categories()
        local page_task = context:refresh(query())
        for _, task in ipairs({ category_task, page_task }) do
            assert(task.request.public_bookstore == true and task.request.session == nil)
            assert(task.request.transport_options == nil and task.request.headers == nil)
        end
        assert(next(category_task.request.arguments) == nil)
        assert(page_task.request.arguments[1].kind == "category" and page_task.request.arguments[2] == 1)
        assert(context.maintenance == 0 and context.serialized == 0 and next(context.app.account.read_requests) == nil)
        assert(ids(context.app:getBookstore(query())) == "101,102")
    end
end)

test("Only categories present in current official metadata may dispatch", function()
    local context = fixture()
    local selected = query("12345")
    context:categories(metadata({ { id = "12345", name = "New official category" } }))
    context:refresh(selected, page(selected, 1, { comic("501") }))
    local count = context.app.account.raw_runner.count
    context.app:refreshBookstore(query("999"), context:callback("unknown")); context.ui:drain()
    assert(context:last("unknown").error and context:last("unknown").value == nil)
    assert(context.app.account.raw_runner.count == count and #context.app:getBookstore(query("999")).items == 0)
    context:categories(metadata({ { id = "1000", name = "Current official category" } }))
    count = context.app.account.raw_runner.count
    context.app:refreshBookstore(selected, context:callback("retired")); context.ui:drain()
    assert(context:last("retired").error and context.app.account.raw_runner.count == count)
    assert(ids(context.app:getBookstore(selected)) == "501")
end)

test("Malformed queries and out of range public pages are rejected before dispatch", function()
    local context = fixture()
    context:categories()
    local before = context.app.account.raw_runner.count
    for _, selected in ipairs({ query("999", -1), query("999", 2), query("999", 4), query("999", 0.5),
        query("not-an-id"), { kind = "other", category_id = "999", sort = 0 },
        { kind = "category", category_id = "999", sort = 0, page = 1 },
        { category_id = "999", sort = 0, session = "synthetic-secret" } }) do
        local empty = context.app:getBookstore(selected)
        assert(type(empty) == "table" and #empty.items == 0 and empty.stale)
        context.app:refreshBookstore(selected, context:callback("invalid refresh"))
        context.app:loadMoreBookstore(selected, context:callback("invalid append")); context.ui:drain()
        assert(context:last("invalid refresh").error and context:last("invalid append").error)
    end
    for _, number in ipairs({ 0, 6, -1, 1.5 }) do
        context.app:_submit({ kind = "client", method = "bookstoreCategoryPage", arguments = { query(), number },
            public_bookstore = true }, {}, context:callback("invalid page")); context.ui:drain()
        assert(context:last("invalid page").error.kind == "invalid_request")
    end
    context.app:_submit({ kind = "client", method = "bookstoreCategories", arguments = { "private" },
        public_bookstore = true }, {}, context:callback("invalid metadata")); context.ui:drain()
    assert(context:last("invalid metadata").error.kind == "invalid_request")
    assert(context.app.account.raw_runner.count == before and context.maintenance == 0 and context.serialized == 0)
end)

test("Default queries coalesce while categories and official orders remain independent", function()
    local context = fixture()
    context:categories()
    local first, second, newest = query(), query("1000"), query("999", 3)
    local runner, before = context.app.account.raw_runner, context.app.account.raw_runner.count
    context.app:refreshBookstore({ category_id = "999" }, context:callback("default"))
    context.app:refreshBookstore(first, context:callback("canonical"))
    context.app:refreshBookstore(second, context:callback("second"))
    context.app:refreshBookstore(newest, context:callback("newest"))
    assert(runner.count == before + 3)
    runner:finish(runner:find("client", "bookstoreCategoryPage", newest, 1), page(newest, 1, { comic("301") }))
    runner:finish(runner:find("client", "bookstoreCategoryPage", second, 1), page(second, 1, { comic("201") }))
    runner:finish(runner:find("client", "bookstoreCategoryPage", first, 1), page(first, 1, { comic("101") }))
    assert(ids(context:last("default").value) == "101" and ids(context:last("canonical").value) == "101")
    assert(ids(context:last("second").value) == "201" and ids(context:last("newest").value) == "301")
    assert(ids(context.app:getBookstore(first)) == "101" and ids(context.app:getBookstore(second)) == "201")
    assert(ids(context.app:getBookstore(newest)) == "301")
    assert(context.app:getBookstore(first).identity.query_key ~= context.app:getBookstore(second).identity.query_key)
    assert(context.app:getBookstore(first).identity.query_key ~= context.app:getBookstore(newest).identity.query_key)
end)

test("Metadata refresh coalesces and failures retain the last official list", function()
    local context = fixture()
    context.app:refreshBookstoreCategories(context:callback("one"))
    context.app:refreshBookstoreCategories(context:callback("two"))
    local runner = context.app.account.raw_runner
    assert(runner.count == 1)
    runner:finish(runner:find("client", "bookstoreCategories"), metadata())
    assert(context:last("one").value.items[1].id == "999" and context:last("two").value.items[1].id == "999")
    context:categories(nil, { kind = "timeout" })
    local retained = context.app:getBookstoreCategories()
    assert(retained.items[1].id == "999" and retained.updated_at == 1000 and retained.stale)
    assert(context:last("metadata").error.kind == "timeout")
    context.now = 1100
    context:categories(metadata({ { id = "1000", name = "Replacement category" } }))
    local saved = context.app:getBookstoreCategories()
    assert(#saved.items == 1 and saved.items[1].id == "1000" and saved.updated_at == 1100 and not saved.stale)
end)

test("Malformed metadata responses preserve the last usable official category list", function()
    local context = fixture()
    context:categories()
    local invalid_sort = metadata()
    invalid_sort.orders = { { id = 2, name = "Unsupported order" } }
    local duplicate = metadata({ { id = "999", name = "First" }, { id = "999", name = "Duplicate" } })
    local wrong_source = metadata()
    wrong_source.source = "untrusted_categories"
    for _, invalid in ipairs({ {}, wrong_source, invalid_sort, duplicate }) do
        context:categories(invalid)
        local saved = context.app:getBookstoreCategories()
        assert(context:last("metadata").error and saved.items[1].id == "999" and #saved.items == 2)
        assert(saved.updated_at == 1000 and saved.stale)
    end
end)

test("Failed first page retains all pages and a successful refresh replaces them atomically", function()
    local context, selected = fixture(), query()
    context:categories()
    context:refresh(selected, page(selected, 1, { comic("101"), comic("102") }))
    context:append(selected, page(selected, 2, { comic("103") }))
    local before = context.app:getBookstore(selected)
    context:refresh(selected, nil, { kind = "timeout" })
    local retained = context.app:getBookstore(selected)
    assert(ids(retained) == "101,102,103" and retained.loaded_pages == 2 and retained.next_page == 3)
    assert(retained.updated_at == before.updated_at and retained.stale and sameIdentity(retained.identity, before.identity))
    context.now = 1100
    context:refresh(selected, page(selected, 1, { comic("104") }))
    local updated = context.app:getBookstore(selected)
    assert(ids(updated) == "104" and updated.loaded_pages == 1 and updated.next_page == 2 and not updated.stale)
    assert(updated.updated_at == 1100 and not sameIdentity(updated.identity, before.identity))
end)

test("Starting a first page refresh invalidates an older append even if refresh fails", function()
    for _, failed in ipairs({ false, true }) do
        local context, selected = fixture(), query()
        context:categories()
        context:refresh(selected, page(selected, 1, { comic("101") }))
        local runner = context.app.account.raw_runner
        context.app:loadMoreBookstore(selected, context:callback("old append"))
        local old = runner:find("client", "bookstoreCategoryPage", selected, 2)
        assert(runner:start(old))
        context.app:refreshBookstore(selected, context:callback("new refresh"))
        local refresh = runner:find("client", "bookstoreCategoryPage", selected, 1)
        if failed then runner:finish(refresh, nil, { kind = "timeout" })
        else runner:finish(refresh, page(selected, 1, { comic("104") })) end
        runner:finish(old, page(selected, 2, { comic("9999") }))
        local saved = context.app:getBookstore(selected)
        assert(ids(saved) == (failed and "101" or "104") and saved.loaded_pages == 1 and saved.next_page == 2)
        assert(context.app.account.store:getComic("9999") == nil)
    end
end)

test("Append coalesces callers and preserves order across duplicate and short nonempty pages", function()
    local context, selected = fixture(), query()
    context:categories()
    context:refresh(selected, page(selected, 1, { comic("102"), comic("101"), comic("102", "Duplicate title") }))
    local runner, before = context.app.account.raw_runner, context.app.account.raw_runner.count
    context.app:loadMoreBookstore(selected, context:callback("append one"))
    context.app:loadMoreBookstore(selected, context:callback("append two"))
    assert(runner.count == before + 1)
    runner:finish(runner:find("client", "bookstoreCategoryPage", selected, 2),
        page(selected, 2, { comic("101", "Must not replace first occurrence"), comic("103"), comic("102") }))
    local saved = context.app:getBookstore(selected)
    assert(ids(saved) == "102,101,103" and saved.items[2].title ~= "Must not replace first occurrence")
    assert(ids(context:last("append one").value) == ids(context:last("append two").value))
    assert(saved.has_more and saved.can_load_more and saved.next_page == 3)
    context:append(selected, page(selected, 3, { comic("102"), comic("101"), comic("103") }))
    saved = context.app:getBookstore(selected)
    assert(ids(saved) == "102,101,103" and saved.loaded_pages == 3 and saved.next_page == 4)
    assert(saved.has_more and saved.can_load_more and not saved.limit_reached)
    context:append(selected, page(selected, 4, {}))
    saved = context.app:getBookstore(selected)
    assert(ids(saved) == "102,101,103" and saved.loaded_pages == 4 and not saved.has_more and not saved.can_load_more)
    before = runner.count
    context.app:loadMoreBookstore(selected, context:callback("finished")); context.ui:drain()
    assert(runner.count == before)
end)

test("Failed append retries the same page without modifying the cached order", function()
    local context, selected = fixture(), query()
    context:categories()
    context:refresh(selected, page(selected, 1, { comic("101") }))
    local original = context.app:getBookstore(selected)
    context:append(selected, nil, { kind = "timeout" })
    local retained = context.app:getBookstore(selected)
    assert(ids(retained) == "101" and retained.loaded_pages == 1 and retained.next_page == 2)
    assert(sameIdentity(retained.identity, original.identity))
    local task = context:append(selected, page(selected, 2, { comic("102") }))
    assert(task.request.arguments[2] == 2 and ids(context.app:getBookstore(selected)) == "101,102")
end)

test("Five remote pages impose an independent ninety comic cap per category and order", function()
    local context, first, second = fixture(), query(), query("999", 1)
    context:categories()
    for number = 1, 5 do
        local items = {}
        for offset = 1, 18 do items[#items + 1] = comic(tostring(1000 + (number - 1) * 18 + offset)) end
        if number == 1 then context:refresh(first, page(first, number, items))
        else context:append(first, page(first, number, items)) end
    end
    local full = context.app:getBookstore(first)
    assert(#full.items == 90 and full.items[1].id == "1001" and full.items[90].id == "1090")
    assert(full.loaded_pages == 5 and full.has_more and full.limit_reached and not full.can_load_more)
    local before = context.app.account.raw_runner.count
    context.app:loadMoreBookstore(first, context:callback("cap")); context.ui:drain()
    assert(context.app.account.raw_runner.count == before)
    context:refresh(second, page(second, 1, { comic("201") }))
    context:append(second, page(second, 2, { comic("202") }))
    assert(ids(context.app:getBookstore(second)) == "201,202" and context.app:getBookstore(second).can_load_more)
    assert(#context.app:getBookstore(first).items == 90 and context.app:getBookstore(first).limit_reached)
end)

test("Duplicate pages also stop at the fifth remote request", function()
    local context, selected = fixture(), query()
    context:categories()
    context:refresh(selected, page(selected, 1, { comic("101") }))
    for number = 2, 5 do context:append(selected, page(selected, number, { comic("101") })) end
    local saved = context.app:getBookstore(selected)
    assert(ids(saved) == "101" and saved.loaded_pages == 5 and saved.limit_reached and saved.has_more and not saved.can_load_more)
    local before = context.app.account.raw_runner.count
    context.app:loadMoreBookstore(selected, context:callback("duplicate cap")); context.ui:drain()
    assert(context.app.account.raw_runner.count == before)
end)

test("Mismatched category order and page responses cannot replace a cached snapshot", function()
    local context, selected = fixture(), query()
    context:categories()
    context:refresh(selected, page(selected, 1, { comic("101") }))
    for _, response in ipairs({ page(query("1000"), 1, { comic("201") }),
        page(query("999", 3), 1, { comic("201") }), page(selected, 2, { comic("201") }),
        { source = "other", personalized = false, query = selected, page = 1, page_size = 18, has_more = true, items = { comic("201") } } }) do
        context:refresh(selected, response)
        assert(context:last("refresh").error and ids(context.app:getBookstore(selected)) == "101")
        assert(context.app.account.store:getComic("201") == nil)
    end
end)

test("Category snapshot and comic persistence roll back together after a storage failure", function()
    local context, selected = fixture(), query()
    context:categories()
    context:refresh(selected, page(selected, 1, { comic("101") }))
    local store = context.app.account.store
    local previous = Codec.canonical(store:getComic("101"))
    local original = store.putSetting
    store.putSetting = function() error("Injected category snapshot persistence failure") end
    context:refresh(selected, page(selected, 1, { comic("101", "Must roll back"), comic("9999") }))
    store.putSetting = original
    assert(context:last("refresh").error.kind == "storage")
    assert(ids(context.app:getBookstore(selected)) == "101" and Codec.canonical(store:getComic("101")) == previous)
    assert(store:getComic("9999") == nil)
end)

test("Queued anonymous category work rechecks offline suspension and account generation", function()
    for _, mutation in ipairs({ "offline", "suspended", "account" }) do
        local context, selected = fixture(), query()
        context:categories()
        context.app:refreshBookstore(selected, context:callback("queued page"))
        context.app:refreshBookstoreCategories(context:callback("queued metadata"))
        local runner = context.app.account.raw_runner
        local page_task = runner:find("client", "bookstoreCategoryPage", selected, 1)
        local category_task = runner:find("client", "bookstoreCategories")
        local before = #context.callbacks
        if mutation == "offline" then context.network.connected = false
        elseif mutation == "suspended" then context.app.suspended = true
        else
            context.old_accounts[#context.old_accounts + 1] = context.app.account
            context.app:_openAccount("bili_43", nil)
        end
        assert(not runner:start(page_task) and not runner:start(category_task))
        assert(page_task.started == nil and category_task.started == nil and #context.app:getBookstore(selected).items == 0)
        if mutation == "account" then assert(#context.callbacks == before) end
        assert(context.maintenance == 0 and context.serialized == 0)
    end
end)

test("Offline restart retains metadata query order and the next page without dispatch", function()
    local context, first, second = fixture(), query(), query("999", 3)
    context:categories()
    context:refresh(first, page(first, 1, { comic("102"), comic("101") }))
    context:append(first, page(first, 2, { comic("103") }))
    context:refresh(second, page(second, 1, { comic("201") }))
    context.app:close()
    local restarted = fixture(context.root)
    restarted.network.connected = false
    local saved = restarted.app:getBookstore(first)
    assert(ids(saved) == "102,101,103" and saved.loaded_pages == 2 and saved.next_page == 3 and saved.updated_at == 1000)
    assert(ids(restarted.app:getBookstore(second)) == "201" and #restarted.app:getBookstoreCategories().items == 2)
    restarted.app:refreshBookstore(first, restarted:callback("offline")); restarted.ui:drain()
    assert(restarted:last("offline").error.kind == "network" and ids(restarted.app:getBookstore(first)) == "102,101,103")
    assert(restarted.app.account.raw_runner.count == 0)
end)

test("Expired metadata still allows offline browsing of saved category feeds", function()
    local context, selected = fixture(), query()
    context:categories()
    context:refresh(selected, page(selected, 1, { comic("101") }))
    context.now = 1000000000
    context.network.connected = false
    local before = context.app.account.raw_runner.count
    assert(context.app:getBookstoreCategories().stale and #context.app:getBookstoreCategories().items == 2)
    assert(context.app:getBookstore(selected).stale and ids(context.app:getBookstore(selected)) == "101")
    context.app:refreshBookstoreCategories(context:callback("offline metadata"))
    context.app:loadMoreBookstore(selected, context:callback("offline append")); context.ui:drain()
    assert(context:last("offline metadata").error.kind == "network" and context:last("offline append").error.kind == "network")
    assert(context.app.account.raw_runner.count == before and ids(context.app:getBookstore(selected)) == "101")
    context.app:close()
    local restarted = fixture(context.root)
    restarted.now, restarted.network.connected = 1000000000, false
    assert(restarted.app:getBookstoreCategories().stale and ids(restarted.app:getBookstore(selected)) == "101")
    assert(restarted.app.account.raw_runner.count == 0)
end)

test("Category editorial projections preserve homepage provenance favorites and exact reading anchors", function()
    local context, selected = fixture(), query()
    local account = context.app.account
    account.catalog:ingestDetail({ comic = { id = "101", title = "Owned title", favorite = true },
        episodes = { { id = "1001", comic_id = "101", order = 1, title = "Opening chapter", access = "free" } } })
    account.store:upsertComic{ id = "101", favorite = true, read = "retained-user-state" }
    local descriptor = { schema_version = 1, account_key = account.key, comic_id = "101", episode_id = "1001",
        revision = "local-version", pages = { { id = "page-1", index = 1, width = 20, height = 40 } } }
    account.pages:ensureDescriptor(descriptor)
    account.catalog:updatePosition(descriptor, { index = 1, page_id = "page-1", x = 0.2, y = 0.6, finished = false })
    local original = comic("101", "Homepage recommendation")
    original.extra.tags, original.extra.recommendation_section = { "Homepage tag" }, "hot_seller"
    context:home({ original })
    local home_before = Codec.canonical(context.app:getBookstore().items[1].extra)
    local anchor = Codec.canonical(account.store:getAnchor("1001", "local-version"))
    local episode = Codec.canonical(account.store:getEpisode("1001"))
    local incoming = comic("101", "Category description")
    incoming.extra.recommendation_section, incoming.extra.tags = "completed", { "Category tag" }
    incoming.favorite, incoming.read, incoming.current_episode_id = false, false, "wrong"
    incoming.reading_position = { index = 999 }
    incoming.extra.reading_position, incoming.extra.progress_source = { index = 999 }, "server"
    incoming.extra.favorite, incoming.extra.Cookie = false, "SESSDATA=must-not-be-cached"
    context:categories()
    context:refresh(selected, page(selected, 1, { incoming }))
    local category = context.app:getBookstore(selected).items[1]
    assert(category.extra.recommendation == "Category description" and category.extra.tags[1] == "Category tag")
    assert(category.extra.recommendation_section == nil and category.extra.Cookie == nil)
    assert(Codec.canonical(context.app:getBookstore().items[1].extra) == home_before)
    assert(category.favorite and category.read == "retained-user-state" and category.current_episode_id == "1001")
    assert(category.reading_position.index == 1 and category.extra.progress_source == "local")
    assert(Codec.canonical(account.store:getAnchor("1001", "local-version")) == anchor)
    assert(Codec.canonical(account.store:getEpisode("1001")) == episode)
    assert(#context.app:getLibrary("favorites") == 1 and context.app:getLibrary("favorites")[1].id == "101")
    local updated_home = comic("101", "New homepage description")
    updated_home.extra.recommendation_section = "internet_hot"
    context:home({ updated_home })
    category = context.app:getBookstore(selected).items[1]
    assert(category.extra.recommendation == "Category description" and category.extra.tags[1] == "Category tag")
    assert(category.extra.recommendation_section == nil and category.favorite and category.reading_position.index == 1)
end)

test("Category covers require the correct snapshot member and identity", function()
    local context, first, second = fixture(), query(), query("1000")
    context:guardSession("invalidated")
    context:categories()
    context:refresh(first, page(first, 1, { comic("101") }))
    context:refresh(second, page(second, 1, { comic("201") }))
    context.app.account.store:upsertComic(comic("9999"))
    local identity = context.app:getBookstore(first).identity
    local forged_account, forged_query, forged_revision = copyIdentity(identity), copyIdentity(identity), copyIdentity(identity)
    forged_account.account_key, forged_query.query_key, forged_revision.revision = "bili_43", "unknown-query", "unknown-revision"
    local runner, before = context.app.account.raw_runner, context.app.account.raw_runner.count
    context.app:requestBookstoreCover("101")
    context.app:requestBookstoreCover("9999", identity)
    context.app:requestBookstoreCover("201", identity)
    context.app:requestBookstoreCover("101", context.app:getBookstore(second).identity)
    for _, invalid in ipairs({ {}, forged_account, forged_query, forged_revision }) do
        context.app:requestBookstoreCover("101", invalid)
    end
    assert(runner.count == before)
    context.app:requestBookstoreCover("101", identity)
    context.app:requestBookstoreCover("101", identity)
    assert(runner.count == before + 1)
    local task = runner:find("download_cover")
    assert(task.request.comic_id == "101" and task.request.url == CoverSource.resolve(comic("101").cover_url).url)
    assert(task.request.public_bookstore == true and task.request.session == nil and task.request.transport_options == nil)
    assert(runner:start(task))
    runner:finish(task, context:coverResult(task))
    assert(Files.exists(context.app.account.store:getComic("101").cover_path))
    assert(context.maintenance == 0 and context.serialized == 0)
end)

test("A refreshed category revision rejects old covers before start and after completion", function()
    for _, started in ipairs({ false, true }) do
        local context, selected = fixture(), query()
        context:categories()
        context:refresh(selected, page(selected, 1, { comic("101") }))
        local previous = context.app:getBookstore(selected).identity
        context.app:requestBookstoreCover("101", previous)
        local runner = context.app.account.raw_runner
        local task = runner:find("download_cover")
        if started then assert(runner:start(task)) end
        local result = context:coverResult(task)
        context:refresh(selected, page(selected, 1, { comic("101", "Updated same member") }))
        local before = runner.count
        context.app:requestBookstoreCover("101", previous)
        assert(runner.count == before)
        if started then runner:finish(task, result) else assert(not runner:start(task)) end
        assert(not Files.exists(result.temporary_path) and context.app.account.store:getComic("101").cover_path == nil)
    end
end)

test("Changed cover URLs cannot authorize downloads through an older category snapshot", function()
    local context, first, second = fixture(), query(), query("1000")
    context:categories()
    context:refresh(first, page(first, 1, { comic("101") }))
    local identity = context.app:getBookstore(first).identity
    context.app:requestBookstoreCover("101", identity)
    local runner = context.app.account.raw_runner
    local task = runner:find("download_cover")
    assert(runner:start(task))
    local result = context:coverResult(task)
    local replacement = comic("101")
    replacement.cover_url = "https://i0.hdslb.com/replaced-101.jpg"
    context:refresh(second, page(second, 1, { replacement }))
    local before = runner.count
    context.app:requestBookstoreCover("101", identity)
    runner:finish(task, result)
    assert(runner.count == before and not Files.exists(result.temporary_path))
    assert(context.app.account.store:getComic("101").cover_path == nil)
    context.app:requestBookstoreCover("101", context.app:getBookstore(second).identity)
    assert(runner:find("download_cover").request.url == CoverSource.resolve(replacement.cover_url).url)
end)

test("Account changes and close discard pending metadata and page callbacks", function()
    for _, change in ipairs({ "account", "close" }) do
        local context, selected = fixture(), query()
        context:categories()
        context.app:refreshBookstoreCategories(context:callback("late metadata"))
        context.app:refreshBookstore(selected, context:callback("late page"))
        local account, runner = context.app.account, context.app.account.raw_runner
        local category_task = runner:find("client", "bookstoreCategories")
        local page_task = runner:find("client", "bookstoreCategoryPage", selected, 1)
        assert(runner:start(category_task) and runner:start(page_task))
        local before = #context.callbacks
        if change == "account" then
            context.old_accounts[#context.old_accounts + 1] = account
            context.app:_openAccount("bili_43", nil)
        else context.app:close() end
        runner:finish(category_task, metadata({ { id = "12345", name = "Late metadata" } }))
        runner:finish(page_task, page(selected, 1, { comic("9999") }))
        assert(#context.callbacks == before)
        if change == "account" then
            assert(#context.app:getBookstoreCategories().items == 0 and #context.app:getBookstore(selected).items == 0)
            assert(account.store:getComic("9999") == nil and context.app.account.store:getComic("9999") == nil)
        else assert(context.app.closed) end
    end
end)

test("Account changes invalidate category cover identities and clean late temporary files", function()
    local context, selected = fixture(), query()
    context:categories()
    context:refresh(selected, page(selected, 1, { comic("101") }))
    local old_identity = context.app:getBookstore(selected).identity
    context.app:requestBookstoreCover("101", old_identity)
    local old_account, old_runner = context.app.account, context.app.account.raw_runner
    local task = old_runner:find("download_cover")
    assert(old_runner:start(task))
    local result = context:coverResult(task)
    context.old_accounts[#context.old_accounts + 1] = old_account
    context.app:_openAccount("bili_43", nil)
    context:guardSession("none")
    context:categories()
    context:refresh(selected, page(selected, 1, { comic("101") }))
    local before = context.app.account.raw_runner.count
    context.app:requestBookstoreCover("101", old_identity)
    assert(context.app.account.raw_runner.count == before)
    old_runner:finish(task, result)
    assert(not Files.exists(result.temporary_path) and old_account.store:getComic("101").cover_path == nil)
    assert(context.app.account.store:getComic("101").cover_path == nil)
end)

test("Forged credentials are stripped from otherwise valid anonymous category requests", function()
    local context = fixture()
    context:guardSession("valid")
    context:categories()
    for _, request in ipairs({ { kind = "client", method = "bookstoreCategories", arguments = {} },
        { kind = "client", method = "bookstoreCategoryPage", arguments = { query(), 1 } } }) do
        request.public_bookstore = true
        request.session = { cookies = { SESSDATA = "injected-secret" } }
        request.transport_options, request.headers = { headers = { Cookie = "private" } }, { Authorization = "private" }
        context.app:_submit(request, {}, context:callback("stripped"))
        local task = context.app.account.raw_runner:find("client", request.method)
        assert(task.request.session == nil and task.request.transport_options == nil and task.request.headers == nil)
    end
    assert(context.serialized == 0 and context.maintenance == 0)
end)

local passed = true
for _, item in ipairs(tests) do passed = passed and item.passed end
Files.write(output .. "/bookstore-categories-controller-result.json", json.encode({ spec = "bookstore-categories-controller",
    host = "test-env", synthetic_data = true, network_workers_executed = false, tests = tests, passed = passed }, { pretty = true }))
print(json.encode({ spec = "bookstore-categories-controller", tests = #tests, passed = passed }))
assert(passed, "One or more bookstore category controller tests failed")
