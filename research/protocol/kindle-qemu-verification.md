# Kindle ARM Loading and Crypto Probe

Date: 2026-09-12. Confirmed product target: Kindle Scribe first generation,
firmware 5.19.3. All preparation and execution occurred on `ssh test-env`.
No production source, native library, build configuration, or official KOReader
runtime was modified or rebuilt. No Kindle device was accessed. No session was
read and no account request or purchase test was executed.

This section records the original probe. A later investigation identified its
loader bootstrap cause and, after correcting a private diagnostic copy, a second
old-glibc relocation-layout issue in the ARM plugin libraries. See
[the bootstrap analysis](native-glibc-bootstrap-analysis.md) and
[the ARM relocation analysis](arm-relocation-compatibility.md). Those later
observations are separate from the historical unmodified-loader attempt below.

## Target selection and static boundary

The [official koxtoolchain 2026.08 target table](https://github.com/koreader/koxtoolchain/blob/2026.08/README.md)
maps `kindlehf` to Kindle firmware >= 5.16.3. Therefore `kindlehf` is the supported
package choice for the stated firmware according to official guidance. Actual
device process ABI and system libraries remain device acceptance observations.

The exact official KOReader archive is
[koreader-kindlehf-v2026.07.1.zip](https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-kindlehf-v2026.07.1.zip),
40,708,065 bytes, SHA-256
`3343a916d12f36c01b59df1f65bd83ff5616e6c2a4dfbe919e7fa1400b8b1bbb`.
Its unchanged `koreader/luajit` has SHA-256
`8174df8c653d26d9daeed5d1c7f452420d8b4ec81419599d9c65cb6ec44a14ee`.
It is an ELF32 ARM EABI5 hard-float executable using
`/lib/ld-linux-armhf.so.3`. The separate `kindlepw2` package uses the softfp
calling ABI and is not compatible with the current hard-float plugin libraries.

| Original production artifact | SHA-256 | Dynamic dependency boundary |
| --- | --- | --- |
| `linux-armhf/libbiliwasm.so` | `df3bb13afbc85a79d229ef57f4f9826d68f4d7715a25d4d50b38ac584278c98d` | `libm.so.6`, `libpthread.so.0`, `libc.so.6`, `ld-linux-armhf.so.3`; `clock_gettime@GLIBC_2.17`, `__isoc99_sscanf@GLIBC_2.7`, other undefined versioned symbols at `GLIBC_2.4` |
| `linux-armhf/libbilicrypto.so` | `424ac0a6ee2c7d5c4afc28b6b2705751306d015269699ac26ed1c379c248cbd1` | `libpthread.so.0`, `libc.so.6`; all undefined versioned symbols at `GLIBC_2.4` |

Both libraries are ELF32 ARM hard-float, built for ARMv6 with the declared Zig
`arm-linux-gnueabihf.2.17` target. No toolchain compiler was executed in this
probe. The manifests' declared glibc 2.17 build baseline is not a measurement of
the Scribe's libc version. The [static ELF review](kindle-elf-review.json)
records their complete versioned undefined-symbol inventories and the official
runtime identities.

## Isolated preparation

The dedicated remote directory is:

```text
/var/tmp/bilicomics-kindle-qemu-20260912/
```

The original package archives were retained and checked against their source
metadata before extraction. QEMU was extracted from a Debian package into this
directory; no package was installed and no `binfmt_misc` handler was registered.
Only `qemu-arm` was extracted from that package. The official toolchain compiler
was not extracted; its `sysroot/lib` directory was extracted for runtime use.
The official KOReader ZIP was extracted unchanged into `runtime/`.

| Download | Size | SHA-256 |
| --- | ---: | --- |
| [Official `kindlehf.tar.zst`, koxtoolchain 2026.08](https://github.com/koreader/koxtoolchain/releases/download/2026.08/kindlehf.tar.zst) | 100,848,195 | `8cc7dfbd71abd78f9e947d6b2e20670288a4402edc7b07176bca791f7eaf87d0` |
| Debian `qemu-user=1:10.0.11+ds-0+deb13u1` | 71,080,424 | `6b6fea55551fbcc1eb30e146ad5abdfbb49f8fa8c5998016242126de4d7f80df` |

The extracted QEMU executable is version 10.0.11, SHA-256
`1de890b2dfec9a24ac3a8a566654a6db1e9c4cbb35d056dff022854b688281f9`.
The emulated CPU model was `cortex-a15`; this is a test configuration, not a
claim about the Scribe's physical CPU. No host x86 implementation replaced any
Kindle or plugin ELF.

Scripts and metadata:

- [Download preparation](kindle-qemu-prepare.py) and [verified metadata](kindle-qemu-preparation.json).
- [Probe](kindle-qemu-probe.lua) and [execution driver](kindle-qemu-run.py).
- [Separate Debian preparation](kindle-qemu-debian.py) and [package metadata](kindle-qemu-debian-preparation.json).

The probe imports the existing production `NativeBackend`, `PortableCrypto`,
`Platform`, and `NativeLibrary` modules. Signing uses a previously acquired,
digest-pinned official WASM asset. Its injected transport rejects every request.
It never imports an account session or invokes API wrappers. A clean environment
and dedicated paths avoid application settings and unrelated runtime libraries;
QEMU user mode is not claimed to be a general security sandbox.

## Official glibc 2.20 sysroot: startup blocked

The official toolchain contains `libc-2.20.so` and `ld-2.20.so`:

- libc SHA-256: `0c3eacfb379ba98c7bd5b06c72b9aad48cd33071531aff2562470172b3c23d98`.
- loader SHA-256: `6f4bbe8b68bf2bf290c6125d4ccee6a44df4451e30866e75beecbcb7f1c4011c`.

Its archived crosstool-NG configuration selects shared GNU glibc 2.20, enables
glibc debug checks, and sets `CT_GLIBC_MIN_KERNEL="4.1"`. These are toolchain
configuration facts, not the user's kernel or firmware inventory. The extracted
libc exports both required newer symbols, `clock_gettime@@GLIBC_2.17` and
`__isoc99_sscanf@@GLIBC_2.7`.

The original Kindle LuaJIT aborted before Lua execution or plugin loading:

```text
Inconsistency detected by ld.so: do-rel.h: 116: elf_dynamic_do_Rel:
Assertion `map->l_info[(34 + 0 + (0x6fffffff - (0x6ffffff0)))] != ((void *)0)' failed!
```

The full command returned exit code 127. A separate `luajit -v` attempt without
`LD_DEBUG`, and direct execution of that loader with `--library-path` and the
same LuaJIT, both reproduced the startup assertion. These diagnostics did not
load the plugin libraries or run crypto fixtures.

The loader's ELF does contain `DT_VERSYM`, `DT_VERDEF`, and relocation tables;
it is not an empty link stub. The corresponding assertion is in the
[`RTLD_BOOTSTRAP` branch of glibc 2.20's `elf/do-rel.h`](https://github.com/bminor/glibc/blob/glibc-2.20/elf/do-rel.h#L114).
At the time of this original attempt, the cause was not established. The later
instruction-state trace now shows the known Thumb ADR load-bias defect: the
computed base is one byte too high, so dynamic tags are read at the wrong
address. Upstream fixed that old source for newer GAS in
[glibc commit 5ba6405](https://github.com/bminor/glibc/commit/5ba6405338c280a3d84dcab1a11dcd1df9b5bee8).
A one-instruction correction in a separate diagnostic loader copy changes
`luajit -v` from exit 127 to success while retaining assertions and all original
core-library bytes. This is not an unmodified-toolchain or physical Kindle pass.

See [execution record](kindle-qemu-official-sysroot-result.json) and
[loader output](kindle-qemu-official-loader.log). The sysroot is an official
cross-toolchain artifact, not a copy of the user's firmware 5.19.3 filesystem.

## Separate Debian glibc 2.41 sysroot: four checks passed

To obtain a narrower, independent ARM ABI/FFI/algorithm result, three Debian
runtime packages were additionally downloaded, verified against configured
package metadata, and privately extracted: `libc6-armhf-cross=2.41-11cross1`,
`libgcc-s1-armhf-cross=14.2.0-19cross1`, and
`libstdc++6-armhf-cross=14.2.0-19cross1`. Their combined download size was
1,517,740 bytes. No installation or compiler invocation occurred.

The same official LuaJIT and exact same two production libraries ran in 0.583
seconds and passed all four bounded checks:

1. Production native loading selected `linux-armhf`; `ffi.arch == "arm"` and
   `ffi.abi("hardfp") == true`.
2. Official signing WASM produced the previously established golden signature.
3. AES-256 ECB matched the NIST vector and decrypted back to its input.
4. The portable P256 implementation matched the standard generator and shared
   secret for scalar one, and rejected a zero scalar.

`gnu_get_libc_version()` reported **2.41**. The loader trace resolves libc and
libgcc from the private Debian extraction, uses the unchanged KOReader-bundled
`libstdc++.so.6` through its existing RPATH, checks the WASM host's
`GLIBC_2.17` reference against Debian libc, and initializes the exact plugin
libraries listed above. The extra extracted Debian libstdc++ was not substituted
for KOReader's RPATH-selected library.

See the [execution and four-check result](kindle-qemu-debian-result.json) and
[loader trace](kindle-qemu-debian-loader.log). This proves the stated ARM process,
FFI loading, and synthetic algorithm behavior under this Debian sysroot. It
does **not** establish execution under Kindle glibc 2.20, the user's firmware,
the real Scribe's memory/input/display behavior, or a softfp process.

## Acceptance boundary

The later rebuilt ARM libraries now pass nine bounded primitive checks in both
the glibc 2.20 diagnostic-loader environment and unmodified Debian glibc 2.41.
The source change keeps REL/JMPREL tables adjacent for the old BIND_NOW loader;
it preserves GNU RELRO, immediate binding, ABI and versioned dependencies.
See [the completed correction report](../../docs/kindle-native-compatibility-fix.md),
[glibc 2.20 result](kindle-native-glibc220-result.json) and
[glibc 2.41 result](kindle-native-glibc241-result.json). No diagnostic loader is
included in either plugin archive. The following physical-device boundary
continues to apply.

Continue ordinary Scribe adaptation using the official `kindlehf` guidance and
the existing `linux-armhf` artifacts. No softfp build is required merely from the
confirmed firmware information, but the softfp branch remains unsupported if
device inspection selects it. Actual Scribe loading, system dependency/glibc
availability, resource use, and reader interaction remain unperformed device
acceptance checks. No additional platform matrix, loader repair, library build,
account activity, or purchase test is part of this historical result. The later
ARM compatibility work retains separate source hashes and makes no claim that
the user's firmware contains either diagnosed toolchain-loader defect.
