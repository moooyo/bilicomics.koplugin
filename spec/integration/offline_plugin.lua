-- Cross-module smoke test. Run only in the authorized remote KOReader runtime.
require("setupkoenv")
local plugin_root, fixture, result_path = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = plugin_root .. "/?.lua;" .. package.path
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local lfs = require("libs/libkoreader-lfs")
local disabled = {}
for name in lfs.dir("plugins") do
    local key = name:match("^(.*)%.koplugin$")
    if key then disabled[key] = true end
end
G_reader_settings:saveSetting("plugins_disabled", disabled)
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local json = require("rapidjson")
local Files = require("bilicomics/storage/files")
local Header = require("bilicomics/storage/image_header")
local Settings = require("bilicomics/settings")
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local root = DataStorage:getDataDir() .. "/bilicomics"
local settings = Settings.open(root)
settings:set("active_account_key", "bili_4242")
settings:set("account_summary:bili_4242", { id = "4242", name = "Offline integration fixture" })
local account_root = root .. "/accounts/bili_4242"
local store = Store.open{ root = account_root, account_key = "bili_4242" }
local pages = PageStore.new{ root = account_root, account_key = "bili_4242", store = store }
local header = Header.read(fixture)
store:upsertComic{ id = "42", title = "Native offline integration", favorite = true,
    last_read_at = os.time(), current_episode_id = "4201", latest_order = 1 }
store:upsertEpisodes("42", { { id = "4201", comic_id = "42", order = 1, title = "Offline chapter",
    access = "owned", extra = { current_revision = "smoke_1" } } })
local descriptor = { schema_version = 1, account_key = "bili_4242", comic_id = "42",
    episode_id = "4201", revision = "smoke_1", pages = {} }
for index = 1, 2 do descriptor.pages[index] = { id = "image_" .. index, index = index, width = header.width, height = header.height } end
local descriptor_path = pages:ensureDescriptor(descriptor)
for index = 1, 2 do
    local temporary = pages.temporary_root .. "/fixture-" .. index .. ".part"
    Files.atomicWrite(temporary, Files.read(fixture, 8 * 1024 * 1024))
    local checksum = Files.digest(temporary)
    pages:commitPage({ episode_id = "4201", revision = "smoke_1", index = index, expected_content_generation = 0 },
        { temporary_path = temporary, checksum = checksum, format = header.format, width = header.width, height = header.height,
          geometry = { source_width = header.width, source_height = header.height, exif_orientation = 1 } })
end
pages:pinEpisode("4201", "smoke_1", true)
store:putJob{ id = "offline-fixture", kind = "episode_download", state = "complete", comic_id = "42",
    episode_id = "4201", revision = "smoke_1", completed = 2, total = 2, payload = { title = "Offline chapter" } }
store:close()

local results = { assertions = {}, runtime = require("version"):getCurrentRevision(), scope = "Production entry, controller, storage, UI and native reader; synthetic offline images; no authenticated network" }
local function check(name, value)
    results.assertions[#results.assertions + 1] = { name = name, passed = not not value }
    assert(value, name)
end
local Plugin = assert(loadfile(plugin_root .. "/main.lua"))()
local registered
local host = { menu = { registerToMainMenu = function(_, plugin) registered = plugin end } }
local plugin = Plugin:new{ ui = host }
check("production_entry_registers_menu", registered == plugin and not plugin.initialization_error)
local menus = {}
plugin:addToMainMenu(menus)
check("tools_menu_has_library_entry", menus.bilicomics and type(menus.bilicomics.callback) == "function")
local app, screens = require("bilicomics/runtime").peek()
check("offline_account_remains_available_without_session", app:getAccount() and app:getAccount().session_valid == false)
check("controller_enriches_ready_chapter", app:getEpisodes("42")[1].downloaded == true)
check("controller_has_complete_download", app:getDownloads()[1].state == "complete")
local submitted = 0
local original_submit = app.runner.submit
app.runner.submit = function(self, ...)
    submitted = submitted + 1
    return original_submit(self, ...)
end
menus.bilicomics.callback()
check("native_business_library_is_visible", screens.widget ~= nil)
local opened, failure
UIManager:scheduleIn(0.1, function()
    app:readEpisode("42", "4201", function(value, err) opened, failure = value, err end)
end)
UIManager:scheduleIn(0.7, function()
    local reader = require("apps/reader/readerui").instance
    check("real_controller_opens_native_reader", reader and reader.document.file == descriptor_path and opened and not failure)
    check("production_reader_integration_attached", reader.bilicomics_integration ~= nil)
    check("complete_offline_read_does_not_dispatch_workers", submitted == 0)
    reader.paging:onGotoViewRel(1)
    UIManager:scheduleIn(0.4, function()
        local anchor = app.account.store:getAnchor("4201", "smoke_1")
        check("native_progress_is_persisted_through_controller", anchor ~= nil)
        reader:onClose()
        UIManager:nextTick(function()
            check("reader_close_preserves_process_service", not app.closed)
            check("pin_survives_reader_close", app.account.store:isPinned("4201", "smoke_1"))
            require("bilicomics/runtime").close()
            check("process_service_closes_cleanly", app.closed)
            UIManager:quit()
        end)
    end)
end)
UIManager:scheduleIn(10, function() error("Whole-plugin offline integration timed out") end)
local ok, err = xpcall(function() UIManager:run() end, debug.traceback)
results.passed, results.error = ok, ok and nil or err
local output = assert(io.open(result_path, "wb"))
output:write(json.encode(results, { pretty = true })); output:close()
print(json.encode(results))
if not ok then os.exit(1) end
