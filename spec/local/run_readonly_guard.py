"""Verify only the local acceptance guard on authorized test-env, without networking."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if sys.platform != "linux" or not os.environ.get("SSH_CONNECTION"):
        raise RuntimeError("Run only through ssh test-env")
    parser = argparse.ArgumentParser()
    for name in ("source", "runtime", "work"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    args.source, args.runtime, args.work = (path.resolve() for path in (args.source, args.runtime, args.work))
    if args.work.exists():
        raise RuntimeError("A fresh isolated output directory is required")
    if (args.runtime / "git-rev").read_text().strip() != "v2026.07.1":
        raise RuntimeError("Use the official v2026.07.1 runtime")
    args.work.mkdir(parents=True, mode=0o700)
    stage = args.work / "source"
    shutil.copytree(args.source / "bilicomics", stage / "bilicomics")
    guard, spec = stage / "readonly_guard.lua", stage / "readonly_guard_spec.lua"
    shutil.copyfile(args.source / "spec/local/readonly_guard.lua", guard)
    shutil.copyfile(args.source / "spec/local/readonly_guard_spec.lua", spec)
    hashes = {str(path.relative_to(stage)): digest(path) for path in sorted(stage.rglob("*.lua"))}
    profile, home = args.work / "profile", args.work / "home"
    profile.mkdir(mode=0o700); home.mkdir(mode=0o700)
    env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "KO_HOME": str(home), "LANG": "C.UTF-8",
           "LUA_PATH": "./?.lua;./frontend/?.lua;./frontend/?/init.lua;./common/?.lua", "LUA_CPATH": "./?.so;./libs/?.so"}
    result_path = args.work / "suite-results.json"
    command = ["unshare", "-n", "--", str(args.runtime / "luajit"), str(spec), str(stage), str(guard), str(profile), str(result_path)]
    timed_out = False
    with (args.work / "runtime.log").open("wb") as log:
        process = subprocess.Popen(command, cwd=args.runtime, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            returncode = process.wait(timeout=40)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
            returncode = 124
    result = json.loads(result_path.read_text()) if result_path.exists() else {"passed": False}
    unchanged = all(digest(stage / name) == value for name, value in hashes.items())
    report = {"passed": returncode == 0 and result.get("passed") is True and unchanged,
              "returncode": returncode, "timed_out": timed_out, "source_unchanged": unchanged,
              "guard_sha256": hashes["readonly_guard.lua"], "spec_sha256": hashes["readonly_guard_spec.lua"],
              "source_sha256": hashes, "launcher_sha256": digest(Path(__file__)), "suite": result,
              "runtime_version": "v2026.07.1", "runtime_luajit_sha256": digest(args.runtime / "luajit"),
              "network_namespace_isolated": True, "strict_fake_originals": True,
              "network_requests": 0, "real_session_used": False, "actual_purchase_executed": False,
              "local_wsl_or_interactive_profile_accessed": False,
              "scope": "Acceptance guard admission/denial only; real Client request construction and strict fake Transport/Runner originals; no service or UI acceptance"}
    (args.work / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "counts": result.get("counts"),
                      "failures": [item for item in result.get("tests", []) if item.get("passed") is not True]}))
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
