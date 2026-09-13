# Native Go/WASM host verification

Date: 2026-09-12. All compilation and execution took place through `ssh test-env`.
No local build, test, validation suite, or runtime probe was executed.

## Environment and artifacts

- Host: Debian Linux x86-64, kernel `6.12.107+deb13-cloud-amd64`.
- Workspace: `/tmp/bili-native-protocol-20260912`.
- Official module fixtures: `/tmp/bili-crypto-research-20260912`.
- wasm3: `5fe766c933c7595d728d6172bb1a197607d85b4e`.
- cJSON: `c859b25da02955fef659d658b8f324b5cde87be3`.
- Final library build: `build.sh`, Zig 0.13.0 C99, `-O2`, guarded memory disabled,
  maximum WASM linear memory 1,024 pages (64 MiB).
- Public ABI: `biliwasm_run` and `biliwasm_free`.

The final x86-64 shared-library SHA-256 is
`00f3200a8e276ea851722d3526105c84d0d13e5d0ebabe436227c9007149dc2d`.
It is included at `bilicomics/protocol/native/bin/linux-x86_64/libbiliwasm.so`.
`readelf --version-info` reports a maximum requirement of `GLIBC_2.17`.
This binary is therefore a Linux x86-64 build for glibc 2.17 or newer, not an
Android, ARM, or musl binary. It replaces the initial Debian-native GCC build
that required glibc 2.38. The included ARM hard-float and AArch64 artifacts also
declare no glibc requirement above 2.17, but have not been executed.
The native manifest and `native-elf-summary.json` record their distinct ABIs,
dependencies, and SHA-256 digests. Each library exports exactly the two public
host functions; a linker export map also hides Zig compiler-runtime symbols.

## Verified behavior

The final `native-verify.py` result was:

```json
{
  "golden_cases": 7,
  "cli_parity_cases": 7,
  "host_failure_cases": 7,
  "repeated_ffi_calls": 100,
  "rss_before_kib": 31340,
  "rss_after_kib": 31344,
  "peak_rss_kib": 31060,
  "elapsed_seconds": 2.936
}
```

The seven golden results cover two deterministic signing requests, the signing
argument-count error, the decoder argument-count error, invalid ciphertext
length, empty decrypted JSON, and a successfully decrypted synthetic payload.
The same seven requests produce matching CLI and shared-library JSON results.
Official Node/Go execution supplied the golden results; Node is only a research
oracle and is absent from the native runtime dependency chain.

`native-large-verify.js` also compares synthetic decoded JSON payloads of
32,782, 262,158, 1,048,590, and 3,145,742 bytes against the official Node result.
All four match. The largest payload reaches Go's internal timer scheduling
during allocation; the host now implements timer bookkeeping and bounded
resume processing instead of rejecting that path. Its measured native CLI
duration was 624 ms using the original GCC CLI. The final glibc-baseline shared
library also passes these four comparisons through a ctypes CLI adapter; the
largest measurement was 638 ms including Python process startup. These are not
ARM latency estimates.

The successful synthetic response fixture is:

```json
{
  "function": "c1_r9k2m7",
  "args": [
    "/twirp/comic.v1.Comic/ComicDetail",
    "yHEYgHkBOklQxZUed3mFB7VmJEAMe8nOHxniUEThJGI=",
    "SYNTHETIC-BUVID",
    "web",
    "{\"comic_id\":36215}"
  ]
}
```

Its callback result is `{"error":"","data":"{\"fixture\":\"crypto\"}"}`.
It contains synthetic data and does not represent a live authenticated response.

Host failure cases cover invalid request structure, an unpermitted callback,
invalid argument-array structure, an absent module, malformed WASM, an
out-of-bounds data initializer, and a module exceeding the configured memory
limit. The latter cases exercise module ownership and cleanup on load failure.
One hundred successive successful FFI calls increase resident memory by 4 KiB
in this process. The `/proc` current-RSS reading and `getrusage` high-water
reading use different kernel accounting paths; neither is a device budget.

The final host source passes remote
`gcc -std=c99 -Wall -Wextra -Werror -fsyntax-only`.
The separate `native-oom.c` harness injects a failure at each of the first 100
cJSON allocation positions. It records 24 correctly reported host failures,
76 complete successful signatures, and zero outstanding JSON allocations.
No allocation failure is reported as a successful partial signing result.
An earlier equivalent signing execution under AddressSanitizer and
UndefinedBehaviorSanitizer completed without reports; the subsequent final
change added cJSON allocation-failure checks and was covered by the final
functional and repeat-call run above.

The first CLI measurements were approximately 28 ms for signing and 33 ms for
the invalid-length decoder request, including full interpreter initialization.
These x86-64 server timings are not reader-device latency estimates.

## Remaining device checks

The official Zig 0.13.0 toolchain was downloaded into the isolated remote
workspace and checked against its published SHA-256, then used to cross-compile
the included Linux ARM hard-float and AArch64 libraries. Their ELF classes,
machine types, symbol versions, dependencies, and restricted exports were
inspected. Neither Linux ARM target was executed.

The subsequent Android build used the official NDK r27c archive, revision
`27.2.12479018`. Its SHA-1 matched the official HTTPS repository metadata;
the additionally recorded SHA-256 is
`59c2f6dc96743b5daf5d1626684640b20a6bd2b1d85b13156b90333741bad5cc`.
The download and extraction used `/var/tmp/bili-android-ndk-20260912`, because
the remote `/tmp` is a smaller memory-backed filesystem. No global toolchain
installation was made.

All four Android ABI builds (`arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`) completed
with `-Werror`. A host constant was renamed to `BILI_MAX_INPUT` to avoid an
Android system-header macro collision, with no change to the 16 MiB limit.
`native-android-build-results.json` records exact source hashes, compiler,
library hashes, ELF headers, ABI notes, exports, and dependencies. Every
library has exactly the two public exports, the expected SONAME, four 16 KiB
aligned load segments, no native TLS segment, and only the Bionic C/math/dl
dependencies. Android API 21 is the selected minimum; older Android versions
are not covered by these outputs.
The additional 32-bit x86 build matches the official KOReader v2026.07.1 x86
APK, whose five native libraries are all ELF32 for `EM_386`; the APK does not
contain `lib/x86_64` libraries.

The remote host exposes `/dev/kvm`, but `adb` and `emulator` were not initially
present in PATH. Android libraries are currently marked as cross-built and
ELF-inspected only; real application-directory loading and runtime execution
must be recorded separately. The deployment document specifies the exact
build inputs and remaining loading requirements.

Live signed API acceptance, authenticated response acquisition, purchases,
image transforms, and reader integration remain outside this native-host
verification. Changing either official WASM digest requires re-verification.
