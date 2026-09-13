# Finishing completion audit

Date: 2026-09-13. Result: all agreed finishing outcomes proved. Implementation,
controlled verification, the final authenticated workflow and all 51 delivery
binding checks passed against the actual uploaded checkout and canonical archive.

This audit covers every required outcome in [the finishing plan](finishing-plan.md)
and the approved [bookshelf proposal](bookshelf-experience-proposal.md). It does
not promote historical account-reading evidence to the current revision.

## Source and evidence identity

The canonical archive contains 108 packaged files from 208 production files.
Its SHA-256 is `43999a0ea657216a8f6206c74641a4c5f3832f95e66f02d9920b90c016905cbd`.
The [preview binding](../spec/package/finishing-preview-binding.json) checks every
production file against common-regression snapshot
`a0b80892866598c0d4491e389a8a781044e1b8aacd3f5e231f34306149336dd6`, every archive
member against production, and every common child receipt against its recorded hash.
All verification executed on `test-env`; this goal performed no local runtime checks.
The [final binding](../spec/package/finishing-acceptance-binding.json) adds the
fresh login, restart, input handoff and whole-chapter reading evidence.

Evidence abbreviations used below:

- **Protocol:** [site initialization](../spec/protocol/site-context-verification.json),
  including 11 protocol groups and 86 assertions, lifecycle, cancellation and guard checks.
- **Controller:** [31 focused cases](../spec/controller/finishing-bookshelf-controller-verification.json)
  with the final Runner, real SQLite and controlled worker responses.
- **UI:** [eight native cases and 1,154 assertions](../spec/ui/bookshelf-finishing-verification.json)
  across Chinese/English and four screen sizes, with synthetic covers/accounts.
- **Concurrency:** [25 cases, 668 assertions and 126 real child processes](../spec/jobs/finishing-concurrency-results.json),
  using synthetic image bytes. These cases do not call the real comic service.
- **Common:** [34 passing suites](../spec/integration/finishing-regression-results.json),
  including the [27 package checks](../spec/package/finishing-results.json).
- **Live:** [fresh login](../spec/integration/finishing-live-login-results.json),
  [restart](../spec/integration/finishing-live-restart-results.json), and
  [complete reading](../spec/integration/finishing-live-reading-results.json),
  using the input proven by the [handoff](../spec/integration/finishing-handoff-read.json).

## Requirement mapping

