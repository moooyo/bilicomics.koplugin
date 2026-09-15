local source = debug.getinfo(1, "S").source
local plugin_path = source:match("^@(.+)/main%.lua$")
if plugin_path then
    package.path = plugin_path .. "/?.lua;" .. plugin_path .. "/?/init.lua;" .. package.path
end

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Runtime = require("bilicomics/runtime")
local Bootstrap = require("bilicomics/bootstrap")
local _ = require("bilicomics/ui/i18n")

local BiliComics = WidgetContainer:extend{ name = "bilicomics", is_doc_only = false }

function BiliComics:init()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    Bootstrap.register(plugin_path)
    local startup, startup_error = Bootstrap.installStartupPatch(plugin_path)
    self.startup_error = startup and nil or startup_error
    local ok, app = pcall(Runtime.get, self.ui)
    if ok then self.app = app else
        self.initialization_error = true
        require("logger").warn("BiliComics initialization failed; inspect storage availability and plugin dependencies")
    end
end

function BiliComics:_prepareStartupFallback()
    local available = Bootstrap.startupCapability()
    if self.startup_error or not available then
        local result, err = Bootstrap.prepareFallback()
        if not result then require("logger").warn("BiliComics startup fallback could not be saved", err and err.code) end
    end
end

function BiliComics:_open(callback)
    local ok, app, screens = pcall(Runtime.get, self.ui)
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("BiliComics could not open its local data. Check free storage and the plugin installation.") })
        return
    end
    self.app = app
    callback(app, screens)
    if self.startup_error then
        local notice = "startup_notice:" .. tostring(self.startup_error.code)
        if not app.settings:get(notice, false) then
            app.settings:set(notice, true)
            UIManager:nextTick(function()
                UIManager:show(InfoMessage:new{ text = _("Automatic comic startup is unavailable in this configuration. Open saved chapters from BiliComics; reading progress is retained.") })
            end)
        end
    end
end

function BiliComics:addToMainMenu(menu_items)
    menu_items.bilicomics = {
        text = _("Bilibili Comics"), sorting_hint = "tools",
        callback = function() self:onShowBiliComics() end,
        hold_callback = function() self:_open(function(_, screens) screens:showAccount() end) end,
    }
    if self.ui and self.ui.document and self.ui.document.provider == "bilicomics_document" then
        menu_items.bilicomics_chapter = {
            text = _("Comic actions"), sorting_hint = "navigation",
            callback = function() self:_open(function(app) app:showReaderMenu() end) end,
        }
    end
end

function BiliComics:onShowBiliComics()
    self:_open(function(_, screens) screens:showLibrary() end)
    return true
end

function BiliComics:onReaderReady()
    if self.ui and self.ui.document and self.ui.document.provider == "bilicomics_document" then
        self:_open(function(app) app:attachReader(self.ui) end)
        self:_prepareStartupFallback()
    end
end

function BiliComics:onDocSettingsLoad(config, document)
    if self.ui and document and document.provider == "bilicomics_document" then
        require("bilicomics/reader/defaults").capture(self.ui, config, true)
    end
end

function BiliComics:onSuspend()
    local app = Runtime.peek()
    if app then app:suspend() end
end
function BiliComics:onResume()
    local app = Runtime.peek()
    if app then app:resume() end
end
BiliComics.onNetworkConnected = BiliComics.onResume

function BiliComics:onFlushSettings()
    local app = Runtime.peek()
    if app and not app.closed then
        for integration in pairs(app.integrations or {}) do integration:saveAnchor() end
        app.settings:flush()
    end
    self:_prepareStartupFallback()
end
function BiliComics:onExit() self:_prepareStartupFallback(); Runtime.close() end
return BiliComics
