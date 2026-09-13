"""Validate a private session or select one bounded free chapter on a selected host.

The source and driver hashes bind public booleans and counts to the exact code.
Credentials, chapter identities, source paths and raw logs stay in private files.
The selector reads at most the first favorite (or first history item when empty),
its catalog, and its first explicitly free chapter index. It never fetches images.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from run_live_reading import code_manifest, digest, execution_context, manifest_digest, mkdir_private, protected_inputs, regular_path, write_json


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--session", type=Path, required=True)
    parser.add_argument("--select", action="store_true")
    parser.add_argument("--execution-host", choices=("test-env", "local-wsl"), default="test-env")
    args = parser.parse_args()
    report = {"passed": False, "checks": {}, "counts": {}}
    trusted_work = None
    try:
        report["execution"] = execution_context(args.execution_host)
        args.runtime = args.runtime.resolve(strict=True)
        args.source = args.source.resolve(strict=True)
        assert not args.work.exists() and not args.work.is_symlink()
        args.work = args.work.resolve()
        args.session = regular_path(args.session)
        assert not any(left.is_relative_to(right) for left, right in (
            (args.work, args.source), (args.source, args.work),
            (args.work, args.runtime), (args.runtime, args.work)))
        assert not args.session.is_relative_to(args.work)
        assert not args.session.is_relative_to(args.source) and not args.session.is_relative_to(args.runtime)
        assert args.session.stat().st_mode & 0o077 == 0
        protected_inputs.add((args.session.stat().st_dev, args.session.stat().st_ino))
        assert (args.runtime / "git-rev").read_text().strip() == "v2026.07.1"
        source_hashes = code_manifest(args.source)
        driver = Path(__file__).resolve().with_suffix(".lua")
        test_hashes = {path.name: digest(path) for path in (Path(__file__).resolve(), driver,
            Path(__file__).resolve().with_name("run_live_reading.py"))}
        mkdir_private(args.work)
        trusted_work = args.work
        report["code_sha256"] = {"production": source_hashes,
            "production_manifest": manifest_digest(source_hashes), "tests": test_hashes,
            "runtime_luajit": digest(args.runtime / "luajit")}
        log = args.work / "private-process.log"
        with log.open("xb") as output:
            process = subprocess.run([str(args.runtime / "luajit"), str(driver), str(args.source),
                str(args.work), str(args.session), "select" if args.select else "validate"],
                cwd=args.runtime, env={**os.environ, "LD_LIBRARY_PATH": str(args.runtime / "libs")},
                stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT, timeout=180)
        observations = json.loads((args.work / "preflight-observations.json").read_text())
        assert set(observations) == {"passed", "checks", "counts"}
        assert type(observations["passed"]) is bool
        assert all(type(key) is str and type(value) is bool for key, value in observations["checks"].items())
        assert all(type(key) is str and type(value) is int and 0 <= value <= 64
            for key, value in observations["counts"].items())
        report.update(observations)
        report["checks"]["source_unchanged"] = code_manifest(args.source) == source_hashes
        report["checks"]["tests_unchanged"] = all(digest(driver.parent / name) == value
            for name, value in test_hashes.items())
        report["passed"] = process.returncode == 0 and report["passed"] and report["checks"]["source_unchanged"] \
            and report["checks"]["tests_unchanged"]
    except (Exception, KeyboardInterrupt):
        report["passed"] = False
        report["checks"]["preflight_completed"] = False
    finally:
        if trusted_work:
            write_json(trusted_work / "preflight-results.json", report)
        print(json.dumps({"passed": report["passed"],
            "session_valid": report["checks"].get("session_valid", False),
            "selection_created": report["checks"].get("selection_created", False)}))
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
