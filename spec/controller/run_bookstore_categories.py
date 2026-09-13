"""Run category controller checks only in an isolated Linux test environment."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import zlib


def main():
    if sys.platform != "linux":
        raise RuntimeError("Run verification only through ssh test-env")
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.runtime, args.source, args.output = args.runtime.resolve(), args.source.resolve(), args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    raw = (b"\0" + bytes([64, 64, 64]) * 20) * 40
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 20, 40, 8, 2, 0, 0, 0))
    (args.output / "fixture.png").write_bytes(png + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    env = os.environ.copy()
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        directory = args.output / key.lower()
        directory.mkdir()
        env[key] = str(directory)
    env.update({"KO_MULTIUSER": "1", "EMULATE_READER_W": "600", "EMULATE_READER_H": "800", "SDL_AUDIODRIVER": "dummy"})
    source_files = ("bilicomics/controller.lua", "bilicomics/bookstore.lua", "bilicomics/bookstore_categories.lua",
                    "bilicomics/cover_source.lua", "bilicomics/catalog/init.lua", "bilicomics/storage/store.lua",
                    "spec/controller/bookstore_categories_spec.lua", "spec/controller/run_bookstore_categories.py")
    source_hashes = {name: hashlib.sha256((args.source / name).read_bytes()).hexdigest() for name in source_files}
    command = ["unshare", "--user", "--map-root-user", "--net", "xvfb-run", "-a", str(args.runtime / "luajit"),
               str(args.source / "spec/controller/bookstore_categories_spec.lua"), str(args.source), str(args.output)]
    result = subprocess.run(command, cwd=args.runtime, env=env, text=True, capture_output=True, timeout=55)
    (args.output / "bookstore-categories-controller.log").write_text(result.stdout + result.stderr)
    after_hashes = {name: hashlib.sha256((args.source / name).read_bytes()).hexdigest() for name in source_files}
    summary = {"host": "test-env", "runtime": (args.runtime / "git-rev").read_text().strip(),
               "network_isolated": True, "source_sha256": source_hashes, "source_after_sha256": after_hashes,
               "source_unchanged": source_hashes == after_hashes, "returncode": result.returncode}
    report = args.output / "bookstore-categories-controller-result.json"
    if report.exists():
        summary["result"] = json.loads(report.read_text())
    summary["passed"] = result.returncode == 0 and summary.get("result", {}).get("passed") is True and summary["source_unchanged"]
    (args.output / "bookstore-categories-controller-verification.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(result.stdout + result.stderr)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
