# Native bookstore verification

Date: 2026-09-13. All execution took place through `ssh test-env` using the
isolated official KOReader v2026.07.1 Linux emulator at
`/var/tmp/bilicomics-bookstore-protocol-7g7nf8co/runtime/lib/koreader`. No local
Windows test, build or runtime probe was run.

## Scope

The production screens, cover cards, dialogs and chapter catalog are rendered
with a controlled asynchronous controller. A seven-item recommendation fixture
has the official-homepage result shape, preserves deliberately unsorted item
order, and marks its source as anonymous and nonpersonalized. All illustrations
are original test artwork with a visible `SYNTHETIC ORIGINAL ART` label.

Each native process has its own XDG directories and isolated network namespace.
No HTTP request, account credential, real comic artwork, purchase or reader
handoff is used. These checks verify UI behavior; the separate protocol and
controller checks establish the real endpoint and durable cache behavior.

## Results

| Language | Resolution | Assertions | Result |
| --- | --- | ---: | --- |
| Chinese | 480 by 640 | 42 | Passed |
| Chinese | 600 by 800 | 42 | Passed |
| Chinese | 720 by 960 | 45 | Passed |
| Chinese | 960 by 720 | 45 | Passed |
| English | 480 by 640 | 42 | Passed |
| English | 600 by 800 | 42 | Passed |
| English | 720 by 960 | 45 | Passed |
| English | 960 by 720 | 45 | Passed |

All 348 assertions passed. They cover:

- Bookshelf/Bookstore/Search/Downloads navigation, with no independent History
  destination or unsupported category/ranking/personalized controls.
- Automatic anonymous loading of an empty feed, visible loading feedback,
  disabled refresh while loading, and no duplicate requests from repaint.
- Native two/three-column cover layout, bounds, focus order, feed order across
  local pages, visible-only cover requests and no fictional extra feed page.
- Fresh-cache reuse, visible cached recommendations while refreshing, explicit
  offline-cache feedback, initial connectivity failure and the native Retry
  action restoring recommendations.
- Recommendation activation opening only its chapter catalog; no implicit read,
  purchase, download, favorite change or account action.
- Duplicate refresh suppression and retirement of obsolete cards and delayed
  success/error callbacks after navigation.

Forbidden-method sentinels remained untouched throughout every scenario. The
56 saved native framebuffers include loading, recommendations, last page,
chapter catalog, cached offline, first-load failure and successful retry states.
Representative Chinese/English, portrait/landscape and compact error/cache
screenshots were visually inspected for readable text, aligned covers, visible
retry actions and the single bottom navigation row.

The source and harness hashes are in `bookstore-verification.json`. Full
assertion records are in `bookstore-results/`; screenshots are in
`screens/bookstore/`. The shared bookshelf refactor also passed all eight cases
in `bookshelf-grid.md`, totaling 760 assertions. Native business, session-file
and QR regressions were rerun against the new navigation and all passed.

Remote output: `/var/tmp/bilicomics-bookstore-7zKUkTCU/ui-bookstore`.

## Reproduction

Use the isolated Pillow dependency directory and a fresh remote output path:

```powershell
ssh test-env 'PYTHONPATH=/var/tmp/bilicomics-bookstore-protocol-7g7nf8co/python-deps python3 /var/tmp/bilicomics-bookstore-7zKUkTCU/source/spec/ui/run_bookstore.py /var/tmp/bilicomics-bookstore-protocol-7g7nf8co/runtime/lib/koreader /var/tmp/bilicomics-bookstore-7zKUkTCU/source /var/tmp/bilicomics-bookstore-ui-new-output'
```

## Separate live anonymous capture

The subsequent [live capture](bookstore-live.md) runs the production Runtime,
Controller, Screens, subprocess Runner, Client and verified-TLS transport in a
fresh anonymous profile on `test-env`. It uses the current desktop read-only
guard and a narrower capture boundary that admits only the exact recommendation
GET and the production CDN thumbnail URLs of the visible recommendation cards.
No Cookie, Authorization, request body, account login, favorite change, reading
operation or purchase is permitted by this capture. Its data and artwork come
from the real official responses, without injected recommendations or covers.

At 600x800 it loaded seven recommendations and both first-page covers, then
captured [the real screen](screens/bookstore-live/600x800.png) after the actual
worker queue became idle. All three GET requests returned HTTP 200: one homepage
recommendation request and two 480x640 cover thumbnails. The Runtime closed
normally, with no session file, favorite/history records or download jobs in the
isolated profile. The screen was visually checked for loaded covers, readable
titles and descriptions, aligned tags and the single bottom navigation row.

[Live evidence](bookstore-live-verification.json) records all production Lua
digests, native component identities, request boundaries, responses, screenshot
digest and unchanged source during execution. Its Controller digest is
`90cdc3210008f10df1e2cb85b70cd0f6429f29d95cef578394e3bfc676597150`.
The separate [guard regression](../local/recommendations-guard-results.json)
passed 208 cases and 369 assertions using strict fake Transport/Runner originals
inside an isolated network namespace on `test-env`. Existing mutation rejection
cases remain covered. Neither run executed local Windows/WSL verification.
