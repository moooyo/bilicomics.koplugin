"""Run the two bounded, non-monetary connectivity suites on authorized test-env."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import zlib


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png(path):
    def chunk(kind, value):
        return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value) & 0xffffffff)
    rows = b"".join(b"\0" + bytes([65]) * 40 for _ in range(80))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 40, 80, 8, 0, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def main():
    if sys.platform != "linux":
        raise RuntimeError("Run only on authorized remote test-env")
    parser = argparse.ArgumentParser()
    for name in ("source", "runtime", "work"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    args.source, args.runtime, args.work = (path.resolve() for path in (args.source, args.runtime, args.work))
    if args.work.exists():
        raise RuntimeError("Use a new isolated directory")
    if (args.runtime / "git-rev").read_text().strip() != "v2026.07.1":
        raise RuntimeError("Use the official v2026.07.1 runtime")
    args.work.mkdir(parents=True, mode=0o700)
    stage = args.work / "source"
    shutil.copytree(args.source / "bilicomics", stage / "bilicomics")
    tests = stage / "spec/jobs"
    tests.mkdir(parents=True)
    for name in ("download_connectivity_spec.lua", "download_connectivity_runner_spec.lua"):
        shutil.copyfile(args.source / "spec/jobs" / name, tests / name)
    sources = {str(path.relative_to(stage)): digest(path) for path in sorted((stage / "bilicomics").rglob("*.lua"))}
    test_hashes = {str(path.relative_to(stage)): digest(path) for path in sorted(tests.iterdir())}
    fixture = args.work / "fixture.png"
    png(fixture)
    suites = []
    for suite in ("service", "runner"):
        output, home = args.work / suite, args.work / (suite + "-home")
        output.mkdir(); home.mkdir()
        env = os.environ.copy()
        env.update(KO_HOME=str(home), SDL_AUDIODRIVER="dummy", EMULATE_READER_W="600", EMULATE_READER_H="800")
        script = tests / ("download_connectivity_spec.lua" if suite == "service" else "download_connectivity_runner_spec.lua")
        result_path = output / "results.json"
        command = ["unshare", "-n", "--", "xvfb-run", "-a", str(args.runtime / "luajit"), str(script), str(stage), str(output)]
        if suite == "service":
            command.append(str(fixture))
        command.append(str(result_path))
        timed_out = False
        with (output / "runtime.log").open("wb") as log:
            process = subprocess.Popen(command, cwd=args.runtime, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                returncode = process.wait(timeout=90)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
                returncode = 124
        result = json.loads(result_path.read_text()) if result_path.exists() else {"passed": False, "error": "No result produced"}
        passed = returncode == 0 and result.get("passed") is True
        suites.append({"suite": suite, "passed": passed, "returncode": returncode, "timed_out": timed_out,
                       "real_sqlite": suite == "service", "real_controller": suite == "service",
                       "real_runner_fork": suite == "runner", "controlled_async_runner": suite == "service",
                       "synthetic_worker": suite == "runner", "result": result})
        print(json.dumps({"suite": suite, "passed": passed, "counts": result.get("counts"),
                          "failures": [item for item in result.get("tests", []) if item.get("passed") is not True]}), flush=True)
    unchanged = all(digest(stage / name) == value for name, value in {**sources, **test_hashes}.items())
    report = {"passed": unchanged and all(item["passed"] for item in suites), "source_unchanged": unchanged,
              "source_sha256": sources, "test_source_sha256": test_hashes, "suites": suites,
              "runtime_version": "v2026.07.1", "runtime_sha256": {name: digest(args.runtime / name)
                  for name in ("luajit", "libs/libsqlite3.so.0")}, "launcher_sha256": digest(Path(__file__)),
              "network_namespace_isolated": True, "network_requests": 0, "real_session_used": False,
              "purchase_tests_executed": False, "quote_tests_executed": False, "wallet_tests_executed": False,
              "scope": "Focused connectivity gates and lifecycle; real SQLite/Controller with controlled runner, separate real fork Runner with synthetic worker; not live-service acceptance"}
    (args.work / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
