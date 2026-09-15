-- Account-scoped recharge evidence. This module never performs network I/O or replays creation.
local Service = {}
Service.__index = Service
local maximum_integer = 9007199254740991
local states = { creating = true, pending = true, unknown = true, failed_not_submitted = true, credited = true }
local private_keys = { cookie = true, cookies = true, sessdata = true, bili_jct = true, csrf = true,
    csrf_token = true, access_token = true, refresh_token = true, authorization = true, headers = true,
    session = true, credentials = true, password = true, token = true }

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function failure(kind, message, fields)
    local result = { kind = kind, message = message, retryable = false }
    for key, value in pairs(fields or {}) do result[key] = value end
    return result
end

local function integer(value, positive)
    return type(value) == "number" and value == value and value < math.huge and value <= maximum_integer
        and value % 1 == 0 and value >= (positive and 1 or 0)
end

local function identifier(value)
    return type(value) == "string" and #value > 0 and #value <= 256 and not value:find("[%c%s]") and value or nil
end

local function orderIdentifier(value)
    return type(value) == "string" and #value <= 128 and value:match("^[1-9]%d*$") and value or nil
end

local function printable(value, limit)
    return type(value) == "string" and #value > 0 and #value <= (limit or 8192) and not value:find("%c") and value or nil
end

local function snapshot(value, depth, seen)
    if value == nil or type(value) == "boolean" then return value end
    if type(value) == "string" then return #value <= 8192 and value or nil end
    if type(value) == "number" then return value == value and math.abs(value) < math.huge and value or nil end
    if type(value) ~= "table" or depth > 8 or seen[value] then return nil end
    seen[value] = true
    local result, count = {}, 0
    for key, item in pairs(value) do
        local lower = type(key) == "string" and key:lower() or ""
        local private = private_keys[lower] or lower:find("cookie", 1, true) or lower:find("session", 1, true)
            or lower:find("authorization", 1, true) or lower:find("password", 1, true) or lower:find("credential", 1, true)
        local allowed_key = type(key) == "string" and #key <= 128 and not private
            or integer(key, true)
        if allowed_key then
            count = count + 1
            if count > 256 then break end
            result[key] = snapshot(item, depth + 1, seen)
        end
    end
    seen[value] = nil
    return result
end

