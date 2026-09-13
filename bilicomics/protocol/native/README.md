# Bilibili Comics native WASM host

This directory contains a C host that runs the official, pinned signing and
response-decoding WASM modules with wasm3. It executes their actual Go code.
It does not reimplement or approximate the signature algorithm, and it needs
neither Node.js nor a browser on the device.

The shared library and command-line executable have been built and verified on
the remote Linux x86-64 `test-env`. The package contains a glibc 2.17 baseline
x86-64 library and cross-compiled ARM hard-float and AArch64 Linux libraries.
The rebuilt ARM32 library has ELF inspection and bounded QEMU primitive evidence
with Debian glibc 2.41 and official-toolchain glibc 2.20 using a separately
corrected diagnostic loader. No physical device execution is claimed.
Android API 21 libraries are also included for `arm64-v8a`,
`armeabi-v7a`, `x86_64`, and `x86`; their current evidence is cross-compilation and ELF
inspection only. Android application loading and execution remain separate
checks. See
[`native-deployment.md`](../../../research/protocol/native-deployment.md)
for ABI, Android, memory, and cross-compilation requirements.

## Interface

`biliwasm.h` exposes:

```c
int biliwasm_run(const char *wasm_path, const char *request_json, char **output_json);
void biliwasm_free(char *output_json);
```

Calls are synchronous and must run in the plugin's worker, with calls serialized.
Every call creates an isolated runtime and releases it before returning.
Pass an absolute module path. Free a non-null result with `biliwasm_free`, including
on failure. The function returns `0` if the WASM callback completed and `1` if the
host failed. A completed callback can still report its own protocol error in
`result.error`.

Example signing request:

```json
{"function":"y1_z2w2a3","args":["device=pc&platform=web&nov=27&eot=812","{}",1789171200000]}
```

Example successful host result:

```json
{"ok":true,"result":{"sign":"Y4wKk9D0kYX0R2LGQ04edYQ0YQX4h9kDsKGXaasha1a4DsKf","error":null}}
```

The only other permitted callback is `c1_r9k2m7`. Its argument order is
`[url, bytesData, buvid, platform, bodyJSON]`. The response is the original Go
object under `result`, including its `error` and `data` fields. `bytesData` is the
base64 string expected by the official wrapper; it is not raw ciphertext bytes.

The CLI has the same JSON contract:

```sh
./biliwasm /absolute/path/to/sign.wasm < request.json
```

The CLI reads exactly one complete JSON document until EOF, writes one JSON
document followed by a newline, and exits. Request data is never accepted through
command-line arguments. It is a Linux integration option; use the shared ABI for
Android integration.

## Pinned dependencies

