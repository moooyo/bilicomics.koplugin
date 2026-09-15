-- Verify expiry display with native chapter widgets and read-only metadata fixtures.
-- No production controller, network client, or payment helper is available.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local output_dir, plugin = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
local prohibited_modules = { "bilicomics/controller", "bilicomics/runtime", "bilicomics/protocol/client",
    "bilicomics/protocol/transport", "bilicomics/purchase/service", "bilicomics/purchase/quote",
    "bilicomics/purchase/candidate", "bilicomics/purchase/selection", "bilicomics/purchase/quote_fetch" }
for _module_index, name in ipairs(prohibited_modules) do
    assert(package.loaded[name] == nil, "A prohibited business module was already loaded")
    package.preload[name] = function() error("Business modules are prohibited in the entitlement display spec") end
end
require("gettext").current_lang = "zh_CN"
local UIManager = require("ui/uimanager")
local json = require("rapidjson")
local Model = require("bilicomics/ui/model")
local Screens = require("bilicomics/ui/screens")
local _ = require("bilicomics/ui/i18n")
local report = { spec = "native-entitlement-display", runtime = "KOReader v2026.07.1",
    width = Device.screen:getWidth(), height = Device.screen:getHeight(),
    read_only_metadata = true, purchase_tests_executed = false, assertions = {}, screens = {} }
