"""Run only the explicit version replacement storage suite on authorized test-env."""
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
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    rows = b"".join(b"\0" + bytes([75]) * 40 for _ in range(80))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 40, 80, 8, 0, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def main():
    if sys.platform != "linux":
        raise RuntimeError("Run only on authorized remote test-env")
    parser = argparse.ArgumentParser()
    for name in ("runtime", "source", "work"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    args.runtime, args.source, args.work = (path.resolve() for path in (args.runtime, args.source, args.work))
    if args.work.exists():
        raise RuntimeError("A fresh isolated work directory is required")
    if (args.runtime / "git-rev").read_text().strip() != "v2026.07.1":
        raise RuntimeError("The official v2026.07.1 runtime is required")
    args.work.mkdir(mode=0o700, parents=True)
    stage = args.work / "source"
    shutil.copytree(args.source / "bilicomics", stage / "bilicomics")
    script = stage / "version_replacement_spec.lua"
    shutil.copyfile(args.source / "spec/storage/version_replacement_spec.lua", script)
    hashes = {str(path.relative_to(stage)): digest(path) for path in sorted(stage.rglob("*.lua"))}
    fixture = args.work / "fixture.png"
    png(fixture)
    output, home = args.work / "data", args.work / "koreader"
    output.mkdir(); home.mkdir()
    env = os.environ.copy()
    env.update(KO_HOME=str(home), SDL_AUDIODRIVER="dummy")
    command = ["unshare", "-n", "--", str(args.runtime / "luajit"), str(script), str(stage), str(output),
               str(fixture), str(args.work / "suite-results.json")]
    timed_out = False
    with (args.work / "runtime.log").open("wb") as log:
        process = subprocess.Popen(command, cwd=args.runtime, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            returncode = process.wait(timeout=90)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill(); process.wait(timeout=5)
            returncode = 124
    result_path = args.work / "suite-results.json"
    result = json.loads(result_path.read_text()) if result_path.exists() else {"passed": False}
    unchanged = all(digest(stage / name) == value for name, value in hashes.items())
    assertions = result.get("assertions", [])
    passed = (returncode == 0 and result.get("passed") is True and unchanged and bool(assertions)
              and all(item.get("passed") is True for item in assertions))
    report = {"passed": passed, "returncode": returncode, "timed_out": timed_out, "source_unchanged": unchanged,
              "runtime_version": "v2026.07.1", "source_sha256": hashes, "suite": result,
              "runtime_sha256": {name: digest(args.runtime / name) for name in ("luajit", "libs/libsqlite3.so.0")},
              "launcher_sha256": digest(Path(__file__)), "network_namespace_isolated": True,
              "purchase_scenarios_executed": False,
              "scope": "Real SQLite/PageStore/Catalog and native DocSettings, synthetic PNG, explicit independent version publication only"}
    (args.work / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": passed, "returncode": returncode, "counts": result.get("counts"),
                      "failed_cases": [item for item in result.get("cases", []) if item.get("passed") is not True]}))
    return int(not passed)


if __name__ == "__main__":
    raise SystemExit(main())
