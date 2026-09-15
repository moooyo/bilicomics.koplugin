"""Run synthetic native ordinal-range UI checks in an isolated network namespace."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
from run_ui_sources import ui_source_names


TESTS = ("ordinal_range_spec.lua", "run_ordinal_range.py", "run_ui_sources.py")
SIZES = ((600, 800), (480, 640))
RESULT_NAME = "ordinal-range-result.json"
LOG_NAME = "ordinal-range.log"
VERIFICATION_NAME = "ordinal-range-verification.json"
REQUIRED_FLAGS = {
    "passed": True,
    "synthetic_only": True,
    "actual_purchase_executed": False,
    "network_namespace_isolated": True,
    "no_network_routes": True,
}


def hashes(root, names):
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}


def stop_process_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def read_result(path):
    try:
        result = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as error:
        return {}, "The native UI result could not be read: " + str(error)
    if not isinstance(result, dict):
        return {}, "The native UI result must be a JSON object."
    return result, None


def run_size(runtime, plugin, output, size):
    width, height = size
    output.mkdir()
    environment = os.environ.copy()
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "KO_HOME", "HOME"):
        directory = output / name.lower()
        directory.mkdir()
        environment[name] = str(directory)
    environment.update(
        KO_MULTIUSER="1", EMULATE_READER_W=str(width), EMULATE_READER_H=str(height),
        SDL_AUDIODRIVER="dummy", BILI_UI_PARENT_NETNS=os.readlink("/proc/self/ns/net"),
    )
    command = [
        "unshare", "-n", "--", "xvfb-run", "-a", str(runtime / "luajit"),
        str(plugin / "spec/ui/ordinal_range_spec.lua"), str(output), str(plugin),
    ]
    interrupted = False
    try:
        process = subprocess.Popen(
            command, cwd=runtime, env=environment, text=True, encoding="utf-8",
            errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
    except OSError as error:
        stdout, stderr, returncode = "", "The isolated native UI spec could not start: " + str(error) + "\n", 127
    else:
        try:
            stdout, stderr = process.communicate(timeout=60)
            returncode = process.returncode
        except subprocess.TimeoutExpired:
            stop_process_group(process)
            stdout, stderr = process.communicate()
            stderr += "\nThe isolated ordinal-range UI check exceeded its time limit.\n"
            returncode = 124
        except KeyboardInterrupt:
            stop_process_group(process)
            stdout, stderr = process.communicate()
            stderr += "\nThe isolated ordinal-range UI check was interrupted.\n"
            returncode, interrupted = 130, True
    log = stdout + stderr
    (output / LOG_NAME).write_text(log, encoding="utf-8")
    result, result_error = read_result(output / RESULT_NAME)
    missing_flags = [name for name, expected in REQUIRED_FLAGS.items() if result.get(name) is not expected]
    dimensions_match = result.get("width") == width and result.get("height") == height
    passed = returncode == 0 and not missing_flags and dimensions_match and not interrupted
    summary = {
        "width": width, "height": height, "returncode": returncode, "passed": bool(passed),
        "count": result.get("count", 0), "dimensions_match": dimensions_match,
        "result_file": f"{width}x{height}/{RESULT_NAME}",
        "log_file": f"{width}x{height}/{LOG_NAME}",
    }
    for name in REQUIRED_FLAGS:
        if name != "passed":
            summary[name] = result.get(name)
    if not passed:
        summary["error"] = result_error or result.get("error") or "The required isolated synthetic UI evidence is incomplete."
        if missing_flags:
            summary["invalid_evidence_flags"] = missing_flags
        print(log[-6000:])
    print(json.dumps(summary))
    return summary, interrupted


def write_verification(output, report):
    (output / VERIFICATION_NAME).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("plugin", type=Path)
    parser.add_argument("output", type=Path, help="A fresh output directory for both isolated screen sizes.")
    args = parser.parse_args()
    if os.name != "posix":
        parser.error("Run only through ssh test-env in the authorized Linux environment.")
    runtime, plugin, output = args.runtime.resolve(), args.plugin.resolve(), args.output.resolve()
    if not (runtime / "luajit").is_file():
        parser.error("The official KOReader LuaJIT runtime was not found.")
    if not (plugin / "spec/ui/ordinal_range_spec.lua").is_file():
        parser.error("The plugin snapshot must contain spec/ui/ordinal_range_spec.lua.")
    try:
        source_sha256 = hashes(plugin, ui_source_names(plugin))
        test_sha256 = hashes(plugin / "spec/ui", TESTS)
        output.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        parser.error("The source snapshot and fresh output directory are required: " + str(error))
    report = {
        "spec": "native-ordinal-range", "environment": "ssh test-env, unshare -n",
        "synthetic_only": True, "actual_purchase_executed": False,
        "source_sha256": source_sha256, "test_sha256": test_sha256,
        "source_unchanged": False, "runs": [], "interrupted": False, "passed": False,
    }
    write_verification(output, report)
    for size in SIZES:
        try:
            summary, interrupted = run_size(runtime, plugin, output / f"{size[0]}x{size[1]}", size)
        except OSError as error:
            summary, interrupted = {
                "width": size[0], "height": size[1], "returncode": None, "passed": False,
                "error": "The isolated run could not be completed: " + str(error),
            }, False
        report["runs"].append(summary)
        report["interrupted"] = interrupted
        write_verification(output, report)
        if interrupted:
            break
    try:
        report["source_sha256_after"] = hashes(plugin, ui_source_names(plugin))
        report["source_unchanged"] = report["source_sha256_after"] == source_sha256
    except OSError as error:
        report["source_hash_error"] = "The source files could not be hashed after the runs: " + str(error)
    report["passed"] = (
        not report["interrupted"] and report["source_unchanged"]
        and len(report["runs"]) == len(SIZES)
        and all(run["passed"] is True for run in report["runs"])
    )
    write_verification(output, report)
    print(json.dumps({"passed": report["passed"], "report": str(output / VERIFICATION_NAME)}))
    if report["interrupted"]:
        raise SystemExit(130)
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
