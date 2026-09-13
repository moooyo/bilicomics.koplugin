"""Run the isolated real-Client identity spec with fake quote JSON only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


FILES = (
    "bilicomics/protocol/client.lua", "bilicomics/protocol/crypto.lua", "bilicomics/protocol/errors.lua",
    "bilicomics/protocol/image.lua", "bilicomics/protocol/json.lua", "bilicomics/protocol/normalize.lua",
    "bilicomics/protocol/session.lua", "bilicomics/purchase/quote_fetch.lua",
    "bilicomics/purchase/selection.lua", "bilicomics/purchase/value.lua",
)


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
        raise RuntimeError("Use a new isolated output directory under /tmp")
    if (runtime / "git-rev").read_text().strip() != "v2026.07.1":
        raise RuntimeError("The pinned official runtime is required")
    os.umask(0o077)
    output.mkdir(mode=0o700)
    plugin = output / "plugin"
    source_hashes = {}
    for name in FILES:
        original, target = source / name, plugin / name
        if original.is_symlink() or not original.is_file():
            raise RuntimeError("Expected a regular production source file")
        data = original.read_bytes()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        source_hashes[name] = hashlib.sha256(data).hexdigest()
    spec = Path(__file__).with_name("purchase_info_identity_spec.lua").resolve()
    env = {"PATH": "/usr/bin:/bin", "HOME": str(output / "home"), "LANG": "C.UTF-8", "TZ": "UTC",
           "KO_MULTIUSER": "1", "LUA_PATH": "./?.lua;./frontend/?.lua;./frontend/?/init.lua;./common/?.lua",
           "LUA_CPATH": "./libs/?.so", "BILI_IDENTITY_PARENT_NETNS": os.readlink("/proc/self/ns/net")}
    for kind in ("DATA", "CONFIG", "CACHE"):
        directory = output / ("xdg-" + kind.lower())
        directory.mkdir(mode=0o700)
        env["XDG_" + kind + "_HOME"] = str(directory)
    completed = subprocess.run(["unshare", "-n", str(runtime / "luajit"), str(spec), str(plugin), str(output / "checks.json")],
                               cwd=runtime, env=env, capture_output=True, text=True, timeout=30)
    (output / "process.log").write_text(completed.stdout + completed.stderr)
    checks = json.loads((output / "checks.json").read_text()) if (output / "checks.json").exists() else {}
    unchanged = all(digest(plugin / name) == value for name, value in source_hashes.items())
    report = {"passed": completed.returncode == 0 and checks.get("passed") is True and unchanged,
              "scope": "Real Client.purchaseInfo identity validation; exact fake quote JSON and memory-only catalog; no actual purchase",
              "runtime_version": "v2026.07.1", "runtime_sha256": digest(runtime / "luajit"),
              "source_sha256": source_hashes, "spec_sha256": digest(spec), "driver_sha256": digest(Path(__file__)),
              "source_unchanged": unchanged, "returncode": completed.returncode, "result": checks,
              "user_session_accessed": False, "profile_accessed": False}
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "groups": len(checks.get("groups", [])),
                      "assertions": checks.get("assertions", 0), "report": str(output / "results.json")}))
    if not report["passed"]:
        print((completed.stdout + completed.stderr)[-5000:])
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
