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
| Purchase dispatch validity | A persisted quote is rechecked immediately before transmission; queued, suspended, and maintenance-delayed expiry sends zero purchase requests and settles the intent | Implementation and remote regression in progress |
| Download completion on storage failure | Persistent metadata-write failure still delivers one completion, preserves journal ownership, and exposes a stopped download without claiming a durable write | Implementation and remote regression in progress |
| Current broad Controller fixtures | Both historical failing harnesses exercise current source-recovery and quote contracts without removing their business assertions | Remote reproduction and fixture repair in progress |
| Unified regression | Authentication, Controller, jobs, storage, recovery, purchase simulation, reader, startup, and package checks pass against one identified source snapshot | Unified runner in progress |
| Canonical candidate | One default archive, its exact manifest, and a source-bound acceptance report are linked from the top-level README | Pending regression and packaging |
| Real reading | A complete free chapter opens online, prefetches, finishes its retained download after reader closure, and reopens offline in a new process on the candidate source | Pending authenticated run |
| Real authentication | Mobile-app QR confirmation, identity validation, private persistence, process restart, and server-required refresh/confirmation succeed | Live acceptance preparation in progress |
| Physical Scribe | Exact KOReader build, installation/cold startup, reading/offline restoration, memory, suspend/resume, touch, and e-ink refresh are observed on the device | Device unavailable; user confirmed on 2026-09-13 |
| Actual purchase | Explicitly authorized debit/asset consumption and delivered membership are verified separately | Not authorized and not executed |

All new tests, builds, syntax checks, and runtime probes run through
`ssh test-env`. Local work is limited to source editing, inspection, and artifact
transfer. Synthetic acceptance is network-isolated and cannot establish a real
login, a live refresh, physical device behavior, or a payment outcome.

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
