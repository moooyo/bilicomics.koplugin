# Portable protocol primitives

`libbilicrypto.so` provides P-256, AES-256 ECB blocks, PBKDF2-HMAC-SHA512, and
authenticated AES-GCM decryption without relying on KOReader's OpenSSL exports.
The shared library contains the pinned Mbed TLS primitive modules from
[`../legacy_v5`](../legacy_v5/README.md). It does not contain a TLS client.
The dependency uses the Apache-2.0 license option; its license and source
provenance remain in that directory.

The plugin loads the library through
[`../../portable_crypto.lua`](../../portable_crypto.lua). Platform selection is
shared with the WASM host through `platform.lua`; Android selects distinct
`android-*` packages and never a glibc library.

## ABI

All functions return `1` on success and `0` on failure. The caller allocates
every input and output buffer. No release function or retained handle is needed.
The export map hides Mbed TLS and toolchain-internal symbols.

[`bilicrypto.h`](bilicrypto.h) declares:

- `bili_p256_new(private32, public65)` generates a fresh private scalar and public point.
- `bili_p256_public(private32, public65)` derives and validates the public point.
- `bili_p256_derive(private32, public65, secret32)` validates both inputs and returns the ECDH X coordinate.
- `bili_aes256_ecb_encrypt(key32, input, length, output)` encrypts whole 16-byte blocks.
- `bili_aes256_ecb_decrypt(key32, input, length, output)` decrypts whole 16-byte blocks.

The two v5 declarations and their explicit input limits are in
[`../legacy_v5/bili_v5.h`](../legacy_v5/bili_v5.h): `bili_pbkdf2_sha512` and
`bili_aes_gcm_decrypt`. Authentication must succeed before GCM plaintext is
published to the caller.

P-256 scalars and coordinates are fixed-width big-endian bytes. A public point is
exactly `0x04 || X[32] || Y[32]`. The adapter checks `1 <= d < n`, rejects infinity,
out-of-field coordinates, and points outside P-256. Failed key and ECDH calls
clear their output buffers. Key and peer inputs must not overlap outputs. AES
input and output may be the same buffer; partial overlap is unsupported. ECB
does not add padding: the image protocol uses these blocks for its specified
CTR or CBC transformation.

Each call has independent Mbed TLS contexts. Linux and Android use the kernel
`getrandom` syscall, with interrupted reads retried. Only an unsupported syscall
falls back to `/dev/urandom` for older kernels. RNG failure fails the operation;
there is no deterministic or userspace fallback. The same CSPRNG supplies the
randomization callback for P-256 multiplication. Private MPI limbs, points,
expanded AES keys, and wrapper temporary buffers are cleared during cleanup.
This does not promise erasure of immutable Lua strings, compiler registers, or
every copy outside the native wrapper.

## Build

Run builds only on `test-env` or an explicitly authorized build host:

```sh
OUTPUT=libbilicrypto.so sh /path/to/native/portable/build.sh
```

`CC`, `CFLAGS`, `LDFLAGS`, `OUTPUT`, and `DEPENDENCY_DIR` are configurable.
`DEPENDENCY_DIR` defaults to the sibling `legacy_v5` directory, whose source list
and configuration define the pinned Mbed TLS build. A GCC- or Clang-compatible
compiler is required. Linux packages target a glibc 2.17 baseline; ARM32 is ARMv6
hard-float and must not be selected for a soft-float process.

For Linux ARM32 the build adds `../arm-relocations.ld`, keeping `.rel.plt`
adjacent to `.rel.dyn` for loaders affected by glibc BZ 14341. `BIND_NOW` and
GNU RELRO remain enabled. Other target families do not use this fragment.
The rebuilt ARM library passed bounded offline QEMU checks with Debian glibc
2.41 and toolchain glibc 2.20 using a separately corrected diagnostic loader;
this is not physical Kindle or firmware-image acceptance. No loader is shipped
with the plugin.

The reproducible Linux matrix builder is
[`portable-build-matrix.py`](../../../../research/protocol/portable-build-matrix.py).
It accepts the portable source directory, dependency directory, Zig executable,
and output directory. It inspects the ELF files and executes the x86-64
primitive verifier. Cross-compilation and ELF inspection alone do not establish
ARM device execution. An optional fifth argument supplies a verified Android
NDK root and adds all three Android packages to the same build matrix.

Android builds use a verified Android NDK Clang compiler and the same sources:

```sh
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang" \
    LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -Wl,-soname,libbilicrypto.so" \
    OUTPUT=libbilicrypto.so sh /path/to/native/portable/build.sh
```

Use `armv7a-linux-androideabi21-clang` for `android-armeabi-v7a` and
`x86_64-linux-android21-clang` for `android-x86_64`. The build manifest records
which artifacts are actually included and their verification scope. An NDK
build is not a claim of execution in an Android KOReader process.

## Verification

[`portable-verify.py`](../../../../research/protocol/portable-verify.py) checks
NIST SP 800-38A AES-256 ECB vectors, in-place decryption, input rejection,
P-256 public keys and ECDH secrets against Node's independent implementation,
random key generation, scalar boundaries, malformed peers, and zeroed failed
ECDH outputs. All fixtures are synthetic and contain no user credentials.
Separate image integration checks compare the actual official browser wrapper
with synthetic encrypted containers; see the protocol research evidence.
