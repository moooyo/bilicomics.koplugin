# Official category protocol

## Observed official contract

The current [classification page](https://manga.bilibili.com/classify) is a
4728-byte client-rendered bootstrap page. It contains no Vike page context or
server-rendered comic list. Its official
[classification bundle](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/classify.119a8e5b12.js)
has SHA-256
`97517814c6d6c6b0894860e81fc249507bf99114d42581d094d32a71b5649738`.
The accompanying
[Bili bundle](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/bili.9409128c39.js)
has SHA-256
`8202851c77a8e8a58dab2fc2529542c09b6b6c296e26fe78390ee1206aae6908`.

The classification bundle loads metadata with an anonymous
`POST /twirp/comic.v1.Comic/AllLabel?device=pc&platform=web&nov=27&a=810` and an empty
JSON object. The recorded response has 16 `styles`, four `areas`, two `status`
values, three `orders`, three `prices`, and two `special` values. Each option is
an object with numeric `id` and string `name`.

The current metadata includes category ID 999 and 1015. ID 995 appears in an
older homepage navigation cache but is absent from the current AllLabel list,
so it is not added to the current choices. The official order IDs are 0
(popularity recommendations), 1 (update time), and 3 (release time).

The list request is a signed POST to `comic.v1.Comic/ClassPage`. This feature
sends only the selected `style_id`, one of those order IDs, `page_num`,
`page_size = 18`, and the observed default dimensions: `area_id = -1`,
`is_finish = -1`, `is_free = -1`, and `special_tag = 0`. The current native
`prepareCatalog` supplies its actual environment-error `m2` report, and the
existing signing backend signs that exact serialized body.

A strictly cookie-free request returned HTTP 200 with business code 99 and no
encrypted payload. The official Bili bundle initializes a device identifier
through `GET /ductape/buvid`. Using only the `buvid3` cookie issued by that exact
official response made the same ClassPage request succeed with code 0 and an
encrypted payload. The existing decoder produced 18 comics. This flow used no
SESSDATA, account identity, CSRF credential, login, or existing account profile.
Both control observations remain in `anonymous_controls` in the verification
report; no cookie value, signature or signed payload is recorded.

## Public interface and isolation

`Client:bookstoreCategories()` returns
`{ source = "official_categories", items = {{id, name}, ...}, orders = {{id, name}, ...} }`.
Category IDs are canonical decimal strings; order IDs remain numbers. The
Controller separately checks that a selected category belongs to this current
metadata snapshot.

`Client:bookstoreCategoryPage(query, page)` accepts
`{kind = "category", category_id = ID, sort = 0|1|3}`. Omitted kind, sort and page
default to category, 0 and 1. The application bounds requests to pages 1 through
5; that local bound does not claim the service ends at page 5. Extra filters,
noncanonical IDs, unsupported orders, and invalid page values are rejected
before any device request.

Each page obtains a new official anonymous device cookie. A temporary guest
Client holds only that cookie in memory; it cannot access the parent's session.
Its transport permits only the exact signed ClassPage route. Cookie capture is
disabled for this guest, and no guest or cookie is returned to the caller. The
Worker also drops any supplied session before constructing its outer Client, so
its third return value cannot become a guest session update.

The page result is
`{source = "official_category", personalized = false, query, page, page_size = 18, has_more, items}`.
The actual wire response is an array. The official website sets its continuation
flag from whether that array is nonempty; it does not expose a result total or
cursor. A short nonempty page therefore still has `has_more = true`, and only an
empty array ends the feed. A JSON object, including `{}`, is rejected. The
individual comic's `total` counts chapters and is never treated as a page count.

Observed comic fields include `season_id`, `type`, `title`, `author`,
`vertical_cover`, `horizontal_cover`, `square_cover`, `animated_vertical_cover`,
`is_finish`, `status`, `release_time`, `is_free`, `discount_type`,
`allow_wait_free`, `last_ord`, `last_short_title`, `total`, `introduction`,
`evaluate`, `styles`, `bottom_info`, `bottom_info_v2`, and `rd_tag`. All 18 recorded
rows had `type = 0` and unique `season_id` values. `styles` contains official
category names; `bottom_info_v2` and `rd_tag` contain separate descriptive tags.

Normalization admits valid comic rows only, preserves source order and the
first valid occurrence of an ID, and returns the existing display fields plus
explicit category ID/names in `extra`. Covers are upgraded to HTTPS and restricted
to official CDN locators without query or fragment components. Favorite,
reading, entitlement and purchase state are not inferred or imported.

## Verification

All execution took place through `ssh test-env` in the official KOReader
v2026.07.1 runtime. `categories_spec.lua` passed 11 groups and 541 assertions
inside an isolated network namespace with fake transport. It covers scalar JSON,
object-versus-array responses, body and query constraints, all three observed
order IDs, per-page device isolation, malformed cookies, cover locators,
pagination, encrypted contexts, parent-session poison sentinels and the actual
Worker's absence of a third session result.

`categories_live.lua` then used the production methods and read-only launcher
guard to fetch current metadata and the first page of category 999 in order 0.
All three requests returned HTTP 200, both business responses returned code 0,
and the encrypted page decoded to 18 comics. The public pinned signing asset was
already available and passed its existing digest check. No session file was
created. Source hashes remained unchanged during both final runs.

The independently maintained read-only guard passed 464 cases and 915 assertions
against the final source. Its report is `spec/local/category-guard-results.json`.
The protocol report is `bookstore-categories-verification.json`, with current
`source_hashes`, focused cases, sanitized live observations, full public field
types and the earlier code-99 contrast. Prior recommendation and expanded-feed
reports remain unchanged.
