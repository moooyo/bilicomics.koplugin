local Catalog = {}
Catalog.__index = Catalog

local private_fields = {
    cookie = true, cookies = true, authorization = true, auth = true, session = true, sessionid = true,
    sessdata = true, bilijct = true, token = true, accesstoken = true,
    refreshtoken = true, csrftoken = true, privatekey = true, secret = true,
    signedurl = true, completeurl = true, ultrasign = true, bytesdata = true,
    m1 = true, m2 = true, credentials = true, password = true, apikey = true,
    accesskey = true, secretkey = true, sign = true, signature = true, csrf = true, xsrf = true,
}
local local_fields = {
    current_revision = true, local_revision = true, descriptor = true,
    current_episode_id = true, last_episode_id = true, last_read_at = true,
    reading_position = true, progress_source = true, downloaded = true,
    download_state = true, cached_pages = true, cached_complete = true, total_pages = true,
    offline_allowed = true,
}
local comic_fields = {
    "id", "title", "authors", "cover_url", "latest_episode_id", "latest_order",
    "latest_episode_title", "favorite", "finished", "updated_at",
}
local episode_fields = {
    "id", "comic_id", "order", "title", "short_title", "access", "expires_at", "pay_gold", "read",
}
local access_values = { free = true, owned = true, temporary = true, locked = true, unavailable = true, unknown = true }
local active_jobs = { queued = true, running = true, paused = true, failed = true }
local credential_queries = { "token", "access_token", "signature", "sign", "auth_key", "wssecret", "ultra_sign" }

local function public(value, seen)
    if type(value) == "string" then
        local lower = value:lower()
        if lower:find("sessdata=", 1, true) or lower:find("bili_jct=", 1, true)
            or ((lower:match("^https?://") or lower:match("^/")) and lower:find("?", 1, true)) then return nil end
        for _, key in ipairs(credential_queries) do
            if lower:find("[?&]" .. key .. "=") then return nil end
        end
        return value
    end
    if type(value) == "number" then
        if value ~= value or math.abs(value) == math.huge then return nil end
        return value
    end
    if type(value) ~= "table" then
        if type(value) == "boolean" then return value end
        return nil
    end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do
        local normalized = tostring(key):lower():gsub("[_%-]", "")
        if not private_fields[normalized] and not normalized:find("token", 1, true) then
            result[key] = public(item, seen)
        end
    end
    seen[value] = nil
    return result
end

local function localField(key)
    return local_fields[key] or tostring(key):match("^local_") or tostring(key):match("^source_")
end

local function mergeExtra(old, incoming)
    local result = public(old) or {}
    for key, value in pairs(public(incoming) or {}) do
        if not localField(key) then
            if type(value) == "table" and type(result[key]) == "table" then
                result[key] = mergeExtra(result[key], value)
            else result[key] = value end
        end
    end
    return result
end

local function identity(value)
    if value == nil then return nil end
    value = tostring(value)
    if value == "" or value == "0" then return nil end
    return value
end

local function finite(value)
    value = tonumber(value)
    if value and value == value and math.abs(value) < math.huge then return value end
end

local function timestamp(value)
    value = finite(value)
    if value and value > 100000000000 then value = value / 1000 end
    return value and value > 0 and value or nil
end

local function first(...)
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if value ~= nil then return value end
    end
end

local function selected(input, fields)
    local result = {}
    for _, key in ipairs(fields) do result[key] = public(input[key]) end
    return result
end

local function access(episode, now)
    local value = access_values[episode.access] and episode.access or "unknown"
    local expiry = finite(episode.expires_at)
    if value == "temporary" or (value == "owned" and expiry and expiry > 0) then
        if not expiry then return "unknown" end
        return expiry > now and "temporary" or "locked"
    end
    return value
end

local function complete(read)
    return read == true or read == "read" or read == "finished" or read == "complete"
end

local function replacementRevision(episode)
    return identity(episode and episode.extra and episode.extra.source_replacement_revision)
end

function Catalog.new(options)
    return setmetatable({ store = assert(options.store), pages = assert(options.pages),
        clock = options.clock or os.time }, Catalog)
end

function Catalog:_snapshot()
    return { descriptors = nil, jobs = nil, anchors = {} }
end

