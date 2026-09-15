"""Run only synthetic native quote-selection UI checks in an isolated network namespace."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
from run_ui_sources import ui_source_names


SOURCES = ("bilicomics/ui/model.lua", "bilicomics/ui/screens.lua", "l10n/bilicomics_zh_CN.lua")
SIZES = ((600, 800), (480, 640))


def hashes(plugin):
    return {name: hashlib.sha256((plugin / name).read_bytes()).hexdigest()
        for name in sorted(set(SOURCES).union(ui_source_names(plugin)))}


def run_size(runtime, plugin, output, size):
    width, height = size
    output.mkdir()
    environment = os.environ.copy()
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "KO_HOME", "HOME"):
        directory = output / name.lower()
        directory.mkdir()
        environment[name] = str(directory)
    environment.update(KO_MULTIUSER="1", EMULATE_READER_W=str(width), EMULATE_READER_H=str(height),
        SDL_AUDIODRIVER="dummy", BILI_UI_PARENT_NETNS=os.readlink("/proc/self/ns/net"))
    command = ["unshare", "-n", "--", "xvfb-run", "-a", str(runtime / "luajit"),
        str(plugin / "spec/ui/quote_selection_spec.lua"), str(output), str(plugin)]
    process = subprocess.Popen(command, cwd=runtime, env=environment, text=True, encoding="utf-8",
        errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=60)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
        stderr += "\nThe isolated quote UI check was interrupted or exceeded its time limit.\n"
    (output / "quote-selection.log").write_text(stdout + stderr, encoding="utf-8")
    result_path = output / "quote-selection-result.json"
    result = json.loads(result_path.read_text()) if result_path.is_file() else {}
    passed = process.returncode == 0 and result.get("passed") is True
    passed = passed and result.get("synthetic_only") is True and result.get("actual_purchase_executed") is False
    passed = passed and result.get("network_namespace_isolated") is True and result.get("no_network_routes") is True
    summary = {"width": width, "height": height, "returncode": process.returncode, "passed": passed,
        "count": result.get("count", 0), "result_file": f"{width}x{height}/quote-selection-result.json"}
    if not passed:
        summary["error"] = result.get("error", "The required isolated synthetic UI evidence is incomplete")
        print((stdout + stderr)[-6000:])
    print(json.dumps(summary))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("plugin", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if os.name != "posix":
        parser.error("Run only through ssh test-env in the authorized Linux environment")
    runtime, plugin, output = args.runtime.resolve(), args.plugin.resolve(), args.output.resolve()
    if not (runtime / "luajit").is_file():
        parser.error("The official KOReader LuaJIT runtime was not found")
    output.mkdir(parents=True, exist_ok=False)
    report = {"spec": "native-quote-selection", "environment": "ssh test-env, unshare -n",
        "synthetic_only": True, "actual_purchase_executed": False, "source_sha256": hashes(plugin),
        "source_unchanged": False, "runs": [], "passed": False}
    report["test_sha256"] = {name: hashlib.sha256((plugin / "spec/ui" / name).read_bytes()).hexdigest()
        for name in ("quote_selection_spec.lua", "run_quote_selection.py", "run_ui_sources.py")}
    try:
        for size in SIZES:
            report["runs"].append(run_size(runtime, plugin, output / f"{size[0]}x{size[1]}", size))
        report["source_sha256_after"] = hashes(plugin)
        report["source_unchanged"] = report["source_sha256_after"] == report["source_sha256"]
        report["passed"] = report["source_unchanged"] and all(run["passed"] for run in report["runs"])
    except (OSError, ValueError) as error:
        report["error"] = str(error)
    (output / "quote-selection-verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "report": str(output / "quote-selection-verification.json")}))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
