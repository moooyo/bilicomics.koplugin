local sqlite = require("lua-ljsqlite3/init")
local Codec = require("bilicomics/storage/codec")
local Files = require("bilicomics/storage/files")
local Migrations = require("bilicomics/storage/migrations")
local ffi = require("ffi")
require("ffi/posix_h")

local Store = {}
Store.__index = Store
local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end
local function id(value) return tostring(assert(value, "Missing identity")) end
local function merge(old, new)
    old = old or {}
    for key, value in pairs(new) do old[key] = value end
    return old
end
local function normalizeReferences(record)
    for _, key in ipairs({ "episode_id", "comic_id", "revision", "latest_episode_id", "last_episode_id" }) do
        if record[key] ~= nil then record[key] = id(record[key]) end
    end
    if record.episode_ids then
        for index, value in ipairs(record.episode_ids) do record.episode_ids[index] = id(value) end
    end
    return record
end

function Store.open(options)
    assert(type(options.account_key) == "string", "Account identity is required")
    -- Services resolves the account namespace before constructing storage.
    local root = assert(options.root):gsub("/+$", "")
    Files.mkdir(root)
    local connection = sqlite.open(root .. "/state.sqlite3")
    local ok, err = pcall(function()
        connection:set_busy_timeout(1000)
        connection:exec("PRAGMA foreign_keys=ON")
        connection:exec("PRAGMA synchronous=FULL")
        local wal = options.wal
        if wal == nil then
            local device_ok, device = pcall(require, "device")
            wal = device_ok and device.canUseWAL and device:canUseWAL() or false
        end
        connection:exec(wal and "PRAGMA journal_mode=WAL" or "PRAGMA journal_mode=TRUNCATE")
        Migrations.apply(connection)
    end)
    if not ok then connection:close(); error(err, 0) end
    local self = setmetatable({ root = root, account_key = options.account_key,
        connection = connection, _pid = tonumber(ffi.C.getpid()), _depth = 0 }, Store)
    local identity_ok, identity_err = pcall(function()
        local account = self:getSetting("storage_account_key")
        assert(not account or account == options.account_key, "Database belongs to another account")
        if not account then self:putSetting("storage_account_key", options.account_key) end
    end)
    if not identity_ok then self:close(); error(identity_err, 0) end
    return self
end

function Store:_assertOwner()
    assert(self.connection, "Storage is closed")
    assert(self._pid == tonumber(ffi.C.getpid()), "Inherited SQLite connections cannot be used in workers")
end

