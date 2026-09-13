"""Apply one diagnostic instruction correction to a private toolchain sysroot copy.

This is not a production loader, firmware modification, or claim that the
unchanged official loader works. Its assertion checks are retained.
"""
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
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    source = ROOT / "x-tools/arm-kindlehf-linux-gnueabihf/arm-kindlehf-linux-gnueabihf/sysroot"
    target = output / "sysroot"
    copied = target / "lib"
    shutil.copytree(source / "lib", copied, symlinks=True)
    original_loader, fixed_loader = source / "lib/ld-2.20.so", copied / "ld-2.20.so"
    assert fixed_loader.resolve().is_relative_to(target.resolve())
    assert (copied / "ld-linux-armhf.so.3").resolve() == fixed_loader.resolve()
    original = original_loader.read_bytes()
    assert hashlib.sha256(original).hexdigest() == "6f4bbe8b68bf2bf290c6125d4ccee6a44df4451e30866e75beecbcb7f1c4011c"
    # For this exact Thumb instruction, PC - 48 clears the known Thumb tag that
    # PC - 47 retains. Upstream's source fix masks both sides before subtraction.
    assert original[0x38e4:0x38e8] == bytes.fromhex("aff22f02")
    fixed = bytearray(original)
    fixed[0x38e6] = 0x30
    fixed_loader.chmod(0o700)
    fixed_loader.write_bytes(fixed)
    assert [index for index, pair in enumerate(zip(original, fixed)) if pair[0] != pair[1]] == [0x38e6]
    unchanged = {}
    for path in (source / "lib").iterdir():
        if path.is_file() and not path.is_symlink() and path.name != "ld-2.20.so":
            unchanged[path.name] = digest(path)
            assert digest(copied / path.name) == unchanged[path.name]
    runtime = ROOT / "runtime/koreader"
    command = ["unshare", "-n", str(ROOT / "qemu/usr/bin/qemu-arm"), "-cpu", "cortex-a15", "-L", str(target),
               "-E", "LD_LIBRARY_PATH=" + str(copied) + ":" + str(runtime / "libs"),
               "-E", "LD_DEBUG=libs:versions", str(runtime / "luajit"), "-v"]
    started = time.monotonic()
    result = subprocess.run(command, cwd=runtime, env={"PATH": "/usr/bin:/bin", "LANG": "C"},
                            capture_output=True, text=True, timeout=15)
    (output / "stdout.log").write_text(result.stdout)
    (output / "loader.log").write_text(result.stderr)
    report = {"scope": "Causal diagnostic with one corrected instruction in a private loader copy",
              "command": command, "returncode": result.returncode, "stdout": result.stdout,
              "seconds": round(time.monotonic() - started, 3), "sysroot": str(target),
              "original_loader_sha256": hashlib.sha256(original).hexdigest(), "modified_loader_sha256": digest(fixed_loader),
              "original_loader_unchanged": original_loader.read_bytes() == original,
              "changed_file_offset": "0x38e6", "before_instruction": "aff22f02", "after_instruction": "aff23002",
              "upstream_fix": "https://github.com/bminor/glibc/commit/5ba6405338c280a3d84dcab1a11dcd1df9b5bee8",
              "unchanged_core_libraries": unchanged, "runtime_luajit_sha256": digest(runtime / "luajit"),
              "official_loader_modified_in_place": False, "diagnostic_modified_loader": True,
              "assertions_disabled": False, "plugin_loaded": False, "device_verified": False,
              "purchase_tests_executed": False, "network_namespace_isolated": True}
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    if result.returncode:
        print(result.stderr[-5000:])


if __name__ == "__main__":
    main()
