"""Run existing offline ARM primitives using the explicitly corrected diagnostic loader."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time


ROOT = Path("/var/tmp/bilicomics-kindle-qemu-20260912")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    for name in ("control", "source", "probe", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    control, source, probe, output = (path.resolve() for path in (args.control, args.source, args.probe, args.output))
    prior = json.loads((control / "result.json").read_text())
    assert prior["returncode"] == 0 and prior["diagnostic_modified_loader"] and prior["original_loader_unchanged"]
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    sysroot = control / "sysroot"
    assert digest(sysroot / "lib/ld-2.20.so") == prior["modified_loader_sha256"]
    for name, expected in prior["unchanged_core_libraries"].items():
        assert digest(sysroot / "lib" / name) == expected
    native = source / "bilicomics/protocol/native"
    libraries = {}
    for name, manifest in (("libbiliwasm.so", native / "manifest.json"),
                           ("libbilicrypto.so", native / "portable/manifest.json")):
        library = native / "bin/linux-armhf" / name
        expected = json.loads(manifest.read_text())["libraries"]["linux-armhf"]
        assert digest(library) == expected["sha256"] and library.stat().st_size == expected["bytes"]
        libraries[name] = digest(library)
    staged_probe = output / "probe.lua"
    shutil.copyfile(probe, staged_probe)
    probe_hash = digest(staged_probe)
    runtime = ROOT / "runtime/koreader"
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C", "KO_MULTIUSER": "1"}
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        path = output / key.lower()
        path.mkdir()
        environment[key] = str(path)
    command = ["unshare", "-n", str(ROOT / "qemu/usr/bin/qemu-arm"), "-cpu", "cortex-a15", "-L", str(sysroot),
               "-E", "LD_LIBRARY_PATH=" + str(sysroot / "lib") + ":" + str(runtime / "libs"),
               "-E", "LD_DEBUG=libs:versions", str(runtime / "luajit"), str(staged_probe),
               str(source), str(ROOT / "assets"), str(output / "probe-result.json"), "2.20"]
    started = time.monotonic()
    result = subprocess.run(command, cwd=runtime, env=environment, capture_output=True, text=True, timeout=60)
    (output / "stdout.log").write_text(result.stdout)
    (output / "loader.log").write_text(result.stderr)
    observed = json.loads((output / "probe-result.json").read_text()) if (output / "probe-result.json").exists() else None
    report = {"command": command, "returncode": result.returncode, "seconds": round(time.monotonic() - started, 3),
              "scope": "Offline native primitives with unmodified official glibc 2.20 core and a one-instruction diagnostic loader correction",
              "passed": result.returncode == 0 and observed is not None and observed.get("passed") == 4,
              "probe": observed, "probe_sha256": probe_hash, "libraries": libraries,
              "loader_sha256": prior["modified_loader_sha256"], "glibc_sha256": digest(sysroot / "lib/libc-2.20.so"),
              "runtime_luajit_sha256": digest(runtime / "luajit"),
              "source_lua_sha256": {str(path.relative_to(source)): digest(path) for path in sorted((source / "bilicomics/protocol").rglob("*.lua"))},
              "diagnostic_modified_loader": True, "production_libraries_modified": False,
              "original_toolchain_modified": False, "firmware_image_used": False, "device_verified": False,
              "purchase_tests_executed": False, "account_requests": 0, "network_namespace_isolated": True}
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "source_lua_sha256"}))
    if result.returncode:
        print(result.stdout[-3000:] + result.stderr[-5000:])
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
