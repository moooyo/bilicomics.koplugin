"""Verify rebuilt ARM native libraries with an explicitly identified private sysroot."""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import shutil
import subprocess
import time


ROOT = Path("/var/tmp/bilicomics-kindle-qemu-20260912")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def no_core():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def main():
    parser = argparse.ArgumentParser()
    for name in ("source", "sysroot", "probe", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--glibc", required=True, choices=("2.20", "2.41"))
    parser.add_argument("--checks", required=True, type=int)
    parser.add_argument("--diagnostic-loader", action="store_true")
    args = parser.parse_args()
    source, sysroot, probe, output = (path.resolve() for path in (args.source, args.sysroot, args.probe, args.output))
    assert 1 <= args.checks <= 20
    assert args.diagnostic_loader == (args.glibc == "2.20")
    loader = sysroot / "lib/ld-linux-armhf.so.3"
    if args.diagnostic_loader:
        assert digest(loader) == "23f586c4b79afe238c1f7274838bcf2de80f7bd2cd954b094a5066902992ac6a"
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    staged_probe = output / "probe.lua"
    shutil.copyfile(probe, staged_probe)
    native = source / "bilicomics/protocol/native"
    libraries = {}
    for name, manifest in (("libbiliwasm.so", native / "manifest.json"),
                           ("libbilicrypto.so", native / "portable/manifest.json")):
        library = native / "bin/linux-armhf" / name
        entry = json.loads(manifest.read_text())["libraries"]["linux-armhf"]
        assert digest(library) == entry["sha256"] and library.stat().st_size == entry["bytes"]
        libraries[name] = {"sha256": digest(library), "bytes": library.stat().st_size}
    runtime = ROOT / "runtime/koreader"
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C", "KO_MULTIUSER": "1"}
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        path = output / key.lower()
        path.mkdir()
        environment[key] = str(path)
    command = ["unshare", "-n", str(ROOT / "qemu/usr/bin/qemu-arm"), "-cpu", "cortex-a15", "-L", str(sysroot),
               "-E", "LD_LIBRARY_PATH=" + str(sysroot / "lib") + ":" + str(runtime / "libs"),
               "-E", "LD_DEBUG=libs:versions", str(runtime / "luajit"), str(staged_probe), str(source),
               str(ROOT / "assets"), str(output / "probe-result.json"), args.glibc]
    started = time.monotonic()
    result = subprocess.run(command, cwd=runtime, env=environment, capture_output=True, text=True,
                            timeout=60, preexec_fn=no_core)
    (output / "stdout.log").write_text(result.stdout)
    (output / "loader.log").write_text(result.stderr)
    observed = json.loads((output / "probe-result.json").read_text()) if (output / "probe-result.json").exists() else None
    passed = result.returncode == 0 and observed is not None and observed.get("passed") == args.checks
    passed = passed and observed.get("glibc") == args.glibc and observed.get("ok") is True
    passed = passed and len(observed.get("checks", [])) == args.checks and all(item.get("ok") is True for item in observed["checks"])
    unchanged = all(digest(native / "bin/linux-armhf" / name) == record["sha256"] for name, record in libraries.items())
    passed = passed and unchanged
    report = {"passed": passed, "command": command, "returncode": result.returncode,
              "seconds": round(time.monotonic() - started, 3), "probe": observed,
              "scope": "Offline ARM native primitives; distinct sysroot identity and diagnostic loader status are recorded",
              "expected_glibc": args.glibc, "diagnostic_modified_loader": args.diagnostic_loader,
              "loader_sha256": digest(loader), "libc_sha256": digest(sysroot / "lib/libc.so.6"),
              "runtime_luajit_sha256": digest(runtime / "luajit"), "probe_sha256": digest(staged_probe),
              "libraries": libraries, "libraries_unchanged_during_run": unchanged, "production_libraries_rebuilt": True,
              "firmware_image_used": False, "device_verified": False,
              "purchase_tests_executed": False, "account_requests": 0, "network_namespace_isolated": True,
              "source_protocol_lua_sha256": {str(path.relative_to(source)): digest(path)
                  for path in sorted((source / "bilicomics/protocol").rglob("*.lua"))}}
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "source_protocol_lua_sha256"}))
    if result.returncode:
        print(result.stdout[-2000:] + result.stderr[-4000:])
    return int(not passed)


if __name__ == "__main__":
    raise SystemExit(main())