| Dependency | Revision | License |
| --- | --- | --- |
| [wasm3](https://github.com/wasm3/wasm3) | `5fe766c933c7595d728d6172bb1a197607d85b4e` | MIT |
| [cJSON](https://github.com/DaveGamble/cJSON) | `v1.7.19`, commit `c859b25da02955fef659d658b8f324b5cde87be3` | MIT |
| [Go host ABI reference](https://github.com/golang/go/blob/go1.25.0/lib/wasm/wasm_exec.js) | Go `1.25.0` | BSD-3-Clause |

These sources are not downloaded or executed at runtime. Build against the exact
revisions above: the current wasm3 memory API differs from its older releases.
The release package must preserve third-party license notices and must obtain
the official WASM assets through the plugin's separately verified asset process.
The official WASM files are not redistributed in this source directory.

| Official asset | Purpose | SHA-256 |
| --- | --- | --- |
| `efae82c96a7eef44bee5.wasm` | Signing | `39bc0676953752c461197df592e1f5894f1a7492a29400c946e560fc109a8e2e` |
| `e461bfa6b471a22c06fc.wasm` | Response decoding | `3b499622e9a5f6181f0709d1485498f533428f9a30ae32694f6f6852ec47184c` |

The caller must verify the asset digest before selecting its path. The generic
native host receives a path and does not duplicate the adapter's asset trust
policy.

## Build

Run these commands on `test-env` or another explicitly authorized build host:

```sh
git clone https://github.com/wasm3/wasm3.git wasm3
git -C wasm3 checkout 5fe766c933c7595d728d6172bb1a197607d85b4e
git clone https://github.com/DaveGamble/cJSON.git cJSON
git -C cJSON checkout c859b25da02955fef659d658b8f324b5cde87be3

WASM3_ROOT="$PWD/wasm3" CJSON_ROOT="$PWD/cJSON" \
    sh /path/to/bilicomics/protocol/native/build.sh

TARGET=shared OUTPUT=libbiliwasm.so \
    WASM3_ROOT="$PWD/wasm3" CJSON_ROOT="$PWD/cJSON" \
    sh /path/to/bilicomics/protocol/native/build.sh
```

`CC`, `CFLAGS`, `LDFLAGS`, and `OUTPUT` select the target compiler and artifact.
The default flags disable wasm3 guarded memory and cap linear memory at 64 MiB.
Bounds checking remains active. The host separately limits JSON input to 16 MiB,
its request arena to 64 MiB, reference counts to 65,536 objects, and nested JSON
depth to 64. These are limits, not measured total process-memory guarantees.
The wasm3 stack allocation is 1 MiB.

`manifest.json` records the included libraries, exact digests, ABI targets, and
dynamic dependencies. The three Linux libraries require glibc 2.17 or newer and `libpthread.so.0`
in addition to the C and math libraries. The ARM32 build is ARMv6 hard-float;
it must not be selected for a soft-float KOReader process. The shared-library
export map exposes only `biliwasm_run` and `biliwasm_free`, including when the
toolchain links its own compiler runtime.

Linux ARM32 shared builds use `arm-relocations.ld` to place `.rel.plt` directly
after `.rel.dyn`. The link-time assertion preserves the adjacency required by
glibc versions predating the BZ 14341 fix. The build retains immediate binding
and GNU RELRO; it does not remove pthread dependencies or alter algorithms.
ARM Android, AArch64 and non-ARM builds do not receive this linker fragment.
The diagnostic loader used to investigate the old toolchain is not packaged.

`build-android.sh` builds the four Android ABI libraries using the verified
NDK r27c (`27.2.12479018`) and API 21 headers/stubs. Set `NDK_ROOT`,
`WASM3_ROOT`, `CJSON_ROOT`, and optionally `OUTPUT_ROOT`, then run it on the
remote build host. These libraries use Bionic `libc.so`, `libm.so`, and
`libdl.so`; they do not require glibc or `libpthread.so.0`. Their ELF load
segments have 16 KiB alignment, the SONAME is `libbiliwasm.so`, and API 21
emulated TLS avoids a native TLS segment. This does not by itself establish
that an Android app may load executable code from its plugin storage path.
The 32-bit `android-x86` output matches the official KOReader x86 APK's process
ABI; that APK does not contain x86-64 native libraries.

The host supports the Go `gojs` operations observed for the pinned modules,
including internal timers reached during larger decoder allocations. It pumps
scheduled Go resumes only while the requested callback is incomplete, with at
most 64 timers and five seconds of timer waiting. The native API remains
synchronous. Unsupported constructors and methods fail with a structured host
error. Changes to official module imports or behavior require a new
compatibility review and new golden fixtures.

## Remote verification evidence

The reproducible verifier is
[`native-verify.py`](../../../research/protocol/native-verify.py).
It compares actual CLI and shared-library execution against official-Node
results, including successful signing and a successful synthetic response
decode. Its malformed-module cases cover cleanup after parse, data-initializer,
and memory-limit failures. It also makes 100 successive FFI calls to detect
accumulating runtime memory.

```sh
python3 /path/to/research/protocol/native-verify.py \
    /tmp/bili-native-protocol-20260912 /tmp/bili-crypto-research-20260912
```

This is offline synthetic protocol verification. It does not establish live
authenticated API access, entitlement, purchase, image decoding, or target-device
compatibility.
