"""Reproduce the toolchain loader failure without loading plugin or account code."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


ROOT = Path("/var/tmp/bilicomics-kindle-qemu-20260912")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    qemu = ROOT / "qemu/usr/bin/qemu-arm"
    runtime = ROOT / "runtime/koreader"
    official = ROOT / "x-tools/arm-kindlehf-linux-gnueabihf/arm-kindlehf-linux-gnueabihf/sysroot"
    debian = ROOT / "debian/usr/arm-linux-gnueabihf"
    loader = official / "lib/ld-2.20.so"
    paths = {"qemu": qemu, "luajit": runtime / "luajit", "official_loader": loader,
             "official_libc": official / "lib/libc-2.20.so", "debian_loader": debian / "lib/ld-linux-armhf.so.3"}
    before = {name: digest(path) for name, path in paths.items()}
    assert before["qemu"] == "1de890b2dfec9a24ac3a8a566654a6db1e9c4cbb35d056dff022854b688281f9"
    assert before["luajit"] == "8174df8c653d26d9daeed5d1c7f452420d8b4ec81419599d9c65cb6ec44a14ee"
    assert before["official_loader"] == "6f4bbe8b68bf2bf290c6125d4ccee6a44df4451e30866e75beecbcb7f1c4011c"
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C"}
    cases = (("official_luajit", official, [str(runtime / "luajit"), "-v"], []),
             ("official_loader_only", official, [str(loader)], []),
             ("official_syscalls", official, [str(runtime / "luajit"), "-v"], ["-strace"]),
             ("debian_control", debian, [str(runtime / "luajit"), "-v"], []))
    records = []
    for name, sysroot, target, flags in cases:
        command = ["unshare", "-n", str(qemu), "-cpu", "cortex-a15", "-L", str(sysroot),
                   "-E", "LD_LIBRARY_PATH=" + str(sysroot / "lib") + ":" + str(runtime / "libs"), *flags, *target]
        started = time.monotonic()
        process = subprocess.run(command, cwd=runtime, env=environment, capture_output=True, text=True, timeout=15)
        (output / (name + ".stdout.log")).write_text(process.stdout)
        (output / (name + ".stderr.log")).write_text(process.stderr)
        record = {"name": name, "command": command, "returncode": process.returncode,
                  "seconds": round(time.monotonic() - started, 3), "stdout": process.stdout[:1000],
                  "stderr": process.stderr[:4000]}
        records.append(record)
        print(json.dumps(record), flush=True)
    report = {"scope": "Loader/LuaJIT CLI only, without plugin, session or API execution",
              "source_sha256": before, "source_unchanged": all(digest(paths[name]) == value for name, value in before.items()),
              "host_machine": os.uname().machine, "host_kernel": os.uname().release,
              "tools": {name: shutil.which(name) for name in ("gdb-multiarch", "gdb", "llvm-objdump", "readelf", "objdump", "strace")},
              "cases": records, "device_verified": False, "purchase_tests_executed": False,
              "plugin_loaded": False, "network_namespace_isolated": True}
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
