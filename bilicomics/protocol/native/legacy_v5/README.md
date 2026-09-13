# Native v5 primitives

This directory supplies the PBKDF2-HMAC-SHA512 and authenticated AES-GCM
primitives used by the v5 image decoder. Its sources are linked into the same
`libbilicrypto.so` as the portable P-256/AES-ECB backend. Node.js, Python, system
OpenSSL, and system Mbed TLS are not device runtime dependencies.

## Dependency and license

Mbed TLS 3.6.7 is pinned to commit
`068ff080b369adfac81509f9b57b2afabaf82dc5`. `dependency.json` records the exact
archive URL, SHA-256, and selected Apache-2.0 license. The upstream offers
Apache-2.0 OR GPL-2.0-or-later; this distribution selects Apache-2.0 and retains
the complete license, original copyright notices, and this directory's `NOTICE`.

The 80 vendored files are a dependency subset of the unmodified upstream
headers and the translation units in `sources.list`, with explicit zeroization
patches to `ecp.c` and `gcm.c`. `vendor-files.list` defines the subset;
`upstream-sha256.json` and `vendored-sha256.json` record the before/after file
hashes. The subset includes P-256/BIGNUM for the sibling portable backend.
`bili_mbedtls_config.h` enables only AES, GCM, SHA-512, HMAC, PBKDF2, and P-256.
AES uses immutable ROM tables, without architecture-specific assembly.

The patches clear a stack array holding the recoded private scalar at the common
cleanup label, the temporary GHASH subkey, GHASH multiplication arrays, and the
temporary computed authentication tag.
They do not change cryptographic calculations, key validation, or authentication.
The pinned upstream PBKDF2 implementation already clears its intermediate hash
arrays, and the upstream free functions clear owned key contexts.

## C interface

`bili_v5.h` is the public ABI. Both functions return `1` on success and `0` on
failure. The caller owns every input/output buffer and must allocate the
documented output capacity. NULL is accepted only for empty optional input or
empty GCM output. Every call has independent contexts.

- `bili_pbkdf2_sha512`: binary password/salt, HMAC-SHA512, explicit iterations
  and output length. Password, salt, and output each have a 1024-byte limit.
  Iterations are in `1..1000000`, and total work is limited by
  `iterations * ceil(outlen / 64) <= 1000000`. Zero output length is rejected.
- `bili_aes_gcm_decrypt`: AES-128/192/256; separate ciphertext and exact 16-byte
  authentication tag; IV length `1..1024`; AAD at most 1 MiB; ciphertext at most
  64 MiB. A valid empty ciphertext is accepted.

Both functions calculate into a private temporary buffer and copy only after
success. Failures leave the caller's output unchanged. Input/output overlap is
supported, including in-place GCM decryption and output overlapping PBKDF2 salt.
Temporary outputs are zeroized before freeing on every cleanup path; GCM key
contexts are freed before the plaintext allocation. Authentication uses the
upstream `mbedtls_gcm_auth_decrypt` implementation and its constant-time tag
comparison. The wrapper does not expose unauthenticated plaintext.

The v5 caller supplies the raw 32-byte P-256 ECDH result as the password, the
16-byte cpx salt, exactly 100000 iterations, and a 32-byte output length. The
GCM IV and AAD are each 16 bytes, and the AAD equals the PBKDF2 salt.

## Reproducible build

Use `ssh test-env`, unless local verification is explicitly authorized for the
current task. To refresh the dependency on the remote host, copy this directory
there and run `python3 vendor-refresh.py` inside it. The script rejects any
archive whose SHA-256 differs from the pin, copies only `vendor-files.list`,
and applies the maintained patches. `--archive /remote/path/archive.tar.gz` uses
a previously downloaded archive. `--check` verifies the checked-in subset
without downloading or changing files.

The standalone build is useful for remote primitive verification:

```powershell
ssh test-env 'cd /remote/path/legacy_v5 && python3 vendor-refresh.py --check && CFLAGS=-Werror sh build.sh'
```

The default output is `libbilicrypto-v5.so`; it is not a separately packaged
device dependency. `CC` must name one compiler executable or wrapper, and
`CFLAGS`, `LDFLAGS`, and `OUTPUT` can be supplied for the target build. The
standalone export map exposes only the two v5 functions.

The production `../portable/build.sh` consumes `sources.list`. Integration must
pass `-DMBEDTLS_CONFIG_FILE='"bili_mbedtls_config.h"'` and include this directory,
`vendor/mbedtls/include`, and `vendor/mbedtls/library`. Its export map must include
both v5 functions. No other Mbed TLS API should be exported from the resulting
library. Linking is entirely from the vendored C sources and the target libc.

## Verification and deployment scope

`research/protocol/v5-verify.py` checks fixed upstream PBKDF2 and NIST GCM
answers, deterministic Node reference cases, authentication corruption,
boundary rejection, overlapping output, and optional official-script synthetic
v5 image fixtures. `v5-fixtures.js` is a verification-only reference generator.
The exact remote commands and results are in `research/protocol/v5-native.md`.

The standalone GCC x86_64 result is a remote test artifact, not a device
package: its host libc references include GLIBC 2.25. Production Linux outputs
must use the maintained target build and their recorded libc baseline. Android
requires an Android NDK/Bionic build and an independently verified loading
route; Linux glibc artifacts cannot satisfy that requirement. Cross-compilation
and ELF inspection alone do not establish ARM or Android device execution.

The portable software AES implementation uses lookup tables. The upstream
security model does not promise complete resistance to timing/cache side
channels for software block ciphers. Neither this wrapper nor its fixed-answer
tests establish a constant-time implementation or target-device security
certification. See the pinned upstream
[security policy](https://github.com/Mbed-TLS/mbedtls/blob/068ff080b369adfac81509f9b57b2afabaf82dc5/SECURITY.md).
