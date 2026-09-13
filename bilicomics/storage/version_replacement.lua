-- Publish an explicitly requested, independent local chapter snapshot.
-- Old files and anchors are not migrated; successful publication pins both versions.
local Codec = require("bilicomics/storage/codec")
local Files = require("bilicomics/storage/files")
local SourceRefresh = require("bilicomics/storage/source_refresh")
local lfs = require("libs/libkoreader-lfs")

local Replacement = {}
local captures = setmetatable({}, { __mode = "k" })
local sequence_key = "version_replacement_sequence"

local function fail(kind, code, message)
    error({ kind = kind, code = code, message = message, retryable = false }, 0)
end

local function attempt(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    if type(value) == "table" and value.kind and value.code then return nil, value end
    return nil, { kind = "storage", code = "version_replacement", retryable = false,
        message = "The new chapter version could not be published safely." }
end

local function integer(value, minimum, maximum)
    return type(value) == "number" and value == value and value % 1 == 0
        and value >= minimum and value <= maximum
end

local function identity(value)
    value = tostring(value or "")
    if value == "" or #value > 256 or value:find("[%z/\\]") then
        fail("invalid_request", "identity", "A valid local chapter identity is required.")
    end
    return value
end

local function canonical(value) return value == nil and "null" or Codec.canonical(value) end
local function equal(left, right) return canonical(left) == canonical(right) end
local function sameEpisode(record, episode_id) return tostring(record.episode_id) == episode_id end

local function permitted(episode)
    if episode.access == "free" or episode.access == "owned" then return true end
    return episode.access == "temporary" and type(episode.expires_at) == "number"
        and episode.expires_at > os.time() and (episode.extra or {}).offline_allowed == true
end

local function inspect(pages, job_id)
    local store = pages.store
    assert(store.root == pages.root and store.account_key == pages.account_key)
    local job = store:getJob(identity(job_id))
    if not job or job.kind ~= "episode_download" or job.state ~= "paused" or not job.revision
        or (job.payload or {}).removed or (job.payload or {}).replaced_by then
        fail("invalid_request", "retained_partial", "Select an unreplaced, retained and paused chapter download.")
    end
    if not integer(job.run_generation or 0, 0, 9007199254740990) then
        fail("storage", "job_generation", "The paused download generation is invalid.")
    end
    local episode_id, revision, comic_id = identity(job.episode_id), identity(job.revision), identity(job.comic_id)
    local episode = store:getEpisode(episode_id)
    if not episode or tostring(episode.comic_id) ~= comic_id then
        fail("invalid_request", "chapter_identity", "The retained download does not match the local chapter.")
    end
    if not permitted(episode) then fail("entitlement", "offline_access", "Offline access for this chapter must be confirmed.") end
    local prefix = episode_id .. "/"
    for key, active in pairs(pages.active or {}) do
        if key:sub(1, #prefix) == prefix and active ~= 0 then
            fail("busy", "chapter_active", "Close every version of this chapter before replacing it.")
        end
    end
    for key in pairs(pages.source_refresh_locks or {}) do
        if key:sub(1, #prefix) == prefix then
            fail("busy", "source_refresh", "Finish or cancel source verification before replacing this chapter.")
        end
    end
    local jobs = {}
    for _, related in ipairs(store:listJobs()) do
        if related.kind == "episode_download" and sameEpisode(related, episode_id) then
            local payload = related.payload or {}
            if related.state == "queued" or related.state == "running" then
                fail("busy", "download_active", "Pause all downloads for this chapter before replacing it.")
            end
            if payload.source_refresh then fail("busy", "source_refresh", "Recover or finish the existing source verification.") end
            if related.id ~= job.id and payload.version_replacement then
                fail("busy", "version_replacement", "Another replacement of this chapter is already pending.")
            end
            if related.revision == revision and not payload.removed and payload.replaced_by then
                fail("invalid_request", "retired_version", "This local version has already been replaced.")
            end
            jobs[#jobs + 1] = Codec.copy(related)
        end
    end
    table.sort(jobs, function(left, right) return left.id < right.id end)
    for _, commit in ipairs(store:listCommits()) do
        if sameEpisode(commit.page or {}, episode_id) then
            fail("busy", "pending_commit", "Recover this chapter's pending image commits before replacing it.")
        end
    end
    local descriptor, path = store:getDescriptor(episode_id, revision)
    if not descriptor or not path or descriptor.account_key ~= pages.account_key or descriptor.comic_id ~= comic_id
        or descriptor.episode_id ~= episode_id or descriptor.revision ~= revision then
        fail("storage", "descriptor_identity", "The retained chapter descriptor is unavailable or inconsistent.")
    end
    assert(equal(pages:readDescriptor(path), descriptor), "The retained descriptor must match its database record")
    local descriptor_bytes = Files.read(path, 4194304)
    assert(descriptor_bytes == Codec.canonical(descriptor) .. "\n", "The retained descriptor bytes must be canonical")
    local file_identity = assert(SourceRefresh.fileIdentity(path, pages.documents_root))
    local records, files = store:listPages(episode_id, revision), {}
    assert(#records == #descriptor.pages, "Every retained descriptor page needs a local record")
    for index, record in ipairs(records) do
        assert(record.index == index and record.id == descriptor.pages[index].id
            and record.episode_id == episode_id and record.revision == revision)
        if record.state == "ready" then
            Files.assertContained(record.path, pages.pages_root)
            local mode = lfs.symlinkattributes(record.path, "mode")
            assert(mode == nil or mode == "file", "Retained page paths must not be links or special files")
            files[index] = { path = record.path,
                identity = mode and assert(SourceRefresh.fileIdentity(record.path, pages.pages_root)) or false }
        else files[index] = false end
    end
    local extra = episode.extra or {}
    return { schema_version = 1, root = pages.root, account_key = pages.account_key,
        job_id = job.id, comic_id = comic_id, episode_id = episode_id, revision = revision,
        job = Codec.copy(job), jobs = jobs, descriptor = descriptor, path = path,
        descriptor_bytes = descriptor_bytes, descriptor_identity = file_identity,
        pages = records, files = files, pinned = store:isPinned(episode_id, revision),
        anchor = store:getAnchor(episode_id, revision),
        local_state = { current_revision = extra.current_revision, local_revision = extra.local_revision,
            source_replacement_revision = extra.source_replacement_revision, progress_source = extra.progress_source,
            local_finished_at = extra.local_finished_at } }
end

function Replacement.capture(pages, job_id)
    return attempt(function()
        assert(pages.store._depth == 0, "Replacement capture must own its read transaction")
        local basis = pages.store:transaction(function() return inspect(pages, job_id) end)
        captures[basis] = { owner = pages, seal = canonical(basis) }
        return basis
    end)
end

local function validateIndex(basis, index)
    if type(index) ~= "table" or tostring(index.episode_id) ~= basis.episode_id
        or index.comic_id ~= nil and tostring(index.comic_id) ~= basis.comic_id then
        fail("invalid_index", "chapter_identity", "The replacement index belongs to a different chapter.")
    end
    local images, count = index.images or index.pages, 0
    if type(images) ~= "table" or #images == 0 or #images > 10000 then
        fail("invalid_index", "page_count", "The replacement chapter needs a bounded nonempty page list.")
    end
    for key in pairs(images) do
        if not integer(key, 1, #images) then fail("invalid_index", "page_order", "The replacement page list must be dense.") end
        count = count + 1
    end
    if count ~= #images then fail("invalid_index", "page_order", "The replacement page list must be dense.") end
    local result, seen = {}, {}
    for number, image in ipairs(images) do
        local width, height = type(image) == "table" and (image.width or image.x), type(image) == "table" and (image.height or image.y)
        if type(image) ~= "table" or image.index ~= number
            or not integer(width, 1, 1000000) or not integer(height, 1, 1000000) then
            fail("invalid_index", "page_geometry", "Replacement page indexes and dimensions must be positive ordered integers.")
        end
        local path = image.path
        if type(path) ~= "string" or path == "" or #path > 8192 or path:find("[%z\r\n]")
            or path:lower():find("[?&]token=") or seen[path] then
            fail("invalid_index", "source_paths", "Replacement source paths must be unique, nonempty and unsigned.")
        end
        seen[path], result[number] = true, { path = path, width = width, height = height }
    end
    return result
end

function Replacement.validateIndex(basis, index)
    return attempt(function() return validateIndex(basis, index) end)
end

local function allocate(pages, index)
    local store = pages.store
    local sequence = store:getSetting(sequence_key, 0)
    assert(integer(sequence, 0, 9007199254739990), "The local snapshot counter is invalid")
    local used = {}
    for _, entry in ipairs(store:listDescriptors()) do used[entry.descriptor.revision] = true end
    for _, job in ipairs(store:listJobs()) do if job.revision then used[job.revision] = true end end
    for _ = 1, 1000 do
        sequence = sequence + 1
        local suffix = string.format("%.0f", sequence)
        local revision, job_id = "local-snapshot-" .. suffix, "version-download-" .. suffix
        local path = pages.documents_root .. "/" .. Files.component(index.comic_id) .. "/" .. Files.component(index.episode_id)
            .. "/" .. Files.component(revision) .. "/chapter.bcomic"
        local directory = Files.parent(path)
        if not used[revision] and revision ~= index.server_revision and not store:getJob(job_id)
            and lfs.symlinkattributes(directory) == nil
            and #store:listPages(index.episode_id, revision) == 0 and not store:getAnchor(index.episode_id, revision)
            and #store:_rows("SELECT pinned FROM pins WHERE episode_id=? AND revision=?", { index.episode_id, revision }) == 0 then
            Files.assertContained(path, pages.documents_root)
            store:putSetting(sequence_key, sequence)
            return revision, job_id, path
        end
    end
    fail("storage", "local_identity", "A fresh local chapter identity could not be allocated.")
end

function Replacement.publish(pages, basis, index)
    return attempt(function()
        local saved = captures[basis]
        if not saved or saved.owner ~= pages or saved.seal ~= canonical(basis) then
            fail("stale_version_replacement", "invalid_basis", "Capture this paused download again before replacing it.")
        end
        local images = validateIndex(basis, index)
        assert(pages.store._depth == 0, "Version publication must own its transaction")
        local result = pages.store:transaction(function()
            local current = inspect(pages, basis.job_id)
            if not equal(current, basis) then
                fail("stale_version_replacement", "basis_changed", "The retained download changed before replacement publication.")
            end
            local revision, job_id, path = allocate(pages, { comic_id = basis.comic_id,
                episode_id = basis.episode_id, server_revision = index.revision })
            local descriptor = { schema_version = 1, account_key = basis.account_key,
                comic_id = basis.comic_id, episode_id = basis.episode_id, revision = revision, pages = {} }
            for number, image in ipairs(images) do
                descriptor.pages[number] = { id = revision .. "-page-" .. number, index = number,
                    width = image.width, height = image.height }
            end
            assert(pages:ensureDescriptor(descriptor) == path)
            for number, image in ipairs(images) do
                local page = assert(pages.store:getPage(basis.episode_id .. "/" .. revision .. "/" .. number))
                assert(page.state == "missing" and (page.extra or {}).content_history_version == 1)
                page.extra.source_path, page.extra.source_generation = image.path, 0
                pages.store:putPage(page)
            end
            pages.store:setPinned(basis.episode_id, revision, true)
            pages.store:setPinned(basis.episode_id, basis.revision, true)
            local episode = assert(pages.store:getEpisode(basis.episode_id))
            local comic = pages.store:getComic(basis.comic_id) or {}
            local now = os.time()
            local job = { id = job_id, kind = "episode_download", state = "paused", comic_id = basis.comic_id,
                episode_id = basis.episode_id, revision = revision, completed = 0, total = #images,
                run_generation = 0, created_at = now, updated_at = now,
                payload = { replaces_job_id = basis.job_id, title = episode.title, comic_title = comic.title } }
            pages.store:putJob(job)
            for _, retired in ipairs(current.jobs) do
                if retired.revision == basis.revision and not (retired.payload or {}).removed then
                    retired.state, retired.updated_at = "canceled", now
                    retired.run_generation = (retired.run_generation or 0) + 1
                    retired.payload = retired.payload or {}
                    retired.payload.version_replacement, retired.payload.replaced_by = nil, job_id
                    pages.store:putJob(retired)
                end
            end
            episode.extra = episode.extra or {}
            episode.extra.current_revision, episode.extra.local_revision = revision, revision
            episode.extra.source_replacement_revision, episode.extra.progress_source = revision, "local"
            episode.extra.local_finished_at, episode.read = nil, false
            pages.store:upsertEpisodes(basis.comic_id, { episode })
            return { job = job, descriptor = descriptor, path = path, replaced_job_id = basis.job_id }
        end)
        captures[basis] = nil
        return result
    end)
end

return Replacement
