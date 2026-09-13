local BD = require("ui/bidi")

local Defaults = {}

local function read(settings, key, fallback)
    if settings and type(settings.get) == "function" then return settings:get(key, fallback) end
    local value = settings and settings[key]
    if value ~= nil then return value end
    return fallback
end

local function has(config, key)
    return config:readSetting(key) ~= nil
end

-- Capture in DocSettingsLoad, before native ReadSettings migrates or fills values.
-- The fallback also supports consumers attaching after ReaderReady without a plugin hook.
function Defaults.capture(reader, config, before_read)
    if reader.bilicomics_initial_settings then return reader.bilicomics_initial_settings end
    local snapshot = {
        visited = config:isTrue("bilicomics_reader_initialized")
            or reader.document.is_new == false or has(config, "last_page") or has(config, "page_positions"),
        zoom = has(config, "zoom_mode") or has(config, "kopt_zoom_mode_genus") or has(config, "kopt_zoom_mode_type"),
        free_zoom = config:readSetting("zoom_mode") == "free",
        scroll = has(config, "kopt_page_scroll"),
        direction = has(config, "inverse_reading_order"),
        writing_direction = config:readSetting("kopt_writing_direction"),
    }
    -- ReaderConfig normally loads this field before view/zoom settings. This provider
    -- has no ReaderConfig, so honor its native setting contract on this instance.
    if before_read and (snapshot.writing_direction == 0 or snapshot.writing_direction == 1 or snapshot.writing_direction == 2) then
        reader.document.configurable.writing_direction = snapshot.writing_direction
    end
    reader.bilicomics_initial_settings = snapshot
    return snapshot
end

local function usableAnchor(reader, anchor)
    if type(anchor) ~= "table" or anchor.schema_version ~= 1
        or type(anchor.x) ~= "number" or type(anchor.y) ~= "number"
        or anchor.x ~= anchor.x or anchor.y ~= anchor.y
        or math.abs(anchor.x) == math.huge or math.abs(anchor.y) == math.huge then return false end
    for _, page in ipairs(reader.document.descriptor.pages) do
        if page.id == anchor.page_id then return true end
    end
    return false
end

-- Native per-document values win. A valid anchor fills missing legacy mode values.
-- Global BiliComics preferences apply only to new chapters, then auto uses geometry.
-- Existing chapters without an anchor keep the settings selected by the native reader.
function Defaults.apply(reader, settings, anchor)
    local config = reader.doc_settings
    local saved = Defaults.capture(reader, config)
    local anchored = usableAnchor(reader, anchor)
    local new_chapter = not saved.visited and not anchored
    local zoom, scroll
    local rtl = read(settings, "reading_direction", "ltr") == "rtl"
    if saved.direction then rtl = reader.view.inverse_reading_order ~= BD.mirroredUILayout() end
    local writing = saved.writing_direction
    if writing ~= 0 and writing ~= 1 and writing ~= 2 then writing = new_chapter and (rtl and 1 or 0) or nil end
    local changed_writing = writing ~= nil and writing ~= reader.document.configurable.writing_direction
    if changed_writing then
        -- This native API updates this document's Configurable without changing zoom.
        reader.zooming:onSetZoomPan({ writing_direction = writing,
            zoom_mode = reader.zooming.zoom_mode, kopt_zoom_factor = reader.zooming.kopt_zoom_factor }, true)
    end
    if anchored then
        if not saved.zoom and reader.zooming.zoom_mode_label[anchor.zoom_mode]
            and anchor.zoom_mode ~= "free" then zoom = anchor.zoom_mode end
        if not saved.scroll and (anchor.mode == "page" or anchor.mode == "continuous") then
            scroll = anchor.mode == "continuous"
        end
    elseif new_chapter then
        local mode = read(settings, "reading_mode", "auto")
        local page = reader.document:getLocalPage(1)
        local strip = mode == "strip" or (mode ~= "page" and page.height / page.width >= 2.5)
        if not saved.zoom then zoom = strip and "pagewidth" or "page" end
        if not saved.scroll then scroll = strip end
    end
    if zoom then reader.zooming:onSetZoomMode(zoom) end
    if scroll ~= nil and reader.view.page_scroll ~= scroll then reader.view:onSetScrollMode(scroll) end
    if new_chapter and not saved.direction then
        reader.view:onToggleReadingOrder(rtl ~= BD.mirroredUILayout())
    end
    if changed_writing then reader.view:recalculate() end
    config:saveSetting("bilicomics_reader_initialized", true)

    -- A stale free-zoom anchor must not replace an explicitly saved native zoom mode.
    if anchored and saved.zoom and not saved.free_zoom and anchor.zoom_mode == "free" then
        local position = {}
        for key, value in pairs(anchor) do position[key] = value end
        position.zoom_mode = nil
        return position
    end
    return anchored and anchor or nil
end

-- This provider deliberately has no ReaderConfig; that native module normally saves
-- kopt_page_scroll. Use its standard setting so ReaderView can restore the real mode.
function Defaults.save(reader)
    local paging = reader.paging
    local scroll = reader.view.page_scroll
    if paging.skim_backup then
        scroll = paging.skim_backup.page_scroll
    elseif paging.page_flipping_mode or paging.bookmark_flipping_mode then
        scroll = paging.orig_scroll_mode
    end
    reader.doc_settings:saveSetting("kopt_page_scroll", scroll and 1 or 0)
    reader.doc_settings:saveSetting("kopt_writing_direction", reader.view.document.configurable.writing_direction)
end

return Defaults
