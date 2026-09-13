# Expanded bookstore verification

Date: 2026-09-13. All verification ran through `ssh test-env` with the official
KOReader v2026.07.1 Linux emulator. No local Windows tests, builds or runtime
probes were executed. The previous bookstore and live reports remain unchanged;
all new receipts and screenshots use expanded names.

## Compact native grid

`bookstore_expanded_spec.lua` retains the earlier controlled loading, cache,
retry, navigation and operation-isolation cases while using 19 unique,
deliberately unsorted recommendation IDs. The original example covers are
visibly marked `SYNTHETIC ORIGINAL ART`. Each case has isolated XDG directories
and a separate network namespace; its controller makes no HTTP request.

| Language | Resolution | Cards per page | Layout | Assertions | Result |
| --- | --- | ---: | --- | ---: | --- |
| Chinese | 480 by 640 | 4 | 2 columns, 2 rows | 152 | Passed |
| Chinese | 600 by 800 | 6 | 3 columns, 2 rows | 200 | Passed |
| Chinese | 720 by 960 | 6 | 3 columns, 2 rows | 200 | Passed |
| Chinese | 960 by 720 | 8 | 4 columns, 2 rows | 248 | Passed |
| English | 480 by 640 | 4 | 2 columns, 2 rows | 152 | Passed |
| English | 600 by 800 | 6 | 3 columns, 2 rows | 200 | Passed |
| English | 720 by 960 | 6 | 3 columns, 2 rows | 200 | Passed |
| English | 960 by 720 | 8 | 4 columns, 2 rows | 248 | Passed |

All 1,600 assertions passed. Coverage includes screen/card bounds, portrait
cover proportions, equal row alignment, focus order, the compact source label,
visible-only cover requests, complete pagination order and no duplicate or
missing IDs across pages. Background refresh and cached-offline feedback retain
the same two-row capacity. The bottom contains only the four navigation tabs.

Long descriptions are absent from grid widgets. Holding a card opens its full
synopsis without starting a request or reading operation. While the synopsis is
open, asynchronous refresh preserves the same background widget and topmost
dialog. Native close applies the deferred repaint; navigating away retires an
obsolete close callback. Tapping a card still opens only the chapter catalog.
Forbidden reading, payment, download, account-mutation and unsupported-store
method sentinels remain untouched.

The source and harness hashes are recorded in
`bookstore-expanded-verification.json`; individual receipts are in
`bookstore-expanded-results/`. The 72 native example screenshots are in
`screens/bookstore-expanded/`. Representative 600 by 800, compact offline,
landscape and synopsis screenshots were visually inspected.

The unchanged Bookshelf presentation also passed all eight Chinese/English
cases, totaling 760 assertions, against the final shared widget and screen
sources. Its separate new receipts are
`bookshelf-expanded-grid-verification.json` and
`bookshelf-expanded-grid-results/`; 64 screenshots are in
`screens/bookshelf-expanded-grid/`. Older native/session/QR runs were not rerun
for this density-only change and remain evidence of their recorded UI scope.

Remote controlled outputs:

- `/var/tmp/bilicomics-bookstore-expanded-TGn5xYAc/ui-expanded-final`
- `/var/tmp/bilicomics-bookstore-expanded-TGn5xYAc/ui-expanded-bookshelf-final`

## Real anonymous two-page capture

The separate live capture ran the production Runtime, Controller, Screens,
subprocess Runner, recommendation adapter and verified-TLS transport in a fresh
anonymous profile. It loaded **35 real recommendations** and captured the first
two pages at **600 by 800**, with **six complete covers on each page**. All 12
visible IDs were unique and followed the cached recommendation order.

The capture waited for valid bounded cover headers and an idle production
worker queue on each page, then used the actual next-page callback. It did not
inject a recommendation or cover and did not open a comic. The exact homepage
GET and production thumbnails for captured cards remained the only permitted
requests; no Cookie, Authorization, request body or unrelated worker was
allowed. The audit aggregates both pages' cover URLs.

All **13 requests returned HTTP 200**: one official homepage response and 12
visible cover thumbnails. There were no blocked operations or verification
errors. The profile retained no session file, favorite/history records or
download jobs. The Runtime closed normally, and all recorded production and
capture source digests remained unchanged during execution.

Both real screenshots were visually inspected for six loaded portrait covers,
readable two-line titles, compact source labels, correct page indicators and the
single bottom navigation row:

- [First real page](screens/bookstore-expanded-live/bookstore-expanded-live-page-01.png)
- [Second real page](screens/bookstore-expanded-live/bookstore-expanded-live-page-02.png)

`bookstore-expanded-live-result.json` records the native identities, recommendation
order, card rectangles, cover dimensions and page actions.
`bookstore-expanded-live-verification.json` binds the complete source digests,
anonymous request audit, responses and individual screenshot SHA256 values.
This is real service/emulator evidence, not physical e-ink hardware acceptance.

Remote live output:
`/var/tmp/bilicomics-bookstore-expanded-TGn5xYAc/live-expanded-final`.

## Reproduction

Run only on the remote host with a fresh output directory:

```powershell
ssh test-env 'PYTHONPATH=/var/tmp/bilicomics-bookstore-protocol-7g7nf8co/python-deps python3 /var/tmp/bilicomics-bookstore-expanded-TGn5xYAc/source/spec/ui/run_bookstore_expanded.py /var/tmp/bilicomics-bookstore-protocol-7g7nf8co/runtime/lib/koreader /var/tmp/bilicomics-bookstore-expanded-TGn5xYAc/source /var/tmp/bilicomics-bookstore-expanded-ui-new'
ssh test-env 'python3 /var/tmp/bilicomics-bookstore-expanded-TGn5xYAc/source/spec/ui/run_bookstore_expanded_live.py /var/tmp/bilicomics-bookstore-protocol-7g7nf8co/runtime/lib/koreader /var/tmp/bilicomics-bookstore-expanded-TGn5xYAc/source /var/tmp/bilicomics-bookstore-expanded-live-new --width 600 --height 800 --pages 2 --min-visible-cards 6 --min-recommendations 12'
```
