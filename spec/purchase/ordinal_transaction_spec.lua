-- Synthetic ordinal transaction safety. Range evidence is produced by real Fetch/Range/Quote.
local root, data_root, phase = assert(arg[1]), assert(arg[2]), assert(arg[3])
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local Service = require("bilicomics/purchase/service")
local Store = require("bilicomics/storage/store")
local Client = require("bilicomics/protocol/client")
local Range = require("bilicomics/purchase/range")
local Value = require("bilicomics/purchase/value")
local JSON = require("bilicomics/protocol/json")
local evidence = assert(BILI_NONSPENDING_EVIDENCE, "Use the network-blocking entry")
local pending_index_key = "purchase.range_pending_ids"
evidence.ordinal_assertions, evidence.ordinal_quotes_built = 0, 0
local stores, fixture_sequence = {}, 0
local function check(condition, message)
    evidence.ordinal_assertions = evidence.ordinal_assertions + 1
    assert(condition, message or "Ordinal transaction assertion failed")
end
local function equal(left, right)
    check(Value.encode(left) == Value.encode(right), "Unexpected ordinal transaction value")
end
local function rejected(value, err, kind)
    check(value == nil and type(err) == "table" and err.kind == kind, "Unexpected ordinal rejection")
end
local function test(name, fn)
    local before = #stores
    local ok, failure = pcall(fn)
    for index = #stores, before + 1, -1 do stores[index]:close(); stores[index] = nil end
    assert(ok, name .. ": " .. tostring(failure))
    print("PASS " .. name)
end
local function rawRow(id, ordinal, locked, pay_mode, unlock_type, price)
    return {id = id, ord = ordinal, is_locked = locked, pay_mode = pay_mode,
        unlock_type = unlock_type, pay_gold = price, is_in_free = false,
        unlock_expire_at = "0000-00-00 00:00:00"}
end
local function rows(offset)
    return {
        rawRow(offset + 101, 1, true, 1, 0, 7), rawRow(offset + 102, 2, false, 0, 0, 0),
        rawRow(offset + 103, 2.5, true, 1, 0, 11), rawRow(offset + 104, 3, false, 1, 1, 13),
        rawRow(offset + 105, 4, true, 1, 0, 17), rawRow(offset + 106, 4.5, false, 0, 0, 0),
        rawRow(offset + 107, 5, true, 1, 0, 23), rawRow(offset + 108, 6, true, 1, 0, 31),
    }
