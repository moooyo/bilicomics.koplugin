# PC reader m1 encoding and native P-256 support

Research and implementation date: 2026-09-12.

The current PC reader sends a Base64-encoded raw P-256 public key as the `ImageToken` request's `m1`. Its private material is a Base64-encoded JSON Web Key, retained for image conversion. An unrelated local field is also named `m1`; that field contains the private JWK, not the wire public key.

The new `bilicomics/protocol/ecdh.lua` implements this key material and raw P-256 shared-secret derivation. It prefers KOReader's LibreSSL symbols and falls back to the separately packaged `libbilicrypto` provider. Both providers passed remote Linux x86_64 interoperability checks. The official Android arm64 build does not expose the required LibreSSL symbols; it needs a compatible packaged portable binary, or it reports unavailable capability. No Android execution is claimed.

## Evidence boundaries

- All downloads, source processing, binary inspection, and runtime checks used `ssh test-env`, under `/tmp/bili-m1-nc9Uf7`.
- No local verification ran. No account session, login, purchase, protected API request, or manga image was used.
- The downloaded Bilibili JavaScript and WASM were not executed. Reader string references were resolved by parsing its literal table and evaluating the documented rotation checksum as arithmetic in a separate Python script.
- Runtime checks used synthetic ephemeral key pairs, official KOReader Linux binaries, and Node WebCrypto. Android was inspected as an ELF artifact; no Android runtime was emulated or tested.
- The key module is not a replacement for request signing, `m2`, encrypted API decoding, or image conversion. These remain separate dependencies.

## First-party source identity

