local BB = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local ImageHeader = require("bilicomics/storage/image_header")
local ImagePolicy = require("bilicomics/image_policy")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("bilicomics/ui/i18n")
local Screen = Device.screen
local W = { ink = BB.Color8(0x11), paper = BB.COLOR_WHITE, muted = BB.Color8(0x55),
    faint = BB.Color8(0x99), divider = BB.Color8(0xCC) }

-- The handoff uses a 930 x 1240 reference, independent of KOReader's 600 px base.
function W.dp(value)
    return math.floor(value * math.min(Screen:getWidth(), Screen:getHeight()) / 930 + 0.5)
end
function W.fontSize(value)
    local multiplier = Screen:scaleBySize(1000) / 1000
    return math.max(1, math.floor(W.dp(value) / multiplier + 0.5))
end
W.font = setmetatable({}, { __index = function(_, key)
    local sizes = { page = 30, title = 26, item = 22, body = 20, status = 18, meta = 16, micro = 15, card = 18 }
    return W.fontSize(sizes[key] or 20)
end })

function W.scale(value) return Screen:scaleBySize(value) end
function W.space(height) return VerticalSpan:new{ width = W.scale(height) } end
function W.spacePixels(height) return VerticalSpan:new{ width = height } end
function W.column(items) items.align = "left"; return VerticalGroup:new(items) end
function W.row(items) items.align = "center"; return HorizontalGroup:new(items) end
function W.gap(width) return HorizontalSpan:new{ width = width } end

function W.text(text, width, size, options)
    options = options or {}
    return TextBoxWidget:new{
        text = tostring(text or ""), width = math.max(1, width), face = Font:getFace("cfont", size or W.font.body),
        bold = options.bold or false, fgcolor = options.color or (options.muted and W.muted or W.ink),
        bgcolor = options.background or options.bgcolor or (options.color and options.color == W.paper and W.ink or W.paper),
        alignment = options.align or "left", height = options.height,
        height_adjust = options.height ~= nil and options.fixed_height ~= true, height_overflow_show_ellipsis = true,
        line_height = options.line_height and (options.line_height >= 1 and options.line_height - 1 or options.line_height) or 0,
        padding = 0,
    }
end

-- Single-line labels have explicit layout height, independent of glyph extents.
function W.line(text, width, size, options)
    options = options or {}
    local label = TextWidget:new{ text = tostring(text or ""), max_width = math.max(1, width),
        face = Font:getFace("cfont", size or W.font.body), bold = options.bold or false,
        fgcolor = options.color or (options.muted and W.muted or W.ink), padding = 0 }
    local height = options.height or math.ceil(label.face.size * 1.3)
    local result = W.box(label, width, height, { align = options.align or "left", background = options.background })
    result.text, result.face, result.label_widget = label.text, label.face, label
    function result:setText(value)
        self.text = tostring(value or "")
        self.label_widget:setText(self.text)
    end
    return result
end

function W.rule(width, dark)
    return FrameContainer:new{ padding = 0, margin = 0, bordersize = 0,
        background = dark and W.ink or W.divider,
        CenterContainer:new{ dimen = Geom:new{ w = width, h = math.max(1, W.dp(1)) }, W.space(0) } }
end
function W.rule1dp(width, color)
    return W.box(nil, width, math.max(1, W.dp(1)), { background = color or W.divider })
end

function W.box(content, width, height, options)
    options = options or {}
    local border, padding = options.border_px or 0, options.padding_px or 0
    local holder = CenterContainer:new{ dimen = Geom:new{ w = math.max(0, width - 2 * (border + padding)),
        h = math.max(0, height - 2 * (border + padding)) }, content or W.spacePixels(0) }
    if options.align or options.valign then
        function holder:paintTo(bb, x, y)
            local size = self[1]:getSize()
            local dx = options.align == "left" and 0 or options.align == "right" and self.dimen.w - size.w
                or math.floor((self.dimen.w - size.w) / 2)
            local dy = options.valign == "top" and 0 or options.valign == "bottom" and self.dimen.h - size.h
                or math.floor((self.dimen.h - size.h) / 2)
            self[1]:paintTo(bb, x + dx, y + dy)
        end
    end
    return FrameContainer:new{ padding = padding, margin = 0, bordersize = border, radius = 0,
        color = options.color or W.ink, background = options.background, holder }
end

function W.inset(content, left, right, top, bottom)
    return FrameContainer:new{ padding = 0, margin = 0, bordersize = 0,
        padding_left = left or 0, padding_right = right or 0,
        padding_top = top or 0, padding_bottom = bottom or 0, content }