local function check(name, condition, detail)
    report.assertions[#report.assertions + 1] = { name = name, passed = not not condition, detail = detail }
    assert(condition, name)
end
local function contains(text, fragment)
    return type(text) == "string" and text:find(fragment, 1, true) ~= nil
end
local function hasChinese(text)
    return type(text) == "string" and text:find("[\228-\233][\128-\191][\128-\191]") ~= nil
end
local unknown = _("Temporary access expiry is unknown.")
local function expected(timestamp)
    return string.format(_("Temporary access expires: %s (UTC)"), timestamp)
end
local native_date = os.date
local function usingDate(stub, callback)
    os.date = stub
    local ok, result = pcall(callback)
    os.date = native_date
    assert(ok, result)
    return result
end

local controller = { calls = {}, forbidden = {}, episodes = {}, generation = 1,
    comic = { id = "10", title = "Synthetic expiry catalog", authors = { "Metadata fixture" },
        current_episode_id = "17", favorite = false } }
local read_methods = { getComic = true, getEpisodes = true, getAccount = true }
local function record(method)
    assert(read_methods[method], "Only read-only metadata getters are allowed")
    controller.calls[#controller.calls + 1] = method
end
function controller:getComic(comic_id)
    record("getComic"); assert(comic_id == "10"); return self.comic
end
function controller:getEpisodes(comic_id)
    record("getEpisodes"); assert(comic_id == "10"); return self.episodes
end
function controller:getAccount()
    record("getAccount"); return { id = "expiry_fixture", account_key = "bili_expiry_fixture" }
end
function controller:cancelPendingRead() end
setmetatable(controller, { __index = function(_controller, key)
    -- These are optional metadata features, not operations permitted by the spec.
    if key == "requestCover" or key == "isFavoritePending" then return nil end
    controller.forbidden[#controller.forbidden + 1] = tostring(key)
    error("Controller member is outside the read-only metadata allowlist: " .. tostring(key))
end })
local screens = Screens.new{ controller = controller }
screens:_ensureRouteViews()
local function textWidgets(widget, result, seen)
    result, seen = result or {}, seen or {}
    if type(widget) ~= "table" or seen[widget] then return result end
    seen[widget] = true
    if type(widget.text) == "string" then result[#result + 1] = widget end
    for _child_index, child in ipairs(widget) do textWidgets(child, result, seen) end
    return result
end
local function screenText()
    local texts = {}
    for _widget_index, widget in ipairs(textWidgets(screens.widget)) do texts[#texts + 1] = widget.text end
    return table.concat(texts, "\n")
end
local function screenButton(message)
    for _row_index, row in ipairs(screens.focus or {}) do
        for _button_index, button in ipairs(row) do if button.text == _(message) then return button end end
    end
end
local function press(message)
    if message == "Current chapter" then
        local jump = assert(screenButton("Jump…"), "Missing chapter jump control")
        assert(jump.callback and jump.enabled ~= false)
        jump.callback()
        for _row_index, row in ipairs(assert(screens.dialog).buttons) do
            for _button_index, button in ipairs(row) do
                if button.text == _(message) then
                    assert(button.callback and button.enabled ~= false)
                    button.callback(); return
                end
            end
        end
        error("The jump picker must expose the current chapter")
    end
    local button = assert(screenButton(message), "Missing navigation button: " .. message)
    assert(button.callback and button.enabled ~= false, "The requested navigation button is disabled")
    button.callback()
end
local function currentVisible()
    for _row_index, row in ipairs(screens.focus or {}) do
        for _button_index, button in ipairs(row) do
            if contains(button.text, "Synthetic chapter 17") then return true end
        end
    end
    return false
end
local function expiryTexts()
    local result = {}
    for _widget_index, widget in ipairs(textWidgets(screens.widget)) do
        if widget.text == unknown or contains(widget.text, "UTC") then result[#result + 1] = widget end
    end
    return result
end
local function capture(name)
    local widget = assert(screens.widget)
    local size = widget.content:getSize()
    check(name .. "_content_fits", size.w <= report.width and size.h <= report.height, { width = size.w, height = size.h })
    UIManager:forceRePaint()
    check(name .. "_has_no_dialog", screens.dialog == nil)
    for index, expiry_widget in ipairs(expiryTexts()) do
        check(name .. "_expiry_" .. index .. "_uses_the_chapter_content_width",
            expiry_widget.width > 0 and expiry_widget.width <= screens.width)
        local box = expiry_widget:getSize()
        check(name .. "_expiry_" .. index .. "_fits", box.w <= report.width and box.h <= report.height)
    end
    Device.screen.bb:writePNG(output_dir .. "/" .. name .. ".png")
    report.screens[#report.screens + 1] = name .. ".png"
end
local function populate(with_temporary)
    controller.episodes = {}
    for index = 1, 18 do
        local access = index % 2 == 0 and "owned" or "free"
        if with_temporary and (index % 4 == 1 or index % 4 == 2) then access = "temporary" end
        controller.episodes[index] = { id = tostring(index), comic_id = "10", order = index,
            title = "Synthetic chapter " .. index, access = access,
            expires_at = index == 2 and nil or index == 17 and 2147483647 or 1704067200,
            read = index == 3, cached_pages = 0, total_pages = 12 }
    end
    -- An absent normalized timestamp must remain visibly unknown.
    if with_temporary then controller.episodes[2].expires_at = nil end
    screens:close()
    screens.loaded["comic:10"] = true
    screens:showComic("10")
end

local function run()
    check("expiry_formatter_is_available", type(Model.entitlementExpiry) == "function")
    check("expiry_messages_have_chinese_translations", hasChinese(unknown) and hasChinese(expected("2024-01-01 00:00:00")))
    for _case_index, case in ipairs({
        { name = "epoch_one", value = 1, timestamp = "1970-01-01 00:00:01" },
        { name = "year_2000", value = 946684800, timestamp = "2000-01-01 00:00:00" },
        { name = "leap_day", value = 951782400, timestamp = "2000-02-29 00:00:00" },
        { name = "fixed_2024", value = 1704067200, timestamp = "2024-01-01 00:00:00" },
        { name = "signed_32_bit_edge", value = 2147483647, timestamp = "2038-01-19 03:14:07" },
    }) do
        local episode = { access = "temporary", expires_at = case.value }
        local label = Model.entitlement(episode)
        local rendered = Model.entitlementExpiry(episode)
        check(case.name .. "_formats_the_exact_utc_instant", rendered == expected(case.timestamp) and contains(rendered, "UTC"))
        check(case.name .. "_does_not_change_access", episode.access == "temporary" and episode.expires_at == case.value
            and Model.entitlement(episode) == label and label == _("Temporary access"))
    end
    for _case_index, case in ipairs({
        { name = "missing" }, { name = "zero", value = 0 }, { name = "negative", value = -1 },
        { name = "fractional", value = 1704067200.5 }, { name = "numeric_string", value = "1704067200" },
        { name = "unparsed_date", value = "2026-09-12 08:00:00" }, { name = "empty_string", value = "" },
        { name = "boolean", value = true }, { name = "table", value = {} }, { name = "nan", value = 0 / 0 },
        { name = "positive_infinity", value = math.huge }, { name = "negative_infinity", value = -math.huge },
        { name = "past_supported_year", value = 253402300800 }, { name = "millisecond_shaped_value", value = 1704067200000 },
        { name = "huge_number", value = 1e20 },
    }) do
        local episode = { access = "temporary", expires_at = case.value }
        check(case.name .. "_is_explicitly_unknown", Model.entitlementExpiry(episode) == unknown)
        check(case.name .. "_keeps_the_existing_access_label", episode.access == "temporary"
            and Model.entitlement(episode) == _("Temporary access"))
    end
    for _access_index, access in ipairs({ "free", "owned" }) do
        for _value_index, value in ipairs({ 1704067200, 0, "2026-09-12 08:00:00" }) do
            local episode = { access = access, expires_at = value }
            local label = Model.entitlement(episode)
            check(access .. "_omits_expiry_" .. _value_index, Model.entitlementExpiry(episode) == nil
                and episode.access == access and Model.entitlement(episode) == label)
        end
    end

    local formats = {}
    local rendered = usingDate(function(format, value)
        formats[#formats + 1] = format
        return native_date(format, value)
    end, function() return Model.entitlementExpiry({ access = "temporary", expires_at = 1704067200 }) end)
    check("formatting_explicitly_requests_a_utc_calendar_table", #formats == 1 and formats[1] == "!*t"
        and rendered == expected("2024-01-01 00:00:00"))
    for _case_index, case in ipairs({
        { name = "platform_error", date = function() error("Synthetic date range failure") end },
        { name = "platform_nil", date = function() return nil end },
        { name = "malformed_calendar", date = function() return { year = 2024, month = 13, day = 1, hour = 0, min = 0, sec = 0 } end },
        { name = "wrapped_instant", date = function() return native_date("!*t", 1) end },
    }) do
        local result = usingDate(case.date, function()
            return Model.entitlementExpiry({ access = "temporary", expires_at = 1704067200 })
        end)
        check(case.name .. "_cannot_display_a_wrong_instant", result == unknown)
    end

    populate(true)
    check("temporary_catalog_is_paginated", screens.pages > 1 and not currentVisible())
    check("first_page_has_known_and_unknown_expiry", contains(screenText(), expected("2024-01-01 00:00:00"))
        and contains(screenText(), unknown))
    check("chapter_status_axes_keep_their_labels", contains(screenText(), _("Progress"))
        and contains(screenText(), _("Access")) and contains(screenText(), _("Storage"))
        and contains(screenText(), _("Temporary access")))
    local temporary_pages = screens.pages
    capture("temporary-first-page")
    local visited = 1
    while screens.page < screens.pages do
        press("Next"); visited = visited + 1
        capture("temporary-page-" .. screens.page)
    end
    check("all_temporary_pages_are_reachable", visited == temporary_pages)
    screens.page = 1; screens:refresh()
    press("Current chapter")
    check("current_chapter_uses_the_temporary_row_capacity", screens.page > 1 and currentVisible())
    check("current_temporary_chapter_keeps_full_expiry", contains(screenText(), expected("2038-01-19 03:14:07")))
    capture("temporary-current-chapter")
    press("Previous"); press("Current chapter")
    check("current_chapter_is_stable_after_paging", currentVisible())
    for _episode_index, episode in ipairs(controller.episodes) do
        check("metadata_access_is_unchanged_" .. _episode_index, episode.access ==
            ((_episode_index % 4 == 1 or _episode_index % 4 == 2) and "temporary" or (_episode_index % 2 == 0 and "owned" or "free")))
    end

    populate(false)
    check("ordinary_catalog_has_no_expiry_line", #expiryTexts() == 0 and screens.pages <= temporary_pages)
    capture("ordinary-first-page")
    press("Current chapter")
    check("ordinary_current_chapter_keeps_native_pagination", screens.page > 1 and currentVisible() and #expiryTexts() == 0)
    capture("ordinary-current-chapter")
    check("only_metadata_getters_were_used", #controller.forbidden == 0 and #controller.calls > 0)
    for _module_index, name in ipairs(prohibited_modules) do
        check("business_module_remains_unloaded_" .. _module_index, package.loaded[name] == nil)
    end
    report.metadata_calls = #controller.calls
end

local ok, failure = pcall(run)
os.date = native_date
report.passed, report.error, report.count = ok, not ok and tostring(failure) or nil, #report.assertions
pcall(screens.close, screens)
local file = assert(io.open(output_dir .. "/entitlement-display-result.json", "wb"))
assert(file:write(json.encode(report, { pretty = true }))); assert(file:close())
print(json.encode(report, { pretty = true }))
if not ok then error(failure) end