function Store:_rows(sql, values)
    self:_assertOwner()
    local statement = self.connection:prepare(sql)
    local ok, rows = pcall(function()
        if values then
            for i = 1, values.n or #values do statement:bind1(i, values[i]) end
        end
        local output = {}
        while true do
            local row, header = statement:step({}, {})
            if not row then break end
            local record = {}
            for i, name in ipairs(header) do
                record[name] = type(row[i]) == "cdata" and tonumber(row[i]) or row[i]
            end
            output[#output + 1] = record
        end
        return output
    end)
    statement:close()
    if not ok then error(rows, 0) end
    return rows
end

function Store:_exec(sql, values) self:_rows(sql, values) end

function Store:close()
    if not self.connection then return end
    self:_assertOwner()
    assert(self._depth == 0, "Cannot close storage in a transaction")
    self.connection:close()
    self.connection = nil
end

function Store:transaction(callback)
    self:_assertOwner()
    local depth = self._depth
    local savepoint = "bilicomics_" .. depth
    self.connection:exec(depth == 0 and "BEGIN IMMEDIATE" or "SAVEPOINT " .. savepoint)
    self._depth = depth + 1
    local results = pack(pcall(callback, self))
    self._depth = depth
    if results[1] then
        local ok, err = pcall(self.connection.exec, self.connection,
            depth == 0 and "COMMIT" or "RELEASE SAVEPOINT " .. savepoint)
        if ok then return unpack(results, 2, results.n) end
        results[1], results[2] = false, err
    end
    local rollback_ok = pcall(self.connection.exec, self.connection,
        depth == 0 and "ROLLBACK" or "ROLLBACK TO SAVEPOINT " .. savepoint)
    if depth > 0 then pcall(self.connection.exec, self.connection, "RELEASE SAVEPOINT " .. savepoint) end
    if not rollback_ok then
        pcall(self.connection.close, self.connection)
        self.connection = nil
    end
    error(results[2], 0)
end

function Store:_record(sql, values)
    local row = self:_rows(sql, values)[1]
    return row and Codec.decode(row.data) or nil
end

function Store:_records(sql, values)
    local records = {}
    for _, row in ipairs(self:_rows(sql, values)) do records[#records + 1] = Codec.decode(row.data) end
    return records
end

function Store:upsertComic(record)
    record = normalizeReferences(merge(self:getComic(record.id), Codec.copy(record)))
    record.id, record.updated_at = id(record.id), record.updated_at or os.time()
    self:_exec("INSERT OR REPLACE INTO comics VALUES(?,?,?,?,?)", pack(record.id,
        record.favorite and 1 or 0, record.last_read_at or 0, record.updated_at, Codec.encode(record)))
    return record
end

function Store:getComic(comic_id)
    return self:_record("SELECT data FROM comics WHERE id=?", { id(comic_id) })
end

function Store:listComics(kind, options)
    options = options or {}
    local sql = "SELECT data FROM comics"
    if kind == "following" or kind == "favorites" then sql = sql .. " WHERE favorite=1"
    elseif kind == "continue" or kind == "history" then sql = sql .. " WHERE last_read_at>0" end
    sql = sql .. ((kind == "continue" or kind == "history") and " ORDER BY last_read_at DESC, id" or " ORDER BY updated_at DESC, id")
    if options.limit then sql = sql .. " LIMIT " .. math.max(0, math.floor(tonumber(options.limit) or 0)) end
    local records = self:_records(sql)
    if not options.query or options.query == "" then return records end
    local output, query = {}, options.query:lower()
    for _, record in ipairs(records) do
        if (record.title or ""):lower():find(query, 1, true) then output[#output + 1] = record end
    end
    return output
end

function Store:upsertEpisodes(comic_id, records)
    return self:transaction(function()
        for _, record in ipairs(records) do
            record = merge(self:getEpisode(record.id), Codec.copy(record))
            record.id, record.comic_id = id(record.id), id(comic_id)
            record.order = assert(tonumber(record.order), "Episode order is required")
            assert(record.order == record.order and math.abs(record.order) < math.huge, "Invalid episode order")
            self:_exec("INSERT OR REPLACE INTO episodes VALUES(?,?,?,?)",
                { record.id, record.comic_id, record.order, Codec.encode(record) })
        end
    end)
end

function Store:getEpisode(episode_id)
    return self:_record("SELECT data FROM episodes WHERE id=?", { id(episode_id) })
end

function Store:listEpisodes(comic_id)
    return self:_records("SELECT data FROM episodes WHERE comic_id=? ORDER BY sort_order, id", { id(comic_id) })
end

function Store:putPage(record)
    record = Codec.copy(record)
    record.episode_id, record.revision = id(record.episode_id), id(record.revision)
    record.index = assert(tonumber(record.index), "Page index is required")
    assert(record.index > 0 and record.index % 1 == 0, "Page index must be a positive integer")
    local key = record.episode_id .. "/" .. record.revision .. "/" .. record.index
    assert(not record.key or record.key == key, "Page key does not match its identity")
    assert(record.state == "missing" or record.state == "ready" or record.state == "failed", "Invalid page state")
    record.key, record.id = key, id(record.id)
    record.content_generation = record.content_generation or 0
    record.geometry_generation = record.geometry_generation or 0
    self:_exec("INSERT OR REPLACE INTO pages VALUES(?,?,?,?,?,?)",
        { key, record.episode_id, record.revision, record.index, record.state, Codec.encode(record) })
    return record
end

function Store:getPage(key) return self:_record("SELECT data FROM pages WHERE page_key=?", { id(key) }) end
function Store:listPages(episode_id, revision)
    return self:_records("SELECT data FROM pages WHERE episode_id=? AND revision=? ORDER BY page_index",
        { id(episode_id), id(revision) })
end
function Store:listAllPages() return self:_records("SELECT data FROM pages ORDER BY page_key") end
function Store:updatePage(key, patch)
    local record = assert(self:getPage(key), "Page does not exist")
    return self:putPage(merge(record, Codec.copy(patch)))
end

local job_states = { queued = true, running = true, paused = true, complete = true, failed = true, canceled = true }
function Store:putJob(record)
    record = normalizeReferences(Codec.copy(record))
    record.id, record.updated_at = id(record.id), record.updated_at or os.time()
    assert(job_states[record.state], "Invalid job state")
    self:_exec("INSERT OR REPLACE INTO jobs VALUES(?,?,?,?,?)",
        { record.id, record.state, record.priority or 0, record.updated_at, Codec.encode(record) })
    return record
end
function Store:getJob(job_id) return self:_record("SELECT data FROM jobs WHERE id=?", { id(job_id) }) end

local function stateFilter(states)
    if not states then return "", nil end
    if type(states) == "string" then states = { states } end
    if #states == 0 then return " WHERE 0", nil end
    local slots = {}
    for i = 1, #states do slots[i] = "?" end
    return " WHERE state IN (" .. table.concat(slots, ",") .. ")", states
end
function Store:listJobs(states)
    local where, values = stateFilter(states)
    return self:_records("SELECT data FROM jobs" .. where .. " ORDER BY priority DESC, updated_at, id", values)
end

function Store:putPurchase(record)
    record = normalizeReferences(Codec.copy(record))
    record.id, record.updated_at = id(record.id), record.updated_at or os.time()
    assert(type(record.state) == "string", "Purchase state is required")
    self:_exec("INSERT OR REPLACE INTO purchases VALUES(?,?,?,?)",
        { record.id, record.state, record.updated_at, Codec.encode(record) })
    return record
end
function Store:getPurchase(purchase_id)
    return self:_record("SELECT data FROM purchases WHERE id=?", { id(purchase_id) })
end
function Store:listPurchases(states)
    local where, values = stateFilter(states)
    return self:_records("SELECT data FROM purchases" .. where .. " ORDER BY updated_at, id", values)
end

function Store:putAnchor(episode_id, revision, record, options)
    return self:transaction(function()
        self:_exec("INSERT OR REPLACE INTO anchors VALUES(?,?,?)", { id(episode_id), id(revision), Codec.encode(record) })
        local episode = self:getEpisode(episode_id)
        local replacement = episode and (episode.extra or {}).source_replacement_revision
        local update_progress = not (type(options) == "table" and options.update_progress == false)
            and (replacement == nil or tostring(replacement) == id(revision))
        -- Retained versions keep their own anchors without changing the current snapshot's progress.
        if episode and update_progress then
            episode.read = record.finished and "finished" or "in_progress"
            self:upsertEpisodes(episode.comic_id, { episode })
            local comic = self:getComic(episode.comic_id)
            if comic then
                comic.last_read_at, comic.last_episode_id = record.updated_at or os.time(), id(episode_id)
                self:upsertComic(comic)
            end
        end
    end)
end
function Store:getAnchor(episode_id, revision)
    return self:_record("SELECT data FROM anchors WHERE episode_id=? AND revision=?", { id(episode_id), id(revision) })
end

function Store:putSetting(key, value)
    self:_exec("INSERT OR REPLACE INTO settings VALUES(?,?)", { id(key), Codec.encode({ value = value }) })
end
function Store:getSetting(key, default)
    local record = self:_record("SELECT data FROM settings WHERE setting_key=?", { id(key) })
    if not record or record.value == nil then return default end
    return record.value
end

function Store:putDescriptor(descriptor, path)
    self:_exec("INSERT OR REPLACE INTO descriptors VALUES(?,?,?,?,?)",
        { descriptor.episode_id, descriptor.revision, descriptor.comic_id, path, Codec.encode(descriptor) })
end
function Store:getDescriptor(episode_id, revision)
    local row = self:_rows("SELECT data, path FROM descriptors WHERE episode_id=? AND revision=?",
        { id(episode_id), id(revision) })[1]
    if row then return Codec.decode(row.data), row.path end
end
function Store:listDescriptors()
    local output = {}
    for _, row in ipairs(self:_rows("SELECT data, path FROM descriptors ORDER BY episode_id, revision")) do
        output[#output + 1] = { descriptor = Codec.decode(row.data), path = row.path }
    end
    return output
end
function Store:setPinned(episode_id, revision, pinned)
    self:_exec("INSERT OR REPLACE INTO pins VALUES(?,?,?)", { id(episode_id), id(revision), pinned and 1 or 0 })
end
function Store:isPinned(episode_id, revision)
    local row = self:_rows("SELECT pinned FROM pins WHERE episode_id=? AND revision=?", { id(episode_id), id(revision) })[1]
    return row ~= nil and row.pinned == 1
end
function Store:putCommit(record)
    self:_exec("INSERT OR REPLACE INTO page_commits VALUES(?,?)", { record.page.key, Codec.encode(record) })
end
function Store:deleteCommit(key) self:_exec("DELETE FROM page_commits WHERE page_key=?", { key }) end
function Store:listCommits() return self:_records("SELECT data FROM page_commits ORDER BY page_key") end

return Store
