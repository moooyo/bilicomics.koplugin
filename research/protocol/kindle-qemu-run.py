"""Run only the authorized offline crypto fixtures on test-env."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path("/var/tmp/bilicomics-kindle-qemu-20260912")
MODE = sys.argv[1] if len(sys.argv) > 1 else "official"
assert MODE in ("official", "debian")
SYSROOT = (ROOT / "x-tools/arm-kindlehf-linux-gnueabihf/arm-kindlehf-linux-gnueabihf/sysroot" if MODE == "official"
           else ROOT / "debian/usr/arm-linux-gnueabihf")
EXPECTED_GLIBC = "2.20" if MODE == "official" else "2.41"
DESTINATION = ROOT if MODE == "official" else ROOT / "debian-result"
DESTINATION.mkdir(mode=0o700, exist_ok=True)
RUNTIME = ROOT / "runtime/koreader"
QEMU = ROOT / "qemu/usr/bin/qemu-arm"
SOURCE = ROOT / "source"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


native = SOURCE / "bilicomics/protocol/native"
for manifest, name in [(native / "manifest.json", "libbiliwasm.so"),
                       (native / "portable/manifest.json", "libbilicrypto.so")]:
    entry = json.loads(manifest.read_text())["libraries"]["linux-armhf"]
    path = native / "bin/linux-armhf" / name
    assert sha(path) == entry["sha256"] and path.stat().st_size == entry["bytes"]

result_path = DESTINATION / "result.json"
assert not result_path.exists(), "Use a fresh result destination for this run"
command = [
    str(QEMU), "-cpu", "cortex-a15", "-L", str(SYSROOT),
    "-E", "LD_LIBRARY_PATH=" + str(SYSROOT / "lib") + ":" + str(RUNTIME / "libs"),
    "-E", "LD_DEBUG=libs:versions", str(RUNTIME / "luajit"), str(ROOT / "probe.lua"),
    str(SOURCE), str(ROOT / "assets"), str(result_path), EXPECTED_GLIBC,
]
environment = {"PATH": "/usr/bin:/bin", "HOME": str(ROOT), "LANG": "C", "KO_MULTIUSER": "1",
               "XDG_DATA_HOME": str(ROOT / "data"), "XDG_CONFIG_HOME": str(ROOT / "config"),
               "XDG_CACHE_HOME": str(ROOT / "cache")}
started = time.monotonic()
process = subprocess.run(command, cwd=RUNTIME, env=environment, capture_output=True, text=True, timeout=120)
(DESTINATION / "stdout.log").write_text(process.stdout)
(DESTINATION / "loader.log").write_text(process.stderr)
report = {
    "sysroot_origin": MODE, "expected_glibc": EXPECTED_GLIBC,
    "command": command, "exit_code": process.returncode, "seconds": round(time.monotonic() - started, 3),
    "qemu_version": subprocess.check_output([str(QEMU), "--version"], text=True).splitlines()[0],
    "kindle_runtime_sha256": sha(RUNTIME / "luajit"),
    "qemu_sha256": sha(QEMU),
    "sysroot_glibc_sha256": sha(SYSROOT / "lib/libc.so.6"),
    "sysroot_loader_sha256": sha(SYSROOT / "lib/ld-linux-armhf.so.3"),
    "libraries": {name: sha(native / "bin/linux-armhf" / name)
                  for name in ("libbiliwasm.so", "libbilicrypto.so")},
    "account_requests": 0, "global_installation": False, "binfmt_registration": False,
    "rebuilt_target_binaries": False, "kindle_firmware_image": False, "device_verified": False,
}
if result_path.exists():
    report["probe"] = json.loads(result_path.read_text())
(DESTINATION / "execution.json").write_text(json.dumps(report, indent=2) + "\n")
print(process.stdout)
print(json.dumps(report, indent=2))
if process.returncode:
    print(process.stderr[-6000:])
raise SystemExit(process.returncode)
