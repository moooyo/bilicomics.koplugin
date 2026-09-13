# Portable protocol primitive evidence

All compilation, runtime checks, and ELF inspection described here ran through
`ssh test-env`. No local Windows verification was performed.

## Selected implementation

The release uses Mbed TLS 3.6.7 at commit
[`068ff080b369adfac81509f9b57b2afabaf82dc5`](https://github.com/Mbed-TLS/mbedtls/commit/068ff080b369adfac81509f9b57b2afabaf82dc5).
The dependency archive, source subset, Apache-2.0 license selection, and
reproducible zeroization-only patches are recorded in
[`dependency.json`](../../bilicomics/protocol/native/legacy_v5/dependency.json).
One primitive library is used for P-256, AES-256 ECB, PBKDF2-HMAC-SHA512, and
authenticated AES-GCM decryption.

The P-256 wrapper follows the upstream API contracts:

- Import the 32-byte private scalar as unsigned big-endian and enforce `1 <= d < n`.
- Require the exact 65-byte uncompressed point representation, then perform a
  separate curve validation after import. Import alone is not validation.
- Supply a non-null cryptographic RNG callback to scalar multiplication.
- Reject the point at infinity before writing a fixed 32-byte big-endian X coordinate.
- Use independent initialized contexts per call and free them on every exit.

These choices follow the official
[`ecp.h` API](https://github.com/Mbed-TLS/mbedtls/blob/068ff080b369adfac81509f9b57b2afabaf82dc5/include/mbedtls/ecp.h),
[`ecdh.c` implementation](https://github.com/Mbed-TLS/mbedtls/blob/068ff080b369adfac81509f9b57b2afabaf82dc5/library/ecdh.c#L93),
and [`bignum.h` encodings](https://github.com/Mbed-TLS/mbedtls/blob/068ff080b369adfac81509f9b57b2afabaf82dc5/include/mbedtls/bignum.h#L539).
AES decrypt uses a decryption key schedule, as required by the official
[`aes.h` API](https://github.com/Mbed-TLS/mbedtls/blob/068ff080b369adfac81509f9b57b2afabaf82dc5/include/mbedtls/aes.h).

Mbed TLS clears owned MPI limbs and key contexts when freed. Its unmodified
`ecp_mul_comb_after_precomp` function leaves the recoded scalar stack array `k`
uncleared. One included patch adds `mbedtls_platform_zeroize(k, sizeof(k))` at
the common cleanup label. A second patch clears GCM's GHASH subkey and
multiplication arrays and the calculated authentication tag. Neither changes
arithmetic, input validation, or return values. The wrapper also wipes generated scalar buffers and failed ECDH
outputs. No guarantee is made about immutable Lua strings, compiler registers,
or process memory outside these explicitly owned buffers.

## Rejected initial candidate

An initial generic-C prototype used official micro-ecc commit
[`541b3a78026420a3e369c4c9281c396b5e531113`](https://github.com/kmackay/micro-ecc/commit/541b3a78026420a3e369c4c9281c396b5e531113)
and tiny-AES-c commit
[`23856752fbd139da0b8ca6e471a13d5bcc99a08d`](https://github.com/kokke/tiny-AES-c/commit/23856752fbd139da0b8ca6e471a13d5bcc99a08d).
The licenses are BSD-2-Clause and Unlicense, respectively. Neither candidate
is included in the final library or vendored runtime source.

Remote checks found that micro-ecc public-key computation failed for valid
P-256 scalars `1`, `n - 1`, and `n - 2`. This was reproduced after restoring
unmodified upstream `uECC.c` and `curve-specific.inc`, so it was not caused by
the prototype's buffer-cleanup edits. The raw boundary results are in
[`portable-rejected-micro-ecc-boundaries.json`](portable-rejected-micro-ecc-boundaries.json).
The same 49 boundary scalars succeeded with Mbed TLS, recorded in
[`portable-mbedtls-boundaries.json`](portable-mbedtls-boundaries.json).
This was a local compatibility finding for the tested configuration, not a
claim about every possible micro-ecc build. The final implementation avoids
repairing elliptic-curve arithmetic in the plugin.

## Release verification

The final Linux x86-64 library was built with Zig 0.13.0 for a glibc 2.17
baseline. [`portable-linux-x86_64-verification.json`](portable-linux-x86_64-verification.json)
records its exact SHA-256 and these passing checks:

- 56 public-key and ECDH cases compared with Node's independent P-256 implementation.
- 24 fresh OS-random private keys with matching public keys and no duplicate scalar.
- Scalars `1`, `2`, and `n - 1`, four invalid scalar boundaries, five malformed peers,
  and cleared output on failed ECDH operations.
- Four AES-256 ECB blocks from NIST SP 800-38A section F.1.5, in-place decrypt,
  zero-length behavior, and invalid-argument rejection.

The AES reference is
[NIST SP 800-38A](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38a.pdf).
The reproducible scripts are `portable-verify.py`, `portable-boundaries.py`,
and `portable-build-matrix.py`. The separate v5 primitive verifier checks
PBKDF2, authenticated GCM, tamper rejection, input limits, and official
synthetic v5 image fixtures against the final combined library. Its 58 passing
checks and release hash are recorded in
[`portable-v5-final-verification.json`](portable-v5-final-verification.json).

## Targets and limits

[`portable/manifest.json`](../../bilicomics/protocol/native/portable/manifest.json)
records all six packaged libraries and their hashes. Linux x86-64 executed the
offline primitive checks. Linux ARMv6 hard-float and AArch64 have successful
cross-compilation and ELF inspection only.

Android `arm64-v8a`, `armeabi-v7a`, and `x86_64` were built with the verified
Android NDK r27c for API 21. Every LOAD segment is aligned to 16 KiB. Their
dynamic dependencies are Android `libdl.so` and `libc.so`; no glibc or OpenSSL
dependency is present. Android libraries were not executed on a device or
emulator. Separate platform selection prevents an Android process from loading
the packaged glibc library.

These are offline synthetic protocol and primitive results. They do not prove
live account access, entitlement, purchases, or target-device compatibility.
