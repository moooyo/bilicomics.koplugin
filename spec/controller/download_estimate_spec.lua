-- Run in an authorized KOReader runtime with synthetic records and real SQLite.
require("setupkoenv")
local source, output = assert(arg[1]), assert(arg[2])
package.path = source .. "/?.lua;" .. package.path
local Catalog = require("bilicomics/catalog/init")
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Codec = require("bilicomics/storage/codec")
local Files = require("bilicomics/storage/files")
local Estimate = require("bilicomics/download_estimate")
local JSON = require("bilicomics/protocol/json")
local contexts, passed, sequence = {}, {}, 0

Files.mkdir(output)

local function fixture()
    sequence = sequence + 1
    local c = { key = "estimate-account", root = output .. "/estimate-account-" .. sequence }
    c.store = Store.open({ root = c.root, account_key = c.key, wal = false })
    c.pages = PageStore.new({ root = c.root, account_key = c.key, store = c.store })
    c.catalog = Catalog.new({ store = c.store, pages = c.pages })
    c.store:upsertComic({ id = "81", title = "Synthetic comic" })
    c.store:upsertEpisodes("81", {
        { id = "101", order = 1, access = "free", title = "First" },
        { id = "102", order = 2, access = "free", title = "Second" },
        { id = "103", order = 3, access = "free", title = "Third" },
    })
    c.store:upsertEpisodes("82", { { id = "201", order = 1, access = "free", title = "Other comic" } })
    contexts[#contexts + 1] = c
    return c
end

local function chapter(c, episode_id, revision, count, comic_id)
    local value = { schema_version = 1, account_key = c.key, comic_id = comic_id or "81",
        episode_id = episode_id, revision = revision, pages = {} }
    for index = 1, count do
        value.pages[index] = { id = "image-" .. index, index = index, width = 20, height = 40 }
    end
    c.pages:ensureDescriptor(value)
    local episode = c.store:getEpisode(episode_id)
    episode.extra = episode.extra or {}
    episode.extra.current_revision = revision
    c.store:upsertEpisodes(episode.comic_id, { episode })
    return value
end

local function ready(c, value, index, bytes)
    local page = c.store:getPage(value.episode_id .. "/" .. value.revision .. "/" .. index)
    page.path = c.pages.pages_root .. "/" .. value.episode_id .. "/" .. value.revision .. "/" .. index .. ".png"
    Files.mkdir(Files.parent(page.path))
    Files.write(page.path, string.rep("x", bytes))
    page.state, page.bytes = "ready", bytes
    return c.store:putPage(page)
end

local function counts(c, episode_id, fields)
    local episode = c.store:getEpisode(episode_id)
    for key, value in pairs(fields) do episode[key] = value end
    c.store:upsertEpisodes(episode.comic_id, { episode })
end

local function expect(value, bytes, known_bytes, estimated, known, total)
    assert(value.bytes == bytes and value.known_bytes == known_bytes and value.estimated == estimated
        and value.known_chapters == known and value.total_chapters == total,
        "Unexpected estimate: " .. Codec.canonical(value))
end

local function test(name, fn)
    local ok, failure = xpcall(fn, debug.traceback)
    for _, c in ipairs(contexts) do if c.store.connection then c.store:close() end end
    contexts = {}
    assert(ok, name .. ": " .. tostring(failure))
    passed[#passed + 1] = name
    print("PASS " .. name)
end

test("An empty selection is exactly zero without an account", function()
    expect(Estimate.estimate(nil, nil, nil), 0, 0, false, 0, 0)
    expect(Estimate.estimate(nil, nil, {}), 0, 0, false, 0, 0)
    expect(Estimate.estimate(nil, nil, { ["101"] = false }), 0, 0, false, 0, 0)
end)

test("Fully cached chapters use actual bytes and deduplicate numeric and string IDs", function()
    local c = fixture()
    local value = chapter(c, "101", "current", 2)
    ready(c, value, 1, 100); ready(c, value, 2, 200)
    expect(Estimate.estimate(c, "81", { "101", 101, "101" }), 300, 300, false, 1, 1)
    expect(Estimate.estimate(c, "81", { [101] = true, ["102"] = false }), 300, 300, false, 1, 1)
end)

test("Partial chapters extrapolate their own observed page mean", function()
    local c = fixture()
    local value = chapter(c, "101", "current", 4)
    ready(c, value, 1, 100); ready(c, value, 3, 200)
    expect(Estimate.estimate(c, "81", { "101" }), 600, 600, true, 1, 1)
end)

test("A zero-sample current descriptor supplies its authoritative page count", function()
    local c = fixture()
    local value = chapter(c, "101", "current", 2)
    ready(c, value, 1, 100); ready(c, value, 2, 200)
    chapter(c, "102", "current", 4)
    expect(Estimate.estimate(c, "81", { "102" }), 600, 600, true, 1, 1)
end)

test("Declared episode counts permit same-comic extrapolation without a descriptor", function()
    for _, field in ipairs({ "image_count", "extra.image_count", "total_pages", "extra.total_pages" }) do
        local c = fixture()
        local value = chapter(c, "101", "current", 1)
        ready(c, value, 1, 120)
        if field:find("extra.", 1, true) then counts(c, "102", { extra = { [field:sub(7)] = "5" } })
        else counts(c, "102", { [field] = "5" }) end
        expect(Estimate.estimate(c, "81", { "102" }), 600, 600, true, 1, 1)
    end
end)

test("Missing or invalid declared counts remain unknown", function()
    for _, value in ipairs({ 0, -1, 1.5, "invalid", false }) do
        local c = fixture()
        local source = chapter(c, "101", "current", 1)
        ready(c, source, 1, 100)
        counts(c, "102", { image_count = value })
        expect(Estimate.estimate(c, "81", { "102" }), nil, 0, true, 0, 1)
    end
    local c = fixture()
    local source = chapter(c, "101", "current", 1)
    ready(c, source, 1, 100)
    expect(Estimate.estimate(c, "81", { "102" }), nil, 0, true, 0, 1)
end)

test("Unknown foreign and invalid selected entries prevent a complete estimate", function()
    local c = fixture()
    local value = chapter(c, "101", "current", 1)
    ready(c, value, 1, 100)
    for _, selected in ipairs({ "999", "201", "" }) do
        expect(Estimate.estimate(c, "81", { "101", selected }), nil, 100, true, 1, 2)
    end
    expect(Estimate.estimate(c, "81", { "101", false, {} }), nil, 100, true, 1, 3)
end)

test("Other-comic samples cannot supply a mean", function()
    local c = fixture()
    local value = chapter(c, "201", "current", 1, "82")
    ready(c, value, 1, 800)
    counts(c, "102", { image_count = 4 })
    expect(Estimate.estimate(c, "81", { "102" }), nil, 0, true, 0, 1)
end)

test("A retained older revision never supplies current estimate evidence", function()
    local c = fixture()
    local old = chapter(c, "101", "old", 1)
    ready(c, old, 1, 100)
    chapter(c, "101", "current", 2)
    chapter(c, "102", "current", 3)
    expect(Estimate.estimate(c, "81", { "101", "102" }), nil, 0, true, 0, 2)
    local bytes, count, total = Estimate.storedBytes(c, "81", "101", "old")
    assert(bytes == 100 and count == 1 and total == 1)
end)

test("A missing authoritative revision cannot revive Catalog's legacy fallback", function()
    local c = fixture()
    local old = chapter(c, "101", "old", 1)
    ready(c, old, 1, 100)
    counts(c, "101", { extra = { current_revision = "absent" } })
    assert(c.catalog:getDescriptor("101").revision == "old")
    expect(Estimate.estimate(c, "81", { "101" }), nil, 0, true, 0, 1)
end)

test("A replacement marker rejects stale current and local revision evidence", function()
    local c = fixture()
    local old = chapter(c, "101", "old", 1)
    ready(c, old, 1, 100)
    chapter(c, "101", "replacement", 2)
    counts(c, "101", { extra = { current_revision = "old", local_revision = "old",
        source_replacement_revision = "replacement" } })
    assert(c.catalog:getDescriptor("101").revision == "old")
    expect(Estimate.estimate(c, "81", { "101" }), nil, 0, true, 0, 1)
    counts(c, "102", { image_count = 4 })
    expect(Estimate.estimate(c, "81", { "102" }), nil, 0, true, 0, 1)
end)

test("A retired revision cannot contribute through Catalog's legacy fallback", function()
    local c = fixture()
    local old = chapter(c, "101", "old", 1)
    ready(c, old, 1, 100)
    counts(c, "101", { extra = {} })
    c.store:putJob({ id = "retired-job", kind = "episode_download", state = "canceled",
        comic_id = "81", episode_id = "101", revision = "old", payload = { replaced_by = "new-job" } })
    assert(c.catalog:getDescriptor("101").revision == "old")
    expect(Estimate.estimate(c, "81", { "101" }), nil, 0, true, 0, 1)
    counts(c, "102", { image_count = 4 })
    expect(Estimate.estimate(c, "81", { "102" }), nil, 0, true, 0, 1)
    assert(Estimate.storedBytes(c, "81", "101", "old") == 100)
end)

test("Missing mismatched empty and non-ready files are not observed bytes", function()
    local c = fixture()
    local value = chapter(c, "101", "current", 6)
    local absent = ready(c, value, 1, 10); assert(os.remove(absent.path))
    local mismatch = ready(c, value, 2, 10); mismatch.bytes = 11; c.store:putPage(mismatch)
    local empty = ready(c, value, 3, 10); Files.write(empty.path, "")
    local failed = ready(c, value, 4, 10); failed.state = "failed"; c.store:putPage(failed)
    local wrong_id = ready(c, value, 5, 10); wrong_id.id = "different-image"; c.store:putPage(wrong_id)
    local invalid_bytes = ready(c, value, 6, 10); invalid_bytes.bytes = "10"; c.store:putPage(invalid_bytes)
    local bytes, count, total = Estimate.storedBytes(c, "81", "101", "current")
    assert(bytes == 0 and count == 0 and total == 6)
    expect(Estimate.estimate(c, "81", { "101" }), nil, 0, true, 0, 1)
end)

test("Files outside the account page root and symbolic links are excluded", function()
    local c = fixture()
    local value = chapter(c, "101", "current", 2)
    local outside = ready(c, value, 1, 30)
    outside.path = c.root .. "/outside.png"; Files.write(outside.path, string.rep("x", 30)); c.store:putPage(outside)
    local link = ready(c, value, 2, 40)
    local target = link.path .. ".target"; assert(os.rename(link.path, target))
    assert(require("libs/libkoreader-lfs").link(target, link.path, true))
    local bytes, count, total = Estimate.storedBytes(c, "81", "101", "current")
    assert(bytes == 0 and count == 0 and total == 2)
end)

test("Wrong descriptor account comic episode and revision identities are rejected", function()
    for _, field in ipairs({ "account_key", "comic_id", "episode_id", "revision" }) do
        local c = fixture()
        local value = chapter(c, "101", "current", 1)
        ready(c, value, 1, 100)
        value[field] = "foreign"
        -- Preserve the SQL lookup identity while corrupting the serialized descriptor.
        c.store:_exec("UPDATE descriptors SET data=? WHERE episode_id=? AND revision=?",
            { Codec.encode(value), "101", "current" })
        assert(Estimate.storedBytes(c, "81", "101", "current") == nil)
        expect(Estimate.estimate(c, "81", { "101" }), nil, 0, true, 0, 1)
    end
end)

test("Invalid descriptor geometry cannot supply authoritative page evidence", function()
    for _, field in ipairs({ "width", "height" }) do
        local c = fixture()
        local value = chapter(c, "101", "current", 1)
        ready(c, value, 1, 100)
        value.pages[1][field] = 0
        c.store:_exec("UPDATE descriptors SET data=? WHERE episode_id=? AND revision=?",
            { Codec.encode(value), "101", "current" })
        assert(Estimate.storedBytes(c, "81", "101", "current") == nil)
        expect(Estimate.estimate(c, "81", { "101" }), nil, 0, true, 0, 1)
    end
end)

test("Stored bytes distinguish verified zero from an unavailable descriptor", function()
    local c = fixture()
    chapter(c, "101", "current", 2)
    local bytes, count, total = Estimate.storedBytes(c, "81", "101", "current")
    assert(bytes == 0 and count == 0 and total == 2)
    assert(Estimate.storedBytes(c, "81", "101", "missing") == nil)
    assert(Estimate.storedBytes(c, "82", "101", "current") == nil)
end)

test("Incomplete selections preserve the computable chapter subtotal", function()
    local c = fixture()
    local value = chapter(c, "101", "current", 1)
    ready(c, value, 1, 100)
    expect(Estimate.estimate(c, "81", { "101", "102" }), nil, 100, true, 1, 2)
end)

test("Selected descriptor metadata reports exact partial and unknown current copies", function()
    local c = fixture()
    local exact = chapter(c, "101", "exact", 2)
    ready(c, exact, 1, 100); ready(c, exact, 2, 200)
    local partial = chapter(c, "102", "partial", 4)
    ready(c, partial, 1, 120)
    chapter(c, "103", "empty-current", 3)
    local result = Estimate.estimate(c, "81", { "101", "102", "103", "101" })
    local metadata = result.descriptors
    assert(metadata["101"].revision == "exact" and metadata["101"].total_pages == 2
        and metadata["101"].bytes == 300 and metadata["101"].estimated == false)
    assert(metadata["102"].revision == "partial" and metadata["102"].total_pages == 4
        and metadata["102"].bytes == 480 and metadata["102"].estimated == true)
    assert(metadata["103"].revision == "empty-current" and metadata["103"].total_pages == 3
        and metadata["103"].bytes == 420 and metadata["103"].estimated == true)
    assert(result.total_chapters == 3)
    assert(Estimate.estimate(c, "81", { "101" }).descriptors["102"] == nil)

    local unknown = fixture()
    chapter(unknown, "101", "unknown-size", 32)
    local only = Estimate.estimate(unknown, "81", { "101" }).descriptors["101"]
    assert(only.revision == "unknown-size" and only.total_pages == 32
        and only.bytes == nil and only.estimated == true)
    assert(next(Estimate.estimate(nil, nil, {}).descriptors) == nil)
end)

test("Declared counts and rejected revisions cannot fabricate descriptor metadata", function()
    local c = fixture()
    local source = chapter(c, "101", "current", 1)
    ready(c, source, 1, 100)
    counts(c, "102", { image_count = 32 })
    local declared = Estimate.estimate(c, "81", { "102" })
    assert(declared.bytes == 3200 and declared.descriptors["102"] == nil)

    local old = chapter(c, "103", "old-copy", 24)
    ready(c, old, 1, 240)
    chapter(c, "103", "new-copy", 32)
    local current = Estimate.estimate(c, "81", { "103" }).descriptors["103"]
    assert(current.revision == "new-copy" and current.total_pages == 32 and current.bytes == 3200)
    counts(c, "103", { image_count = 32, extra = { current_revision = "old-copy", local_revision = "old-copy",
        source_replacement_revision = "new-copy" } })
    local mismatched = Estimate.estimate(c, "81", { "103" })
    assert(mismatched.bytes == 3200 and mismatched.descriptors["103"] == nil)

    local retired = fixture()
    local value = chapter(retired, "101", "retired", 24)
    ready(retired, value, 1, 240)
    retired.store:putJob({ id = "retired-job", kind = "episode_download", state = "canceled",
        comic_id = "81", episode_id = "101", revision = "retired", payload = { replaced_by = "new-job" } })
    assert(Estimate.estimate(retired, "81", { "101" }).descriptors["101"] == nil)
end)

test("Estimation reads real storage without repairs writes or network dispatch", function()
    local c = fixture()
    local value = chapter(c, "101", "current", 2)
    ready(c, value, 1, 100)
    local stale = ready(c, value, 2, 200); stale.bytes = 201; c.store:putPage(stale)
    local before = Codec.canonical(c.store:listAllPages())
    for _, method in ipairs({ "_exec", "transaction", "putPage", "updatePage", "upsertComic", "upsertEpisodes",
        "putDescriptor", "putSetting", "putJob", "putAnchor", "setPinned", "putCommit", "deleteCommit" }) do
        c.store[method] = function() error("Estimation must remain read-only") end
    end
    c.pages.getPage = function() error("Estimation must not repair image metadata") end
    c.pages.isComplete = c.pages.getPage
    c.runner = { submit = function() error("Estimation must not dispatch a worker") end }
    expect(Estimate.estimate(c, "81", { "101" }), 200, 200, true, 1, 1)
    assert(Estimate.storedBytes(c, "81", "101", "current") == 100)
    assert(Codec.canonical(c.store:listAllPages()) == before and Files.size(stale.path) == 200)
end)

local file = assert(io.open(output .. "/download-estimate-result.json", "wb"))
assert(file:write(assert(JSON.encode({ passed = true, count = #passed, cases = passed,
    scope = "Synthetic download size estimation with real SQLite and filesystem evidence; no network operations" }))))
assert(file:close())
