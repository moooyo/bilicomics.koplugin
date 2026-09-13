"""Verify actual main hooks through real reader close and cold FM startup."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


OBSERVER = r'''
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local json = require("rapidjson")
local root = assert(os.getenv("BILICOMICS_STARTUP_PROBE_ROOT"))
local phase = assert(os.getenv("BILICOMICS_FALLBACK_PHASE"))
local Probe = WidgetContainer:extend{}
local result = { phase = phase, observations = {} }
local function record(name, value)
    result.observations[name] = not not value
    assert(value, name)
end
local function write(name, value)
    local file = assert(io.open(root .. "/" .. name, "wb"))
    file:write(json.encode(value)); file:close()
end
local function read(name)
    local file = assert(io.open(root .. "/" .. name, "rb"))
    local value = json.decode(file:read("*a")); file:close(); return value
end
local function run(operation)
    local ok, err = xpcall(operation, debug.traceback)
    if not ok then result.failure = err; write(phase .. "-results.json", result); UIManager:quit(1) end
end
function Probe:init()
    if phase == "recover" and not self.ui.document and not _G.fallback_reopen_started then
        _G.fallback_reopen_started = true
        UIManager:scheduleIn(0.2, function() run(function()
            record("patches_disabled", require("userpatch").arePatchesDisabled())
            record("cold_start_is_filemanager", require("apps/filemanager/filemanager").instance ~= nil
                and require("apps/reader/readerui").instance == nil)
            record("startup_preference_preserved", G_reader_settings:readSetting("start_with") == "last")
            record("unsafe_lastfile_absent", G_reader_settings:readSetting("lastfile") == nil)
            local app = assert(require("bilicomics/runtime").peek())
            local anchor = app.account.store:getAnchor("episode", "r1")
            record("anchor_survives_cold_start", anchor and anchor.y > 0)
            record("native_history_preserved", #require("readhistory").hist > 0)
            app:readEpisode("comic", "episode", function(_, err)
                if err then run(function() error(err.kind .. ": " .. err.message) end) end
            end)
        end) end)
    end
end
function Probe:onReaderReady()
    if not self.ui.document or self.ui.document.provider ~= "bilicomics_document" then return end
    UIManager:scheduleIn(0.3, function() run(function()
        local reader = self.ui
        local app = assert(require("bilicomics/runtime").peek())
        local anchor_module = require("bilicomics/reader/anchors")
        if phase == "read" then
            reader.zooming:onSetZoomMode("pagewidth")
            reader.view:onSetScrollMode(true)
            reader.paging:onGotoViewRel(1)
            reader.bilicomics_integration:saveAnchor()
            local anchor = assert(app.account.store:getAnchor("episode", "r1"))
            record("position_advanced", anchor.y > 0)
            write("expected-anchor.json", anchor)
            require("userpatch").togglePatchesDisabled()
            -- Exercise the actual main.lua event handler; the observer supplies no fallback hook.
            UIManager:broadcastEvent(require("ui/event"):new("FlushSettings"))
            record("actual_flush_hook_cleared_target", G_reader_settings:readSetting("lastfile") == nil)
        else
            local before, current = read("expected-anchor.json"), anchor_module.capture(reader)
            record("offline_reopen_restores_position", current and current.page_id == before.page_id
                and math.abs(current.y - before.y) < 0.005)
            record("actual_readerready_hook_cleared_target", G_reader_settings:readSetting("lastfile") == nil)
        end
        reader:onClose()
        record("normal_close_does_not_restore_unsafe_lastfile", G_reader_settings:readSetting("lastfile") == nil)
        record("start_with_last_stays_unchanged", G_reader_settings:readSetting("start_with") == "last")
        record("document_and_anchor_preserved", app.account.store:getAnchor("episode", "r1") ~= nil
            and app.account.pages:isComplete("episode", "r1"))
        result.success = true
        write(phase .. "-results.json", result)
        require("bilicomics/runtime").close()
        UIManager:quit()
    end) end)
end
return Probe
'''


def main():
    if sys.platform != "linux":
        raise RuntimeError("Run only on the authorized remote verification host")
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    args = parser.parse_args()
    root, home = args.output, args.output / "data"
    plugin = home / "plugins/bilicomics.koplugin"
    plugin.mkdir(parents=True, exist_ok=True)
    for directory in ("bilicomics", "patches"):
        shutil.copytree(args.plugin / directory, plugin / directory, dirs_exist_ok=True)
    for filename in ("main.lua", "_meta.lua"):
        shutil.copyfile(args.plugin / filename, plugin / filename)
    observer = home / "plugins/fallback-probe.koplugin"
    observer.mkdir(exist_ok=True)
    (observer / "main.lua").write_text(OBSERVER)
    (observer / "_meta.lua").write_text("return {fullname='Fallback observer',description='Isolated close/startup contract probe'}")
    disabled = ",".join(f"[{json.dumps(path.name[:-9])}]=true" for path in (args.runtime / "plugins").glob("*.koplugin"))
    (home / "settings.reader.lua").write_text("return {start_with='last',quickstart_shown_version=9999999999,"
        f"color_rendering=false,plugins_disabled={{{disabled}}},"
        f"extra_plugin_paths={{{json.dumps(str(home / 'plugins'))}}},home_dir={json.dumps(str(root))}}}")
    env = os.environ.copy()
    env.update(KO_HOME=str(home), BILICOMICS_STARTUP_PROBE_ROOT=str(root),
               EMULATE_READER_W="600", EMULATE_READER_H="800", SDL_AUDIODRIVER="dummy")
    seed = subprocess.run(["xvfb-run", "-a", str(args.runtime / "luajit"), str(args.plugin / "spec/reader/seed_startup.lua"),
                           str(plugin), str(args.fixture)], cwd=args.runtime, env=env, text=True, capture_output=True, timeout=20)
    (root / "seed.log").write_text(seed.stdout + seed.stderr)
    if seed.returncode:
        print(seed.stdout + seed.stderr)
        return 1
    results = []
    for phase in ("read", "recover"):
        env["BILICOMICS_FALLBACK_PHASE"] = phase
        process = subprocess.run(["xvfb-run", "-a", str(args.runtime / "luajit"), "reader.lua"],
                                 cwd=args.runtime, env=env, text=True, capture_output=True, timeout=20)
        (root / f"{phase}.log").write_text(process.stdout + process.stderr)
        path = root / f"{phase}-results.json"
        result = json.loads(path.read_text()) if path.exists() else {}
        results.append({"phase": phase, "returncode": process.returncode, "result": result})
        print(json.dumps(results[-1]), flush=True)
        if process.returncode or not result.get("success"):
            print((process.stdout + process.stderr)[-7000:])
            break
    report = {"entrypoint": "official reader.lua in two separate processes",
              "runtime_version": (args.runtime / "git-rev").read_text().strip(),
              "scope": "Actual main ReaderReady/FlushSettings hooks and local account, native disabled-patch marker; no substituted fallback hooks",
              "runs": results}
    (root / "fallback-results.json").write_text(json.dumps(report, indent=2) + "\n")
    return int(len(results) != 2 or not all(item["returncode"] == 0 and item["result"].get("success") for item in results))


if __name__ == "__main__":
    raise SystemExit(main())
