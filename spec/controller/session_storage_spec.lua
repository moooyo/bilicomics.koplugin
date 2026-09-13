require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
require("document/canvascontext"):init(require("device"))
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local result = require("spec/controller/session_storage_cases"){
    root = output .. "/shared-data", private_root = output .. "/app-private", fixture = output .. "/fixture.png" }
require("bilicomics/storage/files").write(output .. "/session-storage-result.json", require("rapidjson").encode(result, { pretty = true }))
print(require("rapidjson").encode(result, { pretty = true }))
