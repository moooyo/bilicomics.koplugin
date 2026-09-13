# Verified image conversion contract

## Scope and provenance

This note describes offline interoperability research using the public official
reader artifacts and newly generated keys and images. It does not establish
successful live downloading or access to any paid episode. No account cookies,
purchase, coupon use, or challenge result were involved.

The version 8 oracle was the unmodified official image WASM:

- URL: `https://s1.hdslb.com/bfs/manga-static/manga-pc/dda35c98742815151e46.wasm`
- SHA-256: `f96b11772a59ba8321755fe94e145b175f40354638405442fb2d40a8a8e2dfc8`
- Callback: `a1_h17mj9(privateJwkBase64, responseUint8Array, imageUrl, imageIndex)`.
- Result: `Uint8Array` containing UTF-8 JSON with `code`, `bcode`, `msg`, and
  `data`; successful `data` is the image bytes encoded as standard Base64.

The outer official reader JS adds its own `time` and `uuid` fields. They are not
part of this WASM callback's successful return value.

The legacy oracle is `c_f_49` in the official reader's outer script:
`https://i0.hdslb.com/bfs/activity-plat/static/20260129/79521623691a9889a71defd0f4d0a43b/oAOxa2eJJd.js`.
Its inspected CryptoJS bootstrap is named `XdNhUHQNH1.js`.

The inspected outer script SHA-256 is
`852239b9143e4f56565233f03ef092770691567c63b13814f005d0909263b31b`;
the bootstrap SHA-256 is
`8e3b0117f4df4be452c0b6af5b8f0a0acf9d4ade23d08d55d7e312af22077762`.

## Version 8 container

The first byte is `8`. The remainder contains the ciphertext plus 69 inserted
metadata bytes. Let `N = container_length - 70`; `N` is the ciphertext length.
The official sampler requires `N >= 69`.

1. Parse the URL's `ts` query parameter as hexadecimal `int64`. Production
   accepts nonnegative values. Values above `0x7fffffffffffffff` are rejected by
   the official oracle with `bcode = 5`.
2. Initialize `state = (ts - N - 69) mod 2^32`.
3. Update `state = (1664525 * state + 1013904223) mod 2^32`.
4. Select `floor(state / 2^32 * N)`. Repeat until 69 distinct positions have
   been selected. Positions are zero-based within the bytes after the version.
5. Sort all 69 positions. The first four selected bytes are a header field; the
   next 65 bytes are an uncompressed P-256 public point beginning with `0x04`.
   The official version 8 decryptor does not use the four-byte field.
6. Remove all 69 selected bytes, preserving the order of the remaining bytes.

The shared AES key is the raw 32-byte P-256 ECDH secret computed from the
transient private JWK and the extracted public point. The private JWK is JSON
encoded as standard Base64, including the private `d` coordinate.

Decode the URL's `cpx` query parameter as standard Base64. Bytes `[31:47]`, using
zero-based half-open offsets, are the 16-byte counter. AES-256-CTR decrypts only
the first `min(N, 25 * 1024)` bytes. Append the untouched remainder. Go's CTR
implementation increments the full 128-bit counter in big-endian order.

## Legacy containers

Versions 3, 5, 6, and 7 use the sequential layout:

`version:u8 | payload_length:i32BE | payload | public_point:65bytes`

The public point and private JWK use the same P-256 formats as version 8.
All offsets below address the decoded `cpx`, using zero-based half-open ranges.
Legacy JS applies `decodeURIComponent` again after `URLSearchParams` decoding;
the converter preserves that extra decoding step without interpreting `+` a
second time. Double-percent-encoded parameters also passed the official oracle.

| Version | Key derivation | Cipher | IV | Encrypted prefix |
| --- | --- | --- | --- | --- |
| 3, 7 | Raw ECDH secret | AES-256-CTR | `[25:41]` | 25 KiB |
| 6 | Raw ECDH secret | AES-256-CBC | `[33:49]` | 21 KiB + 16 bytes |
| 5 | PBKDF2-SHA512 from raw ECDH secret | AES-256-GCM | `[32:48]` | 30 KiB + 16 bytes |

