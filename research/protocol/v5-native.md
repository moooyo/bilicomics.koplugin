# Native v5 cryptography verification

Date: 2026-09-12. All downloads, compilation, execution, and validation in this
record ran through `ssh test-env`. No local build, runtime probe, or validation
suite was run.

## Implementation

The native v5 primitive wrapper lives in
`bilicomics/protocol/native/legacy_v5`. It uses the pinned Mbed TLS 3.6.7 source,
commit `068ff080b369adfac81509f9b57b2afabaf82dc5`, from the official upstream
repository. The codeload archive SHA-256 is
`ca6bd316bbec49ef20088f39b8755fcaec0b7e45781506de55b17cd191ae6937`.
The complete dependency pin, selected Apache-2.0 license, 80-file source subset,
source hashes, reproducible refresh script, configuration, and zeroization
patches are retained next to the wrapper. The patches clear the recoded P-256
scalar array, GHASH subkey/multiplication arrays, and temporary computed tag;
they do not change the cryptographic algorithms.

The P-256 and AES-ECB backend shares the dependency and links the v5 functions
into its single `libbilicrypto.so`. Node is used solely to generate verification
references; it is not a KOReader or Android runtime requirement.

The v5 protocol takes a raw 32-byte ECDH secret and applies PBKDF2-HMAC-SHA512
with 100000 iterations, a 16-byte salt, and 32 output bytes. AES-256-GCM uses a
16-byte IV, the same salt as its 16-byte AAD, and a 128-bit tag. Only the first
`min(payload_length, 30 * 1024 + 16)` bytes form the authenticated encrypted
prefix; any remaining payload is appended unchanged by the image layer.

## Executed verification

The isolated remote workspace is `/tmp/bili-legacy-v5-20260912`. The full
upstream archive was downloaded and SHA-256-checked before extraction. A second
build in `minimal/` used only the 80 files in the maintained vendor list, proving
that omitted upstream files are not needed by this configuration on the tested
host. Compiler: GCC 14.2.0; runtime: x86_64 Linux; Node: v20.19.2.

The primitive verification command was:

```powershell
ssh test-env 'cd /tmp/bili-legacy-v5-20260912 && python3 v5-verify.py minimal/libbilicrypto-v5.so --official-fixtures /tmp/bili-image-vm-chain/image-legacy-fixtures.json'
```

The maintained `build.sh` was used with `CFLAGS=-Werror`, and produced no compiler
warnings. The standalone `.so` was 34464 bytes, with SHA-256
`03ebe06b811959231befa8c10118e5682b9e469a645216fff56ab6e042b537c7`.
Its dynamic symbol table exposed exactly `bili_pbkdf2_sha512` and
`bili_aes_gcm_decrypt`. The final run completed in 0.601 seconds on the remote
host; this is not an ARM-device performance estimate.

All 58 cases passed:

| Group | Cases |
| --- | ---: |
| Fixed upstream PBKDF2-SHA512 answers, including embedded NUL | 4 |
| NIST GCM answers, AES-128/192/256, empty message, non-12-byte IV | 7 |
| Node PBKDF2 references, 100000 rounds, binary inputs, multiple output blocks | 5 |
| Node GCM references, including 16-byte IV/AAD and 30 KiB prefix | 5 |
| Modified key, IV, AAD, ciphertext, and tag; output sentinel unchanged | 5 |
| Invalid PBKDF2 pointers, limits, iterations, and aggregate work | 11 |
| Invalid GCM pointers, sizes, and tag lengths | 16 |
| Overlapping PBKDF2 output, in-place GCM output, NULL empty output | 3 |
| Official-script v5 synthetic PNG fixtures, small and large | 2 |

The fixed PBKDF2 values are in the pinned upstream
[PKCS5 test suite](https://github.com/Mbed-TLS/mbedtls/blob/068ff080b369adfac81509f9b57b2afabaf82dc5/tests/suites/test_suite_pkcs5.data).
The GCM values come from the NIST vectors reproduced in the pinned upstream
[GCM self-test](https://github.com/Mbed-TLS/mbedtls/blob/068ff080b369adfac81509f9b57b2afabaf82dc5/library/gcm.c).

The two synthetic image fixtures were generated and fully processed by the
unmodified official `c_f49` JavaScript helper in the separate image-oracle
workspace. Their expected PNG lengths are 92 and 41758 bytes. This verification
derived each fixture's AES key using the new native PBKDF2 function, decrypted
the prefix using the new native GCM function, and compared both the decoded
prefix and unchanged tail byte for byte. No real user private key or service
credential is present in the results file.

`v5-verification-results.json` preserves the machine-readable counts, hash,
duration, and host scope. Node's OpenSSL implementation rejects a 1024-byte IV,
so the Node cross-reference set uses a 128-byte IV for its long-IV case; the
wrapper's documented maximum remains 1024 bytes, with values above it rejected.

## Remaining platform gates

The GCC standalone artifact requires host GLIBC symbols through 2.25; it is not
the production Linux baseline build. The portable backend owns the final
x86_64/ARM/AArch64 cross-build outputs and their GLIBC 2.17 inspection record.
Android requires a separate NDK/Bionic build and a demonstrated shared-library
loading route. This record contains no Android, ARM QEMU, or target-device run.
It does not claim constant-time software AES or a cryptographic certification.