The [current reader page](https://manga.bilibili.com/mc36215) still referenced these assets when fetched:

| Resource | SHA-256 |
| --- | --- |
| [reader.1ffe7bbf9d.js](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/reader.1ffe7bbf9d.js) | `3faf2f5de5c77884669dc749b0123343313c973d5eb2fc9edee1911cae191f1e` |
| [bili.9409128c39.js](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/bili.9409128c39.js) | `8202851c77a8e8a58dab2fc2529542c09b6b6c296e26fe78390ee1206aae6908` |

The reader also references `vendors.c68379b8e3.js`. It was not needed for this bounded inspection.

Source locators below are zero-based UTF-16 character offsets in the original reader asset, not line numbers:

| Marker | Offset |
| --- | ---: |
| `class _0x3c48cc` | 923594 |
| `}[_0x151214(0x20e)]()` (`generateECDHKeyPair`) | 926157 |
| `}[_0x151214(0x19bf)]` (`getM1AndKey`) | 927392 |
| `}[_0x151214(0x572)]` (`loadToken`) | 931777 |

The literal table has 20,801 entries. Its rotation is 202 entries and its checksum is `0xe1bcb`. The decoder subtracts `0x72` from its argument. Relevant resolved entries include:

| Index | Value |
| --- | --- |
| `0x20e` | `generateECDHKeyPair` |
| `0x19bf` | `getM1AndKey` |
| `0x3b95` | `generateKey` |
| `0x196a` | `raw` |
| `0x28fd` | `jwk` |
| `0x16a8` | `publicKey` |
| `0x2ff6` | `privateKey` |
| `0x1fc9` | `deriveKey` |
| `0x3781` | `deriveBits` |
| `0x4661` | `getImageToken` |
| `0x620` | `y6_buo6u2` |

## Key encoding contract

`generateECDHKeyPair` calls `window.crypto.subtle.generateKey` with algorithm `ECDH`, curve `P-256`, extractable `true`, and usages `deriveKey` and `deriveBits`.

The original call excerpt is:

```javascript
_0x550be5[_0x33a287(0x3b95)]({'name':_0x12eb58[_0x33a287(0x4c01)],'namedCurve':_0x12eb58[_0x33a287(0x4f06)]},!0x0,[_0x12eb58[_0x33a287(0x5006)],_0x33a287(0x3781)])
```

The local constants resolve through `_0x553e7a.pugZw` to `ECDH`, and through `_0x553e7a.bjILf` directly to `P-256`. These are source substitutions, not a reimplemented generator.

`getM1AndKey(imagePath)` exports the public key as `raw`, then the private key as `jwk`. The public export is `_0xf77fd6`; the private JWK is `_0x233edc`. It JSON-encodes the private JWK and Base64-encodes both representations. The exact encoding excerpt is:

```javascript
_0x21dce5=JSON[_0x452f1d(0x45a0)](_0x233edc),_0x151e70=_0x4ae2cc[_0x452f1d(0x128e)](btoa,_0x21dce5),_0x6168ec=_0x4ae2cc['DRFdk'](btoa,String['fromCharCode']['apply'](null,new Uint8Array(_0xf77fd6)))
```

It stores `{m1: privateJwkBase64, key: publicRawBase64, url: imagePath}` in `_m1Info`, then returns `publicRawBase64`. Consequently, the variable name `m1` alone is insufficient to determine which representation is involved.

| Value | Exact representation | Destination |
| --- | --- | --- |
| Public key / wire `m1` | Standard padded Base64 of 65 bytes: `0x04 || X[32] || Y[32]` | `ImageToken` body |
| Private material / local `_m1Info[].m1` | Standard padded Base64 of compact JSON for the private JWK | Image conversion context |
| JWK `x`, `y`, `d` | Unpadded Base64url of 32-byte unsigned big-endian values | Inside the private JWK |

The public wire value is 88 Base64 characters. It is not a DER SubjectPublicKeyInfo value, a PEM key, a JWK, or a bare private scalar.

The private JWK contains `key_ops`, `ext`, `kty`, `x`, `y`, `crv`, and `d`. The observed generation options require `key_ops: ["deriveKey", "deriveBits"]`, `ext: true`, `kty: "EC"`, and `crv: "P-256"`. The implementation emits these fields and the same numeric encodings. Imported `key_ops` are checked as the two unique usages, allowing either order. Its fixed compact JSON property order is an implementation choice; JSON object equality does not depend on the engine-specific property order of an exported JWK.

## ImageToken and conversion call chain

`loadToken` obtains `getM1AndKey(_imagePath)`, then passes its return value to `getImageToken([_imagePath], returnedPublicKey)`.

The wrapper's exact request body excerpt is:

```javascript
{'urls':JSON[_0x599bff(0x45a0)](_0x3d1362),'m1':_0x178af1}
```

The wrapper posts to `/twirp/comic.v1.Comic/ImageToken`. `urls` is a JSON-encoded path array held in a string, not an array-valued JSON property. The main reader passes one path at this call site; the wrapper itself accepts an array. The normal shared protected-endpoint request path still applies, including the independently implemented signing and protected-response handling.

The main reader consumes `data[0].token`, `url`, `complete_url`, and the exact spelling `hit_encrpyt`. It initially assigns `complete_url + "&code=" + _comicCode`; its `http://` normalization branch then assigns the original `complete_url` with that prefix replaced by `https://`. This is the actual branch order, not a generalized URL-construction recommendation.

For encrypted images, the reader finds the public-key association by complete URL, then obtains the matching private JWK Base64 from `_m1Info`. It calls:

```javascript
window[_0x19b59c(0x620)](_0x19d7b4,_0x36c4b6,_0x181b16[_0x19b59c(0x3093)])
```

The resolved function is `window.y6_buo6u2(completeUrl, privateJwkBase64, imageIndex)`. The false `hit_encrpyt` branch acquires a normal Blob. Generating `m1` does not establish that the encrypted branch can be replaced by a generic ECDH decrypt operation.

In shared module `59HX`, export `T` maps to the asynchronous image helper `_`. That helper loads [dda35c98742815151e46.wasm](https://s1.hdslb.com/bfs/manga-static/manga-pc/dda35c98742815151e46.wasm), calls `a1_h17mj9(e,t,r,o)`, parses the UTF-8 JSON result, and Base64-decodes its `data` field to bytes. Its exact call excerpt is:

```javascript
const a=i.a1_h17mj9(e,t,r,o),c=(new TextDecoder).decode(a);
```

The fourth WASM argument and the intervening environment-dependent image wrapper are outside this key-generation implementation. No image conversion success is claimed here.

## Existing KOReader native support

Inspected source revisions:

- KOReader: `c5c6f2d39264b0248ee8216780f842b0ea3c9488`.
- koreader-base: `dd0e2522a1c2535c49b69f151a65fd506663c3a7`.

The existing [ffi/crypto.lua](https://github.com/koreader/koreader-base/blob/dd0e2522a1c2535c49b69f151a65fd506663c3a7/ffi/crypto.lua#L7) begins with:

```lua
local ffi = require("ffi")
require("ffi/crypto_h")
local libcrypto = ffi.loadlib("crypto", "57")
```

This wrapper provides PBKDF2-HMAC-SHA1 and AES ECB decryption helpers. The corresponding [crypto declaration file](https://github.com/koreader/koreader-base/blob/dd0e2522a1c2535c49b69f151a65fd506663c3a7/ffi-cdecl/crypto_decl.c) declares no EC or ECDH functions. Reusing its Lua module alone does not provide a P-256 key generator.

The build explicitly includes [LibreSSL because ffi/crypto needs it](https://github.com/koreader/koreader-base/blob/dd0e2522a1c2535c49b69f151a65fd506663c3a7/cmake/CMakeLists.txt#L344). Its [LibreSSL build definition](https://github.com/koreader/koreader-base/blob/dd0e2522a1c2535c49b69f151a65fd506663c3a7/thirdparty/libressl/CMakeLists.txt) selects LibreSSL 4.3.2 and installs `crypto` version 57 for non-monolithic builds. No built-in micro-ecc dependency was found in the inspected KOReader or koreader-base sources.

LibreSSL's [official 4.3.2 source archive](https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-4.3.2.tar.gz) has SHA-256 `edf01aee24c65d69e6a9efcb9d44bcda682ff9d4f3bbbd95e794e1dfa90847b5`. Its `include/openssl/ec.h`, `include/openssl/bn.h`, and `crypto/crypto.sym` declare/export the P-256 operations needed for generation and validation, including `EC_KEY_generate_key`, `EC_POINT_point2oct`, `BN_bn2binpad`, and `ECDH_compute_key`.

### Official Linux artifact

The [Linux x86_64 v2026.07.1 archive](https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-linux-x86_64-v2026.07.1.tar.xz) has SHA-256 `299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0`.

Its `lib/koreader/libs/libcrypto.so.57` has SHA-256 `577a2577f9aecfeced0a5f0fa4b652ea1e8f24ec2e3a95df7a54a1de6d949c10`. `nm -D --defined-only` confirmed the required EC symbols. This actual release library was used for the runtime checks, not the host's unrelated OpenSSL library.

### Official Android artifact

The [Android arm64 v2026.07.1 APK](https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-android-arm64-v2026.07.1.apk) has SHA-256 `89cecbe06eacd2ff7d91e37152d6beeb52809f2ca38060b6515ed8b00d152412`.

It contains `lib/arm64-v8a/libkoreader-monolibtic.so`, SHA-256 `30beab2623c0e20681d2a9a65fbace839bb1b642c2b853a65ba0e9c022fb4bb5`. It contains no separate `libcrypto.so` artifact. Dynamic symbol inspection found none of `EC_KEY_new_by_curve_name`, `EC_KEY_generate_key`, `EC_KEY_check_key`, `EC_KEY_get0_group`, `EC_KEY_get0_private_key`, `EC_KEY_get0_public_key`, `EC_POINT_point2oct`, `BN_bn2binpad`, `ECDH_compute_key`, or `OBJ_txt2nid`.

This matches the source: [ffi/loadlib.lua](https://github.com/koreader/koreader-base/blob/dd0e2522a1c2535c49b69f151a65fd506663c3a7/ffi/loadlib.lua#L24) redirects `crypto` to the monolithic library when present. The [monolithic target](https://github.com/koreader/koreader-base/blob/dd0e2522a1c2535c49b69f151a65fd506663c3a7/thirdparty/cmake_modules/koreader_targets.cmake#L316) exports a C-declaration allowlist. The [export generator](https://github.com/koreader/koreader-base/blob/dd0e2522a1c2535c49b69f151a65fd506663c3a7/utils/gen_linker_exports.sh) makes other symbols local.

A Lua FFI declaration cannot expose a symbol omitted from the dynamic export table. Android needs either an upstream export change and a rebuilt KOReader package, or an independently packaged native provider. The implementation now supports the latter through `bilicomics/protocol/portable_crypto.lua`; the independent native-library task owns its source, build, entropy, ABI, and packaging evidence. A Linux portable-binary check does not establish Android execution.

The Android artifact does export the existing EVP AES ECB functions, including `EVP_aes_192_ecb`, and the existing decryption/context functions. It does not expose low-level `AES_set_decrypt_key`, `AES_decrypt`, or `AES_ecb_encrypt` in the inspected symbol table. These AES observations do not change its unavailable EC capability.

## Implemented Lua interface

`bilicomics/protocol/ecdh.lua` exports:

| Function | Result |
| --- | --- |
| `capability()` | `{available, provider, curve? ,reason?, error?}`; native initialization is lazy and unavailable symbols produce an `image_key_exchange` capability error |
| `newKey()` | `{m1, private_key}` or `nil, error`; `m1` is public raw Base64 and `private_key` is private JWK JSON Base64 |
| `deriveSecret(private_key, peer_raw65)` | A 32-byte raw P-256 shared x-coordinate or `nil, error`; no KDF is applied |
| `serialize(key)` | Validated compact JSON string for transient IPC, or `nil, error` |
| `deserialize(text)` | A new pure-string key table after format and native key-pair validation, or `nil, error` |

LibreSSL generation uses its native random key generation and frees the EC object after export. The exported scalar buffer is zeroed. Validation checks canonical Base64/Base64url, the expected JWK fields and usages, public-coordinate consistency, and `EC_KEY_check_key` after native reconstruction. Scalar BIGNUMs are released with `BN_clear_free`. Derivation rejects malformed, compressed, hybrid, infinite, off-curve, or out-of-range peer points, then calls `ECDH_compute_key` with a null KDF and requires exactly 32 bytes. Native scalar and shared-secret buffers are zeroed after use.

The portable provider exposes `bili_p256_new`, `bili_p256_public`, and `bili_p256_derive`, each returning one on success and zero on failure. Its public-key operation independently recomputes the public point to validate a private JWK pair. ECDH uses caller-owned 32-byte scalar/shared buffers and a 65-byte uncompressed peer representation. Lua clears the mutable scalar/shared buffers on both success and failure. Native curve validation remains mandatory in the portable implementation.

No native pointer, FFI handle, process-local address, or RNG state crosses IPC. The two returned strings are still private transient credentials. Do not store them in SQLite, descriptors, durable jobs, settings, diagnostics, or logs. Lua strings are immutable; this module cannot promise immediate zeroization of all string copies. Worker integrations must discard these transient values when their acquisition context ends.

The module's errors use `bilicomics/protocol/errors`; all cryptographic failures are marked `transmitted=false`. JSON decoding uses `bilicomics/protocol/json`. Base64 uses KOReader's bundled LuaSocket MIME codec. The primary loader follows `ffi.loadlib("crypto", "57")`, including KOReader's monolithic redirection. If the required symbols are unavailable, it calls the portable module's `library()` loader. That loader selects a plugin-packaged binary by OS/CPU ABI, with separate Android targets. It does not use an arbitrary platform crypto library or substitute a Linux glibc binary for a missing Android binary.

## Remote verification

The production ECDH module was run under the official release's `luajit`, with its normal `setupkoenv` and native libraries. Final tests used the real protocol `json.lua`, `errors.lua`, `portable_crypto.lua`, and `platform.lua`, plus the bundled RapidJSON and MIME implementations. The isolated integration tree is `/tmp/bili-m1-nc9Uf7/production`.

The same 61-assertion suite passed with `provider=libcrypto` and with `provider=libbilicrypto`. It covers capability/selection, generation/encodings/usages, fresh randomness, serialization, malformed/oversized JSON, extra fields, noncanonical Base64, mismatched public/private material, zero/out-of-range scalars, incorrect curve/usages, malformed/off-curve peers, unavailable symbols, and the official v8 synthetic image fixture's expected raw shared secret. No real image or account data is present in that fixture.

Additional independent Node fixtures for scalar `1`, scalar `2`, and scalar `n-1` matched public-key validation and shared-secret derivation on both providers. A fresh LuaJIT process using LibreSSL restored a portable-generated serialized key and reproduced the same serialization.

Lifetime instrumentation verified eight cleared 32-byte buffers and 19 native allocations matched by 19 frees on the LibreSSL path, with no duplicate finalizers after collection. The portable path verified eleven cleared 32-byte buffers. A simulated missing Android x86_64 artifact was rejected without attempting to load the packaged Linux binary; this is a loader-selection check, not Android execution.

The tested release portable x86_64 library has SHA-256 `f18e319f168904d07cf1a4e537ce67342a7eea49da2d6a4ca8e1c10b52608f79`. All listed provider, boundary, lifetime, missing-artifact, and process-transfer checks were repeated against that final artifact. Other CPU and Android artifacts require their own recorded checks in the native-library task.

`webcrypto-crosscheck.js` then imported a key generated by the production Lua module and confirmed:

```json
{"public_raw_bytes":65,"public_prefix":4,"wire_m1_base64_chars":88,"private_scalar_bytes":32,"ecdh_bytes":32,"webcrypto_raw_roundtrip":true,"webcrypto_ecdh_match":true}
```

The ECDH comparison used the same exported Lua key material in LibreSSL and WebCrypto with a synthetic peer key. No secret key values were printed in the test results. Final evidence includes `ecdh-real-libcrypto-test-release-result.txt`, `ecdh-real-libbilicrypto-test-release-result.txt`, both `ecdh-boundary-*-release-result.txt` files, `ecdh-lifetime-test-release-result.txt`, `ecdh-portable-lifetime-test-release-result.txt`, `ecdh-missing-platform-test-release-result.txt`, and `ecdh-worker-production-test-release-result.txt` in the remote investigation directory. Earlier encoding/source evidence remains in `lua-webcrypto-result.json`, `native-crosscheck-result.json`, and `android-symbol-result.json`.

This establishes public/private key encoding, raw shared-secret derivation, and both tested Linux provider paths. Full encrypted-image assembly and other image versions belong to the image-crypto task. These checks do not validate an authenticated ImageToken exchange, server acceptance, physical e-ink targets, or Android execution.
