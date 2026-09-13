"""Run cross-layer native integration only on the authorized remote host."""
import argparse
import hashlib
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
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    args = parser.parse_args()
    if args.work.exists() and any(args.work.iterdir()):
        raise RuntimeError("Use a fresh empty work directory so prior results and image gates cannot be reused")
    package = args.work / "bundle/bilicomics.koplugin"
    package.mkdir(parents=True, exist_ok=True)
    for name in ("bilicomics", "patches", "l10n"):
        source = args.source / name
        if source.exists():
            shutil.copytree(source, package / name, dirs_exist_ok=True)
    for name in ("main.lua", "_meta.lua"):
        shutil.copyfile(args.source / name, package / name)
    tests = args.work / "spec/integration"
    tests.mkdir(parents=True)
    for name in ("online_plugin.lua", "offline_plugin.lua", "run_integration.py"):
        shutil.copyfile(args.source / "spec/integration" / name, tests / name)
    sources = {}
    for path in sorted(package.rglob("*")):
        if path.is_file():
            sources[str(path.relative_to(package))] = hashlib.sha256(path.read_bytes()).hexdigest()
    report = {"runtime": str(args.runtime), "version": (args.runtime / "git-rev").read_text().strip(),
              "source_sha256": sources, "runs": [],
              "test_sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(tests.iterdir())},
              "scope": "Actual plugin, native reader, fork/IPC and storage; synthetic protocol data, no Bilibili requests"}
    for name in ("online", "offline-reopen", "offline-smoke"):
        group = "online" if name != "offline-smoke" else "offline-smoke"
        output, home = args.work / group, args.work / group / "data"
        output.mkdir(exist_ok=True)
        home.mkdir(exist_ok=True)
        setting = home / "settings.reader.lua"
        if not setting.exists():
            setting.write_text("return {quickstart_shown_version=9999999999,"
                               f"extra_plugin_paths={{{json.dumps(str(package.parent))}}},color_rendering=false}}")
        env = os.environ.copy()
        env.update(KO_HOME=str(home), EMULATE_READER_W="600", EMULATE_READER_H="800", SDL_AUDIODRIVER="dummy")
        script = tests / ("offline_plugin.lua" if name == "offline-smoke" else "online_plugin.lua")
        result_file = output / ("smoke-results.json" if name == "offline-smoke" else
                                ("online-results.json" if name == "online" else "offline-results.json"))
        command = ["xvfb-run", "-a", str(args.runtime / "luajit"), str(script), str(package), str(args.fixture)]
        command += [str(result_file)] if name == "offline-smoke" else [str(output), "online" if name == "online" else "offline"]
        process = subprocess.run(command, cwd=args.runtime, env=env, text=True, capture_output=True, timeout=40)
        (output / f"{name}.log").write_text(process.stdout + process.stderr)
        result = json.loads(result_file.read_text()) if result_file.exists() else {}
        report["runs"].append({"name": name, "returncode": process.returncode, "result": result})
        print(name, process.returncode, len(result.get("assertions", [])), flush=True)
        if process.returncode or not result.get("passed"):
            print((process.stdout + process.stderr)[-8000:])
            break
    report["passed"] = len(report["runs"]) == 3 and all(
        item["returncode"] == 0 and item["result"].get("passed") for item in report["runs"])
    (args.work / "integration-results.json").write_text(json.dumps(report, indent=2) + "\n")
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
