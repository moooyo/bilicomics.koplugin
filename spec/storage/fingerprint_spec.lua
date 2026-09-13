-- Run only on test-env. This suite exercises image storage, never purchase records.
require("setupkoenv")
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. package.path
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Files = require("bilicomics/storage/files")
local Codec = require("bilicomics/storage/codec")
local JSON = require("bilicomics/protocol/json")
local checks = {}
local function check(name, condition)
    assert(condition, name)
    checks[#checks + 1] = name
end
local root = output .. "/account"
local function open()
    local store = Store.open{ root = root, account_key = "synthetic" }
    return store, PageStore.new{ root = root, account_key = "synthetic", store = store }
end
local store, pages = open()
local descriptor = { schema_version = 1, account_key = "synthetic", comic_id = "1", episode_id = "2",
    revision = "snapshot", pages = { { id = "first", index = 1, width = 40, height = 80 },
        { id = "second", index = 2, width = 40, height = 80 } } }
local path = pages:ensureDescriptor(descriptor)
local original_descriptor = Files.read(path)
store:putAnchor("2", "snapshot", { page = 1, y = 0.45 })
local anchor = Codec.canonical(store:getAnchor("2", "snapshot"))
local sequence = 0
local function candidate(name)
    sequence = sequence + 1
    local temporary = pages.temporary_root .. "/candidate-" .. sequence .. ".part"
    Files.write(temporary, Files.read(output .. "/fixtures/" .. name .. ".png"))
    return { temporary_path = temporary, checksum = Files.digest(temporary), format = "png", width = 40, height = 80 }
end
local function commit(name)
    return pages:commitPage({ account_key = "synthetic", episode_id = "2", revision = "snapshot", index = 1 }, candidate(name))
end
local first = commit("page-a")
local digest_a = first.checksum
check("successful_commit_records_last_verified_digest", first.extra.last_committed_checksum == digest_a)
pages:removeEpisode("2", "snapshot")
local missing = store:getPage("2/snapshot/1")
check("explicit_removal_clears_active_file_but_preserves_evidence", missing.state == "missing"
    and missing.checksum == nil and missing.path == nil and missing.extra.last_committed_checksum == digest_a)
local unknown = store:getPage("2/snapshot/2")
check("never_committed_pages_do_not_gain_fabricated_evidence", not (unknown.extra or {}).last_committed_checksum)
check("new_page_history_is_explicit_after_invalidation", unknown.extra.content_history_version == 1)
store:_exec("DELETE FROM pages WHERE page_key=?", { "2/snapshot/2" })
pages:ensureDescriptor(descriptor)
local repaired = store:getPage("2/snapshot/2")
check("a_repaired_legacy_page_does_not_claim_empty_history", not (repaired.extra or {}).content_history_version)
store:close(); store, pages = open()
check("historical_digest_survives_database_reopen", store:getPage("2/snapshot/1").extra.last_committed_checksum == digest_a)
local second = commit("page-b")
local digest_b = second.checksum
check("verified_replacement_updates_historical_digest", digest_b ~= digest_a and second.extra.last_committed_checksum == digest_b)
local invalid = candidate("page-a")
invalid.checksum = string.rep("0", 64)
local accepted = pcall(pages.commitPage, pages, { episode_id = "2", revision = "snapshot", index = 1 }, invalid)
check("failed_verification_cannot_replace_historical_digest", not accepted
    and store:getPage("2/snapshot/1").extra.last_committed_checksum == digest_b)
os.remove(invalid.temporary_path)
Files.write(second.path, "synthetic corruption")
missing = pages:getPage("2", "snapshot", 1)
check("corruption_preserves_last_good_digest_without_claiming_ready", missing.state == "missing"
    and missing.checksum == nil and missing.extra.last_committed_checksum == digest_b)
local legacy = commit("page-a")
legacy.extra.last_committed_checksum = nil
legacy.extra.content_history_version = nil
store:putPage(legacy)
Files.write(legacy.path, "synthetic legacy corruption")
missing = pages:getPage("2", "snapshot", 1)
check("legacy_ready_digest_is_preserved_before_invalidation", missing.extra.last_committed_checksum == digest_a)
first = commit("page-a")
pages:evictToLimit(0)
check("automatic_eviction_retains_history", store:getPage("2/snapshot/1").extra.last_committed_checksum == digest_a
    and store:getPage("2/snapshot/1").state == "missing")
first = commit("page-a")
pages.fault_hook = function(stage) if stage == "after_journal" then error("Synthetic commit interruption") end end
accepted = pcall(commit, "page-b")
check("unpublished_journal_does_not_change_last_committed_digest", not accepted
    and store:getPage("2/snapshot/1").extra.last_committed_checksum == digest_a)
store:close(); store, pages = open()
local recovery = pages:recoverPendingCommits()
check("journal_recovery_publishes_its_verified_digest", recovery.recovered == 1
    and store:getPage("2/snapshot/1").extra.last_committed_checksum == digest_b)
check("descriptor_identity_and_anchor_are_unchanged", Files.read(path) == original_descriptor
    and Codec.canonical(store:getAnchor("2", "snapshot")) == anchor)
store:close()
Files.write(output .. "/fingerprint-result.json", assert(JSON.encode({ passed = #checks, checks = checks,
    network_requests = 0, purchase_testing = false, scope = "Real SQLite and image commit/eviction/corruption/journal recovery" })))
print("PASS " .. #checks .. " historical image fingerprint checks")
