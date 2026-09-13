# Kindle ARM native compatibility correction

Date: 2026-09-12. Target guidance remains Kindle Scribe first generation,
firmware 5.19.3, official KOReader `kindlehf`. All execution occurred on remote
`test-env`; no Kindle, local acceptance app, session, quote, wallet or purchase
operation was accessed.

## Two distinct failures

| Failure | Evidence | Correction |
| --- | --- | --- |
| Toolchain loader bootstrap | The old Thumb ADR code computes load base `B+1`. Dynamic tags are read one byte late and VERSYM appears absent. Bare loader execution fails before plugin loading. | A private diagnostic loader copy corrects that exact instruction, matching the invariant of upstream glibc fix 5ba6405. No assertion is disabled and no loader is included in the plugin. |
| ARM plugin-library loading under old glibc | `BIND_NOW` causes glibc 2.20 to merge separated REL/JMPREL ranges. It reads intervening ARM exception-index entries as relocations and writes to an executable mapping. Both old native libraries reproduce the crash. | Rebuild Linux ARM32 shared libraries with adjacent `.rel.dyn` and `.rel.plt`. Retain immediate binding, GNU RELRO, pthread/versioned dependencies, ARMv6 hard-float ABI and the glibc 2.17 symbol baseline. |

The first cause is documented in [the bootstrap analysis](../research/protocol/native-glibc-bootstrap-analysis.md),
including instruction-state and one-byte control evidence. The second matches
[glibc BZ 14341](https://github.com/bminor/glibc/commit/fa19d5c48a6b36518ce68412e3bdde6bfa8aa4a6),
fixed upstream for glibc 2.23. [The relocation analysis](../research/protocol/arm-relocation-compatibility.md)
records the actual tables, misplaced scan and fault address.

The production correction is a linker-layout change in
`native/arm-relocations.ld`, selected by the WASM/portable build scripts only for
Linux ARM32 shared targets. The linker asserts adjacency. Algorithms, exports,
other CPU targets and runtime loader files are unchanged.

## Rebuilt artifacts and validation

| Library | Bytes | SHA-256 |
| --- | ---: | --- |
| `libbiliwasm.so` | 1,715,052 | `6dd731ec75e1c4144ad3f6ba56c6a6b37b3db7c234f578a2596fa77b0b17608d` |
| `libbilicrypto.so` | 59,880 | `56422e6570e954710769dfcd730b51eb1c2e7e0080d78ea9814f09eba73cd36f` |

Both libraries passed nine bounded checks in each of two independent sysroot
configurations using the unchanged official Kindle LuaJIT:

- [Official-toolchain glibc 2.20 with the diagnostic loader correction](../research/protocol/kindle-native-glibc220-result.json).
- [Unmodified Debian glibc 2.41 loader and core libraries](../research/protocol/kindle-native-glibc241-result.json).

The checks cover exact native loading, pinned signing-WASM output, AES-256 ECB,
fixed and freshly generated P256 agreement, PBKDF2-HMAC-SHA512, AES-128 GCM,
AES-256 GCM and tampered-tag rejection. Private material is not reported.
The native libraries remained byte-identical during both runs. The official
toolchain's original loader/core files and official KOReader files were not
modified. The generated diagnostic loader is separate test data.

`kindle-native-verify.py` records compiler-output library identities, the exact
probe, selected libc and loader, and network-namespace isolation. The original
loader failure and old-library failure reports remain preserved; successful
new results do not overwrite them. This is native/ABI evidence, not a complete
comic-reading or physical-device acceptance run.

## Archives from the ARM correction

Both artifact variants received only six changed files: the two ARM
libraries, their two manifests and two native README files. All Lua files and
other native targets remain identical to each variant's preceding archive.

- Reading development archive: 91 files, 2,422,729 bytes, SHA-256
  `b7b27290dda31834d593bd0e4234079602f807e7093be5b396d78d18a35691b4`.
- Quote preview: 95 files, 2,439,484 bytes, SHA-256
  `37127a655a2da25417cb29a8a6871a0ea8de78a97e328f1a2807bc5d8e8a537e`.

Each archive passed 27 packaging checks, including a new check of actual ARM
ELF relocation adjacency, immediate binding and GNU RELRO. The source records
for the [reading archive](../spec/package/source-evidence-before-connectivity.json) and
[quote preview](../spec/package/quote-preview-source-evidence-before-connectivity.json) bind the
new native bytes to both nine-check runs. Their earlier Lua/quote evidence
retains its original scope. No diagnostic loader or sysroot enters either ZIP.

The later connectivity/display archives preserve these native bytes. Their
current identities and separate focused Lua evidence are listed in
[implementation status](implementation-status.md).

Physical Scribe startup, real firmware libc/dependencies, memory pressure,
suspend/resume, touch and e-ink refresh remain unverified. Neither diagnosed
toolchain defect is claimed to exist in the user's actual firmware. Quote and
purchase behavior remain outside the executed checks.
