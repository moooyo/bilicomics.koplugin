# Kindle Scribe First-Generation Compatibility

Review date: 2026-09-12. Status: package/ABI investigation and isolated remote loading probe.
Confirmed user target: first-generation Kindle Scribe, firmware **5.19.3**.

The user identified a first-generation Kindle Scribe, subsequently confirmed
firmware 5.19.3, and described KOReader as the latest version. The working
KOReader baseline is the latest stable release identified below. This provides
enough device information to continue ordinary adaptation without requesting
another ZIP name. It does not itself measure the running process's
floating-point ABI or the device's system glibc.
The original review below changed no production code, build configuration or native library. No
Kindle was accessed or operated. Isolated execution on `test-env` is recorded
separately from target-device acceptance below.

A subsequent [ARM native compatibility correction](../../docs/kindle-native-compatibility-fix.md)
changed the ARM shared-library link layout while retaining ABI and protection
flags. Both rebuilt libraries passed nine bounded checks each on Debian glibc
2.41 and toolchain glibc 2.20 with a private diagnostic loader correction. This
does not identify the actual firmware libc or constitute Scribe execution.

## Official release and device selection

The [official latest-release API](https://api.github.com/repos/koreader/koreader/releases/latest)
reported stable release **v2026.07.1**, published `2026-08-01T11:10:30Z`.
The [release page](https://github.com/koreader/koreader/releases/tag/v2026.07.1)
provides `kindle-legacy`, `kindle`, `kindlehf`, and `kindlepw2` packages. The tag
resolves to commit `9192014d8bd82a91dc1012473be0f238dedfdb54`.

Relevant source at that exact release commit:

| Question | Official source and observed behavior |
| --- | --- |
| First-generation Scribe identification | [`ks` identification set, line 2144](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/kindle/device.lua#L2144) contains `27J`, `2BL`, `263`, `227`, `2BM`, `23L`, `23M`, and `270`. The [matching branch](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/kindle/device.lua#L2199) returns `KindleScribe`. These are identification-code observations; the user's full serial number is not needed. |
| Hard-float detection | [`isHardFP()`, lines 44–46](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/kindle/device.lua#L44) tests whether `/lib/ld-linux-armhf.so.3` exists. |
| Distribution selection | [`otaModel()`, lines 593–606](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/kindle/device.lua#L593) selects `kindlehf` when hard-float is detected. Otherwise the Wario-or-newer hardware path, including the `MT8110` match relevant to Scribe, selects `kindlepw2`. |
| Firmware number versus ABI | The inspected ABI selection does not compare a firmware version number. [Firmware-number tests in the launch script](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/platform/kindle/koreader.sh#L254) concern interface workarounds; they do not establish a `5.16.3` ABI transition rule. |

Current master at `c5c6f2d39264b0248ee8216780f842b0ea3c9488` retains the same
ABI/package selection conditions. The changed secondary OTA return string does
not change the `kindlehf` versus `kindlepw2` decision.

The subsequent bounded toolchain review obtained an explicit official firmware
mapping: the
[koxtoolchain 2026.08 README target table](https://github.com/koreader/koxtoolchain/blob/2026.08/README.md)
describes `kindlehf` as "Any Kindle on FW >= 5.16.3". Therefore the confirmed
Scribe 1 / firmware 5.19.3 target should use **`kindlehf` according to the
official toolchain guidance**. This is authoritative installation guidance,
not an observation of the user's running process. The actual loader file or
first return value of `Device:otaModel()` remains the runtime acceptance check.

Ordinary adaptation can proceed against `kindlehf` without another ZIP-name
request. If actual device inspection contradicts the official guidance and
selects the softfp branch, it must be treated as an uncovered ABI rather than
silently loading the hard-float libraries. This review does not contain the
user's firmware-5.19.3 root filesystem or its system-libc inventory.

## Official package identity

Only the two relevant distributions were downloaded for this review. Their
computed SHA-256 values and byte sizes matched the official GitHub release
asset metadata.

| Official package | Bytes | SHA-256 |
| --- | ---: | --- |
| [koreader-kindlepw2-v2026.07.1.zip](https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-kindlepw2-v2026.07.1.zip) | 40,715,224 | `ea1f575c54492a2c679d128b7f3210fd7d6a87e5f5a1ff1f7a7fe2080ff68f86` |
| [koreader-kindlehf-v2026.07.1.zip](https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-kindlehf-v2026.07.1.zip) | 40,708,065 | `3343a916d12f36c01b59df1f65bd83ff5616e6c2a4dfbe919e7fa1400b8b1bbb` |

Remote evidence directory:

```text
/var/tmp/bilicomics-scribe-abi-20260912/
```

It contains the two ZIPs and selected extracted files beneath directories named
after each archive without `.zip`. Each inspected ELF file has an adjacent
`.readelf.txt` record generated with `readelf -h -l -d -V -A`. This is static ELF
inspection on `test-env`, not execution of a Kindle program.

## Observed ELF differences

The inspected files in each distribution were `koreader/luajit`,
`koreader/libs/libcrypto.so.57`, and `koreader/libs/libsqlite3.so.0`.

| Property | `kindlepw2` | `kindlehf` |
| --- | --- | --- |
| ELF class and machine | ELF32, ARM | ELF32, ARM |
| ELF ABI flags | `0x5000200`, EABI5, soft-float calling ABI | `0x5000400`, EABI5, hard-float calling ABI |
| CPU/FPU attributes | ARMv7 application profile, VFPv3 | ARMv7 application profile, VFPv3 |
| VFP argument convention | No VFP-register argument tag; soft-float ELF flag | `Tag_ABI_VFP_args: VFP registers` |
| LuaJIT program interpreter | `/lib/ld-linux.so.3` | `/lib/ld-linux-armhf.so.3` |

The soft-float calling ABI together with VFP instructions is the `softfp`
distinction relevant here. It does not mean that the hardware lacks an FPU.
Both inspected KOReader distributions are 32-bit ARM programs; no assumption
about a CPU product name is needed to establish their process ABI.

The official repository also retains a
[Kindle Buildroot configuration](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/platform/kindle/BR-2020.02-config#L47)
with `aapcs-linux`, `softfp`, and the
[`arm-kindle5-linux-gnueabi` external toolchain prefix](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/platform/kindle/BR-2020.02-config#L247).
This is corroborating configuration evidence, not proof of the exact compiler
or system libc on the user's present firmware. The downloaded release ELFs are
the direct evidence for the package ABI above.

### glibc boundary

The inspected `kindlepw2` files reference `GLIBC_2.4` symbols. The inspected
`kindlehf` LuaJIT and SQLite files also reference `GLIBC_2.4`; its inspected
`libcrypto.so.57` additionally references `GLIBC_2.16`.

These observations are **symbol-version requirements of selected files**. They
are not the version of the Kindle's installed glibc, not an exhaustive inventory
of every release library's requirements, and not proof that the device satisfies
the plugin's glibc 2.17 build target. The actual Scribe system glibc and dynamic
dependency baseline remain unverified in this review.

## Match against the existing plugin libraries

The current [WASM-host manifest](../../bilicomics/protocol/native/manifest.json)
and [portable-crypto manifest](../../bilicomics/protocol/native/portable/manifest.json)
declare the existing `linux-armhf` libraries as ARM hard-float builds targeting
`arm-linux-gnueabihf.2.17`. The WASM host also lists
`ld-linux-armhf.so.3` among its dynamic dependencies. These declarations and the
earlier cross-compilation evidence must not be described as Scribe execution.

The additional static review identifies the actual undefined-symbol boundary:
`libbiliwasm.so` requires `clock_gettime@GLIBC_2.17`,
`__isoc99_sscanf@GLIBC_2.7`, and otherwise `GLIBC_2.4` symbols.
`libbilicrypto.so` references only `GLIBC_2.4` among its undefined symbols.
Both require `libpthread.so.0` through `DT_NEEDED`; the portable library also
requires `libc.so.6`, and the WASM host additionally requires `libm.so.6` and
`ld-linux-armhf.so.3`. The manifest's glibc 2.17 target remains the declared
build baseline even when a particular artifact's symbol requirements are lower.

| Actual Scribe KOReader branch | Consequence |
| --- | --- |
| `kindlehf` | The calling ABI and loader family align with `linux-armhf`. This is a necessary compatibility condition, not a complete result: the actual glibc/dependency baseline and on-device loading still need confirmation. |
| `kindlepw2` / softfp | The existing hard-float libraries are not compatible with this process ABI. They cannot be fixed by renaming the directory or adding a loader alias. A separately built Kindle-compatible softfp target is required. |

[`Platform.nativeTarget()`](../../bilicomics/protocol/platform.lua) currently
maps ARM only when `ffi.abi("hardfp")` is true. A softfp Scribe process therefore
has no matching plugin native target today. This is a concrete conditional
implementation gap; it is not justification to assume that every Scribe needs
softfp or that every Scribe can use the existing hard-float binaries.

## Minimal next action

1. Use **Scribe 1 / firmware 5.19.3 / KOReader v2026.07.1 stable** as the ordinary
   adaptation baseline. Do not block that work on another request for the ZIP
   name, and do not silently broaden the scope to other Kindle models.
2. Include the actual process ABI, loader-file presence or `Device:otaModel()`
   result, and full installed KOReader version in the later authorized
   target-device acceptance record. Checking a similarly named path on
   `test-env` would not establish anything about the Kindle.
3. If that check selects softfp, use a dedicated Kindle softfp build and platform
   selection only after choosing the matching verified toolchain/sysroot. If it
   is hard-float, first confirm the actual runtime dependency/glibc requirements
   rather than assuming that the generic glibc 2.17 artifact is sufficient.
4. Perform any later device-loading, crypto, memory, and reader checks only in
   their separately authorized verification scope. Android emulator results are
   not Kindle compatibility evidence.

The authorized isolated follow-up is recorded in
[Kindle QEMU verification](kindle-qemu-verification.md). With the original
official `kindlehf` LuaJIT and unchanged production libraries, all four bounded
ARM loading/signing/AES/P256 checks passed under a separate Debian glibc 2.41
sysroot. The official toolchain's glibc 2.20 loader aborted during its own
bootstrap before Lua or plugin execution; that result is preserved separately.
Neither result is a device test or a measurement of firmware 5.19.3's libc.

No production change or native build occurred. The user target and firmware
are known; dependency confirmation and actual Scribe execution remain
acceptance checks rather than additional prerequisites for discussing or
implementing the ordinary plugin features.
