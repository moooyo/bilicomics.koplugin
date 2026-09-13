# Finishing acceptance

Date: 2026-09-13. Runtime: official KOReader `v2026.07.1` on `test-env`.

The finishing implementation passed a fresh phone-confirmed login, session
restart, and one complete real free-chapter online/download/offline workflow.
The [completion audit](finishing-completion-audit.md) maps all planned outcomes;
the [final binding](../spec/package/finishing-acceptance-binding.json) ties their
receipts and the canonical archive to the same production files.

## Implemented behavior

- Bookshelf remains the first and default destination, followed by Bookstore,
  Search and Downloads. Cached cards appear immediately; stale data synchronizes
  on entry. More holds refresh, last successful sync time, filters, ordering,
  chapter access and help. Account-specific position and focus are preserved.
- Cards show portrait covers, at most two title lines and one reading-position
  line. Filters are visible and directly removable. Help is shown once and can
  be opened again. Offline and temporarily unavailable synchronization states
  remain distinct from an unauthenticated account.
- New QR sessions receive the required official site context before publication.
  Saved sessions missing that context can recover without changing identity or
  renewal credentials.
- Concurrent image downloads are configurable from one through four, default
  two, and apply to online cache and retained chapters. Lowering the setting
  drains current work; visible pages retain priority. Jobs share requests and
  account for storage reservations until their processes have been reaped.

## Final real-account evidence

The [new login](../spec/integration/finishing-live-login-results.json) used the
native account QR action. Phone confirmation completed official site
initialization and private saving. Automatic favorites/history synchronization
succeeded and the unobstructed native bookshelf displayed its two expected
cards. The [independent restart](../spec/integration/finishing-live-restart-results.json)
restored the saved session, native bookshelf cache and normal session checks.
The service did not require credential rotation.

The [selection](../spec/integration/finishing-live-preflight-results.json) chose
the first explicitly free chapter of an account favorite and preserved its full
45-page index. The [complete reading receipt](../spec/integration/finishing-live-reading-results.json)
records these results:

| Observation | Result |
| --- | --- |
| Retained chapter | 45 of 45 pages, 92,022,101 image bytes |
| Native online opening | Reader opened before the first image and before chapter completion; real pixels replaced the placeholder |
| Prefetch | A next image was acquired without navigation |
| Configured and observed image concurrency | Default two; both actual call and process peaks were two |
| Genuine overlapping calls | 5.599092 seconds after excluding calls behind the initial test gate |
| Download after reader closure | 42 pages completed after closure; 40 image workers started after closure |
| Background overlap | 5.177855 seconds between calls started after reader closure |
| New-process offline opening | All pages present and pinned, same descriptor, restored native anchor and rendered pixels |
| Offline activity | Zero transport requests, worker starts and submissions; isolated network namespace and no session |
| Cleanup and identity | Workers reaped without forced cleanup; source, harness, runtime and guard hashes unchanged |

The [selection handoff](../spec/integration/finishing-handoff-select.json) and
[reading handoff](../spec/integration/finishing-handoff-read.json) bind the public
receipts and confirm that selection and reading received the same unchanged
SessionStorage input from this QR login. The
[executed wrapper](../spec/integration/finishing_handoff_runner.py) never reads or
exports credential contents. Private session paths, identities, raw logs and
downloaded comic images are excluded from repository evidence and the archive.

## Other verification and delivery

All 34 common remote suites, 31 focused controller cases, eight native UI cases
with 1,154 assertions, and the 25 real-process concurrency cases with 668
assertions passed. The concurrency matrix exercises limits one, two and four,
live changes, priority, ownership, storage and cancellation; its synthetic image
inputs remain separate from the real-service evidence above.

The canonical `dist/bilicomics-0.1.0-dev.zip` contains 108 files, with SHA-256
`43999a0ea657216a8f6206c74641a4c5f3832f95e66f02d9920b90c016905cbd`.
The finishing preview has identical bytes. All 208 production files match the
successful common snapshot
`a0b80892866598c0d4491e389a8a781044e1b8aacd3f5e231f34306149336dd6`.
The preceding canonical candidate remains under `dist/history/bookstore-d0dcc11e/`.

This acceptance covers the agreed finishing scope. It does not establish actual
purchases, coupon/card consumption, physical Scribe behavior, real credential
rotation or large-library capacity, which retain their expressly deferred status.
The successful complete-chapter checks do not imply manual visual inspection of
every comic page or physical e-ink performance.