end
local function fixture(durable)
    fixture_sequence = fixture_sequence + 1
    local store = Store.open{root = durable and data_root or data_root .. "/fixture-" .. fixture_sequence,
        account_key = "ordinal-synthetic", wal = false}
    stores[#stores + 1] = store
    local f = {store = store, comics = {["1"] = rows(0), ["2"] = rows(100)},
        wire_calls = 0, read_calls = 0, validated_timeout_returns = 0}
    function f:detail(comic_id)
        local ascending = assert(self.comics[tostring(comic_id)])
        local detail = {comic = {id = tostring(comic_id)}, episodes = {}, extra = {id = tonumber(comic_id), ep_list = {}}}
        for index, raw in ipairs(ascending) do
            detail.extra.ep_list[#ascending - index + 1] = Value.copy(raw)
            detail.episodes[index] = {id = tostring(raw.id), comic_id = tostring(comic_id), order = raw.ord,
                access = raw.is_locked and "locked" or raw.pay_mode == 0 and "free" or "owned",
                pay_gold = raw.pay_gold, extra = Value.copy(raw)}
        end
        return detail
    end
    for comic_id, ascending in pairs(f.comics) do
        if not store:getComic(comic_id) then
            store:upsertComic{ id = comic_id, title = "Synthetic ordinal fixture" }
            store:upsertEpisodes(comic_id, f:detail(comic_id).episodes)
        else
            for _, raw in ipairs(ascending) do
                local saved = store:getEpisode(tostring(raw.id))
                if saved and saved.access == "owned" then
                    raw.is_locked, raw.pay_mode, raw.unlock_type, raw.is_purchased = false, 1, 1, true
                end
            end
        end
    end
    function f:locate(episode_id)
        for comic_id, ascending in pairs(self.comics) do
            for index, raw in ipairs(ascending) do
                if tostring(raw.id) == tostring(episode_id) then return comic_id, index, raw end
            end
        end
        error("Unknown synthetic chapter")
    end
    function f:info(episode_id)
        local comic_id, anchor, raw = self:locate(episode_id)
        local whole_count, whole_price, after_price, after = 0, 0, 0, {}
        for index, row in ipairs(self.comics[comic_id]) do
            if row.is_locked then
                whole_count, whole_price = whole_count + 1, whole_price + row.pay_gold
                if index >= anchor then after[#after + 1], after_price = row, after_price + row.pay_gold end
            end
        end
        local positive_price = 0
        for index = 1, math.min(2, #after) do positive_price = positive_price + after[index].pay_gold end
        local function offer(limit, count, usable, price)
            return {batch_limit = limit, amount = count, usable = usable, original_gold = price,
                pay_gold = price, discount_type = 0, discount = 0, discount_batch_gold = 0}
        end
        return {comic_id = tonumber(comic_id), is_locked = raw.is_locked,
            ep_original_gold = raw.pay_gold, pay_gold = raw.pay_gold, original_gold = whole_price,
            remain_lock_ep_num = whole_count, remain_lock_ep_gold = whole_price,
            after_lock_ep_num = #after, after_lock_ep_gold = after_price,
            ep_discount_type = 0, ep_discount = 0, discount_type = 0, discount = 0,
            discount_ep_gold = 0, discount_remain_gold = 0, remain_gold = 1000, optional_discount_list = {},
            batch_buy = {offer(20, #after, false, after_price), offer(2, 2, #after >= 2, positive_price),
                offer(0, #after, #after > 0, after_price)}}
    end
    function f:setOwned(ids)
        for _, id in ipairs(ids) do
            local comic_id, _, raw = self:locate(id)
            raw.is_locked, raw.pay_mode, raw.unlock_type, raw.is_purchased = false, 1, 1, true
            self.store:upsertEpisodes(comic_id, self:detail(comic_id).episodes)
        end
    end
    local transport = {request = function(_, request)
        f.wire_calls = f.wire_calls + 1
        evidence.fake_buy_route_calls = evidence.fake_buy_route_calls + 1
        check(f.wire_calls == 1 and f.expected_wire ~= nil, "Only one predeclared fake transaction is allowed")
        check(request.method == "POST" and request.output_path == nil
            and request.url == "https://manga.bilibili.com/twirp/comic.v1.Comic/BuyEpisode?device=pc&platform=web&nov=27&a=810")
        check(request.headers.cookie == "SESSDATA=synthetic-ordinal-only")
        equal(assert(JSON.decode(request.body)), f.expected_wire)
        if f.wire_error then
            f.validated_timeout_returns = f.validated_timeout_returns + 1
            return nil, Value.copy(f.wire_error)
        end
        return {status = 200, body = '{"code":0,"data":{}}', transmitted = true}
    end}
    f.client = Client.new{session = {cookies = {SESSDATA = "synthetic-ordinal-only"}}, transport = transport, crypto = {}}
    function f.client:purchaseInfo(id, scope)
        f.read_calls, evidence.synthetic_read_calls = f.read_calls + 1, evidence.synthetic_read_calls + 1
        if scope then
            check(scope.buy_type == (scope.kind == "batch" and 2 or 1) and scope.offer_index == nil)
        end
        return f:info(id)
    end
    function f.client:comicDetail(comic_id)
        f.read_calls, evidence.synthetic_read_calls = f.read_calls + 1, evidence.synthetic_read_calls + 1
        return f:detail(comic_id)
    end
    local sequence = 0
    f.service = Service.new{store = store, client = f.client, clock = function() return 1000 end,
        id_factory = function(kind)
            sequence = sequence + 1
            return phase .. "-" .. fixture_sequence .. "-" .. kind .. "-" .. sequence
        end}
    function f:scope(id, limit)
        local _, _, raw = self:locate(id)
        return {kind = "batch", batch_limit = limit, start_ord = raw.ord, offer_index = limit == 0 and 3 or 2, order = 1}
    end
    function f:quote(id, limit)
        local q, err = self.service:quote(tostring(id), limit ~= nil and self:scope(id, limit) or nil,
            {method = "coin", discount = {kind = "none"}})
        check(q and not err and q.submittable == true, "The complete synthetic evidence must form a usable quote")
        if limit ~= nil then
            evidence.ordinal_quotes_built = evidence.ordinal_quotes_built + 1
            check(q.range_proof and q.range_proof.contract == Range.CONTRACT
                and q.range_proof.provenance == Range.PROVENANCE and q.range_proof.server_confirmed_ids == false)
            check(q.range_proof.basis_digest:match("^sha256:%x+$") ~= nil)
            equal(q.episode_ids, q.range_proof.episode_ids)
        end
        return q
    end
    function f:prepare(id, limit)
        local q, fresh = self:quote(id, limit), self:quote(id, limit)
        local intent, payload = self.service:prepareSubmission(q, {confirmed = true, purpose = "read"}, fresh)
        return intent, payload, q
    end
    function f:pendingOrdinal(id, limit, state)
        local intent = assert(self:prepare(id, limit))
        check(intent.range_outcome_pending == true)
        if state == "accepted" then
            intent = assert(self.service:completeSubmission(intent.id, {accepted = true}))
            check(intent.range_outcome_pending == nil)
        else
            intent = assert(self.service:completeSubmission(intent.id, nil, {kind = "timeout", transmitted = true}))
            check(intent.state == "outcome_unknown" and intent.range_outcome_pending == true)
        end
        return intent
    end
    return f
end

local function units()
    test("positive and zero ordinal requests use recomputed evidence and exact fake wire bodies", function()
        for _, item in ipairs({{2, 28, {"103", "105"}}, {0, 82, {"103", "105", "107", "108"}}}) do
            local f = fixture()
            local q = f:quote("103", item[1])
            equal(q.episode_ids, item[3])
            check(q.amount == item[2] and q.payload.limit == item[1] and q.payload.start_ord == 2.5)
            f.expected_wire = {comic_id = 1, with_ord_scope = true, start_ord = 2.5, limit = item[1],
                buy_method = 3, pay_amount = item[2]}
            local intent = assert(f.service:submit(q, {confirmed = true, purpose = "download"}))
            check(intent.state == "accepted" and intent.transaction_evidence == "server_accepted")
            check(intent.range_outcome_pending == nil and intent.purpose == "download" and f.wire_calls == 1)
            equal(intent.episode_ids, item[3])
        end
    end)
    test("lost ordinal response blocks disjoint same-comic single and ordinal selections", function()
        local f = fixture()
        local old = f:pendingOrdinal("103", 2)
        equal(old.episode_ids, {"103", "105"})
        for _, limit in ipairs({false, 2}) do
            local value, err, q = f:prepare("107", limit or nil)
            equal(q.episode_ids, limit and {"107", "108"} or {"107"})
            rejected(value, err, "outcome_unknown")
            check(err.intent_id == old.id and f.wire_calls == 0)
        end
    end)
    test("a pending ordinal range does not block a different comic", function()
        local f = fixture()
        f:pendingOrdinal("103", 2)
        local intent, payload = f:prepare("203", 2)
        check(intent and intent.comic_id == "2" and payload.comic_id == "2")
        equal(intent.episode_ids, {"203", "205"})
        check(f.wire_calls == 0)
    end)
    test("new ordinal selection conflicts with pending same-comic single outcomes", function()
        for _, outcome in ipairs({"accepted", "unknown"}) do
            local f = fixture()
            local old = assert(f:prepare("103"))
            old = assert(f.service:completeSubmission(old.id, outcome == "accepted" and {accepted = true} or nil,
                outcome == "unknown" and {kind = "timeout", transmitted = true} or nil))
            local value, err = f:prepare("107", 2)
            rejected(value, err, "outcome_unknown")
            check(err.intent_id == old.id and f.wire_calls == 0)
        end
    end)
    test("two disjoint single selections keep their existing narrow conflict rule", function()
        local f = fixture()
        local old = assert(f:prepare("103"))
        assert(f.service:completeSubmission(old.id, nil, {kind = "timeout", transmitted = true}))
        local next_intent = assert(f:prepare("107"))
        check(next_intent.comic_id == "1" and next_intent.quote.scope.kind == "single")
        check(next_intent.range_outcome_pending == nil and f.wire_calls == 0)
    end)
    test("owned intended chapters retain unresolved ordinal outcome and comic lock", function()
        local f = fixture()
        local intent = f:pendingOrdinal("103", 2)
        f:setOwned(intent.episode_ids)
        intent = assert(f.service:completeReconciliation(intent.id, f:detail("1").episodes))
        check(intent.state == "access_confirmed" and intent.range_outcome_pending == true)
        check(intent.transaction_evidence == "none" and intent.access_confirmation_source == "episode_entitlements")
        equal(intent.unresolved_episode_ids, {})
        local pending = assert(f.service:listPending())
        check(#pending == 1 and pending[1].id == intent.id)
        local value, err = f:prepare("107")
        rejected(value, err, "outcome_unknown")
        check(f.wire_calls == 0)
    end)
    test("definitive rejection and known non-transmission clear the ordinal flag", function()
        for _, failure in ipairs({{kind = "capability", transmitted = false},
            {kind = "purchase_rejected", definitive = true, transmitted = true, code = 2}}) do
            local f = fixture()
            local intent = assert(f:prepare("103", 2))
            intent = assert(f.service:completeSubmission(intent.id, nil, failure))
            check(intent.state == "rejected" and intent.range_outcome_pending == nil)
            check(intent.transaction_evidence == (failure.transmitted == false and "not_transmitted" or "server_rejected"))
            check(#assert(f.service:listPending()) == 0)
            check(f:prepare("107", 2) ~= nil and f.wire_calls == 0)
        end
    end)
    test("accepted receipt clears the flag but pending access still protects the comic", function()
        local f = fixture()
        local intent = f:pendingOrdinal("103", 2, "accepted")
        local value, err = f:prepare("107", 2)
        rejected(value, err, "outcome_unknown")
        f:setOwned(intent.episode_ids)
        intent = assert(f.service:completeReconciliation(intent.id, f:detail("1").episodes))
        check(intent.state == "access_confirmed" and intent.range_outcome_pending == nil)
        check(#assert(f.service:listPending()) == 0)
        check(f:prepare("107", 2) ~= nil and f.wire_calls == 0)
    end)
    test("late acceptance clears an already readable uncertain range without regression", function()
        local f = fixture()
        local intent = f:pendingOrdinal("103", 2)
        f:setOwned(intent.episode_ids)
        intent = assert(f.service:completeReconciliation(intent.id, f:detail("1").episodes))
        check(intent.range_outcome_pending == true and intent.state == "access_confirmed")
        intent = assert(f.service:completeSubmission(intent.id, {accepted = true}))
        check(intent.state == "access_confirmed" and intent.range_outcome_pending == nil
            and intent.transaction_evidence == "server_accepted")
        equal(intent.confirmed_episode_ids, {"103", "105"})
        check(#assert(f.service:listPending()) == 0)
        local unchanged = assert(f.service:completeSubmission(intent.id, nil, {kind = "timeout", transmitted = true}))
        equal(unchanged, intent)
        check(f:prepare("107", 2) ~= nil and f.wire_calls == 0)
    end)
    test("intent and range index roll back together after either durable write fails", function()
        for _, failed_write in ipairs({"journal", "index"}) do
            local f = fixture()
            assert(f.service:recover())
            equal(f.store:getSetting(pending_index_key), {})
            local put_purchase, put_setting = f.store.putPurchase, f.store.putSetting
            local injected = 0
            f.store.putPurchase = function(self, intent)
                local result = put_purchase(self, intent)
                if failed_write == "journal" then injected = injected + 1; error("Synthetic post-journal-write failure", 0) end
                return result
            end
            f.store.putSetting = function(self, key, value)
                local result = put_setting(self, key, value)
                if key == pending_index_key and failed_write == "index" then
                    injected = injected + 1; error("Synthetic post-index-write failure", 0)
                end
                return result
            end
            local value, err = f:prepare("103", 2)
            rejected(value, err, "storage")
            f.store.putPurchase, f.store.putSetting = put_purchase, put_setting
            check(injected == 1 and #f.store:listPurchases() == 0)
            equal(f.store:getSetting(pending_index_key), {})
            local intent = assert(f:prepare("103", 2))
            check(f.store:getPurchase(intent.id).range_outcome_pending == true)
            equal(f.store:getSetting(pending_index_key), {[intent.id] = true})
            check(f.wire_calls == 0)
        end
    end)
    test("a failed outcome index update preserves the old durable pair and observed receipt", function()
        local f = fixture()
        local intent = f:pendingOrdinal("103", 2)
        local before_intent, before_index = f.store:getPurchase(intent.id), f.store:getSetting(pending_index_key)
        local put_setting, injected = f.store.putSetting, 0
        f.store.putSetting = function(self, key, value)
            local result = put_setting(self, key, value)
            if key == pending_index_key then injected = injected + 1; error("Synthetic outcome index failure", 0) end
            return result
        end
        local observed, err = f.service:completeSubmission(intent.id, {accepted = true})
        check(observed and err and err.kind == "storage" and observed.persistence_pending == true)
        check(observed.state == "accepted" and observed.range_outcome_pending == nil and injected == 1)
        f.store.putSetting = put_setting
        equal(f.store:getPurchase(intent.id), before_intent)
        equal(f.store:getSetting(pending_index_key), before_index)
        local pending = assert(f.service:listPending())
        check(#pending == 1 and pending[1].state == "accepted" and pending[1].persistence_pending == true)
        observed = assert(f.service:completeSubmission(intent.id, nil, {kind = "timeout", transmitted = true}))
        check(observed.state == "accepted" and observed.persistence_pending == nil and observed.range_outcome_pending == nil)
        check(f.store:getPurchase(intent.id).state == "accepted")
        equal(f.store:getSetting(pending_index_key), {})
        check(f.wire_calls == 0)
    end)
    test("initialized pending refresh uses filtered states and held IDs without history scans", function()
        local f = fixture()
        assert(f.service:recover())
        local intent = f:pendingOrdinal("103", 2)
        f:setOwned(intent.episode_ids)
        intent = assert(f.service:completeReconciliation(intent.id, f:detail("1").episodes))
        for index = 1, 5 do
            f.store:putPurchase{id = "completed-history-" .. index, account_key = "ordinal-synthetic",
                comic_id = "2", episode_ids = {"203"}, state = "access_confirmed",
                quote = {id = "completed-quote-" .. index}, created_at = 1, updated_at = 1}
        end
        local list, filtered_calls = f.store.listPurchases, 0
        f.store.listPurchases = function(self, states)
            check(type(states) == "table", "Initialized listPending must not scan all completed history")
            filtered_calls = filtered_calls + 1
            return list(self, states)
        end
        for _ = 1, 3 do
            local pending = assert(f.service:listPending())
            check(#pending == 1 and pending[1].id == intent.id and pending[1].range_outcome_pending == true)
        end
        f.store.listPurchases = list
        check(filtered_calls == 3 and f.wire_calls == 0)
    end)
end

local function durable()
    local f = fixture(true)
    if phase == "seed" or phase == "seed_timeout" then
        local intent
        if phase == "seed_timeout" then
            local q = f:quote("107", 0)
            f.expected_wire = {comic_id = 1, with_ord_scope = true, start_ord = 5, limit = 0, buy_method = 3, pay_amount = 54}
            f.wire_error = {kind = "timeout", transmitted = true}
            local err
            intent, err = f.service:submit(q, {confirmed = true, purpose = "read"})
            check(f.validated_timeout_returns == 1, "The planned timeout must follow successful wire validation")
            check(intent and err and err.kind == "outcome_unknown" and intent.state == "outcome_unknown")
            check(f.wire_calls == 1 and intent.range_outcome_pending == true)
        else
            local payload
            intent, payload = f:prepare("107", 0)
            check(intent and payload.limit == 0 and payload.start_ord == 5 and payload.pay_amount == 54)
            check(intent.state == "submitting" and intent.range_outcome_pending == true)
        end
        f.store:putSetting("ordinal.original_intent", intent.id)
        equal(intent.episode_ids, {"107", "108"})
        equal(f.store:getSetting(pending_index_key), {[intent.id] = true})
        if phase == "seed" then
            -- Exercise recovery of an old/missing index, without changing the real intent.
            f.store:putSetting(pending_index_key, {["obsolete-index-entry"] = true})
            print("PASS SQLite commits a zero-range intent before simulated process loss")
        else
            print("PASS a real Client fake-transport timeout persists the ordinal intent and index")
        end
    else
        local id = assert(f.store:getSetting("ordinal.original_intent"))
        local pending_before_reads = f.read_calls
        local list, history_scans = f.store.listPurchases, 0
        f.store.listPurchases = function(self, states)
            if states == nil then history_scans = history_scans + 1 end
            return list(self, states)
        end
        local pending = assert(f.service:recover())
        f.store.listPurchases = list
        check(history_scans == 1, "Startup recovery must rebuild the index in one history pass")
        check(f.read_calls == pending_before_reads and f.wire_calls == 0, "Recovery must remain local")
        local intent = assert(f.store:getPurchase(id))
        check(intent.purpose == "read" and intent.quote.scope.batch_limit == 0 and intent.quote.episode_id == "107")
        if phase == "recover" or phase == "recover_timeout" then
            check(intent.state == "outcome_unknown" and intent.range_outcome_pending == true)
            check(#pending == 1 and pending[1].id == id)
            equal(f.store:getSetting(pending_index_key), {[id] = true})
            local value, err, q = f:prepare("103", 2)
            equal(q.episode_ids, {"103", "105"})
            rejected(value, err, "outcome_unknown")
            print("PASS SQLite restart preserves the uncertain ordinal flag and same-comic lock")
        elseif phase == "owned" then
            f:setOwned(intent.episode_ids)
            intent = assert(f.service:completeReconciliation(id, f:detail("1").episodes))
            check(intent.state == "access_confirmed" and intent.range_outcome_pending == true)
            equal(intent.unresolved_episode_ids, {})
            check(#assert(f.service:listPending()) == 1)
            equal(f.store:getSetting(pending_index_key), {[id] = true})
            f.store:putSetting(pending_index_key, {})
            print("PASS SQLite persists readable intended chapters without inventing an ordinal receipt")
        elseif phase == "inspect_pending" then
            check(intent.state == "access_confirmed" and intent.range_outcome_pending == true)
            check(#pending == 1 and pending[1].id == id)
            equal(f.store:getSetting(pending_index_key), {[id] = true})
            check(f.store:getEpisode("107").access == "owned" and f.store:getEpisode("108").access == "owned")
            local value, err = f:prepare("103", 2)
            rejected(value, err, "outcome_unknown")
            print("PASS another process still lists the readable uncertain range as pending")
        elseif phase == "late_accepted" then
            intent = assert(f.service:completeSubmission(id, {accepted = true}))
            check(intent.state == "access_confirmed" and intent.range_outcome_pending == nil)
            check(intent.transaction_evidence == "server_accepted" and #assert(f.service:listPending()) == 0)
            equal(f.store:getSetting(pending_index_key), {})
            local next_intent = assert(f:prepare("103", 2))
            assert(f.service:completeSubmission(next_intent.id, nil, {kind = "capability", transmitted = false}))
            print("PASS a late receipt clears the persisted lock while retaining readable access")
        elseif phase == "inspect_cleared" then
            check(intent.state == "access_confirmed" and intent.range_outcome_pending == nil)
            check(intent.transaction_evidence == "server_accepted" and #pending == 0)
            equal(f.store:getSetting(pending_index_key), {})
            equal(intent.confirmed_episode_ids, {"107", "108"})
            check(f.store:getEpisode("107").access == "owned" and f.store:getEpisode("108").access == "owned")
            print("PASS final SQLite reopen keeps the cleared flag and original readable chapters")
        else error("Unknown ordinal phase") end
    end
    check(f.wire_calls == (phase == "seed_timeout" and 1 or 0), "Only the planned timeout stage may dispatch a fake transaction")
    for index = #stores, 1, -1 do stores[index]:close(); stores[index] = nil end
end
if phase == "unit" then units() else durable() end
check(evidence.real_transport_attempts == 0 and evidence.forbidden_module_attempts == 0)
