-- Shared credential-boundary cases for the Linux runtime and official Android app.
local Controller = require("bilicomics/controller")
local SessionStorage = require("bilicomics/session_storage")
local Session = require("bilicomics/protocol/session")
local Settings = require("bilicomics/settings")
local Store = require("bilicomics/storage/store")
local PageStore = require("bilicomics/storage/page_store")
local Files = require("bilicomics/storage/files")
local lfs = require("libs/libkoreader-lfs")
local ffi = require("ffi")
ffi.cdef[[int chmod(const char *path, unsigned int mode); int symlink(const char *target, const char *path);]]

return function(options)
    local checks = {}
    local function check(name, passed)
        checks[#checks + 1] = { name = name, passed = not not passed }
        assert(passed, name)
    end
    local root, private = options.root, options.private_root
    Files.mkdir(root)
    if not options.native_android then Files.mkdir(private); assert(ffi.C.chmod(private, 448) == 0) end
    local storage = SessionStorage.new{ data_root = root, android = { dir = private } }
    local mid = options.mid or "987650" .. tostring(os.time())
    local key, other_key = "bili_" .. mid, "bili_" .. mid .. "1"
    local function session(identifier, suffix)
        local value = assert(Session.parse("SESSDATA=synthetic-private-" .. suffix .. "; DedeUserID=" .. identifier))
        return assert(value:withIdentity({ id = identifier, name = "Synthetic private session" }))
    end
    local original = session(mid, "legacy")
    local legacy = root .. "/accounts/" .. key .. "/session.dat"
    Files.mkdir(Files.parent(legacy)); assert(original:save(legacy))
    local other_legacy = root .. "/accounts/" .. other_key .. "/session.dat"
    Files.mkdir(Files.parent(other_legacy)); assert(session(mid .. "1", "unselected"):save(other_legacy))
    local settings = Settings.open(root)
    settings:set("active_account_key", key)
    settings:set("account_summary:" .. key, { id = mid, name = "Synthetic offline account" })
    local store = Store.open{ root = root .. "/accounts/" .. key, account_key = key }
    local pages = PageStore.new{ root = store.root, account_key = key, store = store }
    store:upsertComic{ id = "1", title = "Synthetic cached comic", last_read_at = os.time(), last_episode_id = "10" }
    store:upsertEpisodes("1", { { id = "10", comic_id = "1", order = 1, title = "Cached chapter", access = "owned", extra = { current_revision = "private-test" } } })
    local descriptor = { schema_version = 1, account_key = key, comic_id = "1", episode_id = "10", revision = "private-test",
        pages = { { id = "private-test-image", index = 1, width = 20, height = 40 } } }
    pages:ensureDescriptor(descriptor)
    local temporary = pages.temporary_root .. "/fixture.part"
    Files.write(temporary, Files.read(options.fixture))
    pages:commitPage({ episode_id = "10", revision = "private-test", index = 1, expected_content_generation = 0 },
        { temporary_path = temporary, format = "png", width = 20, height = 40, checksum = Files.digest(temporary) })
    store:close()
    local ui = { queue = {} }
    function ui:nextTick(fn) self.queue[#self.queue + 1] = fn end
    function ui:scheduleIn() end
    function ui:unschedule() end
    function ui:show() end
    function ui:close() end
    function ui:drain() while #self.queue > 0 do table.remove(self.queue, 1)() end end
    local runners = {}
    local function runnerFactory()
        local runner = { tasks = {}, submitted = 0 }
        function runner:submit(request, _, callback)
            self.submitted = self.submitted + 1
            self.tasks[self.submitted] = { request = request, callback = callback }
            return self.submitted
        end
        function runner:cancel() end
        function runner:suspend() end
        function runner:resume() end
        function runner:close() self.closed = true end
        runners[#runners + 1] = runner
        return runner
    end
    local function controller_with(selected_storage)
        return Controller.new{ root = root, ui_manager = ui, runner_factory = runnerFactory,
            network = { isConnected = function() return true end }, session_storage = selected_storage }
    end
    local controller = controller_with(storage); ui:drain()
    local private_path = assert(storage:path(key))
    check("android_session_path_is_under_context_files_dir", private_path == private .. "/bilicomics/accounts/" .. key .. "/session.dat")
    check("first_read_does_not_adopt_legacy_shared_session", controller.account.session == nil and not controller:getAccount().session_valid)
    check("first_read_does_not_create_or_remove_credential_files", not lfs.symlinkattributes(Files.parent(private_path)) and Files.exists(legacy))
    check("cached_account_database_stays_in_data_storage", controller.account.store.root == root .. "/accounts/" .. key)
    check("cached_owned_content_remains_readable_without_import", controller:authorizeDescriptor(descriptor) == true
        and controller.account.pages:isComplete("10", "private-test") and #controller:getLibrary("history") == 1)
    check("readonly_startup_does_not_send_network_requests", controller.runner.submitted == 0)
    local function validate_import(target, identifier, suffix)
        local result, failure
        target:importSession("SESSDATA=synthetic-private-" .. suffix .. "; DedeUserID=" .. identifier,
            function(value, err) result, failure = value, err end)
        local task = target.runner.tasks[target.runner.submitted]
        assert(task and task.request.method == "validateSession", "Import must validate in a worker")
        check("import_waits_for_explicit_worker_validation_" .. suffix, result == nil)
        task.callback({ session = session(identifier, suffix):serialize() }); ui:drain()
        return result, failure
    end
    local imported, import_error = validate_import(controller, mid, "verified")
    check("validated_import_enables_private_session", imported and not import_error and controller.account.session_valid)
    check("legacy_cleanup_occurs_only_for_selected_account", not Files.exists(legacy) and Files.exists(other_legacy))
    local process_uid = tonumber(ffi.C.getuid())
    local private_attributes = assert(lfs.symlinkattributes(private_path))
    check("saved_private_file_is_owned_regular_0600_single_link", private_attributes.mode == "file" and tonumber(private_attributes.uid) == process_uid
        and private_attributes.permissions == "rw-------" and tonumber(private_attributes.nlink) == 1)
    local directory_paths = { private .. "/bilicomics", private .. "/bilicomics/accounts", (Files.parent(private_path)) }
    for index, path in ipairs(directory_paths) do
        local attr = assert(lfs.symlinkattributes(path))
        check("private_directory_0700_uid_" .. index, attr.mode == "directory" and tonumber(attr.uid) == process_uid and attr.permissions == "rwx------")
    end
    check("private_session_can_be_loaded_after_verification", storage:load(key) ~= nil)
    assert(original:save(legacy))
    assert(ffi.C.chmod(private_path, 256) == 0)
    check("private_filesystem_enforces_permission_changes", lfs.symlinkattributes(private_path).permissions == "r--------")
    local unsafe = storage:load(key)
    check("unsafe_private_mode_is_rejected_without_legacy_fallback", unsafe == nil and Files.exists(legacy))
    assert(ffi.C.chmod(private_path, 384) == 0)
    local sentinel = root .. "/sentinel.txt"
    Files.write(sentinel, "Synthetic link target; no credentials.")
    local backup = private_path .. ".backup"
    assert(os.rename(private_path, backup)); assert(ffi.C.symlink(sentinel, private_path) == 0)
    check("session_file_symlink_is_not_loaded", storage:load(key) == nil)
    check("session_file_symlink_is_not_followed_on_save", storage:save(session(mid, "link-rejected")) == nil
        and Files.read(sentinel) == "Synthetic link target; no credentials.")
    assert(os.remove(private_path)); assert(os.rename(backup, private_path))
    local linked_directory = private .. "/bilicomics/accounts/" .. other_key
    local external_target = root .. "/linked-target"
    Files.mkdir(external_target); assert(ffi.C.symlink(external_target, linked_directory) == 0)
    check("account_directory_symlink_is_rejected", storage:save(session(mid .. "1", "directory-link")) == nil
        and not Files.exists(external_target .. "/session.dat"))
    assert(os.remove(linked_directory))
    check("unverified_and_path_like_account_keys_are_rejected", storage:save(assert(Session.parse("SESSDATA=synthetic-unverified"))) == nil
        and storage:path("../outside") == nil)
    if options.native_android then
        local shared_owner = tonumber(lfs.symlinkattributes(root).uid)
        local shared_candidate = SessionStorage.new{ data_root = root, android = { dir = root } }
        check("shared_fuse_directory_is_not_accepted_as_private_app_storage", shared_owner ~= process_uid
            and shared_candidate:save(session(mid .. "2", "shared-rejected")) == nil)
        local automatic = SessionStorage.new{ data_root = root }
        check("production_android_detection_uses_context_files_dir", automatic.is_android and automatic:path(key) == private_path)
    else
        local linux = SessionStorage.new{ data_root = root, android = false }
        check("linux_session_path_is_unchanged", linux:path(key) == legacy)
        check("linux_existing_session_still_loads", linux:load(key) ~= nil)
    end
    local failed_mid = mid .. "3"
    local failed_legacy = root .. "/accounts/bili_" .. failed_mid .. "/session.dat"
    Files.mkdir(Files.parent(failed_legacy)); assert(session(failed_mid, "failed-legacy"):save(failed_legacy))
    local real_save = storage.save
    storage.save = function() return nil, { kind = "storage", message = "Synthetic private save failure" } end
    local failure_result, failure = validate_import(controller, failed_mid, "save-failure")
    storage.save = real_save
    check("failed_private_save_preserves_legacy_and_selected_account", failure_result == nil and failure.kind == "storage"
        and Files.exists(failed_legacy) and controller.account.key == key and not Files.exists(storage:path("bili_" .. failed_mid)))
    local rollback_mid = mid .. "4"
    local rollback_key = "bili_" .. rollback_mid
    local rollback_legacy = root .. "/accounts/" .. rollback_key .. "/session.dat"
    Files.mkdir(Files.parent(rollback_legacy)); assert(session(rollback_mid, "rollback-legacy"):save(rollback_legacy))
    local open_account = controller._openAccount
    controller._openAccount = function(self, selected, ...)
        if selected == rollback_key then error("Synthetic account storage open failure") end
        return open_account(self, selected, ...)
    end
    local rolled_back, rollback_error = validate_import(controller, rollback_mid, "account-rollback")
    controller._openAccount = open_account
    check("account_open_rollback_retains_legacy_after_private_save", rolled_back == nil and rollback_error.kind == "storage"
        and controller.account.key == key and Files.exists(storage:path(rollback_key)) and Files.exists(rollback_legacy))
    controller:close(); ui:drain()
    controller = controller_with(storage); ui:drain()
    check("controller_reopen_loads_verified_private_session_without_network", controller.account.session_valid and controller.runner.submitted == 0)
    check("controller_reopen_keeps_database_and_cached_images_outside_credentials_root", controller.account.store.root == root .. "/accounts/" .. key
        and controller.account.pages:isComplete("10", "private-test"))
    controller:close(); ui:drain()
    return { assertions = checks, count = #checks, native_android = options.native_android == true,
        process_uid = process_uid, private_session_path = private_path,
        private_permissions = private_attributes.permissions, private_uid = private_attributes.uid,
        scope = "Synthetic sessions only; real Controller, SQLite, PageStore and credential filesystem operations" }
end
