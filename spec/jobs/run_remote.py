"""Run native job verification only on the authorized Linux test-env host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import zlib


def png(path):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    pixels = b"".join(b"\0" + bytes([80, 80, 80]) * 40 for _ in range(80))
    data = b"\x89PNG\r\n\x1a\n"
    data += chunk(b"IHDR", struct.pack(">IIBBBBB", 40, 80, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
    path.write_bytes(data)


def compressed_png(path, width, height):
    """Stream valid grayscale rows into a tiny PNG without allocating a bitmap."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    compressor = zlib.compressobj(level=9)
    row = b"\0" * (width + 1)
    parts = []
    for _ in range(height):
        encoded = compressor.compress(row)
        if encoded:
            parts.append(encoded)
    parts.append(compressor.flush())
    data = b"\x89PNG\r\n\x1a\n"
    data += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
    data += chunk(b"IDAT", b"".join(parts)) + chunk(b"IEND", b"")
    path.write_bytes(data)
    return {"name": path.name, "width": width, "height": height, "pixels": width * height,
            "encoded_bytes": len(data), "generation": "streamed grayscale rows; no bitmap allocation or decoding"}


def main():
    if sys.platform != "linux":
        raise RuntimeError("Execute only through ssh test-env, never on the local workstation")
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--suites", default="runner,download,worker,extensions,budget,cover,parent-exit")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    fixtures = args.output / "fixtures"
    fixtures.mkdir()
    png(fixtures / "page-a.png")
    image_fixtures = [compressed_png(fixtures / "cover-6mp.png", 3000, 2000),
                      compressed_png(fixtures / "cover-4mp.png", 2000, 2000)]
    env = os.environ.copy()
    env["KO_MULTIUSER"] = "1"
    for kind in ("DATA", "CONFIG", "CACHE"):
        path = args.output / f"xdg-{kind.lower()}"
        path.mkdir()
        env[f"XDG_{kind}_HOME"] = str(path)
    summary = {"host": "test-env", "runtime": str(args.runtime),
               "runtime_version": (args.runtime / "git-rev").read_text().strip(),
               "scope": "Real POSIX subprocesses, pipes, SQLite and synthetic image files; injected download runner and protocol client; no account or real purchase",
               "source_sha256": {}, "test_source_sha256": {}, "image_fixtures": image_fixtures, "suites": [], "passed": True}
    for relative in ("bilicomics/jobs/runner.lua", "bilicomics/jobs/download_service.lua", "bilicomics/jobs/worker.lua",
                     "bilicomics/jobs/storage_budget.lua", "bilicomics/storage/store.lua", "bilicomics/storage/page_store.lua",
                     "bilicomics/protocol/client.lua", "bilicomics/protocol/platform.lua", "bilicomics/protocol/image.lua",
                     "bilicomics/image_policy.lua", "bilicomics/storage/image_header.lua", "_meta.lua"):
        summary["source_sha256"][relative] = hashlib.sha256((args.source / relative).read_bytes()).hexdigest()
    for path in sorted((args.source / "spec/jobs").iterdir()):
        if path.suffix in (".lua", ".py"):
            summary["test_source_sha256"][str(path.relative_to(args.source))] = hashlib.sha256(path.read_bytes()).hexdigest()
    filenames = {"runner": "runner_spec.lua", "download": "download_service_spec.lua", "worker": "worker_spec.lua",
                 "budget": "storage_budget_spec.lua", "extensions": "worker_extensions_spec.lua", "cover": "cover_policy_spec.lua"}
    for suite in args.suites.split(","):
        if suite == "parent-exit":
            from parent_exit_spec import run

            result = run(args.runtime, args.source, args.output, env)
            returncode = 0 if result["passed"] else 1
            summary["suites"].append({"suite": suite, "returncode": returncode, "result": result})
            summary["passed"] = summary["passed"] and result["passed"]
            print(suite, returncode, flush=True)
            if returncode:
                print(json.dumps(result, indent=2), flush=True)
            continue
        completed = subprocess.run([str(args.runtime / "luajit"), str(args.source / "spec/jobs" / filenames[suite]),
                                    str(args.source), str(args.output)], cwd=args.runtime, env=env,
                                   text=True, capture_output=True, timeout=35)
        log = completed.stdout + completed.stderr
        (args.output / f"{suite}.log").write_text(log)
        path = args.output / f"{suite}-result.json"
        item = {"suite": suite, "returncode": completed.returncode,
                "result": json.loads(path.read_text()) if path.exists() else None}
        if completed.returncode:
            item["error"] = log[-12000:]
            summary["passed"] = False
        summary["suites"].append(item)
        print(suite, completed.returncode, flush=True)
        if completed.returncode:
            print(log[-12000:], flush=True)
    (args.output / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
