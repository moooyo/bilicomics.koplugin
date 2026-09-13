# Bookstore category UI verification

Date: 2026-09-13. All verification ran through `ssh test-env` with the official
KOReader v2026.07.1 Linux emulator. No local Windows tests, builds or runtime
probes were executed. Previous bookstore/expanded evidence remains unchanged.

## Implemented behavior

The existing toolbar now contains the current category, loaded count and
Refresh on one line. All recommendations returns to the homepage feed. The
native picker displays the current official category list in three columns,
marks the selected entry, and offers Cancel. It never derives category choices
from homepage tags. Background updates defer the underlying page repaint while
the picker or synopsis is visible; native close applies the deferred repaint.

Category queries use the confirmed canonical category ID and default sort 0.
Changing category resets the local page and reads only that query's cache.
The same next arrow loads the next remote page only after the cached pages are
exhausted. Category page indicators report the local page without inventing a
server total. Appending 18 records fills a partially occupied local page first,
so compact displays with four or eight cards per page do not skip new records.
An empty server page and the bounded browsing limit have different messages.

Bookstore cards retain the compact portrait cover, two-line title and source
label. The 600 by 800 layout still displays six cards, and only the four
navigation tabs occupy the bottom row. Tapping opens chapters; holding opens
the synopsis. No reading or purchase starts from category selection.

## Controlled native results

The categories harness adapts the existing expanded scenarios with query-scoped
synthetic caches and original, visibly labeled example covers. It uses isolated
XDG directories and a separate network namespace without HTTP or credentials.

| Language | Resolution | Assertions | Result |
| --- | --- | ---: | --- |
| Chinese | 480 by 640 | 163 | Passed |
| Chinese | 600 by 800 | 207 | Passed |
| Chinese | 720 by 960 | 203 | Passed |
| Chinese | 960 by 720 | 243 | Passed |
| English | 480 by 640 | 163 | Passed |
| English | 600 by 800 | 207 | Passed |
| English | 720 by 960 | 203 | Passed |
| English | 960 by 720 | 243 | Passed |

All 1,632 assertions passed. They cover the 16-option picker, selection and
Cancel, returning to All, page reset, out-of-order category success/error
callbacks, obsolete picker/card callbacks, catalogue loading/failure/retry,
query-specific offline caches, empty-cache isolation and exact cover identity.
Pagination cases cover cached-page traversal, deduplicated append dispatch,
18-to-36 record growth, partial-page placement, failed append and retry, genuine
server end, and the five-request browsing cap. Native bounds, two-row density,
focus order, one bottom navigation row, synopsis layering, chapter activation
and reading/payment/account isolation also pass.

The unchanged Bookshelf layout separately passed all eight existing cases,
totaling 760 assertions, against the same final screen and locale sources.
Receipts are `bookstore-categories-verification.json`,
`bookstore-categories-results/`, `bookshelf-categories-grid-verification.json`
and `bookshelf-categories-grid-results/`. Screenshots are in
`screens/bookstore-categories/` and `screens/bookshelf-categories-grid/`.
Representative Chinese 600 and 480 picker/category images were visually
inspected for readable options, six-card layout and absence of overflow.

## Real anonymous category capture

The live capture opens the production bookstore route without repeating the
previously verified homepage auto-load. It clicks the actual category toolbar
control, waits for the official catalogue, captures the native picker, and
activates the real Heat category option from that catalogue. It does not inject
categories, comics, covers or account data.

The official catalogue returned **16 categories**. The selected Heat category
returned **18 comics**, and all **six first-screen covers** loaded at 600 by 800.
Both the picker and category screen were visually inspected. The capture did
not open a comic or issue any reading, purchase, favorite or login operation.

The existing read-only guard remains the authority for the exact endpoint,
method, body, headers, anonymous device context and signed request shape. The
successful audit contains one AllLabel POST, one anonymous device GET, one
ClassPage POST, six visible cover GETs, and one official pinned signing-asset
GET required by the fresh profile. Every response returned HTTP 200. Cookie
values, full signed URLs and request bodies are not recorded; the audit stores
only route/method/status and whether the transient cookie is the anonymous
device cookie. No login session was loaded, saved or persisted.

The profile contains no session file, favorite/history records or download jobs.
The Runtime closed normally, and source SHA256 values remained unchanged during
execution. `bookstore-categories-live-result.json` records native identities,
the official categories, selected category, comic count and visible covers.
`bookstore-categories-live-verification.json` binds source digests, the redacted
request audit, response counts and both PNG digests:

- [Official category picker](screens/bookstore-categories-live/bookstore-categories-live-picker.png)
- [Heat category first screen](screens/bookstore-categories-live/bookstore-categories-live-heat.png)

This is service/emulator evidence for the category-entry path, not physical
e-ink hardware acceptance. Multi-page behavior is covered by the controlled
native and separate Controller/protocol tests.

Remote outputs are below `/var/tmp/bilicomics-bookstore-categories-vetErDTs/`:
`ui-categories-pass1`, `ui-categories-bookshelf`, and `live-categories-final`.
