# Complete handoff acceptance

All 43 chosen artboards, A1 through J5, were audited and corrected against the
supplied HTML and README. Directions 1b, 1d and 1h are the approved defaults;
the other direction studies are references rather than additional product
routes. The browser's local-file policy was respected: reference measurements
were read offline and compared with actual KOReader widget geometry and
framebuffer captures.

## Requirement-by-requirement evidence

| Pages | Detailed audit | Final verification receipt |
| --- | --- | --- |
| A1-A6, B1-B4, C1-C4 | [Bookshelf, bookstore and search](all-pages-abc.md) | [Shared native suite](../spec/ui/scribe-handoff-verification.json) |
| D1-D4, F1-F4 | [Catalog and downloads](all-pages-def.md) | [Native D/F suite](../spec/ui/all-pages-def-verification.json) |
| E1-E5 | [Purchase](all-pages-purchase.md) | [Shared native suite](../spec/ui/scribe-handoff-verification.json) |
| G1-G4, H1-H3, I1-I4 | [Account, sign-in and recharge](all-pages-ghi.md) | [Native G/H/I suite](../spec/ui/all-pages-ghi-verification.json) |
| J1-J5 | [Native reader and errors](all-pages-reader.md) | [Native reader suite](../spec/ui/all-pages-reader-verification.json) |

The final UI matrices passed 19,537 assertions and generated 2,514 native
captures across Chinese and English at 1860x2480, 480x640, 600x800 and 960x720.
Every one of the 43 page IDs has a full-frame native capture at all eight
size/language combinations. The aggregate
[coverage receipt](../spec/ui/all-pages-acceptance.json) verifies source identity,
suite acceptance, PNG signatures/dimensions and per-page coverage; it has no
missing page entries. Chapter jump and reader connection failure use their
actual matching-result and error-dialog states, not empty or context-only shots.

The root review also inspected the ten contact sheets and representative
full-resolution captures. Supplemental captures cover menus, input dialogs,
long history and prose, each selection/filter, imported/expired credentials,
QR request/expiry races, recharge history/failures, each download-recovery
category, multiple retained versions and every reader error destination.
Multi-page flows were exercised forward, backward, repainted and operated
after returning; traversal is not limited to first or last page screenshots.

## Corrections and real data

- First-sync counters now come from actual library responses and cover outcomes.
  The initial grid publishes only after the selected visible covers settle.
  Filter, sort, anchor, favorite and source changes are rechecked before
  publication, with an overall deadline to prevent an endless preparation loop.
- Download sizes come from observed bytes of the exact selected revision.
  Estimates use known page counts and observed samples; missing information
  remains unknown. Replacement counts require a validated current descriptor,
  so an old 24-page copy cannot be presented as a new 32-page version.
- Storage uses decimal MB/GB. Presets store exact byte limits. Existing binary
  limits are retained and displayed accurately rather than silently lowered or
  falsely highlighted as an exact decimal preset.
- Key focus, disabled colors, right alignment, static footer summaries, pager
  sizing, repaint modes and shared page ownership were corrected. Status-strip
  repaint reads device time/battery, and network events update the existing strip.
- QR expiry retires slow callbacks. Sign-in returns to its origin. Credited
  receipts update when a wallet observation arrives, including same-second
  observations. Backward recharge/recovery pagination no longer frees reused
  native text resources.
- Reader errors and closure are scoped to the original reader generation.
  Offline access uses real entitlement and cache checks, while existing error
  destinations and explicit purchase confirmation remain intact.

The actual-controller/SQLite/filesystem preparation suite passed 132 checks;
[its receipt](../spec/controller/ui-preparation-verification.json) records
isolated, synthetic worker responses and unchanged sources. Shared widget
checks passed 37 assertions. Additional historical purchase, download,
replacement, session and controller invariants were preserved and rerun where
affected. No real account, purchase or recharge was used.

The packaged plugin also loaded, opened its native account screen, exited
through the native menu and repeated this successfully on restart. Its read-only guard was installed and no session was
present. Repeated packaging produced 124 files and the same SHA-256,
`eef95450ad3cc8487dca44d97432b6e4458506a7ffead1d872d115311566ddf1`.
The [package receipt](../spec/package/scribe-ui-acceptance.json) binds this
archive to the complete UI matrix and distinguishes earlier focused checks.

## Boundaries

Native bundled fonts approximate the reference font; physical e-ink behavior
and live payment outcomes are outside emulator acceptance. Fictional art,
prices, balances, names and QR patterns are not installed as production data.
Unknown quantities are stated explicitly. The bookstore slot/image aspect and
the settings footer retain the documented resolutions of conflicting HTML and
README instructions. These are recorded reference/data boundaries, not omitted
pages or substitute implementations.

The gallery builder is `spec/ui/build_all_pages_gallery.py`; it consumes only
accepted evidence. The complete coverage verifier is `spec/ui/verify_all_pages.py`.
Keep profiles, captures and raw logs outside the repository when reproducing.
