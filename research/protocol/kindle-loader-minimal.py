"""Separate core pthread loading from plugin loading in the diagnostic sysroot."""
import argparse
import json
from pathlib import Path
import resource
import subprocess


ROOT = Path("/var/tmp/bilicomics-kindle-qemu-20260912")


def no_core():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sysroot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--library", action="append", type=Path)
    parser.add_argument("--trace", action="store_true")
    args = parser.parse_args()
    sysroot, output = args.sysroot.resolve(), args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    script = output / "minimal.lua"
    script.write_text('''io.stdout:setvbuf("no")
local ffi = require("ffi")
ffi.cdef[[const char *gnu_get_libc_version(void);]]
print("libc=" .. ffi.string(ffi.C.gnu_get_libc_version()))
if arg[1] ~= "none" then
    print("before_dlopen")
    local library = ffi.load(arg[1])
    print("after_dlopen=" .. tostring(library ~= nil))
end
print("complete")
''')
    runtime = ROOT / "runtime/koreader"
    records = []
    cases = [("library_" + str(index), str(path.resolve())) for index, path in enumerate(args.library or [], 1)]
    if not cases:
        cases = [("ffi_only", "none"), ("pthread_only", str(sysroot / "lib/libpthread.so.0"))]
    for name, library in cases:
        flags = ["-strace", "-d", "in_asm,cpu", "-D", str(output / (name + ".instructions.log"))] if args.trace else []
        command = ["unshare", "-n", str(ROOT / "qemu/usr/bin/qemu-arm"), "-cpu", "cortex-a15", "-L", str(sysroot),
                   "-E", "LD_LIBRARY_PATH=" + str(sysroot / "lib") + ":" + str(runtime / "libs"),
                   "-E", "LD_DEBUG=libs:versions", *flags, str(runtime / "luajit"), str(script), library]
        result = subprocess.run(command, cwd=output, env={"PATH": "/usr/bin:/bin", "LANG": "C"},
                                capture_output=True, text=True, timeout=15, preexec_fn=no_core)
        (output / (name + ".stdout.log")).write_text(result.stdout)
        (output / (name + ".loader.log")).write_text(result.stderr)
        records.append({"name": name, "command": command, "returncode": result.returncode,
                        "stdout": result.stdout, "stderr_tail": result.stderr[-2000:]})
    report = {"scope": "Minimal libc/FFI dlopen isolation, without production Lua modules or algorithm execution", "cases": records,
              "diagnostic_modified_loader": True, "purchase_tests_executed": False,
              "production_lua_loaded": False, "requested_libraries": [str(path) for path in args.library or []]}
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
