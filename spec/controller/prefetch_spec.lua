-- Exercise only next-chapter prefetch policy with delayed index preparation.
-- No application account, purchase service, network worker or payment scenario is created.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(require("datastorage"):getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local root, output = assert(arg[1]), assert(arg[2])
package.path = root .. "/?.lua;" .. package.path
local Controller = require("bilicomics/controller")
local JSON = require("bilicomics/protocol/json")
local checks = {}
local function check(name, value)
    assert(value, name)
    checks[#checks + 1] = name
end
local function fixture()
    local settings = { prefetch = true, prefetch_pages = 3, next_episode_pages = 2 }
    function settings:get(key, fallback)
        if self[key] ~= nil then return self[key] end
        return fallback
    end
    local requests, prepared = {}, {}
    local integration = { generation = 17, current = true }
    function integration:isCurrent() return self.current end
    local account = { session = {}, session_valid = true, downloads = {} }
    function account.downloads:isRetiredVersion() return self.retired == true end
    function account.downloads:requestPage(descriptor, index, options)
        requests[#requests + 1] = { descriptor = descriptor, index = index, options = options }
    end
    local app = setmetatable({ account = account, active_integration = integration,
        settings = settings, preloaded = {}, connected = true,
        next_episode = { id = "102", comic_id = "1", access = "owned" } }, Controller)
    function app:_connected() return self.connected end
    function app:_nextEpisode() return self.next_episode end
    function app:prepareEpisode(comic_id, episode_id, callback)
        prepared[#prepared + 1] = { comic_id = comic_id, episode_id = episode_id, callback = callback }
    end
    local event = { descriptor = { comic_id = "1", episode_id = "101" }, reader_generation = 17 }
    local next_descriptor = { comic_id = "1", episode_id = "102", pages = { {}, {}, {}, {} } }
    return app, event, prepared, requests, next_descriptor
end

local function assertBlocked(name, mutate)
    local app, event, prepared, requests = fixture()
    mutate(app, event)
    app:_preloadNext(event)
    check(name .. "_does_not_prepare_or_fetch", #prepared == 0 and #requests == 0)
end
assertBlocked("next_chapter_disabled", function(app) app.settings.next_episode_pages = 0 end)
assertBlocked("all_prefetch_disabled", function(app) app.settings.prefetch = false end)
assertBlocked("prefetch_page_count_zero", function(app) app.settings.prefetch_pages = 0 end)
assertBlocked("suspended_reader", function(app) app.suspended = true end)
assertBlocked("closed_controller", function(app) app.closed = true end)
assertBlocked("closed_reader", function(app) app.active_integration = nil end)
assertBlocked("obsolete_reader", function(app) app.active_integration.current = false end)
assertBlocked("different_reader_generation", function(_, event) event.reader_generation = 18 end)
assertBlocked("missing_account", function(app) app.account = nil end)
assertBlocked("missing_session", function(app) app.account.session = nil end)
assertBlocked("invalid_session", function(app) app.account.session_valid = false end)
assertBlocked("retained_older_version", function(app) app.account.downloads.retired = true end)
assertBlocked("offline", function(app) app.connected = false end)
assertBlocked("locked_next_chapter", function(app) app.next_episode.access = "locked" end)
assertBlocked("unknown_next_chapter", function(app) app.next_episode.access = "unknown" end)
assertBlocked("last_chapter", function(app) app.next_episode = nil end)

do
    local app, event, prepared, requests, descriptor = fixture()
    app:_preloadNext(event); app:_preloadNext(event)
    check("one_preparation_per_reader_and_next_chapter", #prepared == 1 and #requests == 0)
    check("preparation_keeps_original_chapter_identity", prepared[1].comic_id == "1" and prepared[1].episode_id == "102")
    prepared[1].callback({ descriptor = descriptor })
    check("default_prefetch_is_first_two_images", #requests == 2 and requests[1].index == 1 and requests[2].index == 2)
    check("prefetch_keeps_prepared_descriptor_and_reader_ownership", requests[1].descriptor == descriptor
        and requests[1].options.prefetch and requests[1].options.reader_generation == 17 and requests[1].options.priority == 30)
end

local late_changes = {
    retire_version = function(app) app.account.downloads.retired = true end,
    disable_next = function(app) app.settings.next_episode_pages = 0 end,
    disable_all = function(app) app.settings.prefetch = false end,
    suspend = function(app) app.suspended = true end,
    close = function(app) app.closed = true end,
    reader_close = function(app) app.active_integration = nil end,
    reader_replace = function(app)
        app.active_integration = { generation = 17, isCurrent = function() return true end }
    end,
    account_switch = function(app) app.account = { session = {}, session_valid = true } end,
    session_expiry = function(app) app.account.session_valid = false end,
    offline = function(app) app.connected = false end,
}
for name, mutate in pairs(late_changes) do
    local app, event, prepared, requests, descriptor = fixture()
    app:_preloadNext(event)
    assert(#prepared == 1)
    mutate(app)
    prepared[1].callback({ descriptor = descriptor })
    check("late_" .. name .. "_does_not_fetch_images", #requests == 0)
end
do
    local app, event, prepared, requests, descriptor = fixture()
    app:_preloadNext(event)
    app.settings.next_episode_pages = 1
    prepared[1].callback({ descriptor = descriptor })
    check("late_lowered_count_is_honored", #requests == 1)
end
do
    local app, event, prepared, requests, descriptor = fixture()
    app.settings.next_episode_pages = 5
    app:_preloadNext(event)
    descriptor.pages = { {} }
    prepared[1].callback({ descriptor = descriptor })
    check("short_chapter_bounds_prefetch", #requests == 1 and requests[1].index == 1)
end
do
    local app, event, prepared, requests = fixture()
    app:_preloadNext(event)
    prepared[1].callback(nil, { kind = "network" })
    check("failed_index_does_not_fetch_images", #requests == 0)
end
local file = assert(io.open(output .. "/prefetch-result.json", "wb"))
file:write(assert(JSON.encode({ passed = #checks, checks = checks, network_requests = 0,
    purchase_testing = false, quote_testing = false, wallet_testing = false,
    scope = "Production Controller next-chapter policy with delayed preparation; no real account or image transfer" })))
assert(file:close())
print("PASS " .. #checks .. " next-chapter prefetch checks")
