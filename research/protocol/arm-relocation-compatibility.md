# ARM relocation layout compatibility with old glibc

Date: 2026-09-12. This document records the **second**, independent loader
problem: glibc BZ #14341, triggered by eager binding when the ordinary and PLT
relocation tables are separated by a gap. The diagnosis matches the old library
ELF bytes, upstream loader source and root's existing dynamic instruction trace.
The structured evidence is in
[arm-relocation-compatibility.json](arm-relocation-compatibility.json).

This audit only read ELF/source data and existing remote results. It did not
execute targets, algorithms, account requests or purchase scenarios, and changed
no production file. New library build/runtime results will be appended by root.

## Boundary from the earlier bootstrap defect

The earlier Thumb load-address bug prevented the official toolchain loader from
starting LuaJIT. Root corrected one ADR byte in a **private diagnostic copy**;
that enabled LuaJIT and exposed this later dlopen failure. The first correction
does not repair BZ #14341. These are separate causes and separate controls.

The diagnostic loader SHA is
`23f586c4b79afe238c1f7274838bcf2de80f7bd2cd954b094a5066902992ac6a`;
the original loader remains
`6f4bbe8b68bf2bf290c6125d4ccee6a44df4451e30866e75beecbcb7f1c4011c`.
Core libc remains the unmodified toolchain glibc 2.20. The control is recorded at
`/tmp/bilicomics-kindle-loader-WSAJTBOe/control/result.json`.

The official cross-toolchain sysroot is **not a Kindle firmware 5.19.3 image**.
Nothing here establishes either defect on the user's actual device, including
whether its vendor loader contains upstream backports.

## Old artifact layout

| Old ARM artifact | SHA256 |
| --- | --- |
| libbiliwasm.so | `df3bb13afbc85a79d229ef57f4f9826d68f4d7715a25d4d50b38ac584278c98d` |
| libbilicrypto.so | `424ac0a6ee2c7d5c4afc28b6b2705751306d015269699ac26ed1c379c248cbd1` |

Both use ELF32 ARM REL entries of eight bytes and declare DT_FLAGS=BIND_NOW plus
DT_FLAGS_1=NOW. Their ordinary relocation table is followed by .ARM.exidx, with
the actual PLT relocation table placed after that exception-index data.

| Field | WASM | Crypto |
| --- | ---: | ---: |
| DT_REL | `0x8ac` | `0x490` |
| DT_RELSZ | `0x1ba8` / 7080 | `0x128` / 296 |
| End of REL / start of .ARM.exidx | `0x2454` | `0x5b8` |
| .ARM.exidx size / intervening gap | `0x21e0` / 8672 | `0x410` / 1040 |
| DT_JMPREL | `0x4634` | `0x9c8` |
| DT_PLTRELSZ | `0x148` / 328 | `0x50` / 80 |
| End of PLT REL | `0x477c` | `0xa18` |
| First .ARM.exidx word pair | `(0x13f74, 0x1)` | `(0x11628, 0x1)` |

The real tables contain no R_ARM_PC24 relocation. The second word `0x1` in each
exception-index pair is unwind metadata; if incorrectly read as an Elf32_Rel
record, its low byte instead means R_ARM_PC24.

## Loader source and the observed fault

In [glibc 2.20 dynamic-link.h](https://github.com/bminor/glibc/blob/glibc-2.20/elf/dynamic-link.h#L134),
the eager-binding path adds PLTRELSZ to the first range without checking that
JMPREL immediately follows REL. For crypto it consequently scans
`[0x490, 0x608)` instead of the two valid ranges `[0x490, 0x5b8)` and
`[0x9c8, 0xa18)`. It misreads the **first 80 bytes** of the gap, rather than
skipping the gap to reach the PLT entries. WASM similarly scans to `0x259c`,
misreading the first 328 bytes of its gap.

Root's minimal result at
`/tmp/bilicomics-kindle-loader-WSAJTBOe/minimal-native/result.json` shows both
unmodified libraries printing `libc=2.20` and `before_dlopen`, then returning
`-11` without running production Lua or algorithms. Standalone loading of the
official pthread library succeeds in the separate `minimal/result.json` control.

The decisive crypto trace is
`/tmp/bilicomics-kindle-loader-WSAJTBOe/trace-native/library_1.instructions.log`
and its sibling `result.json`. The mapped base is `r9=0x409a0000`. The relocation
cursor reaches `r10=0x409a05b8`, exactly the first .ARM.exidx entry. Its bytes
become a false relocation offset `0x11628` and type R_ARM_PC24. The loader enters
`relocate_pc24.4` and attempts to store at `0x409a0000 + 0x11628 = 0x409b1628`.
The store at loader PC `0x408093d2` faults with SIGSEGV/SEGV_ACCERR in the crypto
segment's page-rounded RX mapping. This is an exact byte/address match to the
old loader's erroneous range calculation.

## Excluded hypotheses and pthread binding

Static checks found consistent GNU_HASH bucket/chain/bloom data, SysV hash symbol
counts, version table lengths and version-name ELF hashes in both plugin
libraries and official pthread. Every required versioned symbol was found in
its named official provider. There is no plugin RELR, TLSDESC or IFUNC entry,
and the declared relocation types also occur in the old ARM runtime. WASM has a
small TLS template; crypto does not, yet both fail through the same range bug.

The pthread dependency is not removable merely because there are no imports
named `pthread_*`. WASM's version-need index 5 binds `nanosleep`,
`__errno_location`, `longjmp`, `open` and `close` to pthread's GLIBC_2.4. Crypto's
index 3 binds `__errno_location`, `open`, `close` and `read` there. These exact
provider/version relationships were checked against the official library.

## Upstream fix and compatible output layout

Upstream commit [fa19d5c48a6b36518ce68412e3bdde6bfa8aa4a6](https://github.com/bminor/glibc/commit/fa19d5c48a6b36518ce68412e3bdde6bfa8aa4a6),
dated 2015-08-19 and associated with BZ #14341, adds the missing adjacency check
and keeps separate ranges when necessary. The inspected 2.20, 2.21 and 2.22
release tags contain the old behavior; [glibc 2.23](https://github.com/bminor/glibc/blob/glibc-2.23/elf/dynamic-link.h#L137)
contains the fix. This tag boundary does not describe vendor backport status.

The intended plugin compatibility change preserves BIND_NOW and required
dependencies while arranging ARM output sections so that
`DT_JMPREL == DT_REL + DT_RELSZ`. .ARM.exidx must remain valid but must not split
those relocation tables. The rebuilt artifacts subsequently passed nine
primitive checks each with the diagnostic glibc 2.20 loader and unmodified
Debian glibc 2.41; see [the completed correction report](../../docs/kindle-native-compatibility-fix.md).
The production files and both archive variants now contain that layout fix.
No additional loader correction for BZ #14341 is required or packaged. These
results remain distinct from physical Scribe acceptance.
