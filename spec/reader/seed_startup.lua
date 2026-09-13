-- Prepare local synthetic account data in a separate process before cold startup.
require("setupkoenv")
local plugin, fixture = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Files = require("bilicomics/storage/files")
local root = DataStorage:getDataDir() .. "/bilicomics/accounts/anonymous"
local store = require("bilicomics/storage/store").open{ root = root, account_key = "anonymous" }
local pages = require("bilicomics/storage/page_store").new{ root = root, account_key = "anonymous", store = store }
store:upsertComic{ id = "comic", title = "Startup fixture" }
store:upsertEpisodes("comic", {{ id = "episode", comic_id = "comic", title = "Cached chapter",
    order = 1, access = "free", extra = { current_revision = "r1" } }})
local descriptor = { schema_version = 1, account_key = "anonymous", comic_id = "comic", episode_id = "episode", revision = "r1",
    pages = {{ id = "page", index = 1, width = 600, height = 2400 }} }
local path = pages:ensureDescriptor(descriptor)
local temporary = pages.temporary_root .. "/seed.png"
Files.write(temporary, Files.read(fixture, 8 * 1024 * 1024))
local checksum = Files.digest(temporary)
pages:commitPage({ account_key = "anonymous", episode_id = "episode", revision = "r1", index = 1 },
    { temporary_path = temporary, width = 600, height = 2400, format = "png", checksum = checksum,
        geometry = { source_width = 600, source_height = 2400, exif_orientation = 1 } })
pages:pinEpisode("episode", "r1", true)
assert(pages:isComplete("episode", "r1"))
store:close()
G_reader_settings:saveSetting("lastfile", path)
G_reader_settings:flush()
local installed, err = require("bilicomics/bootstrap").installStartupPatch(plugin)
assert(installed, err and err.message)
print(require("rapidjson").encode{ descriptor = path, startup_patch = installed })
