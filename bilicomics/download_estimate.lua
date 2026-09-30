local Files = require("bilicomics/storage/files")

local DownloadEstimate = {}

local function positiveInteger(value)
    value = tonumber(value)
    if value and value == value and value > 0 and value < math.huge and value % 1 == 0 then return value end
end

local function identity(value)
    if type(value) == "number" then
        if not positiveInteger(value) then return nil end
    elseif type(value) ~= "string" then return nil end
    value = tostring(value)
    if value == "" or #value > 256 or value:find("[%z/\\]") then return nil end
    return value
end

local function episodeIdentity(value)
    local value = identity(value)
    return value ~= "0" and value or nil
end

local function read(object, method, ...)
    local ok, value = pcall(object[method], object, ...)
    if ok then return value end
end

local function namespace(account)
    if type(account) ~= "table" or type(account.store) ~= "table" or type(account.pages) ~= "table"
        or type(account.catalog) ~= "table" then return nil end
    local store, pages = account.store, account.pages
    local key = account.key or store.account_key
    if type(key) ~= "string" or key == "" or key ~= store.account_key or key ~= pages.account_key
        or account.catalog.store ~= store or account.catalog.pages ~= pages
        or type(pages.pages_root) ~= "string" or pages.pages_root == "" then return nil end
    return key
end

local function descriptor(account, value, comic_id, episode_id, revision)
    if type(value) ~= "table" or value.schema_version ~= 1 or value.account_key ~= namespace(account)
        or identity(value.comic_id) ~= comic_id or episodeIdentity(value.episode_id) ~= episode_id
        or not identity(value.revision) or (revision and identity(value.revision) ~= revision)
        or type(value.pages) ~= "table" then return nil end
    local total, count, ids = #value.pages, 0, {}
    if total == 0 or total > 10000 then return nil end
    for _ in pairs(value.pages) do count = count + 1 end
    if count ~= total then return nil end
    for index, page in ipairs(value.pages) do
        local page_id = type(page) == "table" and identity(page.id)
        if not page_id or page.index ~= index or ids[page_id]
            or not positiveInteger(page.width) or not positiveInteger(page.height) then return nil end
        ids[page_id] = true
    end
    return value
end

local function currentDescriptor(account, episode, comic_id, retired)
    local episode_id = episodeIdentity(episode.id)
    local extra = type(episode.extra) == "table" and episode.extra or {}
    local current = extra.source_replacement_revision or extra.current_revision or extra.local_revision
    local revision = current ~= nil and identity(current) or nil
    if current ~= nil and not revision then return nil end
    local value = read(account.catalog, "getDescriptor", episode_id)
    if type(value) == "table" and retired[episode_id .. "/" .. tostring(value.revision)] then return nil end
    return descriptor(account, value, comic_id, episode_id, revision)
end

local function observed(account, value)
    local records = read(account.store, "listPages", value.episode_id, value.revision)
    if type(records) ~= "table" then return nil end
    local bytes, count, seen = 0, 0, {}
    for _, page in ipairs(records) do
        local index = type(page) == "table" and positiveInteger(page.index)
        local expected = index and value.pages[index]
        if expected and not seen[index] and page.state == "ready"
            and episodeIdentity(page.episode_id) == episodeIdentity(value.episode_id)
            and identity(page.revision) == identity(value.revision)
            and identity(page.id) == identity(expected.id)
            and type(page.bytes) == "number" and positiveInteger(page.bytes) then
            local ok, size = pcall(function()
                Files.assertRegular(page.path, account.pages.pages_root)
                return Files.size(page.path)
            end)
            if ok and positiveInteger(size) and page.bytes == size and bytes + size < math.huge then
                bytes, count, seen[index] = bytes + size, count + 1, true
            end
        end
    end
    return bytes, count, #value.pages
end

local function declaredPages(episode)
    local extra = type(episode.extra) == "table" and episode.extra or {}
    return positiveInteger(episode.image_count) or positiveInteger(extra.image_count)
        or positiveInteger(episode.total_pages) or positiveInteger(extra.total_pages)
end

