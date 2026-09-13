"""Exercise quote selection with fake responses only on remote test-env."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import zipfile


TARGETS = (
    "bilicomics/purchase/selection.lua", "bilicomics/purchase/quote_fetch.lua",
    "bilicomics/purchase/candidate.lua", "bilicomics/purchase/quote.lua",
    "bilicomics/purchase/value.lua", "bilicomics/ui/model.lua", "bilicomics/ui/i18n.lua",
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    if sys.platform != "linux" or not os.environ.get("SSH_CONNECTION"):
        raise RuntimeError("Run only through ssh test-env")
    parser = argparse.ArgumentParser()
    for name in ("runtime", "archive", "manifest", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    runtime, output = args.runtime.resolve(), args.output.resolve()
    if not output.is_relative_to(Path("/tmp")) or output == Path("/tmp") or output.exists():
        raise RuntimeError("Use a fresh private output directory under /tmp")
    if (runtime / "git-rev").read_text().strip() != "v2026.07.1":
        raise RuntimeError("Use the pinned official runtime")
    manifest = json.loads(args.manifest.read_text())
    archive_bytes = args.archive.read_bytes()
    if digest(archive_bytes) != manifest["sha256"]:
        raise RuntimeError("The preview archive does not match its manifest")
    os.umask(0o077)
    output.mkdir(mode=0o700)
    plugin = output / "plugin"
    plugin.mkdir(mode=0o700)
    source_hashes = {}
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        entries = manifest["files"]
        expected = {"bilicomics.koplugin/" + item["path"] for item in entries}
        if len(expected) != len(entries) or len(archive.namelist()) != len(expected) or set(archive.namelist()) != expected:
            raise RuntimeError("The archive member set differs from its manifest")
        for item in entries:
            relative = Path(item["path"])
            if relative.is_absolute() or ".." in relative.parts or "\\" in item["path"]:
                raise RuntimeError("Unsafe archive member")
            data = archive.read("bilicomics.koplugin/" + item["path"])
            if digest(data) != item["sha256"] or len(data) != item["bytes"]:
                raise RuntimeError("An archive member differs from its manifest")
            target = plugin / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            source_hashes[item["path"]] = digest(data)
    for target in TARGETS:
        if target not in source_hashes:
            raise RuntimeError("A focused production module is absent")
    spec = Path(__file__).with_name("quote_selection_spec.lua").resolve()
    env = {"PATH": "/usr/bin:/bin", "HOME": str(output / "home"), "LANG": "C.UTF-8", "TZ": "UTC",
           "KO_MULTIUSER": "1", "LUA_PATH": "./?.lua;./frontend/?.lua;./frontend/?/init.lua;./common/?.lua",
           "LUA_CPATH": "./libs/?.so", "BILI_QUOTE_PARENT_NETNS": os.readlink("/proc/self/ns/net")}
    for kind in ("DATA", "CONFIG", "CACHE"):
        directory = output / ("xdg-" + kind.lower())
        directory.mkdir(mode=0o700)
        env["XDG_" + kind + "_HOME"] = str(directory)
    command = ["unshare", "-n", str(runtime / "luajit"), str(spec), str(plugin), str(output / "checks.json")]
    completed = subprocess.run(command, cwd=runtime, env=env, capture_output=True, text=True, timeout=45)
    (output / "process.log").write_text(completed.stdout + completed.stderr)
    result = json.loads((output / "checks.json").read_text()) if (output / "checks.json").exists() else {}
    unchanged = all(digest((plugin / path).read_bytes()) == checksum for path, checksum in source_hashes.items())
    report = {
        "passed": completed.returncode == 0 and result.get("passed") is True and unchanged,
        "scope": "Fake Client responses and pure quote construction only; no actual transaction or account request",
        "runtime_version": "v2026.07.1", "luajit_sha256": digest((runtime / "luajit").read_bytes()),
        "archive_sha256": digest(archive_bytes), "archive_files": len(source_hashes),
        "target_source_sha256": {path: source_hashes[path] for path in TARGETS},
        "spec_sha256": digest(spec.read_bytes()), "driver_sha256": digest(Path(__file__).read_bytes()),
        "source_unchanged": unchanged, "returncode": completed.returncode, "result": result,
        "network_namespace_isolated": result.get("network_namespace_isolated"),
        "forbidden_module_attempts": result.get("forbidden_module_attempts"),
        "buy_episode_calls": result.get("buy_episode_calls"), "user_session_accessed": False,
    }
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "groups": len(result.get("groups", [])),
                      "assertions": result.get("assertions", 0), "report": str(output / "results.json")}))
    if not report["passed"]:
        print((completed.stdout + completed.stderr)[-5000:])
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
