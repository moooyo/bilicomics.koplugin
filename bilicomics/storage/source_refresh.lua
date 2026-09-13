-- Proof-gated source replacement for an existing immutable local descriptor.
-- This module reads metadata only. Workers verify reference and candidate bytes.
local Codec = require("bilicomics/storage/codec")
local Files = require("bilicomics/storage/files")
local lfs = require("libs/libkoreader-lfs")

local SourceRefresh = {}
local identity_fields = { "dev", "ino", "size", "modification", "change" }
local captures = setmetatable({}, { __mode = "k" })

local function fail(kind, code, message, index)
    error({ kind = kind, code = code, message = message, index = index, retryable = false }, 0)
end

local function attempt(operation, kind, code)
    local ok, value = pcall(operation)
    if ok then return value end
    if type(value) == "table" and value.kind and value.code then return nil, value end
    return nil, { kind = kind or "storage", code = code or "storage_error",
        message = "The source refresh could not safely inspect or update local storage.", retryable = false }
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function generation(value)
    return finite(value) and value >= 0 and value % 1 == 0 and value < 9007199254740991
end

local function canonical(value)
    if value == nil then return "null" end
    return Codec.canonical(value)
end

local function equal(left, right)
    return canonical(left) == canonical(right)
end

local function digest(value)
    if type(value) == "string" and #value == 64 and not value:find("[^0-9a-fA-F]") then return value:lower() end
end

local function identity(value)
    value = tostring(value or "")
    if value == "" or #value > 256 or value:find("[%z/\\]") then
        fail("storage", "invalid_identity", "The chapter identity is invalid.")
    end
    return value
end

local function fileIdentity(path, root)
    assert(type(root) == "string" and root:sub(1, 1) == "/", "An absolute storage root is required")
    local current = ""
    for component in root:gmatch("[^/]+") do
        assert(component ~= "." and component ~= "..", "The storage root must be resolved")
        current = current .. "/" .. component
        assert(lfs.symlinkattributes(current, "mode") == "directory", "Linked storage ancestors are not allowed")
    end
    Files.assertRegular(path, root)
    local attributes = assert(lfs.attributes(path))
    local result = {}
    for _, key in ipairs(identity_fields) do
        local value = tonumber(attributes[key])
        assert(finite(value), "Required file metadata is unavailable")
        result[key] = value
    end
    assert(result.dev >= 0 and result.ino >= 0 and result.size >= 0)
    return result
end

function SourceRefresh.fileIdentity(path, root)
    return attempt(function() return fileIdentity(path, root) end, "storage", "file_identity")
end

