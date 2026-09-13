local ffi = require("ffi")
require("ffi/posix_h")
local ffiutil = require("ffi/util")
local json = require("rapidjson")
local Util = require("bilicomics/util")
if ffi.os == "Linux" then
    if not pcall(function() return ffi.C.prctl end) then ffi.cdef[[int prctl(int option, ...);]] end
    if not pcall(function() return ffi.C.getppid end) then ffi.cdef[[int getppid(void);]] end
end
local Runner = {}
Runner.__index = Runner
local read_methods = { listFavorites = true, listHistory = true, search = true, comicDetail = true,
    imageIndex = true, wallet = true, purchaseInfo = true, validateSession = true }
local read_kinds = { library = true, quote = true, reconcile_purchase = true, download_page = true, download_cover = true }
local mutations = { purchase_submit = true, set_favorite = true, auth = true }
local function retryableRead(task, err)
    local request = task.request
    if not err or err.retryable ~= true then return false end
    if not read_kinds[request.kind] and not (request.kind == "client" and read_methods[request.method]) then return false end
    if err.kind == "network" or err.kind == "timeout" then return true end
    if err.kind == "http" or err.kind == "image_http" then
        local status = tonumber(err.status)
        return status == 429 or (status and status >= 500 and status <= 599) or false
    end
    return err.kind == "token_expired" and request.kind == "download_page"
end
local function closeFD(task)
    if task.fd then ffi.C.close(task.fd); task.fd = nil end
end
local function killTask(task)
    if not ffiutil.isSubProcessDone(task.pid) then
        ffi.C.kill(-task.pid, 9)
        -- Before the child's setpgid call, its private process group may not exist yet.
        ffi.C.kill(task.pid, 9)
    end
