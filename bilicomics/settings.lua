local LuaSettings = require("luasettings")
local Files = require("bilicomics/storage/files")
local dump = require("dump")

local Settings = {}
Settings.__index = Settings
local defaults = {
    prefetch = true, prefetch_pages = 3, next_episode_pages = 2,
    cache_limit_bytes = 256 * 1024 * 1024, minimum_free_bytes = 64 * 1024 * 1024,
    worker_timeout = 90, reading_direction = "ltr", reading_mode = "auto",
    download_concurrency = 2,
    image_memory_limit_bytes = 64 * 1024 * 1024,
}
function Settings.open(root)
    Files.mkdir(root)
    return setmetatable({ data = LuaSettings:open(root .. "/settings.lua"), root = root, defaults = defaults }, Settings)
end
function Settings:get(key, fallback)
    local value = self.data:readSetting(key)
    if key == "download_concurrency" then
        return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= 4 and value or defaults.download_concurrency
    end
    if value ~= nil then return value end
    if fallback ~= nil then return fallback end
    return defaults[key]
end
function Settings:_write(data)
    local path = assert(self.data.file, "A settings file is required")
    local content = "-- BiliComics settings\nreturn " .. dump(data, nil, true) .. "\n"
    assert(Files.atomicWrite(path, content, self.root or Files.parent(path)) ~= false, "Settings could not be written.")
end
function Settings:set(key, value)
    -- Build a candidate without publishing a rejected value to the running scheduler.
    local candidate = {}
    for name, current in pairs(self.data.data) do candidate[name] = current end
    candidate[key] = value
    self:_write(candidate)
    self.data:saveSetting(key, value)
end
function Settings:flush() self:_write(self.data.data) end
return Settings
