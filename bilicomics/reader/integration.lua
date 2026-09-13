local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Anchors = require("bilicomics/reader/anchors")
local Compatibility = require("bilicomics/reader/compatibility")
local Defaults = require("bilicomics/reader/defaults")

local Integration = {}
Integration.__index = Integration
local next_generation = 0

local function remove(container, value)
    for index = #container, 1, -1 do
        if container[index] == value then table.remove(container, index); return end
    end
end

function Integration.attach(reader, options)
    if not reader.document or reader.document.provider ~= "bilicomics_document" then return nil end
    if reader.bilicomics_integration then return reader.bilicomics_integration end
    options = options or {}
    next_generation = next_generation + 1
    local self = setmetatable({ reader = reader, document = reader.document,
        services = options.services or reader.document.services,
        generation = next_generation, closed = false, pending_transition = false }, Integration)
    local descriptor = self.document.descriptor
    if self.services.pages.setActiveEpisode then
        local acquired = pcall(self.services.pages.setActiveEpisode, self.services.pages,
            descriptor.episode_id, descriptor.revision, true)
        if not acquired then
            return nil, { kind = "storage", message = "The chapter could not be protected for reading", retryable = true }
        end
        self.active_acquired = true
    end
    self.observer = WidgetContainer:new{}
    local function settled() self:scheduleSave() end
    self.observer.onPageUpdate = settled
    self.observer.onViewRecalculate = settled
    self.observer.onPagePositionUpdated = settled
    self.observer.onSuspend = function() self:saveAnchor(); self:emit("suspend") end
    self.observer.onResume = function() self:emit("resume") end
    self.observer.onSaveSettings = function() Defaults.save(reader) end
    self.observer.onCloseDocument = function() self:close(true) end
    -- ReaderUI's first child owns painting. Leave it in place; observe before paging/status handlers.
    table.insert(reader, 2, self.observer)
    local compatible, adapter = pcall(Compatibility.attach, reader, self)
    if not compatible then
        remove(reader, self.observer)
        reader.bilicomics_integration = nil
        self.document._allow_hints = false
        if self.services.pages.setActiveEpisode then
            self.services.pages:setActiveEpisode(descriptor.episode_id, descriptor.revision, false)
            self.active_acquired = false
        end
        return nil, { kind = "unsupported_reader_version", message = "The native reader integration is unavailable", retryable = false }
    end
    self.compatibility = adapter
    reader.bilicomics_integration = self
    self.document._reader_generation = self.generation
    self.document._allow_hints = true
    self.save_callback = function()
        if self:isCurrent() then self:saveAnchor(); self:requestVisible() end
    end
    self.restore_callback = function()
        if not self:isCurrent() then return end
        local anchor = self.services.store:getAnchor(descriptor.episode_id, descriptor.revision)
        anchor = Defaults.apply(reader, self.services.settings, anchor)
        if anchor then pcall(Anchors.restore, reader, anchor) end
        self:requestVisible()
        self:emit("opened")
    end
    UIManager:nextTick(self.restore_callback)
    return self
end

function Integration:isCurrent()
    return not self.closed and self.reader.document == self.document and self.document.is_open
        and (not self.services.isCurrent or self.services.isCurrent())
end

function Integration:emit(name, extra)
    if self.services.onReaderEvent then
        local event = extra or {}
        event.descriptor = self.document.descriptor
        event.reader_generation = self.generation
        event.reader = self.reader
        local ok = pcall(self.services.onReaderEvent, name, event)
        if not ok then
            require("logger").warn("Bilibili reader event handler failed", name)
        end
    end
end

function Integration:scheduleSave()
    if self.closed or not self.save_callback then return end
    UIManager:unschedule(self.save_callback)
    UIManager:scheduleIn(0.25, self.save_callback)
end