function SourceRefresh.sameFileIdentity(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    for _, key in ipairs(identity_fields) do
        if not finite(left[key]) or not finite(right[key]) or left[key] ~= right[key] then return false end
    end
    return true
end

local function assertIdle(pages, episode_id, revision)
    if (pages.active[episode_id .. "/" .. revision] or 0) ~= 0 then
        fail("busy", "chapter_active", "Close the chapter before refreshing its image sources.")
    end
    local jobs = {}
    for _, job in ipairs(pages.store:listJobs()) do
        if job.kind == "episode_download" and tostring(job.episode_id) == episode_id then
            if job.state == "queued" or job.state == "running" then
                fail("busy", "download_active", "Pause this chapter's download before refreshing its image sources.")
            end
            jobs[#jobs + 1] = { id = job.id, revision = job.revision, state = job.state,
                run_generation = job.run_generation or 0 }
        end
    end
    table.sort(jobs, function(left, right) return left.id < right.id end)
    for _, journal in ipairs(pages.store:listCommits()) do
        local page = journal.page or {}
        if tostring(page.episode_id) == episode_id and tostring(page.revision) == revision then
            fail("busy", "pending_commit", "Recover the chapter's pending image commit before refreshing its sources.")
        end
    end
    return jobs
end

local function history(page, index)
    local extra = page.extra or {}
    assert(type(extra) == "table")
    local historical = extra.last_committed_checksum
    if historical ~= nil and not digest(historical) then
        fail("unknown_history", "invalid_history", "The page's committed-content history is invalid.", index)
    end
    local expected
    if page.state == "ready" then
        expected = digest(page.checksum)
        if not expected or historical and expected ~= digest(historical) then
            fail("unknown_history", "conflicting_history", "The page's committed-content history is inconsistent.", index)
        end
    elseif historical then
        expected = digest(historical)
    end
    if extra.expected_source_checksum ~= nil and (not expected or not digest(extra.expected_source_checksum)
        or digest(extra.expected_source_checksum) ~= expected) then
        fail("unknown_history", "conflicting_history", "The page's source-content binding is inconsistent.", index)
    end
    if expected then return "committed", expected end
    if extra.content_history_version == 1 and page.state ~= "ready" then return "never" end
    fail("unknown_history", "unknown_history", "This page has no trustworthy committed-content history.", index)
end

local function assertAnchor(basis)
    local anchor = basis.anchor
    if not anchor then return end
    if type(anchor) ~= "table" then fail("unverified_position", "invalid_anchor", "The stored reading position cannot be verified.") end
    local index
    for number, page in ipairs(basis.descriptor.pages) do
        if page.id == anchor.page_id then index = number; break end
    end
    if anchor.schema_version ~= 1 or not index
        or anchor.index and anchor.index ~= index or not finite(anchor.x) or not finite(anchor.y) then
        fail("unverified_position", "invalid_anchor", "The stored reading position cannot be verified.")
    end
    if basis.pages[index].history == "committed" then return end
    local source = anchor.source
    local geometry = basis.pages[index].record.geometry or {}
    local orientation = geometry.exif_orientation or geometry.orientation or 1
    local start = index == 1 and anchor.x == 0 and anchor.y == 0 and (anchor.rotation == nil or anchor.rotation == 0)
        and (anchor.finished == nil or anchor.finished == false) and orientation == 1
        and (source == nil or type(source) == "table" and source.x == 0 and source.y == 0)
    if not start then
        fail("unverified_position", "uncommitted_anchor", "The precise reading position refers to an unverified page.", index)
    end
end

local function capture(pages, episode_id, revision)
    episode_id, revision = identity(episode_id), identity(revision)
    assert(pages.store.root == pages.root and pages.store.account_key == pages.account_key)
    local jobs = assertIdle(pages, episode_id, revision)
    local descriptor, path = pages.store:getDescriptor(episode_id, revision)
    if not descriptor or not path then fail("storage", "missing_descriptor", "The local chapter descriptor is missing.") end
    assert(descriptor.account_key == pages.account_key and descriptor.episode_id == episode_id and descriptor.revision == revision)
    assert(equal(pages:readDescriptor(path), descriptor))
    local descriptor_bytes = Files.read(path, 4 * 1024 * 1024)
    assert(descriptor_bytes == Codec.canonical(descriptor) .. "\n")
    local basis = { schema_version = 1, root = pages.root, account_key = pages.account_key,
        episode_id = episode_id, revision = revision, descriptor = Codec.copy(descriptor), path = path,
        descriptor_bytes = descriptor_bytes, descriptor_identity = fileIdentity(path, pages.documents_root),
        anchor = pages.store:getAnchor(episode_id, revision), pinned = pages.store:isPinned(episode_id, revision),
        jobs = jobs, pages = {} }
    local records = pages.store:listPages(episode_id, revision)
    assert(#records == #descriptor.pages)
    for index, page in ipairs(records) do
        assert(page.index == index and page.id == descriptor.pages[index].id
            and page.episode_id == episode_id and page.revision == revision)
        assert(page.state == "ready" or page.state == "missing" or page.state == "failed")
        assert(generation(page.content_generation) and generation(page.geometry_generation))
        assert(generation((page.extra or {}).source_generation or 0))
        local kind, checksum = history(page, index)
        local item = { record = Codec.copy(page), history = kind, checksum = checksum }
        if page.state == "ready" then item.reference_identity = fileIdentity(page.path, pages.pages_root) end
        basis.pages[index] = item
    end
    assertAnchor(basis)
    return basis
end

function SourceRefresh.capture(pages, episode_id, revision)
    return attempt(function()
        assert(pages.store._depth == 0, "Capture must own its read transaction")
        local basis = pages.store:transaction(function() return capture(pages, episode_id, revision) end)
        captures[basis] = { owner = pages, seal = canonical(basis) }
        return basis
    end)
end

local function validateIndex(basis, index)
    if type(index) ~= "table" or tostring(index.episode_id) ~= basis.episode_id
        or index.comic_id ~= nil and tostring(index.comic_id) ~= basis.descriptor.comic_id then
        fail("content_changed", "index_identity", "The refreshed index does not match this chapter.")
    end
    local images, count = index.images or index.pages, 0
    if type(images) ~= "table" or #images ~= #basis.pages then
        fail("content_changed", "index_topology", "The refreshed chapter has a different page topology.")
    end
    for _ in pairs(images) do count = count + 1 end
    if count ~= #basis.pages then fail("content_changed", "index_topology", "The refreshed page list is not a dense array.") end
    local paths, seen = {}, {}
    for number = 1, #basis.pages do
        local image, old = images[number], basis.descriptor.pages[number]
        if type(image) ~= "table" or image.index ~= number or (image.width or image.x) ~= old.width
            or (image.height or image.y) ~= old.height then
            fail("content_changed", "index_topology", "The refreshed page order or declared geometry changed.", number)
        end
        local path = image.path
        if type(path) ~= "string" or path == "" or #path > 8192 or seen[path]
            or path:find("[%z\r\n]") or path:find("[?&]token=") then
            fail("content_changed", "index_paths", "The refreshed source paths are invalid or repeated.", number)
        end
        paths[number], seen[path] = path, true
    end
    return paths
end

function SourceRefresh.validateIndex(basis, index)
    return attempt(function() return validateIndex(basis, index) end, "content_changed", "invalid_index")
end

function SourceRefresh.adopt(pages, basis, index, proofs)
    return attempt(function()
        local captured = captures[basis]
        if not captured or captured.owner ~= pages or captured.seal ~= canonical(basis) then
            fail("stale_source_refresh", "invalid_basis", "Capture a new local basis before refreshing sources.")
        end
        local paths = validateIndex(basis, index)
        local verified = 0
        if type(proofs) ~= "table" then fail("content_changed", "missing_proofs", "Historical page verification is missing.") end
        for key in pairs(proofs) do
            if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #basis.pages then
                fail("content_changed", "invalid_proofs", "The verification set contains an unrelated page.")
            end
        end
        for number, item in ipairs(basis.pages) do
            local proof = proofs[number]
            if item.history == "committed" then
                if type(proof) ~= "table" or digest(proof.checksum) ~= item.checksum then
                    fail("content_changed", "checksum_mismatch", "A historical page did not match the refreshed image.", number)
                end
                if item.reference_identity and not SourceRefresh.sameFileIdentity(proof.reference_identity, item.reference_identity) then
                    fail("content_changed", "reference_changed", "The retained reference file was not verified against this basis.", number)
                end
                verified = verified + 1
            elseif proof ~= nil then
                fail("content_changed", "unexpected_proof", "A never-committed page cannot acquire a fabricated history proof.", number)
            end
        end
        assert(pages.store._depth == 0, "Source adoption must own its transaction")
        local summary = pages.store:transaction(function()
            local current = capture(pages, basis.episode_id, basis.revision)
            if not equal(current, basis) then
                fail("stale_source_refresh", "basis_changed", "The chapter changed while its sources were being verified.")
            end
            local generations = {}
            for number, item in ipairs(current.pages) do
                local page = item.record
                page.extra = page.extra or {}
                local next_generation = (page.extra.source_generation or 0) + 1
                page.extra.source_path = paths[number]
                page.extra.source_generation = next_generation
                if item.checksum then page.extra.expected_source_checksum = item.checksum end
                pages.store:putPage(page)
                generations[number] = next_generation
            end
            return { episode_id = basis.episode_id, revision = basis.revision,
                updated_pages = #current.pages, verified_pages = verified, source_generations = generations }
        end)
        captures[basis] = nil
        return summary
    end)
end

return SourceRefresh
