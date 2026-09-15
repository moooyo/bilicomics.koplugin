-- Pure synthetic durability checks. The service has no client and cannot create a real order.
local root = assert(arg[1], "Pass the plugin root")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local Service = require("bilicomics/recharge/service")
local results, assertions = {}, 0
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local function check(value, message)
    assertions = assertions + 1
    assert(value, message or "Recharge service assertion failed")
end
local function rejected(value, err, kind)
    check(value == nil and err and err.kind == kind, "Expected error: " .. kind)
end
local function test(name, callback)
    local ok, err = pcall(callback)
    results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    print((ok and "PASS " or "FAIL ") .. name .. (not ok and ": " .. tostring(err) or ""))
end
local function fixture(account)
    local f = { now = 1800000000, writes = 0 }
    f.store = { account_key = account or "account-a", values = {}, _depth = 0 }
    function f.store:getSetting(key, default)
        if self.fail_reads then error("Synthetic read failure") end
        local value = self.values[key]
        if value == nil then return default end
        return copy(value)
    end
    function f.store:putSetting(key, value)
        if self.fail_writes then error("Synthetic write failure") end
        if self.return_write_error then return nil, { kind = "storage", message = "Synthetic returned failure" } end
        f.writes = f.writes + 1
        self.values[key] = copy(value)
    end
    function f.store:transaction(callback)
        if self.fail_begin then error("Synthetic BEGIN failure") end
        local before = copy(self.values)
        self._depth = 1
        local ok, value, err = pcall(callback)
        self._depth = 0
        if not ok or self.fail_commit then
            self.values = before
            error(not ok and value or "Synthetic COMMIT failure", 0)
        end
        if self.fail_after_commit then error("Synthetic post-commit interruption") end
        return value, err
    end
    function f:newService(key)
        return Service.new{ store = self.store, account_key = key or self.store.account_key, clock = function() return self.now end }
    end
    f.service = f:newService()
    return f
end
local function metadata(token)
    return { confirmation_token = token, created_at = 1799999990, confirmed_at = 1799999999,
        config_snapshot = { options = { { amount_cents = 500, amount_yuan = "5", product_id = "90071992547409931234" } } } }
end
local function create(service, token)
    local record, err = service:prepare(500, metadata(token or "confirmation-1"))
    check(record and not err and record.state == "creating", "Expected a committed creation record")
    return record
end
local function response(order_id)
    return { order_id = order_id or "90071992547409931234", code_url = "weixin://synthetic-only/order", qr_validated = true }
end
local function pending(f, token, order_id)
    local record = create(f.service, token)
    local observed, err = f.service:completeCreation(record.id, response(order_id))
    check(observed and observed.state == "pending" and not err and not observed.persistence_pending)
    return observed
end

test("prepare commits before dispatch and exposes defensive copies", function()
    local f = fixture()
    local record = create(f.service)
    check(f.writes == 1 and record.amount_cents == 500 and record.creation_attempts == 1)
    record.metadata.config_snapshot.options[1].amount_cents = 1
    local saved = assert(f.service:get(record.id))
    check(saved.metadata.config_snapshot.options[1].amount_cents == 500)
    check(saved.metadata.config_snapshot.options[1].product_id == "90071992547409931234")
end)

test("invalid amounts and missing explicit confirmation cannot create records", function()
    local f = fixture()
    for _, amount in ipairs({ 0, -1, 1.5, "500", math.huge, 9007199254740992 }) do
        local value, err = f.service:prepare(amount, metadata("invalid"))
        rejected(value, err, "invalid_recharge_amount")
    end
    local value, err = f.service:prepare(500, {})
    rejected(value, err, "confirmation_required")
    check(f.writes == 0)
end)

