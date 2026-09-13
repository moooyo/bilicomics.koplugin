# Kindle QEMU launcher path audit

This is a read-only audit dated 2026-09-12. It inspected the existing launchers,
logs, ELF headers and filesystem/archive metadata on `ssh test-env`. It did not
run QEMU, any target program, the SDK, an account request or a purchase scenario;
it did not modify production or access local WSL. The structured observations
are in [kindle-qemu-path-audit.json](kindle-qemu-path-audit.json).

## Finding

There is no observed downstream library mixture explaining the official glibc
2.20 loader assertion. Root's subsequent minimal reproduction at
`/tmp/bilicomics-kindle-loader-WSAJTBOe/initial/result.json` directly runs the bare
official loader and gets the same exit 127. Its guest syscall trace contains
only `writev` and `exit_group`, with no library open/read calls. The same QEMU
and LuaJIT succeed with the Debian loader. The failure is therefore already
isolated to loader bootstrap; this audit does not establish its precise cause.

Both selected loaders and LuaJIT are ARM EABI5 hard-float binaries with ARMv7
attributes. The official loader contains DT_VERSYM. Its loader/libc/core-library
symlinks resolve inside the selected official sysroot. Neither the runtime root
nor runtime/libs contains overriding libc, libm, libdl, pthread, libgcc or loader
files. The host ARM interpreter, host ARM library directory and ld.so.preload
are absent. Neither selected sysroot has an ld.so.cache file.

## Search-path behavior

`kindle-qemu-run.py` launches LuaJIT directly. Its PT_INTERP is
`/lib/ld-linux-armhf.so.3`, and `-L` selects the matching official or Debian
sysroot prefix. The explicit process environment does not inherit host LD_* or
QEMU_LD_PREFIX settings. `-E LD_LIBRARY_PATH=SYSROOT/lib:RUNTIME/libs` is a guest
setting. QEMU itself is the inspected x86-64 static PIE with no interpreter or
DT_NEEDED entries.

LuaJIT and rapidjson carry **DT_RPATH**, not RUNPATH. The successful Debian
loader trace demonstrates that LuaJIT's `$ORIGIN:$ORIGIN/libs` is searched before
LD_LIBRARY_PATH, selecting KOReader's bundled libstdc++. Core libc/libm/libdl/
pthread/libgcc resolve from the private Debian extraction. Thus the success is
a mixed-origin, deliberate ABI fixture: Debian core runtime plus KOReader's C++
library. It is neither a pure Debian dependency closure nor Kindle glibc proof.
The Debian libgcc requires GLIBC_2.34, whereas the official sysroot's libgcc
requires GLIBC_2.4; exchanging these files would change the tested boundary.

QEMU `-L` is not a filesystem namespace. Absolute source/runtime paths remain
host-visible, and no corresponding duplicated path below either prefix exists
in the inspected environment. The working directory is intentionally the
official runtime for setupkoenv and relative Lua/C module loading. These are
controlled lookup choices, not a general sandbox claim.

## Reproducibility limits and available tools

The launcher relies on an externally staged `ROOT/probe.lua` but does not hash
it. The original official execution record lacks the current probe's final
expected_glibc argument; the old assertion occurred before Lua ran, but that old
command should not be described as an exact replay of today's probe. Debian
extraction also reuses its destination without clearing unrelated old files.
No conflicting core library was observed here.

Root has already completed the appropriate minimal loader-only reproduction;
there is no reason to repeat SDK/crypto work to investigate this assertion.
For static ARM disassembly, the existing private `kindlehf.tar.zst` contains:

```text
x-tools/arm-kindlehf-linux-gnueabihf/arm-kindlehf-linux-gnueabihf/bin/objdump
```

This is a regular 1,974,728-byte archive member. The prefixed
`bin/arm-kindlehf-linux-gnueabihf-objdump` entry is a tar hardlink to it, so a
minimal extraction should include the actual member. readelf, nm and addr2line
are also present. No executable `/bin/*gdb*` entry was found. These tools were
not already extracted and this audit neither extracts nor executes them.
