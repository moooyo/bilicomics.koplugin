-- Capture native UI states omitted by the focused historical screenshot fixtures.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
require("gettext").current_lang = arg[3] or "zh_CN"
local UIManager = require("ui/uimanager")
local Screens = require("bilicomics/ui/screens")
local json = require("rapidjson")
local _ = require("bilicomics/ui/i18n")
local width, height = Device.screen:getWidth(), Device.screen:getHeight()
local report = { width = width, height = height, language = arg[3] or "zh_CN", screenshots = {}, frames = {},
    scope = "Current production KOReader widgets with synthetic data, original cover fixtures, and no network or account access" }

local controller = { settings = {}, comics = {}, episodes = {}, jobs = {}, waiting = {}, generation = 1,
    view = { help_seen = true, sort = "source", filter = "all", page = 1 },
    wallet = { remain_gold = 80, remain_coupon = 2, stale = false },
    storage = { automatic_bytes = 104857600, pinned_bytes = 356515840 } }
local titles = { "Moonlit Observatory", "The Last Paper Crane", "Lighthouse in the Clouds", "Garden of Quiet Stars", "Silver Mountain" }
for index = 1, 9 do
    local cover = (index - 1) % 5 + 1
    controller.comics[index] = { id = tostring(index), title = titles[cover] .. (index > 5 and " II" or ""),
        authors = { "Synthetic Author" }, finished = index % 2 == 0, favorite = true,
        cover_path = output .. "/fixtures/synthetic-cover-" .. cover .. ".png", latest_order = 17,
        current_episode_id = index % 3 ~= 0 and "2" or nil, has_update = index % 2 == 1,
        description = "An original synthetic journey through quiet valleys, observatories and imagined coastal towns." }
end
for index = 1, 17 do
    controller.episodes[index] = { id = tostring(index), comic_id = "1", order = index, short_title = tostring(index),
        title = string.format(_("Chapter %s"), tostring(index)),
        access = index <= 3 and "free" or index <= 7 and "owned" or "locked",
        read = index == 1, downloaded = index == 3 or index == 5, cached_pages = index == 2 and 4 or 0,
        total_pages = 12, current_revision = "synthetic-review" }
