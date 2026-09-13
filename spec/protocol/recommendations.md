# Official homepage recommendations

`Client:recommendations()` reads the public homepage recommendation section with
an anonymous `GET https://manga.bilibili.com/index.pageContext.json`. It has no
request body, pagination parameters, credentials, signature, or account mutation.
The response is bounded at 4 MiB, and response cookies are ignored even if the
client has an imported session.

The route and schema were confirmed on 2026-09-13 through `ssh test-env`, using
only anonymous requests to official resources:

- The current [homepage](https://manga.bilibili.com/) includes the Vike client
  assets and its server-rendered page context.
- [`chunk-BjQstEAu.js`](https://s1.hdslb.com/bfs/manga-static/manga-pc-ssr/assets/chunks/chunk-BjQstEAu.js)
  appends `/index.pageContext.json` to the root page pathname and fetches that
  route for client-side page data. Its SHA-256 is
  `f3102e03f1cff732b8d35ed29c4bbb8158b0c5c614956c0f4ce100cdfacf8b84`.
- [`pages_index.B7vjAQej.js`](https://s1.hdslb.com/bfs/manga-static/manga-pc-ssr/assets/entries/pages_index.B7vjAQej.js)
  displays `data.recommendation.comics` in its existing order. Its SHA-256 is
  `f3dec7912ae8d6357166ce3681d4b409f795485088f607e170e852269f2b136a`.
- The anonymous [page context](https://manga.bilibili.com/index.pageContext.json)
  returned HTTP 200 and `application/json`, with `pageId` equal to
  `/pages/index`. Its `data.recommendation.comics` contained seven entries with
  `id`, `title`, `evaluate`, `vertical_cover`, `horizontal_cover`, and `tags`.
  This section exposed no cursor, total, or continuation endpoint.

The plugin labels this source `official_homepage` and `personalized = false`.
The public endpoint observation establishes homepage recommendations; it does
not establish account personalization. Other homepage sections and rankings are
not combined into this feed.

The return value is `{ source, personalized, has_more = false, items }`.
Items contain canonical string IDs, titles, HTTPS official-CDN cover locators,
and `extra.recommendation`, `extra.evaluate`, and `extra.tags`. Duplicates keep
their first valid occurrence. Unusable rows are skipped; an entirely unusable
nonempty response is an error. Missing sections and invalid page contexts are
errors, while an explicit empty list is valid. The observed section has no
author, completion, favorite, or reading-state fields, so these are not inferred.

`recommendations_spec.lua` checks the exact anonymous request, cookie isolation,
response shape, source order, display fields, malformed rows, and failure cases.
An optional third argument loads an anonymously captured official response and
confirms the same normalization contract without making a network request.
`spec/jobs/worker_spec.lua` includes `recommendations` in the read-only operation
contract. All verification runs in the remote KOReader runtime on `test-env`.

The recorded run passed 89 recommendation assertions, 87 worker assertions,
and all 12 existing Client regression cases.
A separate anonymous call through the real KOReader `Client` and verified-TLS
transport returned seven recommendations successfully. Recommendation contents
can change between anonymous requests; only each response's own order is used.
`recommendations-verification.json` records these results and the production
source digests. No account credentials were read and no live mutation was sent.