end

function W.progress(width, height, fraction)
    local stroke = math.max(1, W.dp(1))
    fraction = math.max(0, math.min(1, tonumber(fraction) or 0))
    local inner = math.max(0, width - 2 * stroke)
    local filled = math.floor(inner * fraction + 0.5)
    return FrameContainer:new{ padding = 0, margin = 0, bordersize = stroke, color = W.ink,
        W.row{ W.box(nil, filled, math.max(0, height - 2 * stroke), { background = W.ink }),
            W.box(nil, inner - filled, math.max(0, height - 2 * stroke), { background = W.paper }) } }
end

function W.button(text, width, callback, options)
    options = options or {}
    local border = options.borderless and 0 or (options.border_px or math.max(1, W.dp(1.5)))
    local padding_v = options.height_px and 0 or W.scale(4)
    local height = options.height_px and math.max(1, options.height_px - 2 * border)
        or W.scale(options.height or 30)
    local button = Button:new{
        text = text, width = width, height = height, padding_h = options.padding_h or W.dp(10),
        padding_v = padding_v, bordersize = border, radius = 0,
        text_font_size = options.size or W.font.body, text_font_bold = options.primary or options.bold or false,
        align = options.align or "center", callback = callback, enabled = options.enabled ~= false,
        avoid_text_truncation = true,
    }
    if options.enabled == false then
        button.frame.color = W.divider
        button.label_widget.fgcolor = W.faint
    end
    if options.primary and options.enabled ~= false then
        button.frame.background, button.frame.color, button[1].invert = BB.Color8(0xEE), W.ink, true
    end
    -- Native focus inversion must not erase the primary action after focus leaves it.
    local native_unfocus = button.onUnfocus
    function button:onUnfocus()
        native_unfocus(self)
        self.frame.invert = options.primary and self.enabled or false
        return true
    end
    local native_highlight, native_undo = button._doFeedbackHighlight, button._undoFeedbackHighlight
    function button:_doFeedbackHighlight()
        if not options.primary or not self.enabled then return native_highlight(self) end
        self.frame.invert = false
        UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
        UIManager:setDirty(nil, "fast", self.frame.dimen)
    end
    function button:_undoFeedbackHighlight(translucent)
        if not options.primary or not self.enabled then return native_undo(self, translucent) end
        self.frame.invert = true
        UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
        UIManager:setDirty(nil, "ui", self.frame.dimen)
    end
    return button
end

