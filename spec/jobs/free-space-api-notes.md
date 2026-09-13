# KOReader free-space API review

The reviewed runtime is official KOReader `v2026.07.1` at
`/tmp/bilicomics-native-_duimwe7/lib/koreader` on `test-env`.
This review used source inspection and a read-only Linux x64 capacity probe.

| API | Runtime source | Return contract | Limitation |
| --- | --- | --- | --- |
| `require("util").diskUsage(dir)` | `frontend/util.lua:925` | Table with `total`, `used`, and `available` in bytes; failed parsing can leave fields absent. | Executes `df -kP` and `awk` through `io.popen`. |
| `require("ffi/util").df(path)` | `ffi/util.lua:109` | Two values, total bytes and free bytes. | Uses `f_bfree * f_bsize`, ignores the `statvfs` return code, and reuses a shared structure. |
| `ffi.C.statvfs(path, status)` | `ffi/posix_h.lua:1013` | Returns `0` on success and `-1` on failure; `ffi.errno()` reports the error. | Callers must allocate the declared structure and check the return value. |

The remote probe confirmed that `ffi.util.df` can return the preceding successful
capacity result for a nonexistent path. A direct `statvfs` call to that path
returned `-1` with `errno=2`. The plugin therefore uses its own checked wrapper
over KOReader's existing ABI declarations.

Create a new `struct statvfs[1]` for every call and calculate usable bytes as
`f_bavail * f_frsize` only after a successful syscall. `f_bavail` accounts for
blocks available to a non-privileged process. `f_frsize` is the unit for the block
counts. See the [POSIX structure contract](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/sys_statvfs.h.html)
and [function return contract](https://pubs.opengroup.org/onlinepubs/9799919799/functions/statvfs.html).

KOReader declares device-specific layouts in `ffi/posix_h.lua`: Android
ARM/x86/macOS at line 220, Android 64-bit at line 236, Linux ARM at line 253,
Linux ARM64 at line 271, and Linux x64 at line 288. Reuse those declarations
instead of redeclaring the structure. The runtime probe only validates Linux x64;
it is not physical-device ABI evidence.

The current setting is `minimum_free_bytes`, with a default of 64 MiB. Check an
existing `temporary_root` immediately before a new acquisition and recheck in
the actual worker, since queued work can outlive its preflight result. Include
the expected new image write in addition to the reserve. Cached reads and
already-written recovery journals must remain usable below the threshold.

If a separate pre-commit check is added, run it before `putCommit`. A temporary
image already occupies space; a same-filesystem rename should not reserve the
same image size a second time. Recovery of an existing journal must not be
blocked by the acquisition reserve.

The executable budget regressions in `storage_budget_spec.lua` query real
filesystem capacity and request an impossible numeric reserve. They never fill
the filesystem or perform account or image-download operations.
