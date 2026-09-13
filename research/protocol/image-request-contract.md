# Official Image Request and Plain-Response Contract

Research date: 2026-09-12. This review used cached official source and static
VM bytecode tables. It did not read a user session, issue account requests, or
execute purchase tests. The parent task separately performed the authorized
read-only image diagnostics summarized below without exposing credentials or
image content to this review.

## Official source identity

- [Reader bundle](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/reader.1ffe7bbf9d.js),
  SHA-256 `3faf2f5de5c77884669dc749b0123343313c973d5eb2fc9edee1911cae191f1e`.
- [Outer image VM](https://i0.hdslb.com/bfs/activity-plat/static/20260129/79521623691a9889a71defd0f4d0a43b/oAOxa2eJJd.js),
  SHA-256 `852239b9143e4f56565233f03ef092770691567c63b13814f005d0909263b31b`.

Reader character offsets below refer to
`/tmp/bili-m1-nc9Uf7/reader-strings-decoded.js`, not original bundle byte offsets.
The VM's cached static data are `/tmp/bili-image-vm-static/pools.json` and
`opcodes.json`; `awcbb_yhh_fun28.txt` contains the previously decoded response
handler. Inspecting those tables does not execute the official VM.

## Complete URL construction

`ReaderImage.loadToken` takes the first ImageToken result's `complete_url`.
Its live constructor initializes `_comicCode` to the fixed string
`DanmakuInfo`. The aliases and constructor condition were resolved at offsets
345711–345780, 945384–945511, and 982613.

The request URL construction at 958227–958490 is equivalent to:

```javascript
completeUrl = result.complete_url + "&code=DanmakuInfo";
if (result.complete_url.startsWith("http://")) {
    completeUrl = result.complete_url.replace("http://", "https://");
}
```

Thus HTTPS URLs retain their exact bytes and gain the fixed parameter.
Protocol-relative URLs gain it and resolve under the HTTPS reader origin.
The original HTTP branch upgrades to HTTPS using the original string, replacing
the earlier result and therefore omitting the added parameter. The marker is
neither a comic identifier nor a derived signature or page number.

The main reading path does not demonstrate a fallback rebuilding this resource
from `url` and `token`. Existing plugin fallback semantics were left intact.
In particular, the unrelated first-image wrapper is not evidence that the
current ImageToken's `token` field contains additional query parameters.
Existing `token`, `cpx`, and `ts` parameter bytes must not be decoded and
re-encoded while applying this construction.

The parent task's controlled fourth-image observation used the same fresh
token/context: the original HTTPS complete URL returned HTTP 400, and adding
only `&code=DanmakuInfo` returned HTTP 200. No other query field or header was
changed in that comparison. This supports the URL correction but does not by
itself establish image decoding success.

## XHR and index

The reader calls `y6_buo6u2(completeUrl, privateJwkBase64, imageIndex)` at
970907. Its third argument is the zero-based index supplied by the original
`images.map` operation at 3274814 and 3275189, carried through the constructor
at 983133 and 986045. Added reader blank pages do not change this source index.
The fourth original image therefore uses index three.

The VM's `awcbb_yhh_fun26` binds those arguments and creates a Promise using
`awcbb_yhh_fun27`. The latter constructs XMLHttpRequest at PCs 275–283, calls
`open("GET", completeUrl, true)` at 284–300, sets
`responseType="arraybuffer"` at 301–309, binds its handlers at 317–345, and calls
`send()` without a body at 353–361. That function does not set request headers,
change credentials mode, re-encode the URL, or include the image index in GET.
It reads `navigator.userAgent` elsewhere for an environment check; that read is
not a User-Agent request-header assignment.

The existing plugin encrypted branch omits an explicit User-Agent, causing the
bundled LuaSocket HTTP module to use its default `socket._VERSION`; the plain
branch explicitly uses the Client's configured browser-style User-Agent.
The parent's separate User-Agent comparison still returned HTTP 400. No
production User-Agent change followed from this evidence.

## A token marked encrypted can return an ordinary image

The first relevant branch in `awcbb_yhh_fun28` is:

1. PCs 219–235 read `xhr.getResponseHeader("Content-Type") || ""`.
2. PCs 237–248 test `contentType.startsWith("image/")`.
3. If true, PC 252 creates `new Blob([xhr.response])`; PCs 270–306 resolve a
   success object containing the Blob, and PC 308 returns.
4. Only the false branch, starting at PC 309, builds a Uint8Array and reads the
   encrypted container's version.

The response handler does not inspect `hit_encrpyt` for this decision and does
not check magic bytes. Its fixed message `"> 1MB"` is not a size condition.
Therefore the token flag is not proof that the received bytes are an encrypted
container.

The parent confirmed that the HTTP 200 resource had `Content-Type: image/jpeg`,
JPEG magic, and first byte 255 while the token flag remained true. The response
contained 4,640,394 bytes. Passing those bytes directly to the
container converter produces an unsupported-version error. The source-supported
compatibility path is to recognize an HTTP `image/*` response before container
conversion, then retain the plugin's existing file inspection, image-size
bounds, checksum, and cleanup requirements. A magic-only fallback in the
absence of that header is not established by this source review.

The implemented Backend branch follows the exact case-sensitive `image/`
prefix after HTTP success and the existing bounded file read. It returns the
unchanged temporary candidate to `Client.downloadImage`; it does not bypass
`Image.inspect`, increase the byte budget, infer a successful encrypted
transformation, or add a magic-only fallback. Missing and non-image headers
retain the encrypted-container path.

## Targeted URL regression

The production URL change is limited to `Client.imageURL`.
The [dedicated image request suite](../../spec/protocol/image_request_spec.lua)
passed six groups and eleven injected CDN requests on the official Linux
KOReader LuaJIT on `test-env`. It checks exact query-byte preservation,
HTTPS/HTTP/protocol-relative behavior, shared plain/encrypted construction,
unchanged fallback encoding, no account credentials at the CDN boundary, and
nonretryable HTTP 400 cleanup. Encrypted success cases use the actual production
converter and compare all bytes with the established synthetic PNG golden.

The existing image-only acquisition suite also passed ten groups using the
updated URL code. Its results are in
[image-url-acquisition-result.json](image-url-acquisition-result.json); the new
suite result is [image-request-result.json](../../spec/protocol/image-request-result.json).
No general Client suite or quote/wallet/purchase test was run. Injected transport
results prove the local paths, not live service success.

After the Backend header change, the dedicated
[image response suite](../../spec/protocol/image_response_spec.lua) passed eight
groups with fifteen injected CDN responses. Those cases exercise real JPEG/PNG
inspection, unchanged original bytes and checksum, malformed/truncated input,
missing/non-image/case-mismatched headers, the existing byte and geometry
limits, HTTP failure cleanup, and actual conversion of a supported encrypted
container. The synthetic JPEG input is the 24 by 37 fixture produced by the
existing remote protocol preparation, supplied as the suite's third argument.
The first draft assertion used `jpeg` as the normalized format; it was corrected
to the existing `Image.inspect` contract `jpg`, without changing production.

The six URL groups and ten existing acquisition groups also passed against the
final Backend. Results are
[image-response-result.json](../../spec/protocol/image-response-result.json),
[image-request-result.json](../../spec/protocol/image-request-result.json), and
[image-response-acquisition-result.json](image-response-acquisition-result.json).
The final remote run directory is
`/tmp/bilicomics-protocol-tests-vlh4afyq/image-response-20260912/`.
