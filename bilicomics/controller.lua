local Catalog = require("bilicomics/catalog/init")
local Bookshelf = require("bilicomics/bookshelf_state")
local Bookstore = require("bilicomics/bookstore")
local Categories = require("bilicomics/bookstore_categories")
local Codec = require("bilicomics/storage/codec")
local ComicID = require("bilicomics/catalog/comic_id")
local CoverSource = require("bilicomics/cover_source")
local DownloadService = require("bilicomics/jobs/download_service")
local Files = require("bilicomics/storage/files")
local Normalize = require("bilicomics/protocol/normalize")
local PageStore = require("bilicomics/storage/page_store")
local Provider = require("bilicomics/reader/document")
local PurchaseService = require("bilicomics/purchase/service")
local PurchaseSelection = require("bilicomics/purchase/selection")
local Runner = require("bilicomics/jobs/runner")
local Session = require("bilicomics/protocol/session")
local SessionStorage = require("bilicomics/session_storage")
local SessionManager = require("bilicomics/session_manager")
local SessionRunner = require("bilicomics/jobs/session_runner")
local Settings = require("bilicomics/settings")
local Store = require("bilicomics/storage/store")
local Util = require("bilicomics/util")
local _ = require("bilicomics/ui/i18n")

local Controller = {}
Controller.__index = Controller

local function accountKey(value)
    if type(value) == "string" and value:match("^bili_[1-9]%d*$") then return value end
    return "anonymous"
end

local function errorValue(kind, message, fields) return Util.error(kind, message, fields) end
local function id(value) return value ~= nil and tostring(value) or nil end
local function currentRead(controller, account, generation, read_generation)
    return not controller.closed and controller.account == account and controller.generation == generation
        and (read_generation == nil or controller.read_generation == read_generation)
end

function Controller.new(options)
    options = options or {}
    local root = assert(options.root, "A private plugin data root is required"):gsub("/+$", "")
    if root:sub(1, 1) ~= "/" then root = require("libs/libkoreader-lfs").currentdir() .. "/" .. root end
    root = root:gsub("/%./", "/")
    for component in root:gmatch("[^/]+") do assert(component ~= "..", "The data root must be resolved") end
    Files.mkdir(root)
    local self = setmetatable({ root = root, host_ui = options.ui,
        ui_manager = options.ui_manager or require("ui/uimanager"), runner_factory = options.runner_factory,
        reader_opener = options.reader_opener, settings = options.settings or Settings.open(root),
        generation = 0, read_generation = 0, closed = false, preparing = {}, covers = {}, quotes = {}, purchase_inflight = {},
        clock = options.clock or os.time,
        integrations = {}, preloaded = {}, errors_shown = {}, reader_dialogs = {},
        network = options.network or require("ui/network/manager") }, Controller)
    self.session_storage = options.session_storage or SessionStorage.new{ data_root = root }
    local key = accountKey(self.settings:get("active_account_key"))
    local session = self.session_storage:load(key)
    self:_openAccount(key, session)
    Provider:setServicesResolver(function(requested)
        local active = self.account
        if not self.closed and active and requested == active.key then return active.reader_services end
    end)
    return self
end

function Controller:setScreens(screens) self.screens = screens end
function Controller:setHostUI(ui) self.host_ui = ui end

function Controller:_notify()
    if self.closed or self.notify_pending then return end
    self.notify_pending = true
    local generation = self.generation
    self.ui_manager:nextTick(function()
        self.notify_pending = nil
        if not self.closed and generation == self.generation and self.screens then self.screens:refresh() end
    end)
end

function Controller:_later(callback, value, err)
    local generation = self.generation
    self.ui_manager:nextTick(function()
        if self.generation == generation then Util.callback(callback, value, err) end
    end)
end

function Controller:_openAccount(key, session, verified_import)
    self.generation = self.generation + 1
    self.preparing, self.covers, self.cover_failures, self.quotes, self.purchase_inflight = {}, {}, {}, {}, {}
    self.preloaded, self.errors_shown = {}, {}
    local root = self.root .. "/accounts/" .. Files.component(key)
    Files.mkdir(root)
    local account = { key = key, root = root, session = session, session_valid = session ~= nil,
        generation = self.generation, online_read_grants = {}, pending_submission_results = {},
        authentication_generation = 0, read_requests = {}, favorite_operations = {}, favorite_versions = {}, favorite_revision = 0,
        validated_descriptors = setmetatable({}, { __mode = "k" }) }
    account.store = Store.open{ root = root, account_key = key }
    if verified_import then account.store:putSetting("session_invalidated", false)
    elseif account.store:getSetting("session_invalidated", false) then
        account.session_valid, account.authentication_invalidated = false, true
        account.authentication_generation = 1
    end
    account.pages = PageStore.new{ root = root, account_key = key, store = account.store }
    account.purchases = PurchaseService.new{ store = account.store, account_key = key }
    account.catalog = Catalog.new{ store = account.store, pages = account.pages }
    self.account = account
    local runner_options = { ui = self.ui_manager, image_concurrency = self:getSetting("download_concurrency", 2) }
    local raw_runner = self.runner_factory and self.runner_factory(runner_options) or Runner.new(runner_options)
    account.raw_runner = raw_runner
    local function current() return not self.closed and self.account == account and self.generation == account.generation end
    account.session_manager = SessionManager.new{
        runner = raw_runner, get_session = function() return account.session end,
        save_session = function(candidate) return self:_saveRenewedSession(account, candidate) end,
        clock = self.clock, is_current = current, on_state = function() if current() then self:_notify() end end,
    }
    self.runner = SessionRunner.new{ runner = raw_runner, manager = account.session_manager,
        get_session = function() return account.session end, is_current = current }
    account.runner = self.runner
    account.purchases:recover()
    account.downloads = DownloadService.new{
        store = account.store, pages = account.pages, runner = self.runner, account_key = key, settings = self.settings,
        ui = self.ui_manager, session = function() return account.session and account.session:serialize() end,
        authentication_valid = function() return account.session ~= nil and account.session_valid == true end,
        network_available = function()
            return not self.closed and not self.suspended and self.account == account
                and self.generation == account.generation and self:_connected()
        end,
        on_authentication_error = function(err) self:_invalidateAuthentication(account, err) end,
        prepare = function(comic_id, episode_id, callback) self:prepareEpisode(comic_id, episode_id, callback) end,
        notify = function() if self.account == account then self:_notify() end end,
        page_ready = function(page)
            if self.account ~= account then return end
            for integration in pairs(self.integrations) do integration:notifyPageReady(page) end
        end,
    }
    account.downloads:recover()
    account.reader_services = {
        store = account.store, pages = account.pages,
        settings = { max_lossless_pixels = self.settings:get("max_lossless_pixels", 4000000),
            max_jpeg_pixels = self.settings:get("max_jpeg_pixels", 32000000),
            max_tile_bytes = self.settings:get("max_tile_bytes", 16777216),
            get = function(_settings, key, default) return self:getSetting(key, default) end },
        isCurrent = function() return not self.closed and self.account == account and self.generation == account.generation end,
        authorizeDescriptor = function(descriptor) return self:authorizeDescriptor(descriptor, account) end,
        requestPage = function(descriptor, index, request_options) self:_requestReaderPage(account, descriptor, index, request_options) end,
        onReaderEvent = function(name, event)
            if not self.closed and self.account == account then self:_readerEvent(name, event) end
        end,
    }
end

function Controller:_releaseOpening(err)
    local opening = self.opening
    if not opening then return end
    self.opening = nil
    if opening.timeout then self.ui_manager:unschedule(opening.timeout) end
    if opening.active_guard then
        opening.account.pages:setActiveEpisode(opening.descriptor.episode_id, opening.descriptor.revision, false)
        opening.active_guard = nil
    end
    if err then Util.callback(opening.callback, nil, err) end
    return opening
end

function Controller:_closeAccount()
    local account = self.account
    if not account then return end
    self:cancelQRLogin()
    for dialog in pairs(self.reader_dialogs) do self.ui_manager:close(dialog) end
    self.reader_dialogs = {}
    if self.chapter_dialog then self.ui_manager:close(self.chapter_dialog); self.chapter_dialog = nil end
    for integration in pairs(self.integrations) do
        integration:close()
        if integration.reader.onClose then integration.reader:onClose() end
    end
    self.integrations = {}
    self:_releaseOpening(errorValue("closed", "The active account is closing."))
    self.generation = self.generation + 1
    account.downloads:close()
    self.runner:close()
    if self.diagnostics_runner then self.diagnostics_runner:close(); self.diagnostics_runner = nil end
    for intent_id, observed in pairs(account.pending_submission_results) do
        account.purchases:completeSubmission(intent_id, observed.response, observed.error)
    end
    -- Recover only after the old workers have been killed and reaped.
    account.purchases:recover()
    if account.recharge_service then account.recharge_service:close() end
    account.store:close()
    self.account, self.runner = nil, nil
end

function Controller:close()
    if self.closed then return end
    if self.screens then self.screens:close() end
    self:_closeAccount()
    self.closed = true
    self.settings:flush()
end

