# Bookshelf cover thumbnails

Date: 2026-09-13.

## Verified source behavior

The official manga website's public image component in
[chunk-BTk2--tq.js](https://s1.hdslb.com/bfs/manga-static/manga-pc-ssr/assets/chunks/chunk-BTk2--tq.js)
appends `@<width>w.<format>` to ordinary HTTPS image URLs. Its fallback image
uses `jpg` for JPEG sources and `png` for PNG, WebP and AVIF sources. The
component leaves URLs with an existing `@` transformation or without a plain
supported extension untouched. The anonymous official homepage also contains
real JPEG cover URLs using `@282w.jpg` and `@484w.jpg`.

The source was retrieved again anonymously on `test-env`; its SHA-256 was
`1af019702c2639ee04c4e7c8a908bb8f84511e04c66062b820eed0a3366e3fb6`.
No account credentials or account response files were needed for this check.

## Production behavior

`bilicomics/cover_source.lua` resolves a catalog cover URL into a request URL and
a versioned cache identity. It uses the verified 480-pixel width transformation
and the official JPEG/PNG fallback. Existing transformations and opaque/query
URLs remain unchanged because their transformation contracts are unknown.

The resolver accepts only HTTPS resources under the same Bilibili image host
families as the production client. It rejects user information, explicit ports,
untrusted hosts, whitespace and control characters. The production client
continues to independently enforce its HTTPS image-host allowlist.

`Controller:requestCover(comic_id)` is unchanged. Acquisition remains an
asynchronous `download_cover` operation with duplicate visible-card requests
sharing an in-flight operation. Library refresh and search ingestion do not
queue cover downloads for hidden results; visible cards request their own
covers, and opening a comic detail still requests that comic's cover.
The 4 MiB response limit, four-million-pixel
source limit, worker isolation and credential-free image request headers remain
in place. A failed thumbnail keeps the existing 300-second retry backoff.

Both the saved cache metadata and its filename bind the derived request URL and
strategy version. An old original-image cache does not suppress thumbnail
acquisition, and an old source's failure does not delay a changed cover URL.
Results from superseded URLs are discarded before dispatching the current URL.
Successful results are synchronized and atomically renamed within the account
cover directory; callbacks from a previous account generation remove their
temporary file without changing the current account.

## Verification

All execution took place on `test-env` using the official KOReader v2026.07.1
runtime. No tests, runtime probes or image decoding were run on the workstation.

- `spec/controller/cover-thumbnail-results.json`: 33 assertions covering URL
  transformation and rejection, offline behavior, asynchronous deduplication,
  strategy-aware cache reuse, replacement of legacy original caches, exact
  retry-backoff timing, changed URLs, obsolete account callbacks and suppression
  of cover acquisition for hidden library/search items.
- The same report contains two real anonymous production-client transfers of
  public homepage thumbnails: 480 x 640 JPEGs of 99,537 and 75,506 bytes. Both
  passed production container inspection within the existing byte/pixel limits.
  Only the derived thumbnails were requested, and their temporary files were
  removed after recording metadata.
- `spec/jobs/cover-thumbnail-policy-results.json`: all eight existing production
  worker/client cover policy checks passed, including the inclusive pixel limit,
  oversized-header rejection, chapter-page independence and anonymous image
  request behavior.
- `spec/controller/cover-thumbnail-regression-result.json`: all 69 existing
  controller integration assertions passed with synthetic accounts and injected
  worker responses.

To reproduce the targeted verification on the remote host:

```sh
python3 <source>/spec/controller/run_cover_thumbnails.py \
  --runtime <koreader-runtime> --source <source> --output <new-output-directory> \
  --live-public
python3 <source>/spec/jobs/run_remote.py \
  --runtime <koreader-runtime> --source <source> --output <new-policy-output> \
  --suites cover
```

This proves public CDN behavior and the controller/cache contracts. It does not
claim an account-specific bookshelf render or a live read of the user's manga.
Unavailable or already transformed oversized cover resources can still fall
back to the existing placeholder while retaining the download limits.
