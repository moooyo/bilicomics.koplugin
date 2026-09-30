-- Only session-file parsing, native selection and controlled session validation are exercised.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local plugin, output = assert(arg[1]), assert(arg[2])
package.path = plugin .. "/?.lua;" .. plugin .. "/?/init.lua;" .. package.path
require("gettext").current_lang = "zh_CN"
local Controller = require("bilicomics/controller")
local Session = require("bilicomics/protocol/session")
local SessionInput = require("bilicomics/ui/session_input")
local Screens = require("bilicomics/ui/screens")
local UIManager = require("ui/uimanager")
local FileChooser = require("ui/widget/filechooser")
local Files = require("bilicomics/storage/files")
local json = require("rapidjson")
local _ = require("bilicomics/ui/i18n")
local fixtures = output .. "/fixtures"
G_reader_settings:saveSetting("home_dir", fixtures)
G_reader_settings:saveSetting("collate", "strcoll")
local results = { assertions = {}, screens = {}, scope = "Synthetic files; native widgets; real Controller/Session/SQLite; controlled validation only" }
local function check(name, value)
    results.assertions[#results.assertions + 1] = { name = name, passed = not not value }
    assert(value, name)
end
local queue, native_next_tick = {}, UIManager.nextTick
UIManager.nextTick = function(_manager, callback, ...)
    local arguments, length = { ... }, select("#", ...)
    queue[#queue + 1] = function() return callback(unpack(arguments, 1, length)) end
end
local function flush()
    local remaining = 1000
    while #queue > 0 do remaining = remaining - 1; assert(remaining > 0); table.remove(queue, 1)() end
end
local requests, runners = {}, {}
local function runnerFactory()
    local runner = { pending = {} }
    function runner:submit(request, options, callback)
        assert(request.kind == "client" and request.method == "validateSession", "Only session validation is allowed")
        local task = { request = request, callback = callback, runner = self }
        requests[#requests + 1] = task; self.pending[#requests] = task
        return tostring(#requests)
    end
    function runner:close() self.closed = true; self.pending = {} end
    function runner:cancel() end
    runners[#runners + 1] = runner
    return runner
end
local host = { folder_shortcuts = {
    hasFolderShortcut = function() return false end, getShortcutFullName = function() return nil end,
} }
local app = Controller.new{ root = output .. "/data", ui = host, ui_manager = UIManager, runner_factory = runnerFactory }
for _index, method in ipairs({ "getWallet", "refreshWallet", "quotePurchase", "purchase", "reconcilePurchase" }) do
    app[method] = function() error("Unrelated account operations are forbidden in this check") end
end
local screens = Screens.new{ controller = app }
app:setScreens(screens)
screens:showLibrary(); flush()
check("session_import_default_destination_is_bookshelf", screens.route == "favorites")
local function dialogButton(message)
    local dialog = assert(screens.dialog, "Expected an import dialog")
    for _index, row in ipairs(dialog.buttons or {}) do
        for _index, button in ipairs(row) do if button.text == _(message) then return button end end
    end
    error("Expected import control was not found: " .. message)
end
local function dialogPress(message)
    local button = dialogButton(message)
    assert(button.enabled ~= false and button.callback, "Expected an enabled import control: " .. message)
    button.callback()
end
local function capture(name)
    UIManager:forceRePaint()
    local dialog = assert(screens.dialog)
    local size = dialog.movable and dialog.movable:getSize() or dialog:getSize()
    check(name .. "_fits_screen", size.w <= Device.screen:getWidth() and size.h <= Device.screen:getHeight())
    Device.screen.bb:writePNG(output .. "/" .. name .. ".png")
    results.screens[#results.screens + 1] = name .. ".png"
end
local function selectFile(name)
    screens:_importSessionFile()
    local picker = assert(screens.dialog)
    picker:onMenuSelect({ path = fixtures .. "/" .. name, is_file = true })
    flush()
end
local function validated(task, identity)
    local session = Session.new(task.request.session)
    assert(session:withIdentity({ id = identity or "424242", name = "Synthetic file account" }))
    task.callback({ session = session:serialize() }); flush()
end

for _index, name in ipairs({ "session.txt", "session-bom.TXT", "session.json", "session.cookies" }) do
    local content = assert(SessionInput.read(fixtures .. "/" .. name))
    local session = assert(Session.parse(content))
    check("supported_format_" .. name, session.cookies.DedeUserID == "424242")
end
check("exactly_128_kib_can_be_read", #assert(SessionInput.read(fixtures .. "/boundary.txt")) == 131072)
for name, code in pairs({ ["too-large.txt"] = "size", ["directory.txt"] = "regular_file", ["linked.txt"] = "regular_file",
    ["pipe.txt"] = "regular_file", ["missing.txt"] = "regular_file", ["empty.txt"] = "format", ["binary.txt"] = "format", ["unsupported.log"] = "format" }) do
    local content, err = SessionInput.read(fixtures .. "/" .. name)
    check("rejects_" .. name, content == nil and err.code == code and err.message == nil and err.path == nil)
end
check("path_with_nul_is_rejected", SessionInput.read(fixtures .. "/session.txt\0") == nil)
screens:_otherSignInMethods()
check("other_sign_in_methods_expose_both_import_sources", dialogButton("Paste web session") and dialogButton("Import from file"))
dialogPress("Paste web session")
check("paste_input_remains_masked", screens.dialog.text_type == "password")
dialogPress("Import from file")
local picker = screens.dialog
check("file_entry_opens_native_file_chooser", picker.onMenuSelect == FileChooser.onMenuSelect and picker.path == fixtures)
local original_filter = FileChooser.show_filter.status
FileChooser.show_filter.status = { complete = true }
check("file_types_ignore_book_status_filters", picker:show_file("session.txt") and picker:show_file("session-bom.TXT") and not picker:show_file("unsupported.log"))
FileChooser.show_filter.status = original_filter
capture("session-file-picker")
picker:onClose()
local before = #requests
picker:onFileSelect({ path = fixtures .. "/session.txt" }); flush()
check("cancel_and_obsolete_picker_never_start_validation", screens.session_input == nil and #requests == before)
screens:_importSessionFile(); picker = screens.dialog
picker:onMenuSelect({ path = fixtures .. "/directory.txt", is_file = false })
check("selecting_directory_only_navigates", picker.path == fixtures .. "/directory.txt" and #requests == before)
UIManager:close(picker)
check("direct_native_close_retires_picker", screens.session_input == nil and screens.dialog == nil)
screens:_importSessionFile(); picker = screens.dialog
picker:onMenuSelect({ path = fixtures .. "/session.txt", is_file = true })
screens:_closeDialog(); flush()
check("closing_before_deferred_read_cancels_import", #requests == before)

for index, name in ipairs({ "session.txt", "session-bom.TXT", "session.json", "session.cookies" }) do
    selectFile(name)
    local task = requests[#requests]
    check("file_selection_dispatches_validation_" .. index, #requests == before + index and task.request.session.cookies.DedeUserID == "424242")
    if index == 1 then capture("session-file-validating") end
    validated(task)
    check("file_import_saves_verified_account_" .. index, app.account.key == "bili_424242"
        and Files.exists(output .. "/data/accounts/bili_424242/session.dat")
        and screens.dialog.title:find(_("Session imported"), 1, true))
end
capture("session-file-imported")
check("success_feedback_stays_above_controller_refresh", UIManager:getTopmostVisibleWidget() == screens.dialog)
check("success_feedback_contains_no_secret_or_input_path", not screens.dialog.title:find("synthetic-session-file", 1, true)
    and not screens.dialog.title:find(fixtures, 1, true))
before = #requests
selectFile("too-large.txt")
local function dialogText()
    local values, seen = {}, {}
    local function collect(widget)
        if type(widget) ~= "table" or seen[widget] then return end
        seen[widget] = true
        if type(widget.text) == "string" then values[#values + 1] = widget.text end
        if type(widget.title) == "string" then values[#values + 1] = widget.title end
        for _, child in ipairs(widget) do collect(child) end
        for _, field in ipairs({ "content", "body", "footer", "buttons" }) do collect(widget[field]) end
    end
    collect(screens.dialog)
    return table.concat(values, "\n")
end
check("oversize_selection_never_reaches_controller", #requests == before and dialogText():find("128 KiB", 1, true))
capture("session-file-error")
selectFile("session.txt")
requests[#requests].callback(nil, { kind = "invalid_session", message = "SESSDATA=synthetic-session-file " .. fixtures }); flush()
check("validation_error_does_not_echo_cookie_or_path", not dialogText():find("synthetic-session-file", 1, true)
    and not dialogText():find(fixtures, 1, true))
check("failure_feedback_stays_above_controller_refresh", UIManager:getTopmostVisibleWidget() == screens.dialog)
selectFile("session.txt")
local closed_task = requests[#requests]
local background_import = screens.session_import
dialogPress("Continue in background")
check("background_validation_keeps_its_pending_state", screens.dialog == nil and screens.session_import == background_import
    and background_import.status == "validating")
validated(closed_task)
check("background_completion_does_not_reopen_a_modal_or_change_route", screens.dialog == nil and screens.route == "favorites"
    and screens.session_import == background_import and background_import.status == "complete")
screens:_sessionImportResult(background_import)
check("background_result_can_be_reviewed_explicitly", screens.dialog.title:find(_("Session imported"), 1, true)
    and dialogButton("Open bookshelf") and not screens.dialog.title:find("synthetic-session-file", 1, true)
    and not screens.dialog.title:find(fixtures, 1, true))
dialogPress("Close")
check("closing_reviewed_result_retires_its_state", screens.dialog == nil and screens.session_import == nil)

screens:_importSessionFile(); picker = screens.dialog
picker:onMenuSelect({ path = fixtures .. "/session.txt", is_file = true })
before = #requests
app:importSession("SESSDATA=synthetic-other-file; DedeUserID=424243", function() end)
validated(requests[#requests], "424243")
check("account_change_cancels_a_deferred_selected_file", #requests == before + 1 and app.account.key == "bili_424243")
screens:_closeDialog()
selectFile("session.txt")
local old_task = requests[#requests]
app:importSession("SESSDATA=synthetic-other-file; DedeUserID=424243", function() end)
validated(requests[#requests], "424243")
validated(old_task)
check("old_validation_callback_cannot_replace_new_account", app.account.key == "bili_424243")
screens:close(); app:close(); flush()
UIManager.nextTick = native_next_tick
check("only_session_validation_was_dispatched", #requests > 0)
results.count, results.validation_requests = #results.assertions, #requests
Files.write(output .. "/session-import-result.json", json.encode(results, { pretty = true }))
print(json.encode(results, { pretty = true }))
