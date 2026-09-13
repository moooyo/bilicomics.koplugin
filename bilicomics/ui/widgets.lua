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
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("bilicomics/ui/i18n")
local Screen = Device.screen
local W = { ink = BB.COLOR_BLACK, paper = BB.COLOR_WHITE, muted = BB.COLOR_DARK_GRAY }

function W.scale(value) return Screen:scaleBySize(value) end
function W.space(height) return VerticalSpan:new{ width = W.scale(height) } end
function W.spacePixels(height) return VerticalSpan:new{ width = height } end
function W.column(items) items.align = "left"; return VerticalGroup:new(items) end
function W.row(items) items.align = "center"; return HorizontalGroup:new(items) end
function W.gap(width) return HorizontalSpan:new{ width = width } end

function W.text(text, width, size, options)
    options = options or {}
    return TextBoxWidget:new{
        text = tostring(text or ""), width = width, face = Font:getFace(options.display and "tfont" or "cfont", size or 18),
        bold = options.bold or false, fgcolor = options.muted and W.muted or W.ink,
        alignment = options.align or "left", height = options.height,
        height_adjust = options.height ~= nil and options.fixed_height ~= true, height_overflow_show_ellipsis = true,
        line_height = 0, padding = 0,
    }
end

function W.rule(width, dark)
    return FrameContainer:new{ padding = 0, margin = 0, bordersize = 0,
        background = dark and W.ink or BB.COLOR_LIGHT_GRAY,
        CenterContainer:new{ dimen = Geom:new{ w = width, h = W.scale(dark and 2 or 1) }, W.space(0) } }
end

function W.button(text, width, callback, options)
    options = options or {}
    local button = Button:new{
        text = text, width = width, height = W.scale(options.height or 30), padding_h = W.scale(5),
        padding_v = W.scale(4), bordersize = options.borderless and 0 or W.scale(1), radius = 0,
        text_font_size = options.size or 18, text_font_bold = options.primary or options.bold or false,
        align = options.align or "center", callback = callback, enabled = options.enabled ~= false,
        avoid_text_truncation = true,
    }
    if options.primary then button[1].invert = true end
    return button
end

function W.navigation(entries, total_width)
    local cells, buttons = {}, {}
    for index, entry in ipairs(entries) do
        local width = math.floor(total_width * index / #entries) - math.floor(total_width * (index - 1) / #entries)
        local selected = entry.selected == true
        local button = W.button(entry.text, width, entry.callback,
            { borderless = true, bold = selected, height = 30, size = 18 })
        button.selected = selected
        local underline = selected and W.rule(math.floor(width * 0.36), true) or W.space(0)
        cells[#cells + 1] = W.column{ button,
            CenterContainer:new{ dimen = Geom:new{ w = width, h = W.scale(3) }, underline } }
        buttons[#buttons + 1] = button
    end
    return W.column{ W.rule(total_width), W.space(5), W.row(cells) }, buttons
end

function W.cover(comic, width, height)
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
        image = CenterContainer:new{ dimen = Geom:new{ w = width, h = height },
            W.column{ W.text(_("COMIC"), width - W.scale(10), 12, { align = "center", bold = true }), W.space(8),
                W.text(comic.title or _("Untitled comic"), width - W.scale(10), 18,
                    { display = true, align = "center", height = height - W.scale(40) }) } }
    end
    return FrameContainer:new{ padding = 0, bordersize = W.scale(1), margin = 0, image }
end

local CoverCard = InputContainer:extend{ enabled = true }

function CoverCard:init()
    local border, padding = W.scale(2), W.scale(4)
    local inner = self.width - 2 * (border + padding)
    local image_border = W.scale(1)
    local cover_width = math.min(inner, math.floor(self.cover_height / 1.34))
    local content = {
        CenterContainer:new{ dimen = Geom:new{ w = inner, h = self.cover_height },
            W.cover(self.comic, cover_width - 2 * image_border, self.cover_height - 2 * image_border) },
    }
    if self.compact then
        content[#content + 1] = W.space(5)
        content[#content + 1] = W.text(self.text, inner, 16, { bold = true, height = W.scale(40), fixed_height = true })
        content[#content + 1] = W.space(2)
        content[#content + 1] = W.text(self.update or "", inner, 12,
            { muted = true, height = W.scale(18), fixed_height = true })
    elseif self.bookshelf then
        content[#content + 1] = W.space(7)
        content[#content + 1] = W.text(self.text, inner, 18, { bold = true, height = W.scale(42), fixed_height = true })
        content[#content + 1] = W.space(3)
        content[#content + 1] = W.text(self.progress, inner, 14, { height = W.scale(20), fixed_height = true })
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
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.frame:getSize().h }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
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
end

function Panel:onClose() self.close_callback(); return true end
function Panel:onNextPage() if self.next_page then self.next_page() end; return true end
function Panel:onPreviousPage() if self.previous_page then self.previous_page() end; return true end
function Panel:onShow() UIManager:setDirty(self, "ui"); return true end
function Panel:onCloseWidget() UIManager:setDirty(nil, "ui"); return true end
W.Panel = Panel

return W
