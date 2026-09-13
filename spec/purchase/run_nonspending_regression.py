"""Run only synthetic purchase-state and fake-transport cases through ssh test-env."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


SOURCES = (
    "bilicomics/purchase/service.lua", "bilicomics/purchase/quote.lua",
    "bilicomics/purchase/selection.lua", "bilicomics/purchase/candidate.lua",
    "bilicomics/purchase/quote_fetch.lua", "bilicomics/purchase/value.lua", "bilicomics/purchase/range.lua",
    "bilicomics/protocol/client.lua", "bilicomics/protocol/crypto.lua",
    "bilicomics/protocol/errors.lua", "bilicomics/protocol/image.lua",
    "bilicomics/protocol/json.lua", "bilicomics/protocol/normalize.lua",
    "bilicomics/protocol/session.lua", "bilicomics/protocol/transport.lua",
    "bilicomics/storage/store.lua", "bilicomics/storage/codec.lua",
    "bilicomics/storage/files.lua", "bilicomics/storage/migrations.lua",
)
SPECS = ("nonspending_entry.lua", "state_machine.lua", "restart.lua", "protocol_boundary.lua")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


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
        original, destination = source / name, plugin / name
        if original.is_symlink() or not original.is_file():
            raise RuntimeError("A required production source is not a regular file")
        data = original.read_bytes()
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        source_hashes[name] = hashlib.sha256(data).hexdigest()
    for name in SPECS:
        original = Path(__file__).with_name(name)
        shutil.copyfile(original, spec_root / name)
        spec_hashes[name] = digest(spec_root / name)
    env = {"PATH": "/usr/bin:/bin", "HOME": str(output / "home"), "LANG": "C.UTF-8", "TZ": "UTC",
           "KO_MULTIUSER": "1", "LUA_PATH": "./?.lua;./frontend/?.lua;./frontend/?/init.lua;./common/?.lua",
           "LUA_CPATH": "./?.so;./libs/?.so", "BILI_NONSPENDING_PARENT_NETNS": os.readlink("/proc/self/ns/net")}
    for kind in ("DATA", "CONFIG", "CACHE"):
        directory = output / ("xdg-" + kind.lower())
        directory.mkdir()
        env["XDG_" + kind + "_HOME"] = str(directory)
    planned = [("state_machine", None, None), ("protocol_boundary", None, None)]
    for purpose in ("read", "download"):
        planned.extend(("restart", phase, purpose) for phase in ("prepare", "recover", "confirm", "inspect"))
    results = []
    for script, phase, purpose in planned:
        name = "-".join(value for value in (script, purpose, phase) if value)
        evidence_path = output / (name + ".json")
        data_root = output / ("durable-" + (purpose or "unused"))
        command = ["unshare", "-n", str(runtime / "luajit"), str(spec_root / "nonspending_entry.lua"),
                   str(plugin), str(spec_root), script, str(evidence_path), str(data_root), phase or "", purpose or ""]
        completed = subprocess.run(command, cwd=runtime, env=env, capture_output=True, text=True, timeout=45)
        (output / (name + ".log")).write_text(completed.stdout + completed.stderr)
        evidence = json.loads(evidence_path.read_text()) if evidence_path.exists() else {}
        case_names = [line[5:] for line in completed.stdout.splitlines() if line.startswith("PASS ")]
        result = {"name": name, "returncode": completed.returncode, "passed_cases": len(case_names),
                  "case_names": case_names, "evidence": evidence}
        results.append(result)
        print(name, completed.returncode, len(case_names), flush=True)
        if completed.returncode or not evidence.get("passed") or not case_names:
            print((completed.stdout + completed.stderr)[-7000:])
            break
    unchanged = all(digest(plugin / name) == checksum for name, checksum in source_hashes.items())
    passed = len(results) == len(planned) and unchanged and all(
        item["returncode"] == 0 and item["evidence"].get("passed") and item["passed_cases"] > 0 for item in results)
    report = {
        "passed": passed, "runtime_version": "v2026.07.1", "runtime_sha256": digest(runtime / "luajit"),
        "scope": "Single-episode synthetic state, real Client with strict memory-only BuyEpisode responses, and isolated SQLite restart",
        "source_sha256": source_hashes, "spec_sha256": spec_hashes, "driver_sha256": digest(Path(__file__)),
        "source_unchanged": unchanged, "runs": results, "user_session_accessed": False,
        "actual_http_permitted": False, "actual_purchases_permitted": False,
        "legacy_multi_episode_origin": "Directly seeded historical accepted journal; no new batch scope proof",
        "limits": ["No real charge or entitlement delivery", "No exact batch-membership proof",
                   "Original action persistence only; no Controller/UI continuation execution"],
    }
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": passed, "runs": len(results), "report": str(output / "results.json")}))
    return int(not passed)


if __name__ == "__main__":
    raise SystemExit(main())
