-- Focused synthetic storage verification; run only on test-env with networking disabled.
require("setupkoenv")
local source, work, fixture, result_path = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path
G_reader_settings = require("luasettings"):open(work .. "/reader-settings.lua")
G_reader_settings:saveSetting("document_metadata_folder", "doc")
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Replacement = require("bilicomics/storage/version_replacement")
local Files = require("bilicomics/storage/files")
local Codec = require("bilicomics/storage/codec")
local DocSettings = require("docsettings")
local Catalog = require("bilicomics/catalog/init")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local report = { cases = {}, assertions = {}, passed = false }
local sequence, case_name, contexts = 0, "setup", {}
local fixture_bytes, fixture_checksum = Files.read(fixture, 65536), Files.digest(fixture)
local function check(name, condition)
    local label = case_name .. ": " .. name
    report.assertions[#report.assertions + 1] = { name = label, passed = not not condition }
    assert(condition, label)
end
local function same(a, b) return Codec.canonical(a) == Codec.canonical(b) end
local function withoutHash(fn)
    local digest, calls = Files.digest, 0
    Files.digest = function() calls = calls + 1; error("Image hashing is forbidden in version publication") end
    local ok, value, err = pcall(fn)
    Files.digest = digest
    check("capture/publication does not hash images", calls == 0)
    if not ok then error(value, 0) end
    return value, err
end
local function page(context, index) return assert(context.store:getPage("101/R1/" .. index)) end
local function oldFiles(context)
    local records = {}
    for _, path in ipairs(context.file_paths) do
        local stat = assert(lfs.attributes(path))
        records[path] = { checksum = Files.digest(path), size = stat.size, ino = stat.ino, dev = stat.dev,
            modification = stat.modification, change = stat.change }
    end
    return records
end
local function database(context)
    return { pages = context.store:listAllPages(), descriptors = context.store:listDescriptors(), jobs = context.store:listJobs(),
        episode = context.store:getEpisode("101"), comic = context.store:getComic("81"),
        anchor = context.store:getAnchor("101", "R1"), pinned = context.store:isPinned("101", "R1"),
        pins = context.store:_rows("SELECT * FROM pins ORDER BY episode_id,revision"),
        counter = context.store:getSetting("version_replacement_sequence", 0), commits = context.store:listCommits() }
end
local function snapshot(context) return { database = database(context), files = oldFiles(context) } end
local function unchanged(context, before)
    check("all existing database state and files remain unchanged", same(snapshot(context), before))
end
local function seed(options)
    options = options or {}
    sequence = sequence + 1
    local context = { root = work .. "/case-" .. sequence, key = "synthetic-version", job_id = "old-download" }
    context.store = Store.open{ root = context.root, account_key = context.key, wal = false }
    context.pages = PageStore.new{ root = context.root, account_key = context.key, store = context.store }
    contexts[#contexts + 1] = context
    context.store:upsertComic{ id = "81", title = "Synthetic comic", reading_position = { index = 3, y = 0.35 } }
    context.store:upsertEpisodes("81", { { id = "101", title = "Synthetic retained chapter", order = 1, access = "free",
        extra = { current_revision = "R1", local_revision = "R1", local_finished_at = 1700000000, retained = "unchanged" } } })
    context.descriptor = { schema_version = 1, account_key = context.key, comic_id = "81", episode_id = "101", revision = "R1", pages = {} }
    for i = 1, 3 do context.descriptor.pages[i] = { id = "original-" .. i, index = i, width = 40, height = 80 } end
    context.path = context.pages:ensureDescriptor(context.descriptor)
    for i = 1, 3 do
        local record = page(context, i)
        record.extra.source_path = "/synthetic/old-" .. i
        context.store:putPage(record)
    end
    for i = 1, 2 do
        local temporary = context.pages.temporary_root .. "/seed-" .. i .. ".part"
        Files.write(temporary, fixture_bytes)
        local record = page(context, i)
        context.pages:commitPage({ account_key = context.key, episode_id = "101", revision = "R1", index = i,
            id = record.id, expected_content_generation = record.content_generation },
            { temporary_path = temporary, checksum = fixture_checksum, format = "png", width = 40, height = 80,
                geometry = { source_width = 40, source_height = 80, exif_orientation = 1 } })
    end
    context.pages:_evict(page(context, 2))
    context.pages:pinEpisode("101", "R1", options.pinned ~= false)
    context.store:putAnchor("101", "R1", { schema_version = 1, page_id = "original-3", index = 3, x = 0, y = 0.35,
        finished = true, source = { x = 0, y = 0.35 } })
    local native = DocSettings:open(context.path)
    native:saveSetting("page_positions", { [3] = 0.35 }); native:saveSetting("last_page", 3)
    native:saveSetting("initialized", true); native:flush()
    context.store:putJob{ id = context.job_id, kind = "episode_download", state = "paused", comic_id = "81",
        episode_id = "101", revision = "R1", run_generation = 4, completed = 1, total = 3,
        payload = { retained = "unchanged", version_replacement = { id = "synthetic-operation", stage = "index" } } }
    if options.siblings then
        for index, state in ipairs({ "paused", "canceled", "complete" }) do
            context.store:putJob{ id = "sibling-" .. index, kind = "episode_download", state = state, comic_id = "81",
                episode_id = "101", revision = "R1", run_generation = index, payload = { retained = true } }
        end
        context.store:putJob{ id = "removed-sibling", kind = "episode_download", state = "canceled", comic_id = "81",
            episode_id = "101", revision = "R1", run_generation = 7, payload = { removed = true } }
    end
    context.file_paths = {}
    Files.walk(context.pages.documents_root, function(path) context.file_paths[#context.file_paths + 1] = path end)
    Files.walk(context.pages.pages_root, function(path) context.file_paths[#context.file_paths + 1] = path end)
    table.sort(context.file_paths)
    return context
end
local function candidate(count)
    local result = { episode_id = "101", comic_id = "81", revision = "R1", images = {} }
    for i = 1, count or 2 do
        result.images[i] = { id = "transient-" .. i, index = i, width = 60, height = 120, path = "/synthetic/new-" .. i }
    end
    return result
end
local function capture(context)
    local before = snapshot(context)
    local value, err = withoutHash(function() return Replacement.capture(context.pages, context.job_id) end)
    check("capture succeeds", value ~= nil and err == nil)
    unchanged(context, before)
    return value
end
local function rejected(context, basis, index, expected)
    local before = snapshot(context)
    local value, err = withoutHash(function() return Replacement.publish(context.pages, basis, index) end)
    check("publication rejects with a structured error", value == nil and type(err) == "table" and type(err.code) == "string")
    if expected then check("rejection has the expected kind", err.kind == expected) end
    unchanged(context, before)
    check("the transaction is no longer active", context.store._depth == 0)
    return err
end
local function publish(context, basis, index)
    local before = snapshot(context)
    local result, err = withoutHash(function() return Replacement.publish(context.pages, basis, index) end)
    check("publication returns the committed independent snapshot", result and not err and result.job.state == "paused"
        and result.job.payload.replaces_job_id == context.job_id and result.replaced_job_id == context.job_id)
    local revision = result.descriptor.revision
    check("local revision and descriptor path are new", revision ~= "R1" and revision ~= index.revision
        and result.path ~= context.path and #context.store:listDescriptors() == #before.database.descriptors + 1)
    check("old descriptor, pages and ready/native files remain untouched", same(oldFiles(context), before.files)
        and same(context.store:getDescriptor("101", "R1"), context.descriptor)
        and same(context.store:listPages("101", "R1"), before.database.pages))
    check("old stored and native anchors remain while the new snapshot has none",
        same(context.store:getAnchor("101", "R1"), before.database.anchor) and context.store:getAnchor("101", revision) == nil
        and DocSettings:open(context.path):readSetting("last_page") == 3
        and DocSettings:open(result.path):readSetting("initialized") == nil
        and DocSettings:open(result.path):readSetting("page_positions") == nil)
    check("the retained old version and the new version are both pinned", context.store:isPinned("101", "R1")
        and context.store:isPinned("101", revision))
    for i, image in ipairs(index.images) do
        local record = assert(context.store:getPage("101/" .. revision .. "/" .. i))
        check("new page has independent missing content and never history " .. i, record.state == "missing"
            and record.path == nil and record.checksum == nil and record.content_generation == 0 and record.geometry_generation == 0
            and record.extra.content_history_version == 1 and record.extra.last_committed_checksum == nil
            and record.extra.expected_source_checksum == nil and record.extra.source_generation == 0
            and record.extra.source_path == image.path and record.id ~= image.id and record.id ~= "original-" .. i)
    end
    for _, previous in ipairs(before.database.jobs) do
        if previous.revision == "R1" and not (previous.payload or {}).removed then
            local retired = context.store:getJob(previous.id)
            check("retained old job is retired atomically " .. previous.id, retired.state == "canceled"
                and retired.payload.replaced_by == result.job.id and retired.payload.version_replacement == nil
                and retired.run_generation == (previous.run_generation or 0) + 1
                and retired.payload.retained == previous.payload.retained)
        else check("unrelated or removed job is untouched " .. previous.id, same(context.store:getJob(previous.id), previous)) end
    end
    local episode = context.store:getEpisode("101")
    check("the new local version is authoritative with fresh progress", episode.extra.current_revision == revision
        and episode.extra.local_revision == revision and episode.extra.source_replacement_revision == revision
        and episode.extra.progress_source == "local" and episode.extra.local_finished_at == nil and episode.read == false
        and episode.extra.retained == "unchanged")
    check("comic-level old progress is preserved for Catalog to isolate", same(context.store:getComic("81"), before.database.comic))
    check("Catalog selects the published descriptor", Catalog.new{ store = context.store, pages = context.pages }:getDescriptor("101").revision == revision)
    return result
end
local function run(name, fn)
    case_name = name
    local ok, err = xpcall(fn, debug.traceback)
    report.cases[#report.cases + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    print((ok and "PASS " or "FAIL ") .. name)
    for _, context in ipairs(contexts) do if context.store.connection then context.store:close() end end
end

run("independent_topology_and_all_siblings", function()
    local context = seed{ siblings = true }
    publish(context, capture(context), candidate())
end)
run("unpinned_old_version_is_retained_and_unknown_legacy_is_allowed", function()
    local context = seed{ pinned = false }
    check("the old version starts unpinned", not context.store:isPinned("101", "R1"))
    local record = page(context, 3); record.extra.content_history_version = nil; context.store:putPage(record)
    publish(context, capture(context), candidate())
end)
run("identical_service_index_still_creates_unique_local_versions", function()
    local context = seed()
    local index = candidate(3)
    for i, image in ipairs(index.images) do image.path, image.width, image.height = "/synthetic/old-" .. i, 40, 80 end
    local first = publish(context, capture(context), index)
    local basis = assert(Replacement.capture(context.pages, first.job.id))
    local second = assert(Replacement.publish(context.pages, basis, index))
    check("repeat index never reuses a local snapshot", second.descriptor.revision ~= first.descriptor.revision
        and second.path ~= first.path and second.job.id ~= first.job.id and #context.store:listDescriptors() == 3)
    check("both published snapshot histories remain independent", #context.store:listPages("101", first.descriptor.revision) == 3
        and #context.store:listPages("101", second.descriptor.revision) == 3)
end)
run("fresh_catalog_title_and_permission_can_change", function()
    local context = seed(); local basis = capture(context)
    local episode = context.store:getEpisode("101"); episode.title, episode.access = "Updated synthetic title", "owned"
    context.store:upsertEpisodes("81", { episode })
    local result = publish(context, basis, candidate())
    check("the new job uses fresh catalog metadata", result.job.payload.title == episode.title)
end)
run("fresh_permission_loss_blocks_publication", function()
    local context = seed(); local basis = capture(context)
    local episode = context.store:getEpisode("101"); episode.access = "locked"; context.store:upsertEpisodes("81", { episode })
    rejected(context, basis, candidate(), "entitlement")
end)

local invalid = {
    wrong_episode = function(index) index.episode_id = "102" end,
    wrong_comic = function(index) index.comic_id = "82" end,
    empty_pages = function(index) index.images = {} end,
    sparse_pages = function(index) index.images[2] = nil; index.images[3] = { index = 3 } end,
    named_page_key = function(index) index.images.extra = true end,
    wrong_ordinal = function(index) index.images[2].index = 1 end,
    fractional_geometry = function(index) index.images[2].height = 3.5 end,
    unbounded_geometry = function(index) index.images[2].width = math.huge end,
    duplicate_paths = function(index) index.images[2].path = index.images[1].path end,
    signed_paths = function(index) index.images[2].path = "/synthetic/page?token=private" end,
    empty_paths = function(index) index.images[2].path = "" end,
}
for name, mutate in pairs(invalid) do
    run("invalid_index_" .. name, function()
        local context = seed(); local basis, index = capture(context), candidate()
        mutate(index); rejected(context, basis, index, "invalid_index")
    end)
end
local mutations = {
    job_generation = function(context)
        local job = context.store:getJob(context.job_id); job.run_generation = job.run_generation + 1; context.store:putJob(job)
    end,
    current_revision = function(context)
        local episode = context.store:getEpisode("101"); episode.extra.current_revision = "another-version"; context.store:upsertEpisodes("81", { episode })
    end,
    old_pin = function(context) context.pages:pinEpisode("101", "R1", false) end,
    old_anchor = function(context) context.store:putAnchor("101", "R1", { schema_version = 1, page_id = "original-1", index = 1, x = 0, y = 0 }) end,
    old_page = function(context)
        local record = page(context, 2); record.extra.source_generation = 1; context.store:putPage(record)
    end,
    sibling_job = function(context)
        context.store:putJob{ id = "late-paused", kind = "episode_download", state = "paused", episode_id = "101", comic_id = "81", revision = "R0" }
    end,
}
for name, mutate in pairs(mutations) do
    run("stale_" .. name, function()
        local context = seed(); local basis = capture(context); mutate(context)
        rejected(context, basis, candidate(), "stale_version_replacement")
    end)
end
local busy = {
    reader_of_other_version = function(context) context.pages.active["101/R0"] = 1 end,
    source_refresh_of_other_version = function(context) context.pages.source_refresh_locks = { ["101/R0"] = {} } end,
    running_sibling = function(context)
        context.store:putJob{ id = "other-running", kind = "episode_download", state = "running", episode_id = "101", comic_id = "81", revision = "R0" }
    end,
    pending_commit_of_other_version = function(context)
        context.store:putCommit{ page = { key = "101/R0/1", episode_id = "101", revision = "R0", index = 1 } }
    end,
    other_replacement = function(context)
        context.store:putJob{ id = "other-replacement", kind = "episode_download", state = "paused", episode_id = "101", comic_id = "81", revision = "R0",
            payload = { version_replacement = { id = "other-operation" } } }
    end,
}
for name, mutate in pairs(busy) do
    run("busy_" .. name, function()
        local context = seed(); local basis = capture(context); mutate(context)
        rejected(context, basis, candidate(), "busy")
    end)
end
run("basis_cannot_be_mutated_or_replayed", function()
    local context = seed(); local basis = capture(context); basis.local_state.current_revision = "altered"
    rejected(context, basis, candidate(), "stale_version_replacement")
    basis = capture(context); publish(context, basis, candidate())
    rejected(context, basis, candidate(), "stale_version_replacement")
end)
run("orphan_namespace_and_foreign_anchor_collisions_are_skipped", function()
    local context = seed()
    Files.mkdir(context.pages.documents_root .. "/81/101/local-snapshot-1")
    context.store:_exec("INSERT INTO anchors VALUES(?,?,?)", { "101", "local-snapshot-2", Codec.encode({ index = 9 }) })
    context.store:setPinned("101", "local-snapshot-3", true)
    context.store:putJob{ id = "version-download-4", kind = "episode_download", state = "paused", episode_id = "other", comic_id = "81", revision = "other" }
    local result = publish(context, capture(context), candidate())
    check("occupied local identities are never overwritten", result.descriptor.revision == "local-snapshot-5"
        and context.store:getAnchor("101", "local-snapshot-2").index == 9 and context.store:isPinned("101", "local-snapshot-3"))
end)

local function rollbackCase(name, install, options)
    run(name, function()
        local context = seed{ siblings = true, pinned = options and options.pinned }
        if options and options.pinned == false then check("the old version starts unpinned", not context.store:isPinned("101", "R1")) end
        local basis = capture(context); local before = snapshot(context)
        local restore = install(context)
        rejected(context, basis, candidate(), "storage")
        if restore then restore() end
        unchanged(context, before)
        local orphan_count = 0
        Files.walk(context.pages.documents_root, function(path)
            if path:match("/local%-snapshot%-%d+/chapter%.bcomic$") then orphan_count = orphan_count + 1 end
        end)
        check("a prepared descriptor may remain without a published row", orphan_count == 1 and #context.store:listDescriptors() == 1)
        context.store:close()
        context.store = Store.open{ root = context.root, account_key = context.key, wal = false }
        context.pages = PageStore.new{ root = context.root, account_key = context.key, store = context.store }
        context.pages:reconcile()
        unchanged(context, before)
        check("reopen and reconcile never adopt the orphan descriptor", Catalog.new{ store = context.store, pages = context.pages }:getDescriptor("101").revision == "R1")
        local result = publish(context, capture(context), candidate())
        check("retry chooses another fresh namespace with never history", result.descriptor.revision == "local-snapshot-2")
    end)
end
rollbackCase("second_page_sql_failure_rolls_back", function(context)
    local statement = context.store.connection:prepare([[CREATE TEMP TRIGGER reject_new_page BEFORE INSERT ON pages
        WHEN NEW.revision != 'R1' AND NEW.page_index = 2 BEGIN SELECT RAISE(ABORT, 'synthetic page failure'); END]])
    statement:step(); statement:close()
end)
rollbackCase("final_episode_sql_failure_rolls_back_all_jobs_and_pins", function(context)
    local statement = context.store.connection:prepare([[CREATE TEMP TRIGGER reject_new_episode BEFORE INSERT ON episodes
        BEGIN SELECT RAISE(ABORT, 'synthetic final publication failure'); END]])
    statement:step(); statement:close()
end, { pinned = false })
rollbackCase("descriptor_fsync_failure_preserves_old_snapshot", function(context)
    local original = Files.atomicWrite
    Files.atomicWrite = function(path, bytes, root)
        original(path, bytes, root)
        if path:match("/local%-snapshot%-%d+/chapter%.bcomic$") then error("Synthetic failure after descriptor preparation") end
    end
    return function() Files.atomicWrite = original end
end)

report.passed = #report.cases > 0
for _, item in ipairs(report.cases) do report.passed = report.passed and item.passed end
report.counts = { cases = #report.cases, assertions = #report.assertions }
Files.write(result_path, json.encode(report, { pretty = true }))
print(json.encode({ passed = report.passed, cases = #report.cases, assertions = #report.assertions }))
if not report.passed then os.exit(1) end
