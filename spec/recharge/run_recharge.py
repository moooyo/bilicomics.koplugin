"""Run synthetic recharge integration and native UI checks only through ssh test-env."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys


def source_hashes(source):
    paths = sorted((source / "bilicomics").rglob("*.lua")) + sorted((source / "l10n").glob("*.lua"))
    paths += sorted((source / "spec/recharge").glob("*.lua")) + sorted((source / "spec/recharge").glob("*.py"))
    return {path.relative_to(source).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def run_case(runtime, source, output, suite, size):
    output.mkdir(mode=0o700)
    width, height = size
    environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LANG": "C.UTF-8", "TZ": "UTC",
        "KO_MULTIUSER": "1", "SDL_AUDIODRIVER": "dummy", "EMULATE_READER_W": str(width),
        "EMULATE_READER_H": str(height), "BILI_RECHARGE_PARENT_NETNS": os.readlink("/proc/self/ns/net")}
    for variable in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "KO_HOME", "HOME"):
        directory = output / variable.lower()
        directory.mkdir(mode=0o700)
        environment[variable] = str(directory)
    command = ["unshare", "-n", "--", "xvfb-run", "-a", str(runtime / "luajit"),
        str(source / "spec/recharge" / f"{suite}_spec.lua"), str(source), str(output)]
    process = subprocess.Popen(command, cwd=runtime, env=environment, text=True, encoding="utf-8",
        errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=180)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        timed_out = True
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
    (output / "suite.log").write_text(stdout + stderr, encoding="utf-8")
    result_path = output / f"{suite}-result.json"
    try:
        result = json.loads(result_path.read_text(encoding="utf-8")) if result_path.is_file() else {}
    except (OSError, ValueError) as error:
        result = {"error": f"The result could not be read: {error}"}
    required = {"passed": True, "synthetic_only": True, "actual_order_created": False,
        "actual_payment_made": False, "network_namespace_isolated": True, "no_network_routes": True}
    passed = process.returncode == 0 and not timed_out and all(result.get(key) is value for key, value in required.items())
    summary = {"suite": suite, "width": width, "height": height, "passed": passed,
        "returncode": process.returncode, "timed_out": timed_out, "count": result.get("count", 0),
        "screens": len(result.get("screens", [])), "result_file": str(result_path)}
    if not passed:
        summary["error"] = result.get("error") or (stdout + stderr)[-10000:]
    print(json.dumps(summary, ensure_ascii=False), flush=True)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("runtime", "source", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--suite", choices=("all", "controller", "ui"), default="all")
    args = parser.parse_args()
    if sys.platform != "linux" or not os.environ.get("SSH_CONNECTION"):
        parser.error("Run only through ssh test-env; local verification is not allowed")
    runtime, source, output = args.runtime.resolve(), args.source.resolve(), args.output.resolve()
    if not (runtime / "luajit").is_file():
        parser.error("The official KOReader LuaJIT runtime was not found")
    os.umask(0o077)
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    before = source_hashes(source)
    report = {"spec": "recharge-integration", "host": "test-env", "synthetic_only": True,
        "actual_order_created": False, "actual_payment_made": False,
        "source_sha256": before, "runs": [], "passed": False}
    try:
        if args.suite in ("all", "controller"):
            report["runs"].append(run_case(runtime, source, output / "controller", "controller", (600, 800)))
        if args.suite in ("all", "ui"):
            for size in ((600, 800), (480, 640)):
                report["runs"].append(run_case(runtime, source, output / f"ui-{size[0]}x{size[1]}", "ui", size))
    except (OSError, ValueError) as error:
        report["error"] = str(error)
    report["source_sha256_after"] = source_hashes(source)
    report["source_unchanged"] = before == report["source_sha256_after"]
    report["passed"] = bool(report["runs"]) and report["source_unchanged"] and all(run["passed"] for run in report["runs"])
    result_path = output / "recharge-report.json"
    result_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "report": str(result_path)}), flush=True)
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
