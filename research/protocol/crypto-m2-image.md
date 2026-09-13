# m2 Reporting, Encoding, and Image Boundary Evidence

Research date: 2026-09-12. Runtime work ran exclusively on `ssh test-env`, using synthetic inputs with no account cookies, purchases, or real manga image requests. Asset URLs and SHA-256 values are recorded in [the cryptography investigation](crypto-investigation.md).

## Current reader error-report path

The current reader has an explicit reporting fallback. It continues a read request with an error string when collecting m2 fails. This is client-source behavior; server acceptance, access grants, or successful reading do not follow from that fact.

The following pseudocode preserves the observed branches while renaming the obfuscated variables:

```javascript
async function reportM2Checks(id) {
    try {
        await loadCryptoAndVM();
        window.MC = readCookies();
        window.b1_0ccy7b = shared.P;
        window.b6_mlkh99 = shared.T;
        window.TGB = shared.T.toString();
        const result = await window.h1_o8j1i2(id);
        return result || ("error:m2_empty_" + Date.now());
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return "error:" + message + "_" + Date.now();
    }
}

async function getIndexFileUrl(ep_id, options = {}) {
    const config = { params: {} };
    if (options.cpx) config.params.cpx = options.cpx;
    if (options.m1) config.params.m1 = options.m1;
    let m2 = await reportM2Checks(ep_id.toString());
    if (!m2) m2 = "error:image_failed_" + Date.now();
    return post({ url: getImageIndexPath, data: { ep_id, m2 }, config });
}

async function getSeasonData(comic_id) {
    let m2 = await reportM2Checks(comic_id.toString());
    if (!m2) m2 = "error:detail_failed_" + Date.now();
    return post({ url: comicDetailPath, data: { comic_id, m2 } });
}
```

`GetImageIndex` therefore does not require `m1` or `cpx` in its client-side argument handling; both are added only when truthy. Its body always includes the resulting m2. `ComicDetail` also includes m2, rather than just `comic_id`. The shared protected POST wrapper signs the final serialized body, including m2. A generated signature for a different body is not interchangeable.

The caught error message is not a fixed protocol constant. A device adapter that cannot collect browser evidence can preserve this exact reporting shape using its real capability-error message. It must keep `index_challenge=false` until full reporting is implemented and verified. An `index_error_reporting=true` capability describes only construction of this error-report branch; it does not assert a valid browser fingerprint or successful authenticated reading. The server remains authoritative about whether it accepts the request.

### Source markers

The source is the served `reader.1ffe7bbf9d.js`, SHA-256 `3faf2f5de5c77884669dc749b0123343313c973d5eb2fc9edee1911cae191f1e`. For reproducible source inspection, the string-table-decoded copy is at `/tmp/bili-m1-nc9Uf7/reader-strings-decoded.js`. Character offsets below refer to that decoded copy, not line numbers or byte offsets in the original bundle:

| Character offset | Marker |
| ---: | --- |
| 2492969 | Export `$` resolves to `_0x210d25`, the reporting helper |
| 2546194 | `window.h1_o8j1i2` call after assigning the WASM bridges |
| 2546409 | `error:m2_empty_` branch |
| 2546525 | `reportM2Checks error:` catch and message serialization |
| 2224800-2227000 | `getIndexFileUrl`, optional `cpx`/`m1`, reporting fallback, and unconditional POST |
| 842000-843000 | `getSeasonData`, detail fallback, and `{comic_id,m2}` body |
| 970915 | Image wrapper invocation `y6_buo6u2(complete_url, privateJwkBase64, imageIndex)` |

## What m2 actually collects

The first external script, `XdNhUHQNH1.js`, initializes `CryptoJS`. The second, `oAOxa2eJJd.js`, contains FingerprintJS and a VM-obfuscated layer. Loading these scripts in an isolated JavaScript VM registered `h1_o8j1i2` and `y6_buo6u2`. Loading is not evidence that either operation works in a native reader.