end
controller.jobs = {
    { id = "one", kind = "episode_download", comic_id = "1", episode_id = "2", revision = "synthetic-review", state = "running", completed = 4, total = 12 },
    { id = "two", kind = "episode_download", comic_id = "2", episode_id = "3", revision = "synthetic-review", state = "complete", completed = 12, total = 12 },
    { id = "three", kind = "episode_download", comic_id = "3", episode_id = "4", revision = "synthetic-review", state = "queued", completed = 0, total = 16 },
}
function controller:getAccount() return { id = "synthetic", account_key = "synthetic-review", name = "Synthetic review account", session_valid = true } end
function controller:getLibrary() return self.comics end
function controller:getBookshelfItems() return self.comics end
function controller:getBookshelfViewState() return self.view end
function controller:saveBookshelfViewState(changes) self.view = changes; return true end
function controller:getBookshelfSyncState() return { has_cache = true, can_sync = true, authenticated = true, last_synced_at = 1789344000 } end
function controller:ensureBookshelfSync(callback) if callback then callback(self.comics) end end
function controller:getComic(id) return self.comics[tonumber(id)] end
function controller:getEpisodes() return self.episodes end
function controller:getEpisode(id) return self.episodes[tonumber(id)] end
function controller:getDownloads() return self.jobs end
function controller:getWallet() return self.wallet end
function controller:getPendingPurchases() return self.purchases or {} end
function controller:getStorageSummary() return self.storage end
function controller:getSetting(key, default) local value = self.settings[key]; if value == nil then return default end; return value end
function controller:setSetting(key, value) self.settings[key] = value; return true end
function controller:requestCover() end
function controller:cancelPendingRead() end
function controller:enqueue(method, callback) self.waiting[#self.waiting + 1] = { method = method, callback = callback } end
function controller:search(_query, callback) self:enqueue("search", callback) end
function controller:getDiagnostics(callback) self:enqueue("diagnostics", callback) end
function controller:refreshComic(_id, callback) self:enqueue("comic", callback) end
function controller:importSession(_value, callback)
    self.import_sequence = (self.import_sequence or 0) + 1
    self:enqueue("session", callback)
end
function controller:lookupComicID(_value, callback) self:enqueue("lookup", callback) end
function controller:clearAutomaticCache()
    local freed = self.storage.automatic_bytes
    self.storage.automatic_bytes = 0
    return { freed_bytes = freed, remaining_bytes = 0 }
end
function controller:getBookstore()
    return { items = self.comics, stale = false, loaded_pages = 1, has_more = false, can_load_more = false,
        identity = { account_key = "synthetic-review", query_key = "homepage", revision = 1 } }
end
function controller:requestBookstoreCover() end
function controller:getBookstoreCategories() return { items = self.categories or {}, stale = self.category_stale == true } end
function controller:refreshBookstoreCategories(callback) self:enqueue("categories", callback) end
function controller:quotePurchase(_episode, _scope, _payment, callback) self:enqueue("quote", callback) end
function controller:purchase(_quote, _purpose, callback) self:enqueue("purchase", callback) end
function controller:reconcilePurchase(_intent, callback) self:enqueue("reconcile", callback) end
local function finish(method, value, err)
    for index, request in ipairs(controller.waiting) do
        if request.method == method then table.remove(controller.waiting, index); request.callback(value, err); return end
    end
    error("Missing synthetic callback: " .. method)
end
local screens = Screens.new{ controller = controller }
local function press(message)
    for _index, row in ipairs(screens.focus or {}) do
        for _index, button in ipairs(row) do
            if button.text == _(message) and button.callback and button.enabled ~= false then button.callback(); return end
        end
    end
    error("Screen button not found: " .. message)
end
local function pressDialog(message)
    for _index, row in ipairs(assert(screens.dialog).buttons or {}) do
        for _index, button in ipairs(row) do
            local label = type(button.text) == "string" and button.text:gsub("^%[x%] ", ""):gsub("^%[ %] ", "")
            if (button.text == _(message) or label == _(message)) and button.enabled ~= false then button.callback(); return end
        end
    end
    error("Dialog button not found: " .. message)
end
local function capture(name, source, overlay)
    UIManager:forceRePaint()
    local content = assert(screens.widget).content:getSize()
    local frame = { name = name, route = screens.route, source = source, content = { width = content.w, height = content.h },
        content_fits = content.w <= width and content.h <= height }
    local dialog = overlay or screens.dialog
    if dialog and dialog.movable then
        local size = dialog.movable:getSize()
        frame.dialog = { width = size.w, height = size.h }
        frame.dialog_fits = size.w <= width and size.h <= height
    end
    Device.screen.bb:writePNG(output .. "/" .. name .. ".png")
    report.screenshots[#report.screenshots + 1] = name .. ".png"
    report.frames[#report.frames + 1] = frame
end

local ok, failure = xpcall(function()
    screens:showLibrary()
    screens:_bookshelfSort()
    capture("bookshelf-sort", "bilicomics/ui/screens.lua:_bookshelfSort")
    pressDialog("Title")
    screens:_bookshelfFilter()
    pressDialog("Updated")
    capture("bookshelf-updated-filter", "bilicomics/ui/screens.lua:_bookshelf")
    screens:_bookshelfFilter()
    pressDialog("Completed series")
    capture("bookshelf-completed-filter", "bilicomics/ui/screens.lua:_bookshelf")

    screens:showSearch()
    capture("search-empty-history", "bilicomics/ui/screens.lua:_search")
    controller.settings.search_history = { "Moonlit", "Paper Crane", "Lighthouse", "Garden", "Mountain" }
    screens:_render()
    capture("search-recent-history", "bilicomics/ui/screens.lua:_search")
    screens:_editSearch()
    screens.dialog._input_widget:setText("Moonlit")
    capture("search-input-keyboard", "bilicomics/ui/screens.lua:_editSearch")
    pressDialog("Search")
    capture("search-loading", "bilicomics/ui/screens.lua:_search")
    finish("search", controller.comics)
    capture("search-results", "bilicomics/ui/screens.lua:_search")
    screens:_changePage(1)
    capture("search-results-next-page", "bilicomics/ui/screens.lua:_search")
    press(_("All") .. " ▾")
    capture("search-filter-menu", "bilicomics/ui/screens.lua:_searchFilter")
    pressDialog("Ongoing")
    capture("search-ongoing-filter", "bilicomics/ui/screens.lua:_search")
    press(_("Ongoing") .. " ▾"); pressDialog("Completed")
    capture("search-completed-filter", "bilicomics/ui/screens.lua:_search")
    press("Clear search")
    capture("search-return-to-history", "bilicomics/ui/screens.lua:_searchHome")
    local saved_history = controller.settings.search_history
    press("Clear history")
    capture("search-history-cleared", "bilicomics/ui/screens.lua:_search")
    controller.settings.search_history = saved_history
    screens:refresh()
    press("Paper Crane")
    capture("search-history-loading", "bilicomics/ui/screens.lua:_runSearch")
    finish("search", controller.comics)
    capture("search-history-results", "bilicomics/ui/screens.lua:_search")
    press("Change search")
    screens.dialog._input_widget:setText("No matching comic")
    pressDialog("Search"); finish("search", {})
    capture("search-no-results", "bilicomics/ui/screens.lua:_search")
    screens:_lookupComicID()
    screens.dialog._input_widget:setText("mc12345")
    capture("comic-id-keyboard", "bilicomics/ui/screens.lua:_lookupComicID")
    screens:_closeDialog()
    screens:_error({ kind = "invalid_comic_id" })
    capture("comic-id-error", "bilicomics/ui/screens.lua:_error")
    screens:_closeDialog()

    screens.loaded["comic:1"] = true
    screens:showComic("1")
    press("More"); pressDialog("Comic overview")
    capture("comic-overview", "bilicomics/ui/catalog_screens.lua:_catalogDetails")
    screens:_closeDialog()
    press(_("All") .. " ▾")
    capture("chapter-filter-menu", "bilicomics/ui/catalog_screens.lua:_catalogFilter")
    pressDialog("Unread")
    capture("chapters-unread-filter", "bilicomics/ui/catalog_screens.lua:_comic")
    press(_("Unread") .. " ▾"); pressDialog("Downloaded")
    capture("chapters-downloaded-filter", "bilicomics/ui/catalog_screens.lua:_comic")
    press(_("Downloaded") .. " ▾"); pressDialog("All chapters")
    press("Oldest first")
    capture("chapters-newest-first", "bilicomics/ui/catalog_screens.lua:_comic")
    press("Newest first")
    press("Jump…")
    capture("chapter-jump-input", "bilicomics/ui/catalog_screens.lua:_catalogJump")
    screens.dialog._input_widget:setText("missing-synthetic-chapter")
    pressDialog("Find chapter")
    capture("chapter-jump-no-match", "bilicomics/ui/catalog_screens.lua:_catalogJumpResults")
    pressDialog("Edit search")
    screens.dialog._input_widget:setText(assert(controller.episodes[1].title:match("^(.-)%d")))
    pressDialog("Find chapter")
    capture("chapter-jump-results", "bilicomics/ui/catalog_screens.lua:_catalogJumpResults")
    pressDialog("Close")
    press("…")
    capture("chapter-actions", "bilicomics/ui/catalog_screens.lua:_chapterActions")
    pressDialog("Close")
    assert(screens.pagination and screens.pagination.counter.callback, "The synthetic catalog must have multiple pages")()
    capture("chapter-page-picker", "bilicomics/ui/catalog_screens.lua:_catalogJump")
    pressDialog("Cancel")
    press("Select downloads")
    capture("chapters-selection-empty", "bilicomics/ui/catalog_screens.lua:_comic")
    press("Select scope…")
    capture("chapter-selection-menu", "bilicomics/ui/catalog_screens.lua:_catalogSelectionMenu")
    pressDialog("Select all downloadable matches")
    capture("chapters-selection-selected", "bilicomics/ui/catalog_screens.lua:_comic")
    press("Select scope…"); pressDialog("Review selected chapters")
    capture("chapter-selected-summary", "bilicomics/ui/catalog_screens.lua:_catalogSelected")
    pressDialog("Back to chapters")
    local episodes = controller.episodes
    controller.episodes = {}
    screens.selecting, screens.selected = false, {}
    screens:_render()
    capture("chapters-empty", "bilicomics/ui/catalog_screens.lua:_comic")
    controller.episodes = episodes

    screens:showDownloads()
    press(_("All downloads") .. " ▾")
    capture("download-filter-menu", "bilicomics/ui/downloads_screens.lua:_downloadFilter")
    pressDialog("Unfinished downloads")
    capture("downloads-active-filter", "bilicomics/ui/downloads_screens.lua:_downloads")
    press(_("Unfinished downloads") .. " ▾"); pressDialog("Ready offline")
    capture("downloads-ready-offline", "bilicomics/ui/downloads_screens.lua:_downloads")
    screens:_confirmRemoveDownload(controller.jobs[2])
    capture("download-remove-confirmation", "bilicomics/ui/downloads_screens.lua:_confirmRemoveDownload")
    screens:_closeDialog()
    controller.jobs = {}
    screens.filter = "all"
    screens:_render()
    capture("downloads-empty", "bilicomics/ui/downloads_screens.lua:_downloads")

    screens:showAccount()
    press("Other sign-in methods")
    capture("account-other-sign-in-methods", "bilicomics/ui/account_screens.lua:_otherSignInMethods")
    pressDialog("Paste web session")
    screens.dialog._input_widget:setText("synthetic-review-session-placeholder")
    capture("session-masked-input", "bilicomics/ui/account_screens.lua:_importSession")
    screens:_closeDialog()
    press("Storage and cache")
    capture("account-storage-and-cache", "bilicomics/ui/account_screens.lua:_storageSettings")
    pressDialog(string.format(_("Automatic cache limit: %d MiB"), 512))
    capture("account-cache-limit-options", "bilicomics/ui/account_screens.lua:_cacheLimitOptions")
    pressDialog(string.format(_("%d MiB"), 256))
    capture("account-cache-limit-reduction", "bilicomics/ui/account_screens.lua:_cacheLimitOptions")
    screens:_closeDialog()
    press("Storage and cache"); pressDialog("Clear automatic cache")
    capture("cache-clear-confirmation", "bilicomics/ui/account_screens.lua:_account")
    assert(screens.dialog.ok_callback, "Expected the native cache confirmation action")()
    capture("account-cache-cleanup-result", "bilicomics/ui/account_screens.lua:_clearAutomaticCache")
    pressDialog("Close")
    press(string.format(_("Preload next images: %d"), 3))
    capture("account-preload-options", "bilicomics/ui/account_screens.lua:_prefetchOptions")
    pressDialog(string.format(_("%d images"), 5))
    capture("account-preload-saved", "bilicomics/ui/account_screens.lua:_prefetchOptions")
    pressDialog("Close")
    press("Defaults for new chapters")
    capture("account-reader-defaults", "bilicomics/ui/account_screens.lua:_readerDefaults")
    pressDialog("Close")
    screens:_closeDialog()
    screens:_diagnostics()
    capture("diagnostics-loading", "bilicomics/ui/account_screens.lua:_diagnostics")
    finish("diagnostics", { plugin_version = "review-fixture", koreader_version = "v2026.07.1",
        local_session = "missing", credential_storage = "app_private", platform = { os = "Linux", arch = "x64", target = "emulator" },
        capabilities = { request_signing = true, response_decoding = true, image_index = true, image_tokens = false } })
    capture("diagnostics-mixed-capabilities", "bilicomics/ui/account_screens.lua:_diagnostics")
    screens:_closeDialog()
    controller.wallet.stale = true
    screens:_render()
    capture("account-stale-balance", "bilicomics/ui/account_screens.lua:_account")
    press("Other sign-in methods"); pressDialog("Paste web session")
    screens.dialog._input_widget:setText("synthetic-background-session-placeholder")
    pressDialog("Import session")
    capture("session-validating-background-option", "bilicomics/ui/account_screens.lua:_beginSessionImport")
    pressDialog("Continue in background")
    finish("session", { account_key = "synthetic-review" })
    local import_notice = UIManager:getTopmostVisibleWidget()
    if import_notice ~= screens.widget then UIManager:close(import_notice) end
    controller.purchases = { { id = "synthetic-account-pending", comic_id = "1", episode_ids = { "8" },
        purpose = "read", state = "outcome_unknown", quote = { scope = { kind = "single" }, payment = { method = "coin" }, amount = 20 } } }
    screens:refresh()
    capture("account-stale-pending-import-result", "bilicomics/ui/account_screens.lua:_account")
    report.account_combined_bounds = report.frames[#report.frames].content_fits
    press("View session import result")
    capture("account-session-import-result", "bilicomics/ui/account_screens.lua:_sessionImportResult")
    pressDialog("Close")
    controller.purchases = {}
    screens:refresh()
    for _index, kind in ipairs({ "auth", "network", "low_space", "capability", "locked", "unsupported_image_size", "in_use" }) do
        screens:_error({ kind = kind })
        capture("generic-error-" .. kind, "bilicomics/ui/model.lua:Model.error")
        screens:_closeDialog()
    end

    controller.categories, controller.category_stale = {}, true
    screens:showBookstore()
    screens:_bookstoreCategoryPicker()
    capture("bookstore-category-picker-loading", "bilicomics/ui/screens.lua:_renderBookstoreCategoryPicker")
    finish("categories", nil, { kind = "network" })
    capture("bookstore-category-picker-uncached-error", "bilicomics/ui/screens.lua:_renderBookstoreCategoryPicker")
    screens:_closeDialog()
    controller.categories = { { id = "1", name = "Adventure" }, { id = "2", name = "Fantasy" }, { id = "3", name = "Mystery" } }
    screens:_bookstoreCategoryPicker()
    finish("categories", nil, { kind = "network" })
    capture("bookstore-category-picker-cached-error", "bilicomics/ui/screens.lua:_renderBookstoreCategoryPicker")
    screens:_closeDialog()
    controller.categories, controller.category_stale = {}, false
    screens:_bookstoreCategoryPicker()
    capture("bookstore-category-picker-empty", "bilicomics/ui/screens.lua:_renderBookstoreCategoryPicker")
    screens:_closeDialog()

    screens:showComic("1")
    finish("comic", true)
    screens:_purchaseFor(controller.comics[1], controller.episodes[8], "read")
    capture("purchase-quote-loading", "bilicomics/ui/purchase_screens.lua:_purchaseDialog")
    finish("quote", nil, { kind = "network" })
    capture("purchase-quote-error", "bilicomics/ui/purchase_screens.lua:_purchaseDialog")
    local quote = { id = "synthetic-review-quote", comic_id = "1", episode_id = "8", episode_ids = { "8" },
        scope = { kind = "single" }, payment = { method = "coin" }, method = "coin", amount = 20, balance = 80,
        can_afford = true, fingerprint = "synthetic-review-quote", expected_access = { ["8"] = { access = "owned" } } }
    local confirm_label = string.format(_("Confirm purchase · %s %s"), "20", _("coins"))
    pressDialog("Refresh quote")
    finish("quote", quote)
    pressDialog(confirm_label)
    capture("purchase-submitting", "bilicomics/ui/purchase_screens.lua:_purchaseDialog")
    local rejected = { id = "synthetic-rejected-intent", comic_id = "1", episode_ids = { "8" },
        quote = quote, purpose = "read", state = "rejected" }
    finish("purchase", rejected)
    capture("purchase-rejected", "bilicomics/ui/purchase_screens.lua:_purchaseDialog")
    pressDialog("Get new quote")
    finish("quote", quote)
    pressDialog(confirm_label)
    local pending = { id = "synthetic-pending-intent", comic_id = "1", episode_ids = { "8" },
        quote = quote, purpose = "read", state = "outcome_unknown" }
    finish("purchase", pending)
    pressDialog("Refresh result")
    capture("purchase-checking-result", "bilicomics/ui/purchase_screens.lua:_purchaseDialog")
    finish("reconcile", pending)
    screens:_closeDialog()

    -- Call the real entry method while replacing only runtime acquisition and deferred delivery.
    screens:showLibrary()
    local Runtime = require("bilicomics/runtime")
    local BiliComics = dofile(plugin .. "/main.lua")
    local runtime_get = Runtime.get
    Runtime.get = function() error("Synthetic local-data initialization failure") end
    BiliComics._open({}, function() error("An unavailable runtime must not dispatch the entry callback") end)
    Runtime.get = runtime_get
    local notice = assert(UIManager:getTopmostVisibleWidget())
    capture("startup-local-data-error", "main.lua:BiliComics._open", notice)
    UIManager:close(notice)

    local settings = { values = {} }
    function settings:get(key, default) local value = self.values[key]; if value == nil then return default end; return value end
    function settings:set(key, value) self.values[key] = value end
    local deferred, native_next_tick = nil, UIManager.nextTick
    Runtime.get = function() return { settings = settings }, screens end
    UIManager.nextTick = function(_manager, callback) deferred = callback end
    BiliComics._open({ startup_error = { code = "synthetic-unavailable" } }, function() end)
    Runtime.get, UIManager.nextTick = runtime_get, native_next_tick
    assert(deferred, "The startup warning must be scheduled through the real entry method")()
    notice = assert(UIManager:getTopmostVisibleWidget())
    capture("startup-automatic-open-unavailable", "main.lua:BiliComics._open", notice)
    UIManager:close(notice)
end, debug.traceback)
report.passed = ok and report.account_combined_bounds ~= false
report.error = not ok and failure or report.account_combined_bounds == false and "The combined account content exceeds the screen bounds" or nil
local file = assert(io.open(output .. "/review-supplement-result.json", "wb"))
file:write(json.encode(report, { pretty = true })); file:close()
if screens.route then screens:close() end
print(json.encode({ passed = report.passed, screenshots = #report.screenshots, error = report.error }))
if not report.passed then os.exit(1) end
