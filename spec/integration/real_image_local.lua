-- Run only on authorized test-env with explicitly supplied local image files.
require("setupkoenv")
local source, work, phase, image_path = assert(arg[1]), assert(arg[2]), assert(arg[3]), arg[4]
assert(phase == "open" or phase == "reopen")
package.path = source .. "/?.lua;" .. package.path
local json = require("rapidjson")
local ffi = require("ffi")
local report = { checks = {} }
local function check(name, value)
    report.checks[name] = not not value
    assert(value, name)
end
local function forbidden()
    report.checks.no_network_or_worker_attempts = false
    error("Acquisition is forbidden in the local reader probe")
end
-- These modules are outside this local rendering boundary, including payment.
for _, name in ipairs({ "bilicomics/jobs/runner", "bilicomics/jobs/worker",
    "bilicomics/protocol/client", "bilicomics/protocol/session", "bilicomics/purchase/service" }) do
    package.preload[name] = forbidden
end
local socket = require("socket")
for _, key in ipairs({ "tcp", "tcp6", "udp", "udp6", "connect" }) do socket[key] = forbidden end
if socket.dns then
    socket.dns.toip, socket.dns.tohostname, socket.dns.getaddrinfo = forbidden, forbidden, forbidden
end
report.checks.no_network_or_worker_attempts = true
local Files = require("bilicomics/storage/files")
local Header = require("bilicomics/storage/image_header")
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Codec = require("bilicomics/storage/codec")
local store, reader, integration
local UIManager

