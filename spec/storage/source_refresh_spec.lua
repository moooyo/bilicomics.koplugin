-- Run only inside the isolated official KOReader runtime on test-env.
-- This focused suite uses synthetic local files and never imports an account.
require("setupkoenv")
local source, work, fixture, result_path = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4])
package.path = source .. "/?.lua;" .. source .. "/?/init.lua;" .. package.path

local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Refresh = require("bilicomics/storage/source_refresh")
local Files = require("bilicomics/storage/files")
local Codec = require("bilicomics/storage/codec")
local Header = require("bilicomics/storage/image_header")
local lfs = require("libs/libkoreader-lfs")
local json = require("rapidjson")
local unpack = unpack or table.unpack
local report = { passed = false, assertions = {}, cases = {}, counts = {} }
local contexts, case_sequence, temporary_sequence = {}, 0, 0
local current_case = "setup"
local fixture_bytes, fixture_header, fixture_checksum

local function pack(...)
    return { n = select("#", ...), ... }
end

local function check(name, condition)
    local label = current_case .. ": " .. name
    report.assertions[#report.assertions + 1] = { name = label, passed = not not condition }
    assert(condition, label)
end

local function same(left, right)
    return Codec.canonical(left) == Codec.canonical(right)
end

local function structuredError(name, value, err, kind, code)
    check(name .. " returns no success", value == nil or value == false)
    check(name .. " returns a structured error", type(err) == "table"
        and type(err.kind) == "string" and err.kind ~= ""
        and type(err.code) == "string" and err.code ~= "")
    if kind then check(name .. " has the expected error kind", err.kind == kind) end
    if code then check(name .. " has the expected error code", err.code == code) end
end

local function withoutDigest(name, operation)
    local original, calls = Files.digest, 0
    Files.digest = function()
        calls = calls + 1
        error("Image hashing is forbidden inside the source-refresh metadata API")
    end
    local values = pack(pcall(operation))
    Files.digest = original
    check(name .. " never hashes files", calls == 0)
    if not values[1] then error(values[2], 0) end
    return unpack(values, 2, values.n)
end

local function fileInventory(context)
    local inventory = {}
    for _, root in ipairs({ context.pages.documents_root, context.pages.pages_root, context.pages.temporary_root }) do
        Files.walk(root, function(path)
            local info = assert(lfs.attributes(path))
            local checksum = Files.digest(path)
            inventory[path:sub(#context.root + 2)] = {
                dev = info.dev, ino = info.ino, size = info.size, mode = info.mode,
                modification = info.modification, change = info.change, checksum = checksum,
            }
        end)
    end
    return inventory
end

local function snapshot(context)
    return {
        pages = context.store:listAllPages(), descriptors = context.store:listDescriptors(),
        jobs = context.store:listJobs(), commits = context.store:listCommits(),
        anchor = context.store:getAnchor(context.episode, context.revision) or false,
        pinned = context.store:isPinned(context.episode, context.revision),
        comic = context.store:getComic(context.comic), episode = context.store:getEpisode(context.episode),
        files = fileInventory(context),
    }
end

local function checkUnchanged(context, before, name)
    check(name or "all database records and files remain unchanged", same(snapshot(context), before))
end

local function page(context, index)
    return assert(context.store:getPage(context.episode .. "/" .. context.revision .. "/" .. index))
end

local function newDescriptor(context, episode, revision, count)
    local descriptor = { schema_version = 1, account_key = context.account, comic_id = context.comic,
        episode_id = episode, revision = revision, pages = {} }
    for index = 1, count do
        descriptor.pages[index] = { id = "page-" .. index, index = index,
            width = fixture_header.width, height = fixture_header.height }
    end
    return descriptor
end

local function commit(context, episode, revision, index, fault_hook)
    temporary_sequence = temporary_sequence + 1
    local path = context.pages.temporary_root .. "/synthetic-" .. temporary_sequence .. ".part"
    Files.atomicWrite(path, fixture_bytes, context.root)
    local stored = assert(context.store:getPage(episode .. "/" .. revision .. "/" .. index))
    local original = context.pages.fault_hook
    context.pages.fault_hook = fault_hook
    local values = pack(pcall(context.pages.commitPage, context.pages,
        { account_key = context.account, episode_id = episode, revision = revision, index = index,
            id = stored.id, expected_content_generation = stored.content_generation },
        { temporary_path = path, checksum = Files.digest(path), format = "png",
            width = fixture_header.width, height = fixture_header.height,
            geometry = { source_width = fixture_header.width, source_height = fixture_header.height,
                exif_orientation = 1 } }))
    context.pages.fault_hook = original
    return unpack(values, 1, values.n)
end

local function seed(options)
    options = options or {}
    case_sequence = case_sequence + 1
    local context = { root = work .. "/source-refresh-case-" .. case_sequence, account = "synthetic-source-refresh",
        comic = "synthetic-comic", episode = "synthetic-episode", revision = "immutable-revision" }
    check("the case storage directory is new", lfs.symlinkattributes(context.root) == nil)
    context.store = Store.open{ root = context.root, account_key = context.account, wal = false }
    contexts[#contexts + 1] = context
    context.pages = PageStore.new{ root = context.root, account_key = context.account, store = context.store,
        clock = function() return 1700000000 end }
    context.store:upsertComic{ id = context.comic, title = "Synthetic source refresh" }
    context.store:upsertEpisodes(context.comic, {
        { id = context.episode, order = 1, title = "Synthetic chapter", access = "free" },
    })
    context.descriptor = newDescriptor(context, context.episode, context.revision, 3)
    context.path = context.pages:ensureDescriptor(context.descriptor)
    for index = 1, 3 do
        local stored = page(context, index)
        stored.extra = stored.extra or {}
        stored.extra.source_path = "synthetic-old-source-" .. index
        stored.extra.retained_metadata = "unchanged"
        context.store:putPage(stored)
    end
    if not options.all_never then
        check("the first fixture commits through PageStore", commit(context, context.episode, context.revision, 1))
        check("the second fixture commits through PageStore", commit(context, context.episode, context.revision, 2))
        context.pages:_evict(page(context, 2))
        check("eviction preserves the historical checksum", page(context, 2).state == "missing"
            and page(context, 2).checksum == nil and page(context, 2).extra.last_committed_checksum == fixture_checksum)
    end
    context.pages:pinEpisode(context.episode, context.revision, true)
    if options.anchor ~= false then
        local anchor = type(options.anchor) == "table" and Codec.copy(options.anchor) or {
            schema_version = 1, page_id = "page-1", index = 1, x = 0, y = 0.125,
            source = { x = 0, y = 0.125 }, rotation = 0, mode = "continuous",
            zoom_mode = "pagewidth", zoom_ratio = 1, geometry_generation = page(context, 1).geometry_generation,
        }
        context.store:putAnchor(context.episode, context.revision, anchor)
    end
    context.job_id = "synthetic-download"
    context.store:putJob{ id = context.job_id, kind = "episode_download", state = options.job_state or "paused",
        comic_id = context.comic, episode_id = context.episode, revision = context.revision,
        run_generation = 4, total = 3, completed = options.all_never and 0 or 1,
        payload = { title = "Synthetic paused download" }, updated_at = 1700000000 }
    return context
end

local function capture(context)
    local before = snapshot(context)
    local basis, err = withoutDigest("capture", function()
        return Refresh.capture(context.pages, context.episode, context.revision)
    end)
    check("capture succeeds", type(basis) == "table" and err == nil)
    check("capture identifies the existing namespace", basis.root == context.root and basis.path == context.path
        and basis.account_key == context.account and basis.episode_id == context.episode and basis.revision == context.revision)
    check("capture preserves the immutable descriptor", same(basis.descriptor, context.descriptor))
    check("capture contains complete page snapshots", #basis.pages == 3)
    for index = 1, 3 do
        check("capture page snapshot " .. index .. " is exact", same(basis.pages[index].record, page(context, index)))
    end
    checkUnchanged(context, before, "capture has no database or file side effects")
    return basis
end

local function candidate(context, suffix)
    local value = { episode_id = context.episode, images = {} }
    for index = 1, 3 do
        value.images[index] = { id = "new-source-identity-" .. index, index = index,
            path = "synthetic-new-source-" .. (suffix or "first") .. "-" .. index,
            width = fixture_header.width, height = fixture_header.height,
            x = fixture_header.width, y = fixture_header.height }
    end
    return value
end

local function proofsFor(basis)
    local proofs = {}
    for index, entry in ipairs(basis.pages) do
        if entry.history == "committed" then
            proofs[index] = { checksum = entry.checksum,
                reference_identity = entry.reference_identity and Codec.copy(entry.reference_identity) or nil }
        end
    end
    return proofs
end

local function expectedAdoption(before, context, basis, index)
    local expected = Codec.copy(before)
    for _, record in ipairs(expected.pages) do
        if record.episode_id == context.episode and record.revision == context.revision then
            local entry = basis.pages[record.index]
            record.extra = record.extra or {}
            record.extra.source_path = index.images[record.index].path
            record.extra.source_generation = (record.extra.source_generation or 0) + 1
            if entry.history == "committed" then record.extra.expected_source_checksum = entry.checksum end
        end
    end
    return expected
end

local function adoptSuccess(context, basis, index)
    local before = snapshot(context)
    local expected = expectedAdoption(before, context, basis, index)
    local paths, validation_error = withoutDigest("validateIndex", function()
        return Refresh.validateIndex(basis, index)
    end)
    check("the complete replacement index validates", type(paths) == "table" and validation_error == nil and #paths == 3)
    for number = 1, 3 do check("validated path order " .. number .. " is unchanged", paths[number] == index.images[number].path) end
    local summary, err = withoutDigest("adopt", function()
        return Refresh.adopt(context.pages, basis, index, proofsFor(basis))
    end)
    local committed = 0
    for _, entry in ipairs(basis.pages) do if entry.history == "committed" then committed = committed + 1 end end
    check("adoption returns a complete summary", type(summary) == "table" and err == nil
        and summary.episode_id == context.episode and summary.revision == context.revision
        and summary.updated_pages == 3 and summary.verified_pages == committed)
    for number = 1, 3 do
        check("the source generation advances once for page " .. number,
            summary.source_generations[number] == (basis.pages[number].record.extra.source_generation or 0) + 1)
    end
    check("only allowed source metadata changes", same(snapshot(context), expected))
    return expected
end

local function adoptRejected(context, basis, index, proofs, kind)
    local before = snapshot(context)
    local value, err = withoutDigest("rejected adopt", function()
        return Refresh.adopt(context.pages, basis, index, proofs or proofsFor(basis))
    end)
    structuredError("adoption rejection", value, err, kind)
    checkUnchanged(context, before)
end

local function captureRejected(context, kind)
    local before = snapshot(context)
    local value, err = withoutDigest("rejected capture", function()
        return Refresh.capture(context.pages, context.episode, context.revision)
    end)
    structuredError("capture rejection", value, err, kind)
    checkUnchanged(context, before)
end

local function reopen(context)
    context.store:close()
    context.store = Store.open{ root = context.root, account_key = context.account, wal = false }
    context.pages = PageStore.new{ root = context.root, account_key = context.account, store = context.store,
        clock = function() return 1700000000 end }
end

local function runCase(name, operation)
    current_case = name
    local first_context = #contexts + 1
    local ok, failure = pcall(operation)
    for index = first_context, #contexts do
        local context = contexts[index]
        local closed = pcall(context.store.close, context.store)
        if not closed then ok, failure = false, "The synthetic store did not close cleanly" end
    end
    local result = { name = name, passed = ok }
    if not ok then result.failure = tostring(failure) end
    report.cases[#report.cases + 1] = result
end

local function pendingCommit(context, episode, revision)
    if episode ~= context.episode or revision ~= context.revision then
        context.store:upsertEpisodes(context.comic, { { id = episode, order = 2, title = "Unrelated synthetic chapter", access = "free" } })
        context.pages:ensureDescriptor(newDescriptor(context, episode, revision, 1))
    end
    local index = episode == context.episode and revision == context.revision and 3 or 1
    local ok = commit(context, episode, revision, index, function(point)
        if point == "after_journal" then error("Intentional interruption after the durable commit journal") end
    end)
    check("a real PageStore commit is interrupted after journaling", not ok)
    check("the interrupted commit remains recorded", #context.store:listCommits() > 0)
end

local setup_ok, setup_error = pcall(function()
    Files.mkdir(work)
    fixture_header = Header.read(fixture)
    assert(fixture_header.format == "png" and (fixture_header.exif_orientation or 1) == 1,
        "The focused suite requires a synthetic unrotated PNG fixture")
    fixture_bytes = Files.read(fixture, 8 * 1024 * 1024)
    fixture_checksum = Files.digest(fixture)

    runCase("file_identity_contract", function()
        local context = seed()
        local reference = page(context, 1).path
        local identity, err = withoutDigest("fileIdentity", function() return Refresh.fileIdentity(reference, context.root) end)
        check("file identity is available without hashing", type(identity) == "table" and err == nil)
        for _, key in ipairs({ "dev", "ino", "size", "modification", "change" }) do
            check("file identity field " .. key .. " is numeric", type(identity[key]) == "number")
            local changed = Codec.copy(identity); changed[key] = changed[key] + 1
            check("file identity compares " .. key .. " strictly", not Refresh.sameFileIdentity(identity, changed))
        end
        check("equal file identities compare equal", Refresh.sameFileIdentity(identity, Codec.copy(identity)))
        check("missing identities never compare equal", not Refresh.sameFileIdentity(identity, nil)
            and not Refresh.sameFileIdentity(nil, nil))
        local missing, missing_error = withoutDigest("missing fileIdentity", function()
            return Refresh.fileIdentity(context.root .. "/absent.png", context.root)
        end)
        structuredError("missing reference file", missing, missing_error, "storage", "file_identity")
        local escaped, escaped_error = withoutDigest("outside fileIdentity", function()
            return Refresh.fileIdentity(reference, context.pages.temporary_root)
        end)
        structuredError("reference outside the allowed root", escaped, escaped_error, "storage", "file_identity")
    end)

    runCase("mixed_history_success_is_durable", function()
        local context = seed()
        local basis = capture(context)
        check("ready and historical missing pages are both committed", basis.pages[1].history == "committed"
            and basis.pages[2].history == "committed" and basis.pages[3].history == "never")
        check("both committed pages require the trusted fixture digest", basis.pages[1].checksum == fixture_checksum
            and basis.pages[2].checksum == fixture_checksum and basis.pages[3].checksum == nil)
        check("only the ready page has a reference identity", type(basis.pages[1].reference_identity) == "table"
            and basis.pages[2].reference_identity == nil and basis.pages[3].reference_identity == nil)
        local expected = adoptSuccess(context, basis, candidate(context))
        reopen(context)
        check("all allowed changes survive reopening SQLite", same(snapshot(context), expected))
        local next_basis = capture(context)
        adoptSuccess(context, next_basis, candidate(context, "second"))
        check("every source generation is durable and monotonic", page(context, 1).extra.source_generation == 2
            and page(context, 2).extra.source_generation == 2 and page(context, 3).extra.source_generation == 2)
    end)

    runCase("zero_ready_retains_historical_proof_requirements", function()
        local context = seed()
        context.pages:_evict(page(context, 1))
        local basis = capture(context)
        check("zero ready pages still retain both committed baselines", basis.pages[1].history == "committed"
            and basis.pages[2].history == "committed" and basis.pages[1].reference_identity == nil)
        local incomplete = proofsFor(basis); incomplete[2] = nil
        adoptRejected(context, basis, candidate(context), incomplete)
        adoptSuccess(context, basis, candidate(context))
    end)

    for _, source_anchor in ipairs({ false, true }) do
        runCase(source_anchor and "known_never_chapter_start_with_source" or "known_never_chapter_start_without_source", function()
            local anchor = { schema_version = 1, page_id = "page-1", index = 1, x = 0, y = 0,
                rotation = 0, mode = "continuous", zoom_mode = "pagewidth", finished = false }
            if source_anchor then anchor.source = { x = 0, y = 0 } end
            local context = seed{ all_never = true, anchor = anchor }
            adoptSuccess(context, capture(context), candidate(context))
        end)
    end

    runCase("known_never_without_anchor", function()
        local context = seed{ all_never = true, anchor = false, job_state = "failed" }
        local basis = capture(context)
        check("all new pages have explicit never history", basis.pages[1].history == "never"
            and basis.pages[2].history == "never" and basis.pages[3].history == "never")
        adoptSuccess(context, basis, candidate(context))
    end)

    local unsafe_anchors = {
        { name = "later_page", page_id = "page-2", index = 2, x = 0, y = 0, rotation = 0 },
        { name = "vertical_offset", page_id = "page-1", index = 1, x = 0, y = 0.2, rotation = 0 },
        { name = "horizontal_offset", page_id = "page-1", index = 1, x = 0.2, y = 0, rotation = 0 },
        { name = "source_offset", page_id = "page-1", index = 1, x = 0, y = 0, rotation = 0, source = { x = 0, y = 0.2 } },
        { name = "rotation", page_id = "page-1", index = 1, x = 0, y = 0, rotation = 90 },
        { name = "finished", page_id = "page-1", index = 1, x = 0, y = 0, rotation = 0, finished = true },
    }
    for _, template in ipairs(unsafe_anchors) do
        runCase("known_never_rejects_" .. template.name, function()
            local anchor = Codec.copy(template); anchor.name = nil; anchor.schema_version = 1
            captureRejected(seed{ all_never = true, anchor = anchor }, "unverified_position")
        end)
    end

    runCase("legacy_missing_history_is_unknown", function()
        local context = seed{ all_never = true, anchor = false }
        for number = 1, 3 do
            local stored = page(context, number)
            stored.extra.content_history_version = nil
            context.store:putPage(stored)
        end
        captureRejected(context, "unknown_history")
    end)

    runCase("one_unknown_page_rejects_a_partial_history", function()
        local context = seed()
        local stored = page(context, 3)
        stored.extra.content_history_version = nil
        context.store:putPage(stored)
        captureRejected(context, "unknown_history")
    end)

    runCase("failed_historical_page_still_requires_sha", function()
        local context = seed()
        local stored = page(context, 2); stored.state = "failed"; stored.error = "Synthetic acquisition failure"
        context.store:putPage(stored)
        local basis = capture(context)
        check("failed historical pages stay committed", basis.pages[2].history == "committed"
            and basis.pages[2].checksum == fixture_checksum)
        local proofs = proofsFor(basis); proofs[2].checksum = string.rep("0", 64)
        adoptRejected(context, basis, candidate(context), proofs, "content_changed")
    end)

    local bad_indexes = {
        { name = "episode", mutate = function(value) value.episode_id = "another-episode" end },
        { name = "count", mutate = function(value) table.remove(value.images) end },
        { name = "order", mutate = function(value) value.images[1], value.images[2] = value.images[2], value.images[1] end },
        { name = "width", mutate = function(value) value.images[2].width = value.images[2].width + 1; value.images[2].x = value.images[2].width end },
        { name = "height", mutate = function(value) value.images[2].height = value.images[2].height + 1; value.images[2].y = value.images[2].height end },
        { name = "duplicate_source", mutate = function(value) value.images[2].path = value.images[1].path end },
        { name = "empty_source", mutate = function(value) value.images[2].path = "" end },
        { name = "missing_index", mutate = function(value) value.images[2].index = nil end },
        { name = "non_table_page", mutate = function(value) value.images[2] = "invalid" end },
    }
    for _, item in ipairs(bad_indexes) do
        runCase("topology_rejects_" .. item.name, function()
            local context = seed()
            local basis, index = capture(context), candidate(context)
            item.mutate(index)
            local before = snapshot(context)
            local value, err = withoutDigest("invalid validateIndex", function() return Refresh.validateIndex(basis, index) end)
            structuredError("index rejection", value, err)
            checkUnchanged(context, before)
            adoptRejected(context, basis, index)
        end)
    end

    for _, number in ipairs({ 1, 2 }) do
        runCase("checksum_rejection_page_" .. number, function()
            local context = seed()
            local basis = capture(context)
            local proofs = proofsFor(basis); proofs[number].checksum = string.rep("0", 64)
            adoptRejected(context, basis, candidate(context), proofs, "content_changed")
        end)
    end

    runCase("ready_reference_proof_is_required", function()
        local context = seed()
        local basis = capture(context)
        local proofs = proofsFor(basis); proofs[1].reference_identity = nil
        adoptRejected(context, basis, candidate(context), proofs)
    end)

    runCase("ready_reference_proof_must_match", function()
        local context = seed()
        local basis = capture(context)
        local proofs = proofsFor(basis)
        proofs[1].reference_identity.size = proofs[1].reference_identity.size + 1
        adoptRejected(context, basis, candidate(context), proofs)
    end)

    runCase("ready_reference_replacement_invalidates_basis", function()
        local context = seed()
        local basis = capture(context)
        local reference = page(context, 1).path
        Files.atomicWrite(reference, fixture_bytes, context.root)
        local changed = assert(Refresh.fileIdentity(reference, context.root))
        check("replacement changes the reference identity", not Refresh.sameFileIdentity(changed, basis.pages[1].reference_identity))
        adoptRejected(context, basis, candidate(context))
    end)

    local page_mutations = {
        { name = "content_generation", mutate = function(record) record.content_generation = record.content_generation + 1 end },
        { name = "geometry_generation", mutate = function(record) record.geometry_generation = record.geometry_generation + 1 end },
        { name = "source_generation", mutate = function(record) record.extra.source_generation = 7 end },
        { name = "source_path", mutate = function(record) record.extra.source_path = "concurrent-source" end },
        { name = "unrelated_page_metadata", mutate = function(record) record.extra.retained_metadata = "concurrently edited" end },
    }
    for _, item in ipairs(page_mutations) do
        runCase("page_cas_rejects_" .. item.name, function()
            local context = seed()
            local basis = capture(context)
            local stored = page(context, 1); item.mutate(stored); context.store:putPage(stored)
            adoptRejected(context, basis, candidate(context), nil, "stale_source_refresh")
        end)
    end

    runCase("anchor_cas_rejects_change", function()
        local context = seed()
        local basis = capture(context)
        local anchor = context.store:getAnchor(context.episode, context.revision)
        anchor.y, anchor.source.y = 0.25, 0.25
        context.store:putAnchor(context.episode, context.revision, anchor)
        adoptRejected(context, basis, candidate(context), nil, "stale_source_refresh")
    end)

    runCase("pin_cas_rejects_change", function()
        local context = seed()
        local basis = capture(context)
        context.store:setPinned(context.episode, context.revision, false)
        adoptRejected(context, basis, candidate(context), nil, "stale_source_refresh")
    end)

    runCase("descriptor_cas_rejects_change", function()
        local context = seed()
        local basis = capture(context)
        local changed = Codec.copy(context.descriptor); changed.pages[2].id = "concurrent-page-identity"
        context.store:putDescriptor(changed, context.path)
        adoptRejected(context, basis, candidate(context))
    end)

    runCase("active_chapter_cannot_adopt", function()
        local context = seed()
        local basis = capture(context)
        context.pages:setActiveEpisode(context.episode, context.revision, true)
        adoptRejected(context, basis, candidate(context))
        context.pages:setActiveEpisode(context.episode, context.revision, false)
    end)

    for _, state in ipairs({ "queued", "running" }) do
        runCase("active_download_job_rejects_" .. state, function()
            local context = seed()
            local basis = capture(context)
            local job = context.store:getJob(context.job_id)
            job.state = state; job.revision = "another-revision-of-the-same-episode"
            context.store:putJob(job)
            adoptRejected(context, basis, candidate(context))
        end)
    end

    for _, field in ipairs({ "state", "revision", "run_generation" }) do
        runCase("job_cas_rejects_" .. field, function()
            local context = seed()
            local basis = capture(context)
            local job = context.store:getJob(context.job_id)
            if field == "state" then job.state = "canceled"
            elseif field == "revision" then job.revision = "changed-revision"
            else job.run_generation = job.run_generation + 1 end
            context.store:putJob(job)
            adoptRejected(context, basis, candidate(context), nil, "stale_source_refresh")
        end)
    end

    runCase("job_payload_and_timestamp_are_not_binding", function()
        local context = seed()
        local basis = capture(context)
        local job = context.store:getJob(context.job_id)
        job.payload.title = "Changed display metadata"; job.updated_at = job.updated_at + 10
        context.store:putJob(job)
        adoptSuccess(context, basis, candidate(context))
    end)

    runCase("target_pending_journal_blocks_adoption", function()
        local context = seed()
        local basis = capture(context)
        pendingCommit(context, context.episode, context.revision)
        adoptRejected(context, basis, candidate(context))
    end)

    runCase("unrelated_journal_and_job_are_retained", function()
        local context = seed()
        pendingCommit(context, "unrelated-episode", "unrelated-revision")
        context.store:putJob{ id = "unrelated-running-download", kind = "episode_download", state = "running",
            comic_id = context.comic, episode_id = "unrelated-episode", revision = "unrelated-revision", run_generation = 2 }
        local basis = capture(context)
        adoptSuccess(context, basis, candidate(context))
    end)

    runCase("sql_failure_rolls_back_every_page_durably", function()
        local context = seed()
        local basis, index = capture(context), candidate(context)
        local before = snapshot(context)
        local original, writes, first_write_seen = context.store.putPage, 0, false
        context.store.putPage = function(target, record)
            if record.episode_id == context.episode and record.revision == context.revision then
                writes = writes + 1
                if writes == 2 then error("Intentional failure before the second page update") end
            end
            local value = original(target, record)
            if writes == 1 then
                first_write_seen = target:getPage(record.key).extra.source_path == index.images[record.index].path
            end
            return value
        end
        local values = pack(pcall(function()
            return withoutDigest("transaction rollback adopt", function()
                return Refresh.adopt(context.pages, basis, index, proofsFor(basis))
            end)
        end))
        context.store.putPage = original
        if not values[1] then error(values[2], 0) end
        structuredError("injected transaction failure", values[2], values[3], "storage")
        check("the first real SQL write ran before the second failed", writes == 2 and first_write_seen)
        check("the transaction depth returns to zero", context.store._depth == 0)
        checkUnchanged(context, before, "the failed transaction restores every database record and file")
        reopen(context)
        checkUnchanged(context, before, "rollback remains complete after reopening SQLite")
    end)
end)

if not setup_ok then report.setup_failure = tostring(setup_error) end
report.passed = setup_ok and #report.cases > 0
for _, item in ipairs(report.cases) do report.passed = report.passed and item.passed end
report.counts.cases = #report.cases
report.counts.assertions = #report.assertions
report.counts.failed_cases = 0
for _, item in ipairs(report.cases) do
    if not item.passed then report.counts.failed_cases = report.counts.failed_cases + 1 end
end
Files.write(result_path, json.encode(report, { pretty = true }))
print(json.encode({ passed = report.passed, cases = report.counts.cases,
    assertions = report.counts.assertions, failed_cases = report.counts.failed_cases }))
if not report.passed then os.exit(1) end
