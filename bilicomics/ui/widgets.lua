local BB = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local ImageHeader = require("bilicomics/storage/image_header")
local ImagePolicy = require("bilicomics/image_policy")
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
        height_adjust = options.height ~= nil, height_overflow_show_ellipsis = true,
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
