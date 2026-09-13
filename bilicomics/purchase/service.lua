local Value = require("bilicomics/purchase/value")
local Quote = require("bilicomics/purchase/quote")
local Selection = require("bilicomics/purchase/selection")

local Service = {}
Service.__index = Service
local pending_states = {"submitting", "accepted", "outcome_unknown"}
local function ordinal(quote)
    return type(quote) == "table" and type(quote.scope) == "table" and quote.scope.kind == "batch"
end

local function fail(kind, message, extra)
    error(Value.error(kind, message, extra), 0)
end

local function protected(fn)
    local ok, value, err = pcall(fn)
    if ok then return value, err end
    if type(value) == "table" and value.kind then return nil, value end
    return nil, Value.error("storage", "Purchase state could not be safely persisted or loaded.")
end

local function network(client, method, ...)
    if not client or type(client[method]) ~= "function" then
        return nil, Value.error("capability", "The protocol operation is not available.", {transmitted = false})
    end
    local ok, value, err = pcall(client[method], client, ...)
    if not ok then return nil, Value.error("transport", "The request outcome is unknown.") end
    return value, err
end

function Service.new(options)
    assert(options and options.store, "A purchase store is required")
    local self = setmetatable({}, Service)
    self.store, self.client = options.store, options.client
    self.clock, self.id_factory = options.clock or os.time, options.id_factory
    self.account_key = options.account_key or options.store.account_key
    self.max_quote_age = options.max_quote_age or 120
    self.quote_sequence = 0
    self.unpersisted_results = {}
    self.instance_id = tostring(self):gsub("[^%w]", "")
    return self
end

function Service:_now()
    if type(self.clock) == "function" then return self.clock() end
    return self.clock:now()
end

function Service:_quoteID()
    if self.id_factory then return assert(Value.id(self.id_factory("quote")), "Invalid quote identifier") end
    self.quote_sequence = self.quote_sequence + 1
    return "quote-" .. self:_now() .. "-" .. self.instance_id .. "-" .. self.quote_sequence
end

function Service:_purchaseID()
    if self.id_factory then return assert(Value.id(self.id_factory("purchase")), "Invalid purchase identifier") end
    local sequence = self.store:getSetting("purchase.intent_sequence", 0) + 1
    self.store:putSetting("purchase.intent_sequence", sequence)
    return "purchase-" .. self:_now() .. "-" .. sequence
end

function Service:_requireDurableBoundary()
    if (self.store._depth or 0) > 0 then
        fail("nested_transaction", "Purchase journal operations require their own committed transaction.")
    end
end

function Service:_rangePendingIds()
    local indexed = self.store:getSetting("purchase.range_pending_ids")
    if type(indexed) == "table" then return Value.copy(indexed) end
    local result = {}
    for _, intent in ipairs(self.store:listPurchases()) do
        if intent.account_key == self.account_key and intent.range_outcome_pending == true then result[intent.id] = true end
    end
    return result
end

-- The caller owns a committed purchase-journal transaction.
function Service:_putIntent(intent)
    self.store:putPurchase(intent)
    local indexed = self:_rangePendingIds()
    indexed[intent.id] = intent.range_outcome_pending == true and true or nil
    self.store:putSetting("purchase.range_pending_ids", indexed)
end

function Service:buildQuote(episode_id, scope, payment, raw_info, raw_detail, context)
    return protected(function()
        local info = raw_info or {}
        local episode = self.store:getEpisode(episode_id)
        local comic_id = Value.id(info.comic_id) or (episode and Value.id(episode.comic_id))
        local episodes
        if raw_detail then
            episodes = raw_detail.episodes or raw_detail
        elseif comic_id then
            episodes = self.store:listEpisodes(comic_id)
        end
        return Quote.build({
            info = info, episode_id = episode_id, scope = scope, payment = payment,
            episodes = episodes, raw_detail = raw_detail, account_key = self.account_key, context = context,
            id = self:_quoteID(), now = self:_now(), max_age = self.max_quote_age,
        })
    end)
end

-- This synchronous convenience method is for a controlled execution context.
-- Native UI uses worker reads followed by buildQuote on the main process.
function Service:quote(episode_id, scope, payment)
    return protected(function()
        local selection, err = Selection.normalize(scope, payment)
        if not selection then return nil, err end
        local episode = self.store:getEpisode(episode_id)
        local result
        result, err = require("bilicomics/purchase/quote_fetch").run(self.client, {
            episode_id = episode_id, comic_id = episode and episode.comic_id,
            scope = selection.scope, payment = selection.payment })
        if not result then return nil, Value.publicError(err, "protocol") end
        return self:buildQuote(episode_id, selection.scope, selection.payment, result.info, result.detail, result.context)
    end)
end