function Controller:suspend()
    if self.closed or not self.account then return end
    self:cancelQRLogin()
    if self.screens and self.screens._rechargeClose then self.screens:_rechargeClose() end
    for integration in pairs(self.integrations) do integration:saveAnchor() end
    if not self.suspended then
        self.suspended_jobs = {}
        for _index, job in ipairs(self.account.store:listJobs({ "running", "queued" })) do
            if job.kind == "episode_download" then self.suspended_jobs[#self.suspended_jobs + 1] = job.id end
        end
    end
    self.account.downloads:suspend()
    self.runner:suspend()
    if self.diagnostics_runner then self.diagnostics_runner:suspend() end
    self.suspended = true
    self.settings:flush()
end

function Controller:_connected()
    local ok, connected = pcall(self.network.isConnected, self.network)
    return ok and connected == true
end

function Controller:_invalidateAuthentication(account)
    if self.closed or self.account ~= account or self.generation ~= account.generation or account.authentication_invalidated then return false end
    account.session_valid, account.authentication_invalidated = false, true
    account.authentication_generation = account.authentication_generation + 1
    account.online_read_grants = {}
    self.suspended_jobs = nil
    -- A public boolean keeps a known-invalid private session disabled across restarts.
    pcall(account.store.putSetting, account.store, "session_invalidated", true)
    account.downloads:invalidateAuthentication()
    local canceling = {}
    for task_id in pairs(account.read_requests) do canceling[#canceling + 1] = task_id end
    for _index, task_id in ipairs(canceling) do account.runner:cancel(task_id) end
    self:_notify()
    return true
end

function Controller:resume()
    if self.closed or not self.account then return end
    if self.diagnostics_runner then self.diagnostics_runner:resume() end
    if not self:_connected() then self.suspended = true; return false end
    self.suspended = false
    self.runner:resume()
    local suspended_jobs = self.suspended_jobs or {}; self.suspended_jobs = nil
    for _index, job_id in ipairs(suspended_jobs) do
        local job = self.account.store:getJob(job_id)
        if job and job.state == "paused" and self.account.session_valid then self.account.downloads:resume(job_id) end
    end
    self.preloaded = {}
    for integration in pairs(self.integrations) do
        self.account.downloads:clearFailures(integration.document.descriptor.episode_id)
        integration:requestVisible()
    end
    self:_notify()
    return true
end

function Controller:_diagnosticsRunner()
    if not self.diagnostics_runner then
        local options = { ui = self.ui_manager, max_workers = 1 }
        self.diagnostics_runner = self.runner_factory and self.runner_factory(options) or Runner.new(options)
    end
    return self.diagnostics_runner
end

function Controller:_submit(request, options, callback)
    if self.closed or not self.account then
        self:_later(callback, nil, errorValue("closed", "The plugin is closed.")); return
    end
    local account, generation = self.account, self.generation
    local diagnostics = request.kind == "diagnostics"
    local public_bookstore = request.public_bookstore == true
    if public_bookstore then
        if not self:_bookstoreRequestAllowed(request) then
            self:_later(callback, nil, errorValue("invalid_request", "This operation is not a public bookstore request.", { transmitted = false }))
            return
        end
        -- Use a narrow request shape so explicit or inherited session/transport credentials cannot escape.
        if request.kind == "client" then
            local arguments = {}
            if request.method == "bookstoreCategoryPage" then
                local query, page = Categories.arguments(request.arguments)
                arguments = { query, page }
            end
            request = { kind = "client", method = request.method, arguments = arguments, public_bookstore = true }
        else
            request = { kind = "download_cover", comic_id = request.comic_id, url = request.url,
                temporary_path = request.temporary_path, max_bytes = 4 * 1024 * 1024,
                minimum_free_bytes = self.settings:get("minimum_free_bytes"), public_bookstore = true,
                feed_identity = request.feed_identity and { account_key = request.feed_identity.account_key,
                    query_key = request.feed_identity.query_key, revision = request.feed_identity.revision } or nil }
        end
    end
    local mutation = request.kind == "purchase_submit" or request.kind == "set_favorite" or request.kind == "recharge"
    local uses_current_session = not diagnostics and not public_bookstore and request.session == nil
    local authentication_generation = account.authentication_generation
    if uses_current_session and (account.authentication_invalidated or (account.session and not account.session_valid)) then
        self:_later(callback, nil, errorValue("authentication", "Import a verified session before using this account online.",
            { transmitted = false, definitive = true }))
        return
    end
    if diagnostics or public_bookstore then request.session = nil
    else request.session = request.session or (account.session and account.session:serialize()) end
    options = options or {}
    options.timeout = options.timeout or self.settings:get("worker_timeout", 90)
    if public_bookstore then
        local before_start = options.before_start
        options.before_start = function()
            if self.closed or self.account ~= account or self.generation ~= generation then
                return nil, errorValue("canceled", "The public bookstore request is no longer current.", { transmitted = false })
            end
            if self.suspended or not self:_connected() then
                return nil, errorValue("network", "Connect before refreshing the public bookstore.", { transmitted = false })
            end
            if not self:_bookstoreRequestAllowed(request) then
                return nil, errorValue("canceled", "The public bookstore item is no longer current.", { transmitted = false })
            end
            if before_start then return before_start() end
            return true
        end
    end
    local task_id, completed
    local function cleanupCover()
        if request.kind == "download_cover" and request.temporary_path
            and Files.within(request.temporary_path, account.root .. "/covers") then
            pcall(os.remove, request.temporary_path)
        end
    end
    local execution_runner = diagnostics and self:_diagnosticsRunner() or public_bookstore and account.raw_runner or self.runner
    task_id = execution_runner:submit(request, options, function(value, err)
        completed = true
        if task_id then account.read_requests[task_id] = nil end
        -- Preserve a received recharge receipt in its original account before retiring UI callbacks.
        if request.kind == "recharge" and options.on_observed then
            local ok = pcall(options.on_observed, value, err)
            if not ok then require("logger").warn("BiliComics recharge receipt persistence failed") end
        end
        if self.closed or self.account ~= account or self.generation ~= generation then
            cleanupCover()
            return
        end
        if uses_current_session and not mutation and authentication_generation ~= account.authentication_generation then
            value, err = nil, errorValue("authentication", "The account session is no longer valid.")
        end
        if request.kind == "download_cover" and not value then cleanupCover() end
        if uses_current_session and err and err.kind == "authentication" then self:_invalidateAuthentication(account, err) end
        local ok, failure = pcall(callback, value, err)
        if not ok then
            require("logger").warn("BiliComics operation completion failed", type(failure))
            self:_notify()
        end
    end)
    if task_id and not completed and uses_current_session and not mutation then
        account.read_requests[task_id] = true
    end
    return task_id
end

function Controller:_client(method, arguments, callback, options)
    return self:_submit({ kind = "client", method = method, arguments = arguments or {} }, options, callback)
end

function Controller:_authenticated(callback)
    if self.account and self.account.session and self.account.session_valid then return true end
    self:_later(callback, nil, errorValue("authentication", "Import a valid web session before using this operation."))
    return false
end

function Controller:_protect(callback, operation)
    local ok, value, err = pcall(operation)
    if not ok then
        local failure = type(value) == "table" and value.kind and value or errorValue("storage", "The local operation could not be completed safely.")
        Util.callback(callback, nil, failure)
    else Util.callback(callback, value, err) end
end

function Controller:_guardAsync(callback, operation)
    local ok, failure = pcall(operation)
    if not ok then
        Util.callback(callback, nil, type(failure) == "table" and failure.kind and failure
            or errorValue("storage", "The operation could not be completed safely."))
    end
end

function Controller:getAccount()
    local account = self.account
    if not account then return { session_valid = false } end
    local identity = account.session and account.session.identity or self.settings:get("account_summary:" .. account.key, {})
    local session = account.session
    return { id = identity.id, name = identity.name, account_key = account.key, recharge_supported = true,
        session_valid = account.session_valid, pending_purchases = self:getPendingPurchases(),
        renewable = session ~= nil and session.refresh_token ~= nil and not session.refresh_blocked and not session.confirmation_blocked,
        last_refreshed_at = session and session.last_refreshed_at,
        auth_state = session and (session.refresh_blocked or session.confirmation_blocked) and "reauth_required"
            or account.session_manager and account.session_manager.state }
end
function Controller:getComic(comic_id) return comic_id and self.account.catalog:getComic(tostring(comic_id)) end
function Controller:getEpisodes(comic_id) return comic_id and self.account.catalog:getEpisodes(tostring(comic_id)) or {} end
function Controller:getEpisode(episode_id) return episode_id and self.account.store:getEpisode(tostring(episode_id)) end
function Controller:getLibrary(kind, query) return self.account.catalog:getLibrary(kind or "history", query) end

function Controller:_bookshelfSyncSnapshot()
    if self.closed or not self.account then return nil end
    local ok, value = pcall(self.account.store.getSetting, self.account.store, Bookshelf.sync_key)
    return ok and Bookshelf.syncCache(value, self.account.key) or nil
end

function Controller:getBookshelfItems()
    if self.closed or not self.account then return {} end
    return Bookshelf.order(self.account.catalog:getLibrary("favorites"), self:_bookshelfSyncSnapshot())
end

function Controller:getBookshelfSyncState()
    if self.closed or not self.account then return { has_cache = false, stale = true, syncing = false, can_sync = false } end
    local account, snapshot, now = self.account, self:_bookshelfSyncSnapshot(), self.clock()
    local authenticated = account.session ~= nil and account.session_valid == true and not account.authentication_invalidated
    local offline = not self:_connected()
    local reading_away = self.active_integration ~= nil and (not self.screens or self.screens.route ~= "favorites")
    local cached = snapshot ~= nil or #account.store:listComics("favorites") > 0
    local stale = snapshot == nil or now < snapshot.last_synced_at or now - snapshot.last_synced_at >= Bookshelf.ttl
        or account.bookshelf_sync_error ~= nil
    return { has_cache = cached, syncing = account.bookshelf_sync ~= nil, last_synced_at = snapshot and snapshot.last_synced_at,
        error = account.bookshelf_sync_error, stale = stale, offline = offline, authenticated = authenticated,
        can_sync = authenticated and not offline and not self.suspended and not reading_away,
        retry_at = account.bookshelf_sync_retry_at }
end

function Controller:getBookshelfViewState()
    local account = self.account
    if self.closed or not account then return Bookshelf.view(nil, "anonymous") end
    local ok, value = pcall(account.store.getSetting, account.store, Bookshelf.view_key)
    return Bookshelf.view(ok and value or nil, account.key)
end

function Controller:saveBookshelfViewState(changes, expected_account)
    if self.closed or not self.account or expected_account and expected_account ~= self.account.key then
        return nil, errorValue("account_mismatch", "The bookshelf view belongs to another account.")
    end
    local value, err = Bookshelf.updateView(self:getBookshelfViewState(), changes, self.account.key)
    if not value then return nil, err end
    local ok = pcall(self.account.store.putSetting, self.account.store, Bookshelf.view_key, value)
    if not ok then return nil, errorValue("storage", "The bookshelf view could not be saved.") end
    return value
end

function Controller:ensureBookshelfSync(callback)
    local state = self:getBookshelfSyncState()
    if state.syncing then return self:syncBookshelf(callback) end
    if not state.stale or not state.can_sync or state.retry_at and self.clock() < state.retry_at then
        self:_later(callback, self:getBookshelfItems())
        return
    end
    return self:syncBookshelf(callback)
end

function Controller:syncBookshelf(callback)
    if self.closed or not self.account then self:_later(callback, nil, errorValue("closed", "The plugin is closed.")); return end
    if not self:_authenticated(callback) then return end
    local account, generation = self.account, self.generation
    if account.bookshelf_sync then
        if callback then table.insert(account.bookshelf_sync.waiters, callback) end
        return account.bookshelf_sync.task_ids[1]
    end
    local reading_away = self.active_integration ~= nil and (not self.screens or self.screens.route ~= "favorites")
    if self.suspended or not self:_connected() or reading_away then
        self:_later(callback, nil, errorValue("network", "Open the bookshelf while connected to synchronize it.", { transmitted = false }))
        return
    end
    local pending = { waiters = callback and { callback } or {}, task_ids = {}, lists = {}, remaining = 2,
        favorite_revision = account.favorite_revision }
    account.bookshelf_sync, account.bookshelf_sync_error = pending, nil
    local function current()
        return not self.closed and self.account == account and self.generation == generation and account.bookshelf_sync == pending
    end
    local function finish(value, err)
        if not current() then return end
        account.bookshelf_sync, account.bookshelf_sync_error = nil, err
        account.bookshelf_sync_retry_at = err and self.clock() + Bookshelf.retry_delay or nil
        for _, waiter in ipairs(pending.waiters) do
            if self.closed or self.account ~= account or self.generation ~= generation then break end
            Util.callback(waiter, value, err)
        end
        self:_notify()
    end
    local function received(kind, comics, err)
        if not current() then return end
        if not comics then
            pending.error = pending.error or err or errorValue("protocol", "The bookshelf response is unavailable.")
        else pending.lists[kind] = comics end
        pending.remaining = pending.remaining - 1
        if pending.remaining > 0 then return end
        if pending.error then finish(nil, pending.error); return end
        local saved = pcall(function()
            account.store:transaction(function()
                local preserve = {}
                for comic_id, revision in pairs(account.favorite_versions) do
                    if revision > pending.favorite_revision or account.favorite_operations[comic_id] then
                        local comic = account.store:getComic(comic_id)
                        if comic then preserve[comic_id] = comic.favorite == true end
                    end
                end
                account.catalog:ingestLibrary("favorites", pending.lists.favorites)
                account.catalog:ingestLibrary("history", pending.lists.history)
                for comic_id, favorite in pairs(preserve) do account.store:upsertComic{ id = comic_id, favorite = favorite } end
                account.store:putSetting(Bookshelf.sync_key,
                    Bookshelf.syncSnapshot(pending.lists.favorites, account.key, self.clock()))
            end)
        end)
        if not saved then finish(nil, errorValue("storage", "The bookshelf could not be saved.")); return end
        finish(self:getBookshelfItems())
    end
    for _, kind in ipairs{ "favorites", "history" } do
        if not current() then break end
        local completed = false
        local function done(value, err)
            if completed then return end
            completed = true
            received(kind, value, err)
        end
        local ok, task = pcall(self._submit, self, { kind = "library", library = kind }, { priority = 10 }, done)
        if not ok then done(nil, errorValue("storage", "The bookshelf request could not start."))
        elseif task then pending.task_ids[#pending.task_ids + 1] = task end
    end
    self:_notify()
    return pending.task_ids[1]
end
function Controller:getPendingPurchases()
    if not self.account then return {} end
    local pending = self.account.purchases:listPending() or {}
    for index, intent in ipairs(pending) do
        local observed = self.account.pending_submission_results[intent.id]
        if observed and observed.visible then pending[index] = Util.copy(observed.visible) end
    end
    return pending
end

function Controller:authorizeDescriptor(descriptor, expected_account)
    local account = self.account
    if self.closed or not account or (expected_account and expected_account ~= account)
        or type(descriptor) ~= "table" or descriptor.account_key ~= account.key then
        return nil, errorValue("account_mismatch", "This chapter belongs to an inactive account.")
    end
    if not account.validated_descriptors[descriptor] then
        local saved = account.store:getDescriptor(descriptor.episode_id, descriptor.revision)
        if not saved or Codec.canonical(saved) ~= Codec.canonical(descriptor) then
            return nil, errorValue("invalid_descriptor", "The chapter document does not match its saved content revision.")
        end
        account.validated_descriptors[descriptor] = true
    end
    local episode = account.store:getEpisode(descriptor.episode_id)
    if not episode or tostring(episode.comic_id) ~= tostring(descriptor.comic_id) then
        return nil, errorValue("access_unknown", "Refresh the chapter catalog before opening this document.")
    end
    if DownloadService.isReadable(episode, true) then return true end
    local grant = account.online_read_grants[tostring(descriptor.episode_id)]
    if DownloadService.isReadable(episode, false) and account.session and account.session_valid
        and grant and grant > os.time() then return true end
    return nil, errorValue("locked", "This chapter needs a current online reading entitlement.")
end

function Controller:_cacheCover(comic, public_bookstore, feed_identity)
    if not comic or not comic.id or not comic.cover_url or not self:_connected() then return end
    if public_bookstore and feed_identity == nil then feed_identity = self:_bookstoreIdentity() end
    local request_key = public_bookstore and "bookstore:" .. Util.hash(feed_identity or {}) .. ":" .. comic.id or comic.id
    if self.covers[request_key] then return end
    if public_bookstore then
        if not self:_bookstoreMember(comic.id, feed_identity) then return end
    elseif self.account.authentication_invalidated or (self.account.session and not self.account.session_valid) then return end
    local source = CoverSource.resolve(comic.cover_url)
    if not source then return end
    if public_bookstore and not self:_bookstoreCoverAllowed(comic.id, source.url, feed_identity) then return end
    local cache_identity = tostring(comic.id) .. ":" .. source.identity
    local failure_identity = public_bookstore and "bookstore:" .. cache_identity or cache_identity
    if (self.cover_failures[failure_identity] or 0) > self.clock() then return end
    if comic.cover_path and Files.exists(comic.cover_path)
        and (comic.extra or {}).cached_cover_identity == source.identity then return end
    local account, original_url = self.account, comic.cover_url
    local root = account.root .. "/covers"
    Files.mkdir(root)
    local temporary = root .. "/" .. Util.id("cover") .. ".part"
    self.covers[request_key] = cache_identity
    self:_submit({ kind = "download_cover", url = source.url, temporary_path = temporary, max_bytes = 4 * 1024 * 1024,
        minimum_free_bytes = self.settings:get("minimum_free_bytes"),
        public_bookstore = public_bookstore == true, comic_id = public_bookstore and comic.id or nil,
        feed_identity = public_bookstore and feed_identity or nil },
        { priority = 60, resource = "image" }, function(result)
            self.covers[request_key] = nil
            if public_bookstore and not self:_bookstoreMember(comic.id, feed_identity) then os.remove(temporary); return end
            local current = account.store:getComic(comic.id)
            if not current or current.cover_url ~= original_url then
                os.remove(temporary)
                if current then self:_cacheCover(current, public_bookstore, feed_identity) end
                return
            end
            if public_bookstore and not self:_bookstoreCoverAllowed(comic.id, source.url, feed_identity) then
                os.remove(temporary); return
            end
            local format = result and result.format
            if not result or result.temporary_path ~= temporary
                or (format ~= "jpeg" and format ~= "jpg" and format ~= "png" and format ~= "webp") then
                os.remove(temporary)
                self.cover_failures[failure_identity] = self.clock() + 300
                return
            end
            self.cover_failures[failure_identity] = nil
            local path = root .. "/" .. Util.hash(cache_identity) .. "." .. format
            Files.assertRegular(temporary, root)
            Files.assertContained(path, root)
            Files.syncFile(temporary)
            assert(os.rename(temporary, path))
            Files.syncDirectory(root)
            current.cover_path = path
            current.extra = current.extra or {}
            current.extra.cached_cover_url = source.url
            current.extra.cached_cover_identity = source.identity
            account.store:upsertComic(current)
            self:_notify()
        end)
end

function Controller:requestCover(comic_id)
    if self.closed or not self.account then return end
    self:_cacheCover(self.account.store:getComic(tostring(comic_id)))
end

function Controller:_bookstoreSnapshot()
    if self.closed or not self.account then return nil end
    local ok, value = pcall(self.account.store.getSetting, self.account.store, Bookstore.key)
    return ok and Bookstore.cache(value, self.account.key) or nil
end

function Controller:_bookstoreMetadata()
    if self.closed or not self.account then return nil end
    local ok, value = pcall(self.account.store.getSetting, self.account.store, Categories.metadata_key)
    return ok and Categories.metadataCache(value, self.account.key) or nil
end

function Controller:_bookstoreCategorySnapshot(query)
    if self.closed or not self.account then return nil end
    local ok, value = pcall(self.account.store.getSetting, self.account.store, Categories.cacheKey(query))
    return ok and Categories.cache(value, self.account.key, query) or nil
end

function Controller:_bookstoreIdentity(query, snapshot)
    if not snapshot then
        if query then snapshot = self:_bookstoreCategorySnapshot(query)
        else snapshot = self:_bookstoreSnapshot() end
    end
    if not snapshot or not self.account then return nil end
    return { account_key = self.account.key, query_key = query and Categories.queryKey(query) or "homepage",
        revision = snapshot.revision or "legacy:" .. Util.hash(snapshot) }
end

function Controller:_bookstoreScopedSnapshot(identity)
    if identity == nil then return self:_bookstoreSnapshot() end
    if self.closed or not self.account or type(identity) ~= "table" or identity.account_key ~= self.account.key
        or type(identity.query_key) ~= "string" or type(identity.revision) ~= "string" then return nil end
    local query
    if identity.query_key ~= "homepage" then
        query = Categories.queryFromKey(identity.query_key)
        if not query then return nil end
    end
    local snapshot
    if query then snapshot = self:_bookstoreCategorySnapshot(query)
    else snapshot = self:_bookstoreSnapshot() end
    local current = snapshot and self:_bookstoreIdentity(query, snapshot)
    if current and current.revision == identity.revision then return snapshot, query end
end

function Controller:_bookstoreMember(comic_id, identity)
    local snapshot, query = self:_bookstoreScopedSnapshot(identity)
    if not snapshot then return false end
    if query then
        for _, entry in ipairs(Categories.entries(snapshot)) do
            if entry.id == tostring(comic_id) then return true, entry end
        end
    else
        for _, id in ipairs(snapshot.ids) do if id == tostring(comic_id) then return true end end
    end
    return false
end

function Controller:_bookstoreCoverAllowed(comic_id, url, identity)
    local member, entry = self:_bookstoreMember(comic_id, identity)
    if not member then return false end
    local comic = self.account.store:getComic(tostring(comic_id))
    local current = comic and CoverSource.resolve(comic.cover_url)
    if not current or current.url ~= url then return false end
    local expected = entry and CoverSource.resolve(entry.cover_url)
    return not entry or (expected ~= nil and expected.url == url)
end

function Controller:_bookstoreRequestAllowed(request)
    if request.kind == "client" then
        if request.method == "recommendations" or request.method == "bookstoreCategories" then
            return type(request.arguments) == "table" and next(request.arguments) == nil
        elseif request.method == "bookstoreCategoryPage" then
            local query = Categories.arguments(request.arguments)
            return query ~= nil and Categories.available(self:_bookstoreMetadata(), query)
        end
        return false
    end
    if request.kind ~= "download_cover"
        or type(request.temporary_path) ~= "string"
        or not Files.within(request.temporary_path, self.account.root .. "/covers") then return false end
    return self:_bookstoreCoverAllowed(request.comic_id, request.url, request.feed_identity)
end

function Controller:getBookstore(query)
    if query ~= nil then return self:_getBookstoreCategory(query) end
    local result = { items = {}, source = Bookstore.source, personalized = false, has_more = false, stale = true,
        can_load_more = false, limit_reached = false, loaded_pages = 0 }
    local snapshot = self:_bookstoreSnapshot()
    if not snapshot then return result end
    local now = self.clock()
    result.identity, result.loaded_pages = self:_bookstoreIdentity(nil, snapshot), 1
    result.updated_at = snapshot.fetched_at
    result.stale = snapshot.schema_version ~= Bookstore.schema_version or self.account.bookstore_failed == true
        or now < snapshot.fetched_at or now - snapshot.fetched_at >= Bookstore.ttl
    for _, id in ipairs(snapshot.ids) do
        local ok, comic = pcall(self.account.catalog.getComic, self.account.catalog, id)
        if ok and comic and type(comic.title) == "string" and comic.title:find("%S") then
            local extra = type(comic.extra) == "table" and comic.extra or {}
            local editorial = Bookstore.editorial(extra)
            extra.recommendation, extra.evaluate, extra.tags = editorial.recommendation, editorial.evaluate, editorial.tags
            extra.recommendation_section = editorial.recommendation_section
            comic.extra = extra
            result.items[#result.items + 1] = comic
            if not CoverSource.resolve(comic.cover_url) then result.stale = true end
        else result.stale = true end
    end
    return result
end

function Controller:refreshBookstore(query, callback)
    if type(query) == "function" then callback, query = query, nil end
    if query ~= nil then return self:_requestBookstoreCategory(query, false, callback) end
    if self.closed or not self.account then self:_later(callback, nil, errorValue("closed", "The plugin is closed.")); return end
    local account, generation = self.account, self.generation
    if account.bookstore_refresh then
        if callback then account.bookstore_refresh.waiters[#account.bookstore_refresh.waiters + 1] = callback end
        return account.bookstore_refresh.task_id
    end
    if self.suspended or not self:_connected() then
        account.bookstore_failed = true
        self:_later(callback, nil, errorValue("network", "Connect before refreshing the public bookstore.", { transmitted = false }))
        return
    end
    local pending = { waiters = callback and { callback } or {} }
    account.bookstore_refresh = pending
    local function finish(value, err)
        if self.account ~= account or self.generation ~= generation or account.bookstore_refresh ~= pending then return end
        account.bookstore_refresh, account.bookstore_failed = nil, not value
        for _, waiter in ipairs(pending.waiters) do
            if self.account ~= account or self.generation ~= generation then break end
            Util.callback(waiter, value, err)
        end
        self:_notify()
    end
    local ok, task = pcall(self._submit, self,
        { kind = "client", method = "recommendations", arguments = {}, public_bookstore = true },
        { priority = 10 }, function(feed, err)
            if not feed then finish(nil, err or errorValue("protocol", "The public recommendation feed is unavailable.")); return end
            local items, failure = Bookstore.normalize(feed)
            if not items then finish(nil, failure); return end
            local saved = pcall(function()
                account.store:transaction(function()
                    -- Editorial arrays and absent descriptions replace the previous response as one snapshot.
                    -- Clear them before Catalog's recursive merge, retaining its normal public-data sanitizer.
                    for _, item in ipairs(items) do
                        local current = account.store:getComic(item.id)
                        if current then
                            local extra = type(current.extra) == "table" and current.extra or {}
                            extra.recommendation, extra.evaluate, extra.tags = nil, nil, nil
                            extra.recommendation_section = nil
                            account.store:upsertComic{ id = item.id, extra = extra }
                        end
                    end
                    account.catalog:ingestSearch(items)
                    account.store:putSetting(Bookstore.key, Bookstore.snapshot(items, account.key, self.clock()))
                end)
            end)
            if not saved then finish(nil, errorValue("storage", "The public recommendation feed could not be cached.")); return end
            account.bookstore_failed = false
            finish(self:getBookstore())
        end)
    if not ok then finish(nil, errorValue("storage", "The public recommendation request could not start.")); return nil
    else pending.task_id = task end
    return task
end

function Controller:getBookstoreCategories()
    local metadata = self:_bookstoreMetadata()
    if not metadata then return { source = Categories.metadata_source, items = {}, orders = {}, stale = true } end
    local now = self.clock()
    metadata.stale = self.account.bookstore_categories_failed == true or now < metadata.updated_at
        or now - metadata.updated_at >= Categories.metadata_ttl
    return metadata
end

function Controller:refreshBookstoreCategories(callback)
    if self.closed or not self.account then self:_later(callback, nil, errorValue("closed", "The plugin is closed.")); return end
    local account, generation = self.account, self.generation
    if account.bookstore_categories_refresh then
        if callback then table.insert(account.bookstore_categories_refresh.waiters, callback) end
        return account.bookstore_categories_refresh.task_id
    end
    if self.suspended or not self:_connected() then
        account.bookstore_categories_failed = true
        self:_later(callback, nil, errorValue("network", "Connect before refreshing comic categories.", { transmitted = false })); return
    end
    local pending = { waiters = callback and { callback } or {} }
    account.bookstore_categories_refresh = pending
    local function finish(value, err)
        if self.account ~= account or self.generation ~= generation or account.bookstore_categories_refresh ~= pending then return end
        account.bookstore_categories_refresh, account.bookstore_categories_failed = nil, not value
        for _, waiter in ipairs(pending.waiters) do
            if self.account ~= account or self.generation ~= generation then break end
            Util.callback(waiter, value, err)
        end
        self:_notify()
    end
    local ok, task = pcall(self._submit, self,
        { kind = "client", method = "bookstoreCategories", arguments = {}, public_bookstore = true },
        { priority = 10 }, function(value, err)
            if not value then finish(nil, err or errorValue("protocol", "The official categories are unavailable.")); return end
            local metadata, failure = Categories.metadata(value)
            if not metadata then finish(nil, failure); return end
            local saved = pcall(account.store.putSetting, account.store, Categories.metadata_key,
                Categories.metadataSnapshot(metadata, account.key, self.clock()))
            if not saved then finish(nil, errorValue("storage", "The official categories could not be cached.")); return end
            account.bookstore_categories_failed = false
            finish(self:getBookstoreCategories())
        end)
    if not ok then finish(nil, errorValue("storage", "The category request could not start.")); return nil end
    pending.task_id = task
    return task
end

function Controller:_getBookstoreCategory(value)
    local result = { source = Categories.source, items = {}, personalized = false, stale = true,
        loaded_pages = 0, has_more = false, can_load_more = false, limit_reached = false }
    local query = Categories.query(value)
    if not query then return result end
    result.query, result.query_key = query, Categories.queryKey(query)
    local snapshot = self:_bookstoreCategorySnapshot(query)
    if not snapshot then return result end
    local state, now = self.account.bookstore_category_state, self.clock()
    result.stale = state ~= nil and state.failures[result.query_key] == true
    result.identity = self:_bookstoreIdentity(query, snapshot)
    result.updated_at, result.loaded_pages = snapshot.pages[1].updated_at, #snapshot.pages
    result.has_more = snapshot.pages[#snapshot.pages].has_more
    result.limit_reached = result.has_more and result.loaded_pages >= Categories.max_pages
    result.can_load_more = result.has_more and not result.limit_reached
    if result.has_more then result.next_page = result.loaded_pages + 1 end
    for _, page in ipairs(snapshot.pages) do
        if now < page.updated_at or now - page.updated_at >= Categories.ttl then result.stale = true end
    end
    for _, entry in ipairs(Categories.entries(snapshot)) do
        local ok, comic = pcall(self.account.catalog.getComic, self.account.catalog, entry.id)
        if ok and comic then
            local expected = not entry.cover_url:find("?", 1, true) and CoverSource.resolve(entry.cover_url)
            local extra = type(comic.extra) == "table" and comic.extra or {}
            local editorial = Bookstore.editorial(entry.editorial)
            -- The feed owns editorial presentation; shared catalog state owns favorites and native progress.
            extra.recommendation, extra.evaluate, extra.tags = editorial.recommendation, editorial.evaluate, editorial.tags
            extra.recommendation_section, extra.category_id = nil, query.category_id
            if not expected or comic.cover_url ~= entry.cover_url then result.stale = true end
            if not expected or extra.cached_cover_identity ~= expected.identity then
                comic.cover_path, extra.cover_path = nil, nil
            end
            comic.title, comic.cover_url, comic.extra = entry.title, entry.cover_url, extra
            result.items[#result.items + 1] = comic
        else result.stale = true end
    end
    return result
end

function Controller:_requestBookstoreCategory(value, append, callback)
    if self.closed or not self.account then self:_later(callback, nil, errorValue("closed", "The plugin is closed.")); return end
    local query, invalid = Categories.query(value)
    if not query then self:_later(callback, nil, invalid); return end
    local account, generation, key = self.account, self.generation, Categories.queryKey(query)
    account.bookstore_category_state = account.bookstore_category_state or { generations = {}, failures = {}, tasks = {}, refreshes = {} }
    local state = account.bookstore_category_state
    if not Categories.available(self:_bookstoreMetadata(), query) then
        state.failures[key] = true
        self:_later(callback, nil, errorValue("invalid_category", "Refresh the official categories and select an available category.")); return
    end
    if not append and state.refreshes[key] then
        if callback then table.insert(state.refreshes[key].waiters, callback) end
        return state.refreshes[key].task_id
    end
    if append and state.refreshes[key] then
        self:_later(callback, nil, errorValue("busy", "The first category page is refreshing.")); return
    end
    if self.suspended or not self:_connected() then
        state.failures[key] = true
        self:_later(callback, nil, errorValue("network", "Connect before loading this comic category.", { transmitted = false })); return
    end
    local base, page = self:_bookstoreCategorySnapshot(query), 1
    if append then
        if not base or not base.pages[#base.pages].has_more or #base.pages >= Categories.max_pages then
            self:_later(callback, nil, errorValue("no_more_pages", "No further category page can be loaded.")); return
        end
        page = #base.pages + 1
    else
        state.generations[key] = (state.generations[key] or 0) + 1
    end
    local operation_generation = state.generations[key] or 0
    local task_key = key .. ":page:" .. page .. ":generation:" .. operation_generation
    if state.tasks[task_key] then
        if callback then table.insert(state.tasks[task_key].waiters, callback) end
        return state.tasks[task_key].task_id
    end
    local pending = { waiters = callback and { callback } or {}, generation = operation_generation }
    state.tasks[task_key] = pending
    if not append then state.refreshes[key] = pending end
    local function current()
        if self.closed or self.account ~= account or self.generation ~= generation
            or (state.generations[key] or 0) ~= operation_generation then return false end
        if append then
            local snapshot = self:_bookstoreCategorySnapshot(query)
            return snapshot ~= nil and snapshot.revision == base.revision
        end
        return true
    end
    local function finish(result, err)
        if self.account ~= account or self.generation ~= generation or state.tasks[task_key] ~= pending then return end
        state.tasks[task_key] = nil
        if state.refreshes[key] == pending then state.refreshes[key] = nil end
        if (state.generations[key] or 0) == operation_generation then state.failures[key] = not result end
        for _, waiter in ipairs(pending.waiters) do
            if self.account ~= account or self.generation ~= generation then break end
            Util.callback(waiter, result, err)
        end
        self:_notify()
    end
    local stale_error = function() return errorValue("canceled", "This category page belongs to an older feed refresh.", { transmitted = false }) end
    local ok, task = pcall(self._submit, self,
        { kind = "client", method = "bookstoreCategoryPage", arguments = { query, page }, public_bookstore = true },
        { priority = 10, before_start = function()
            if not current() then return nil, stale_error() end
            return true
        end }, function(response, err)
            if not current() then finish(nil, stale_error()); return end
            if not response then finish(nil, err or errorValue("protocol", "The official category page is unavailable.")); return end
            local saved_page, neutral = Categories.page(response, query, page, self.clock())
            if not saved_page then finish(nil, neutral); return end
            local pages = append and Util.copy(base.pages) or {}
            pages[#pages + 1] = saved_page
            local snapshot = Categories.snapshot(query, account.key, pages, self.clock())
            local saved = pcall(function()
                account.store:transaction(function()
                    account.catalog:ingestSearch(neutral)
                    account.store:putSetting(Categories.cacheKey(query), snapshot)
                end)
            end)
            if not saved then finish(nil, errorValue("storage", "The category page could not be cached.")); return end
            state.failures[key] = false
            finish(self:getBookstore(query))
        end)
    if not ok then finish(nil, errorValue("storage", "The category page request could not start.")); return nil end
    pending.task_id = task
    return task
end

function Controller:loadMoreBookstore(query, callback)
    return self:_requestBookstoreCategory(query, true, callback)
end

function Controller:requestBookstoreCover(comic_id, identity)
    if self.closed or not self.account or not self:_bookstoreMember(comic_id, identity) then return end
    self:_cacheCover(self.account.store:getComic(tostring(comic_id)), true, identity)
end

function Controller:refreshLibrary(kind, callback)
    if not self:_authenticated(callback) then return end
    kind = (kind == "favorites" or kind == "following") and "favorites" or "history"
    local account, favorite_revision = self.account, self.account.favorite_revision
    self:_submit({ kind = "library", library = kind }, { priority = 10 }, function(comics, err)
        if not comics then Util.callback(callback, nil, err); return end
        self:_protect(callback, function()
            local preserve = {}
            if kind == "favorites" then
                for comic_id, revision in pairs(account.favorite_versions) do
                    if revision > favorite_revision or account.favorite_operations[comic_id] then
                        local existing = account.store:getComic(comic_id)
                        if existing then preserve[comic_id] = existing.favorite == true end
                    end
                end
            end
            account.store:transaction(function()
                account.catalog:ingestLibrary(kind, comics)
                for comic_id, favorite in pairs(preserve) do account.store:upsertComic{ id = comic_id, favorite = favorite } end
            end)
            local result = account.catalog:getLibrary(kind)
            self:_notify(); return result
        end)
    end)
end

function Controller:lookupComicID(input, callback)
    local comic_id = ComicID.parse(input)
    if not comic_id then
        self:_later(callback, nil, errorValue("invalid_comic_id", "Enter a positive comic ID with at most 15 digits, optionally prefixed by mc."))
        return
    end
    self:refreshComic(comic_id, function(detail, err)
        if detail and tostring(detail.comic.id) ~= comic_id then
            Util.callback(callback, nil, errorValue("protocol", "The returned comic does not match the requested ID.")); return
        end
        Util.callback(callback, detail, err)
    end)
end

function Controller:resolveReadingEpisode(comic_id, callback)
    comic_id = ComicID.parse(tostring(comic_id or ""))
    if not comic_id then self:_later(callback, nil, errorValue("invalid_comic_id", "Select a valid comic.")); return end
    local function selectEpisode()
        local comic = self.account.catalog:getComic(comic_id)
        local episodes = self.account.catalog:getEpisodes(comic_id)
        if not comic or #episodes == 0 then return nil, errorValue("not_found", "This comic has no available chapter catalog.") end
        local current = tostring(comic.current_episode_id or comic.last_episode_id or "")
        for index, episode in ipairs(episodes) do
            if tostring(episode.id) == current then
                if episode.read == true or episode.read == "complete" or episode.read == "finished" or episode.read == "read" then
                    if not episodes[index + 1] then return nil, errorValue("no_next_chapter", "No later chapter is present in the current catalog.") end
                    episode = episodes[index + 1]
                end
                return { comic = comic, episode = episode }
            end
        end
        return { comic = comic, episode = episodes[1] }
    end
    if #self.account.store:listEpisodes(comic_id) == 0 then
        self:refreshComic(comic_id, function(detail, err)
            if not detail then Util.callback(callback, nil, err); return end
            self:_protect(callback, selectEpisode)
        end)
    else
        self:_protect(function(value, err) self:_later(callback, value, err) end, selectEpisode)
    end
end

function Controller:isFavoritePending(comic_id)
    return self.account and self.account.favorite_operations[tostring(comic_id)] ~= nil or false
end

function Controller:setFavorite(comic_id, favorite, callback)
    comic_id = ComicID.parse(tostring(comic_id or ""))
    if not comic_id or type(favorite) ~= "boolean" then
        self:_later(callback, nil, errorValue("invalid_request", "Select a comic and an explicit following state.")); return
    end
    if not self:_authenticated(callback) then return end
    local account = self.account
    if not account.store:getComic(comic_id) then
        self:_later(callback, nil, errorValue("not_found", "Open the comic details before changing its following state.")); return
    end
    if account.favorite_operations[comic_id] then
        self:_later(callback, nil, errorValue("busy", "This comic's following state is already being updated.")); return
    end
    account.favorite_revision = account.favorite_revision + 1
    account.favorite_versions[comic_id] = account.favorite_revision
    local operation = { favorite = favorite }
    account.favorite_operations[comic_id] = operation
    self:_notify()
    self:_submit({ kind = "set_favorite", comic_id = comic_id, favorite = favorite },
        { priority = 5, cancelable = false }, function(response, err)
            if account.favorite_operations[comic_id] ~= operation then return end
            account.favorite_operations[comic_id] = nil
            if not response or response.accepted ~= true
                or (response.comic_id ~= nil and tostring(response.comic_id) ~= comic_id)
                or (response.favorite ~= nil and response.favorite ~= favorite) then
                Util.callback(callback, nil, err or errorValue("protocol", "The server did not confirm this following change."))
                self:_notify(); return
            end
            self:_protect(callback, function()
                account.favorite_revision = account.favorite_revision + 1
                account.favorite_versions[comic_id] = account.favorite_revision
                account.store:upsertComic{ id = comic_id, favorite = favorite }
                self:_notify(); return account.catalog:getComic(comic_id)
            end)
        end)
end

function Controller:search(query, callback)
    query = type(query) == "string" and query:match("^%s*(.-)%s*$") or ""
    if query == "" or #query > 512 then self:_later(callback, nil, errorValue("invalid_request", "Enter a bounded search query.")); return end
    self:_client("search", { query, { page_num = 1, page_size = 100 } }, function(comics, err)
        if not comics then Util.callback(callback, nil, err); return end
        self:_protect(callback, function()
            local result = self.account.catalog:ingestSearch(comics)
            self:_notify(); return result
        end)
    end, { priority = 10 })
end

function Controller:refreshComic(comic_id, callback)
    comic_id = id(comic_id)
    if not comic_id then self:_later(callback, nil, errorValue("invalid_request", "A comic is required.")); return end
    self:_client("comicDetail", { comic_id }, function(detail, err)
        if not detail then Util.callback(callback, nil, err); return end
        self:_protect(callback, function()
            local result = self.account.catalog:ingestDetail(detail)
            self:_cacheCover(result.comic); self:_notify(); return result
        end)
    end, { priority = 5 })
end

function Controller:getWallet()
    local wallet = self.account.store:getSetting("wallet", {})
    wallet.stale = not wallet.updated_at or os.time() - wallet.updated_at > 300 or not self.account.session_valid
    return wallet
end

function Controller:refreshWallet(callback)
    if not self:_authenticated(callback) then return end
    self:_client("wallet", {}, function(wallet, err)
        if not wallet then Util.callback(callback, nil, err); return end
        self:_protect(callback, function()
            wallet = Normalize.safeExtra(wallet); wallet.updated_at = os.time()
            self.account.store:putSetting("wallet", wallet)
            self:_notify(); return wallet
        end)
    end, { priority = 10 })
end

function Controller:_saveRenewedSession(account, fields)
    if self.closed or self.account ~= account or self.generation ~= account.generation then
        return nil, errorValue("canceled", "The account changed before its session could be saved.")
    end
    local session = Session.new(fields)
    if session.account_key ~= account.key or not session.identity or not session.validated_at
        or not session.cookies.SESSDATA or tostring(session.identity.id) ~= tostring(account.session.identity.id)
        or (session.cookies.DedeUserID and session.cookies.DedeUserID ~= tostring(session.identity.id)) then
        return nil, errorValue("account_mismatch", "The renewed session does not match the active account.")
    end
    session.credential_generation = (account.session.credential_generation or 0)
        + (account.session:sameCredentials(session) and 0 or 1)
    local saved, err = self.session_storage:save(session)
    if not saved then return nil, err end
    account.session = session
    self:_notify()
    return true
end

function Controller:_adoptValidatedSession(fields)
    local session = Session.new(assert(fields, "Validated session is missing"))
    local key = session.account_key
    assert(accountKey(key) == key and session.identity and session.validated_at, "Invalid validated account")
    local saved, save_error = self.session_storage:save(session)
    if not saved then return nil, save_error end
    local previous_key, previous_session = self.account.key, self.account.session
    self:_closeAccount()
    local opened = pcall(self._openAccount, self, key, session, true)
    if not opened then
        if self.account and self.account.store then pcall(self.account.store.close, self.account.store) end
        self.account = nil
        self:_openAccount(previous_key, previous_session)
        return nil, errorValue("storage", "The new account could not be opened. The previous account is still selected.")
    end
    self.settings:set("account_summary:" .. key, { id = session.identity.id, name = session.identity.name })
    self.settings:set("active_account_key", key)
    self.session_storage:removeLegacy(key)
    self:_notify()
    return self:getAccount()
end

function Controller:cancelQRLogin()
    local state = self.qr_login
    self.qr_login = nil
    if state and state.task_id then state.runner:cancel(state.task_id) end
end

function Controller:_qrRequest(state, method, arguments, callback)
    local completed = false
    local identifier = state.runner:submit({ kind = "auth", method = method, arguments = arguments }, {
        priority = 0, timeout = 60, retry_attempts = 1,
        before_start = function()
            if self.qr_login ~= state or self.closed or self.generation ~= state.generation then
                return false, errorValue("canceled", "This sign-in code is no longer active.", { transmitted = false })
            end
            if not self:_connected() then return false, errorValue("network", "Connect to sign in.", { transmitted = false }) end
            return true
        end,
    }, function(value, err)
        completed = true
        if self.qr_login ~= state or self.closed or self.generation ~= state.generation then return end
        state.task_id = nil
        callback(value, err)
    end)
    if not completed and self.qr_login == state then state.task_id = identifier end
end

function Controller:beginQRLogin(callback)
    self:cancelQRLogin()
    self.import_sequence = (self.import_sequence or 0) + 1
    if self.closed or not self.account then return end
    if not self:_connected() then self:_later(callback, nil, errorValue("network", "Connect to sign in.")); return end
    local state = { generation = self.generation, runner = self.account.raw_runner }
    self.qr_login = state
    self:_qrRequest(state, "generateQR", {}, function(value, err)
        if not value then self.qr_login = nil; Util.callback(callback, nil, err); return end
        state.key = value.key
        Util.callback(callback, { url = value.url, key = value.key, expires_at = value.expires_at })
    end)
end

function Controller:pollQRLogin(key, callback)
    local state = self.qr_login
    if not state or not state.key or state.key ~= key or state.task_id then
        self:_later(callback, nil, errorValue("canceled", "This sign-in code is no longer active.")); return
    end
    self:_qrRequest(state, "pollQR", { key }, function(value, err)
        if not value then Util.callback(callback, nil, err); return end
        if value.status == "confirmed" then
            self.qr_login = nil
            self:_protect(callback, function()
                local account, save_error = self:_adoptValidatedSession(value.session)
                if not account then return nil, save_error end
                return { status = "confirmed" }
            end)
        else
            if value.status == "expired" then self.qr_login = nil end
            Util.callback(callback, { status = value.status })
        end
    end)
end

function Controller:importSession(text, callback)
    self:cancelQRLogin()
    local parsed, err = Session.parse(text)
    if not parsed then self:_later(callback, nil, err); return end
    self.import_sequence = (self.import_sequence or 0) + 1
    local sequence = self.import_sequence
    self:_submit({ kind = "client", method = "validateSession", session = parsed:serialize() }, { priority = 0 }, function(result, failure)
        if sequence ~= self.import_sequence then return end
        if not result then Util.callback(callback, nil, failure); return end
        self:_protect(callback, function()
            return self:_adoptValidatedSession(result.session)
        end)
    end)
end

function Controller:prepareEpisode(comic_id, episode_id, callback)
    comic_id, episode_id = id(comic_id), id(episode_id)
    if not comic_id or not episode_id then self:_later(callback, nil, errorValue("invalid_request", "A comic and chapter are required.")); return end
    local account = self.account
    if account.downloads:isReplacingVersion(episode_id) then
        self:_later(callback, nil, errorValue("busy", "Finish or cancel the new-version preparation before opening this chapter.")); return
    end
    local episode = account.store:getEpisode(episode_id)
    if not episode or episode.comic_id ~= comic_id then
        self:refreshComic(comic_id, function(detail, err)
            if not detail then Util.callback(callback, nil, err); return end
            local refreshed = account.store:getEpisode(episode_id)
            if not refreshed or refreshed.comic_id ~= comic_id then
                Util.callback(callback, nil, errorValue("not_found", "The chapter is not in this comic.")); return
            end
            self:prepareEpisode(comic_id, episode_id, callback)
        end)
        return
    end
    if not DownloadService.isReadable(episode, false) then
        self:_later(callback, nil, errorValue("locked", "The chapter does not have confirmed reading access.")); return
    end
    local descriptor, path = account.catalog:getDescriptor(episode_id)
    if descriptor and path and Files.exists(path) then
        local usable, cached = true, false
        for number in ipairs(descriptor.pages) do
            local page = account.pages:getPage(episode_id, descriptor.revision, number)
            if page and page.state == "ready" then cached = true end
            if not page or (page.state ~= "ready" and not (page.extra or {}).source_path) then usable = false end
        end
        if usable or cached then
            self:_later(callback, { descriptor = descriptor, path = path }); return
        end
        self:_later(callback, nil, errorValue("source_unavailable", "Use download recovery to prepare this chapter's missing image sources.")); return
    end
    if not self:_authenticated(callback) then return end
    if self.preparing[episode_id] then table.insert(self.preparing[episode_id], callback); return end
    self.preparing[episode_id] = { callback }
    self:_client("imageIndex", { episode_id }, function(index, err)
        local waiting = self.preparing[episode_id] or {}
        self.preparing[episode_id] = nil
        local prepared
        if index then
            local ok, value = pcall(function()
                local record = { schema_version = 1, account_key = account.key, comic_id = comic_id,
                    episode_id = episode_id, revision = assert(index.revision), pages = {} }
                for number, image in ipairs(assert(index.images or index.pages)) do
                    assert(type(image.path) == "string" and not image.path:find("[?&]token="), "A durable source path is required")
                    record.pages[number] = { id = assert(image.id), index = number, width = image.width, height = image.height }
                end
                local descriptor_path = account.pages:ensureDescriptor(record)
                account.store:transaction(function()
                    for number, image in ipairs(index.images or index.pages) do
                        assert(type(image.path) == "string" and not image.path:find("[?&]token="), "A durable source path is required")
                        local page = account.store:getPage(episode_id .. "/" .. record.revision .. "/" .. number)
                        page.extra = page.extra or {}; page.extra.source_path = image.path
                        account.store:putPage(page)
                    end
                    local latest = account.store:getEpisode(episode_id)
                    latest.extra = latest.extra or {}; latest.extra.current_revision = record.revision
                    account.store:upsertEpisodes(comic_id, { latest })
                end)
                return { descriptor = record, path = descriptor_path }
            end)
            if ok then prepared = value else err = errorValue("storage", "The chapter index could not be stored safely.") end
        end
        for _index, done in ipairs(waiting) do Util.callback(done, prepared, err) end
        self:_notify()
    end, { priority = 0, before_start = function()
        if self.account == account and self.generation == account.generation
            and not self.closed and not self.suspended and self:_connected() then return true end
        return nil, errorValue("network", "Connect before acquiring the chapter index.", { transmitted = false })
    end })
end

-- Retire only the foreground reading intent. Shared preparation, downloads and purchases may finish normally.
function Controller:cancelPendingRead()
    self.read_generation = (self.read_generation or 0) + 1
    if self.opening and self.opening.read_generation ~= nil then self:_releaseOpening() end
end

function Controller:readEpisode(comic_id, episode_id, callback)
    if self.opening then self:_later(callback, nil, errorValue("busy", "Another chapter is opening.")); return end
    self:cancelPendingRead()
    if self.closed or not self.account then self:_later(callback, nil, errorValue("closed", "The plugin is closed.")); return end
    local account, generation = self.account, self.generation
    local read_generation = self.read_generation
    self:prepareEpisode(comic_id, episode_id, function(prepared, err)
        if not currentRead(self, account, generation, read_generation) then return end
        if not prepared then Util.callback(callback, nil, err); return end
        self:_guardAsync(callback, function()
            local episode = account.store:getEpisode(episode_id)
            local complete = account.pages:isComplete(prepared.descriptor.episode_id, prepared.descriptor.revision)
            if not DownloadService.isReadable(episode, true) then
                if not account.session or not account.session_valid then
                    Util.callback(callback, nil, errorValue("entitlement", "Offline rights for this chapter are not confirmed.")); return
                end
                -- A complete cache is not proof of offline permission. Reconfirm temporary online access.
                self:refreshComic(comic_id, function(detail, failure)
                    if not currentRead(self, account, generation, read_generation) then return end
                    if not detail then Util.callback(callback, nil, failure); return end
                    if not DownloadService.isReadable(account.store:getEpisode(episode_id), false) then
                        Util.callback(callback, nil, errorValue("locked", "The temporary reading permission is no longer available.")); return
                    end
                    local current = account.store:getEpisode(episode_id)
                    account.online_read_grants[tostring(episode_id)] = tonumber(current.expires_at) or os.time()
                    self:_openPrepared(prepared, callback, account, generation, read_generation)
                end)
                return
            end
            if not complete and (not account.session or not account.session_valid) then
                local cached = false
                for number in ipairs(prepared.descriptor.pages) do
                    local page = account.pages:getPage(tostring(episode_id), prepared.descriptor.revision, number)
                    if page and page.state == "ready" then cached = true; break end
                end
                if not cached then
                    Util.callback(callback, nil, errorValue("authentication", "This chapter has no cached images. Import a valid session to fetch them.")); return
                end
            end
            self:_openPrepared(prepared, callback, account, generation, read_generation)
        end)
    end)
end

function Controller:_openPrepared(prepared, callback, account, generation, read_generation)
    if not currentRead(self, account, generation, read_generation) then return end
    self:_guardAsync(callback, function()
        if self.opening then Util.callback(callback, nil, errorValue("busy", "Another chapter is opening.")); return end
        for integration in pairs(self.integrations) do
            if integration:isCurrent() and integration.document.file == prepared.path then
                account.downloads:clearFailures(prepared.descriptor.episode_id); integration:requestVisible()
                Util.callback(callback, prepared); return
            end
        end
        local allowed, access_error = self:authorizeDescriptor(prepared.descriptor, account)
        if not allowed then Util.callback(callback, nil, access_error); return end
        local opening = { descriptor = prepared.descriptor, path = prepared.path, account = account, callback = callback,
            read_generation = read_generation }
        local active_key = opening.descriptor.episode_id .. "/" .. opening.descriptor.revision
        local before_active = account.pages.active[active_key] or 0
        local acquired = pcall(account.pages.setActiveEpisode, account.pages, opening.descriptor.episode_id, opening.descriptor.revision, true)
        if not acquired then
            account.pages.active[active_key] = before_active
            Util.callback(callback, nil, errorValue("storage", "The chapter could not be protected for reading.")); return
        end
        self.opening = opening
        opening.active_guard = true
        opening.timeout = function()
            if self.opening == opening then self:_releaseOpening(errorValue("reader", "The native reader did not finish opening the chapter.")) end
        end
        self.ui_manager:scheduleIn(30, opening.timeout)
        local after_open = function(reader)
            if currentRead(self, account, generation, read_generation) and self.opening == opening then self:attachReader(reader, opening)
            elseif reader and reader.onClose then reader:onClose() end
        end
        local ok = pcall(function()
            if self.reader_opener then self.reader_opener(prepared.path, Provider, after_open)
            else require("apps/reader/readerui"):showReader(prepared.path, Provider, nil, true, after_open) end
        end)
        if not ok then self:_releaseOpening(errorValue("reader", "The native reader could not open this chapter.")) end
    end)
end

function Controller:attachReader(reader, expected_opening)
    if self.closed or not reader or not reader.document or reader.document.provider ~= "bilicomics_document" then return end
    -- The request's after-open callback owns attachment while a controlled open is pending.
    if self.opening and not expected_opening then return end
    if expected_opening and self.opening ~= expected_opening then return end
    local allowed, access_error = self:authorizeDescriptor(reader.document.descriptor)
    if not allowed then
        if expected_opening then self:_releaseOpening(access_error) end
        self.ui_manager:nextTick(function() if reader.onClose then reader:onClose() end end)
        return nil, access_error
    end
    local integration, err = require("bilicomics/reader/integration").attach(reader)
    if not integration then self:_releaseOpening(err or errorValue("reader", "Native reader integration is unavailable.")); return nil, err end
    self.integrations[integration], self.active_integration = true, integration
    local opening = self.opening
    if opening and reader.document.file == opening.path then
        self:_releaseOpening()
        local comic = self.account.store:getComic(opening.descriptor.comic_id)
        if comic and not self.account.downloads:isRetiredVersion(opening.descriptor.episode_id, opening.descriptor.revision) then
            comic.last_read_at, comic.last_episode_id = os.time(), opening.descriptor.episode_id
            self.account.store:upsertComic(comic)
        end
        Util.callback(opening.callback, { descriptor = opening.descriptor, path = opening.path })
    end
    self:_notify()
    return integration
end

function Controller:downloadEpisodes(comic_id, episode_ids, callback)
    self:_protect(callback, function()
        local jobs = {}
        -- Validate the complete selection before enqueueing any chapter.
        for _index, episode_id in ipairs(episode_ids or {}) do
            local episode = self.account.store:getEpisode(episode_id)
            if not episode or episode.comic_id ~= tostring(comic_id) or not DownloadService.isReadable(episode, true) then
                return nil, errorValue("entitlement", "Every selected chapter must have confirmed offline reading rights.")
            end
            if not self.account.session or not self.account.session_valid then
                local descriptor = self.account.catalog:getDescriptor(tostring(episode_id))
                if not descriptor or not self.account.pages:isComplete(tostring(episode_id), descriptor.revision) then
                    return nil, errorValue("authentication", "Import a valid session to download missing chapter images.")
                end
            end
        end
        for _index, episode_id in ipairs(episode_ids or {}) do
            local job, err = self.account.downloads:enqueue(comic_id, episode_id)
            if not job then return nil, err end
            jobs[#jobs + 1] = job
        end
        self:_notify(); return jobs
    end)
end
function Controller:getDownloads()
    local result, retained = {}, {}
    for _index, job in ipairs(self.account.store:listJobs()) do
        if self.account.downloads then job = self.account.downloads:projectJob(job) end
        if job.kind == "episode_download" and not (job.payload or {}).removed then
            local key = job.episode_id .. "/" .. tostring(job.revision)
            if not (job.payload or {}).replaced_by or not retained[key] then result[#result + 1] = job end
            if (job.payload or {}).replaced_by then retained[key] = true end
        end
    end
    return result
end

function Controller:readDownload(job_id, callback)
    local account, generation = self.account, self.generation
    self:_guardAsync(callback, function()
        local job = account.store:getJob(job_id)
        if not job or job.kind ~= "episode_download" or not job.revision or (job.payload or {}).removed then
            Util.callback(callback, nil, errorValue("not_found", "The retained download was not found.")); return
        end
        local descriptor, path = account.store:getDescriptor(job.episode_id, job.revision)
        if not descriptor or not path or not Files.exists(path) or descriptor.comic_id ~= job.comic_id then
            Util.callback(callback, nil, errorValue("cache_missing", "This download's chapter descriptor is unavailable.")); return
        end
        if not DownloadService.isReadable(account.store:getEpisode(job.episode_id), true) then
            Util.callback(callback, nil, errorValue("entitlement", "Offline rights for this chapter are not confirmed.")); return
        end
        if account.downloads:isRetiredVersion(job.episode_id, job.revision) or not account.session or not account.session_valid then
            local cached = false
            for index in ipairs(descriptor.pages) do
                local page = account.pages:getPage(job.episode_id, job.revision, index)
                if page and page.state == "ready" then cached = true; break end
            end
            if not cached then
                Util.callback(callback, nil, errorValue("cache_missing", "This retained version has no usable cached images.")); return
            end
        end
        self:_openPrepared({ descriptor = descriptor, path = path }, callback, account, generation)
    end)
end
function Controller:pauseJob(job_id) return self.account.downloads:pause(job_id) end
function Controller:resumeJob(job_id) return self.account.downloads:resume(job_id) end
function Controller:cancelJob(job_id) return self.account.downloads:pause(job_id, true) end

function Controller:_checkSourceRefreshPositions(basis)
    local function invalid()
        return nil, errorValue("unverified_position", "The saved native reading position refers to unverified content.")
    end
    local DocSettings = require("docsettings")
    local config = DocSettings:open(basis.path)
    local positions = config:readSetting("page_positions") or {}
    if type(positions) ~= "table" then return invalid() end
    local function item(value)
        local index = tonumber(value)
        if not index or index % 1 ~= 0 then return end
        return basis.pages[index], index
    end
    for number, position in pairs(positions) do
        local page = item(number)
        if not page or type(position) ~= "number" or position ~= position or math.abs(position) == math.huge
            or (position ~= 0 and page.history ~= "committed") then return invalid() end
    end
    local page, index = item(config:readSetting("last_page") or 1)
    if not page or (page.history ~= "committed" and index ~= 1) then return invalid() end
    return true
end

function Controller:refreshDownloadSources(job_id, callback)
    if not self:_authenticated(callback) then return end
    if self.suspended or not self:_connected() then
        self:_later(callback, nil, errorValue("network", "Connect before refreshing the chapter's image sources.")); return
    end
    local account, generation = self.account, self.generation
    local job = account.store:getJob(job_id)
    if not job then self:_later(callback, nil, errorValue("not_found", "The download was not found.")); return end
    local function finish(value, err)
        if self.closed or self.account ~= account or self.generation ~= generation then return end
        if value then
            local ok, resumed, resume_error = pcall(function()
                account.pages:pinEpisode(value.episode_id, value.revision, true)
                return account.downloads:resume(job_id)
            end)
            if not ok then err = errorValue("storage", "Image sources were updated, but the download could not resume safely.")
            elseif not resumed then err = resume_error or errorValue("download", "The verified chapter download could not resume.") end
        end
        Util.callback(callback, value, err)
        self:_notify()
    end
    local ok, started, err = pcall(account.downloads.refreshSources, account.downloads, job_id,
        function(episode_id, done)
            return self:_submit({ kind = "source_index", comic_id = job.comic_id, episode_id = episode_id },
                { priority = 30 }, function(result, failure)
                    if not result then Util.callback(done, nil, failure); return end
                    self:_protect(done, function()
                        account.catalog:ingestDetail(result.detail)
                        return result.index
                    end)
                end)
        end, finish, function(basis) return self:_checkSourceRefreshPositions(basis) end)
    if not ok then self:_later(callback, nil, errorValue("storage", "Source verification could not start safely."))
    elseif not started then self:_later(callback, nil, err) end
end

function Controller:cancelSourceRefresh(job_id)
    return self.account.downloads:cancelSourceRefresh(job_id)
end

function Controller:replaceDownloadVersion(job_id, callback)
    if not self:_authenticated(callback) then return end
    if self.suspended or not self:_connected() then
        self:_later(callback, nil, errorValue("network", "Connect before preparing a new chapter version.")); return
    end
    local account, generation = self.account, self.generation
    self:_guardAsync(callback, function()
        local job = account.store:getJob(job_id)
        if not job then Util.callback(callback, nil, errorValue("not_found", "The download was not found.")); return end
        if self.preparing[job.episode_id] then
            Util.callback(callback, nil, errorValue("busy", "Wait for the current chapter preparation to finish.")); return
        end
        local function finish(value, err)
            if self.closed or self.account ~= account or self.generation ~= generation then
                Util.callback(callback, nil, errorValue("canceled", "The account changed before new-version preparation completed.")); return
            end
            if value then
                local ok, resumed, resume_error = pcall(account.downloads.resume, account.downloads, value.job.id)
                if not ok then err = errorValue("storage", "The new version was saved, but its download could not resume safely.")
                elseif not resumed then err = resume_error or errorValue("download", "The new chapter download could not resume.") end
            end
            Util.callback(callback, value, err)
            self:_notify()
        end
        local started, err = account.downloads:replaceVersion(job_id, function(episode_id, done)
            return self:_submit({ kind = "source_index", comic_id = job.comic_id, episode_id = episode_id },
                { priority = 30 }, function(result, failure)
                    if not result then Util.callback(done, nil, failure); return end
                    self:_protect(done, function()
                        account.catalog:ingestDetail(result.detail)
                        return result.index
                    end)
                end)
        end, finish)
        if not started then self:_later(callback, nil, err) end
    end)
end

function Controller:cancelVersionReplacement(job_id)
    return self.account.downloads:cancelVersionReplacement(job_id)
end

function Controller:removeDownload(job_id, callback)
    self:_protect(callback, function()
        local job = self.account.store:getJob(job_id)
        if not job or job.kind ~= "episode_download" or not job.revision then return nil, errorValue("not_found", "The download was not found.") end
        if (self.account.pages.active[job.episode_id .. "/" .. job.revision] or 0) > 0 then
            return nil, errorValue("active_content", "Close this chapter before removing its downloaded images.")
        end
        local related = {}
        for _, candidate in ipairs(self.account.store:listJobs()) do
            if candidate.kind == "episode_download" and candidate.episode_id == job.episode_id
                and candidate.revision == job.revision then
                self.account.downloads:pause(candidate.id, true)
                related[#related + 1] = candidate.id
            end
        end
        local result = self.account.pages:removeEpisode(job.episode_id, job.revision)
        self.account.store:transaction(function()
            for _, related_id in ipairs(related) do
                local current = self.account.store:getJob(related_id)
                current.state, current.completed = "canceled", 0
                current.payload = current.payload or {}; current.payload.removed = true
                self.account.store:putJob(current)
            end
        end)
        self.account.downloads:clearFailures(job.episode_id)
        self:_notify(); return result
    end)
end

function Controller:getSetting(key, default)
    if key == "download_concurrency" then
        local value = self.settings:get(key, 2)
        return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= 4 and value or 2
    elseif key == "reading_mode" then
        local value = self.settings:get(key, "auto")
        return (value == "auto" or value == "page" or value == "strip") and value or "auto"
    elseif key == "reading_direction" then
        return self.settings:get(key, "ltr") == "rtl" and "rtl" or "ltr"
    end
    if key == "cache_limit_mb" then return math.floor((self.settings:get("cache_limit_bytes") or (default or 256) * 1048576) / 1048576) end
    if key == "search_history" then return self.account.store:getSetting(key, default or {}) end
    return self.settings:get(key, default)
end
function Controller:setSetting(key, value)
    if key == "download_concurrency" then
        if type(value) ~= "number" or value % 1 ~= 0 or value < 1 or value > 4 then
            return nil, errorValue("invalid_request", "Choose one through four concurrent downloads.")
        end
        local saved = pcall(self.settings.set, self.settings, key, value)
        if not saved then return nil, errorValue("storage", "The download concurrency could not be saved.") end
        if self.account and self.account.raw_runner.setImageConcurrency then self.account.raw_runner:setImageConcurrency(value) end
        if self.account and self.account.downloads.refreshConcurrency then self.account.downloads:refreshConcurrency() end
        self:_notify()
        return true
    end
    if (key == "reading_mode" and value ~= "auto" and value ~= "page" and value ~= "strip")
        or (key == "reading_direction" and value ~= "ltr" and value ~= "rtl") then
        return nil, errorValue("invalid_request", "Select a supported reading default.")
    end
    if key == "search_history" then self.account.store:putSetting(key, value)
    elseif key == "cache_limit_mb" then
        local limit = math.max(0, tonumber(value) or 256) * 1048576
        self.settings:set("cache_limit_bytes", limit)
        self.account.pages:evictToLimit(limit)
    else self.settings:set(key, value) end
    self:_notify(); return true
end
function Controller:getStorageSummary()
    local summary = { total_bytes = 0, automatic_bytes = 0, pinned_bytes = 0, ready_pages = 0, missing_pages = 0, failed_pages = 0 }
    local filesystem = require("bilicomics/jobs/storage_budget").summary(self.account.root)
    if filesystem then
        summary.free_bytes, summary.capacity_bytes = filesystem.free_bytes, filesystem.capacity_bytes
    end
    for _index, page in ipairs(self.account.store:listAllPages()) do
        if page.state == "ready" then
            summary.ready_pages = summary.ready_pages + 1
            local bytes = page.bytes or 0
            summary.total_bytes = summary.total_bytes + bytes
            local category = self.account.store:isPinned(page.episode_id, page.revision) and "pinned_bytes" or "automatic_bytes"
            summary[category] = summary[category] + bytes
        else summary[page.state == "failed" and "failed_pages" or "missing_pages"] = summary[page.state == "failed" and "failed_pages" or "missing_pages"] + 1 end
    end
    return summary
end
function Controller:clearAutomaticCache()
    local ok, result = pcall(self.account.pages.clearAutomaticCache, self.account.pages)
    if not ok then return nil, errorValue("storage", "The automatic cache could not be cleared safely.") end
    self:_notify(); return result
end

local diagnostic_capabilities = { "request_signing", "response_decoding", "index_challenge", "image_key_exchange",
    "encrypted_images", "protected_catalog", "image_index", "image_tokens", "purchase", "wallet", "search", "library" }
local diagnostic_os = { Linux = true, Windows = true, OSX = true, BSD = true, POSIX = true, Android = true }
local diagnostic_arch = { x86 = true, x64 = true, arm = true, arm64 = true, ppc = true, mips = true }
local diagnostic_target = { ["android-arm64-v8a"] = true, ["android-armeabi-v7a"] = true,
    ["android-x86"] = true, ["android-x86_64"] = true, ["linux-x86_64"] = true,
    ["linux-aarch64"] = true, ["linux-armhf"] = true }
local function diagnosticVersion(value)
    if type(value) ~= "string" or #value > 64 or not value:match("^[vV]?%d[%w._+%-]*$") then return "unknown" end
    local lower = value:lower()
    for _, word in ipairs({ "cookie", "token", "sessdata", "authorization", "secret" }) do
        if lower:find(word, 1, true) then return "unknown" end
    end
    return value
end

function Controller:getDiagnostics(callback)
    self:_submit({ kind = "diagnostics" }, { priority = 30 }, function(result, err)
        if not result then Util.callback(callback, nil, err); return end
        self:_protect(callback, function()
            local platform = type(result.platform) == "table" and result.platform or {}
            local source = type(result.capabilities) == "table" and result.capabilities or {}
            local capabilities = {}
            for _, key in ipairs(diagnostic_capabilities) do if type(source[key]) == "boolean" then capabilities[key] = source[key] end end
            local account = self.account
            return {
                schema_version = 1, checked_at = os.time(), server_checked = false,
                plugin_version = diagnosticVersion(result.plugin_version), koreader_version = diagnosticVersion(result.koreader_version),
                platform = { os = diagnostic_os[platform.os] and platform.os or "unknown",
                    arch = diagnostic_arch[platform.arch] and platform.arch or "unknown",
                    target = diagnostic_target[platform.target] and platform.target or "unknown" },
                capabilities = capabilities,
                local_session = account.authentication_invalidated and "invalid"
                    or (account.session and account.session_valid and "stored") or "missing",
                credential_storage = self.session_storage.is_android and "app_private" or "account_storage",
                reader_defaults = { reading_mode = self:getSetting("reading_mode", "auto"),
                    reading_direction = self:getSetting("reading_direction", "ltr") },
            }
        end)
    end)
end

function Controller:_fetchQuote(episode_id, scope, payment, callback)
    local selection, selection_error = PurchaseSelection.normalize(scope, payment)
    if not selection then self:_later(callback, nil, selection_error); return end
    if not self:_authenticated(callback) then return end
    local episode = self.account.store:getEpisode(episode_id)
    if not episode then self:_later(callback, nil, errorValue("access_unknown", "Refresh the chapter catalog before reviewing a purchase.")); return end
    self:_submit({ kind = "quote", episode_id = tostring(episode_id), comic_id = episode.comic_id,
        scope = Util.copy(selection.scope), payment = Util.copy(selection.payment) },
        { priority = -5 }, function(result, err)
            if not result then Util.callback(callback, nil, err); return end
            self:_protect(callback, function()
                self.account.catalog:ingestDetail(result.detail)
                return self.account.purchases:buildQuote(tostring(episode_id), selection.scope, selection.payment,
                    result.info, result.detail, result.context)
            end)
        end)
end
function Controller:quotePurchase(episode_id, scope, payment, callback)
    self:_fetchQuote(episode_id, scope, payment, function(quote, err)
        if quote and quote.submittable ~= false and quote.fingerprint then self.quotes[quote.id] = Util.copy(quote) end
        Util.callback(callback, quote, err); self:_notify()
    end)
end

function Controller:purchase(quote, purpose, callback)
    if type(purpose) == "function" and callback == nil then callback, purpose = purpose, "read" end
    if purpose == nil then purpose = "read" end
    if purpose ~= "read" and purpose ~= "download" then
        self:_later(callback, nil, errorValue("invalid_purpose", "Purchase continuation must be read or download.")); return
    end
    if type(quote) ~= "table" or not self.quotes[quote.id]
        or not quote.fingerprint or self.quotes[quote.id].fingerprint ~= quote.fingerprint then
        self:_later(callback, nil, errorValue("invalid_quote", "Get a current quote and explicitly confirm it before purchasing.")); return
    end
    -- The displayed, stored snapshot is authoritative; caller tables cannot replace its terms.
    quote = Util.copy(self.quotes[quote.id])
    if self.purchase_inflight[quote.id] then self:_later(callback, nil, errorValue("purchase_busy", "This purchase is already being submitted.")); return end
    self.purchase_inflight[quote.id] = true
    local account = self.account
    local function done(intent, err)
        self.purchase_inflight[quote.id] = nil
        Util.callback(callback, intent, err); self:_notify()
    end
    self:_fetchQuote(quote.episode_id, quote.scope, quote.payment, function(fresh, err)
        if not fresh then done(nil, err); return end
        local intent, payload = account.purchases:prepareSubmission(quote, { confirmed = true, purpose = purpose }, fresh)
        if not intent then
            local existing = payload and payload.intent_id and account.store:getPurchase(payload.intent_id)
            done(existing, payload); return
        end
        self:_notify()
        self:_submit({ kind = "purchase_submit", intent_id = intent.id, payload = payload },
            { priority = -10, resource = "purchase", cancelable = false, timeout = 120,
                before_start = function() return account.purchases:authorizeSubmission(intent.id) end }, function(response, submission_error)
                local completed, completion_error = account.purchases:completeSubmission(intent.id, response, submission_error)
                if not completed or completed.persistence_pending then
                    local visible = completed
                    if not visible then
                        local loaded, saved = pcall(account.store.getPurchase, account.store, intent.id)
                        visible = (loaded and saved) or Util.copy(intent)
                    end
                    visible.persistence_pending = true
                    if visible.state == "submitting" then
                        visible.state = response and response.accepted and "accepted"
                            or (submission_error and (submission_error.definitive or submission_error.transmitted == false)
                                and "rejected") or "outcome_unknown"
                        if submission_error and submission_error.transmitted == false then
                            visible.transaction_evidence = "not_transmitted"
                        end
                    end
                    account.pending_submission_results[intent.id] = { response = response, error = submission_error, visible = visible }
                    done(visible, completion_error or errorValue("outcome_unknown", "The purchase result is pending durable confirmation.")); return
                end
                if completed.state == "accepted" then self:reconcilePurchase(intent.id, done)
                else done(completed, completion_error) end
            end)
    end)
end

function Controller:reconcilePurchase(intent_id, callback)
    local account = self.account
    local intent = account.store:getPurchase(intent_id)
    local received = account.pending_submission_results[intent_id]
    if received then
        local saved, save_error = account.purchases:completeSubmission(intent_id, received.response, received.error)
        if not saved or saved.persistence_pending then
            self:_later(callback, saved or received.visible, save_error or errorValue("storage", "The known purchase result is not yet durable.")); return
        end
        account.pending_submission_results[intent_id], intent = nil, saved
    end
    for _index, candidate in ipairs(account.purchases:listPending() or {}) do if candidate.id == intent_id then intent = candidate; break end end
    if not intent then self:_later(callback, nil, errorValue("not_found", "The pending purchase was not found.")); return end
    if intent.state == "rejected" or intent.state == "access_confirmed" then self:_later(callback, intent); return end
    if intent.state == "submitting" and not intent.persistence_pending then
        self:_later(callback, intent, errorValue("purchase_busy", "The purchase is still being submitted.")); return
    end
    if not account.session or not account.session_valid then
        self:_later(callback, intent, errorValue("authentication", "Import a verified session to confirm chapter access."))
        return
    end
    self:_submit({ kind = "reconcile_purchase", comic_id = intent.comic_id }, { priority = -5 }, function(result, err)
        self:_protect(callback, function()
            if result and result.detail then account.catalog:ingestDetail(result.detail) end
            if result and result.wallet then
                local wallet = Normalize.safeExtra(result.wallet); wallet.updated_at = os.time(); account.store:putSetting("wallet", wallet)
            end
            local wallet_evidence = result and result.wallet_error and { error = result.wallet_error } or nil
            local observed, observation_error = account.purchases:completeReconciliation(intent_id,
                result and result.detail, wallet_evidence, err)
            self:_notify(); return observed, observation_error
        end)
    end)
end

function Controller:_requestReaderPage(account, descriptor, index, options)
    if self.closed or self.account ~= account or self.suspended then return end
    options = options or {}
    local page = account.pages:getPage(descriptor.episode_id, descriptor.revision, index)
    if page and page.state == "ready" then return end
    if account.downloads:isRetiredVersion(descriptor.episode_id, descriptor.revision) then
        if not options.prefetch then self.ui_manager:nextTick(function()
            if self.account == account then self:_pageError(descriptor, index, options,
                errorValue("version_replaced", "Only cached pages are available in this retained older version.")) end
        end) end
        return
    end
    if not account.session or not account.session_valid or not self:_connected() then
        if not options.prefetch then
            self.ui_manager:nextTick(function()
                if self.account == account then self:_pageError(descriptor, index, options,
                    errorValue(account.session and account.session_valid and "network" or "authentication", "The missing image needs an online session.")) end
            end)
        end
        return
    end
    if options.prefetch then
        local count = self.settings:get("prefetch_pages", 3)
        if not self.settings:get("prefetch", true) or count <= 0 then return end
        local integration = self.active_integration
        if integration and integration:isCurrent() and integration.document.descriptor.episode_id == descriptor.episode_id then
            if index > integration.reader.paging:getTopPage() + count then return end
        end
    end
    if not page or not (page.extra or {}).source_path then
        self:prepareEpisode(descriptor.comic_id, descriptor.episode_id, function(prepared, err)
            if not prepared then
                if not options.prefetch then self:_pageError(descriptor, index, options, err) end
                return
            end
            if prepared.descriptor.revision ~= descriptor.revision then
                if not options.prefetch then self:_pageError(descriptor, index, options,
                    errorValue("content_changed", "The chapter content changed. Reopen it from the catalog.")) end
                return
            end
            account.downloads:requestPage(descriptor, index, options, function(_page, failure)
                if failure and not options.prefetch then self:_pageError(descriptor, index, options, failure) end
            end)
        end)
        return
    end
    account.downloads:requestPage(descriptor, index, options, function(_page, err)
        if err and not options.prefetch and err.kind ~= "canceled" then self:_pageError(descriptor, index, options, err) end
    end)
end

function Controller:_nextEpisode(descriptor)
    local found = false
    for _index, episode in ipairs(self.account.catalog:getEpisodes(descriptor.comic_id)) do
        if found then return episode end
        if tostring(episode.id) == descriptor.episode_id then found = true end
    end
end

function Controller:_preloadNext(event)
    local account, integration = self.account, self.active_integration
    local function permittedCount()
        if self.closed or self.suspended or not account or self.account ~= account
            or not integration or self.active_integration ~= integration or not integration:isCurrent()
            or integration.generation ~= event.reader_generation then return 0 end
        if not account.session or not account.session_valid or not self:_connected() then return 0 end
        if not self.settings:get("prefetch", true) or self.settings:get("prefetch_pages", 3) <= 0 then return 0 end
        if account.downloads:isRetiredVersion(event.descriptor.episode_id, event.descriptor.revision) then return 0 end
        return self.settings:get("next_episode_pages", 2)
    end
    if permittedCount() <= 0 then return end
    local next_episode = self:_nextEpisode(event.descriptor)
    if not next_episode or not DownloadService.isReadable(next_episode, false) then return end
    local key = tostring(event.reader_generation) .. ":" .. next_episode.id
    if self.preloaded[key] then return end
    self.preloaded[key] = true
    self:prepareEpisode(event.descriptor.comic_id, next_episode.id, function(prepared)
        if not prepared then return end
        local count = permittedCount()
        if count <= 0 then return end
        for index = 1, math.min(count, #prepared.descriptor.pages) do
            account.downloads:requestPage(prepared.descriptor, index,
                { prefetch = true, reader_generation = event.reader_generation, priority = 30 })
        end
    end)
end

function Controller:_readerEvent(name, event)
    local retired = event.descriptor and self.account.downloads:isRetiredVersion(event.descriptor.episode_id, event.descriptor.revision)
    if name == "position" then
        local episode = self.account.store:getEpisode(event.descriptor.episode_id)
        if not retired and episode and (episode.extra or {}).local_finished_at then event.anchor.finished = true end
        self.account.catalog:updatePosition(event.descriptor, event.anchor)
        self:_prefetchConfigured(event)
        self:_notify()
    elseif name == "opened" then self.errors_shown = {}; self:_prefetchConfigured(event)
    elseif name == "near_end" then self:_preloadNext(event)
    elseif name == "end_of_book" then
        local anchor = self.account.store:getAnchor(event.descriptor.episode_id, event.descriptor.revision)
        if anchor then
            anchor.finished = true
            self.account.catalog:updatePosition(event.descriptor, anchor)
            if not retired then
                local episode = self.account.store:getEpisode(event.descriptor.episode_id)
                episode.extra = episode.extra or {}; episode.extra.local_finished_at = os.time()
                self.account.store:upsertEpisodes(episode.comic_id, { episode })
            end
        end
        self:_chapterBoundary(event)
    elseif name == "closed" then
        self.account.downloads:releaseReader(event.reader_generation)
        for integration in pairs(self.integrations) do
            if integration.generation == event.reader_generation then self.integrations[integration] = nil end
        end
        if self.active_integration and self.active_integration.generation == event.reader_generation then self.active_integration = nil end
        local account, generation = self.account, self.generation
        self.ui_manager:nextTick(function()
            if not self.closed and not self.suspended and self.account == account and self.generation == generation
                and not self.opening and not self.active_integration and next(self.integrations) == nil
                and self.screens and self.screens.onReaderClosed then
                self.screens:onReaderClosed{ comic_id = event.comic_id or event.descriptor and event.descriptor.comic_id,
                    reader_generation = event.reader_generation }
            end
        end)
    elseif name == "page_error" then self:_pageError(event.descriptor, event.index or 1, {}, event.error)
    elseif name == "suspend" then self:suspend()
    elseif name == "resume" then self:resume() end
end

function Controller:_prefetchConfigured(event)
    local integration = self.active_integration
    local count = self.settings:get("prefetch_pages", 3)
    if not self.settings:get("prefetch", true) or count <= 0 or self.suspended or not integration or not integration:isCurrent() then return end
    if integration.generation ~= event.reader_generation then return end
    local index = integration.reader.paging:getTopPage()
    for number = index + 1, math.min(index + count, #event.descriptor.pages) do
        self:_requestReaderPage(self.account, event.descriptor, number,
            { prefetch = true, reader_generation = event.reader_generation, priority = 20 })
    end
end

local function readerCaption(value)
    local text = tostring(value or ""):gsub("[%c]", " ")
    if #text <= 120 then return text end
    local last = 120
    while last > 0 and text:byte(last + 1) >= 128 and text:byte(last + 1) <= 191 do last = last - 1 end
    return text:sub(1, last) .. "…"
end

local function readerOverlayUI()
    local W = require("bilicomics/ui/widgets")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local screen_width = require("device").screen:getWidth()
    local margin = W.dp(56)
    local ui = { W = W, width = screen_width - 2 * margin, focus = {} }
    function ui:text(text, width, size, options)
        return W.text(text, width or self.width, W.fontSize(size), options)
    end
    function ui:space(height) return W.spacePixels(W.dp(height)) end
    function ui:rule(width)
        return W.rule(width or self.width)
    end
    function ui:button(text, callback, width, primary, height)
        local button = W.button(text, width or self.width, callback,
            { primary = primary, size = W.fontSize(primary and 23 or 22), height_px = W.dp(height or 68) })
        return button
    end
    function ui:progress(index, total)
        return W.progress(self.width, W.dp(8), index / math.max(1, total))
    end
    function ui:row(label, hint, callback)
        local label_width = math.floor(self.width * 0.58)
        local row = W.ActionRow:new{ width = self.width, callback = callback,
            content = CenterContainer:new{ dimen = Geom:new{ w = self.width, h = W.dp(72) },
                W.row{ self:text(label, label_width, 21),
                    self:text(hint or "", self.width - label_width, 17, { muted = true, align = "right" }) } } }
        self.focus[#self.focus + 1] = { row }
        return W.column{ row, self:rule() }
    end
    function ui:card(content)
        return FrameContainer:new{ padding = 0, margin = 0, bordersize = W.dp(1.5), radius = 0,
            color = W.ink, background = W.paper,
            W.inset(content, W.dp(26), W.dp(26), W.dp(22), W.dp(22)) }
    end
    function ui:tag(text)
        local TextWidget = require("ui/widget/textwidget")
        local Font = require("ui/font")
        return FrameContainer:new{ padding = W.dp(4), margin = 0, bordersize = W.dp(1.5), radius = 0,
            color = W.ink, background = W.paper, W.row{ W.gap(W.dp(5)),
                TextWidget:new{ text = text, face = Font:getFace("cfont", W.fontSize(18)),
                    bold = true, fgcolor = W.ink, padding = 0 }, W.gap(W.dp(5)) } }
    end
    function ui:sheet(content, dismiss)
        return W.sheetDialog(W.inset(content, margin, margin, W.dp(30), W.dp(36)), self.focus,
            { width = screen_width, padding = 0, close_callback = dismiss })
    end
    return ui
end

function Controller:_chapterBoundary(event)
    if self.chapter_dialog then return end
    local next_episode = self:_nextEpisode(event.descriptor)
    local account = self.account
    local integration = event.reader and event.reader.bilicomics_integration or self.active_integration
    local function current()
        return not self.closed and self.account == account and (not integration or integration:isCurrent())
    end
    local properties = {}
    if integration and integration.document.getDocumentProps then properties = integration.document:getDocumentProps() or {} end
    local heading = next_episode and _("End of chapter") or _("Latest available chapter finished")
    local function dismiss()
        if self.chapter_dialog then self.ui_manager:close(self.chapter_dialog); self.chapter_dialog = nil end
        if integration then integration:finishTransition() end
    end
    local ui = readerOverlayUI()
    local W = ui.W
    local content = { ui:text(heading, nil, 30, { bold = true }), ui:space(12),
        ui:text(string.format(_("Finished: %s"), readerCaption(properties.title or event.descriptor.episode_id)), nil, 20) }
    local next_readable = next_episode and DownloadService.isReadable(next_episode, false)
    if next_episode then
        local card_width = ui.width - 2 * W.dp(26) - 2 * W.dp(1.5)
        local available = require("bilicomics/ui/model").entitlement(next_episode)
        local status = next_readable and (available .. " · " .. (self:_connected() and _("Online reading") or _("Offline reading")))
            or (next_episode.access == "locked" and _("Unread · purchase required before reading") or available)
        local preload_key = tostring(event.reader_generation) .. ":" .. tostring(next_episode.id)
        if next_readable and self.preloaded[preload_key] then status = status .. " · " .. _("Preloading started") end
        local details = { ui:text(_("Next chapter"), card_width, 16, { muted = true }), ui:space(6),
            ui:text(readerCaption(next_episode.title or next_episode.short_title or next_episode.id), card_width, 25, { bold = true }),
            ui:space(10), ui:text(status, card_width, 17, { muted = true }) }
        local price = tonumber(next_episode.pay_gold)
        if next_episode.access == "locked" and price and price == price and price >= 0 and price < math.huge then
            details[#details + 1] = ui:space(12)
            details[#details + 1] = ui:tag(string.format(_("%s comic coins"), tostring(price)))
        end
        content[#content + 1] = ui:space(26)
        content[#content + 1] = ui:card(W.column(details))
    else
        content[#content + 1] = ui:space(20)
        content[#content + 1] = ui:text(_("Check the catalog for future updates."), nil, 19, { muted = true })
    end
    local primary
    if next_episode then
        if next_readable then
            primary = ui:button(_("Read next chapter"), function()
                if not current() then return end
                dismiss(); self:readEpisode(event.descriptor.comic_id, next_episode.id, function(_value, err)
                    if err and self.screens then self.screens:_error(err) end
                end)
            end, nil, true)
        elseif next_episode.access == "locked" then
            primary = ui:button(_("Review next chapter purchase quote"), function()
                if not current() then return end
                dismiss()
                if self.screens then
                    self.screens:showComic(event.descriptor.comic_id)
                    self.screens:_purchaseFor(self:getComic(event.descriptor.comic_id), next_episode)
                end
            end, nil, true)
        end
    end
    if primary then
        content[#content + 1] = ui:space(26)
        content[#content + 1] = primary
        ui.focus[#ui.focus + 1] = { primary }
        if not next_readable then
            content[#content + 1] = ui:space(14)
            content[#content + 1] = ui:text(_("No automatic purchase. A quote must be confirmed before submitting."), nil, 17, { muted = true })
        end
    end
    local gap, catalog_width = W.dp(16), math.floor((ui.width - 2 * W.dp(16)) / 3)
    local catalog = ui:button(_("Chapter catalog"), function()
        if not current() then return end
        dismiss(); if self.screens then self.screens:showComic(event.descriptor.comic_id) end
    end, catalog_width, false, 64)
    local bookshelf = ui:button(_("Return to bookshelf"), function()
        if not current() then return end
        dismiss()
        self.ui_manager:nextTick(function()
            if not current() then return end
            if integration and integration.reader.onClose then integration.reader:onClose() end
            self.ui_manager:nextTick(function()
                if not self.closed and self.account == account and self.screens then self.screens:showLibrary() end
            end)
        end)
    end, catalog_width, false, 64)
    local stay = ui:button(_("Stay in this chapter"), dismiss, ui.width - 2 * catalog_width - 2 * gap, false, 64)
    content[#content + 1] = ui:space(16)
    content[#content + 1] = W.row{ catalog, W.gap(gap), bookshelf, W.gap(gap), stay }
    ui.focus[#ui.focus + 1] = { catalog, bookshelf, stay }
    self.chapter_dialog = ui:sheet(W.column(content), dismiss)
    self.ui_manager:show(self.chapter_dialog)
end

function Controller:_pageError(descriptor, index, options, err)
    local account = self.account
    local integration = self.active_integration
    if not integration or not integration:isCurrent() or integration.document.descriptor.episode_id ~= descriptor.episode_id
        or integration.document.descriptor.revision ~= descriptor.revision then return end
    local key = descriptor.episode_id .. "/" .. descriptor.revision .. "/" .. index
    if self.errors_shown[key] then return end
    self.errors_shown[key] = true
    local W = require("bilicomics/ui/widgets")
    local heading, message, action = require("bilicomics/ui/model").error(err)
    local kind = err and err.kind
    if kind == "network" or kind == "connectivity" or kind == "timeout" or kind == "transport" then
        message = _("Check the connection and retry. Downloaded chapters remain available offline; the reading position is saved.")
    end
    local dialog
    local function current()
        return not self.closed and self.account == account and self.active_integration == integration and integration:isCurrent()
    end
    local function dismiss()
        if dialog then self.ui_manager:close(dialog); self.reader_dialogs[dialog] = nil; dialog = nil end
    end
    local function openRecovery(destination)
        if not current() then return end
        dismiss()
        -- Release the active chapter before storage or source recovery can alter its images.
        self.ui_manager:nextTick(function()
            if not current() then return end
            if integration.reader.onClose then integration.reader:onClose() end
            self.ui_manager:nextTick(function()
                if self.closed or self.account ~= account or not self.screens then return end
                if destination == "storage" and self.screens._showStorageSettings then self.screens:_showStorageSettings()
                else self.screens:showDownloads() end
            end)
        end)
    end
    local buttons = {}
    if action == "account" then
        buttons[#buttons + 1] = { { text = _("Open account"), callback = function()
            if not current() then return end
            dismiss(); if self.screens then self.screens:showAccount() end
        end } }
    elseif err and err.kind == "low_space" then
        buttons[#buttons + 1] = { { text = _("Close chapter and manage storage"), callback = function() openRecovery("storage") end } }
        buttons[#buttons + 1] = { { text = _("Close chapter and open downloads"), callback = function() openRecovery("downloads") end } }
    elseif err and (err.kind == "source_unavailable" or err.kind == "image_decode") then
        buttons[#buttons + 1] = { { text = _("Close chapter and open downloads"), callback = function() openRecovery("downloads") end } }
    elseif err and (err.kind == "unsupported_image_size" or err.kind == "content_changed" or err.kind == "version_replaced") then
        buttons[#buttons + 1] = { { text = _("Chapter catalog"), callback = function()
            if not current() then return end
            dismiss(); if self.screens then self.screens:showComic(descriptor.comic_id) end
        end } }
        if err.kind ~= "unsupported_image_size" then
            buttons[#buttons + 1] = { { text = _("Close chapter and open downloads"), callback = function() openRecovery("downloads") end } }
        end
    else
        buttons[#buttons + 1] = { { text = _("Retry image"), primary = true, callback = function()
            if not current() then return end
            dismiss()
            self.errors_shown[key] = nil
            self.account.downloads:clearFailures(descriptor.episode_id)
            self:_requestReaderPage(account, descriptor, index,
                { retry = true, reader_generation = integration.generation, priority = 0 })
        end } }
        buttons[#buttons + 1] = { { text = _("Close chapter and open downloads"), callback = function() openRecovery("downloads") end } }
    end
    if buttons[1] and buttons[1][1] then buttons[1][1].primary = true end
    buttons[#buttons + 1] = { { text = _("Back to reading"), callback = dismiss } }
    local position = string.format(_("Image %d / %d"), index, #descriptor.pages)
    local properties = integration.document:getDocumentProps() or {}
    position = position .. " · " .. readerCaption(properties.title or descriptor.episode_id)
    dialog = W.menuDialog(heading, { { text = position, size = W.fontSize(17), muted = true },
        { text = message, size = W.fontSize(20), line_height = 0.7 } }, buttons,
        { placement = "center", width = W.dp(700), left = W.dp(115), top = W.dp(320),
            title_size = 28, text_size = 20, button_height = 66, close_callback = dismiss })
    self.reader_dialogs[dialog] = true
    self.ui_manager:show(dialog)
end

function Controller:showReaderMenu()
    local integration = self.active_integration
    if not integration or not integration:isCurrent() then if self.screens then self.screens:showLibrary() end; return end
    local descriptor = integration.document.descriptor
    local account = self.account
    local dialog
    local function current()
        return not self.closed and self.account == account and self.active_integration == integration and integration:isCurrent()
    end
    local function close() if dialog then self.ui_manager:close(dialog); self.reader_dialogs[dialog] = nil; dialog = nil end end
    local properties = integration.document:getDocumentProps() or {}
    local chapter = readerCaption(properties.title or descriptor.episode_id)
    if properties.series then chapter = readerCaption(properties.series) .. " · " .. chapter end
    local ui = readerOverlayUI()
    local W = ui.W
    local title_width = W.dp(190)
    local index = math.max(1, math.min(#descriptor.pages, integration.reader.paging:getTopPage()))
    local saved, running = 0, 0
    for page = 1, #descriptor.pages do
        local spec = integration.document:getLocalPage(page)
        if spec.state == "ready" and spec.path then saved = saved + 1 end
    end
    for _, job in ipairs(self:getDownloads()) do
        if job.state == "running" or job.state == "queued" then running = running + 1 end
    end
    local rows = { W.row{ ui:text(_("Comic actions"), title_width, 26, { bold = true }),
            ui:text(chapter, ui.width - title_width, 17, { muted = true, align = "right" }) },
        ui:space(24), ui:text(string.format(_("Image %d / %d"), index, #descriptor.pages), nil, 17, { muted = true }),
        ui:space(10), ui:progress(index, #descriptor.pages), ui:space(18),
        ui:row(_("Chapter catalog"), string.format(_("%d chapters in total"), #self:getEpisodes(descriptor.comic_id)), function()
            if not current() then return end
            close(); if self.screens then self.screens:showComic(descriptor.comic_id) end
        end),
        ui:row(_("Download this chapter"), string.format(_("Cached %d / %d images"), saved, #descriptor.pages), function()
            if not current() then return end
            close(); self:downloadEpisodes(descriptor.comic_id, { descriptor.episode_id }, function(_value, err)
                if not self.screens or self.closed or self.account ~= account then return end
                if err then self.screens:_error(err) else self.screens:showDownloads() end
            end)
        end),
        ui:row(_("Manage downloads"), string.format(_("%d tasks in progress"), running), function()
            if not current() then return end
            close(); if self.screens then self.screens:showDownloads() end
        end),
    }
    if integration.reader.menu and integration.reader.menu.onShowMenu then
        rows[#rows + 1] = ui:row(_("Reader settings"), _("KOReader native menu"), function()
            if not current() then return end
            close()
            self.ui_manager:nextTick(function() if current() then integration.reader.menu:onShowMenu() end end)
        end)
    end
    rows[#rows + 1] = ui:row(_("Close chapter and return to bookshelf"), "", function()
        if not current() then return end
        close()
        self.ui_manager:nextTick(function()
            if not current() then return end
            if integration.reader.onClose then integration.reader:onClose() end
            self.ui_manager:nextTick(function()
                if not self.closed and self.account == account and self.screens then self.screens:showLibrary() end
            end)
        end)
    end)
    local back = ui:button(_("Back to reading"), close, nil, true)
    rows[#rows + 1] = ui:space(24)
    rows[#rows + 1] = back
    ui.focus[#ui.focus + 1] = { back }
    dialog = ui:sheet(W.column(rows), close)
    self.reader_dialogs[dialog] = true
    self.ui_manager:show(dialog)
end

require("bilicomics/recharge/controller")(Controller)

return Controller
