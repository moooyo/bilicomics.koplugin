# Complete bookshelf, bookstore, and search fidelity audit

This audit covers every chosen A, B, and C artboard in the supplied handoff,
plus their reachable menus, input dialogs, pagination, long content, and error
states. The alternate visual directions are references; the approved bookshelf
direction is 1b. The reference HTML was read offline, including its inline
measurements, and compared with actual KOReader framebuffer output. No browser
URL-policy workaround was used.

The screenshots use original synthetic cover art and synthetic records. Comic
names, account values, metadata, device status, dates, and record counts remain
service data in production. The table describes layout and state fidelity; it
does not claim browser-to-FreeType pixel equality.

| Artboard | Required content and geometry | Native evidence and outcome |
| --- | --- | --- |
| A1 | Resume cover at 56,150, 216x288 dp; bottom-aligned 66 dp actions; grid begins at y=555; 5 columns and 10 grid cards, excluding the resume comic | `A1-default.png`, hero/grid coordinate checks, most-recent-local-anchor and duplicate exclusion checks: pass |
| A2 | More panel: 440 dp wide, top 104, right 40; sync status, filter, sort, help, account | `A2-more.png` and filter/sort/help screenshots, panel coordinate and native action-bound checks: pass. Key devices retain a reachable chapter-catalog action as required by the handoff's keyboard behavior |
| A3 | True matched/total count, emphasized active filter, condition bar with the update count, clear action, filtered grid | `A3-filtered.png`, true-count and navigation-clearance checks: pass |
| A4 | Offline header and sync timestamp; offline chapter/full-series availability; explicit uncached-cover placeholder; cached content retained | `A4-offline.png`, full-series and missing-cover state checks: pass. Full-series availability requires an official latest ordinal and every corresponding chapter to be available offline |
| A5 | Centered sign-in block; 360x68 dp actions; separate downloaded-comic footer; direct QR login from the bookshelf | `A5-signed-out.png`, action-size, copy, action-bound, and QR-origin checks: pass |
| A6 | No partial grid; real fetched-comic count and visible-cover counters; static progress; 240x64 dp alternate destinations | `A6-first-sync-library.png`, `A6-first-sync-covers.png`, and `A6-completed-once.png`, library/cover phase and no-partial-grid checks: pass. Controller integration separately verifies real successful and settled cover outcomes |
| B1 | 88 dp toolbar, four columns, 12 cards, 240 dp cover slots, source/genre metadata | `B1-recommendations.png`, first-cover coordinate and capacity checks: pass. Thumbnail aspect ratio follows the handoff's existing image pipeline |
| B2 | Framed panel with 72 dp side margins and top 176; official subjects in four columns; current selection; update time and cancel | `B2-category-picker.png` and category-page-two, panel geometry, timestamp retention, action-bound, and page-turn checks: pass |
| B3 | Bottom sheet, 150x200 dp cover, top-aligned summary, author/publication/source metadata, bordered genre chips, complete paginated synopsis, chapter/follow/close actions | `B3-synopsis.png` and long-synopsis pages, cover dimensions, source/publication metadata, chip-border and pagination checks: pass |
| B4 | Offline category with zero loaded records; centered honest cache explanation; retry and saved-recommendations actions, 320x68 dp | `B4-offline-no-cache.png`, copy, alternative destination, action-size and action-bound checks: pass |
| C1 | 34 dp top gap, 72 dp field/search row; recent-search rows; ID and bookstore entries | `C1-initial.png`, history first/next/last pages, and native comic-ID input, geometry, reachability, and action-bound checks: pass. All eight stored searches remain reachable instead of silently dropping entries after five |
| C2 | Native InputDialog at x=56, y=160, width=818 dp; native field and keyboard; cancel/search | `C2-native-input-keyboard.png`, dialog-coordinate and native-keyboard checks: pass. The keyboard layout remains the user's KOReader keyboard setting |
| C3 | Query/clear field; result count and state chips; 130 dp rows with 78x104 dp covers, author/publication metadata and bookshelf tag | `C3-results.png` and result-filter dialog, row coordinate/height, metadata and action-bound checks: pass |
| C4 | Query preserved, centered no-result explanation, 320x68 dp edit and browse actions; no result-summary chips when no result exists | `C4-no-results.png` and search-error, query preservation, absent-summary, action-size and retry checks: pass |

The audit corrected centered state placement, missing filter counts, incorrectly
flattened synopsis tags, missing publication/source metadata, discarded search
history entries, and a result toolbar appearing on the no-result screen.
Pagination and same-screen repaint now use KOReader's `ui` refresh mode; tab and
screen changes use `flashui`. The actual rendering continues to use existing
KOReader rectangles, text, buttons, image widgets, and native input controls.

Run the domain acceptance with the shared official-runtime runner:

```text
python3 spec/ui/run_scribe_handoff.py RUNTIME PLUGIN OUTPUT \
  --sizes 1860x2480 480x640 600x800 960x720 --languages zh_CN C \
  --domains bookshelf bookstore search --extra-modules all_pages_abc_spec
```

The final [shared native receipt](../spec/ui/scribe-handoff-verification.json)
is authoritative for source hashes, assertion
counts, and output paths. Domain runs during parallel editing establish their
painted state and behavior but do not substitute for the final unchanged-source
matrix. The first-sync visual fixture also does not substitute for controller
tests: progress is derived from actual library responses and cover outcomes,
never from a hardcoded percentage.