function Integration:saveAnchor()
    if not self:isCurrent() then return end
    local anchor = Anchors.capture(self.reader)
    if not anchor then return end
    local signature = table.concat({ anchor.page_id, anchor.x, anchor.y, anchor.mode,
        anchor.rotation, anchor.geometry_generation, anchor.zoom_mode or "", anchor.zoom_ratio or 1,
        anchor.source and anchor.source.x or 0, anchor.source and anchor.source.y or 0 }, ":")
    if signature == self.last_anchor then return end
    local descriptor = self.document.descriptor
    local saved = pcall(self.services.store.putAnchor, self.services.store,
        descriptor.episode_id, descriptor.revision, anchor)
    if not saved then
        self:emit("anchor_error", { error = { kind = "storage", message = "The reading position could not be saved", retryable = true } })
        return false
    end
    self.last_anchor = signature
    self:emit("position", { anchor = anchor })
end

function Integration:requestVisible()
    if not self:isCurrent() then return end
    local reader = self.reader
    local index = reader.paging:getTopPage()
    self.document:requestPage(index, false)
    if reader.view.page_scroll then
        for _, state in ipairs(reader.view.page_states or {}) do
            self.document:requestPage(state.page, false)
        end
    end
    for number = index + 1, math.min(index + 3, self.document:getPageCount()) do
        self.document:requestPage(number, true)
    end
    if index >= self.document:getPageCount() - 2 then self:emit("near_end", { index = index }) end
end

function Integration:notifyPageReady(page)
    if not self:isCurrent() then return false end
    local descriptor = self.document.descriptor
    if tostring(page.episode_id) ~= descriptor.episode_id or tostring(page.revision) ~= descriptor.revision then
        return false
    end
    local index = page.index
    local previous = self.document._known_geometry[index]
    if not previous then return false end
    local changed = previous.geometry_generation ~= (page.geometry_generation or 0)
        or previous.width ~= page.width or previous.height ~= page.height
    local anchor
    if changed then
        local dimensions = self.reader.paging:getTopPage() == index and previous or nil
        anchor = Anchors.capture(self.reader, dimensions)
    end
    self.document._known_geometry[index] = { width = page.width, height = page.height,
        geometry_generation = page.geometry_generation or 0, geometry = page.geometry or (page.extra and page.extra.geometry) }
    self.document._render_errors[index] = nil
    self.compatibility:invalidate(index)
    if changed then
        self.document.bbox[index] = nil
        local Event = require("ui/event")
        -- Recompute zoom from the corrected geometry before restoring a normalized source position.
        if self.reader.zooming then self.reader.zooming:onSetZoomMode(self.reader.view.zoom_mode or "pagewidth") end
        self.reader:handleEvent(Event:new("PageUpdate", self.reader.paging:getTopPage()))
        if anchor then Anchors.restore(self.reader, anchor) end
    end
    UIManager:setDirty(self.reader.dialog, "partial")
    return true
end

function Integration:onEndOfBook()
    if self.closed then return true end
    if self.pending_transition then return true end
    self.pending_transition = true
    self.transition_callback = function()
        if self:isCurrent() then self:saveAnchor(); self:emit("end_of_book") end
    end
    UIManager:nextTick(self.transition_callback)
    return true
end

function Integration:finishTransition()
    self.pending_transition = false
end

function Integration:close(in_event_dispatch)
    if self.closed then return end
    local saved = pcall(function()
        Defaults.save(self.reader)
        self:saveAnchor()
    end)
    if not saved then
        self:emit("anchor_error", { error = { kind = "storage", message = "The reading position could not be saved", retryable = true } })
    end
    self.closed = true
    self.document._allow_hints = false
    UIManager:unschedule(self.save_callback)
    UIManager:unschedule(self.restore_callback)
    if self.transition_callback then UIManager:unschedule(self.transition_callback) end
    self.compatibility:close()
    if not in_event_dispatch then remove(self.reader, self.observer) end
    local descriptor = self.document.descriptor
    if self.active_acquired then
        self.services.pages:setActiveEpisode(descriptor.episode_id, descriptor.revision, false)
        self.active_acquired = false
    end
    self:emit("closed")
    self.reader.bilicomics_integration = nil
end

return Integration
