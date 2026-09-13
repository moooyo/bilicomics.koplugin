# Architecture stabilization and acceptance

Started on 2026-09-13 from `658650b28b4620187d9f5b2d3d0680c051753dd2`.
The user requested implementation of the architecture review plan. This record
separates current work from historical verification and keeps every remaining
acceptance gate visible.

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
| Real authentication | Mobile-app QR confirmation, identity validation, private persistence, process restart, and server-required refresh/confirmation succeed | QR generation and pending polling worked; the first bounded attempt ended without phone confirmation. Fresh current-source preparation is ready |
| Physical Scribe | Exact KOReader build, installation/cold startup, reading/offline restoration, memory, suspend/resume, touch, and e-ink refresh are observed on the device | Device unavailable; user confirmed on 2026-09-13 |
| Actual purchase | Explicitly authorized debit/asset consumption and delivered membership are verified separately | Not authorized and not executed |

All new tests, builds, syntax checks, and runtime probes run through
`ssh test-env`. Local work is limited to source editing, inspection, and artifact
transfer. Synthetic acceptance is network-isolated and cannot establish a real
login, a live refresh, physical device behavior, or a payment outcome.

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
QR lifetime. The current-source prepared attempt has not yet been started.

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
the target device before making a capacity claim. Reusing a same-pass validated
result may remove duplicate work, but must not remove corruption detection,
journal recovery, or explicit offline-integrity guarantees.

## Completion rule

The development candidate may be delivered with explicitly outstanding live or
device gates. The overall plan is not complete until the required acceptance
conditions are proved. Actual purchasing stays a separately authorized gate;
synthetic success must never be described as successful real payment.
