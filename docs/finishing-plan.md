# Finishing plan and download concurrency

Started: 2026-09-13, from `6646c11` on `codex/finish-and-concurrency`.
Status: complete for the agreed finishing scope. Implementation, authenticated
acceptance and all 51 final delivery-binding checks passed.
Verification host: `ssh test-env` only.

The active objective is to complete the previously identified finishing work
and add configurable concurrent downloading for retained and cached comics.
The current navigation remains Bookshelf, Bookstore, Search and Downloads;
the older proposal's History destination has been superseded.

## Required outcomes

1. Complete official site initialization for a newly confirmed QR login before
   publishing or persisting the authenticated session. Restore already saved
   sessions that lack the device context without replacing their account or
   renewal credentials. Initialization failures and stale/canceled responses
   must not install an incomplete or foreign session.
2. Implement the approved bookshelf experience: show cached cards immediately,
   synchronize stale favorites and reading history on entry, retain a manual
   sync command and its success time in More, preserve per-account filters,
   ordering, grid position and focus, distinguish empty/error/filter states,
   and avoid reordering cards on cover arrival. Use the quiet header and bottom
   navigation, compact title/progress captions, visible removable active filters,
   first-use help and accessible chapter actions for touch and keys.
3. Enable real concurrent image acquisition with a persistent user control.
   The current image resource limit and the retained-download per-chapter pump
   must both permit parallel work. Concurrency changes must affect dispatch,
   retain visible-page priority, preserve deduplication and ownership, and respect
   storage reservations, suspend/cancel, session and account generations.
4. Verify the final combined source through focused regressions and a real fresh
   QR session, followed by a complete free chapter: online opening before full
   download, prefetch, retained download continuing after reader closure, and
   new-process offline reopening with the correct anchor and no network/workers.
5. Deliver one deterministic plugin archive and source-bound evidence, together
   with native screenshots for the new bookshelf and concurrency control. Audit
   every outcome above against the final source before completing the goal.

## Implementation interfaces

Bookshelf synchronization uses a 15-minute freshness policy and one coalesced
favorites/history refresh. Both source lists must succeed before one atomic
publication, preserving local following changes and exact reading anchors.
Automatic synchronization occurs on bookshelf entry, never on a periodic timer
while reading. Per-account view state is stored separately from service data.

The planned download setting is `download_concurrency`, integer 1 through 4,
default 2. It controls the shared image pool, with one additional non-image
worker slot. Decreasing the setting stops replenishment above the new limit;
it does not terminate already started work merely to reach the new count.
This fixed range is a client policy, not a physical-device performance claim.

## Retained exclusions

Actual purchases, coupon/card consumption, physical Scribe acceptance, real
credential rotation/old-token confirmation, and 1/5/10 GB capacity claims retain
their previous deferred status. Production renewal capability remains intact;
the live acceptance harness must not force or perform the deferred rotation.
Only user-confirmed QR login is used for the final authenticated acceptance.
No local runtime testing is authorized in this goal.

## Evidence tracking

All reports for this goal use a new finishing/concurrency/site-context scope.
Earlier reports and the `d0dcc11e` candidate keep their original source identity.
Synthetic tests do not substitute for real parallel worker execution or the
final authenticated online/download/offline workflow. Real account input and
downloaded chapter images remain outside the repository and plugin archive.

## Current progress

The implementation is present in the finishing branch. Directed tests have
passed for site initialization, atomic bookshelf synchronization and view state,
native UI, and real worker concurrency. The third frozen common regression
passes all 34 suites on production snapshot
`a0b80892866598c0d4491e389a8a781044e1b8aacd3f5e231f34306149336dd6`.
The first attempt exposed outdated valid-session fixtures and incomplete
isolated test staging; those were corrected without weakening their behavioral
assertions or changing production to accommodate them.

The first actual QR-login attempt used the same production source and expired
without phone confirmation. The driver and workers terminated cleanly and its
QR image was removed. A subsequent phone-confirmed fresh login and independent
restart passed on the final source, followed by the complete 45-page real
online/download/offline workflow. The [acceptance record](finishing-acceptance.md)
and [requirement audit](finishing-completion-audit.md) preserve each proof's scope.

The canonical archive is `dist/bilicomics-0.1.0-dev.zip`, with 108 files
and SHA-256 `43999a0ea657216a8f6206c74641a4c5f3832f95e66f02d9920b90c016905cbd`.
`dist/bilicomics-finishing-preview.zip` has identical bytes. The preceding
canonical candidate remains under `dist/history/bookstore-d0dcc11e/`.

The [preview binding](../spec/package/finishing-preview-binding.json) now verifies
all 208 production files against the successful common regression and every one
of the 108 packaged files against that production tree. It also binds the native
UI matrix, site initialization, concurrent-worker cases, and the 31 controller
cases rerun with the final Runner. The common suite matches the current
production and recorded test inventory. The concurrency fixture does not load
the plugin UI; that separate matrix now passes 1,154 assertions in eight cases.
That earlier preview receipt retains `goal_complete=false` and `release_ready=false`.
The [final binding](../spec/package/finishing-acceptance-binding.json) adds the
successful authenticated workflow and exact session-input handoff receipts.

The audit found and corrected one UI state error: inability to synchronize no
longer implies an unauthenticated account. Authenticated offline and temporarily
unavailable states retain their identity, show the appropriate explanation, and
disable dispatch until synchronization is possible. Reconnection enables retry;
anonymous accounts keep the QR action. The new native cases preserve all 986
preceding assertions and add 168 checks. Earlier UI and preview evidence remains
in `spec/ui/history/bookshelf-finishing-986/` and
`spec/package/history/finishing-5ea0dce8/`.

Fresh acceptance directories were prepared on test-env from source snapshot
3: `/var/tmp/bilicomics-finishing-OHQWOHTS/auth-ready-final` and
`/var/tmp/bilicomics-finishing-OHQWOHTS/reading-ready-final`. Both subsequent live
phases completed and cleaned their workers. Reading used the original confirmed
SessionStorage input and preserved its file identity throughout selection and
execution. Offline reopened without a session and dispatched no network or workers.

The finishing work follows the earlier bookshelf and categorized Bookstore
delivery `6646c11` and was developed on `codex/finish-and-concurrency`. Production
file hashes, rather than a caller-supplied revision label, identify its acceptance.