function Service:_validateQuote(quote)
    if type(quote) == "table" and quote.submittable == false then
        fail("quote_unverified", "The exact chapters and final asset costs must be confirmed before purchasing.")
    end
    if type(quote) ~= "table" or not Value.id(quote.id) or quote.schema_version ~= 1
        or not Value.ids(quote.episode_ids) or quote.account_key ~= self.account_key
        or type(quote.fingerprint) ~= "string" or quote.fingerprint ~= Quote.fingerprint(quote) then
        fail("invalid_quote", "The confirmed quote is invalid or has changed.")
    end
    if not quote.expires_at or self:_now() > quote.expires_at then
        fail("quote_expired", "Refresh the quote and confirm the current price.")
    end
end

-- The caller must provide a newly fetched quote after the user's confirmation.
-- This function performs no network work; persist its result before dispatching.
function Service:prepareSubmission(quote, options, refreshed_quote)
    return protected(function()
        if not options or options.confirmed ~= true then
            fail("confirmation_required", "Explicit confirmation of this quote is required.")
        end
        if options.purpose and options.purpose ~= "read" and options.purpose ~= "download" then
            fail("invalid_purpose", "Purchase continuation must be read or download.")
        end
        self:_validateQuote(quote)
        if not refreshed_quote then fail("quote_refresh_required", "Refresh the server quote before submitting.") end
        self:_validateQuote(refreshed_quote)
        if refreshed_quote.id == quote.id or refreshed_quote.created_at < quote.created_at then
            fail("quote_refresh_required", "Use a newly retrieved quote after confirmation.")
        end
        if quote.fingerprint ~= refreshed_quote.fingerprint then
            fail("quote_changed", "The price, assets, scope, or access changed. Confirm a new quote.", {quote = refreshed_quote})
        end
        if not refreshed_quote.can_afford then
            fail("insufficient_balance", "The selected asset balance is insufficient.", {quote = refreshed_quote})
        end

        self:_requireDurableBoundary()
        local intent, payload
        self.store:transaction(function()
            local selected = {}
            for _, id in ipairs(quote.episode_ids) do selected[id] = true end
            for _, existing in ipairs(self.store:listPurchases()) do
                if existing.quote and existing.quote.id == quote.id then
                    fail("duplicate_submission", "This confirmation already has a purchase result.", {intent_id = existing.id, state = existing.state})
                end
                if existing.state == "submitting" then
                    fail("purchase_busy", "Another purchase is being submitted.", {intent_id = existing.id})
                end
                local pending = existing.state == "accepted" or existing.state == "outcome_unknown"
                    or existing.range_outcome_pending == true
                if pending and Value.id(existing.comic_id) == Value.id(quote.comic_id)
                    and (ordinal(existing.quote) or ordinal(quote) or existing.range_outcome_pending == true) then
                    -- Another client can unlock earlier chapters and shift an ordinal range.
                    fail("outcome_unknown", "Reconcile the earlier range purchase before purchasing this comic again.", {intent_id = existing.id})
                end
                if existing.state == "accepted" or existing.state == "outcome_unknown" then
                    for _, id in ipairs(existing.unresolved_episode_ids or existing.episode_ids) do
                        if selected[id] then fail("outcome_unknown", "Reconcile the earlier purchase before buying these chapters.", {intent_id = existing.id}) end
                    end
                end
            end
            local id = self:_purchaseID()
            if self.store:getPurchase(id) then fail("id_collision", "The purchase identifier is already in use.") end
            local now = self:_now()
            intent = {
                id = id, account_key = self.account_key, state = "submitting",
                comic_id = quote.comic_id, episode_ids = Value.copy(quote.episode_ids),
                quote = Value.copy(quote), before_access = Value.copy(quote.before_access),
                expected_access = Value.copy(quote.expected_access),
                purpose = options.purpose, created_at = now, updated_at = now,
                confirmed_episode_ids = {}, unresolved_episode_ids = Value.copy(quote.episode_ids),
                transaction_evidence = "none", attempts = 1,
                range_outcome_pending = ordinal(quote) or nil,
            }
            self:_putIntent(intent)
            payload = Value.copy(quote.payload)
        end)
        return intent, payload
    end)
end

function Service:_getIntent(id)
    local intent = Value.copy(self.unpersisted_results[id]) or self.store:getPurchase(id)
    if not intent then fail("not_found", "The purchase intent was not found.") end
    if intent.account_key ~= self.account_key then fail("account_mismatch", "The purchase belongs to another account.") end
    return intent
end