The FingerprintJS-facing layer references visitor identity and confidence, plugins, font preferences, touch support, canvas text and geometry, fonts, hardware concurrency, device memory, platform/vendor information, WebGL vendor/renderer, languages, time zone, color gamut, HDR, and related browser features. It stores a JSON report under `window.b7_l9bt98`.

The m2 WASM `a1_o8iso5` reads that report, defaulting to `{"bilibili_0":1}` when absent. It evaluates additional browser observations before encoding the combined report:

- Canvas, image, WebGL, OffscreenCanvas, Blob, and URL method identities, including native-function representations and reader-installed hook identities.
- Screen dimensions and color depth, viewport size, navigator values, media queries, time zone, and the result of drawing a sample canvas.
- The calling error stack.
- The values of `window.r5_m42d2s` and `window.v5_t1iv5e`.
- The actual `#main_ui` text, the presence of a download control, the count/classes/attributes/HTML of `.action-settings > *`, and whether `XMLHttpRequest.prototype.open` contains an image-index-specific modification.

The argument to `a1_o8iso5` is interpolated into a membership check against `window.d3_m4s2gd`. It is not an image decryption key. The reader separately creates entries in this map from an identifier, time suffix, and random value.

The direct WASM call in an incomplete Node environment reached `document.getElementById('main_ui')` and subsequently failed because DOM query methods were absent. The unmodified call returned `null` after recovering its panic. This is direct evidence that the environment dependency is larger than reading a script's text or running a cryptographic digest.

## The byte codec is portable

For research only, a second harness converted otherwise uncaught JavaScript evaluation failures into error objects. It did not report these objects as successful browser checks and did not transmit the resulting report anywhere. This allowed inspection of the WASM's serialization and encoding boundary.

The serialized report contained the initial `bilibili_0` plus `bilibili_16`, `bilibili_17`, `bilibili_18`, `bilibili_19`, and `bilibili_21`. The observed strings included the real Node/WASM call stack and `<object>` markers for unsupported browser observations. Such a report is an invalid browser fixture, not usable challenge data.

The resulting codec is ordinary Base64 followed by a substitution over all 65 symbols, including padding:

```text
Input alphabet:  ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=
Output alphabet: ZBCDe0WGH1IJ9Kl3MNo2PQRstuVF+/=XY5Aab4cdEfghij6kLmnOpq7rSTU8vwxyz
```

Thus the ordinary Base64 padding symbol becomes `z`, and `=` is a valid data symbol in an encoded m2. Treating this string as normal Base64 is incorrect.

Two independent serialized error fixtures of 461 and 462 bytes encoded to 616 characters and matched the unchanged official WASM output byte for byte. `crypto-m2-codec.lua` implements only this byte operation in Lua; `crypto-m2-spec.lua` compared it with both saved official outputs on the remote official KOReader LuaJIT release. **Two official codec vectors passed.** The fixture file is explicitly marked `synthetic_error_fixtures`; it must not be used as request m2 data.

A native implementation can perform this encoding. It cannot infer a genuine browser canvas, DOM, plugin list, or native-method identity from KOReader's Linux/Android environment. The honest device path currently available is the source-supported error report, subject to actual server/session verification. A fabricated browser report is not a portability result.

## Image investigation handoff

The reader calls `y6_buo6u2` with the complete image URL, Base64 private JWK, and image index. This outer VM layer owns XMLHttpRequest/Blob handling and calls the four-argument `b6_mlkh99` bridge. The bridge is `59HX.T`, which calls the image WASM synchronously and parses the returned byte array as JSON; its `data` field is then Base64-decoded.

The VM exposes parser/crypto helpers during isolated execution. Synthetic calls established that its `c_f_22` helper reads a signed 32-bit big-endian integer from the beginning of a Uint8Array, and `c_f_26` decodes Base64 JSON. These are local helper observations, not a complete image-container contract. The initial four-argument WASM trials used deliberately empty/malformed inputs and exited with code 2, so no valid transformation result follows from them.

The parallel image-specific investigation owns the exact bridge argument/container contract and any synthetic encrypted-image proof. This document does not declare encrypted images supported from initialization, strings, or helper behavior alone.
