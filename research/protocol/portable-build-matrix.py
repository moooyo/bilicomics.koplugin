#!/usr/bin/env python3
"""Build the pinned portable library on the remote Linux build host."""

import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


source, dependency, zig, work = [Path(value).resolve() for value in sys.argv[1:5]]
ndk = Path(sys.argv[5]).resolve() if len(sys.argv) > 5 else None
work.mkdir(parents=True, exist_ok=True)
targets = {
    "linux-x86_64": "x86_64-linux-gnu.2.17",
    "linux-armhf": "arm-linux-gnueabihf.2.17",
    "linux-aarch64": "aarch64-linux-gnu.2.17",
}
if ndk:
    targets.update({
        "android-arm64-v8a": "aarch64-linux-android21",
        "android-armeabi-v7a": "armv7a-linux-androideabi21",
        "android-x86_64": "x86_64-linux-android21",
    })


def build(item):
    name, target = item
    destination = work / name
    destination.mkdir(exist_ok=True)
    compiler = destination / "cc.sh"
    android = name.startswith("android-")
    if android:
        ndk_cc = ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin" / f"{target}-clang"
        compiler.write_text(f'#!/bin/sh\nexec "{ndk_cc}" "$@"\n')
    else:
        compiler.write_text(f'#!/bin/sh\nexec "{zig}" cc -target {target} "$@"\n')
    compiler.chmod(0o755)
    output = destination / "libbilicrypto.so"
    env = dict(os.environ, CC=str(compiler), OUTPUT=str(output), DEPENDENCY_DIR=str(dependency),
               ZIG_LOCAL_CACHE_DIR=str(destination / "cache"),
               ZIG_GLOBAL_CACHE_DIR=str(work / "cache-global"))
    if android:
        env["LDFLAGS"] = "-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -Wl,-soname,libbilicrypto.so"
    run = subprocess.run(["sh", str(source / "build.sh")], env=env, capture_output=True, text=True)
    (destination / "build.log").write_text(run.stdout + run.stderr)
    if run.returncode:
        raise RuntimeError(f"{name} failed: {run.stderr[-6000:]}")
    elf = subprocess.check_output(["readelf", "-h", "-A", "-d", "--version-info", str(output)], text=True)
    exports = subprocess.check_output(["nm", "-D", "--defined-only", str(output)], text=True)
    (destination / "elf.txt").write_text(elf)
    (destination / "exports.txt").write_text(exports)
    names = sorted(line.split()[-1] for line in exports.splitlines() if line.strip())
    expected = sorted([
        "bili_p256_new", "bili_p256_public", "bili_p256_derive",
        "bili_aes256_ecb_encrypt", "bili_aes256_ecb_decrypt",
        "bili_pbkdf2_sha512", "bili_aes_gcm_decrypt",
    ])
    assert names == expected, (name, names)
    record = {
        "path": f"../bin/{name}/libbilicrypto.so", "target": target,
        "sha256": hashlib.sha256(output.read_bytes()).hexdigest(), "bytes": output.stat().st_size,
        "needed": re.findall(r"Shared library: \[([^]]+)\]", elf),
        "exports": names,
        "verification": "cross-compiled-elf-inspected-only", "device_verified": False,
    }
    if android:
        record.update(minimum_android_api=21, elf_page_alignment=16384)
        assert not any(".so." in name for name in record["needed"]), record["needed"]
        headers = subprocess.check_output(["readelf", "-lW", str(output)], text=True)
        (destination / "program-headers.txt").write_text(headers)
        loads = [line for line in headers.splitlines() if line.strip().startswith("LOAD ")]
        assert loads and all(int(line.split()[-1], 16) == 16384 for line in loads)
    else:
        record["minimum_glibc"] = "2.17"
    if name == "linux-armhf":
        assert "hard-float ABI" in elf and "Tag_CPU_arch: v6" in elf
        record.update(cpu="ARMv6", float_abi="hard")
    if name == "linux-x86_64":
        report = json.loads(subprocess.check_output([
            "python3", str(Path(__file__).with_name("portable-verify.py")), str(output)], text=True))
        (destination / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
        record["verification"] = "remote-linux-x86_64-nist-node-primitive-golden"
    print(json.dumps({"built": name, **record}), flush=True)
    return name, record


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    libraries = dict(pool.map(build, targets.items()))
manifest = {
    "schema": 1, "host_abi": "bilicrypto-v1", "source_date": "2026-09-12",
    "dependency": {
        "name": "Mbed TLS", "version": "3.6.7",
        "commit": "068ff080b369adfac81509f9b57b2afabaf82dc5",
        "license": "Apache-2.0", "manifest": "../legacy_v5/dependency.json",
    },
    "toolchain": {"name": "Zig", "version": "0.13.0",
        "archive_sha256": "d45312e61ebcc48032b77bc4cf7fd6915c11fa16e4aad116b66c9468211230ea"},
    "libraries": libraries,
}
if ndk:
    manifest["android_toolchain"] = {
        "name": "Android NDK", "version": "r27c",
        "official_archive_sha1": "090e8083a715fdb1a3e402d0763c388abb03fb4e",
        "archive_sha256": "59c2f6dc96743b5daf5d1626684640b20a6bd2b1d85b13156b90333741bad5cc",
    }
(work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
