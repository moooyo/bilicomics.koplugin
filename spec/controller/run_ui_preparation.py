"""Verify UI preparation data using actual controllers in isolated native profiles."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import zlib


def isolation_prefix():
    for prefix in (["unshare", "--net", "--"],
                   ["unshare", "--user", "--map-root-user", "--net", "--"]):
        if subprocess.run([*prefix, "true"], capture_output=True, timeout=5).returncode == 0:
            return prefix
    raise RuntimeError("The native acceptance host cannot isolate external network access.")


def fixture(path):
    def chunk(kind, value):
        return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value) & 0xFFFFFFFF)
    header = chunk(b"IHDR", struct.pack(">IIBBBBB", 20, 40, 8, 2, 0, 0, 0))
    pixels = (b"\0" + bytes([64, 64, 64]) * 20) * 40
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + header + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("runtime", "plugin", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--suites", nargs="+", default=["ui_preparation", "download_estimate", "bookshelf_finishing", "cover_thumbnail"])
    args = parser.parse_args()
    args.output.mkdir(parents=True, mode=0o700, exist_ok=False)
    prefix = isolation_prefix()
    sources = ["bilicomics/controller.lua", "bilicomics/bookshelf_state.lua", "bilicomics/download_estimate.lua",
               "spec/controller/ui_preparation_spec.lua", "spec/controller/download_estimate_spec.lua",
               "spec/controller/bookshelf_finishing_spec.lua", "spec/controller/cover_thumbnail_spec.lua",
               "spec/controller/run_ui_preparation.py"]
    hashes = {name: hashlib.sha256((args.plugin / name).read_bytes()).hexdigest()
              for name in sources if (args.plugin / name).exists()}
    results = []
    for suite in args.suites:
        output = args.output / suite
        output.mkdir(mode=0o700)
        fixture(output / "fixture.png")
        env = os.environ.copy()
        for key in ("HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "KO_HOME"):
            directory = output / key.lower()
            directory.mkdir(mode=0o700)
            env[key] = str(directory)
        for key in ("LUA_PATH", "LUA_CPATH", "LD_PRELOAD"):
            env.pop(key, None)
        env.update(KO_MULTIUSER="1", EMULATE_READER_W="600", EMULATE_READER_H="800", SDL_AUDIODRIVER="dummy")
        command = [*prefix, "xvfb-run", "-a", str(args.runtime / "luajit"),
                   str(args.plugin / "spec/controller" / f"{suite}_spec.lua"), str(args.plugin), str(output)]
        completed = subprocess.run(command, cwd=args.runtime, env=env, capture_output=True,
                                   text=True, encoding="utf-8", errors="replace", timeout=90)
        (output / "native.log").write_text(completed.stdout + completed.stderr, encoding="utf-8")
        reports = list(output.glob("*-result.json"))
        report = json.loads(reports[0].read_text()) if len(reports) == 1 else {}
        passed = completed.returncode == 0 and report.get("passed") is True
        results.append({"suite": suite, "returncode": completed.returncode, "passed": passed,
                        "result": report, "output": str(output)})
        print(json.dumps({"suite": suite, "passed": passed, "returncode": completed.returncode}), flush=True)
        if not passed:
            print((completed.stdout + completed.stderr)[-12000:], flush=True)
    after_hashes = {name: hashlib.sha256((args.plugin / name).read_bytes()).hexdigest() for name in hashes}
    summary = {"passed": all(result["passed"] for result in results) and hashes == after_hashes, "network_isolated": True,
               "runtime": (args.runtime / "git-rev").read_text().strip(), "execution_host": os.uname().nodename,
               "execution_kernel": os.uname().release, "source_sha256": hashes,
               "source_after_sha256": after_hashes, "source_unchanged": hashes == after_hashes, "suites": results}
    (args.output / "ui-preparation-verification.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