| Required behavior | Current implementation and direct evidence | Result |
| --- | --- | --- |
| 1. Initialize a new QR candidate before saving or publishing it | `Auth:pollQR`, `SiteContext.ensure`; Protocol: `Confirmed QR sessions receive their site cookie before nav and publication`; Live login records the official site-context response, confirmed login and durable context | Controlled and fresh real-account verification passed. |
| 1. Restore a saved session without replacing identity or renewal credentials; reject failures and late results | `SessionManager:_ready`, `_persist`; lifecycle cases `static_restoration_is_saved_before_dispatch`, `static_restoration_preserves_credentials_and_markers`, `account_generation_prevents_late_site_publication` | Controlled verification passed. |
| 2. Cached cards first, automatic stale refresh, atomic favorites/history publication and preserved anchors | `Screens:showFavorites`, `Controller:ensureBookshelfSync`, `syncBookshelf`; Controller covers both response orders, 900-second boundary, storage rollback and `Local exact anchors survive conflicting chapter level server history`; Live login syncs both lists and restart restores cache | Controlled and real-account sync verification passed. |
| 2. Keep cache on failure, distinguish cache/account/filter empty states and offer recovery | `Screens:_bookshelf`, `_more`; UI covers initial failure, confirmed empty, filter clear, authenticated offline and temporarily unavailable states, and retry after reconnect | Native verification passed. The audit's authentication-versus-connectivity defect is fixed. |
| 2. Manual sync and last success time in More; avoid periodic reading-time sync | Controller activity/offline/suspension and manual bypass cases; UI `more_preserves_the_last_confirmed_sync_time`, `more_exposes_Refresh_bookshelf` | Controlled verification passed. |
| 2. Account-specific filter, sort, page and focus; stable cover repaint order; return after reader closure | `BookshelfState`, `Screens:_saveBookshelfView`, `Controller` reader-close hook; Controller restart/isolation/multiple-reader cases; UI `background_source_and_cover_repaint_preserve_the_visible_order`, `native_reader_close_automatically_restores_the_saved_bookshelf` | Native controlled view-state verification passed. Live separately verifies real Reader closure and restored offline reading position. |
| 2. Quiet header, compact pagination, four destinations, removable filters and compact card captions | `Screens:_bookshelf`, `Widgets.navigation`, `Widgets.card`; UI default header/underline, filter-clear, fixed-title/single-position and removed-latest-caption cases | Native verification passed. |
| 2. One-time help, replayable help and keyboard-accessible chapter actions | `Screens:_bookshelfHelp`, `_selectedBookshelfComic`, `_more`; UI help acknowledgement/reentry and selected-comic menu cases | Native verification passed. |
| 3. Persistent 1–4 image concurrency, default 2, for cache and retained downloads | `Settings`, `Controller:setSetting`, shared image resource and `DownloadService` page window; Controller initialization, persistence/restart, invalid value and failed-write cases; native settings menu cases | Controlled verification passed. |
| 3. Real parallel execution, including within one chapter | Runner cases `runner_real_overlap_1/2/4`; Service cases `single_chapter_real_parallel_download_1/2/4`; Live records 45 calls with peak two and 5.599092 seconds of overlap after excluding the initial gate | Configurable limits verified with real processes; default two also verified against real-service images. |
| 3. Runtime changes and visible-page priority | `Runner:setImageConcurrency`, `DownloadService:refreshConcurrency`; increase/refill, downshift/drain and `visible_page_preempts_background_and_restarts_once` | Real process verification passed. |
| 3. Deduplication, owner sharing, failure accounting, cancellation and generations | Concurrency cases for visible owner promotion, pause, failed-page owner retirement, ready-page count, immediate resume and source/account isolation | Real process/storage verification passed. |
| 3. Shared filesystem reservations and reap-before-release | `Budget.scope/admit`, Runner reservations; same/different filesystem, retry/preemption and cancel/timeout/reap cases | Real process verification passed. |
| 4. Final combined regression | Common 34 suites, Controller 31 cases, native UI matrix and separate concurrency/protocol evidence matched by the preview binding | Passed within the documented synthetic/controlled scopes. |
| 4. Fresh QR confirmation, saved-session restart, then complete real online/cache/download/offline chapter workflow | Live login and restart pass; reading retains all 45 pages, starts before images finish, prefetches, finishes 42 pages after Reader closure, and restores the native anchor offline with zero requests/workers | Passed on the final source with the same QR-derived input. |
| 5. Deterministic package and native screenshots | Canonical 108-file archive, package checks and UI screenshots, including the new offline/More states; final binder matches the actual delivered default/concurrency PNG bytes to their remote native output | Passed against the actual uploaded files and archive. |
| 5. Requirement-by-requirement final acceptance binding | This audit plus 51 passing final binding checks links the exact source, archive and 26 successful live/controlled evidence files | Complete for the agreed finishing scope. |

## Authenticated workflow and retained limits

The [expired login receipt](../spec/integration/finishing-login-expired-results.json)
records `login_confirmed=false`, `ensureSiteContext=0`, `session_saves=0` and
`automatic_bookshelf_sync_verified=false`. Its worker/driver cleanup passed.
A fresh attempt was subsequently confirmed by the user. Its public login and
restart receipts passed; the earlier expired attempt remains a separate record
and is not counted as successful authentication evidence.

The final source has been staged into `auth-ready-final` and `reading-ready-final`
under `/var/tmp/bilicomics-finishing-OHQWOHTS/`. The
[reading preparation receipt](../spec/integration/live-reading-ready-final-preparation.json)
proves staging and syntax only. The subsequent live receipts prove the successful
real phases. Both drivers and their workers have completed, and the QR image was
removed from the remote environment and the local display directory.

The [acceptance record](finishing-acceptance.md) summarizes the 45-page run,
92,022,101 verified image bytes, real two-worker peak and independent offline
restoration. The timing gate excludes initially blocked calls from overlap
evidence. The
[observer-only checks](../spec/integration/image-worker-timing-observer-results.json)
remain separately scoped and do not replace the real run.

The final source/evidence binding passed, including exact input handoff and
recomputed real concurrency intervals. Actual purchases, physical
Scribe testing, real credential rotation and capacity claims retain the plan's
explicit deferred scope. The finishing branch follows the preceding `main`
delivery `6646c11`; Git history records the final integration commit.
