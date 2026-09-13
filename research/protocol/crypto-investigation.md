# Current PC Cryptography Investigation

Research date: 2026-09-12. All downloads, execution, binary inspection, and verification in this investigation ran through `ssh test-env`. No local verification, account login, purchase, coupon use, or manga image download was performed.

This document supplements the product research, which did not execute the downloaded JavaScript or WASM. This investigation executed the current publicly served WASM with synthetic inputs in an isolated remote directory. A request for the reader HTML returned HTTP 412; the static assets below remained available. Static asset availability does not independently establish their selection by a freshly rendered page.

## Artifacts

| Official asset | Bytes | SHA-256 |
| --- | ---: | --- |
| [Signing WASM](https://s1.hdslb.com/bfs/manga-static/manga-pc/efae82c96a7eef44bee5.wasm) | 2,158,373 | `39bc0676953752c461197df592e1f5894f1a7492a29400c946e560fc109a8e2e` |
| [Response WASM](https://s1.hdslb.com/bfs/manga-static/manga-pc/e461bfa6b471a22c06fc.wasm) | 2,853,061 | `3b499622e9a5f6181f0709d1485498f533428f9a30ae32694f6f6852ec47184c` |
| [m2 WASM](https://s1.hdslb.com/bfs/manga-static/manga-pc/2ad56ae2f95bd54cf0b8.wasm) | 2,111,004 | `2bb3a7e1c4ce37074fab50b39979c84e22f41a5c1f814dbf11a13f086edf578c` |
| [Image WASM](https://s1.hdslb.com/bfs/manga-static/manga-pc/dda35c98742815151e46.wasm) | 3,174,782 | `f96b11772a59ba8321755fe94e145b175f40354638405442fb2d40a8a8e2dfc8` |
| [Shared JavaScript](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/bili.9409128c39.js) | 537,221 | `8202851c77a8e8a58dab2fc2529542c09b6b6c296e26fe78390ee1206aae6908` |
| [Reader JavaScript](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/reader.1ffe7bbf9d.js) | 3,616,526 | `3faf2f5de5c77884669dc749b0123343313c973d5eb2fc9edee1911cae191f1e` |
| [m2 bootstrap JavaScript](https://activity.hdslb.com/blackboard/static/20250424/79521623691a9889a71defd0f4d0a43b/XdNhUHQNH1.js) | 48,316 | `8e3b0117f4df4be452c0b6af5b8f0a0acf9d4ade23d08d55d7e312af22077762` |
| [m2 VM JavaScript](https://i0.hdslb.com/bfs/activity-plat/static/20260129/79521623691a9889a71defd0f4d0a43b/oAOxa2eJJd.js) | 489,538 | `852239b9143e4f56565233f03ef092770691567c63b13814f005d0909263b31b` |

Remote working directory: `/tmp/bili-crypto-research-20260912`. `probe.js` executes the unchanged WASM with the [official Go 1.25 JavaScript host](https://raw.githubusercontent.com/golang/go/go1.25.0/lib/wasm/wasm_exec.js); `trace.js` logs host-object operations. The official WABT 1.0.41 Linux x64 release was used for binary-to-text inspection. These remote tools and downloaded assets are research inputs, not a Node dependency of the plugin.

## Signing and the minimal WASM host

The shared module calls `y1_z2w2a3(query, body, timestamp)`. Its wrapper uses `timestamp || Date.now()` and requires a 13-character decimal representation. The parameter is a JavaScript number in milliseconds, not Unix seconds. The wrapper returns `result.sign` or throws `result.error`.

The decoded current reader places `ultra_sign` in `axios` query parameters. It places the constant `1E74C20E5720FBF3BB351965D7A9DFC1` in the `x-bili-data-sn` request header. That header is not the timestamp. The reader calls the wrapper with the canonical query and the serialized body; the shared wrapper supplies the time.

Synthetic signing vectors, independently repeatable without network requests:

| Query | Body | Timestamp | Sign |
| --- | --- | ---: | --- |
| `device=pc&platform=web&nov=27&eot=812` | `{}` | 1789171200000 | `Y4wKk9D0kYX0R2LGQ04edYQ0YQX4h9kDsKGXaasha1a4DsKf` |
| `device=pc&platform=web&nov=27&eot=812` | `{"comic_id":36215}` | 1789171200000 | `dRas4960Rha0D2RL60weLdR0w6LK69ddXhkLYasGd1sKYaXf` |

The same input produced the same signature on repeated calls. The observed result is 48 characters. No claim that this is ordinary Base64, MD5, or SHA-256 follows from that length. The signature algorithm was not fully reimplemented in Lua in this investigation.

All four modules exported `run`, `resume`, `getsp`, and `mem`; each initialized an 8 MiB linear memory in the Go host. Signing and response decoding imported 20 Go host functions: timing, random bytes, memory-view reset, exit/write, reference handling, string conversion, property/index access, construction/calls, and copying bytes to the host.

For the executed signing and response cases, initialization accessed `Object`, `Array`, `process`, `path`, `fs.constants`, and `Uint8Array`, registered a wrapper with `Go._makeFuncWrapper(1)`, and published the global entry point. Invocation consumed `Go._pendingEvent` containing `id`, `this`, and `args`, then assigned an object to its `result`. Neither operation accessed the DOM, navigator, WebCrypto, or network APIs during these cases. This evidence supports a narrow Go host over a native WASM interpreter. It does not establish such a host for the environment-dependent m2/image modules. The parallel native-host work supplies the separate native execution and packaging evidence.

## Verified response algorithm and production implementation

The response entry point identifies its exact arguments in its argument-count error:

```text
c1_r9k2m7(url, bytesData, buvid, platform, bodyJSON)
```

Memory inspection with synthetic values exposed the key material. Independent encryption using Node's AES implementation produced ciphertext that the unchanged official WASM successfully decoded, confirming the following algorithm for the current `web` contract:

1. Parse the request URL, remove the `/twirp` prefix, and select the body field in the table below.
2. Take bytes at zero-based positions `0, 2, ..., 34` of the ASCII buvid, stopping at its end. Characters after the first 36 bytes do not participate.
3. Append `web`, then the last three characters of the selected field's string representation. Missing fields contribute an empty suffix.
4. Pad on the right with `=` to exactly 24 bytes. This is the AES-192 key.
5. Decode the response using standard padded Base64. Decrypt with AES-192-CBC; the IV is the first 16 key bytes.
6. Remove PKCS#7 padding and parse the UTF-8 JSON data.

| Endpoint after `/twirp` | Body field |
| --- | --- |
| `/comic.v1.Comic/ComicDetail` | `comic_id` |
| `/comic.v1.Comic/GetImageIndex` | `ep_id` |
| `/comic.v1.Comic/ClassPage` | `style_id` |
| `/comic.v1.Comic/ImageToken` | `urls` |

The `urls` field is the JSON-encoded path-list string from the request body. It is not decoded a second time for key derivation. A synthetic value of `["synthetic-a","synthetic-b"]` therefore contributes `b"]`.

One complete decoder vector:

```text
url: /twirp/comic.v1.Comic/ComicDetail
buvid: SYNTHETIC-BUVID
platform: web
bodyJSON: {"comic_id":36215}
key: SNHTCBVDweb215==========
bytesData: yHEYgHkBOklQxZUed3mFB7VmJEAMe8nOHxniUEThJGI=
official result: {"error":"","data":"{\"fixture\":\"crypto\"}"}
```

`bilicomics/protocol/response_crypto.lua` implements this contract. Its API is `deriveKey(context)`, `decrypt(context, bytesData)`, `decode(context, envelope)`, and `available()`. The context uses `url` (or `path`/`endpoint`), exact serialized `body` (`body_json` is an alias), `buvid`, and `platform`. Errors return `nil` plus a structured `{kind, code, message}` object. A decoded success preserves envelope metadata, replaces `data`, and removes `bytesData`; plain data and nonzero business responses pass through. A success without object/array data is rejected.

The implementation performs CBC XOR over KOReader's existing `ffi/crypto` AES-192-ECB operation. It requires no new CBC, low-level AES, or P-256 exports. It strictly validates Base64 encoding, all PKCS#7 padding bytes, UTF-8, and JSON object/array results. The stricter invalid-input behavior is intentional; it does not reproduce malformed-padding acceptance merely because an upstream decoder might tolerate it.

Verification used the official KOReader v2026.07.1 Linux x86_64 release's LuaJIT, crypto binding, and `libcrypto.so.57`: **71 assertions passed**. Ten valid fixtures cover all four endpoint fields, short/numeric/string IDs, a full URL with query parameters, absent fields, a buvid with hyphens and `infoc`, and truncation of a long buvid. Each fixture was accepted by the unchanged official WASM before the Lua comparison. Negative cases cover malformed/canonical Base64, partial blocks, inconsistent padding bytes, invalid UTF-8, invalid JSON, missing response data, unsupported endpoints/platforms, non-ASCII buvids, and fractional key fields.

The replay files are `crypto-response-spec.lua`, `crypto-response-fixtures.json`, and `crypto-response-invalid-fixtures.json`. Copy the production module into the remote replay directory as `response_crypto.lua`; run the spec from the official release directory. The Android APK exports the ECB/EVP operations used by this path, but no Android runtime or physical-device memory claim is made here.

## m1 and native dependencies

See [m1 native research](crypto-m1-native.md) and `bilicomics/protocol/ecdh.lua` for the independently verified P-256 implementation and platform capability distinction. The public request `m1` is Base64 of the uncompressed raw public point. The converter's private-key input is Base64 of the serialized private JWK, not the same `m1` and not a scalar byte string.

## m2 and image conversion remain separate gates

The m2 WASM `a1_o8iso5` was initialized successfully, but synthetic calls reached real browser-environment evaluation. The trace captured calls to `eval` that inspect native canvas/image/WebGL methods, screen and navigator properties, canvas fingerprint content, stack traces, and the reader's actual DOM. It examines `#main_ui`, the action controls, download-related elements, and the XMLHttpRequest method body. With an intentionally incomplete synthetic document, it returned `null` after reporting missing DOM methods. Returning made-up answers for these checks would not establish a faithful device implementation.

The image WASM initialized and registered `a1_h17mj9`; its binary contains P-256 ECDH, AES-CBC/AES-CTR, SHA-256, JWK parsing, and byte-buffer conversion machinery. The shared JavaScript accepts the four-argument result as a byte array containing JSON, then Base64-decodes its `data` field. Initialization and strings alone do not establish the encrypted-image format, derivation, segmentation, or conversion behavior. No real encrypted image was obtained or transformed in this investigation.

Consequently, a native signing host and a verified native response decoder remove two concrete protocol obstacles. They do not complete the m2 or `hit_encrpyt=true` image branch. Production support must retain explicit capability failures for those missing paths until a current, usable image result and its target-device resource behavior are demonstrated.
