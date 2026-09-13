# Bookshelf grid verification

Date: 2026-09-13. Execution host: `ssh test-env`. Runtime: the isolated official
KOReader v2026.07.1 Linux emulator at
`/var/tmp/bilicomics-bookstore-protocol-7g7nf8co/runtime/lib/koreader`. No test, build or runtime probe was
executed on the local Windows machine.

## Native grid matrix

The production main entry, screen navigation and cover-card widgets were
exercised with an injected asynchronous controller. Each case used isolated XDG
directories and a separate network namespace. The cover illustrations were
drawn by the test runner and are visibly labeled `SYNTHETIC ORIGINAL ART`.
There was no real account, session, HTTP request, comic purchase or third-party
comic artwork in these checks.

| Language | Resolution | Assertions | Result |
| --- | --- | ---: | --- |
| Chinese | 480 by 640 | 92 | Passed |
| Chinese | 600 by 800 | 92 | Passed |
| Chinese | 720 by 960 | 98 | Passed |
| Chinese | 960 by 720 | 98 | Passed |
| English | 480 by 640 | 92 | Passed |
| English | 600 by 800 | 92 | Passed |
| English | 720 by 960 | 98 | Passed |
| English | 960 by 720 | 98 | Passed |

All 760 assertions passed. Reading and purchase-boundary checks were retained;
the removed standalone History layout checks were replaced with Bookstore-tab
and legacy history-link compatibility assertions. Coverage includes default Bookshelf entry and first
tab, two or three columns, equal card bounds and row alignment, visual/focus
order, visible-cover requests, pagination and page keys, a left-aligned final
single card, distinct local reading progress and latest-update labels, known
reading and unknown-history filters, and the empty bookshelf state. Bookstore
is the second tab, there is no separate History tab, and both legacy `history`
and `continue` links return to Bookshelf. The library UI requests only favorites;
retained controller history remains available for progress without a dedicated
history screen.

Bookshelf pagination now uses compact borderless arrows and a page count above
the covers, beside the reading hint. The matrix checks their position, compact
height, shared vertical center line, page count, first/last disabled state and operation through the actual
pagination controls. Only the four navigation tabs appear below the covers;
there is no second full-width pagination row. A one-page bookshelf and an empty
bookshelf omit pagination entirely. A dedicated single-page screenshot is
included for each language and resolution. Native page-key behavior remains
covered.

Actual native focus movement followed by repaint preserves the focused comic
and its border. Tap resolves the correct target before reading; a locked target
requests a quote without submitting a purchase. Hold opens the chapter catalog.
Old card callbacks are retired after page, filter, navigation and account
changes. Pending target resolution is retired on navigation and account change.
Page, filter, navigation and close actions invoke the optional
`cancelPendingRead` controller contract.

Two successive taps on different comics on the same page retire the earlier
request. Resolving the newer target before the older target dispatches only the
newer comic to `readEpisode`. Selecting another comic while the first is being
prepared cancels the earlier preparation; its obsolete completion cannot close
the new selection, which can still prepare its own reader target.

An initial native run found that automatic text-height adjustment gave cards
different heights and vertically shifted covers within a row. Fixed text slots
resolved the issue. The final matrix also verifies portrait cover frames on the
landscape display. The final screenshots were visually inspected for legible
titles and progress, aligned covers and the left-aligned short final page.

The source hashes and per-case outcomes are in
`bookshelf-grid-verification.json`; full assertion records are in
`bookshelf-grid-results/{language}-{width}x{height}.json`. The 64 synthetic
framebuffer screenshots are in `screens/bookshelf-grid/`. They establish native
layout behavior and controlled UI actions, not physical e-ink hardware or live
account acceptance.

Remote output: `/var/tmp/bilicomics-bookstore-7zKUkTCU/ui-bookshelf-bookstore`.

## Existing native regressions

| Harness | Cases | Assertions per case | Result |
| --- | --- | ---: | --- |
| Native business probe | 480 by 640, 600 by 800 | 101 | Passed |
| Session-file import | 480 by 640, 600 by 800 | 43 | Passed |
| QR sign-in, Chinese | 480 by 640, 600 by 800 | 50 | Passed |
| QR sign-in, English | 480 by 640, 600 by 800 | 50 | Passed |

Legacy `showLibrary("history")` and `showLibrary("continue")` calls now assert
Bookshelf navigation. The broad native probe activates the actual cover-card
callback, resolves the selected chapter, and selects Updated in the filter dialog. Its
existing purchase assertions were preserved while the old direct batch and
payment controls were adapted to the current Choose range/Choose payment
dialogs. All quote and purchase activity in this harness remains synthetic.

The individual native, session and QR regression receipts are also retained in
`bookshelf-grid-results/`. These runs supplement the focused grid matrix; the
controller's real pending-reader cancellation is covered separately by the
controller-focused checks.

All eight grid cases and all native/session/QR cases above were rerun after the
Bookstore navigation change and shared cover-grid extraction. Their current
receipts replace the older executions. The grid matrix hashes identify the
tested screens and locale. The separate `bookstore.md` report covers the new
recommendation destination and its account/read/purchase isolation.
