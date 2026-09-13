-- BiliComics managed startup provider bootstrap v1
-- Loaded by KOReader's supported late user-patch hook, before selecting lastfile.
-- This registers a document provider; it does not replace any KOReader methods.
local preferred_path = nil
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local candidates, seen = {}, {}
local disabled = G_reader_settings:readSetting("plugins_disabled", {})
if G_reader_settings:isTrue("plugins_disable_external") then return end

local function add(path)
    if type(path) ~= "string" then return end
    path = path:gsub("/+$", "")
    if not seen[path] then candidates[#candidates + 1] = path; seen[path] = true end
end
add(preferred_path)
add(lfs.currentdir() .. "/plugins/bilicomics.koplugin")
add(DataStorage:getDataDir() .. "/plugins/bilicomics.koplugin")
local extra = G_reader_settings:readSetting("extra_plugin_paths")
if type(extra) == "string" then extra = { extra } end
if type(extra) == "table" then
    for _, path in ipairs(extra) do
        if type(path) == "string" then add(path .. "/bilicomics.koplugin") end
    end
end

for _, candidate in ipairs(candidates) do
    local name = candidate:match("([^/]+)%.koplugin$")
    if name and not disabled[name]
        and lfs.attributes(candidate .. "/bilicomics/bootstrap.lua", "mode") == "file"
        and lfs.attributes(candidate .. "/main.lua", "mode") == "file" then
        package.path = candidate .. "/?.lua;" .. candidate .. "/?/init.lua;" .. package.path
        local ok = pcall(function() require("bilicomics/bootstrap").register(candidate) end)
        if not ok then require("logger").warn("BiliComics startup provider registration failed") end
        return
    end
end
