"""Run only source_refresh_spec.lua on authorized remote test-env."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import zlib


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png(path):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\0" + bytes([70, 70, 70]) * 40 for _ in range(80))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 40, 80, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def main():
    if sys.platform != "linux":
        raise RuntimeError("Run only on authorized remote test-env")
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    if args.work.exists():
        raise RuntimeError("A fresh isolated work directory is required")
    if (args.runtime / "git-rev").read_text().strip() != "v2026.07.1":
        raise RuntimeError("The expected official runtime is unavailable")
    args.work.mkdir(mode=0o700, parents=True)
    stage = args.work / "source"
    modules = stage / "bilicomics/storage"
    modules.mkdir(parents=True)
    for path in sorted((args.source / "bilicomics/storage").glob("*.lua")):
        shutil.copyfile(path, modules / path.name)
    spec = stage / "source_refresh_spec.lua"
    shutil.copyfile(args.source / "spec/storage/source_refresh_spec.lua", spec)
    sources = {str(path.relative_to(stage)): digest(path) for path in sorted(stage.rglob("*.lua"))}
    fixture = args.work / "fixture.png"
    png(fixture)
    output = args.work / "data"
    output.mkdir(mode=0o700)
    env = os.environ.copy()
    env["KO_HOME"] = str(args.work / "koreader")
    Path(env["KO_HOME"]).mkdir(mode=0o700)
    env["SDL_AUDIODRIVER"] = "dummy"
    result_file = args.work / "suite-results.json"
    command = ["unshare", "-n", "--", str(args.runtime / "luajit"), str(spec),
               str(stage), str(output), str(fixture), str(result_file)]
    completed = subprocess.run(command, cwd=args.runtime, env=env, text=True,
                               capture_output=True, timeout=90)
    (args.work / "suite.log").write_text(completed.stdout + completed.stderr)
    result = json.loads(result_file.read_text()) if result_file.exists() else {"passed": False}
    unchanged = all(digest(stage / name) == value for name, value in sources.items())
    report = {"passed": completed.returncode == 0 and result.get("passed") is True and unchanged,
              "returncode": completed.returncode, "source_unchanged": unchanged,
              "runtime_version": "v2026.07.1", "source_sha256": sources,
              "runtime_sha256": {name: digest(args.runtime / name) for name in ("luajit", "libs/libsqlite3.so.0")},
              "launcher_sha256": digest(Path(__file__)), "suite": result,
              "scope": "Real SQLite source-refresh proof storage only; synthetic PNG; isolated network namespace",
              "purchase_scenarios_executed": False}
    (args.work / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "returncode": completed.returncode,
                      "checks": len(result.get("assertions", []))}))
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
