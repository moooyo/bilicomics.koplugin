"""Run bounded real-child concurrency acceptance only on authorized test-env."""
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
import time
import zlib


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hashes(root):
    paths = sorted((root / "bilicomics").rglob("*.lua"))
    paths += sorted(path for path in (root / "spec/jobs").rglob("*") if path.suffix in (".lua", ".py"))
    return {str(path.relative_to(root)): digest(path) for path in paths}


def png(path):
    def chunk(kind, value):
        return (struct.pack(">I", len(value)) + kind + value
                + struct.pack(">I", zlib.crc32(kind + value) & 0xffffffff))
    rows = b"".join(b"\0" + bytes([65]) * 40 for _ in range(80))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 40, 80, 8, 0, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def main():
    if sys.platform != "linux":
        raise RuntimeError("Execute only through ssh test-env, never on the local workstation")
    parser = argparse.ArgumentParser()
    for name in ("source", "runtime", "work"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--suites", default="runner,service")
    args = parser.parse_args()
    args.source, args.runtime, args.work = (path.resolve() for path in (args.source, args.runtime, args.work))
    suites = args.suites.split(",")
    if not suites or any(suite not in ("runner", "service") for suite in suites):
        raise ValueError("Select runner, service, or both")
    if args.work.exists():
        raise RuntimeError("Use a new isolated concurrency output directory")
    runtime_version = (args.runtime / "git-rev").read_text().strip()
    if runtime_version != "v2026.07.1":
        raise RuntimeError("Use the official v2026.07.1 runtime")
    source_before = hashes(args.source)
    args.work.mkdir(parents=True, mode=0o700)
    stage = args.work / "source"
    shutil.copytree(args.source / "bilicomics", stage / "bilicomics")
    shutil.copytree(args.source / "spec/jobs", stage / "spec/jobs")
    staged_before = hashes(stage)
    fixture = args.work / "concurrency-fixture.png"
    png(fixture)
    results = []
    for suite in suites:
        output, home = args.work / ("concurrency-" + suite), args.work / ("concurrency-" + suite + "-home")
        output.mkdir(); home.mkdir()
        env = os.environ.copy()
        env.update(KO_HOME=str(home), SDL_AUDIODRIVER="dummy", EMULATE_READER_W="600", EMULATE_READER_H="800")
        result_path = output / ("concurrency-" + suite + "-results.json")
        command = ["unshare", "-n", "--", "xvfb-run", "-a", str(args.runtime / "luajit"),
                   str(stage / "spec/jobs/concurrency_spec.lua"), str(stage), str(output), str(fixture), str(result_path), suite]
        timed_out, started_at = False, time.monotonic()
        with (output / ("concurrency-" + suite + ".log")).open("wb") as log:
            process = subprocess.Popen(command, cwd=args.runtime, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                returncode = process.wait(timeout=55)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
                returncode = 124
        result = json.loads(result_path.read_text()) if result_path.exists() else {"passed": False, "error": "No result produced"}
        passed = returncode == 0 and result.get("passed") is True
        results.append({"suite": suite, "passed": passed, "returncode": returncode, "timed_out": timed_out,
                        "duration_seconds": round(time.monotonic() - started_at, 3), "timeout_seconds": 55,
                        "real_runner_fork": True, "real_sqlite_and_page_store": suite == "service", "result": result})
        print(json.dumps({"suite": suite, "passed": passed, "duration_seconds": results[-1]["duration_seconds"],
                          "counts": result.get("counts"), "failures": [item for item in result.get("tests", [])
                          if item.get("passed") is not True]}), flush=True)
    source_after, staged_after = hashes(args.source), hashes(stage)
    unchanged = source_before == source_after and staged_before == staged_after
    report = {"passed": unchanged and all(item["passed"] for item in results), "host": "test-env",
              "source_unchanged": unchanged, "source_sha256_before": source_before, "source_sha256_after": source_after,
              "staged_sha256_before": staged_before, "staged_sha256_after": staged_after,
              "runtime_version": runtime_version, "runtime_sha256": {name: digest(args.runtime / name)
                  for name in ("luajit", "libs/libsqlite3.so.0")}, "launcher_sha256": digest(Path(__file__)),
              "fixture_sha256": digest(fixture), "suites": results, "network_namespace_isolated": True,
              "network_requests": 0, "real_session_used": False, "purchase_tests_executed": False,
              "quote_tests_executed": False, "wallet_tests_executed": False,
              "scope": "Real POSIX child overlap and lifecycle, live concurrency, aggregate storage reservations, real SQLite/PageStore commit integrity and owner sharing; synthetic images and accounts only"}
    (args.work / "concurrency-results.json").write_text(json.dumps(report, indent=2) + "\n")
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