local ok = xpcall(function()
    ffi.cdef[[long readlink(const char *path, char *buf, unsigned long bufsiz);]]
    local ns = ffi.new("char[128]")
    local length = ffi.C.readlink("/proc/self/ns/net", ns, 128)
    check("isolated_network_namespace", length > 0
        and ffi.string(ns, length) ~= assert(os.getenv("BILI_PARENT_NETNS")))
    local route_file = assert(io.open("/proc/net/route", "rb"))
    local route = route_file:read(8192) or ""
    route_file:close()
    check("no_network_routes", not route:match("\n[^\n]+\t[0-9A-F]+\t"))
    G_defaults = require("luadefaults"):open()
    local DataStorage = require("datastorage")
    G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
    G_reader_settings:saveSetting("color_rendering", false)
    local disabled = {}
    for name in require("libs/libkoreader-lfs").dir("plugins") do
        local key = name:match("^(.*)%.koplugin$")
        if key then disabled[key] = true end
    end
    G_reader_settings:saveSetting("plugins_disabled", disabled)
    local Device = require("device")
    require("document/canvascontext"):init(Device)
    UIManager = require("ui/uimanager")
    local Provider = require("bilicomics/reader/document")
    local Integration = require("bilicomics/reader/integration")
    local Anchors = require("bilicomics/reader/anchors")
    local ReaderUI = require("apps/reader/readerui")
    local Registry = require("document/documentregistry")
    local account_key, episode_id, revision = "bili_939393", "939301", "local_1"
    local account_root = work .. "/account"
    store = Store.open{ root = account_root, account_key = account_key }
    local pages = PageStore.new{ root = account_root, account_key = account_key, store = store }
    local descriptor, descriptor_path
    if phase == "open" then
        local header = Header.read(assert(image_path))
        local width, height = header.width, header.height
        local orientation = header.exif_orientation or 1
        if orientation >= 5 then width, height = height, width end
        report.width, report.height, report.format = width, height, header.format
        local maximum = header.format == "jpg" and 32000000 or 4000000
        check("within_existing_decode_budget", header.width * header.height <= maximum)
        store:upsertComic{ id = "9393", title = "Local image probe" }
        store:upsertEpisodes("9393", { { id = episode_id, comic_id = "9393", order = 1,
            title = "Local sample", access = "owned", extra = { current_revision = revision } } })
        descriptor = { schema_version = 1, account_key = account_key, comic_id = "9393",
            episode_id = episode_id, revision = revision,
            pages = { { id = "sample-page", index = 1, width = width, height = height } } }
        descriptor_path = pages:ensureDescriptor(descriptor)
        local temporary = pages.temporary_root .. "/local-image.part"
        local input, output = assert(io.open(image_path, "rb")), assert(io.open(temporary, "wb"))
        while true do
            local chunk = input:read(65536)
            if not chunk then break end
            assert(output:write(chunk))
        end
        assert(input:close()); assert(output:close())
        pages:commitPage({ episode_id = episode_id, revision = revision, index = 1,
            expected_content_generation = 0 }, { temporary_path = temporary,
            checksum = Files.digest(temporary), width = width, height = height, format = header.format,
            geometry = { source_width = header.width, source_height = header.height,
                exif_orientation = orientation } })
        Files.atomicWrite(work .. "/descriptor-path.txt", descriptor_path)
    else
        descriptor_path = Files.read(work .. "/descriptor-path.txt", 4096)
        descriptor = pages:readDescriptor(descriptor_path)
        local page = pages:getPage(episode_id, revision, 1)
        report.width, report.height, report.format = page.width, page.height, page.format
    end
    check("committed_local_page_ready", pages:isComplete(episode_id, revision))
    local expected = phase == "reopen" and store:getAnchor(episode_id, revision) or nil
    if phase == "reopen" then check("durable_anchor_available", expected ~= nil) end
    local services = { store = store, pages = pages,
        settings = { reading_mode = "strip", reading_direction = "ltr" },
        isCurrent = function() return true end,
        authorizeDescriptor = function(value)
            return value.account_key == account_key
                and Codec.canonical(value) == Codec.canonical(store:getDescriptor(episode_id, revision))
                and store:getEpisode(episode_id).access == "owned"
        end,
        requestPage = function(_, index)
            check("all_reader_hints_stay_local", pages:getPage(episode_id, revision, index).state == "ready")
        end }
    Provider:setServicesResolver(function(key) assert(key == account_key); return services end)
    Provider:register()
    -- Observe real ReaderUI paints without replacing any decode or drawing result.
    local original_init = Provider.init
    function Provider:init()
        original_init(self)
        local policy = self._document.policy
        check("unchanged_decode_and_buffer_limits", policy.max_lossless_pixels == 4000000
            and policy.max_jpeg_pixels == 32000000 and policy.max_tile_bytes == 16 * 1024 * 1024
            and policy.max_intermediate_pixels == 2000000)
        local original_open = self._document.openPage
        function self._document:openPage(index)
            local native_page = original_open(self, index)
            local original_draw = native_page.draw
            function native_page:draw(...)
                original_draw(self, ...)
                local context = self.owner.owner._probe_draw
                if context then context.decoded = true end
            end
            return native_page
        end
        local original_placeholder, original_draw = self._placeholder, self._draw
        function self:_placeholder(...)
            if self._probe_draw then self._probe_draw.placeholder = true end
            self._probe_placeholder = true
            return original_placeholder(self, ...)
        end
        function self:_draw(...)
            local context = {}
            self._probe_draw = context
            original_draw(self, ...)
            if context.decoded and not context.placeholder and next(self._render_errors) == nil
                and next(self._document.active) == nil then self._probe_decoded = true end
            self._probe_draw = nil
        end
    end
    local function closeReader()
        local document = reader.document
        reader:onClose()
        check("native_reader_closed", ReaderUI.instance == nil and integration.closed)
        check("native_document_released", not document.is_open and Registry:getReferenceCount(descriptor_path) == nil)
        if phase == "open" then
            local saved = store:getAnchor(episode_id, revision)
            check("scrolled_anchor_saved_on_close", saved and expected
                and saved.page_id == expected.page_id and math.abs(saved.y - expected.y) < 0.005
                and math.abs(saved.x - expected.x) < 0.005)
        end
        UIManager:quit()
    end
    services.onReaderEvent = function(name, event)
        if name == "page_error" or name == "anchor_error" then check("no_reader_errors", false) end
        if name ~= "opened" then return end
        UIManager:nextTick(function()
            check("matching_native_opened_event", event.reader == reader
                and event.reader_generation == integration.generation and reader == ReaderUI.instance)
            if phase == "open" then
                reader.zooming:onSetZoomMode("pagewidth")
                reader.view:onSetScrollMode(true)
            end
            reader:paintTo(Device.screen.bb, 0, 0)
            check("actual_native_image_draw", reader.document._probe_decoded
                and not reader.document._probe_placeholder and next(reader.document._render_errors) == nil)
            if phase == "reopen" then
                local anchor = Anchors.capture(reader)
                check("source_anchor_restored", anchor and anchor.page_id == expected.page_id
                    and math.abs(anchor.x - expected.x) < 0.005 and math.abs(anchor.y - expected.y) < 0.005)
                check("continuous_mode_restored", reader.view.page_scroll == true)
                closeReader()
            else
                local before = Anchors.capture(reader)
                reader.paging:onGotoViewRel(1)
                reader:paintTo(Device.screen.bb, 0, 0)
                expected = Anchors.capture(reader)
                check("native_scroll_moves_within_source", expected and before
                    and expected.page_id == before.page_id and expected.y > before.y)
                check("scrolled_view_has_no_placeholder", not reader.document._probe_placeholder
                    and next(reader.document._render_errors) == nil)
                closeReader()
            end
        end)
    end
    ReaderUI:showReader(descriptor_path, Provider)
    local function attach()
        reader = ReaderUI.instance
        if not reader then UIManager:scheduleIn(0.05, attach); return end
        integration = assert(Integration.attach(reader, { services = services }))
    end
    UIManager:nextTick(attach)
    UIManager:scheduleIn(15, function() error("Local reader probe timed out") end)
    UIManager:run()
end, function(err)
    -- Failure detail remains only in private remote logs; published results use booleans.
    io.stderr:write(debug.traceback(tostring(err), 2):gsub("[^%s]*/", ""), "\n")
    return "Local reader probe failed"
end)
if reader and reader.document and reader.document.is_open then pcall(reader.onClose, reader) end
if store then pcall(store.close, store) end
report.passed = ok
for _, value in pairs(report.checks) do report.passed = report.passed and value end
local output = assert(io.open(work .. "/" .. phase .. "-result.json", "wb"))
output:write(json.encode(report, { pretty = true })); output:close()
os.exit(report.passed and 0 or 1)
