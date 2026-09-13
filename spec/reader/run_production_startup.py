"""Exercise the actual plugin bootstrap, Runtime, Store, and official reader.lua."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    if sys.platform != "linux":
        raise RuntimeError("Run only on the authorized remote verification host")
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    args = parser.parse_args()
    root = args.output
    home = root / "data"
    plugin = home / "plugins/bilicomics.koplugin"
    patches = home / "patches"
    patches.mkdir(parents=True, exist_ok=True)
    plugin.mkdir(parents=True, exist_ok=True)
    for directory in ("bilicomics", "patches"):
        shutil.copytree(args.plugin / directory, plugin / directory, dirs_exist_ok=True)
    for filename in ("main.lua", "_meta.lua"):
        shutil.copyfile(args.plugin / filename, plugin / filename)
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
    shutil.copyfile(args.plugin / "spec/reader/startup_probe.lua", patches / "2-00-observe.lua")
    process = subprocess.run(["xvfb-run", "-a", str(args.runtime / "luajit"), "reader.lua"],
                             cwd=args.runtime, env=env, text=True, capture_output=True, timeout=20)
    (root / "startup.log").write_text(process.stdout + process.stderr)
    result_file = root / "startup-results.json"
    report = json.loads(result_file.read_text()) if result_file.exists() else {}
    passed = bool(process.returncode == 0 and report.get("reader_provider") == "bilicomics_document"
                  and report.get("first_show", {}).get("provider_available")
                  and not report.get("first_show", {}).get("plugins_loaded")
                  and not report.get("first_show", {}).get("runtime_initialized")
                  and report.get("actual_plugin_present") and report.get("reader_integration_attached")
                  and abs(report.get("visible_pixel", 0) - 40) <= 2
                  and not report.get("filemanager_opened"))
    result = {"passed": passed, "returncode": process.returncode, "scope": "Actual plugin, cached synthetic free chapter, official reader.lua",
              "runtime_version": (args.runtime / "git-rev").read_text().strip(), "report": report}
    (root / "production-startup-results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    if not passed:
        print((process.stdout + process.stderr)[-7000:])
    return int(not passed)


if __name__ == "__main__":
    raise SystemExit(main())