-- Recheck the committed confirmation immediately before the worker can transmit.
function Service:authorizeSubmission(intent_id)
    local allowed, err = protected(function()
        self:_requireDurableBoundary()
        if self.unpersisted_results[intent_id] then
            fail("persistence_pending", "The observed purchase result must be saved before any further action.")
        end
        local intent = self.store:getPurchase(intent_id)
        if not intent then fail("not_found", "The purchase intent was not found.") end
        if intent.account_key ~= self.account_key then fail("account_mismatch", "The purchase belongs to another account.") end
        if intent.state ~= "submitting" then
            fail("duplicate_submission", "This confirmation already has a purchase result.")
        end
        self:_validateQuote(intent.quote)
        return true
    end)
    if allowed then return true end
    err = Value.copy(err)
    err.transmitted, err.definitive = false, true
    return nil, err
end

function Service:completeSubmission(intent_id, response, err)
    local observed
    local result, result_error = protected(function()
        self:_requireDurableBoundary()
        local result, result_error
        self.store:transaction(function()
            local intent = self:_getIntent(intent_id)
            local access_was_confirmed = intent.state == "access_confirmed"
            -- Refusing a new dispatch is not evidence against an earlier transmitted attempt.
            local refused_dispatch = err and err.transmitted == false
            if intent.state ~= "submitting" and (refused_dispatch or (intent.state ~= "outcome_unknown"
                and not (access_was_confirmed and intent.range_outcome_pending))) then
                if intent.persistence_pending then
                    intent.persistence_pending = nil
                    observed = Value.copy(intent)
                    self:_putIntent(intent)
                end
                result = intent
                if refused_dispatch then result_error = Value.publicError(err, "purchase_rejected") end
                return
            end
            if response ~= nil and response ~= false and not err then
                -- The client recognizes success explicitly before returning a value.
                intent.state, intent.transaction_evidence = access_was_confirmed and "access_confirmed" or "accepted", "server_accepted"
                intent.accepted_at, intent.error = self:_now(), nil
                intent.range_outcome_pending = nil
            elseif err and (err.definitive == true or err.transmitted == false) then
                intent.state = "rejected"
                intent.transaction_evidence = err.transmitted == false and "not_transmitted" or "server_rejected"
                intent.error = Value.publicError(err, "purchase_rejected")
                intent.range_outcome_pending = nil
                result_error = intent.error
            else
                intent.state = access_was_confirmed and "access_confirmed" or "outcome_unknown"
                intent.range_outcome_pending = ordinal(intent.quote) or intent.range_outcome_pending or nil
                intent.error = Value.error("outcome_unknown", "The purchase outcome is unknown. Refresh access without resubmitting.")
                intent.transport_error = Value.publicError(err, "transport")
                result_error = intent.error
            end
            intent.updated_at = self:_now()
            observed = Value.copy(intent)
            self:_putIntent(intent)
            result = intent
        end)
        return result, result_error
    end)
    if result then
        self.unpersisted_results[intent_id] = nil
        return result, result_error
    end
    if observed then
        -- A disk failure cannot erase a response already observed by this process.
        -- The old durable intent still prevents replay after a subsequent crash.
        observed.persistence_pending = true
        self.unpersisted_results[intent_id] = observed
        return Value.copy(observed), result_error
    end
    return nil, result_error
end

