"""Run synthetic ordinal transaction safety and affected state/protocol cases only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from run_nonspending_regression import SOURCES, digest


SPECS = ("nonspending_entry.lua", "ordinal_transaction_spec.lua", "state_machine.lua", "protocol_boundary.lua")
PHASES = ("unit", "seed", "recover", "owned", "inspect_pending", "late_accepted", "inspect_cleared", "seed_timeout", "recover_timeout")


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
    if (runtime / "git-rev").read_text().strip() != "v2026.07.1":
        raise RuntimeError("Use the pinned official runtime")
    os.umask(0o077)
    output.mkdir(mode=0o700)
    plugin, spec_root = output / "plugin", output / "spec"
    spec_root.mkdir()
    source_hashes, spec_hashes = {}, {}
    for name in SOURCES:
        original, target = source / name, plugin / name
        if original.is_symlink() or not original.is_file():
            raise RuntimeError("A production source is not a regular file")
        data = original.read_bytes()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        source_hashes[name] = hashlib.sha256(data).hexdigest()
    for name in SPECS:
        shutil.copyfile(Path(__file__).with_name(name), spec_root / name)
        spec_hashes[name] = digest(spec_root / name)
    env = {"PATH": "/usr/bin:/bin", "HOME": str(output / "home"), "LANG": "C.UTF-8", "TZ": "UTC",
           "KO_MULTIUSER": "1", "LUA_PATH": "./?.lua;./frontend/?.lua;./frontend/?/init.lua;./common/?.lua",
           "LUA_CPATH": "./?.so;./libs/?.so", "BILI_NONSPENDING_PARENT_NETNS": os.readlink("/proc/self/ns/net")}
    for kind in ("DATA", "CONFIG", "CACHE"):
        path = output / ("xdg-" + kind.lower())
        path.mkdir()
        env["XDG_" + kind + "_HOME"] = str(path)
    planned = [("state_machine", ""), ("protocol_boundary", "")]
    planned.extend(("ordinal_transaction_spec", phase) for phase in PHASES)
    results = []
    for script, phase in planned:
        name = script + ("-" + phase if phase else "")
        destination = output / (name + ".json")
        data = output / ("unit-data" if phase == "unit" else "durable-timeout" if phase.endswith("_timeout") else "durable-data")
        command = ["unshare", "-n", str(runtime / "luajit"), str(spec_root / "nonspending_entry.lua"),
                   str(plugin), str(spec_root), script, str(destination), str(data), phase, ""]
        completed = subprocess.run(command, cwd=runtime, env=env, capture_output=True, text=True, timeout=45)
        (output / (name + ".log")).write_text(completed.stdout + completed.stderr)
        evidence = json.loads(destination.read_text()) if destination.exists() else {}
        case_names = [line[5:] for line in completed.stdout.splitlines() if line.startswith("PASS ")]
        results.append({"name": name, "returncode": completed.returncode, "passed_cases": len(case_names),
                        "case_names": case_names, "evidence": evidence})
        print(name, completed.returncode, len(case_names), flush=True)
        if completed.returncode or not evidence.get("passed") or not case_names:
            print((completed.stdout + completed.stderr)[-7000:])
            break
    unchanged = all(digest(plugin / name) == value for name, value in source_hashes.items())
    passed = len(results) == len(planned) and unchanged and all(
        item["returncode"] == 0 and item["evidence"].get("passed") and item["passed_cases"] > 0 for item in results)
    report = {
        "passed": passed, "runtime_version": "v2026.07.1", "runtime_sha256": digest(runtime / "luajit"),
        "scope": "Real ordinal evidence derivation, synthetic transaction outcomes, same-comic conflict rules and SQLite process restarts",
        "source_sha256": source_hashes, "spec_sha256": spec_hashes, "source_unchanged": unchanged,
        "driver_sha256": digest(Path(__file__)),
        "driver_dependency_sha256": digest(Path(__file__).with_name("run_nonspending_regression.py")),
        "runs": results, "actual_http_permitted": False, "actual_purchases_permitted": False,
        "user_session_accessed": False, "server_confirmed_episode_ids_assumed": False,
        "limits": ["Synthetic catalogs and quote responses only", "No live charge or entitlement delivery",
                   "Range proof comes from production Range/Fetch/Quote; no fabricated approval Boolean"],
    }
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": passed, "runs": len(results), "report": str(output / "results.json")}))
    return int(not passed)


if __name__ == "__main__":
    raise SystemExit(main())