local function ordered(journal)
    local result = {}
    for _, record in pairs(journal.orders) do result[#result + 1] = copy(record) end
    table.sort(result, function(left, right)
        if left.sequence ~= right.sequence then return left.sequence > right.sequence end
        return left.id < right.id
    end)
    return result
end

function Service.new(options)
    assert(type(options) == "table" and options.store, "A recharge store is required")
    local account_key = identifier(options.account_key or options.store.account_key)
    assert(account_key, "A recharge account identity is required")
    assert(not options.store.account_key or options.store.account_key == account_key, "Recharge storage belongs to another account")
    return setmetatable({ store = options.store, account_key = account_key, clock = options.clock or os.time,
        setting_key = "recharge.journal.v1:" .. account_key, unpersisted_results = {} }, Service)
end

function Service:_now()
    local value = type(self.clock) == "function" and self.clock() or self.clock:now()
    assert(integer(value, false), "The recharge clock must return a nonnegative integer timestamp")
    return value
end

function Service:_load()
    if self.store.account_key and self.store.account_key ~= self.account_key then
        return nil, failure("account_mismatch", "Recharge storage belongs to another account.")
    end
    local ok, journal, err = pcall(self.store.getSetting, self.store, self.setting_key)
    if not ok or err then return nil, failure("storage", "Recharge records could not be read safely.") end
    if journal == nil then journal = { schema_version = 1, account_key = self.account_key, sequence = 0, orders = {} } end
    if type(journal) ~= "table" or journal.schema_version ~= 1 or journal.account_key ~= self.account_key
        or not integer(journal.sequence, false) or type(journal.orders) ~= "table" then
        return nil, failure("recharge_journal_invalid", "Recharge records require recovery before another order can be created.")
    end
    for key, record in pairs(journal.orders) do
        if type(record) ~= "table" or identifier(key) ~= key or record.id ~= key or record.account_key ~= self.account_key
            or not states[record.state] or not integer(record.sequence, true) or record.sequence > journal.sequence
            or not integer(record.amount_cents, true) or not integer(record.created_at, false)
            or type(record.metadata) ~= "table" or not identifier(record.metadata.confirmation_token)
            or record.order_id ~= nil and orderIdentifier(record.order_id) ~= record.order_id then
            return nil, failure("recharge_journal_invalid", "A saved recharge record is invalid; creation remains blocked.")
        end
    end
    return copy(journal)
end

function Service:_merge(journal)
    for local_id, observed in pairs(self.unpersisted_results) do
        local saved = journal.orders[local_id]
        if saved and saved.order_id and observed.order_id and saved.order_id ~= observed.order_id then
            error(failure("recharge_order_conflict", "Conflicting recharge order identities require review."), 0)
        end
        local retain_saved = saved and (saved.state == "credited" or saved.state == "pending" and observed.state == "unknown")
        journal.orders[local_id] = copy(retain_saved and saved or observed)
        journal.orders[local_id].persistence_pending = nil
        journal.sequence = math.max(journal.sequence, observed.sequence)
    end
    return journal
end

function Service:_public(record)
    local value = copy(self.unpersisted_results[record.id] or record)
    value.qr_expired = value.qr_validated == true and integer(value.expires_at, true) and self:_now() >= value.expires_at or nil
    value.credited_confirmed = value.state == "credited" and value.persistence_pending ~= true
    return value
end

function Service:_publicValue(value)
    if type(value) ~= "table" then return value end
    if value.id then return self:_public(value) end
    local result = {}
    for _, record in ipairs(value) do result[#result + 1] = self:_public(record) end
    return result
end

-- Store.transaction, when present, keeps creation gating and journal replacement in one commit.
-- A failed commit retains observed evidence in memory, never a permission to retransmit.
function Service:_mutate(callback, options)
    options = options or {}
    local changed, candidate, result, operation_error = {}, nil, nil, nil
    local ok, caught = pcall(function()
        if self.store.account_key and self.store.account_key ~= self.account_key then
            error(failure("account_mismatch", "Recharge storage belongs to another account."), 0)
        end
        if (self.store._depth or 0) > 0 then
            error(failure("nested_transaction", "Recharge journal changes require their own durable transaction."), 0)
        end
        local function work()
            local journal, read_error = self:_load()
            if journal then self.cached_journal = copy(journal) end
            if not journal and options.allow_cached and read_error.kind == "storage" then journal = copy(self.cached_journal) end
            if not journal then error(read_error, 0) end
            self:_merge(journal)
            local function put(record)
                record.persistence_pending = nil
                journal.orders[record.id], changed[record.id] = copy(record), copy(record)
            end
            result, operation_error = callback(journal, put)
            candidate = journal
            if read_error then error(read_error, 0) end
            if next(changed) or next(self.unpersisted_results) or options.force then
                local written, write_error = self.store:putSetting(self.setting_key, copy(journal))
                if written == false or write_error then error(failure("storage", "Recharge records could not be saved safely."), 0) end
            end
        end
        if type(self.store.transaction) == "function" then self.store:transaction(work) else work() end
    end)
    if ok then
        if candidate then self.cached_journal = copy(candidate); self.unpersisted_results = {} end
        return self:_publicValue(result), operation_error
    end
    local err = failure(type(caught) == "table" and type(caught.kind) == "string" and caught.kind or "storage",
        "Recharge records could not be safely persisted or loaded.")
    if options.allow_cached and err.kind == "storage" and not candidate and self.cached_journal then
        -- BEGIN itself can fail before the callback runs; retain a response even in that case.
        pcall(function()
            local journal = self:_merge(copy(self.cached_journal))
            result, operation_error = callback(journal, function(record)
                journal.orders[record.id], changed[record.id] = copy(record), copy(record)
            end)
        end)
    end
    for local_id, observed in pairs(changed) do
        if options.preparing then
            observed.state = "failed_not_submitted"
            observed.error = failure("storage", "The order was not dispatched because its confirmation could not be saved.",
                { transmitted = false, definitive = true })
        end
        observed.persistence_pending = true
        self.unpersisted_results[local_id] = observed
    end
    if options.preparing then
        err.transmitted, err.definitive = false, true
        if result then err.local_id = result.id end
        return nil, err
    end
    return self:_publicValue(result), err
end

function Service:list()
    local journal, err = self:_load()
    if journal then self.cached_journal = copy(journal)
    elseif err.kind == "storage" then journal = copy(self.cached_journal) end
    if not journal then return nil, err end
    local ok, merged = pcall(self._merge, self, journal)
    if not ok then return nil, type(merged) == "table" and merged or failure("storage", "Recharge records could not be read safely.") end
    return self:_publicValue(ordered(merged)), err
end

function Service:get(local_id)
    if not identifier(local_id) then return nil, failure("not_found", "The local recharge record was not found.") end
    local records, err = self:list()
    for _, record in ipairs(records or {}) do if record.id == local_id then return record, err end end
    return nil, err or failure("not_found", "The local recharge record was not found.")
end

function Service:prepare(amount_cents, metadata)
    if self.closed then return nil, failure("closed", "The recharge service is closed.", { transmitted = false, definitive = true }) end
    if not integer(amount_cents, true) then return nil, failure("invalid_recharge_amount", "Recharge amount must be a positive integer number of cents.") end
    if type(metadata) ~= "table" or not identifier(metadata.confirmation_token) then
        return nil, failure("confirmation_required", "A fresh explicit recharge confirmation is required.")
    end
    if metadata.account_key and metadata.account_key ~= self.account_key then
        return nil, failure("account_mismatch", "The recharge confirmation belongs to another account.")
    end
    if next(self.unpersisted_results) then
        return nil, failure("persistence_pending", "Save the observed recharge records before creating another order.")
    end
    return self:_mutate(function(journal, put)
        for _, record in pairs(journal.orders) do
            if record.metadata.confirmation_token == metadata.confirmation_token then
                return nil, failure("duplicate_confirmation", "This confirmation has already been consumed; its order must not be recreated.", { local_id = record.id })
            end
            if record.state == "creating" then
                return nil, failure("recharge_busy", "Another recharge order is being created.", { local_id = record.id })
            end
        end
        if journal.sequence >= maximum_integer then return nil, failure("recharge_journal_invalid", "The recharge sequence cannot advance safely.") end
        journal.sequence = journal.sequence + 1
        local now = self:_now()
        local record = { id = "recharge-" .. string.format("%.0f", journal.sequence), sequence = journal.sequence,
            account_key = self.account_key, state = "creating", amount_cents = amount_cents,
            created_at = now, updated_at = now, creation_attempts = 1,
            metadata = { confirmation_token = metadata.confirmation_token,
                config_snapshot = snapshot(metadata.config_snapshot or metadata.config or {}, 0, {}),
                created_at = integer(metadata.created_at, false) and metadata.created_at or now,
                confirmed_at = integer(metadata.confirmed_at, false) and metadata.confirmed_at or now } }
        if journal.orders[record.id] then return nil, failure("recharge_journal_invalid", "The next local recharge identity is already in use.") end
        put(record)
        return record
    end, { preparing = true })
end

function Service:completeCreation(local_id, result, err)
    return self:_mutate(function(journal, put)
        local record = journal.orders[local_id]
        if not record then return nil, failure("not_found", "The local recharge record was not found.") end
        local result_id = type(result) == "table" and orderIdentifier(result.order_id)
        local error_id = type(err) == "table" and orderIdentifier(err.order_id)
        local order_id = result_id or error_id
        if order_id and record.order_id and order_id ~= record.order_id then
            return record, failure("recharge_order_conflict", "A creation callback reported a different recharge order identity.")
        end
        if record.state == "credited" or record.state == "pending" then return record end
        if record.state == "failed_not_submitted" and result == nil and not order_id then return record end
        local observed = copy(record)
        local code_url = type(result) == "table" and printable(result.code_url)
        local amount_matches = type(result) == "table" and (result.amount_cents == nil
            or integer(result.amount_cents, true) and result.amount_cents == observed.amount_cents)
        local valid = result_id and code_url and result.qr_validated == true and amount_matches
        if order_id then observed.order_id = order_id end
        if type(result) == "table" then
            observed.creation_observation = { order_id = order_id, code_url = code_url,
                qr_validated = result.qr_validated == true, amount_cents = integer(result.amount_cents, true) and result.amount_cents or nil }
        elseif error_id then
            -- A rejected QR URL can still leave a trustworthy identity for later reconciliation.
            observed.creation_observation = { order_id = error_id, qr_validated = false, identity_source = "creation_error" }
        end
        local creation_error
        if valid then
            observed.state, observed.code_url, observed.qr_validated, observed.error = "pending", code_url, true, nil
            if integer(result.expires_at, true) then observed.expires_at = result.expires_at end
        elseif type(err) == "table" and err.transmitted == false and err.definitive == true and not observed.order_id
            and record.state == "creating" then
            observed.state = "failed_not_submitted"
            creation_error = failure("recharge_not_submitted", "The recharge request was definitely not dispatched.", { transmitted = false, definitive = true })
        else
            observed.state = "unknown"
            creation_error = failure(type(result) == "table" and "recharge_result_invalid" or "recharge_unknown",
                "The recharge creation outcome is uncertain. Check records without recreating this order.")
        end
        observed.error, observed.updated_at = creation_error, self:_now()
        put(observed)
        return observed, creation_error
    end, { allow_cached = true })
end

-- The caller must supply records fetched for this service's authenticated account.
-- Amounts and balances are never used as a substitute for an exact string order identity.
function Service:applyHistory(local_id, records)
    if type(records) ~= "table" then return nil, failure("invalid_recharge_history", "Recharge history must be a record array.") end
    if records.account_key and records.account_key ~= self.account_key then
        return nil, failure("account_mismatch", "Recharge history belongs to another account.")
    end
    local length, entries = #records, 0
    for key in pairs(records) do
        if key ~= "account_key" then
            if not integer(key, true) or key > length then
                return nil, failure("invalid_recharge_history", "Recharge history must be a dense record array.")
            end
            entries = entries + 1
        end
    end
    if entries ~= length then return nil, failure("invalid_recharge_history", "Recharge history must be a dense record array.") end
    return self:_mutate(function(journal, put)
        local record = journal.orders[local_id]
        if not record then return nil, failure("not_found", "The local recharge record was not found.") end
        if record.state == "credited" then return record end
        local observed, now = copy(record), self:_now()
        observed.last_checked_at, observed.history_match = now, false
        for _, entry in ipairs(records) do
            if type(entry) == "table" and (not entry.account_key or entry.account_key == self.account_key)
                and orderIdentifier(entry.order_id) and record.order_id and entry.order_id == record.order_id then
                observed.state, observed.history_match, observed.error = "credited", true, nil
                observed.credited_observed_at = now
                observed.history_evidence = { order_id = entry.order_id, observed_at = now, amount_unit = "unverified",
                    raw_pay_amount = snapshot(entry.raw_pay_amount, 0, {}), product_amount = snapshot(entry.product_amount, 0, {}) }
                break
            end
        end
        observed.updated_at = now
        put(observed)
        return observed
    end, { allow_cached = true })
end

-- Call only after workers from the previous owner have stopped. No interrupted request is replayed.
function Service:recover()
    return self:_mutate(function(journal, put)
        for _, record in pairs(journal.orders) do
            if record.state == "creating" then
                local recovered = copy(record)
                recovered.state, recovered.updated_at = "unknown", self:_now()
                recovered.error = failure("recharge_unknown", "An interrupted recharge creation has an unknown outcome and must not be recreated.")
                put(recovered)
            end
        end
        return ordered(journal)
    end, { allow_cached = true })
end

function Service:flush()
    return self:_mutate(function(journal) return ordered(journal) end, { allow_cached = true, force = true })
end

function Service:close()
    self.closed = true
    return self:recover()
end

return Service