Legacy CTR increments only the low 64 bits of the counter, matching WebCrypto's
`length: 64`. This differs from the version 8 Go CTR implementation at counter
overflow.

CBC removes validated PKCS#7 padding from the decrypted prefix. The suffix starts
at the encrypted-prefix boundary, so the padding bytes do not shift the suffix.

Version 5 uses `salt = cpx[48:64]`, PBKDF2-SHA512 with 100000 iterations and a
32-byte output key. The GCM additional authenticated data is the same salt. Its
authentication tag is the final 16 bytes of the encrypted prefix. Authentication
must succeed before any plaintext is returned.

## Production boundary

`bilicomics/protocol/image_crypto.lua` performs conversion only. It does not
fetch URLs, send telemetry, store private keys, or change content entitlement.
The caller owns the temporary image file and applies the existing image
inspection and integrity checks after conversion. CTR does not itself provide
an authentication tag.

The converter rejects unsupported versions, malformed URLs and Base64, invalid
P-256 material, truncated containers, invalid CBC padding, and inputs above
16 MiB. Private key material is transient and must not be included in logs,
settings, download descriptors, or process command-line arguments.

## Remote validation evidence

All execution took place through `ssh test-env`; no local verification ran.

The unmodified version 8 WASM restored a generated 128 by 128 PNG of 49,363 bytes
exactly. Nine additional synthetic vectors cover ciphertext lengths 69, 70,
127, 128, 1024, 25599, 25600, 25601, and 49363, timestamps spanning the supported
integer range, and a counter crossing the low 64-bit boundary. The independent
Lua converter matched all ten official WASM outputs using the production
P-256 provider and the portable AES library under KOReader's LuaJIT.

For every legacy version, the unmodified official `c_f_11` and `c_f_49` helpers
restored both a 92-byte PNG and a 41,758-byte PNG. The production converter
matched all eight results, including an additional round with double-encoded
URL parameters. Two additional version 3 and 7 vectors verified low-64-bit
counter wraparound against the original WebCrypto helper. Altered GCM
authentication tags and invalid CBC padding were rejected. The committed
`image-spec.lua` passed 47 assertions against the final
Linux x86-64 library with SHA-256
`8e50c8a822d88472d7bb7933c0c014c79ab15fde0ff98db0436433b8f29c519a`.

The official WASM attempts an optional telemetry `fetch` before decrypting.
The successful oracle run returned a rejected Promise from that host function
with `Network disabled for synthetic research`; decryption still succeeded
synchronously. No success response was fabricated for telemetry. The production
converter does not contain this telemetry operation.

Working evidence on `test-env`:

- `/tmp/bili-crypto-research-20260912/image-golden.js`
- `/tmp/bili-crypto-research-20260912/image-golden-fixture.json`
- `/tmp/bili-crypto-research-20260912/image-v8-fixtures.js`
- `/tmp/bili-crypto-research-20260912/image-v8-fixtures.json`
- `/tmp/bili-image-verify-20260912/image-spec.lua`
- `/tmp/bili-image-vm-chain/findings.md`

Synthetic fixture files contain newly generated test private keys only. They
must never be replaced with keys from a user session.

The committed fixture suite can be repeated remotely from a KOReader release:

```powershell
ssh test-env 'cd /path/to/koreader && ./luajit /path/to/plugin/research/protocol/image-spec.lua /path/to/plugin'
```

`image-synthetic-golden.js` and `image-v8-boundaries.js` accept the official
artifact directory as their first argument. That directory must contain the
pinned WASM and Go's matching `wasm_exec.js`. The first script creates the
synthetic key fixture required by the second. They reject an unexpected WASM
digest and disable telemetry network traffic. The legacy generator and verifier
accept an official artifact directory followed by an existing output directory.
