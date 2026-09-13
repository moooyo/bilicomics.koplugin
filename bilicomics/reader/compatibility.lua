local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Compatibility = {}
Compatibility.__index = Compatibility

local function restore(object, name, value)
    object[name] = value
end

local function detach(container, child)
    for index = #container, 1, -1 do
        if container[index] == child then table.remove(container, index); break end
    end
end

function Compatibility.attach(reader, integration)
    assert(reader.status, "This KOReader version has no reader status container")
    local self = setmetatable({ reader = reader, integration = integration, originals = {} }, Compatibility)
    self.interceptor = WidgetContainer:new{}
    self.interceptor.onEndOfBook = function() return integration:onEndOfBook() end
    table.insert(reader.status, 1, self.interceptor)
    local ok, failure = pcall(self.guardThumbnails, self)
    if not ok then
        pcall(self.close, self)
        error(failure)
    end
    return self
end

function Compatibility:guardThumbnails()
    local thumbnail = self.reader.thumbnail
    if not thumbnail or not thumbnail.thumbnails_requests then return end
    self.thumbnail = thumbnail
    local document, integration = self.reader.document, self.integration
    for _, name in ipairs({ "getPageThumbnail", "startTileGeneration", "checkTileGeneration", "_getPageImage" }) do
        self.originals[name] = { own = rawget(thumbnail, name), method = thumbnail[name] }
    end
    local function signature(page)
        if not integration:isCurrent() then return nil end
        if not document:isPageReady(page) then return nil end
        return integration.generation .. ":" .. document:getPageGeneration(page)
    end
    thumbnail.getPageThumbnail = function(target, page, width, height, batch, callback)
        local generation = signature(page)
        if not generation then callback(nil, batch, false); return false end
        target:setupCache()
        target.current_target_size_tag = string.format("w%d_h%d", width, height)
        local hash = string.format("p%d-%s-comic=%s", page, target.current_target_size_tag, generation)
        local cached = target.tile_cache:check(hash)
        if cached then callback(cached, batch, false); return false end
        target.thumbnails_requests[batch] = target.thumbnails_requests[batch] or {}
        local request = {
            hash = hash, page = page, width = width, height = height, batch_id = batch,
            comic_generation = generation,
        }
        request.when_generated_callback = function(tile, batch_id, delayed)
            request.comic_callback_delivered = true
            if signature(page) == generation then callback(tile, batch_id, delayed)
            else callback(nil, batch_id, delayed) end
        end
        table.insert(target.thumbnails_requests[batch], request)
        target._ensureTileGeneration_action(true)
        return true
    end
    thumbnail.startTileGeneration = function(target, request)
        if request.comic_generation ~= signature(request.page) then return false end
        -- Snapshot in the parent, before fork. No inherited SQLite handle is used by the child.
        target._comic_snapshot = document:localSnapshot()
        local ok, result = pcall(self.originals.startTileGeneration.method, target, request)
        target._comic_snapshot = nil
        if not ok then return false end
        return result
    end
    thumbnail._getPageImage = function(target, page)
        document:enterThumbnailMode(assert(target._comic_snapshot, "Missing thumbnail snapshot"))
        assert(document:isPageReady(page), "Thumbnail image is not locally usable")
        local original_hint = document.hintPage
        document.hintPage = function() end
        local result = self.originals._getPageImage.method(target, page)
        document.hintPage = original_hint
        if not document:isPageReady(page) then
            result:free()
            error("The thumbnail image could not be decoded")
        end
        return result
    end
    thumbnail.checkTileGeneration = function(target, request)
        local cache = target.tile_cache
        local previous_insert, inherited_insert
        if cache then
            previous_insert = rawget(cache, "insert")
            inherited_insert = cache.insert
            cache.insert = function(cache_object, hash, tile)
                -- Checking only the callback is too late: native code inserts before invoking it.
                if request.comic_generation == signature(request.page) then
                    return inherited_insert(cache_object, hash, tile)
                end
                tile:onFree()
            end
        else
            target.tile_cache = { insert = function(_, _, tile) tile:onFree() end }
        end
        local ok, running, collect = pcall(self.originals.checkTileGeneration.method, target, request)
        if cache then cache.insert = previous_insert else target.tile_cache = nil end
        if not ok then error(running) end
        if not running and request.when_generated_callback and not request.comic_callback_delivered then
            -- Native EOF-without-output does not notify its requester. Surface a failed
            -- child as unavailable instead of leaving a page-browser request pending.
            request.when_generated_callback(nil, request.batch_id, true)
        end
        return running, collect
    end
end

function Compatibility:invalidate(index)
    if self.thumbnail then self.thumbnail:removeFromCache(string.format("p%d-", index)) end
end

function Compatibility:close()
    if self.closed then return end
    self.closed = true
    detach(self.reader.status, self.interceptor)
    if self.thumbnail then
        self.thumbnail:cancelPageThumbnailRequests()
        self.thumbnail:resetCache()
        -- Keep generation filtering alive until an already-running native child is collected.
        -- Other instance methods can safely return to their original definitions immediately.
        for name, original in pairs(self.originals) do
            if name ~= "checkTileGeneration" then restore(self.thumbnail, name, original.own) end
        end
        local target, original_check = self.thumbnail, self.originals.checkTileGeneration
        if not target.req_in_progress then
            restore(target, "checkTileGeneration", original_check.own)
        else
            local guarded_check = target.checkTileGeneration
            target.checkTileGeneration = function(object, request)
                local running, collect = guarded_check(object, request)
                if not running then restore(object, "checkTileGeneration", original_check.own) end
                return running, collect
            end
        end
    end
end

return Compatibility
