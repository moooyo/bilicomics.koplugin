# Progress recovery

Recovered on 2026-09-13 from merged commit
`e86f894742dba66242e582dbfb8510e941ebd616`.
Both local `main` and the remote `main` identified that commit when recovery
started, and the working tree was clean.

## Completed scope

The previous architecture stabilization and revised local KOReader acceptance
are complete. The archived task's last operation merged and pushed the completed
work. Its [acceptance matrix and completion rule](architecture-stabilization.md)
remain authoritative. There is no unfinished implementation step in that scope.

| Area | Recorded outcome |
| --- | --- |
| Architecture corrections | Purchase quote validity is checked at dispatch; persistent storage errors settle downloads without losing journal ownership. |
| Unified regression | All 34 remote synthetic suites passed on one identified production tree. |
| Real reading | A 45-page chapter passed online opening, prefetch, retained download after reader closure, and independent-process offline reopening; 51 online and 30 offline checks passed. |
| Real authentication | Phone QR confirmation, private persistence, restart and a normal server session check passed. |
| Revised local acceptance | The canonical package passed visible WSLg startup, native session import/restart, an authenticated online request and complete online/offline reading. |
| Integration | The completed work was merged and pushed to `main` as `e86f894`. |

These outcomes identify the accepted development candidate. They do not declare
all first-release payment or physical-device requirements satisfied.

## Current delivery and recovery verification

Use [bilicomics-0.1.0-dev.zip](../dist/bilicomics-0.1.0-dev.zip) and its
[adjacent manifest](../dist/bilicomics-0.1.0-dev.manifest.json). The ZIP contains
101 files and 2,466,094 bytes, with SHA256
`45385c6ff3cc99d2639f92575fb6db0ac363ab20aa76800aa7bbdbdbe93f5342`.
The authentication and quote-preview archives are historical candidates.

The [recovery identity check](../spec/package/progress-recovery-results.json)
ran through `ssh test-env`. It verified all 201 production files from the merged
commit against the existing unified regression, the bound regression report,
the exact delivered ZIP and manifest, and all 101 packaged files against the
source. The later acceptance record uses a canonical path/hash-map digest;
the original package binding separately records the manifest file's byte digest.
Both identities match their respective records.

This recovery reran no business or live-account workflow and performed no local
verification. It read only public source, delivery artifacts and evidence.
The [original package binding](../spec/package/stabilization-source-evidence.json)
and [later acceptance addendum](../spec/package/local-acceptance-source-evidence.json)
retain their original execution dates and test-source boundaries.

Recovery also clarified historical wording in the README, implementation status,
implementation plan and package guide. No production module or candidate ZIP
changed.

## Future work and retained decisions

| Item | Status and prerequisite |
| --- | --- |
| Credential rotation and old-token confirmation | Explicitly deferred after the service returned `refresh=false`; real rotation and long-term retention remain unverified. |
| Actual purchase and asset consumption | Not authorized or executed. Requires explicit authorization for the concrete account, chapters and asset amount before live payment acceptance. |
| Physical Scribe acceptance | Removed from the completed task. Device startup, input, memory and e-ink behavior remain necessary before advertising physical support. |
| Large offline-library capacity | Future measurement at 1, 5 and 10 GB on a declared target; current evidence does not establish those capacity claims. |
| Controller decomposition | Future refactoring, not a missing stabilization fix; preserve the documented lifecycle, storage, reader and purchase contracts. |

The [implementation plan](implementation-plan.md) remains the product baseline.
Its broad release gates must not be mistaken for unfinished steps in the
completed stabilization task. New verification uses `ssh test-env` unless the
user explicitly authorizes local verification for that task; the prior local
acceptance record is not a standing local-testing authorization.
