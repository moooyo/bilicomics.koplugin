local Codec = require("bilicomics/storage/codec")
local Files = require("bilicomics/storage/files")
local Header = require("bilicomics/storage/image_header")
local lfs = require("libs/libkoreader-lfs")

local PageStore = {}
PageStore.__index = PageStore
local function identity(value)
    value = tostring(assert(value, "Missing descriptor identity"))
    assert(#value > 0 and #value <= 256 and not value:find("[%z/\\]"), "Invalid descriptor identity")
    return value
end
local function positive(value)
    value = tonumber(value)
    assert(value and value > 0 and value < math.huge and value % 1 == 0, "Invalid page geometry")
    return value
end
local function episodeKey(episode_id, revision) return tostring(episode_id) .. "/" .. tostring(revision) end
local function pageKey(episode_id, revision, index) return episodeKey(episode_id, revision) .. "/" .. index end

local function descriptorRecord(input, account_key)
    assert(input.schema_version == 1, "Unsupported descriptor schema")
    assert(input.account_key == account_key, "Descriptor belongs to another account")
    local record = { schema_version = 1, account_key = account_key, comic_id = identity(input.comic_id),
        episode_id = identity(input.episode_id), revision = identity(input.revision), pages = {} }
    assert(type(input.pages) == "table" and #input.pages > 0 and #input.pages <= 10000, "Invalid descriptor page list")
    local count, ids = 0, {}
    for _ in pairs(input.pages) do count = count + 1 end
    assert(count == #input.pages, "Descriptor page list must be dense")
    for index, page in ipairs(input.pages) do
        local source_id = identity(page.id)
        assert(page.index == index, "Descriptor page indexes must be ordered and contiguous")
        assert(not ids[source_id], "Descriptor source image identities must be unique")
        ids[source_id] = true
        record.pages[index] = { id = source_id, index = index, width = positive(page.width), height = positive(page.height) }
    end
    return record
end

function PageStore.new(options)
    local root = assert(options.root):gsub("/+$", "")
    assert(options.store.root == root and options.store.account_key == options.account_key, "Storage namespace mismatch")
    local self = setmetatable({ root = root, account_key = options.account_key, store = options.store,
        active = {}, verified = {}, fault_hook = options.fault_hook,
        clock = options.clock or os.time }, PageStore)
    self.documents_root, self.pages_root, self.temporary_root = root .. "/documents", root .. "/pages", root .. "/temporary"
    Files.mkdir(self.documents_root)
    Files.mkdir(self.pages_root)
    Files.mkdir(self.temporary_root)
    return self
end

function PageStore:ensureDescriptor(input)
    local descriptor = descriptorRecord(input, self.account_key)
    local path = self.documents_root .. "/" .. Files.component(descriptor.comic_id) .. "/"
        .. Files.component(descriptor.episode_id) .. "/" .. Files.component(descriptor.revision) .. "/chapter.bcomic"
    local encoded = Codec.canonical(descriptor) .. "\n"
    local stored = self.store:getDescriptor(descriptor.episode_id, descriptor.revision)
    local descriptor_existed = stored ~= nil or Files.exists(path)
    assert(not stored or Codec.canonical(stored) .. "\n" == encoded, "A content revision cannot change its descriptor")
    if Files.exists(path) then
        Files.assertRegular(path, self.documents_root)
        assert(Files.read(path, 4 * 1024 * 1024) == encoded, "Existing chapter descriptor is immutable")
    else
        Files.atomicWrite(path, encoded, self.documents_root)
    end
    self.store:transaction(function()
        self.store:putDescriptor(descriptor, path)
        for index, source in ipairs(descriptor.pages) do
            if not self.store:getPage(pageKey(descriptor.episode_id, descriptor.revision, index)) then
                self.store:putPage({ key = pageKey(descriptor.episode_id, descriptor.revision, index),
                    episode_id = descriptor.episode_id, revision = descriptor.revision, index = index,
                    id = source.id, width = source.width, height = source.height, state = "missing",
                    content_generation = 0, geometry_generation = 0,
                    extra = not descriptor_existed and { content_history_version = 1 } or nil })
            end
        end
    end)
    return path
end

function PageStore:readDescriptor(path)
    Files.assertRegular(path, self.documents_root)
    return descriptorRecord(Codec.decode(Files.read(path, 4 * 1024 * 1024)), self.account_key)
end

function PageStore:_validFile(path, expected, force)
    local ok, detail = pcall(function()
        Files.assertRegular(path, self.root)
        local attributes = assert(lfs.attributes(path))
        assert(not expected.bytes or attributes.size == expected.bytes, "Cached file size changed")
        local signature = path .. ":" .. attributes.size .. ":" .. attributes.modification .. ":" .. (expected.checksum or "")
        if not force and self.verified[path] == signature then return true end
        local digest, bytes = Files.digest(path)
        assert(expected.checksum and digest == expected.checksum, "Cached image checksum mismatch")
        local header = Header.read(path)
        assert(header.format == expected.format, "Cached image format mismatch")
        if expected.geometry then
            assert(not expected.geometry.source_width or expected.geometry.source_width == header.width,
                "Cached source width mismatch")
            assert(not expected.geometry.source_height or expected.geometry.source_height == header.height,
                "Cached source height mismatch")
        end
        local orientation = expected.geometry and (expected.geometry.exif_orientation or expected.geometry.orientation) or 1
        if header.exif_orientation then
            assert(header.exif_orientation == orientation, "Cached JPEG orientation mismatch")
        end
        local width, height = header.width, header.height
        if orientation >= 5 and orientation <= 8 then width, height = height, width end
        assert(width == expected.width and height == expected.height, "Cached image geometry mismatch")
        assert(bytes == attributes.size, "Cached image size changed during verification")
        self.verified[path] = signature
        return true
    end)
    return ok and detail == true, ok and nil or tostring(detail)
end

function PageStore:_markMissing(page, message, preserve_pending)
    if page.path then self.verified[page.path] = nil end
    local previous_generation = page.content_generation or 0
    if page.checksum then
        page.extra = page.extra or {}
        page.extra.last_committed_checksum = page.checksum
        page.extra.content_history_version = 1
    end
    page.state, page.path, page.bytes, page.checksum = "missing", nil, nil, nil
    page.content_generation = previous_generation + 1
    page.error = message or "Cached page is unavailable"
    if preserve_pending then
        -- Corruption of the old file does not cancel an already verified replacement.
        -- Explicit removal deletes its journal before invalidating the page.
        return self.store:transaction(function()
            local current = self.store:getPage(page.key)
            assert(current and current.id == page.id and current.content_generation == previous_generation,
                "Page changed during corruption invalidation")
            local journal = self.store:_record("SELECT data FROM page_commits WHERE page_key=?", { page.key })
            self.store:putPage(page)
            if journal and journal.base_generation == previous_generation then
                journal.base_generation = page.content_generation
                journal.page.content_generation = page.content_generation + 1
                self.store:putCommit(journal)
            end
            return page
        end)
    end
    return self.store:putPage(page)
end

function PageStore:getPage(episode_id, revision, index)
    local page = self.store:getPage(pageKey(episode_id, revision, index))
    if page and page.state == "ready" then
        local valid, err = self:_validFile(page.path, page)
        if not valid then return self:_markMissing(page, err, true) end
    end
    return page
end

function PageStore:_finishCommit(journal)
    local page = journal.page
    local existing = self.store:getPage(page.key)
    assert(existing and existing.id == page.id, "Commit no longer matches the page identity")
    assert(existing.content_generation == journal.base_generation, "Commit was canceled by a newer page generation")
    self.store:transaction(function()
        self.store:putPage(page)
        self.store:deleteCommit(page.key)
    end)
    if journal.previous_path and journal.previous_path ~= page.path then
        local ok, err = pcall(function()
            if Files.exists(journal.previous_path) then
                Files.assertRegular(journal.previous_path, self.pages_root)
                assert(os.remove(journal.previous_path))
                Files.syncDirectory(Files.parent(journal.previous_path))
            end
        end)
        self.verified[journal.previous_path] = nil
        if not ok then
            self.cleanup_errors = self.cleanup_errors or {}
            self.cleanup_errors[#self.cleanup_errors + 1] = tostring(err)
        end
    end
    return page
end

function PageStore:commitPage(context, result)
    assert(self.store._depth == 0, "Page commits must own their transaction boundary")
    assert(not context.account_key or context.account_key == self.account_key, "Stale account completion")
    if context.is_current then assert(context.is_current(context), "Stale acquisition completion") end
    local episode_id, revision = identity(context.episode_id), identity(context.revision)
    local index = positive(context.index or context.page_index)
    local descriptor = assert(self.store:getDescriptor(episode_id, revision), "Page descriptor is missing")
    local source = assert(descriptor.pages[index], "Page is outside the descriptor")
    local old = assert(self.store:getPage(pageKey(episode_id, revision, index)), "Page state is missing")
    assert(not context.id or context.id == source.id, "Stale image identity")
    assert(not context.expected_content_generation or old.content_generation == context.expected_content_generation,
        "Stale page generation")
    assert(context.expected_source_generation == nil
        or (tonumber((old.extra or {}).source_generation) or 0) == context.expected_source_generation,
        "Stale source generation")
    assert(not self.store:_record("SELECT data FROM page_commits WHERE page_key=?", { old.key }), "Page commit requires recovery")
    local temporary_path = assert(result.temporary_path, "Acquisition result has no temporary file")
    Files.assertRegular(temporary_path, self.temporary_root)
    local checksum = assert(result.checksum, "Acquisition result has no checksum"):lower():gsub("^sha256:", "")
    assert(#checksum == 64 and not checksum:find("[^0-9a-f]"), "A SHA-256 checksum is required")
    assert(not context.expected_checksum or checksum == context.expected_checksum, "Verified source content changed")
    local format = assert(result.format, "Acquisition result has no image format"):lower()
    if format == "jpeg" then format = "jpg" end
    local page = Codec.copy(old)
    page.path = self.pages_root .. "/" .. Files.component(episode_id) .. "/" .. Files.component(revision)
        .. "/" .. Files.component(source.id) .. "-" .. checksum .. "." .. format
    page.width, page.height = positive(result.width), positive(result.height)
    page.geometry, page.format, page.checksum = result.geometry and Codec.copy(result.geometry), format, checksum
    page.extra = page.extra or {}
    page.extra.last_committed_checksum = checksum
    page.extra.content_history_version = 1
    page.bytes = Files.size(temporary_path)
    page.state, page.error, page.last_access_at = "ready", nil, self.clock()
    page.content_generation = (old.content_generation or 0) + 1
    local geometry_changed = old.width ~= page.width or old.height ~= page.height
        or Codec.canonical(old.geometry or {}) ~= Codec.canonical(page.geometry or {})
    page.geometry_generation = (old.geometry_generation or 0) + (geometry_changed and 1 or 0)
    local valid, err = self:_validFile(temporary_path, page, true)
    assert(valid, err)
    Files.syncFile(temporary_path)
    Files.syncDirectory(Files.parent(temporary_path))
    Files.assertContained(page.path, self.pages_root)
    Files.mkdir(Files.parent(page.path))
    local journal = { page = page, temporary_path = temporary_path, previous_path = old.path,
        base_generation = old.content_generation }
    self.store:putCommit(journal)
    if self.fault_hook then self.fault_hook("after_journal", journal) end
    assert(os.rename(temporary_path, page.path))
    Files.syncDirectory(Files.parent(page.path))
    Files.syncDirectory(Files.parent(temporary_path))
    self.verified[temporary_path] = nil
    if self.fault_hook then self.fault_hook("after_rename", journal) end
    local committed = self:_finishCommit(journal)
    if self.fault_hook then self.fault_hook("after_database", journal) end
    return committed
end

function PageStore:pinEpisode(episode_id, revision, pinned)
    assert(self.store:getDescriptor(episode_id, revision), "Cannot pin an unknown descriptor")
    self.store:setPinned(episode_id, revision, pinned)
end

-- Active ownership is independent of durable pins; readers must release it on close.
function PageStore:setActiveEpisode(episode_id, revision, active)
    local key = episodeKey(episode_id, revision)
    local count = self.active[key] or 0
    if active then
        assert(self.store._depth == 0, "Reader activation must own its transaction boundary")
        self.store:transaction(function()
            for _, page in ipairs(self.store:listPages(episode_id, revision)) do
                page.last_access_at = self.clock()
                self.store:putPage(page)
            end
        end)
    end
    self.active[key] = active and count + 1 or math.max(0, count - 1)
end

function PageStore:isComplete(episode_id, revision)
    local descriptor, path = self.store:getDescriptor(episode_id, revision)
    if not descriptor or not Files.exists(path) then return false end
    local descriptor_ok, descriptor_valid = pcall(function()
        Files.assertRegular(path, self.documents_root)
        return Files.read(path, 4 * 1024 * 1024) == Codec.canonical(descriptor) .. "\n"
    end)
    if not descriptor_ok or not descriptor_valid then return false end
    for index in ipairs(descriptor.pages) do
        -- The forced check below already validates the complete file. Avoid a
        -- second cold-cache checksum pass through getPage().
        local page = self.store:getPage(pageKey(episode_id, revision, index))
        if not page or page.state ~= "ready" then return false end
        local valid, err = self:_validFile(page.path, page, true)
        if not valid then self:_markMissing(page, err, true); return false end
    end
    return true
end

-- Safe during unrelated acquisitions: only journal-owned files are accessed.
-- Workers relinquish their temporary file before a journal can be created.
function PageStore:recoverPendingCommits()
    assert(self.store._depth == 0, "Commit recovery must own its transaction boundaries")
    local summary = { recovered = 0, recovered_pages = {}, discarded = 0, remaining = 0, errors = {} }
    for _, journal in ipairs(self.store:listCommits()) do
        local page = journal.page
        local existing = self.store:getPage(page.key)
        local current = existing and existing.id == page.id and existing.content_generation == journal.base_generation
        local final_valid = Files.within(page.path, self.pages_root) and self:_validFile(page.path, page, true)
        local temporary_valid = Files.within(journal.temporary_path, self.temporary_root)
            and self:_validFile(journal.temporary_path, page, true)
        local ok, err = pcall(function()
            assert(current, "Interrupted commit was canceled by a newer page generation")
            assert(final_valid or temporary_valid, "Interrupted commit has no valid image file")
            if not final_valid then
                Files.assertContained(page.path, self.pages_root)
                Files.mkdir(Files.parent(page.path))
                assert(os.rename(journal.temporary_path, page.path))
            end
            Files.syncFile(page.path)
            Files.syncDirectory(Files.parent(page.path))
            Files.syncDirectory(Files.parent(journal.temporary_path))
            local committed = self:_finishCommit(journal)
            summary.recovered = summary.recovered + 1
            summary.recovered_pages[#summary.recovered_pages + 1] = committed
        end)
        if not ok then
            summary.errors[#summary.errors + 1] = { key = page.key, message = tostring(err) }
            if not current or not (final_valid or temporary_valid) then
                self.store:deleteCommit(page.key)
                summary.discarded = summary.discarded + 1
            end
        end
    end
    summary.remaining = #self.store:listCommits()
    return summary
end

-- Reconcile before starting any workers. Interrupted .part files are restarted.
function PageStore:reconcile()
    local recovered = self:recoverPendingCommits()
    local summary = { recovered = recovered.recovered, discarded = recovered.discarded,
        recovered_pages = recovered.recovered_pages, remaining = recovered.remaining, invalidated = 0, removed_temporary = 0,
        removed_orphan = 0, errors = recovered.errors }
    local referenced, pending_temporary = {}, {}
    for _, journal in ipairs(self.store:listCommits()) do
        referenced[journal.page.path] = true
        if journal.previous_path then referenced[journal.previous_path] = true end
        pending_temporary[journal.temporary_path] = true
    end
    for _, page in ipairs(self.store:listAllPages()) do
        if page.state == "ready" then
            local valid, err = self:_validFile(page.path, page, true)
            if valid then referenced[page.path] = true
            else self:_markMissing(page, err, true); summary.invalidated = summary.invalidated + 1 end
        end
    end
    for _, entry in ipairs(self.store:listDescriptors()) do
        local ok, err = pcall(self.ensureDescriptor, self, entry.descriptor)
        if not ok then summary.errors[#summary.errors + 1] = { path = entry.path, message = tostring(err) } end
    end
    Files.walk(self.pages_root, function(path)
        if not referenced[path] then
            assert(os.remove(path))
            summary.removed_orphan = summary.removed_orphan + 1
        end
    end)
    Files.walk(self.temporary_root, function(path)
        if not pending_temporary[path] then
            assert(os.remove(path))
            summary.removed_temporary = summary.removed_temporary + 1
        end
    end)
    return summary
end

function PageStore:_protected(page)
    return (self.active[episodeKey(page.episode_id, page.revision)] or 0) > 0
        or (self.source_refresh_locks and self.source_refresh_locks[episodeKey(page.episode_id, page.revision)] ~= nil)
        or (self.version_replacement_locks and self.version_replacement_locks[episodeKey(page.episode_id, page.revision)] ~= nil)
        or self.store:isPinned(page.episode_id, page.revision)
        or self.store:_record("SELECT data FROM page_commits WHERE page_key=?", { page.key }) ~= nil
end

function PageStore:_evict(page)
    local path, bytes = page.path, page.bytes or Files.size(page.path) or 0
    self:_markMissing(page, "Page was removed from the local cache")
    if path and Files.within(path, self.pages_root) and Files.exists(path) then
        Files.assertRegular(path, self.pages_root)
        assert(os.remove(path))
        Files.syncDirectory(Files.parent(path))
    end
    return bytes
end

-- The limit applies only to automatic files; pinned and active pages are exempt.
function PageStore:evictToLimit(limit)
    limit = assert(tonumber(limit), "Cache byte limit is required")
    assert(limit >= 0, "Cache limit cannot be negative")
    local candidates, automatic_bytes = {}, 0
    for _, page in ipairs(self.store:listAllPages()) do
        if page.state == "ready" and not self.store:isPinned(page.episode_id, page.revision) then
            automatic_bytes = automatic_bytes + (page.bytes or 0)
            if not self:_protected(page) then candidates[#candidates + 1] = page end
        end
    end
    table.sort(candidates, function(a, b)
        if (a.last_access_at or 0) == (b.last_access_at or 0) then return a.key < b.key end
        return (a.last_access_at or 0) < (b.last_access_at or 0)
    end)
    local removed, freed = 0, 0
    for _, page in ipairs(candidates) do
        if automatic_bytes <= limit then break end
        local bytes = self:_evict(page)
        automatic_bytes, freed, removed = automatic_bytes - bytes, freed + bytes, removed + 1
    end
    return { removed_pages = removed, freed_bytes = freed, remaining_bytes = automatic_bytes,
        protected_over_limit = automatic_bytes > limit }
end

function PageStore:clearAutomaticCache() return self:evictToLimit(0) end

-- Explicit removal preserves descriptor identity and reading anchors.
function PageStore:removeEpisode(episode_id, revision)
    assert((self.active[episodeKey(episode_id, revision)] or 0) == 0, "Close the chapter before removing its files")
    local removed, freed, files = 0, 0, {}
    self.store:transaction(function()
        self.store:setPinned(episode_id, revision, false)
        for _, page in ipairs(self.store:listPages(episode_id, revision)) do
            if page.state == "ready" then
                freed, removed = freed + (page.bytes or 0), removed + 1
                files[page.path] = self.pages_root
            end
            local journal = self.store:_record("SELECT data FROM page_commits WHERE page_key=?", { page.key })
            if journal then
                files[journal.page.path], files[journal.temporary_path] = self.pages_root, self.temporary_root
                self.store:deleteCommit(page.key)
            end
            self:_markMissing(page, "Chapter download was removed")
        end
    end)
    for path, root in pairs(files) do
        if Files.exists(path) then
            Files.assertRegular(path, root)
            assert(os.remove(path))
            Files.syncDirectory(Files.parent(path))
        end
    end
    return { removed_pages = removed, freed_bytes = freed }
end

function PageStore:getSummary()
    local summary = { total_bytes = 0, automatic_bytes = 0, pinned_bytes = 0, temporary_bytes = 0,
        ready_pages = 0, missing_pages = 0, failed_pages = 0, complete_episodes = 0,
        pinned_episodes = 0, partial_episodes = 0, absent_episodes = 0 }
    for _, entry in ipairs(self.store:listDescriptors()) do
        local descriptor = entry.descriptor
        if self.store:isPinned(descriptor.episode_id, descriptor.revision) then summary.pinned_episodes = summary.pinned_episodes + 1 end
        if self:isComplete(descriptor.episode_id, descriptor.revision) then
            summary.complete_episodes = summary.complete_episodes + 1
        else
            local has_content = false
            for _, page in ipairs(self.store:listPages(descriptor.episode_id, descriptor.revision)) do
                has_content = has_content or page.state == "ready"
            end
            local category = has_content and "partial_episodes" or "absent_episodes"
            summary[category] = summary[category] + 1
        end
    end
    for _, page in ipairs(self.store:listAllPages()) do
        if page.state == "ready" then
            summary.ready_pages = summary.ready_pages + 1
            summary.total_bytes = summary.total_bytes + (page.bytes or 0)
            local category = self.store:isPinned(page.episode_id, page.revision) and "pinned_bytes" or "automatic_bytes"
            summary[category] = summary[category] + (page.bytes or 0)
        elseif page.state == "failed" then summary.failed_pages = summary.failed_pages + 1
        else summary.missing_pages = summary.missing_pages + 1 end
    end
    Files.walk(self.temporary_root, function(path) summary.temporary_bytes = summary.temporary_bytes + (Files.size(path) or 0) end)
    return summary
end

return PageStore