end
local function writeFrame(fd, packet, limit)
    local data = json.encode(packet)
    if not data or #data > limit then
        data = json.encode({ id = packet.id, attempt = packet.attempt,
            error = { kind = "worker_limit", message = "The worker response exceeded its size limit.", retryable = false } })
    end
    local frame = string.format("%08x\n", #data) .. data
    local offset = 0
    while offset < #frame do
        local size = tonumber(ffi.C.write(fd, frame:sub(offset + 1), #frame - offset))
        if size < 0 and ffi.errno() == 4 then
            -- Retry interrupted writes, including short writes to a full pipe.
        elseif size <= 0 then break
        else offset = offset + size end
    end
    ffi.C.close(fd)
end
function Runner.new(options)
    options = options or {}
    local self = setmetatable({ ui = options.ui or require("ui/uimanager"), clock = options.clock or require("socket").gettime,
        worker = options.worker or function(request) return require("bilicomics/jobs/worker").execute(request) end,
        limit = options.max_payload or 4 * 1024 * 1024, interval = options.interval or 0.05,
        max_workers = options.max_workers or 2, resource_limits = options.resource_limits or { image = 1 },
        retry_delay = math.max(0.01, options.retry_delay or 1),
        tasks = {}, queue = {}, sequence = 0, stopped = false, suspended = false }, Runner)
    self.tick = function() self:_tick() end
    return self
end
function Runner:_schedule()
    if self.stopped or (not next(self.tasks) and #self.queue == 0) then return end
    if self.suspended and not next(self.tasks) then return end
    local now, delay = self.clock(), self.interval
    if not next(self.tasks) then
        local earliest = math.huge
        for _, task in ipairs(self.queue) do earliest = math.min(earliest, task.not_before or now) end
        delay = math.max(self.interval, earliest - now)
    end
    if self.scheduled then
        if self.scheduled_at <= now + delay then return end
        self.ui:unschedule(self.tick)
    end
    self.scheduled = true
    self.scheduled_at = now + delay
    self.ui:scheduleIn(delay, self.tick)
end
function Runner:_counts()
    local total, resources = 0, {}
    for _, task in pairs(self.tasks) do
        total = total + 1
        if task.resource then resources[task.resource] = (resources[task.resource] or 0) + 1 end
    end
    return total, resources
end
function Runner:_hold(task)
    if not task.held and self.ui.preventStandby then self.ui:preventStandby(); task.held = true end
end
function Runner:_release(task)
    if task.held then task.held = nil; self.ui:allowStandby() end
end
function Runner:_start(task)
    if task.before_start then
        local ok, allowed, err = pcall(task.before_start)
        if not ok or allowed ~= true then
            Util.callback(task.callback, nil, type(err) == "table" and err
                or Util.error("canceled", "The background operation is no longer available.", { transmitted = false }))
            return
        end
    end
    task.attempt = (task.attempt or 0) + 1
    local id, attempt, request, worker, limit = task.id, task.attempt, task.request, self.worker, self.limit
    local parent_pid = tonumber(ffi.C.getpid())
    local pid, fd = ffiutil.runInSubProcess(function(_, child_fd)
        if ffi.os == "Linux" then
            local zero = ffi.cast("unsigned long", 0)
            local guarded = ffi.C.prctl(1, ffi.cast("unsigned long", 9), zero, zero, zero) == 0
            if not guarded then
                writeFrame(child_fd, { id = id, attempt = attempt, error = {
                    kind = "capability", message = "Worker lifetime could not be tied to the reader process.", retryable = false } }, limit)
                return
            end
            if tonumber(ffi.C.getppid()) ~= parent_pid then ffi.C._exit(0) end
        end
        local ok, value, err, session_update = pcall(worker, request)
        if not ok then value = nil; err = { kind = "worker", message = "The background operation failed.", retryable = false } end
        writeFrame(child_fd, { id = id, attempt = attempt, value = value, error = err,
            session_update = ok and session_update or nil }, limit)
    end, true)
    if not pid then
        Util.callback(task.callback, nil, Util.error("worker", "A background process could not be started."))
        return
    end
    task.pid, task.fd, task.buffer = pid, fd, ""
    task.started_at, task.cancel_kind = self.clock(), nil
    self.tasks[id] = task
    self:_hold(task)
end
function Runner:_pump()
    if self.stopped or self.suspended then return end
    table.sort(self.queue, function(a, b)
        if a.priority == b.priority then return a.sequence < b.sequence end
        return a.priority < b.priority
    end)
    while not self.stopped and not self.suspended and #self.queue > 0 do
        local total, resources = self:_counts()
        local candidate
        for index, task in ipairs(self.queue) do
            local available = not task.resource or not self.resource_limits[task.resource]
                or (resources[task.resource] or 0) < self.resource_limits[task.resource]
            if total < self.max_workers and available and (task.not_before or 0) <= self.clock() then candidate = index; break end
        end
        if not candidate then break end
        self:_start(table.remove(self.queue, candidate))
    end
    if self.stopped or self.suspended then return end
    -- A visible page may interrupt a long, cancelable prefetch occupying its resource slot.
    local urgent
    for _, task in ipairs(self.queue) do
        if (task.not_before or 0) <= self.clock() then urgent = task; break end
    end
    if urgent then
        local victim
        for _, task in pairs(self.tasks) do
            if task.cancelable and not task.cancel_kind and task.priority > urgent.priority
                and (not urgent.resource or task.resource == urgent.resource)
                and (not victim or task.priority > victim.priority) then victim = task end
        end
        if victim then victim.cancel_kind = "preempt"; killTask(victim) end
    end
end
function Runner:submit(request, options, callback)
    options = options or {}
    if self.stopped then Util.callback(callback, nil, Util.error("closed", "The background service is closed.")); return nil end
    self.sequence = self.sequence + 1
    local task = { id = options.id or Util.id("worker"), request = request, priority = options.priority or 40,
        sequence = self.sequence, timeout = options.timeout or 90, callback = callback, before_start = options.before_start,
        resource = options.resource, cancelable = options.cancelable ~= false and not mutations[request.kind],
        retry_limit = math.max(0, math.min(2, (options.retry_attempts or 3) - 1)), retries = 0 }
    for _, queued in ipairs(self.queue) do assert(queued.id ~= task.id, "Duplicate worker task") end
    assert(not self.tasks[task.id], "Duplicate worker task")
    self.queue[#self.queue + 1] = task
    self:_pump(); self:_schedule()
    return task.id
end
function Runner:promote(id, priority)
    for _, task in ipairs(self.queue) do if task.id == id then task.priority = math.min(task.priority, priority) end end
    if self.tasks[id] then self.tasks[id].priority = math.min(self.tasks[id].priority, priority) end
    self:_pump(); self:_schedule()
end
function Runner:cancel(id)
    for index = #self.queue, 1, -1 do
        local task = self.queue[index]
        if task.id == id then
            table.remove(self.queue, index)
            Util.callback(task.callback, nil, Util.error("canceled", "The operation was canceled.", { transmitted = false }))
            return true
        end
    end
    local task = self.tasks[id]
    if task then task.cancel_kind = "cancel"; killTask(task); self:_schedule(); return true end
    return false
end
function Runner:_read(task)
    local available = ffiutil.getNonBlockingReadSize(task.fd)
    if available == nil then return nil, Util.error("capability", "Nonblocking worker pipes are unavailable.") end
    local budget = math.min(available, 256 * 1024)
    if budget > 0 then
        local chunk = ffi.new("uint8_t[?]", budget)
        local count = tonumber(ffi.C.read(task.fd, chunk, budget))
        if count > 0 then task.buffer = task.buffer .. ffi.string(chunk, count) end
    end
    if #task.buffer > self.limit + 9 then return nil, Util.error("worker_limit", "The worker response exceeded its size limit.") end
    if #task.buffer < 9 then return end
    local length = task.buffer:sub(1, 8):match("^[0-9a-f]+$") and tonumber(task.buffer:sub(1, 8), 16)
    if not length or task.buffer:sub(9, 9) ~= "\n" or length > self.limit then return nil, Util.error("worker_protocol", "The background response was invalid.") end
    if #task.buffer < length + 9 then return end
    if #task.buffer ~= length + 9 then return nil, Util.error("worker_protocol", "The background response contained trailing data.") end
    local ok, packet = pcall(json.decode, task.buffer:sub(10))
    if not ok or type(packet) ~= "table" or packet.id ~= task.id or packet.attempt ~= task.attempt then
        return nil, Util.error("worker_protocol", "The background response identity did not match.")
    end
    return packet
end
function Runner:_finish(task, packet, err)
    closeFD(task)
    self.tasks[task.id] = nil
    self:_release(task)
    if task.cancel_kind == "preempt" and not self.stopped then
        task.buffer, task.pid, task.packet, task.read_error = nil, nil, nil, nil
        self.queue[#self.queue + 1] = task
    else
        local value = packet and packet.value
        if task.cancel_kind then
            value = nil
            err = Util.error(task.cancel_kind == "timeout" and "timeout" or "canceled",
                task.cancel_kind == "timeout" and "The background operation timed out." or "The operation was canceled.",
                { retryable = task.cancelable and task.cancel_kind == "timeout", transmitted = true })
        else
            err = err or (packet and packet.error)
                or (not packet and Util.error("worker", "The background process exited without a complete response."))
        end
        if not value and not (packet and packet.session_update) and not self.stopped
            and task.retries < task.retry_limit and retryableRead(task, err) then
            task.retries = task.retries + 1
            task.not_before = self.clock() + math.min(8, self.retry_delay * 2 ^ (task.retries - 1))
            task.buffer, task.pid, task.packet, task.read_error, task.cancel_kind = nil, nil, nil, nil, nil
            self.queue[#self.queue + 1] = task
        else Util.callback(task.callback, value, err, not task.cancel_kind and packet and packet.session_update or nil) end
    end
end
function Runner:_tick()
    self.scheduled = false
    self.scheduled_at = nil
    local snapshot = {}
    for _, task in pairs(self.tasks) do snapshot[#snapshot + 1] = task end
    for _, task in ipairs(snapshot) do
        if not task.packet and not task.read_error and not task.cancel_kind then
            task.packet, task.read_error = self:_read(task)
            if task.read_error then killTask(task) end
        end
        if not task.cancel_kind and self.clock() - task.started_at > task.timeout then
            task.cancel_kind = "timeout"; killTask(task)
        end
        local done = ffiutil.isSubProcessDone(task.pid)
        if done then
            if not task.packet and not task.read_error and not task.cancel_kind then task.packet, task.read_error = self:_read(task) end
            -- Drain large completed responses over subsequent ticks without blocking the UI.
            if task.packet or task.read_error or task.cancel_kind or ffiutil.getNonBlockingReadSize(task.fd) == 0 then
                self:_finish(task, task.packet, task.read_error)
            end
        end
    end
    self:_pump(); self:_schedule()
end
function Runner:suspend()
    self.suspended = true
    for _, task in pairs(self.tasks) do
        if task.cancelable and not task.cancel_kind then task.cancel_kind = "preempt"; killTask(task) end
    end
    self:_schedule()
end
function Runner:resume() self.suspended = false; self:_pump(); self:_schedule() end
function Runner:close()
    self.stopped = true
    local queued = self.queue; self.queue = {}
    for _, task in ipairs(queued) do Util.callback(task.callback, nil, Util.error("closed", "The background service is closed.")) end
    for _, task in pairs(self.tasks) do
        killTask(task)
        -- Only teardown waits to reap; no network work remains in these killed processes.
        ffiutil.isSubProcessDone(task.pid, true)
        task.cancel_kind = "close"
        self:_finish(task)
    end
    if self.scheduled then self.ui:unschedule(self.tick); self.scheduled = false end
end
return Runner
