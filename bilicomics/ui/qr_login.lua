local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local QRWidget = require("ui/widget/qrwidget")
local UIManager = require("ui/uimanager")
local W = require("bilicomics/ui/widgets")
local _ = require("bilicomics/ui/i18n")

local QRLogin = {}
QRLogin.__index = QRLogin

function QRLogin.new(options)
    return setmetatable({ controller = assert(options.controller), is_current = assert(options.is_current),
        on_dialog = assert(options.on_dialog), on_close = assert(options.on_close),
        on_confirmed = assert(options.on_confirmed), active = true, sequence = 0 }, QRLogin)
end

function QRLogin:_current(confirmed)
    if not self.active then return false end
    if self.is_current(confirmed) then return true end
    self:close()
    return false
end

function QRLogin:_unschedule()
    if self.timer then UIManager:unschedule(self.timer); self.timer = nil end
end

function QRLogin:close()
    if not self.active then return end
    self.active = false
    self.sequence = self.sequence + 1
    self:_unschedule()
    self.controller:cancelQRLogin()
    local dialog = self.dialog
    self.dialog = nil
    if dialog then UIManager:close(dialog) end
    self.on_close(dialog)
end

function QRLogin:_show(status)
    if not self:_current() then return end
    if self.status == status then return end
    self.status = status
    local messages = {
        loading = _("Getting a sign-in code…"),
        waiting = _("Scan with the Bilibili app, then confirm sign-in on your phone."),
        scanned = _("Code scanned. Confirm sign-in on your phone."),
        expired = _("This code has expired. Get a new code to continue."),
        error = _("Sign-in could not be completed. Check your connection and try again."),
    }
    local buttons = { { { text = _("Cancel"), callback = function() self:close() end } } }
    if status == "expired" or status == "error" then
        buttons[1][2] = { text = _("Get a new code"), callback = function() self:start() end }
    end
    local dialog
    dialog = ButtonDialog:new{ modal = true, title = _("Sign in with QR code") .. "\n\n" .. messages[status],
        buttons = buttons,
        onCloseWidget = function(widget)
            ButtonDialog.onCloseWidget(widget)
            if self.dialog == widget then self:close() end
        end,
    }
    if status == "waiting" or status == "scanned" then
        local width = dialog:getAddedWidgetAvailableWidth()
        local size = math.floor(math.min(width - W.scale(20), Device.screen:getHeight() * 0.38, W.scale(290)))
        local qr = QRWidget:new{ text = self.code.url, width = size, height = size, scale_factor = 1 }
        -- A white quiet zone surrounds the native QR image for reliable scanning.
        local centered = CenterContainer:new{ dimen = Geom:new{ w = width, h = size + W.scale(24) },
            parent = dialog, not_focusable = true, qr }
        dialog:addWidget(centered)
    end
    local previous = self.dialog
    self.dialog = dialog
    if previous then UIManager:close(previous) end
    self.on_dialog(dialog)
    UIManager:show(dialog)
end

function QRLogin:_schedule()
    if not self:_current() then return end
    self:_unschedule()
    local timer
    timer = function()
        if self.timer ~= timer then return end
        self.timer = nil
        self:_poll()
    end
    self.timer = timer
    UIManager:scheduleIn(3, timer)
end

function QRLogin:_poll()
    if not self:_current() or self.inflight or not self.code then return end
    if self.code.expires_at and os.time() >= self.code.expires_at then
        self:_show("expired"); self.controller:cancelQRLogin(); return
    end
    self.inflight = true
    local sequence, completed = self.sequence, false
    local function done(result, err)
        if completed then return end
        completed = true
        if sequence ~= self.sequence or not self:_current(result and result.status == "confirmed") then return end
        self.inflight = false
        if err or not result then self:_show("error"); return end
        if result.status == "confirmed" then
            self:close()
            self.on_confirmed()
        elseif result.status == "expired" then
            self:_show("expired"); self.controller:cancelQRLogin()
        elseif result.status == "waiting" or result.status == "scanned" then
            self:_show(result.status); self:_schedule()
        else
            self:_show("error")
        end
    end
    local ok = pcall(function() self.controller:pollQRLogin(self.code.key, done) end)
    if not ok then done(nil, { kind = "internal" }) end
end

function QRLogin:start()
    if not self:_current() then return end
    self.sequence = self.sequence + 1
    self:_unschedule()
    self.inflight, self.code, self.status = true, nil, nil
    self.controller:cancelQRLogin()
    self:_show("loading")
    local sequence, completed = self.sequence, false
    local function done(result, err)
        if completed then return end
        completed = true
        if sequence ~= self.sequence or not self:_current() then return end
        self.inflight = false
        if err or type(result) ~= "table" or type(result.url) ~= "string" or result.url == ""
            or type(result.key) ~= "string" or result.key == "" then self:_show("error"); return end
        self.code = result
        self:_show("waiting")
        self:_schedule()
    end
    local ok = pcall(function() self.controller:beginQRLogin(done) end)
    if not ok then done(nil, { kind = "internal" }) end
end

return QRLogin
