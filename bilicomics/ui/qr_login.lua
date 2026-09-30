local BB = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
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
        on_confirmed = assert(options.on_confirmed), on_other_methods = options.on_other_methods, active = true, sequence = 0 }, QRLogin)
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

local function space(value) return W.spacePixels(W.dp(value)) end
local function face(value) return W.fontSize(value) end
local function centered(content, width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, content }
end
local function frame(content, width, height, border, fill)
    border = border or 0
    return FrameContainer:new{ padding = 0, margin = 0, radius = 0, bordersize = border,
        color = BB.Color8(0x11), background = fill or W.paper,
        centered(content, width - border * 2, height - border * 2) }
end
local QRFrame = InputContainer:extend{}
function QRFrame:init() self[1] = self.base end
function QRFrame:getSize() return Geom:new{ w = W.dp(480), h = W.dp(480) } end
function QRFrame:paintTo(bb, x, y)
    self.base:paintTo(bb, x, y)
    if self.overlay then self.overlay:paintTo(bb, x + W.dp(56), y + W.dp(150)) end
end

function QRLogin:_show(status)
    if not self:_current() or self.status == status then return end
    self.status = status
    local width, layout = Device.screen:getWidth() - W.dp(112), {}
    local rows, steps = { space(44) }, {}
    local labels = { _("Open Bilibili\nmobile app"), _("Scan the code\nbelow"), _("Confirm sign-in\non your phone") }
    local step_width = math.floor((width - W.dp(40)) / 3)
    for index, label in ipairs(labels) do
        if index > 1 then steps[#steps + 1] = W.gap(W.dp(20)) end
        local scanned = status == "scanned"
        local number = scanned and index < 3 and "✓" or tostring(index)
        local outlined = scanned and index == 3
        steps[#steps + 1] = W.row{
            frame(W.text(number, W.dp(40), face(22), { align = "center", bold = true,
                color = outlined and BB.Color8(0x11) or W.paper,
                background = outlined and W.paper or BB.Color8(0x11) }), W.dp(46), W.dp(46),
                outlined and W.dp(3) or 0, outlined and W.paper or BB.Color8(0x11)),
            W.gap(W.dp(14)), W.text(label, step_width - W.dp(60), face(19), {
                bold = outlined, muted = scanned and index < 3, line_height = 1.4 }),
        }
    end
    rows[#rows + 1], rows[#rows + 2] = W.row(steps), space(56)
    local code_content, overlay, retry
    if status == "waiting" or status == "scanned" then
        local ok, qr = false, nil
        if self.code and type(self.code.url) == "string" and #self.code.url <= 2953 then
            ok, qr = pcall(QRWidget.new, QRWidget, { text = self.code.url, width = W.dp(428), height = W.dp(428), scale_factor = 1 })
        end
        if ok and qr.image and qr.image:getWidth() > 0 then code_content = qr
        else
            status, self.status = "error", "error"
        end
        if status == "scanned" then
            overlay = frame(W.column{
                W.text(_("✓ Code scanned"), W.dp(320), face(30), { bold = true, align = "center" }), space(10),
                W.text(_("Confirm sign-in on your phone"), W.dp(320), face(19), { align = "center" }),
            }, W.dp(368), W.dp(146), W.dp(2))
        end
    end
    if status == "expired" or status == "error" then
        retry = W.button(_("Get a new code"), W.dp(300), function() self:start() end,
            { primary = true, height_px = W.dp(66), size = face(22) })
        layout[#layout + 1] = { retry }
        code_content = W.column{
            W.text(status == "expired" and _("The QR code has expired") or _("Sign-in unavailable"), W.dp(400), face(30), { bold = true, align = "center" }),
            space(12), W.text(status == "expired" and _("Get a new code, then scan again.")
                or _("Sign-in could not be completed. Check your connection, then get a new code."),
                W.dp(400), face(19), { align = "center", muted = true, line_height = 1.7 }),
            space(34), centered(retry, W.dp(400), W.dp(66)),
        }
    elseif status == "loading" then
        code_content = W.text(_("Getting a sign-in code…"), W.dp(400), face(28), { align = "center", bold = true })
    end
    rows[#rows + 1] = centered(QRFrame:new{
        base = frame(code_content, W.dp(480), W.dp(480), W.dp(2)), overlay = overlay,
    }, width, W.dp(480))
    if status == "waiting" or status == "scanned" then
        rows[#rows + 1], rows[#rows + 2] = space(38), W.text(status == "scanned" and _("Waiting for phone confirmation…") or _("Waiting for scan"),
            width, face(28), { bold = true, align = "center" })
        rows[#rows + 1] = space(10)
        local seconds = self.code.expires_at and math.max(0, self.code.expires_at - os.time())
        local hint = status == "scanned" and _("Confirmation completes sign-in and syncs your bookshelf.")
            or seconds and string.format(_("The code is valid for about %d minutes. Get a new one after it expires."), math.max(1, math.ceil(seconds / 60)))
            or _("The code expires automatically. Get a new one after it expires.")
        rows[#rows + 1] = W.text(hint, width, face(18), { muted = true, align = "center" })
    end
    local buttons = {}
    if status ~= "scanned" and self.on_other_methods then
        buttons[#buttons + 1] = { text = _("Other sign-in methods"), callback = function()
            local callback = self.on_other_methods
            self:close()
            callback()
        end }
    end
    buttons[#buttons + 1] = { text = _("Cancel"), callback = function() self:close() end }
    local dialog = W.flowDialog(_("Sign in with QR code"), {}, { buttons }, {
        body = W.column(rows), layout = layout, selected = { x = #buttons, y = 1 }, body_padding_px = 0,
        close_callback = function() self:close() end,
        dismiss_callback = function(widget) if self.dialog == widget then self:close() end end,
    })
    local owner, native_close = self, dialog.onCloseWidget
    function dialog:onCloseWidget()
        if native_close then native_close(self) end
        if owner.dialog == self then owner:close() end
    end
    local previous = self.dialog
    self.dialog = dialog
    if previous then UIManager:close(previous) end
    self.on_dialog(dialog)
    UIManager:show(dialog)
end
function QRLogin:_schedule()
    if not self:_current() or self.status == "expired" or self.status == "error" then return end
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
