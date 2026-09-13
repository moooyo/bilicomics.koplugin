local LuaSettings = require("luasettings")
local Files = require("bilicomics/storage/files")

local Settings = {}
Settings.__index = Settings
local defaults = {
    prefetch = true, prefetch_pages = 3, next_episode_pages = 2,
    cache_limit_bytes = 256 * 1024 * 1024, minimum_free_bytes = 64 * 1024 * 1024,
    worker_timeout = 90, reading_direction = "ltr", reading_mode = "auto",
    image_memory_limit_bytes = 64 * 1024 * 1024,
}
function Settings.open(root)
    Files.mkdir(root)
    return setmetatable({ data = LuaSettings:open(root .. "/settings.lua"), defaults = defaults }, Settings)
end
function Settings:get(key, fallback)
    local value = self.data:readSetting(key)
    if value ~= nil then return value end
    if fallback ~= nil then return fallback end
    return defaults[key]
end
function Settings:set(key, value)
    self.data:saveSetting(key, value)
    self.data:flush()
end
function Settings:flush() self.data:flush() end
return Settings
