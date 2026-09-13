# Linux ARM32 shared-library relocation layout

Date: 2026-09-12. This change addresses shared-object layout compatibility with
glibc versions affected by BZ 14341. It does not change cryptographic algorithms,
remove dependencies, weaken binding, or modify a loader.

The upstream fix is
[`fa19d5c48a6b36518ce68412e3bdde6bfa8aa4a6`](https://github.com/bminor/glibc/commit/fa19d5c48a6b36518ce68412e3bdde6bfa8aa4a6).
The affected eager-relocation path can treat dynamic and PLT REL tables as one
continuous range. Existing LLD ARM outputs place `.ARM.exidx` between those
tables, which is incompatible with that assumption.

## Maintained source change

- `native/arm-relocations.ld` assigns `.rel.plt` immediately after `.rel.dyn`
  with an `INSERT` command and asserts their adjacency at link time.
- Both native build scripts inspect the actual compiler's predefined macros.
  The rule applies only to `__arm__ && __linux__ && !__ANDROID__`, and only to
  shared-library outputs.
- The WASM host's Linux ARM32 branch explicitly preserves `-z relro -z now`.
  Portable crypto retains its existing RELRO/NOW options.
- The output script does not force unnatural alignment or move other relocation
  sections. Other platform branches receive no new linker-layout flags.

The final checks use dynamic tags, not only output-section order. Both candidates
must satisfy `DT_JMPREL == DT_REL + DT_RELSZ`, with `DT_PLTREL=REL` and
`DT_RELENT=8`.

## Isolated candidate builds

Only the two Linux ARM hard-float libraries were rebuilt, on `ssh test-env`, in:

```text
/var/tmp/bili-arm-relocations-20260912-kxhQC0K1/
```

The compiler is the previously verified Zig 0.13.0, target
`arm-linux-gnueabihf.2.17`. The WASM host retains
`CFLAGS=-DM3_HAS_TAIL_CALL=0`. The existing pinned wasm3, cJSON, and portable
Mbed TLS dependency checkouts are reused. The current production portable
source's `bili_secure.h` is included unchanged in the private source snapshot.

| Candidate | Bytes | SHA-256 |
| --- | ---: | --- |
| `output/libbiliwasm.so` | 1715052 | `6dd731ec75e1c4144ad3f6ba56c6a6b37b3db7c234f578a2596fa77b0b17608d` |
| `output/libbilicrypto.so` | 59880 | `56422e6570e954710769dfcd730b51eb1c2e7e0080d78ea9814f09eba73cd36f` |

## Static verification

| Field | WASM host | Portable crypto |
| --- | --- | --- |
| `DT_REL` | `0x8ac` | `0x490` |
| `DT_RELSZ` | 7080 | 296 |
| End of dynamic REL table | `0x2454` | `0x5b8` |
| `DT_JMPREL` | `0x2454` | `0x5b8` |
| `DT_PLTRELSZ` | 328 | 80 |
| REL entry size | 8 | 8 |
| Effective NOW binding | Present | Present |
| `PT_GNU_RELRO` | Present | Present |
| ELF ABI | ARM ELF32 EABI5 hard-float, ARMv6 | ARM ELF32 EABI5 hard-float, ARMv6 |
| Public exports | Same 2 host functions | Same 7 crypto functions |

The WASM host retains `libm.so.6`, `libpthread.so.0`, `libc.so.6`, and
`ld-linux-armhf.so.3` dependencies. Its required version tags remain GLIBC 2.4,
2.7, and 2.17. Portable crypto retains `libpthread.so.0` and `libc.so.6`, with
only GLIBC 2.4 versioned imports.

Exact source hashes, dynamic ranges, imports, exports, and build commands are
recorded in `native-arm-relocations-elf.json` and
`native-arm-relocations-build.json`. The private directory also retains full
`readelf` output and compiler logs.

This subtask performed build and ELF inspection only. It did not run algorithm
suites or target programs, rebuild other platforms, replace local production
binaries, or update a manifest. The root task owns diagnostic-glibc-2.20 and
Debian-glibc-2.41 acceptance runs and any later decision to promote candidates.

The root subsequently ran [nine checks with the glibc 2.20 diagnostic loader](kindle-native-glibc220-result.json)
and [nine with unmodified Debian glibc 2.41](kindle-native-glibc241-result.json),
all passing for these exact binary hashes. Both libraries and integrity
manifests were then promoted into the reading and quote-preview archives.
[The consolidated report](../../docs/kindle-native-compatibility-fix.md) records
the final package identities and remaining device/monetary acceptance limits.
