# Architecture stabilization and acceptance

This completed task records the earlier 101-file candidate, now retained under
`dist/history/stabilization-45385c6f/`. The default ZIP was subsequently updated
by [the bookshelf revision](bookshelf-grid.md); its separate evidence does not
relabel the source snapshots recorded here.

Started on 2026-09-13 from `658650b28b4620187d9f5b2d3d0680c051753dd2`.
The user requested implementation of the architecture review plan. This record
separates current work from historical verification and keeps every remaining
acceptance gate visible.

The user revised the acceptance target on 2026-09-13: physical Scribe execution
is not required for this task; use the actual local KOReader runtime instead.
Local verification is explicitly authorized for this task. This changes the
acceptance target, not the evidence of physical Kindle compatibility.
After the service returned `refresh=false`, the user also explicitly moved real
credential rotation and old-token confirmation to later acceptance. Completing
the local KOReader checks is sufficient for this task; those deferred behaviors
must remain recorded as unverified.

## Scope and retained architecture

Keep native ReaderUI and the immutable `.bcomic` provider, worker-side network
requests, main-process SQLite ownership, journaled image commits, independent
reader/download ownership, and separate session and purchase state machines.
The immediate changes address dispatch validity and asynchronous completion,
then establish a common source snapshot for regression and packaging.

The Controller remains the application facade for this stabilization. Future
extraction of account lifecycle, reading coordination, and purchase coordination
should preserve those contracts. UI dialog construction should ultimately live
in Screens rather than being split across Screens and Controller. A broad
reorganization is not a prerequisite for proving the reviewed boundary fixes.

## Required outcomes

| Requirement | Evidence required | Current state |
| --- | --- | --- |
| Purchase dispatch validity | A persisted quote is rechecked immediately before transmission; queued, suspended, and maintenance-delayed expiry sends zero purchase requests and settles the intent | Passed: 11 focused scenarios, 72 assertions, plus the unified transaction regressions |
| Download completion on storage failure | Persistent metadata-write failure still delivers one completion, preserves journal ownership, and exposes a stopped download without claiming a durable write | Passed: 30 download scenarios, including real SQLite read-only failure and later recovery |
| Current broad Controller fixtures | Both historical failing harnesses exercise current source-recovery and quote contracts without removing their business assertions | Passed: 69 Controller and 28 authentication assertions in the unified snapshot |
| Unified regression | Authentication, Controller, jobs, storage, recovery, purchase simulation, reader, startup, and package checks pass against one identified source snapshot | Passed: all 34 suites at `7cfdc660bf7c21256bf900ea82d36ae5cae80c01` |
| Canonical candidate | One default archive, its exact manifest, and a source-bound acceptance report are linked from the top-level README | Produced and verified remotely; `dist/bilicomics-0.1.0-dev.zip` is the canonical candidate |
| Real reading | A complete free chapter opens online, prefetches, finishes its retained download after reader closure, and reopens offline in a new process on the candidate source | Passed: 45 pages, 92,022,101 bytes, 51 online and 30 offline checks; production tree matches the candidate |
| Real authentication | Mobile-app QR confirmation, identity validation, private persistence, process restart and normal server session check | Passed: real QR confirmation, private save, independent-process restoration and server session check |
| Credential rotation | Server-required credential replacement and old-token confirmation | Explicitly deferred by the user after refresh=false; neither live rotation nor long-term retention is claimed |
| Local KOReader | The current candidate starts in the actual local runtime, restores across process restart, and passes online/download/offline reading in an isolated local profile | Passed: visible WSLg startup at two sizes, native import/exit/reopen, the first renewable-session online request, and 45-page real online/download/offline reading |
| Physical Scribe | Device-specific startup, memory, input and e-ink refresh observations | Removed from this task's required gates by the user; physical compatibility remains unverified |
| Actual purchase | Debit/asset consumption and delivered membership require separate explicit authorization | Deferred outside this task; not authorized and not executed |

The first stabilization matrix ran through `ssh test-env`. The user subsequently
authorized local KOReader verification for this task, so the remaining local
acceptance uses isolated WSL/WSLg profiles and records that host honestly.
Synthetic acceptance is network-isolated and cannot establish a real login,
a live refresh, physical device behavior, or a payment outcome.

## Current evidence

The [unified regression report](../spec/integration/stabilization-regression-results.json)
binds all 34 suites to commit `7cfdc66` and snapshot SHA256
`5e665ad960c27891d706be95016bf4aa6b884e4bd3e33a979ee401e57eb82caa`.
The [package/source binding](../spec/package/stabilization-source-evidence.json)
connects the verified archive to that production tree and the
[real online/offline run](../spec/integration/stabilization-live-reading-results.json).
The live run executed at `d7617f2`; subsequent changes before `7cfdc66` affected
tests and evidence, and the complete production manifests are identical.

The canonical ZIP contains 101 files and 2,466,094 bytes, with SHA256
`45385c6ff3cc99d2639f92575fb6db0ac363ab20aa76800aa7bbdbdbe93f5342`.
Its adjacent manifest lists every packaged file. After evidence collection,
[scoped cleanup](../spec/integration/stabilization-live-reading-cleanup.json)
removed this run's acquired images, private runtime data, and copied input
credential. The original user-supplied credential file was not changed.

The first combined run passed 33 of 34 suites. Its two failing worker assertions
were already inconsistent with the unchanged production quote collector and
cover URL contract: they expected a malformed batch scope to be accepted and a
cover to carry the chapter-only `complete_url` field. The repaired worker suite
asserts the current three-step read collector, copied selection context,
malformed-scope rejection, and unmodified cover URLs. It now passes 84 assertions
inside the final matrix. No production behavior was weakened to make it pass.