local function selection(input)
    local ids, seen, invalid = {}, {}, 0
    local function add(value)
        local id = episodeIdentity(value)
        if not id then invalid = invalid + 1
        elseif not seen[id] then ids[#ids + 1], seen[id] = id, true end
    end
    if input == nil then return ids, invalid end
    if type(input) ~= "table" then return ids, 1 end
    local map = true
    for _, value in pairs(input) do
        if type(value) ~= "boolean" then map = false; break end
    end
    for key, value in pairs(input) do
        if map then
            if value then add(key) end
        elseif type(key) == "string" and type(value) == "boolean" then
            if value then add(key) end
        else add(value) end
    end
    return ids, invalid
end

-- This reports verified local bytes for the explicitly requested immutable revision.
function DownloadEstimate.storedBytes(account, comic_id, episode_id, revision)
    comic_id, episode_id, revision = identity(comic_id), episodeIdentity(episode_id), identity(revision)
    if not namespace(account) or not comic_id or not episode_id or not revision then return nil end
    local value = descriptor(account, read(account.store, "getDescriptor", episode_id, revision),
        comic_id, episode_id, revision)
    if not value then return nil end
    return observed(account, value)
end

-- Current descriptors provide page counts; only matching real files provide size evidence.
function DownloadEstimate.estimate(account, comic_id, episode_ids)
    local ids, invalid = selection(episode_ids)
    local result = { bytes = 0, known_bytes = 0, estimated = false,
        known_chapters = 0, total_chapters = #ids + invalid, descriptors = {} }
    if result.total_chapters == 0 then return result end
    result.bytes, result.estimated = nil, true
    comic_id = identity(comic_id)
    if not namespace(account) or not comic_id then return result end

    local episodes, samples, retired, mean_bytes, mean_pages = {}, {}, {}, 0, 0
    local records = read(account.store, "listEpisodes", comic_id)
    if type(records) ~= "table" then return result end
    local jobs = read(account.store, "listJobs")
    if type(jobs) ~= "table" then return result end
    for _, job in ipairs(jobs) do
        local payload = type(job.payload) == "table" and job.payload or {}
        local episode_id, revision = episodeIdentity(job.episode_id), identity(job.revision)
        if job.kind == "episode_download" and episode_id and revision and payload.replaced_by then
            retired[episode_id .. "/" .. revision] = true
        end
    end
    for _, episode in ipairs(records) do
        local episode_id = type(episode) == "table" and episodeIdentity(episode.id)
        if episode_id and identity(episode.comic_id) == comic_id then
            episodes[episode_id] = episode
            local value = currentDescriptor(account, episode, comic_id, retired)
            local bytes, count, total
            if value then bytes, count, total = observed(account, value) end
            samples[episode_id] = { bytes = bytes, count = count or 0, descriptor = value,
                total = total or (value and #value.pages) or declaredPages(episode) }
            if bytes and count > 0 and mean_bytes + bytes < math.huge then
                mean_bytes, mean_pages = mean_bytes + bytes, mean_pages + count
            end
        end
    end

    local extrapolated = false
    for _, episode_id in ipairs(ids) do
        local sample = episodes[episode_id] and samples[episode_id]
        local bytes
        if sample and sample.count > 0 then
            if sample.count == sample.total then bytes = sample.bytes
            else
                bytes = sample.bytes / sample.count * sample.total
                extrapolated = true
            end
        elseif sample and sample.total and mean_pages > 0 then
            bytes = mean_bytes / mean_pages * sample.total
            extrapolated = true
        end
        if bytes and (bytes ~= bytes or bytes >= math.huge) then bytes = nil end
        if sample and sample.descriptor then
            result.descriptors[episode_id] = { revision = identity(sample.descriptor.revision),
                total_pages = #sample.descriptor.pages, bytes = bytes,
                estimated = sample.count ~= #sample.descriptor.pages }
        end
        if bytes and result.known_bytes + bytes < math.huge then
            result.known_bytes = result.known_bytes + bytes
            result.known_chapters = result.known_chapters + 1
        end
    end
    result.estimated = extrapolated or result.known_chapters < result.total_chapters
    if result.known_chapters == result.total_chapters then result.bytes = result.known_bytes end
    return result
end

return DownloadEstimate
