-- Run only inside the isolated test-env KOReader runtime.
require("setupkoenv")
local source_root, output, mode = assert(arg[1]), assert(arg[2]), arg[3] or "core"
package.path = source_root .. "/?.lua;" .. package.path
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Files = require("bilicomics/storage/files")
local Codec = require("bilicomics/storage/codec")
local sha = require("ffi/sha2")
local Header = require("bilicomics/storage/image_header")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local json = require("rapidjson")
ffi.cdef[[int symlink(const char *target, const char *linkpath);]]
local assertions = {}
local function check(name, condition)
    assertions[#assertions + 1] = { name = name, passed = not not condition }
    assert(condition, name)
end
local function rejected(name, callback)
    local ok = pcall(callback)
    check(name, not ok)
end
local function descriptor(episode_id, count, revision)
    local record = { schema_version = 1, account_key = "account-a", comic_id = "comic-1",
        episode_id = episode_id, revision = revision or "revision-1", pages = {} }
    for i = 1, count do record.pages[i] = { id = "image-" .. i, index = i, width = 40, height = 80 } end
    return record
end
local function open(root, fault_hook, wal)
    local store = Store.open({ root = root, account_key = "account-a", wal = not not wal })
    return store, PageStore.new({ root = root, account_key = "account-a", store = store, fault_hook = fault_hook })
end
local function resultFor(pages, name, fixture)
    local path = pages.temporary_root .. "/" .. name .. ".part"
    Files.write(path, Files.read(output .. "/fixtures/" .. (fixture or "page-a.png")))
    return { temporary_path = path, checksum = Files.digest(path),
        format = (fixture or "page-a.png"):match("%.(%w+)$"), width = 40, height = 80 }
end
local function commit(pages, episode_id, index, name, fixture)
    return pages:commitPage({ account_key = "account-a", episode_id = episode_id, revision = "revision-1", index = index },
        resultFor(pages, name, fixture))
end
local function finish()
    local path = output .. "/" .. mode .. "-result.json"
    Files.write(path, json.encode({ mode = mode, assertions = assertions }, { pretty = true }))
    print(json.encode({ mode = mode, passed = #assertions, result_path = path }))
end
local function startWriter(path)
    local ready, resume = ffi.new("int[2]"), ffi.new("int[2]")
    assert(ffi.C.pipe(ready) == 0 and ffi.C.pipe(resume) == 0)
    local pid = tonumber(ffi.C.fork())
    assert(pid >= 0, "Cannot fork the isolated writer")
    if pid == 0 then
        ffi.C.close(ready[0]); ffi.C.close(resume[1])
        local ok = pcall(function()
            local file = assert(io.open(path, "wb"))
            assert(file:write("first chunk\n")); assert(file:flush())
            assert(ffi.C.write(ready[1], "R", 1) == 1)
            ffi.C.close(ready[1])
            local signal = ffi.new("char[1]")
            assert(ffi.C.read(resume[0], signal, 1) == 1)
            ffi.C.close(resume[0])
            assert(file:write("second chunk\n")); assert(file:close())
        end)
        ffi.C._exit(ok and 0 or 91)
    end
    ffi.C.close(ready[1]); ffi.C.close(resume[0])
    local signal = ffi.new("char[1]")
    assert(ffi.C.read(ready[0], signal, 1) == 1, "Writer did not create its temporary file")
    ffi.C.close(ready[0])
    return function()
        assert(ffi.C.write(resume[1], "R", 1) == 1)
        ffi.C.close(resume[1])
        local status = ffi.new("int[1]")
        assert(ffi.C.waitpid(pid, status, 0) == pid)
        return tonumber(status[0])
    end
end

if mode == "core" then
    local root = output .. "/core-account"
    local store, pages = open(root)
    check("SQLite schema migration is durable", tonumber(store.connection:rowexec("PRAGMA user_version")) == 1)
    check("Non-WAL device configuration uses TRUNCATE", store.connection:rowexec("PRAGMA journal_mode") == "truncate")
    store:upsertComic({ id = 1, title = "Reader's comic; DROP TABLE comics;", favorite = true })
    check("Identifiers normalize and SQL punctuation is safely bound", store:getComic("1").title == "Reader's comic; DROP TABLE comics;")
    store:upsertComic({ id = "comic-1", title = "Native comic", favorite = true })
    store:upsertEpisodes("comic-1", {
        { id = "episode-2", order = 2, title = "Second", access = "owned" },
        { id = "episode-1", order = 1, title = "First", access = "free" },
        { id = "special", order = 1.5, title = "Special", access = "temporary", expires_at = 2000000000 },
    })
    check("Fractional special episode ordering is preserved", store:listEpisodes("comic-1")[2].id == "special")
    check("Temporary access expiry survives storage", store:getEpisode("special").expires_at == 2000000000)
    store:putSetting("disabled", false)
    check("False settings do not fall back to defaults", store:getSetting("disabled", true) == false)
    check("Absent setting returns its default", store:getSetting("absent", 42) == 42)
    rejected("Failed transaction rolls back all records", function()
        store:transaction(function()
            store:putSetting("rolled_back", true)
            store:upsertComic({ id = "rollback", title = "Rollback" })
            error("Intentional transaction failure")
        end)
    end)
    check("Rollback removes its writes", store:getSetting("rolled_back") == nil and store:getComic("rollback") == nil)
    store:transaction(function()
        store:putSetting("outer", "retained")
        rejected("Nested failure is isolated by a savepoint", function()
            store:transaction(function() store:putSetting("inner", "discarded"); error("Inner failure") end)
        end)
        store:putSetting("outer_after", "retained")
    end)
    check("Outer transaction survives a caught nested failure", store:getSetting("inner") == nil and store:getSetting("outer_after") == "retained")
    local value, absent, last = store:transaction(function() return 3, nil, "last" end)
    check("Transaction preserves multiple and nil return values", value == 3 and absent == nil and last == "last")
    store:putJob({ id = "job-a", kind = "download", state = "paused", priority = 10, payload = { episode_ids = { "episode-1" } } })
    store:putPurchase({ id = "intent-a", state = "outcome_unknown", episode_ids = { "episode-2" },
        quote = { fingerprint = "quote-a", amount = 10 }, unresolved_episode_ids = { "episode-2" }, receipt_status = "unavailable" })
    check("Durable jobs can be filtered by state", #store:listJobs({ "paused" }) == 1 and #store:listJobs({ "queued" }) == 0)
    check("Purchase uncertainty and additional evidence fields persist", store:getPurchase("intent-a").receipt_status == "unavailable")
    rejected("Credentials cannot enter the ordinary database", function() store:putSetting("unsafe", { cookies = "secret" }) end)
    store:putAnchor("episode-1", "revision-1", { page = 1, y = 0.45, updated_at = 200, finished = false })
    check("Precise local anchor and continue library are linked", store:getAnchor("episode-1", "revision-1").y == 0.45
        and store:listComics("continue")[1].last_episode_id == "episode-1")
    rejected("A database cannot be opened under another account identity", function()
        Store.open({ root = root, account_key = "account-b", wal = false })
    end)
    local first = descriptor("episode-1", 2)
    local descriptor_path = pages:ensureDescriptor(first)
    local original_bytes, original_modified = Files.read(descriptor_path), lfs.attributes(descriptor_path, "modification")
    first.title, first.cookies = "Not persisted", "Not persisted"
    pages:ensureDescriptor(first)
    check("Descriptor drops mutable and private input fields", not Files.read(descriptor_path):find("Not persisted", 1, true))
    check("Same descriptor is never rewritten", Files.read(descriptor_path) == original_bytes
        and lfs.attributes(descriptor_path, "modification") == original_modified)
    local changed = descriptor("episode-1", 2)
    changed.pages[1].height = 81
    rejected("A revision cannot mutate its descriptor geometry", function() pages:ensureDescriptor(changed) end)
    rejected("Descriptors reject a foreign account", function()
        local foreign = descriptor("foreign", 1); foreign.account_key = "account-b"; pages:ensureDescriptor(foreign)
    end)
    rejected("Descriptors reject traversal identities", function()
        pages:ensureDescriptor(descriptor("../outside", 1))
    end)
    local link = pages.documents_root .. "/symlink-comic"
    check("Symlink fixture is created only inside the isolated output", ffi.C.symlink(output, link) == 0)
    rejected("New descriptor writes reject symlinked parent directories", function()
        local linked = descriptor("linked", 1); linked.comic_id = "symlink-comic"; pages:ensureDescriptor(linked)
    end)
    check("Rejected descriptor writes do not escape their namespace", not lfs.attributes(output .. "/linked"))
    assert(os.remove(link))
    check("New chapters are incomplete with explicit missing pages", not pages:isComplete("episode-1", "revision-1")
        and #store:listPages("episode-1", "revision-1") == 2)
    local page1 = commit(pages, "episode-1", 1, "first")
    check("Verified file is atomically committed before ready state", page1.state == "ready" and Files.exists(page1.path)
        and not Files.exists(pages.temporary_root .. "/first.part") and #store:listCommits() == 0)
    check("Initial content generation is persistent", page1.content_generation == 1 and page1.geometry_generation == 0)
    check("One available image does not imply a complete chapter", not pages:isComplete("episode-1", "revision-1"))
    local bad = resultFor(pages, "checksum-mismatch")
    bad.checksum = string.rep("0", 64)
    rejected("Acquisition checksum mismatch cannot commit", function()
        pages:commitPage({ episode_id = "episode-1", revision = "revision-1", index = 2 }, bad)
    end)
    local truncated = resultFor(pages, "truncated")
    local bytes = Files.read(truncated.temporary_path)
    Files.write(truncated.temporary_path, bytes:sub(1, -13))
    truncated.checksum = Files.digest(truncated.temporary_path)
    rejected("A matching digest does not make a truncated image usable", function()
        pages:commitPage({ episode_id = "episode-1", revision = "revision-1", index = 2 }, truncated)
    end)
    local outside = resultFor(pages, "outside")
    outside.temporary_path = output .. "/fixtures/page-a.png"
    rejected("Workers cannot commit paths outside their account temporary directory", function()
        pages:commitPage({ episode_id = "episode-1", revision = "revision-1", index = 2 }, outside)
    end)
    local stale = resultFor(pages, "stale")
    rejected("Stale account callbacks cannot commit", function()
        pages:commitPage({ account_key = "account-b", episode_id = "episode-1", revision = "revision-1", index = 2 }, stale)
    end)
    commit(pages, "episode-1", 2, "second")
    check("All usable images make the existing descriptor complete", pages:isComplete("episode-1", "revision-1"))
    local revised = commit(pages, "episode-1", 1, "replacement", "page-b.png")
    check("Same-second image replacement increments its generation", revised.content_generation == 2 and revised.path ~= page1.path)
    check("Replaced content path is released after commit", not Files.exists(page1.path) and Files.exists(revised.path))
    check("Image commits do not rewrite the descriptor", Files.read(descriptor_path) == original_bytes)
    Files.write(descriptor_path, original_bytes .. "invalid")
    check("A corrupted descriptor cannot retain a complete badge", not pages:isComplete("episode-1", "revision-1"))
    Files.write(descriptor_path, original_bytes)
    local corrected_descriptor = descriptor("corrected", 1)
    corrected_descriptor.pages[1].width = 80
    local corrected_path = pages:ensureDescriptor(corrected_descriptor)
    local corrected_before = Files.read(corrected_path)
    local corrected = commit(pages, "corrected", 1, "corrected")
    check("Derived geometry corrections increment a separate generation", corrected.width == 40 and corrected.geometry_generation == 1)
    check("Geometry corrections preserve native descriptor identity", Files.read(corrected_path) == corrected_before)
    pages:removeEpisode("corrected", "revision-1")
    pages:ensureDescriptor(descriptor("oriented", 1))
    local oriented_result = resultFor(pages, "oriented", "page-exif-6.jpg")
    oriented_result.width, oriented_result.height = 80, 40
    oriented_result.geometry = { source_width = 40, source_height = 80, exif_orientation = 6, native_orientation = 1 }
    local oriented = pages:commitPage({ episode_id = "oriented", revision = "revision-1", index = 1 }, oriented_result)
    check("Oriented logical geometry retains source and native mapping fields", oriented.width == 80
        and oriented.geometry.source_width == 40 and oriented.geometry.native_orientation == 1)
    local false_source = resultFor(pages, "false-source", "page-exif-6.jpg")
    false_source.width, false_source.height = 80, 40
    false_source.geometry = { source_width = 99, source_height = 80, exif_orientation = 6 }
    rejected("Source mapping metadata must match actual file dimensions", function()
        pages:commitPage({ episode_id = "oriented", revision = "revision-1", index = 1 }, false_source)
    end)
    pages:removeEpisode("oriented", "revision-1")
    for _, fixture in ipairs({ "page.jpg", "page-lossy.webp", "page-lossless.webp", "page-extended.webp",
        "page-exif.png", "page-exif.webp" }) do
        local header = Header.read(output .. "/fixtures/" .. fixture)
        local expected_orientation = fixture:find("exif", 1, true) and 6 or 1
        check("Real image header has correct dimensions and orientation: " .. fixture,
            header.width == 40 and header.height == 80 and header.exif_orientation == expected_orientation)
        local episode_id = "format-" .. fixture
        pages:ensureDescriptor(descriptor(episode_id, 1))
        local result = resultFor(pages, "format-" .. fixture, fixture)
        result.geometry = { source_width = 40, source_height = 80, exif_orientation = expected_orientation }
        if expected_orientation >= 5 then result.width, result.height = 80, 40 end
        pages:commitPage({ episode_id = episode_id, revision = "revision-1", index = 1 }, result)
        check("Verified image format can be stored and reopened: " .. fixture, pages:isComplete(episode_id, "revision-1"))
        pages:removeEpisode(episode_id, "revision-1")
    end
    for orientation = 1, 8 do
        check("JPEG EXIF is independently read for orientation " .. orientation,
            Header.read(output .. "/fixtures/page-exif-" .. orientation .. ".jpg").exif_orientation == orientation)
    end
    pages:ensureDescriptor(descriptor("orientation-mismatch", 1))
    rejected("Worker metadata cannot hide an actual JPEG EXIF transform", function()
        commit(pages, "orientation-mismatch", 1, "orientation-mismatch", "page-exif-6.jpg")
    end)
    pages:ensureDescriptor(descriptor("inflight-removal", 1))
    local inflight = resultFor(pages, "inflight-removal")
    pages:removeEpisode("inflight-removal", "revision-1")
    rejected("Removing an incomplete download invalidates its pending worker generation", function()
        pages:commitPage({ episode_id = "inflight-removal", revision = "revision-1", index = 1,
            expected_content_generation = 0 }, inflight)
    end)
    local pending_store = PageStore.new({ root = root, store = store, account_key = "account-a", fault_hook = function(stage)
        if stage == "after_journal" then error("Injected interruption for explicit removal") end
    end })
    pending_store:ensureDescriptor(descriptor("pending-removal", 1))
    rejected("Injected interrupted commit leaves a durable journal", function()
        commit(pending_store, "pending-removal", 1, "pending-removal")
    end)
    check("Pending removal test reaches the journal boundary", #store:listCommits() == 1)
    pages:removeEpisode("pending-removal", "revision-1")
    check("Removing a download cancels its interrupted commit", #store:listCommits() == 0
        and store:getPage("pending-removal/revision-1/1").content_generation == 1
        and not Files.exists(pages.temporary_root .. "/pending-removal.part"))
    pages:ensureDescriptor(descriptor("episode-1", 1, "revision-2"))
    check("Content revisions have independent page state", not pages:isComplete("episode-1", "revision-2")
        and pages:isComplete("episode-1", "revision-1"))
    pages:pinEpisode("episode-1", "revision-1", true)
    pages:ensureDescriptor(descriptor("active", 1)); commit(pages, "active", 1, "active")
    pages:ensureDescriptor(descriptor("automatic", 1)); commit(pages, "automatic", 1, "automatic")
    pages:setActiveEpisode("active", "revision-1", true)
    local eviction = pages:clearAutomaticCache()
    check("Automatic eviction preserves pinned and active chapters", eviction.removed_pages == 1
        and pages:isComplete("episode-1", "revision-1") and pages:isComplete("active", "revision-1")
        and not pages:isComplete("automatic", "revision-1"))
    rejected("Explicit removal cannot invalidate an active reader", function() pages:removeEpisode("active", "revision-1") end)
    pages:setActiveEpisode("active", "revision-1", false)
    check("Released readers become evictable", pages:clearAutomaticCache().removed_pages == 1)
    local summary = pages:getSummary()
    check("Storage summary distinguishes manual retention and automatic data", summary.complete_episodes == 1
        and summary.pinned_bytes > 0 and summary.automatic_bytes == 0 and summary.ready_pages == 2)
    store:close()
    store, pages = open(root)
    check("Content generations survive closing the SQLite connection", store:getPage("episode-1/revision-1/1").content_generation == 2)
    check("Offline completeness survives restart without remote services", pages:isComplete("episode-1", "revision-1"))
    check("Purchases and pins survive process state replacement", store:getPurchase("intent-a").state == "outcome_unknown"
        and store:isPinned("episode-1", "revision-1"))
    local ready = store:getPage("episode-1/revision-1/1")
    local corrupt = Files.read(ready.path)
    local old_time = lfs.attributes(ready.path, "modification")
    Files.write(ready.path, corrupt:sub(1, 30) .. "X" .. corrupt:sub(32))
    assert(lfs.touch(ready.path, old_time, old_time))
    check("Completeness detects equal-size corruption with unchanged timestamps", not pages:isComplete("episode-1", "revision-1"))
    Files.write(pages.pages_root .. "/orphan.png", Files.read(output .. "/fixtures/page-a.png"))
    Files.write(pages.temporary_root .. "/abandoned.part", "unfinished")
    local recovery = pages:reconcile()
    check("Corruption invalidates a previously complete pinned chapter", recovery.invalidated == 0
        and not pages:isComplete("episode-1", "revision-1"))
    check("Startup removes only unreferenced committed and abandoned temporary files", recovery.removed_orphan >= 2
        and recovery.removed_temporary >= 1 and #store:listCommits() == 0)
    check("Corruption invalidation advances the persistent content generation", store:getPage("episode-1/revision-1/1").content_generation == 3)
    local removed = pages:removeEpisode("episode-1", "revision-1")
    check("Removing downloads keeps native identity and precise progress", removed.removed_pages == 1
        and Files.exists(descriptor_path) and store:getAnchor("episode-1", "revision-1").y == 0.45)
    store:close()
    local wal_store = Store.open({ root = output .. "/wal-account", account_key = "account-a", wal = true })
    check("Supported device configuration uses WAL", wal_store.connection:rowexec("PRAGMA journal_mode") == "wal")
    wal_store:close()
    local future_path = output .. "/future-account"
    local future_store = Store.open({ root = future_path, account_key = "account-a", wal = false })
    future_store.connection:exec("PRAGMA user_version=99")
    future_store:close()
    rejected("Newer database schemas cannot be silently downgraded", function()
        Store.open({ root = future_path, account_key = "account-a", wal = false })
    end)
    local full_root = output .. "/full-account"
    local full_store = Store.open({ root = full_root, account_key = "account-a", wal = false })
    full_store:putSetting("retained", "original")
    local page_count = tonumber(full_store.connection:rowexec("PRAGMA page_count"))
    full_store.connection:exec("PRAGMA max_page_count=" .. page_count)
    rejected("Real SQLite capacity exhaustion rejects the oversized transaction", function()
        full_store:transaction(function()
            full_store:putSetting("retained", "uncommitted")
            full_store:putSetting("too_large", string.rep("x", 1024 * 1024))
        end)
    end)
    if full_store.connection then full_store:close() end
    full_store = Store.open({ root = full_root, account_key = "account-a", wal = false })
    check("SQLite FULL preserves previously committed state after reopening", full_store:getSetting("retained") == "original"
        and full_store:getSetting("too_large") == nil)
    full_store:close()
    finish()
elseif mode == "integration-safety" then
    local root = output .. "/integration-account"
    local store, pages = open(root)
    pages:ensureDescriptor(descriptor("activation", 1))
    pages.clock = function() return 301 end
    store.connection:exec("PRAGMA query_only=ON")
    local ok, err = pcall(pages.setActiveEpisode, pages, "activation", "revision-1", true)
    check("Actual SQLite read-only failure rejects reader activation", not ok and tostring(err):find("readonly", 1, true) ~= nil)
    check("Failed initial activation cannot leak an active reference", pages.active["activation/revision-1"] == nil)
    check("Failed activation rolls back its access timestamp", store:getPage("activation/revision-1/1").last_access_at == nil)
    store.connection:exec("PRAGMA query_only=OFF")
    pages:setActiveEpisode("activation", "revision-1", true)
    check("Successful activation publishes one reference after writing", pages.active["activation/revision-1"] == 1
        and store:getPage("activation/revision-1/1").last_access_at == 301)
    pages.clock = function() return 302 end
    store.connection:exec("PRAGMA query_only=ON")
    ok, err = pcall(pages.setActiveEpisode, pages, "activation", "revision-1", true)
    check("Failure preserves an existing reference and committed timestamp", not ok
        and pages.active["activation/revision-1"] == 1 and store:getPage("activation/revision-1/1").last_access_at == 301)
    pages:setActiveEpisode("activation", "revision-1", false)
    check("Reader release succeeds while SQLite is read only", pages.active["activation/revision-1"] == 0)
    store.connection:exec("PRAGMA query_only=OFF")
    store:transaction(function()
        rejected("Activation cannot publish a reference from an uncommitted outer transaction", function()
            pages:setActiveEpisode("activation", "revision-1", true)
        end)
    end)
    check("Rejected nested activation does not alter reference counts", pages.active["activation/revision-1"] == 0)
    local pending_pages = PageStore.new({ root = root, store = store, account_key = "account-a", fault_hook = function(stage)
        if stage == "after_journal" then error("Injected interruption before final rename") end
    end })
    pending_pages:ensureDescriptor(descriptor("resume", 1))
    rejected("Recovery test reaches a durable pending commit", function() commit(pending_pages, "resume", 1, "resume") end)
    local unrelated_descriptor = pages:ensureDescriptor(descriptor("unrelated", 1))
    local unrelated_page = commit(pages, "unrelated", 1, "unrelated")
    assert(os.remove(unrelated_descriptor)); assert(os.remove(unrelated_page.path))
    local orphan_path = pages.pages_root .. "/unrelated-orphan.bin"
    Files.write(orphan_path, "unrelated orphan")
    local live_path = pages.temporary_root .. "/other-worker.part"
    local finish_writer = startWriter(live_path)
    local recovered = pages:recoverPendingCommits()
    check("Journal-only recovery commits a verified pending page", recovered.recovered == 1 and recovered.remaining == 0
        and recovered.discarded == 0 and #recovered.errors == 0 and pages:isComplete("resume", "revision-1"))
    check("Recovery returns committed page records for reader notifications", #recovered.recovered_pages == 1
        and recovered.recovered_pages[1].key == "resume/revision-1/1" and recovered.recovered_pages[1].content_generation == 1)
    check("Recovery does not unlink a live unrelated worker temporary file", Files.exists(live_path))
    check("Unrelated worker finishes and is reaped after recovery", finish_writer() == 0)
    check("Concurrent worker data remains reachable at its assigned path", Files.read(live_path) == "first chunk\nsecond chunk\n")
    check("Journal-only recovery does not sweep orphan files", Files.read(orphan_path) == "unrelated orphan")
    check("Journal-only recovery does not rewrite descriptors or unrelated page state", not Files.exists(unrelated_descriptor)
        and store:getPage("unrelated/revision-1/1").state == "ready")
    local again = pages:recoverPendingCommits()
    check("Repeated journal-only recovery is idempotent", again.recovered == 0 and again.remaining == 0 and #again.errors == 0)
    store:transaction(function()
        rejected("Journal recovery cannot delete files before an outer transaction commits", function() pages:recoverPendingCommits() end)
    end)
    pages:ensureDescriptor(descriptor("replacement-recovery", 1))
    local replaced = commit(pages, "replacement-recovery", 1, "replacement-original")
    local interrupted = PageStore.new({ root = root, store = store, account_key = "account-a", fault_hook = function(stage)
        if stage == "after_rename" then error("Injected replacement commit interruption") end
    end })
    rejected("A replacement can be interrupted after final rename", function()
        commit(interrupted, "replacement-recovery", 1, "replacement-new", "page-b.png")
    end)
    assert(os.remove(replaced.path))
    local put_page = store.putPage
    store.putPage = function(_, page)
        if page.state == "ready" then error("Injected replacement recovery write failure") end
        return put_page(store, page)
    end
    local attempted = pages:reconcile()
    store.putPage = put_page
    local replacement_journal = assert(store:listCommits()[1])
    check("Invalidating a missing old file preserves the verified replacement journal", #attempted.errors >= 1
        and replacement_journal.base_generation == 2 and replacement_journal.page.content_generation == 3
        and store:getPage("replacement-recovery/revision-1/1").state == "missing")
    local replacement = pages:recoverPendingCommits()
    check("A retained replacement recovers with a newer render generation", replacement.recovered == 1
        and #replacement.recovered_pages == 1 and replacement.recovered_pages[1].content_generation == 3
        and pages:isComplete("replacement-recovery", "revision-1") and #store:listCommits() == 0)
    store:close()
    finish()
elseif mode == "crash-retry-commit" then
    local store, pages = open(output .. "/retry-commit", function(stage)
        if stage == "after_journal" then ffi.C._exit(73) end
    end)
    pages:ensureDescriptor(descriptor("retry-episode", 1))
    commit(pages, "retry-episode", 1, "retry-image")
    error("Crash hook was not reached")
elseif mode == "recover-retry-commit" then
    local store, pages = open(output .. "/retry-commit")
    local journal = assert(store:listCommits()[1])
    local rename = os.rename
    os.rename = function() return nil, "Injected transient rename failure" end
    local first = pages:recoverPendingCommits()
    os.rename = rename
    check("Transient rename failure retains the recovery journal and verified temporary file", #first.errors == 1
        and #first.recovered_pages == 0 and #store:listCommits() == 1 and Files.exists(journal.temporary_path))
    local sync_directory = Files.syncDirectory
    Files.syncDirectory = function() error("Injected transient directory sync failure") end
    local sync_failure = pages:recoverPendingCommits()
    Files.syncDirectory = sync_directory
    check("Directory sync failure retains the only verified renamed image", #sync_failure.errors == 1
        and #store:listCommits() == 1 and Files.exists(journal.page.path))
    local put_page = store.putPage
    store.putPage = function(_, page)
        if page.state == "ready" then error("Injected transient SQLite write failure") end
        return put_page(store, page)
    end
    local second = pages:recoverPendingCommits()
    store.putPage = put_page
    check("Transient database failure retains the renamed file and journal", #second.errors == 1
        and #second.recovered_pages == 0 and #store:listCommits() == 1 and Files.exists(journal.page.path)
        and store:getPage("retry-episode/revision-1/1").state == "missing")
    check("A later successful recovery adopts the retained file exactly once", pages:recoverPendingCommits().recovered == 1
        and pages:isComplete("retry-episode", "revision-1") and #store:listCommits() == 0)
    store:close()
    finish()
elseif mode == "crash-invalid-commit" then
    local store, pages = open(output .. "/invalid-commit", function(stage)
        if stage == "after_journal" then ffi.C._exit(73) end
    end)
    pages:ensureDescriptor(descriptor("invalid-episode", 1))
    commit(pages, "invalid-episode", 1, "invalid-image")
    error("Crash hook was not reached")
elseif mode == "recover-invalid-commit" then
    local store, pages = open(output .. "/invalid-commit")
    local journal = assert(store:listCommits()[1])
    Files.write(journal.temporary_path, "corrupted interrupted download")
    local recovered = pages:reconcile()
    check("Recovery does not adopt a corrupted interrupted file", recovered.recovered == 0
        and #recovered.errors == 1 and not pages:isComplete("invalid-episode", "revision-1"))
    check("Invalid interrupted commits leave retryable missing pages", #store:listCommits() == 0
        and store:getPage("invalid-episode/revision-1/1").state == "missing")
    check("Invalid interrupted temporary content is discarded", not Files.exists(journal.temporary_path))
    store:close()
    finish()
elseif mode:match("^crash%-(.+)$") then
    local point = assert(mode:match("^crash%-(.+)$"))
    local store, pages = open(output .. "/" .. point, function(stage)
        if stage == point then ffi.C._exit(73) end
    end)
    pages:ensureDescriptor(descriptor("crash-episode", 1))
    commit(pages, "crash-episode", 1, "crash-image")
    error("Crash hook was not reached")
elseif mode:match("^recover%-(.+)$") then
    local point = assert(mode:match("^recover%-(.+)$"))
    local store, pages = open(output .. "/" .. point)
    local before = store:getPage("crash-episode/revision-1/1")
    if point ~= "after_database" then
        check("Interrupted file commit is not prematurely marked ready", before.state == "missing" and #store:listCommits() == 1)
        local journal = store:listCommits()[1]
        check("Journal records the actual crash window", point == "after_journal"
            and Files.exists(journal.temporary_path) and not Files.exists(journal.page.path)
            or point == "after_rename" and not Files.exists(journal.temporary_path) and Files.exists(journal.page.path))
    end
    local recovered = pages:reconcile()
    check("Restart verifies and completes interrupted atomic commits", pages:isComplete("crash-episode", "revision-1"))
    check("Recovery is exactly once and preserves page generation", #store:listCommits() == 0
        and store:getPage("crash-episode/revision-1/1").content_generation == 1)
    check("Recovery reports only work that was unfinished", recovered.recovered == (point == "after_database" and 0 or 1))
    check("Repeated recovery is harmless", pages:reconcile().recovered == 0)
    store:close()
    finish()
else
    error("Unknown storage test mode")
end
