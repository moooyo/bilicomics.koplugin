"""Verify purchase dispatch expiry only through ssh test-env with networking isolated."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    for name in ("runtime", "source", "output"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    runtime, source, output = (getattr(args, name).resolve() for name in ("runtime", "source", "output"))
    if sys.platform != "linux" or not os.environ.get("SSH_CONNECTION"):
        raise RuntimeError("Run only through ssh test-env")
    if not source.is_relative_to(Path("/tmp")) or not output.is_relative_to(Path("/tmp")) or output == Path("/tmp"):
        raise RuntimeError("Use isolated source and output directories under /tmp")
    if (runtime / "git-rev").read_text().strip() != "v2026.07.1":
        raise RuntimeError("Use the pinned official KOReader runtime")
    os.umask(0o077)
    output.mkdir(mode=0o700, exist_ok=False)
    paths = sorted((source / "bilicomics").rglob("*.lua")) + sorted((source / "l10n").rglob("*.lua"))
    paths += [source / "spec/controller/purchase_dispatch_spec.lua", source / "spec/controller/run_purchase_dispatch.py"]
    hashes = {str(path.relative_to(source)): digest(path) for path in paths}
    environment = {"PATH": "/usr/bin:/bin", "HOME": str(output / "home"), "LANG": "C.UTF-8", "TZ": "UTC",
                   "KO_MULTIUSER": "1", "SDL_AUDIODRIVER": "dummy", "EMULATE_READER_W": "600", "EMULATE_READER_H": "800",
                   "BILI_DISPATCH_PARENT_NETNS": os.readlink("/proc/self/ns/net")}
    for variable in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        directory = output / variable.lower()
        directory.mkdir()
        environment[variable] = str(directory)
    command = ["unshare", "--net", "xvfb-run", "-a", str(runtime / "luajit"),
               str(source / "spec/controller/purchase_dispatch_spec.lua"), str(source), str(output)]
    process = subprocess.Popen(command, cwd=runtime, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding="utf-8", errors="replace", start_new_session=True)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=60)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
    (output / "suite.log").write_text(stdout + stderr, encoding="utf-8")
    result_file = output / "purchase-dispatch-result.json"
    result = json.loads(result_file.read_text()) if result_file.exists() else None
    unchanged = all(digest(source / name) == expected for name, expected in hashes.items())
    passed = process.returncode == 0 and not timed_out and unchanged and bool(result and result.get("passed"))
    report = {"passed": passed, "host": "test-env", "runtime_version": "v2026.07.1", "runtime_sha256": digest(runtime / "luajit"),
              "source_sha256": hashes, "source_unchanged": unchanged, "returncode": process.returncode, "timed_out": timed_out,
              "completed_at": datetime.now(timezone.utc).isoformat(), "result": result,
              "error": (stdout + stderr)[-8000:] if not passed else None,
              "limits": ["Controlled asynchronous workers with production Controller, SessionRunner and SQLite",
                         "No real account, network request or payment"]}
    (output / "purchase-dispatch-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": passed, "report": str(output / "purchase-dispatch-report.json"),
                      "tests": len(result["tests"]) if result else 0, "assertions": result.get("assertions") if result else 0,
                      "error": report["error"]}, indent=2))
    return int(not passed)


if __name__ == "__main__":
    raise SystemExit(main())
