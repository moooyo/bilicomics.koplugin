"""Bind isolated live-harness scope checks to the exact remote source snapshot."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if sys.platform != "linux" or not os.environ.get("SSH_CONNECTION"):
        raise RuntimeError("Run only through ssh test-env")
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("runtime", "source", "guard", "work", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    source, runtime, guard = (path.resolve(strict=True) for path in (args.source, args.runtime, args.guard))
    work = args.work.resolve()
    if work.exists() or work.is_relative_to(source) or work.is_relative_to(runtime):
        raise RuntimeError("Use a fresh work directory outside source and runtime")
    os.umask(0o077)
    work.mkdir(mode=0o700, parents=True)
    files = [source / "main.lua", source / "_meta.lua"]
    for name in ("bilicomics", "l10n", "patches"):
        files.extend(path for path in (source / name).rglob("*") if path.is_file())
    production = {path.relative_to(source).as_posix(): digest(path) for path in sorted(files)}
    harness_names = ("live_acceptance_scope.lua", "live_acceptance_scope_spec.lua", "run_live_acceptance_scope.py")
    harness = {name: digest(source / "spec/integration" / name) for name in harness_names}
    guard_hash = digest(guard)
    result_path = work / "scope-results.json"
    command = ["unshare", "--net", str(runtime / "luajit"),
               str(source / "spec/integration/live_acceptance_scope_spec.lua"), str(source), str(result_path), str(guard)]
    with (work / "process.log").open("wb") as log:
        result = subprocess.run(command, cwd=runtime, env={**os.environ, "LD_LIBRARY_PATH": str(runtime / "libs")},
                                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=60)
    report = json.loads(result_path.read_text())
    unchanged = all(digest(source / path) == value for path, value in production.items())
    unchanged = unchanged and all(digest(source / "spec/integration" / name) == value for name, value in harness.items())
    unchanged = unchanged and digest(guard) == guard_hash
    report.update(execution_host="test-env", network_namespace_isolated=True, source_unchanged=unchanged,
                  production_sha256=production, harness_sha256=harness, guard_sha256=guard_hash,
                  runtime_version=(runtime / "git-rev").read_text().strip())
    report["passed"] = report.get("passed") is True and result.returncode == 0 and unchanged
    args.output.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "assertions": report["assertions"], "real_network_requests": 0}))
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
