"""Run synthetic ordinal-range contracts only through ssh test-env without networking."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


SOURCES = (
    "bilicomics/purchase/range.lua",
    "bilicomics/purchase/selection.lua",
    "bilicomics/purchase/quote_fetch.lua",
    "bilicomics/purchase/candidate.lua",
    "bilicomics/purchase/quote.lua",
    "bilicomics/purchase/value.lua",
)
RUNTIME_VERSION = "v2026.07.1"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def regular_file(path):
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("A required synthetic-test input is not a regular file")
    return path.read_bytes()


def main():
    if sys.platform != "linux" or not os.environ.get("SSH_CONNECTION"):
        raise RuntimeError("Run only through ssh test-env")
    parser = argparse.ArgumentParser()
    for name in ("runtime", "source", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    runtime, source, output = args.runtime.resolve(), args.source.resolve(), args.output.resolve()
    if not output.is_relative_to(Path("/tmp")) or output == Path("/tmp") or output.exists():
        raise RuntimeError("Use a fresh isolated output directory under /tmp")
    if regular_file(runtime / "git-rev").decode().strip() != RUNTIME_VERSION:
        raise RuntimeError("Use the pinned official KOReader runtime")
    source_bytes = {name: regular_file(source / name) for name in SOURCES}
    spec_path = Path(__file__).with_name("ordinal_range_spec.lua").resolve()
    spec_bytes = regular_file(spec_path)
    driver_path = Path(__file__).resolve()
    driver_bytes = regular_file(driver_path)
    os.umask(0o077)
    output.mkdir(mode=0o700)
    plugin, spec_root = output / "plugin", output / "spec"
    spec_root.mkdir(mode=0o700)
    source_hashes = {}
    for name, data in source_bytes.items():
        destination = plugin / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        source_hashes[name] = digest(data)
    copied_spec = spec_root / "ordinal_range_spec.lua"
    copied_spec.write_bytes(spec_bytes)
    env = {
        "PATH": "/usr/bin:/bin", "HOME": str(output / "home"), "LANG": "C.UTF-8", "TZ": "UTC",
        "KO_MULTIUSER": "1", "LUA_PATH": "./?.lua;./frontend/?.lua;./frontend/?/init.lua;./common/?.lua",
        "LUA_CPATH": "./?.so;./libs/?.so", "BILI_ORDINAL_PARENT_NETNS": os.readlink("/proc/self/ns/net"),
    }
    for kind in ("DATA", "CONFIG", "CACHE"):
        directory = output / ("xdg-" + kind.lower())
        directory.mkdir(mode=0o700)
        env["XDG_" + kind + "_HOME"] = str(directory)
    command = ["unshare", "-n", str(runtime / "luajit"), str(copied_spec),
               str(plugin), str(output / "checks.json")]
    completed = subprocess.run(command, cwd=runtime, env=env, capture_output=True, text=True, timeout=45)
    (output / "process.log").write_text(completed.stdout + completed.stderr)
    check_path = output / "checks.json"
    result = json.loads(check_path.read_text()) if check_path.exists() else {}
    unchanged = all(digest((plugin / name).read_bytes()) == checksum for name, checksum in source_hashes.items())
    unchanged = unchanged and digest(copied_spec.read_bytes()) == digest(spec_bytes)
    report = {
        "passed": completed.returncode == 0 and result.get("passed") is True and unchanged,
        "scope": "Synthetic Range, fake Fetch, and pure Quote; no real Client, Service, transport, or session modules",
        "runtime_version": RUNTIME_VERSION,
        "runtime_sha256": digest(regular_file(runtime / "luajit")),
        "source_sha256": source_hashes,
        "spec_sha256": digest(spec_bytes), "driver_sha256": digest(driver_bytes),
        "source_unchanged": unchanged, "returncode": completed.returncode,
        "network_namespace_isolated": result.get("network_namespace_isolated"),
        "forbidden_module_attempts": result.get("forbidden_module_attempts"),
        "buy_episode_calls": result.get("buy_episode_calls"),
        "user_session_accessed": False, "actual_http_permitted": False, "actual_purchases_permitted": False,
        "result": result,
        "limits": ["Synthetic contract checks only", "No real charging or entitlement-delivery verification",
                   "No guarantee of atomic server scope between quote and submit"],
    }
    report_path = output / "results.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "groups": len(result.get("groups", [])),
                      "assertions": result.get("assertions", 0), "report": str(report_path)}))
    if not report["passed"]:
        print((completed.stdout + completed.stderr)[-9000:])
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