function W.navigation(entries, total_width)
    local cells, buttons = {}, {}
    for index, entry in ipairs(entries) do
        local width = math.floor(total_width * index / #entries) - math.floor(total_width * (index - 1) / #entries)
        local selected = entry.selected == true
        local button = W.button(entry.text, width, entry.callback,
            { borderless = true, bold = selected, height_px = W.dp(88) - W.dp(6), size = W.fontSize(23) })
        if entry.badge and entry.badge > 0 then
            local label = button.label_widget
            local badge_text = TextWidget:new{ text = tostring(entry.badge), face = Font:getFace("cfont", W.fontSize(16)),
                bold = true, fgcolor = W.paper }
            local badge_width = math.max(W.dp(28), badge_text:getSize().w + W.dp(14))
            local badge = W.box(badge_text, badge_width, W.dp(28), { background = W.ink })
            local group = W.row{ label, W.gap(W.dp(8)), badge }
            group.text = entry.text
            button.label_widget, button.label_container[1] = group, group
            button.download_badge = badge
        end
        button.selected = selected
        local underline = W.box(nil, W.dp(80), W.dp(6), { background = selected and W.ink or W.paper })
        cells[#cells + 1] = W.column{
            CenterContainer:new{ dimen = Geom:new{ w = width, h = W.dp(6) }, underline }, button }
        buttons[#buttons + 1] = button
    end
    -- The selected bar shares the top rule's edge without changing the bar height.
    local navigation = W.row(cells)
    local native_paint = navigation.paintTo
    function navigation:paintTo(bb, x, y)
        native_paint(self, bb, x, y)
        bb:paintRect(x, y, total_width, math.max(1, W.dp(1)), W.ink)
        for index, entry in ipairs(entries) do
            if entry.selected then
                local center = total_width * (index - 0.5) / #entries
                bb:paintRect(x + math.floor(center - W.dp(40)), y, W.dp(80), W.dp(6), W.ink)
            end
        end
    end
    return navigation, buttons
end

function W.header(title, total_width, options)
    options = options or {}
    local margin, side = W.dp(56), W.dp(210)
    local status_width = total_width - 2 * margin
    local online = not options.offline
    if options.offline == nil then
        local ok, manager = pcall(require, "ui/network/manager")
        if ok and manager.isConnected then
            local available, value = pcall(manager.isConnected, manager)
            if available then online = value == true end
        end
    end
    local battery
    local ok, value = pcall(function() return Device:getPowerDevice():getCapacity() end)
    if ok and tonumber(value) then battery = string.format(_("Battery %d%%"), value) end
    local connection = online and _("Online") or _("Offline")
    local status_parts = { TextWidget:new{ text = connection, face = Font:getFace("cfont", W.fontSize(16)),
        fgcolor = online and W.muted or W.ink, bold = not online } }
    if battery then status_parts[#status_parts + 1] = TextWidget:new{ text = " · " .. battery,
        face = Font:getFace("cfont", W.fontSize(16)), fgcolor = W.muted } end
    local status = W.row(status_parts)
    local strip = W.inset(W.row{
        W.text(os.date("%H:%M"), math.floor(status_width * 0.25), W.fontSize(16), { muted = true }),
        W.box(status, status_width - math.floor(status_width * 0.25), status:getSize().h, { align = "right" }),
    }, margin, margin, W.dp(15), 0)
    local buttons = {}
    local bar_height = W.dp(116) - W.dp(40) - math.max(1, W.dp(1))
    local function action(label, callback)
        local measured = TextWidget:new{ text = label, face = Font:getFace("cfont", W.fontSize(22)) }
        local action_width = measured:getSize().w + W.dp(40)
        measured:free()
        return W.button(label, action_width, callback,
            { borderless = true, size = W.fontSize(22), height_px = W.dp(54), padding_h = W.dp(20) })
    end
    local back_button = options.back_callback and action(_("‹ Back"), options.back_callback)
    local more_button = options.more_callback and action(_("More"), options.more_callback)
    local back = W.inset(W.box(back_button, side - W.dp(36), bar_height, { align = "left" }), W.dp(36), 0, 0, 0)
    local more = W.inset(W.box(more_button, side - W.dp(36), bar_height, { align = "right" }), 0, W.dp(36), 0, 0)
    if options.back_callback then buttons[#buttons + 1] = back_button end
    if options.more_callback then buttons[#buttons + 1] = more_button end
    local bar = W.row{ back,
        W.box(W.line(title, math.max(1, total_width - 2 * side), W.font.page,
            { bold = true, align = "center", height = W.dp(48) }), total_width - 2 * side, bar_height), more }
    local header = W.column{ W.box(strip, total_width, W.dp(40)), bar, W.rule(total_width, true) }
    header.status_strip, header.title_bar = header[1], bar
    return header, buttons
end

function W.cover(comic, width, height, options)
    options = options or {}
    local border = math.max(1, W.dp(1))
    local outer_width, outer_height = width, height
    width, height = math.max(1, width - 2 * border), math.max(1, height - 2 * border)
    local path = comic.cover_path or (comic.extra or {}).cover_path
    local image
    if path and not path:match("^https?://") then
        local file = io.open(path, "rb")
        if file then
            file:close()
            local ok, widget = pcall(function()
                local header = ImageHeader.read(path)
                if not ImagePolicy.fitsCover(header) then return nil end
                local result = ImageWidget:new{ file = path, width = width, height = height,
                    scale_factor = 0, file_do_cache = false }
                result:getSize()
                return result
            end)
            if ok then image = widget end
        end
    end
    if not image then
        image = W.box(W.text(options.offline and _("Cover not cached") or _("Cover"),
            math.max(1, width - W.dp(8)), W.font.micro, { align = "center", muted = true }), width, height)
    end
    local frame = FrameContainer:new{ padding = 0, bordersize = border, margin = 0,
        color = options.offline and not path and BB.Color8(0xAA) or W.ink, image }
    if options.hero then
        local native_paint = frame.paintTo
        function frame:paintTo(bb, x, y)
            native_paint(self, bb, x, y)
            bb:paintRect(x + outer_width - W.dp(52), y, W.dp(26), W.dp(56), W.ink)
        end
    end
    frame.outer_width, frame.outer_height = outer_width, outer_height
    return frame
end

local CoverCard = InputContainer:extend{ enabled = true }

function CoverCard:init()
    if self.redesign then
        self.card_cover_width, self.card_cover_inset = self.width, 0
        local content = { W.cover(self.comic, self.width, self.cover_height, { offline = self.offline, hero = self.hero }),
            W.spacePixels(W.dp(10)),
            W.line(self.text, self.width, W.fontSize(self.bookshelf and 18 or 19),
                { bold = true, height = W.dp(self.bookshelf and 23.4 or 24.7) }),
            W.spacePixels(W.dp(4)),
            W.line(self.progress_label or self.progress or self.update or "", self.width,
                W.fontSize(self.bookshelf and 15 or 16),
                { muted = self.progress_muted or not self.bookshelf, height = W.dp(self.bookshelf and 19.5 or 20.8) }),
        }
        self.frame = FrameContainer:new{ padding = 0, margin = 0, bordersize = 0,
            color = W.paper, background = W.paper, W.column(content) }
        self[1] = self.frame
        if self.updated then
            self.update_badge = FrameContainer:new{ padding = 0, padding_left = W.dp(8), padding_right = W.dp(8),
                padding_top = W.dp(6), padding_bottom = W.dp(6), margin = 0, bordersize = 0, radius = 0,
                background = W.ink,
                TextWidget:new{ text = _("New chapters"), face = Font:getFace("cfont", W.fontSize(14)),
                    bold = true, fgcolor = W.paper, padding = 0 } }
        end
        self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.frame:getSize().h }
        self.ges_events = {
            TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
            HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
        }
        return
    end
    local border, padding = W.scale(2), W.scale(4)
    local inner = self.width - 2 * (border + padding)
    local image_border = W.scale(1)
    local cover_width = math.min(inner, math.floor(self.cover_height / 1.34))
    self.card_cover_width, self.card_cover_inset = cover_width, border + padding
    local content = {
        CenterContainer:new{ dimen = Geom:new{ w = inner, h = self.cover_height },
            W.cover(self.comic, cover_width - 2 * image_border, self.cover_height - 2 * image_border) },
    }
    if self.compact then
        content[#content + 1] = W.space(5)
        content[#content + 1] = W.text(self.text, inner, W.font.card, { bold = true, height = W.scale(40), fixed_height = true })
        content[#content + 1] = W.space(2)
        content[#content + 1] = W.text(self.update or "", inner, W.font.meta,
            { muted = true, height = W.scale(18), fixed_height = true })
    elseif self.bookshelf then
        content[#content + 1] = W.space(5)
        content[#content + 1] = W.text(self.text, inner, W.font.card, { bold = true, height = W.scale(40), fixed_height = true })
        content[#content + 1] = W.space(2)
        content[#content + 1] = W.text(self.progress_label or self.progress, inner, W.font.meta,
            { height = W.scale(20), fixed_height = true })
    else
        content[#content + 1] = W.space(7)
        content[#content + 1] = W.text(self.text, inner, 18, { bold = true, height = W.scale(44), fixed_height = true })
        content[#content + 1] = W.space(3)
        content[#content + 1] = W.text(self.progress, inner, 14, { height = W.scale(38), fixed_height = true })
        content[#content + 1] = W.space(2)
        content[#content + 1] = W.text(self.update or "", inner, 13,
            { muted = true, height = W.scale(22), fixed_height = true })
    end
    self.frame = FrameContainer:new{ padding = padding, margin = 0, bordersize = border,
        color = W.paper, background = W.paper, W.column(content) }
    self[1] = self.frame
    if self.bookshelf and self.updated then
        self.update_badge = FrameContainer:new{ padding = W.scale(3), margin = 0, bordersize = W.scale(1),
            radius = 0, background = W.paper, color = W.ink,
            TextWidget:new{ text = _("Updated"), face = Font:getFace("cfont", W.font.micro),
                bold = true, fgcolor = W.ink, padding = 0 } }
        self[2] = self.update_badge
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.frame:getSize().h }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function CoverCard:getSize()
    return Geom:new{ w = self.width, h = self.frame:getSize().h }
end

function CoverCard:paintTo(bb, x, y)
    local size = self:getSize()
    self.dimen.x, self.dimen.y, self.dimen.w, self.dimen.h = x, y, size.w, size.h
    self.frame:paintTo(bb, x, y)
    if self.update_badge then
        local badge = self.update_badge:getSize()
        local inset = self.redesign and 0 or W.scale(3)
        self.update_badge:paintTo(bb, x + math.floor((self.width + self.card_cover_width) / 2) - badge.w - inset,
            y + self.card_cover_inset + inset)
    end
    if self.focused and self.redesign then
        local stroke = math.max(1, W.dp(2))
        bb:paintBorder(x, y, size.w, size.h, stroke, W.ink, 0)
    end
end

function CoverCard:onFocus()
    self.focused = true
    self.frame.color = W.ink
    if self.focus_callback then self.focus_callback(self.comic) end
    return true
end
function CoverCard:onUnfocus() self.focused = false; self.frame.color = W.paper; return true end
function CoverCard:onTapSelect()
    if self.enabled and self.callback then self.callback() end
    return true
end
function CoverCard:onHoldSelect()
    if self.enabled and self.hold_callback then self.hold_callback() end
    return true
end
W.CoverCard = CoverCard

-- Keep the apparent row and its touch/key target identical without adding height.
local ActionRow = InputContainer:extend{ enabled = true }

function ActionRow:init()
    self[1] = assert(self.content)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.content:getSize().h }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function ActionRow:getSize()
    return Geom:new{ w = self.width, h = self.content:getSize().h }
end

function ActionRow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.dimen.w, self.dimen.h = self.width, self.content:getSize().h
    self.content:paintTo(bb, x, y)
    if self.focused then
        local stroke, size = math.max(1, W.dp(2)), self:getSize()
        bb:paintRect(x, y, size.w, stroke, W.ink)
        bb:paintRect(x, y + size.h - stroke, size.w, stroke, W.ink)
        bb:paintRect(x, y, stroke, size.h, W.ink)
        bb:paintRect(x + size.w - stroke, y, stroke, size.h, W.ink)
    end
end

function ActionRow:onFocus()
    self.focused = true
    if self.focus_callback then self.focus_callback() end
    return true
end
function ActionRow:onUnfocus() self.focused = false; return true end
function ActionRow:onTapSelect()
    if self.enabled and self.callback then self.callback() end
    return true
end
function ActionRow:onHoldSelect()
    if self.enabled and self.hold_callback then self.hold_callback() end
    return true
end
W.ActionRow = ActionRow

local Panel = FocusManager:extend{ name = "bilicomics", covers_fullscreen = true }

function Panel:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self[1] = FrameContainer:new{ padding = 0, margin = 0, bordersize = 0, background = W.paper,
        CenterContainer:new{ dimen = self.dimen:copy(), self.content } }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PreviousPage = { { Device.input.group.PgBack } }
    end
    self.ges_events = {
        SwipePage = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
end

function Panel:onClose() self.close_callback(); return true end
function Panel:onNextPage() if self.next_page then self.next_page() end; return true end
function Panel:onPreviousPage() if self.previous_page then self.previous_page() end; return true end
function Panel:onSwipePage(_, gesture)
    if gesture.direction == "west" or gesture.direction == "north" then return self:onNextPage() end
    if gesture.direction == "east" or gesture.direction == "south" then return self:onPreviousPage() end
    return true
end
function Panel:onShow() UIManager:setDirty(self, self.refresh_mode or "flashui"); return true end
function Panel:onCloseWidget() UIManager:setDirty(nil, "ui"); return true end
W.Panel = Panel

local Sheet = FocusManager:extend{ name = "bilicomics_sheet", modal = true }

function Sheet:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.frame = FrameContainer:new{ padding = 0, margin = 0, bordersize = self.placement == "bottom" and 0 or self.border_px or W.dp(2),
        radius = 0, color = W.ink, background = W.paper, self.content }
    self[1] = self.frame
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipePage = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PreviousPage = { { Device.input.group.PgBack } }
    end
end

function Sheet:getSize() return self.frame:getSize() end
function Sheet:paintTo(bb, x, y)
    local size = self.frame:getSize()
    local left = self.left or self.right and Screen:getWidth() - self.right - size.w
        or math.floor((Screen:getWidth() - size.w) / 2)
    local top = self.top or (self.placement == "bottom" and Screen:getHeight() - size.h
        or math.floor((Screen:getHeight() - size.h) / 2))
    top = math.max(0, math.min(top, Screen:getHeight() - size.h))
    self.panel_dimen = Geom:new{ x = left, y = top, w = size.w, h = size.h }
    self.frame:paintTo(bb, left, top)
    if self.placement == "bottom" then bb:paintRect(left, top, size.w, self.border_px or W.dp(2), W.ink) end
end
function Sheet:onClose()
    if self.dismissable == false then return true end
    if self.close_callback then self.close_callback() else UIManager:close(self) end
    return true
end
function Sheet:onTapOutside(_, gesture)
    if self.dismissable ~= false and gesture and gesture.pos and self.panel_dimen
        and not self.panel_dimen:contains(gesture.pos) then return self:onClose() end
    return true
end
Sheet.onNextPage, Sheet.onPreviousPage, Sheet.onSwipePage = Panel.onNextPage, Panel.onPreviousPage, Panel.onSwipePage
Sheet.onShow, Sheet.onCloseWidget = Panel.onShow, Panel.onCloseWidget

function W.sheetDialog(content, focus, options)
    options = options or {}
    local border = options.border_px or W.dp(2)
    local width = options.width or Screen:getWidth()
    local inner = (options.placement == nil or options.placement == "bottom") and width or width - 2 * border
    -- Manual sheets supply their own handoff padding.
    content = W.box(content, inner, content:getSize().h, { align = "left", valign = "top" })
    return Sheet:new{ content = content, layout = focus or {}, placement = options.placement or "bottom",
        left = options.left, right = options.right, top = options.top, selected = options.selected,
        border_px = border, close_callback = options.close_callback or options.close,
        dismissable = options.dismissable, next_page = options.next_page, previous_page = options.previous_page }
end

local function specButtons(spec, width, height)
    local widgets, focus = {}, {}
    local gap = W.dp(16)
    local flexible, remaining = 0, width - gap * math.max(0, #spec - 1)
    for _, entry in ipairs(spec) do
        if entry.width then remaining = remaining - entry.width else flexible = flexible + 1 end
    end
    for index, entry in ipairs(spec) do
        if index > 1 then widgets[#widgets + 1] = W.gap(gap) end
        local button = W.button(entry.text, entry.width or math.floor(remaining / math.max(1, flexible)), entry.callback,
            { primary = entry.primary == true or entry.invert == true, bold = entry.font_bold or entry.bold,
                enabled = entry.enabled, borderless = entry.borderless, align = entry.align,
                height_px = entry.height_px or height, size = entry.font_size or entry.size or W.fontSize(21) })
        button.id, button.spec = entry.id, entry
        widgets[#widgets + 1], focus[#focus + 1] = button, button
    end
    return W.row(widgets), focus
end

local function paragraphRows(paragraphs, width, max_height)
    local rows = {}
    for _, paragraph in ipairs(paragraphs or {}) do
        local item = type(paragraph) == "table" and paragraph or { text = paragraph }
        local text = tostring(item.text or "")
        local characters = {}
        for character in text:gmatch(".[\128-\191]*") do characters[#characters + 1] = character end
        local first = 1
        local function label(last)
            return W.text(table.concat(characters, "", first, last), width, item.size or W.font.body,
                { bold = item.bold, muted = item.muted, color = item.color, background = item.background,
                    line_height = item.line_height, align = item.align })
        end
        -- Measure actual FreeType line geometry, including fallback glyph extents.
        while first <= #characters do
            local low, high, best = first, #characters, first - 1
            while low <= high do
                local middle = math.floor((low + high) / 2)
                local probe = label(middle)
                local fits = probe:getSize().h + W.dp(14) <= max_height
                probe:free()
                if fits then best, low = middle, middle + 1 else high = middle - 1 end
            end
            if best < first then error("A text line exceeds the available page height") end
            if best < #characters then
                for index = best, math.max(first, best - math.floor((best - first) * 0.35)), -1 do
                    if characters[index]:match("%s") then best = index; break end
                end
            end
            rows[#rows + 1] = { widget = W.column{ label(best), W.spacePixels(W.dp(14)) } }
            first = best + 1
        end
    end
    return rows
end

local function partitionRows(rows, available)
    local expanded = {}
    local function contains(widget, wanted)
        if widget == wanted then return true end
        for _, child in ipairs(widget) do
            if type(child) == "table" and contains(child, wanted) then return true end
        end
        return false
    end
    local function expand(entry)
        if not entry.widget then entry = { widget = entry } end
        local widget = entry.widget
        if widget:getSize().h <= available then expanded[#expanded + 1] = entry; return end
        if widget.align == "left" and widget.resetLayout and #widget > 0 then
            for _, child in ipairs(widget) do
                local focus = {}
                for _, item in ipairs(entry.focus or {}) do if contains(child, item) then focus[#focus + 1] = item end end
                local focus_rows = {}
                for _, row in ipairs(entry.focus_rows or {}) do
                    local matching = {}
                    for _, item in ipairs(row) do if contains(child, item) then matching[#matching + 1] = item end end
                    if #matching > 0 then focus_rows[#focus_rows + 1] = matching end
                end
                expand{ widget = child, focus = #focus > 0 and focus or nil, focus_rows = focus_rows }
            end
        elseif type(widget.text) == "string" and widget.face and widget.width then
            local parts = paragraphRows({ { text = widget.text, size = widget.face.orig_size,
                bold = widget.bold, color = widget.fgcolor, background = widget.bgcolor,
                line_height = (widget.line_height or 0) + 1, align = widget.alignment } }, widget.width, available)
            for _, part in ipairs(parts) do expand(part) end
        else
            -- Fixed graphics must be sized by their caller; never paint over actions.
            error("A fixed UI row exceeds the available page height")
        end
    end
    for _, entry in ipairs(rows) do expand(entry) end
    local pages, page, used = {}, {}, 0
    for _, entry in ipairs(expanded) do
        if not entry.widget then entry = { widget = entry } end
        local height = entry.widget:getSize().h
        if #page > 0 and used + height > available then
            pages[#pages + 1], page, used = page, {}, 0
        end
        page[#page + 1], used = entry, used + height
    end
    if #page > 0 or #pages == 0 then pages[#pages + 1] = page end
    return pages
end

function W.flowDialog(title, paragraphs, buttons, options)
    options, buttons = options or {}, buttons or {}
    local total_width, total_height = Screen:getWidth(), Screen:getHeight()
    local width, margin = total_width - W.dp(112), W.dp(56)
    local close = options.close_callback or options.close
    local footer_spec = buttons[#buttons] or {}
    local footer_row, footer_buttons = specButtons(footer_spec, width, W.dp(68))
    local footer = W.column{ W.rule(total_width, true),
        W.box(W.inset(footer_row, margin, margin, 0, 0), total_width, W.dp(107)) }
    local body_height = total_height - W.dp(116) - footer:getSize().h
    local padding_top = options.body_padding_top_px or options.body_padding_px or W.dp(28)
    local padding_bottom = options.body_padding_bottom_px or options.body_padding_px or W.dp(28)
    local available = body_height - padding_top - padding_bottom
    local rows = {}
    for _, entry in ipairs(options.body_rows or paragraphRows(paragraphs, width, available - W.dp(60))) do
        rows[#rows + 1] = entry
    end
    if options.body then
        rows = { { widget = options.body, focus_rows = options.layout } }
    end
    for index = 1, #buttons - 1 do
        local row, focus = specButtons(buttons[index], width, W.dp(66))
        rows[#rows + 1] = { widget = W.column{ row, W.spacePixels(W.dp(14)) }, focus = focus }
    end
    local pages = partitionRows(rows, available)
    if #pages > 1 then pages = partitionRows(rows, available - W.dp(60)) end
    local dialog, current_page = nil, math.max(1, math.min(options.page or 1, #pages))
    local layout = {}
    local header, header_buttons = W.header(title, total_width, {
        back_callback = not options.no_back and options.dismissable ~= false and function() dialog:onClose() end or nil,
        offline = options.offline,
    })
    if #header_buttons > 0 then layout[#layout + 1] = header_buttons end
    local content_rows = {}
    for _, entry in ipairs(pages[current_page]) do
        content_rows[#content_rows + 1] = entry.widget
        if entry.focus then layout[#layout + 1] = entry.focus end
        for _, focus in ipairs(entry.focus_rows or {}) do layout[#layout + 1] = focus end
    end
    if not options.body then for _, focus in ipairs(options.layout or {}) do layout[#layout + 1] = focus end end
    if #pages > 1 then
        local pager, focus = specButtons({
            { text = "‹", enabled = current_page > 1, callback = function() dialog:onPreviousPage() end },
            { text = current_page .. " / " .. #pages, enabled = false },
            { text = "›", enabled = current_page < #pages, callback = function() dialog:onNextPage() end },
        }, width, W.dp(52))
        content_rows[#content_rows + 1], layout[#layout + 1] = pager, focus
    end
    layout[#layout + 1] = footer_buttons
    local body = W.box(W.inset(W.column(content_rows), margin, margin, padding_top, padding_bottom),
        total_width, body_height, { align = "left", valign = "top" })
    local selected = { x = 1, y = #layout }
    if options.selected then
        selected.x = options.selected.x or 1
        selected.y = options.selected.y == #buttons and #layout or math.min(options.selected.y or #layout, #layout)
    end
    local function change(delta)
        local page = current_page + delta
        if page < 1 or page > #pages then return end
        if options.on_page then options.on_page(page); return end
        options.page = page
        local replacement = W.flowDialog(title, paragraphs, buttons, options)
        local visible = options._visible_dialog or dialog
        if options.on_replace then
            options._visible_dialog = replacement
            options.on_replace(replacement, visible)
        else
            -- Keep owner identity stable across pages, including every async guard.
            for _, key in ipairs({ "content", "layout", "selected", "header", "body", "footer", "footer_buttons",
                "body_height", "page", "pages", "next_page", "previous_page" }) do visible[key] = replacement[key] end
            visible[1] = replacement[1]
            UIManager:setDirty(visible, "ui")
        end
    end
    dialog = Panel:new{ content = W.column{ header, body, footer }, layout = layout, selected = selected,
        close_callback = function()
            if options.dismissable == false or options.no_back then return end
            if close then close() else UIManager:close(options._visible_dialog or dialog) end
        end,
        next_page = options.next_page or function() change(1) end,
        previous_page = options.previous_page or function() change(-1) end }
    dialog.fullpage, dialog.header, dialog.body, dialog.footer = true, header, body, footer
    dialog.footer_buttons, dialog.body_height, dialog.page, dialog.pages = footer_buttons, body_height, current_page, #pages
    dialog.title, dialog.buttons = title, buttons
    options._visible_dialog = options._visible_dialog or dialog
    function dialog:getButtonById(id)
        for _, row in ipairs(self.layout or {}) do for _, button in ipairs(row) do if button.id == id then return button end end end
    end
    return dialog
end

function W.menuDialog(title, paragraphs, buttons, options)
    options, buttons = options or {}, buttons or {}
    local border = options.border_px or W.dp(2)
    local width = options.width or Screen:getWidth()
    local padding = options.padding_px or W.dp(options.placement == "right" and 28 or 40)
    local framed = options.placement and options.placement ~= "bottom"
    local inner = width - 2 * (padding + (framed and border or 0))
    local max_height = Screen:getHeight() - W.dp(80)
    local title_widget = W.text(title, inner, W.fontSize(options.title_size or 28), { bold = true })
    local available = max_height - 2 * padding - title_widget:getSize().h - W.dp(24) - 2 * border
    local rows = paragraphRows(paragraphs, inner, available - W.dp(60))
    for _, spec in ipairs(buttons) do
        local row, focus = specButtons(spec, inner, W.dp(66))
        rows[#rows + 1] = { widget = W.column{ row, W.spacePixels(W.dp(12)) }, focus = focus }
    end
    local pages = partitionRows(rows, available - W.dp(60))
    local page, dialog = math.max(1, math.min(options.page or 1, #pages)), nil
    local function build()
        local layout, content = {}, { title_widget, W.spacePixels(W.dp(24)) }
        for _, entry in ipairs(pages[page]) do
            content[#content + 1] = entry.widget
            if entry.focus then layout[#layout + 1] = entry.focus end
        end
        if #pages > 1 then
            local pager, focus = specButtons({
                { text = "‹", enabled = page > 1, callback = function() dialog:onPreviousPage() end },
                { text = page .. " / " .. #pages, enabled = false },
                { text = "›", enabled = page < #pages, callback = function() dialog:onNextPage() end },
            }, inner, W.dp(52))
            content[#content + 1], layout[#layout + 1] = pager, focus
        end
        return W.inset(W.column(content), padding, padding, padding, padding), layout
    end
    local content, layout = build()
    local function change(delta)
        local target = page + delta
        if target < 1 or target > #pages then return end
        page = target
        local replacement, focus = build()
        dialog.content = W.box(replacement, width - (framed and 2 * border or 0), replacement:getSize().h,
            { align = "left", valign = "top" })
        dialog.layout, dialog.selected, dialog.page = focus, { x = 1, y = 1 }, page
        dialog:init()
        UIManager:setDirty(dialog, "ui")
    end
    options.next_page, options.previous_page = function() change(1) end, function() change(-1) end
    dialog = W.sheetDialog(content, layout, options)
    dialog.title, dialog.buttons = title, buttons
    dialog.page, dialog.pages = page, #pages
    function dialog:getButtonById(id)
        for _, row in ipairs(self.layout or {}) do for _, button in ipairs(row) do if button.id == id then return button end end end
    end
    return dialog
end

return W