function Catalog:_descriptors(snapshot)
    if snapshot.descriptors then return snapshot.descriptors end
    local grouped = {}
    for _, item in ipairs(self.store:listDescriptors()) do
        local descriptor = item.descriptor
        if descriptor and (not self.store.account_key or descriptor.account_key == self.store.account_key) then
            local id = tostring(descriptor.episode_id)
            grouped[id] = grouped[id] or {}
            grouped[id][#grouped[id] + 1] = item
        end
    end
    snapshot.descriptors = grouped
    return grouped
end

function Catalog:_jobs(snapshot)
    if snapshot.jobs then return snapshot.jobs end
    local grouped = {}
    for _, job in ipairs(self.store:listJobs()) do
        local payload = type(job.payload) == "table" and job.payload or {}
        if job.kind == "episode_download" and job.episode_id and not payload.replaced_by and not payload.removed then
            local id = tostring(job.episode_id)
            grouped[id] = grouped[id] or {}
            grouped[id][#grouped[id] + 1] = job
        end
    end
    for _, jobs in pairs(grouped) do
        table.sort(jobs, function(a, b)
            local at, bt = finite(a.updated_at) or 0, finite(b.updated_at) or 0
            if at == bt then return tostring(a.id) > tostring(b.id) end
            return at > bt
        end)
    end
    snapshot.jobs = grouped
    return grouped
end

function Catalog:_descriptor(episode_id, snapshot)
    episode_id = tostring(episode_id)
    local episode = self.store:getEpisode(episode_id)
    local extra = episode and episode.extra or {}
    local function revision(value)
        if not identity(value) then return end
        local descriptor, path = self.store:getDescriptor(episode_id, value)
        if descriptor and (not episode or tostring(descriptor.comic_id) == tostring(episode.comic_id))
            and (not self.store.account_key or descriptor.account_key == self.store.account_key) then
            return descriptor, path
        end
    end
    for _, key in ipairs({ "current_revision", "local_revision" }) do
        local descriptor, path = revision(extra[key])
        if descriptor then return descriptor, path end
    end
    for _, job in ipairs(self:_jobs(snapshot)[episode_id] or {}) do
        local descriptor, path = revision(job.revision)
        if descriptor then return descriptor, path end
    end
    -- Hash revisions have no temporal ordering. This is only a legacy fallback;
    -- successful index preparation records the authoritative current_revision.
    local descriptors = self:_descriptors(snapshot)[episode_id] or {}
    for index = #descriptors, 1, -1 do
        local item = descriptors[index]
        if not episode or tostring(item.descriptor.comic_id) == tostring(episode.comic_id) then
            return item.descriptor, item.path
        end
    end
end

function Catalog:getDescriptor(episode_id)
    if not identity(episode_id) then return nil end
    return self:_descriptor(episode_id, self:_snapshot())
end

function Catalog:_anchor(episode_id, snapshot)
    episode_id = tostring(episode_id)
    if snapshot.anchors[episode_id] ~= nil then
        local saved = snapshot.anchors[episode_id]
        return saved.anchor, saved.descriptor, saved.isolated
    end
    local selected_anchor, selected_descriptor
    local episode = self.store:getEpisode(episode_id)
    local replacement = replacementRevision(episode)
    local descriptor
    if replacement then
        local candidate = self.store:getDescriptor(episode_id, replacement)
        if candidate and tostring(candidate.comic_id) == tostring(episode.comic_id)
            and (not self.store.account_key or candidate.account_key == self.store.account_key) then descriptor = candidate end
    else
        descriptor = self:_descriptor(episode_id, snapshot)
    end
    if descriptor then
        selected_anchor = self.store:getAnchor(episode_id, descriptor.revision)
        selected_descriptor = selected_anchor and descriptor or nil
    end
    if not replacement then
        for _, item in ipairs(self:_descriptors(snapshot)[episode_id] or {}) do
            local matching_comic = not episode or tostring(item.descriptor.comic_id) == tostring(episode.comic_id)
            local candidate = matching_comic and self.store:getAnchor(episode_id, item.descriptor.revision)
            if candidate and (not selected_anchor
                or (timestamp(candidate.updated_at) or 0) > (timestamp(selected_anchor.updated_at) or 0)) then
                selected_anchor, selected_descriptor = candidate, item.descriptor
            end
        end
    end
    snapshot.anchors[episode_id] = { anchor = selected_anchor, descriptor = selected_descriptor, isolated = replacement ~= nil }
    return selected_anchor, selected_descriptor, replacement ~= nil
end

function Catalog:_localProgress(comic, snapshot)
    local extra = comic.extra or {}
    -- Store.putAnchor writes last_episode_id before the controller observes it.
    -- Prefer that identity to an older server current_episode_id hint.
    for _, key in ipairs({ "last_episode_id", "current_episode_id" }) do
        local id = identity(comic[key])
        if id then
            local episode = self.store:getEpisode(id)
            if episode and tostring(episode.comic_id) == tostring(comic.id) then
                local anchor, descriptor, isolated = self:_anchor(id, snapshot)
                if anchor then return anchor, descriptor end
                if isolated then return nil, nil, true end
            end
        end
    end
    if extra.progress_source == "local" and type(comic.reading_position) == "table" then
        local episode_id = identity(comic.reading_position.episode_id or comic.last_episode_id)
        local episode = episode_id and self.store:getEpisode(episode_id)
        if episode and tostring(episode.comic_id) == tostring(comic.id) and replacementRevision(episode) then
            local anchor, descriptor = self:_anchor(episode_id, snapshot)
            return anchor, descriptor, true
        end
        return comic.reading_position, {
            episode_id = comic.reading_position.episode_id or comic.last_episode_id,
            revision = comic.reading_position.revision,
        }
    end
end

function Catalog:_upsertComic(input, kind, index, snapshot)
    assert(type(input) == "table" and identity(input.id), "Comic identity is required")
    local old = self.store:getComic(input.id) or {}
    local record = selected(input, comic_fields)
    record.id = tostring(input.id)
    record.extra = mergeExtra(old.extra, input.extra)
    record.updated_at = timestamp(record.updated_at) or timestamp(old.updated_at) or self.clock()
    if old.favorite ~= nil then record.favorite = old.favorite end
    if kind == "favorites" then record.favorite = true end
    local anchor, _, isolated = self:_localProgress(old, snapshot)
    if kind == "history" and not anchor and not isolated and (old.extra or {}).progress_source ~= "local" then
        local extra = input.extra or {}
        local current_id = identity(first(input.current_episode_id, input.last_episode_id,
            extra.current_episode_id, extra.last_episode_id, extra.last_read_ep_id, extra.read_ep_id))
        local read_at = timestamp(first(input.last_read_at, extra.last_read_at, extra.last_read_time, extra.read_time))
        record.last_read_at = read_at or timestamp(old.last_read_at) or math.max(1, self.clock() - (index or 1) + 1)
        if current_id then record.current_episode_id, record.last_episode_id = current_id, current_id end
        record.extra.progress_source = "server"
        -- Server history is chapter-level. Only the native reader creates precise anchors.
    end
    return self.store:upsertComic(record)
end

function Catalog:ingestLibrary(kind, comics)
    kind = kind == "following" and "favorites" or kind == "continue" and "history" or kind
    assert(kind == "favorites" or kind == "history", "Unknown library kind")
    assert(type(comics) == "table", "Comic list is required")
    local snapshot = self:_snapshot()
    self.store:transaction(function()
        if kind == "favorites" then
            local present = {}
            for _, comic in ipairs(comics) do present[tostring(assert(comic.id))] = true end
            for _, comic in ipairs(self.store:listComics("favorites")) do
                if not present[tostring(comic.id)] then
                    comic.favorite = false
                    self.store:upsertComic(comic)
                end
            end
        end
        for index, comic in ipairs(comics) do self:_upsertComic(comic, kind, index, snapshot) end
    end)
    return self:getLibrary(kind)
end

function Catalog:ingestSearch(comics)
    assert(type(comics) == "table", "Comic list is required")
    local snapshot, ids = self:_snapshot(), {}
    self.store:transaction(function()
        for index, comic in ipairs(comics) do
            ids[index] = self:_upsertComic(comic, "search", index, snapshot).id
        end
    end)
    local result = {}
    for _, id in ipairs(ids) do result[#result + 1] = self:_comic(self.store:getComic(id), snapshot) end
    return result
end

function Catalog:ingestDetail(detail)
    assert(type(detail) == "table" and type(detail.comic) == "table", "Normalized comic detail is required")
    assert(type(detail.episodes) == "table", "Normalized episode list is required")
    local snapshot, comic_id = self:_snapshot(), tostring(assert(detail.comic.id))
    self.store:transaction(function()
        self:_upsertComic(detail.comic, "detail", nil, snapshot)
        local episodes = {}
        for _, input in ipairs(detail.episodes) do
            assert(identity(input.id), "Episode identity is required")
            assert(not input.comic_id or tostring(input.comic_id) == comic_id, "Episode belongs to another comic")
            local old = self.store:getEpisode(input.id) or {}
            assert(not old.comic_id or tostring(old.comic_id) == comic_id, "Episode identity cannot change comics")
            local record = selected(input, episode_fields)
            record.id, record.comic_id = tostring(input.id), comic_id
            record.order = finite(input.order) or finite(old.order) or 0
            record.access = access(input, self.clock())
            record.expires_at = finite(input.expires_at) or 0
            record.extra = mergeExtra(old.extra, input.extra)
            record.extra.offline_allowed = record.access == "owned" or record.access == "free"
            local anchor = self:_anchor(record.id, snapshot)
            if anchor then record.read = anchor.finished and "finished" or "in_progress"
            elseif replacementRevision(record) then record.read = false
            elseif old.read == "in_progress" or old.read == "finished" or old.read == "reading"
                or (old.extra or {}).progress_source == "local" then record.read = old.read end
            episodes[#episodes + 1] = record
        end
        self.store:upsertEpisodes(comic_id, episodes)
    end)
    return { comic = self:getComic(comic_id), episodes = self:getEpisodes(comic_id) }
end

function Catalog:_comic(record, snapshot)
    if not record then return nil end
    record = public(record)
    record.extra = record.extra or {}
    local episodes = self.store:listEpisodes(record.id)
    local latest
    for _, episode in ipairs(episodes) do
        if not record.latest_episode_id and (not latest
            or (finite(episode.order) or 0) > (finite(latest.order) or 0)) then latest = episode end
        if record.latest_episode_id and tostring(episode.id) == tostring(record.latest_episode_id) then
            latest = episode
            break
        end
    end
    record.latest_episode_title = record.latest_episode_title or record.extra.latest_episode_title
        or record.extra.latest_ep_title or (latest and (latest.short_title or latest.title))
    if not record.latest_episode_id and latest then record.latest_episode_id = tostring(latest.id) end
    if not record.latest_order and latest then record.latest_order = finite(latest.order) end
    local anchor, descriptor, isolated = self:_localProgress(record, snapshot)
    if anchor and descriptor then
        record.current_episode_id, record.last_episode_id = tostring(descriptor.episode_id), tostring(descriptor.episode_id)
        record.reading_position = public(anchor)
        record.reading_position.episode_id, record.reading_position.revision = descriptor.episode_id, descriptor.revision
        record.reading_position.page = record.reading_position.index or record.reading_position.page
        record.extra.progress_source = "local"
    else
        if isolated then record.reading_position = nil end
        record.current_episode_id = identity(record.current_episode_id or record.last_episode_id)
    end
    local current
    for _, episode in ipairs(episodes) do
        if tostring(episode.id) == tostring(record.current_episode_id) then current = episode; break end
    end
    local latest_order, current_order = finite(record.latest_order), current and finite(current.order)
    if latest_order and current_order then record.has_update = latest_order > current_order
    elseif record.latest_episode_id and record.current_episode_id then
        record.has_update = tostring(record.latest_episode_id) ~= tostring(record.current_episode_id)
    else record.has_update = record.extra.has_update == true or record.extra.has_update == 1 end
    record.extra.current_episode_id = record.current_episode_id
    record.extra.reading_position = record.reading_position
    record.extra.latest_episode_title, record.extra.has_update = record.latest_episode_title, record.has_update
    return record
end

function Catalog:getComic(comic_id)
    if not identity(comic_id) then return nil end
    return self:_comic(self.store:getComic(comic_id), self:_snapshot())
end

function Catalog:getLibrary(kind, query)
    local result, snapshot = {}, self:_snapshot()
    if type(query) == "table" then query = query.query end
    for _, comic in ipairs(self.store:listComics(kind, { query = query })) do
        result[#result + 1] = self:_comic(comic, snapshot)
    end
    return result
end

function Catalog:getEpisodes(comic_id)
    local result, snapshot = {}, self:_snapshot()
    local comic = self:_comic(self.store:getComic(comic_id), snapshot) or {}
    for _, source in ipairs(self.store:listEpisodes(comic_id)) do
        local episode = public(source)
        episode.extra = episode.extra or {}
        episode.access = access(episode, self.clock())
        episode.offline_allowed = episode.access == "owned" or episode.access == "free"
        episode.current = tostring(episode.id) == tostring(comic.current_episode_id)
        local anchor = self:_anchor(episode.id, snapshot)
        if anchor then episode.read = anchor.finished and "complete" or "reading"
        elseif replacementRevision(episode) then episode.read = false
        elseif complete(episode.read) then episode.read = "complete"
        elseif episode.read == "in_progress" then episode.read = "reading"
        else episode.read = episode.read == "reading" and "reading" or false end
        local descriptor = self:_descriptor(episode.id, snapshot)
        local ready, total = 0, descriptor and #descriptor.pages or 0
        if descriptor then
            for _, page in ipairs(self.store:listPages(episode.id, descriptor.revision)) do
                local expected = descriptor.pages[page.index]
                if expected and expected.id == page.id and page.state == "ready" then ready = ready + 1 end
            end
        end
        local job
        for _, candidate in ipairs(self:_jobs(snapshot)[tostring(episode.id)] or {}) do
            if not descriptor or (not candidate.revision and not replacementRevision(episode))
                or tostring(candidate.revision) == tostring(descriptor.revision) then
                job = candidate
                break
            end
        end
        if total == 0 and job then total = math.max(0, math.floor(finite(job.total) or 0)) end
        episode.cached_pages, episode.total_pages = ready, total
        episode.cached_complete = descriptor ~= nil and total > 0 and ready == total
        episode.downloaded = episode.offline_allowed and episode.cached_complete
            and self.store:isPinned(episode.id, descriptor.revision) == true
        if episode.downloaded then episode.download_state = "complete"
        elseif episode.cached_complete then episode.download_state = "cached"
        elseif job and active_jobs[job.state] then episode.download_state = job.state
        else episode.download_state = ready > 0 and "partial" or "none" end
        for _, key in ipairs({ "offline_allowed", "downloaded", "download_state", "cached_complete", "cached_pages", "total_pages" }) do
            episode.extra[key] = episode[key]
        end
        result[#result + 1] = episode
    end
    return result
end

function Catalog:updatePosition(descriptor, anchor)
    assert(type(descriptor) == "table" and identity(descriptor.comic_id)
        and identity(descriptor.episode_id) and identity(descriptor.revision), "Descriptor identity is required")
    assert(not self.store.account_key or descriptor.account_key == self.store.account_key,
        "Descriptor belongs to another account")
    assert(type(anchor) == "table", "Reading anchor is required")
    local record = public(anchor)
    local index = finite(record.index or record.page)
    if record.page_id then
        index = nil
        for number, page in ipairs(descriptor.pages or {}) do
            if tostring(page.id) == tostring(record.page_id) then index = number; break end
        end
    end
    assert(index and index > 0 and index % 1 == 0 and descriptor.pages[index], "Anchor is outside its descriptor")
    record.schema_version, record.index, record.page_id = 1, index, descriptor.pages[index].id
    record.updated_at = self.clock()
    local comic_id, episode_id, revision = tostring(descriptor.comic_id), tostring(descriptor.episode_id), tostring(descriptor.revision)
    self.store:transaction(function()
        local comic = self.store:getComic(comic_id) or { id = comic_id, title = "" }
        local episode = self.store:getEpisode(episode_id) or { id = episode_id, comic_id = comic_id, order = 0, access = "unknown" }
        assert(tostring(episode.comic_id) == comic_id, "Episode belongs to another comic")
        local previous = self.store:getAnchor(episode_id, revision)
        if record.finished == nil and previous and previous.finished then record.finished = true end
        local replacement = replacementRevision(episode)
        if replacement and replacement ~= revision then
            self.store:putAnchor(episode_id, revision, record, { update_progress = false })
            return
        end
        episode.extra = public(episode.extra) or {}
        episode.extra.local_revision, episode.extra.progress_source = revision, "local"
        episode.extra.current_revision = episode.extra.current_revision or revision
        self.store:upsertComic(comic)
        self.store:upsertEpisodes(comic_id, { episode })
        self.store:putAnchor(episode_id, revision, record)
        comic = self.store:getComic(comic_id)
        comic.last_read_at, comic.current_episode_id, comic.last_episode_id = record.updated_at, episode_id, episode_id
        comic.reading_position = public(record)
        comic.reading_position.episode_id, comic.reading_position.revision = episode_id, revision
        comic.reading_position.page = index
        comic.extra = public(comic.extra) or {}
        comic.extra.progress_source = "local"
        self.store:upsertComic(comic)
    end)
    return self:getComic(comic_id)
end

return Catalog