test("only one creating request is allowed across service instances", function()
    local f = fixture()
    create(f.service)
    local value, err = f:newService():prepare(1000, metadata("confirmation-2"))
    rejected(value, err, "recharge_busy")
    check(#assert(f.service:list()) == 1)
end)

test("a confirmation token cannot be reused after a successful creation", function()
    local f = fixture()
    pending(f)
    local value, err = f.service:prepare(500, metadata("confirmation-1"))
    rejected(value, err, "duplicate_confirmation")
end)

test("fresh explicit confirmations preserve multiple older pending orders", function()
    local f = fixture()
    local first = pending(f, "first", "10000000000000000001")
    local second = pending(f, "second", "10000000000000000002")
    local records = assert(f.service:list())
    check(#records == 2 and records[1].id == second.id and records[2].id == first.id)
    check(records[2].order_id == "10000000000000000001")
end)

test("recovery makes interrupted creation unknown and never reuses its confirmation", function()
    local f = fixture()
    local original = create(f.service)
    local restarted = f:newService()
    local records, err = restarted:recover()
    check(not err and records[1].state == "unknown" and records[1].id == original.id)
    local value, duplicate = restarted:prepare(500, metadata("confirmation-1"))
    rejected(value, duplicate, "duplicate_confirmation")
    create(restarted, "fresh-confirmation")
    check(#assert(restarted:list()) == 2)
end)

test("unknown transport failure cannot be treated as not submitted", function()
    local f = fixture()
    local record = create(f.service)
    local observed, err = f.service:completeCreation(record.id, nil, { kind = "timeout", message = "Cookie: synthetic-secret" })
    check(observed.state == "unknown" and err.kind == "recharge_unknown")
    check(not observed.error.message:find("synthetic-secret", 1, true))
    check(not observed.order_id and observed.creation_attempts == 1)
end)

test("not-submitted requires both definitive and transmitted-false evidence", function()
    for index, input in ipairs({ { transmitted = false }, { definitive = true }, { transmitted = false, definitive = true } }) do
        local f = fixture()
        local record = create(f.service)
        local observed = f.service:completeCreation(record.id, nil, input)
        check(observed.state == (index == 3 and "failed_not_submitted" or "unknown"))
    end
end)

test("a late dispatch refusal cannot resolve an already unknown creation", function()
    local f = fixture()
    local record = create(f.service)
    f.service:completeCreation(record.id, nil, { kind = "timeout" })
    local observed = f.service:completeCreation(record.id, nil, { transmitted = false, definitive = true })
    check(observed.state == "unknown")
end)

test("a definitive local rejection is idempotent and consumes its token", function()
    local f = fixture()
    local record = create(f.service)
    f.service:completeCreation(record.id, nil, { transmitted = false, definitive = true })
    local observed = f.service:completeCreation(record.id, nil, { kind = "timeout" })
    check(observed.state == "failed_not_submitted")
    local value, err = f.service:prepare(500, metadata("confirmation-1"))
    rejected(value, err, "duplicate_confirmation")
end)

test("numeric large order identities are never converted into strings", function()
    local f = fixture()
    local record = create(f.service)
    local result = response(9007199254740992)
    local observed, err = f.service:completeCreation(record.id, result)
    check(observed.state == "unknown" and not observed.order_id and err.kind == "recharge_result_invalid")
end)

test("order identities accept only canonical positive decimal strings of at most 128 digits", function()
    for _, invalid in ipairs({ "", "0", "01", "+1", "-1", "1.0", "1e9", "order-1", " 1", "1\n",
        string.rep("9", 129), 9007199254740992 }) do
        local f = fixture()
        local record = create(f.service)
        local observed = f.service:completeCreation(record.id,
            { order_id = invalid, code_url = "weixin://synthetic-only/order", qr_validated = true })
        check(observed.state == "unknown" and not observed.order_id and not observed.code_url)
    end
    local f = fixture()
    local maximum = string.rep("9", 128)
    local record = pending(f, "opaque-confirmation-token", maximum)
    check(record.id:match("^recharge%-") and record.order_id == maximum)
    check(assert(f.service:applyHistory(record.id, { { order_id = maximum } })).credited_confirmed)
end)

test("a valid identity in a rejected-QR error is retained for exact reconciliation only", function()
    local f = fixture()
    local record = create(f.service)
    local order_id = "90071992547409931234"
    local observed, err = f.service:completeCreation(record.id, nil,
        { kind = "untrusted_recharge_url", order_id = order_id, code_url = "https://untrusted.invalid/payment" })
    check(observed.state == "unknown" and observed.order_id == order_id and err.kind == "recharge_unknown")
    check(not observed.code_url and observed.qr_validated ~= true and not observed.creation_observation.code_url)
    check(observed.creation_observation.identity_source == "creation_error")
    local restarted = f:newService()
    local saved = assert(restarted:get(record.id))
    check(saved.state == "unknown" and saved.order_id == order_id and not saved.code_url)
    local credited = assert(restarted:applyHistory(record.id, { { order_id = order_id } }))
    check(credited.state == "credited" and credited.credited_confirmed)
end)

test("an error identity is not discarded even if the error also claims no transmission", function()
    local f = fixture()
    local record = create(f.service)
    local observed = f.service:completeCreation(record.id, nil,
        { kind = "rejected_qr", order_id = "123456789012345678", transmitted = false, definitive = true })
    check(observed.state == "unknown" and observed.order_id == "123456789012345678")
end)

test("invalid and numeric error identities are never retained as order identities", function()
    for _, invalid in ipairs({ "0", "01", "order-1", string.rep("9", 129), 9007199254740992 }) do
        local f = fixture()
        local record = create(f.service)
        local observed = f.service:completeCreation(record.id, nil, { kind = "rejected_qr", order_id = invalid })
        check(observed.state == "unknown" and not observed.order_id and not observed.code_url)
    end
end)

test("an error-only order identity survives failed persistence and flush", function()
    local f = fixture()
    local record = create(f.service)
    f.store.fail_writes = true
    local observed, err = f.service:completeCreation(record.id, nil,
        { kind = "rejected_qr", order_id = "123456789012345678" })
    check(observed.order_id == "123456789012345678" and observed.persistence_pending and err.kind == "storage")
    check(not observed.code_url)
    f.store.fail_writes = false
    check(f.service:flush())
    check(assert(f:newService():get(record.id)).order_id == "123456789012345678")
end)

test("stored noncanonical order identities are rejected without resetting the journal", function()
    local f = fixture()
    local record = pending(f)
    f.store.values[f.service.setting_key].orders[record.id].order_id = "090071992547409931234"
    local records, err = f.service:list()
    rejected(records, err, "recharge_journal_invalid")
end)

test("unvalidated QR data preserves the exact order for history without exposing a payable QR", function()
    local f = fixture()
    local record = create(f.service)
    local result = response(); result.qr_validated = false
    local observed = f.service:completeCreation(record.id, result)
    check(observed.state == "unknown" and observed.order_id == result.order_id and not observed.code_url)
    local matched = assert(f.service:applyHistory(record.id, { { order_id = result.order_id } }))
    check(matched.state == "credited" and matched.credited_confirmed)
end)

test("mismatched response amounts do not expose the QR as ready", function()
    local f = fixture()
    local record = create(f.service)
    local result = response(); result.amount_cents = 1000
    local observed = f.service:completeCreation(record.id, result)
    check(observed.state == "unknown" and observed.amount_cents == 500 and not observed.code_url)
    check(observed.creation_observation.amount_cents == 1000)
end)

test("pending creation cannot be downgraded by a duplicate failed callback", function()
    local f = fixture()
    local record = pending(f)
    local repeated = assert(f.service:completeCreation(record.id, nil, { transmitted = false, definitive = true }))
    check(repeated.state == "pending" and repeated.code_url == record.code_url)
end)

test("conflicting creation identities never replace a retained order", function()
    local f = fixture()
    local record = pending(f)
    local observed, err = f.service:completeCreation(record.id, response("90071992547409939999"))
    check(observed.order_id == record.order_id and err.kind == "recharge_order_conflict")
    check(assert(f.service:get(record.id)).order_id == record.order_id)
end)

test("history requires an exact canonical decimal string identity", function()
    local f = fixture()
    local record = pending(f, "first", "123456789012345678")
    local missed = assert(f.service:applyHistory(record.id, { { order_id = "123456789012345679" },
        { order_id = 123456789012345678 }, { order_id = "0123456789012345678" }, { order_id = "different", raw_pay_amount = 500 } }))
    check(missed.state == "pending" and missed.history_match == false)
    local matched = assert(f.service:applyHistory(record.id, { { order_id = "123456789012345678", raw_pay_amount = "5.00", product_amount = 500 } }))
    check(matched.state == "credited" and matched.history_evidence.raw_pay_amount == "5.00")
    check(matched.history_evidence.amount_unit == "unverified" and not matched.history_evidence.amount_cents)
end)

test("unrelated history and equal amounts cannot resolve an order without an identity", function()
    local f = fixture()
    local record = create(f.service)
    f.service:completeCreation(record.id, nil, { kind = "timeout" })
    local observed = assert(f.service:applyHistory(record.id, { { order_id = "123456789012345679", raw_pay_amount = 500, product_amount = 500 } }))
    check(observed.state == "unknown" and observed.history_match == false)
end)

test("credited evidence is monotonic across later empty history pages", function()
    local f = fixture()
    local record = pending(f)
    f.service:applyHistory(record.id, { { order_id = record.order_id } })
    f.now = f.now + 100
    local observed = assert(f.service:applyHistory(record.id, {}))
    check(observed.state == "credited" and observed.history_match and observed.credited_confirmed)
    check(observed.credited_observed_at == 1800000000)
end)

test("missing server expiry never creates a local expired or unpaid outcome", function()
    local f = fixture()
    local record = pending(f)
    f.now = f.now + 86400 * 30
    local observed = assert(f.service:get(record.id))
    check(observed.state == "pending" and not observed.expires_at and not observed.qr_expired)
    observed = assert(f.service:applyHistory(record.id, {}))
    check(observed.state == "pending")
end)

test("server QR expiry does not cancel history reconciliation", function()
    local f = fixture()
    local record = create(f.service)
    local result = response(); result.expires_at = f.now + 30
    f.service:completeCreation(record.id, result)
    f.now = f.now + 31
    local observed = assert(f.service:get(record.id))
    check(observed.qr_expired and observed.state == "pending")
    observed = assert(f.service:applyHistory(record.id, { { order_id = result.order_id } }))
    check(observed.state == "credited" and observed.credited_confirmed)
end)

test("prepare write failure never authorizes dispatch and gates later creation until flush", function()
    local f = fixture(); f.store.fail_writes = true
    local value, err = f.service:prepare(500, metadata("first"))
    rejected(value, err, "storage")
    check(err.transmitted == false and err.definitive == true and err.local_id)
    local retained = assert(f.service:get(err.local_id))
    check(retained.state == "failed_not_submitted" and retained.persistence_pending)
    local second, pending_error = f.service:prepare(500, metadata("second"))
    rejected(second, pending_error, "persistence_pending")
    f.store.fail_writes = false
    check(f.service:flush())
    create(f.service, "second")
    check(#assert(f.service:list()) == 2)
end)

test("post-commit prepare interruption cannot consume the same confirmation twice", function()
    local f = fixture(); f.store.fail_after_commit = true
    local value, err = f.service:prepare(500, metadata("first"))
    rejected(value, err, "storage")
    f.store.fail_after_commit = false
    local restarted = f:newService()
    check(restarted:recover())
    local duplicate, duplicate_error = restarted:prepare(500, metadata("first"))
    rejected(duplicate, duplicate_error, "duplicate_confirmation")
    check(assert(restarted:list())[1].state == "unknown")
end)

test("observed server order survives a write failure and flushes without creation replay", function()
    local f = fixture()
    local record = create(f.service)
    f.store.fail_writes = true
    local observed, err = f.service:completeCreation(record.id, response())
    check(observed.state == "pending" and observed.persistence_pending and observed.order_id == response().order_id and err.kind == "storage")
    check(assert(f.service:get(record.id)).code_url == response().code_url)
    f.store.fail_writes = false
    local flushed = assert(f.service:flush())
    check(flushed[1].state == "pending" and not flushed[1].persistence_pending)
    check(flushed[1].creation_attempts == 1)
end)

test("observed server order survives BEGIN failure before any storage callback runs", function()
    local f = fixture()
    local record = create(f.service)
    f.store.fail_begin = true
    local observed, err = f.service:completeCreation(record.id, response())
    check(observed and observed.order_id == response().order_id and observed.persistence_pending and err.kind == "storage")
    f.store.fail_begin = false
    check(f.service:flush())
    check(assert(f.service:get(record.id)).state == "pending")
end)

test("read failure retains a creation response without overwriting an unread journal", function()
    local f = fixture()
    local record = create(f.service)
    local writes = f.writes
    f.store.fail_reads = true
    local observed, err = f.service:completeCreation(record.id, response())
    check(observed.order_id == response().order_id and observed.persistence_pending and err.kind == "storage")
    check(f.writes == writes)
    f.store.fail_reads = false
    check(f.service:flush())
end)

test("history evidence retained during commit failure is not labeled durably credited", function()
    local f = fixture()
    local record = pending(f)
    f.store.fail_commit = true
    local observed, err = f.service:applyHistory(record.id, { { order_id = record.order_id } })
    check(observed.state == "credited" and observed.persistence_pending and not observed.credited_confirmed and err.kind == "storage")
    local value, gated = f.service:prepare(500, metadata("second"))
    rejected(value, gated, "persistence_pending")
    f.store.fail_commit = false
    check(f.service:flush())
    check(assert(f.service:get(record.id)).credited_confirmed)
end)

test("a stale retained observation cannot overwrite another instance's credited evidence", function()
    local f = fixture()
    local record = create(f.service)
    f.store.fail_writes = true
    f.service:completeCreation(record.id, response())
    f.store.fail_writes = false
    local other = f:newService()
    other:completeCreation(record.id, response())
    other:applyHistory(record.id, { { order_id = response().order_id } })
    local flushed = assert(f.service:flush())
    check(flushed[1].state == "credited" and flushed[1].credited_confirmed)
end)

test("returned storage errors are failures even when the store does not throw", function()
    local f = fixture(); f.store.return_write_error = true
    local value, err = f.service:prepare(500, metadata("first"))
    rejected(value, err, "storage")
    check(value == nil and err.transmitted == false)
end)

test("account namespaces do not expose or reconcile another account's order", function()
    local f = fixture(); f.store.account_key = nil
    local first = f:newService("account-a")
    local second = f:newService("account-b")
    local a = create(first, "same-token"); first:completeCreation(a.id, response("10000000000000000001"))
    local b = create(second, "same-token"); second:completeCreation(b.id, response("20000000000000000002"))
    local observed = assert(second:applyHistory(b.id, { { order_id = "10000000000000000001" } }))
    check(observed.state == "pending" and assert(first:get(a.id)).order_id == "10000000000000000001")
    local wrong = { { order_id = "20000000000000000002" } }; wrong.account_key = "account-a"
    local value, err = second:applyHistory(b.id, wrong)
    rejected(value, err, "account_mismatch")
end)

test("constructor and later store account changes are rejected", function()
    local f = fixture()
    local ok = pcall(function() f:newService("account-b") end)
    check(not ok)
    create(f.service)
    f.store.account_key = "account-b"
    local value, err = f.service:list()
    rejected(value, err, "account_mismatch")
end)

test("metadata snapshots exclude session material and unknown top-level metadata", function()
    local f = fixture()
    local input = metadata("first")
    input.cookies, input.extra = "synthetic-secret", { authorization = "synthetic-secret" }
    input.config_snapshot.CookieHeader = "synthetic-secret"
    input.config_snapshot.options[1].session = { cookies = "synthetic-secret" }
    input.config_snapshot.options[1].authorization = "synthetic-secret"
    local record = assert(f.service:prepare(500, input))
    check(not record.metadata.cookies and not record.metadata.extra and not record.metadata.config_snapshot.CookieHeader)
    check(not record.metadata.config_snapshot.options[1].session and not record.metadata.config_snapshot.options[1].authorization)
    check(record.metadata.confirmation_token == "first")
end)

test("malformed journals are not silently reset to permit new creation", function()
    local f = fixture()
    f.store.values[f.service.setting_key] = { schema_version = 1, account_key = "account-a", sequence = 1,
        orders = { broken = { id = "broken", account_key = "account-a", state = "pending", sequence = 1,
            created_at = f.now, amount_cents = 500, metadata = 99 } } }
    local value, err = f.service:prepare(500, metadata("first"))
    rejected(value, err, "recharge_journal_invalid")
    check(f.writes == 0)
end)

test("malformed history is not accepted as a successful empty query", function()
    local f = fixture()
    local record = pending(f)
    local value, err = f.service:applyHistory(record.id, { order_id = record.order_id })
    rejected(value, err, "invalid_recharge_history")
end)

test("nested transactions cannot authorize creation before an outer commit", function()
    local f = fixture(); f.store._depth = 1
    local value, err = f.service:prepare(500, metadata("first"))
    rejected(value, err, "nested_transaction")
    check(f.writes == 0)
end)

test("close marks creating unknown and does not prevent retaining a late valid response", function()
    local f = fixture()
    local record = create(f.service)
    check(f.service:close())
    check(assert(f.service:get(record.id)).state == "unknown")
    local value, err = f.service:prepare(500, metadata("second"))
    rejected(value, err, "closed")
    local observed = assert(f.service:completeCreation(record.id, response()))
    check(observed.state == "pending" and observed.creation_attempts == 1)
end)

if arg[3] then
    test("real SQLite store preserves exact identities and interrupted creation across reopen", function()
        require("setupkoenv")
        local Store = require("bilicomics/storage/store")
        local options = { root = arg[3], account_key = "synthetic-recharge-restart", wal = false }
        local store = Store.open(options)
        local function serviceFor(target)
            return Service.new{ store = target, account_key = options.account_key, clock = function() return 1800000000 end }
        end
        local service = serviceFor(store)
        local first = create(service, "durable-first")
        check(service:completeCreation(first.id, response("90071992547409931234")))
        local interrupted = create(service, "durable-interrupted")
        store:close()
        store = Store.open(options)
        service = serviceFor(store)
        local recovered, err = service:recover()
        check(recovered and not err and #recovered == 2)
        check(assert(service:get(interrupted.id)).state == "unknown")
        local saved = assert(service:get(first.id))
        check(saved.state == "pending" and saved.order_id == "90071992547409931234")
        local duplicate, duplicate_error = service:prepare(500, metadata("durable-interrupted"))
        rejected(duplicate, duplicate_error, "duplicate_confirmation")
        check(service:applyHistory(first.id, { { order_id = "90071992547409931234", raw_pay_amount = "5.00" } }))
        store:close()
        store = Store.open(options)
        local credited = assert(serviceFor(store):get(first.id))
        check(credited.state == "credited" and credited.credited_confirmed and credited.history_evidence.raw_pay_amount == "5.00")
        store:close()
    end)
end

local passed = true
for _, result in ipairs(results) do if not result.passed then passed = false end end
local summary = string.format('{"passed":%s,"tests":%d,"assertions":%d,"network_calls":0}', tostring(passed), #results, assertions)
print(summary)
if arg[2] then
    local file = assert(io.open(arg[2], "wb"))
    file:write(summary .. "\n"); file:close()
end
if not passed then os.exit(1) end