Independent review also caught two composition issues while implementing the
fixes: a new dispatch refusal must not erase a historical unknown transaction,
and a failed pause request must not display a still-running worker as stopped.
Both are covered by the final focused regression.

The [first QR attempt](../spec/integration/stabilization-auth-attempt-1.json)
used the earlier authentication source. It successfully generated and polled a
real QR but received no phone confirmation within the 180-second operator
window. Its clean timeout is not evidence of successful login or a fixed server
QR lifetime. The subsequent current-source
[login attempt](../spec/integration/stabilization-auth-login-results.json)
received real phone confirmation, verified the account through the production
identity endpoint, and saved the renewable session privately. A
[separate process](../spec/integration/stabilization-auth-restart-results.json)
loaded that session, checked cookie information and revalidated the identity.
Both phases closed all owned workers and retained unchanged source hashes.
The server did not require rotation; no refresh or confirmation HTTP request was
sent, and neither is claimed as live-tested.

## Local acceptance under the revised target

The exact canonical ZIP also passed
[local complete-chapter reading](../spec/local/live-reading-candidate-results.json)
as the ordinary WSL user. Its 101 packaged files match the original 201-file
production map; the omitted files are native build sources. All 51 online and
30 independent offline checks passed with 45 real pages and 92,022,101 image
bytes. Offline execution used separate user and network namespaces, no session,
no routes, and no workers. The original input was not changed.

The [visible startup result](../spec/local/candidate-startup-result.json) and
[anonymous layout review](../spec/local/candidate-layout-review.json) cover
720x960 and 600x800 WSLg windows, native exit/reopen, preserved profile state,
and exact candidate files. The
[native session result](../spec/local/native-session-result.json) then covers
the actual production import of the newly scanned session, a private 0600 save,
native exit and restored login in a new process. The one-time export was deleted;
no authenticated screenshots or credentials were added to the repository.

The [first local online request](../spec/local/renewable-online-result.json)
then used that same restored profile and the actual production Runner. Cookie
information, identity validation and the favorites read all succeeded; the
business callback completed once and session maintenance returned to ready.
The service again returned `refresh=false`. One incidental cover exceeded the
existing 4 MiB production response limit and used the normal fallback; this is
recorded separately rather than described as a successful image request.
The observer process exited, and the normal authenticated WSLg window was
reopened without the one-time import or observer enabled.

The acceptance-only guard now permits the exact production authentication
routes while continuing to reject purchasing and unrelated account writes.
[Its isolated regression](../spec/local/authentication-guard-results.json)
passed 162 cases and 279 assertions. The full local reading workflow retains
its narrower read-only guard. Cancellation and Python-optimization defenses
added to the local wrapper after the successful real run have their own
[four-case isolated evidence](../spec/local/live-reading-wrapper-results.json);
the original real-run test hashes are preserved rather than relabeled.

[Scoped local cleanup](../spec/local/live-reading-cleanup.json) then verified
all 49 recorded process identities had terminated and removed this independent
reading run's private images, account data, selection and raw logs. It retained
269 public evidence and code files unchanged. The separate authenticated visible
profile and the user's original Windows credential file were not touched.

The [local acceptance addendum](../spec/package/local-acceptance-source-evidence.json)
binds the exact candidate archive and current production tree to all remote
authentication, local startup, import, first-online-request, complete-reading,
layout, guard, wrapper and cleanup evidence. It preserves historical harness
hashes and records the user's deferred gates without marking them verified.

After successful local import and online use,
[remote authentication cleanup](../spec/integration/stabilization-auth-cleanup.json)
removed the extra remote session and export while preserving the external code
and public login/restart reports. The authenticated local profile remains the
active session used by the visible KOReader window.

## Historical evidence

- `06e794b` introduced the full plugin and earlier scoped evidence. The real
  45-page reading run belongs to its documented historical source snapshot.
- `658650b` added QR login and renewable sessions. Its ten-suite authentication
  regression is distinct from full reading and device acceptance.
- The historical default development archive contains 96 files. The later
  authentication candidate contains 101 files and was delivered as
  `bilicomics-0.1.0-dev-auth.zip`; these are different artifacts.
- The two historical broad Controller harness failures are documented in
  [session renewal](session-renewal.md). Their existence must not be hidden by a
  passing focused authentication summary.

## Capacity acceptance

Startup currently verifies ready image files during PageStore reconciliation
and rechecks completed jobs through explicit completeness verification. The
existing getter benchmark excludes startup and uses approximately 24 MiB of
images. It does not establish startup performance with a large offline library.
Measure startup and chapter opening with 1, 5, and 10 GB retained libraries on
any future declared physical target before making a capacity claim. This is a
future capacity characterization, not a remaining Scribe gate for the revised
local acceptance task. Reusing a same-pass validated
result may remove duplicate work, but must not remove corruption detection,
journal recovery, or explicit offline-integrity guarantees.

## Completion rule

The architecture stabilization and the user's revised local acceptance task are
complete. Real credential rotation/old-token confirmation were explicitly moved
to later acceptance, and physical Scribe execution was removed from this task.
Those behaviors remain unverified. Actual purchasing stays separately authorized
release work; synthetic success must never be described as successful real
payment. The artifact remains a development candidate, not a claim that every
future device or payment release gate has passed.
