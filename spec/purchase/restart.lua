local root, data_root, phase = assert(arg[1]), assert(arg[2]), assert(arg[3])
local purpose = arg[4] or "read"
assert(purpose == "read" or purpose == "download", "Use a supported original action")
require("setupkoenv")
package.path = root .. "/?.lua;" .. package.path
local Store = require("bilicomics/storage/store")
local Service = require("bilicomics/purchase/service")
local store = Store.open({root = data_root, account_key = "purchase-restart-fixture", wal = false})
local calls = 0
local client = {
    buyEpisode = function() calls = calls + 1; error("No transmission is authorized") end,
    purchaseInfo = function() calls = calls + 1; error("No network is authorized") end,
    comicDetail = function() calls = calls + 1; error("No network is authorized") end,
}
local service = Service.new({store = store, client = client, clock = function() return 1000 end})
local episodes = {{id = "10", comic_id = "1", order = 1.5, title = "Synthetic chapter", access = "locked"}}
local info = {ep_id = "10", comic_id = "1", ep_original_gold = 30, pay_gold = 30, remain_gold = 100}
if phase == "prepare" then
    store:upsertComic({id = "1", title = "Synthetic comic"})
    store:upsertEpisodes("1", episodes)
    local quote = assert(service:buildQuote("10", nil, nil, info, {episodes = episodes}))
    local current = assert(service:buildQuote("10", nil, nil, info, {episodes = episodes}))
    store:transaction(function()
        local nested, err = service:prepareSubmission(quote, {confirmed = true}, current)
        assert(nested == nil and err.kind == "nested_transaction")
    end)
    assert(#store:listPurchases() == 0)
    print("PASS outer transaction cannot release an uncommitted purchase payload")
    local intent, payload = service:prepareSubmission(quote, {confirmed = true, purpose = purpose}, current)
    assert(intent and intent.state == "submitting" and payload.pay_amount == 30)
    assert(store:getPurchase(intent.id).state == "submitting" and store:getPurchase(intent.id).purpose == purpose)
    print("PASS real SQLite durable intent before process exit")
elseif phase == "recover" then
    local pending = assert(service:recover())
    assert(#pending == 1 and pending[1].state == "outcome_unknown")
    assert(pending[1].purpose == purpose and pending[1].quote.amount == 30)
    assert(pending[1].quote.episode_id == "10" and pending[1].episode_ids[1] == "10")
    assert(pending[1].expected_access["10"].access == "owned")
    assert(calls == 0)
    local quote = assert(service:buildQuote("10", nil, nil, info, {episodes = episodes}))
    local current = assert(service:buildQuote("10", nil, nil, info, {episodes = episodes}))
    local intent, err = service:prepareSubmission(quote, {confirmed = true}, current)
    assert(intent == nil and err.kind == "outcome_unknown")
    print("PASS separate process recovery blocks overlapping resubmission without network")
elseif phase == "confirm" then
    local pending = assert(service:listPending())
    assert(#pending == 1 and pending[1].state == "outcome_unknown")
    episodes[1].access = "owned"
    local intent = assert(service:completeReconciliation(pending[1].id, episodes))
    assert(intent.state == "access_confirmed" and intent.transaction_evidence == "none")
    assert(intent.purpose == purpose and intent.quote.episode_id == "10")
    print("PASS separate process entitlement confirmation preserves absent receipt")
elseif phase == "inspect" then
    assert(#service:listPending() == 0)
    local intents = store:listPurchases()
    assert(#intents == 1 and intents[1].state == "access_confirmed")
    assert(intents[1].confirmed_episode_ids[1] == "10" and #intents[1].unresolved_episode_ids == 0)
    assert(intents[1].purpose == purpose and intents[1].quote.episode_id == "10")
    print("PASS separate process confirmed state survives reopening")
else error("Unknown test phase") end
assert(calls == 0)
store:close()