function Service:completeReconciliation(intent_id, episodes, wallet, err)
    local observed
    local result, result_error = protected(function()
        self:_requireDurableBoundary()
        local result, result_error
        self.store:transaction(function()
            local intent = self:_getIntent(intent_id)
            if intent.state == "access_confirmed" or intent.state == "rejected" then
                intent.persistence_pending = nil
                observed = Value.copy(intent)
                self:_putIntent(intent)
                result = intent
                return
            end
            if intent.state == "submitting" then
                fail("purchase_busy", "Wait for the active submission before reconciling.", {intent_id = intent.id})
            end
            if err or type(episodes) ~= "table" then
                intent.reconciliation_error = Value.publicError(err, "access_refresh_failed")
                result_error = intent.reconciliation_error
            else
                local by_id, confirmed, unresolved = {}, {}, {}
                for _, episode in ipairs(episodes.episodes or episodes) do
                    local id = Value.id(episode.id)
                    if id and Value.id(episode.comic_id) == intent.comic_id then by_id[id] = episode end
                end
                local access_evidence = {}
                for _, id in ipairs(intent.episode_ids) do
                    local episode = by_id[id]
                    local expected = intent.expected_access[id]
                    if episode then access_evidence[id] = {access = episode.access, expires_at = episode.expires_at} end
                    if episode and expected and episode.access == expected.access
                        and expected.access == "owned" and (episode.expires_at == nil or tonumber(episode.expires_at) == 0) then
                        confirmed[#confirmed + 1] = id
                    else
                        unresolved[#unresolved + 1] = id
                    end
                end
                intent.confirmed_episode_ids, intent.unresolved_episode_ids = confirmed, unresolved
                intent.access_evidence, intent.reconciled_at = access_evidence, self:_now()
                intent.reconciliation_error = nil
                if #unresolved == 0 then
                    intent.state, intent.access_confirmed_at, intent.error = "access_confirmed", self:_now(), nil
                    -- Access is sufficient to continue; it does not create a receipt.
                    intent.access_confirmation_source = "episode_entitlements"
                    if ordinal(intent.quote) and intent.transaction_evidence ~= "server_accepted" then
                        intent.range_outcome_pending = true
                    end
                else
                    result_error = Value.error("access_pending", "Some chapter entitlements have not been confirmed yet.")
                end
            end
            -- Wallet changes never establish a chapter purchase or alter its state.
            if wallet and wallet.error then intent.wallet_refresh_error = Value.publicError(wallet.error, "wallet_refresh_failed") end
            intent.updated_at = self:_now()
            intent.persistence_pending = nil
            observed = Value.copy(intent)
            self:_putIntent(intent)
            result = intent
        end)
        return result, result_error
    end)
    if result then
        self.unpersisted_results[intent_id] = nil
        return result, result_error
    end
    if observed then
        observed.persistence_pending = true
        self.unpersisted_results[intent_id] = observed
        return Value.copy(observed), result_error
    end
    return nil, result_error
end

function Service:submit(quote, options)
    if not options or options.confirmed ~= true then return nil, Value.error("confirmation_required", "Explicit confirmation is required.") end
    local valid, validation_error = protected(function() self:_validateQuote(quote); return true end)
    if not valid then return nil, validation_error end
    local refreshed, refresh_error = self:quote(quote.episode_id, quote.scope, quote.payment)
    if not refreshed then return nil, refresh_error end
    local intent, payload = self:prepareSubmission(quote, options, refreshed)
    if not intent then return nil, payload end
    local allowed, err = self:authorizeSubmission(intent.id)
    local response
    if allowed then response, err = network(self.client, "buyEpisode", payload) end
    local completed, completion_error = self:completeSubmission(intent.id, response, err)
    if not completed then
        return intent, Value.error("outcome_unknown", "The response could not be persisted. Do not resubmit this purchase.", {cause = completion_error and completion_error.kind})
    end
    if completed.state ~= "accepted" then return completed, completion_error end
    return self:reconcile(completed.id)
end

function Service:reconcile(intent_id)
    local intent, load_error = protected(function() return self:_getIntent(intent_id) end)
    if not intent then return nil, load_error end
    if intent.state == "access_confirmed" or intent.state == "rejected" then
        if intent.persistence_pending then return self:completeReconciliation(intent_id) end
        return intent
    end
    if intent.state == "submitting" then return intent, Value.error("purchase_busy", "The purchase is still being submitted.") end
    local detail, err = network(self.client, "comicDetail", intent.comic_id)
    return self:completeReconciliation(intent_id, detail and detail.episodes, nil, err)
end

-- Startup recovery is local and must run only after old workers are gone.
-- No network request, purchase replay, or wallet inference occurs here.
function Service:recover()
    return protected(function()
        self:_requireDurableBoundary()
        self.store:transaction(function()
            local indexed = {}
            for _, intent in ipairs(self.store:listPurchases()) do
                if intent.account_key == self.account_key then
                    if intent.state == "submitting" then
                        intent.state, intent.updated_at = "outcome_unknown", self:_now()
                        intent.range_outcome_pending = ordinal(intent.quote) or intent.range_outcome_pending or nil
                        intent.error = Value.error("outcome_unknown", "An interrupted purchase needs entitlement reconciliation.")
                        self.store:putPurchase(intent)
                    end
                    if intent.range_outcome_pending == true then indexed[intent.id] = true end
                end
            end
            self.store:putSetting("purchase.range_pending_ids", indexed)
        end)
        return self:listPending()
    end)
end

function Service:listPending()
    return protected(function()
        local result, candidates, seen = {}, self.store:listPurchases(pending_states), {}
        for _, saved in ipairs(candidates) do seen[saved.id] = true end
        for id, held in pairs(self:_rangePendingIds()) do
            if held == true and not seen[id] then
                local saved = self.store:getPurchase(id)
                if saved then candidates[#candidates + 1], seen[id] = saved, true end
            end
        end
        for id, intent in pairs(self.unpersisted_results) do
            if not seen[id] then candidates[#candidates + 1], seen[id] = intent, true end
        end
        for _, saved in ipairs(candidates) do
            local intent = Value.copy(self.unpersisted_results[saved.id]) or saved
            local pending = intent.range_outcome_pending == true or intent.persistence_pending == true
            for _, state in ipairs(pending_states) do if intent.state == state then pending = true end end
            if intent.account_key == self.account_key and pending then result[#result + 1] = intent end
        end
        return result
    end)
end

return Service
