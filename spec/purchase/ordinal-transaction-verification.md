# Ordinal transaction regression

The final report is [ordinal-transaction-result.json](ordinal-transaction-result.json).
It records 11 successful isolated processes: the affected state-machine cases
(34), protocol-boundary cases (12), 12 new ordinal transaction groups, and eight
SQLite persistence stages. The new ordinal cases made 489 assertions and built
57 quotes through production Fetch, Range, and Quote.

## Boundary

Execution used ssh test-env and the official KOReader v2026.07.1 LuaJIT runtime,
with a separate unshare -n network namespace for every process. The mandatory
entry point rejected production Transport requests and network/acquisition
module loading before loading Client or Service. No user session was read.

Catalogs, ownership, basic quote reads, and scoped quote reads were synthetic.
The fixtures called production Service, Fetch, Range, and Quote to derive the
positive and zero-limit ranges from the raw catalog and price evidence. They
did not construct an approval Boolean or claim that the server echoed the
resolved episode IDs. Client purchaseInfo and comicDetail were replaced with
synthetic read functions, so these cases do not establish their read-request
serialization.

Production Client buyEpisode serialized only into a strict in-memory transport.
There were 14 fake BuyEpisode route calls: 11 protocol-boundary calls, two ordinal
success responses, and one transmitted-timeout response. The timeout case records
a separate marker after every request check and asserts that marker outside
Service, preventing a swallowed request assertion from resembling the planned
timeout. Real Transport attempts and forbidden-module attempts were both zero.
Actual HTTP, charges, and live entitlement delivery were not permitted or tested.

## Covered behavior

- Positive and zero-limit quotes derive original episode IDs and exact fake wire
  fields from production range proof, including fractional start ordinals.
- An uncertain ordinal intent blocks disjoint new purchases of the same comic;
  a new ordinal purchase also conflicts with an existing same-comic single intent.
  Other comics remain independent, and disjoint single purchases retain their
  narrower overlap rule.
- An uncertain range whose original IDs become owned is readable but retains
  its range flag, pending-list entry, and same-comic lock. Reconciliation preserves
  the original action. A late accepted response clears the flag while preserving
  readable state; a late failure does not overwrite known acceptance.
- Definitive rejection and not-transmitted results clear the range flag.
  Acceptance clears the flag, while the accepted intent remains pending until
  access is confirmed.
- Real SQLite transactions roll back both journal and range-index writes when
  either write fails. An outcome-update failure preserves the durable pair and
  the in-memory observed result for a later flush.
- Separate processes exercise unfinished submission, transmitted timeout,
  recovery, original ownership, late acceptance, and final restart. Recovery
  rebuilds stale or missing indexes, including readable flagged intents.
- After initialization, pending-list refreshes use filtered states and indexed
  held IDs; the test rejects an unfiltered full-history query on that path.

## Reproducibility

The report contains all 19 production source hashes, spec and driver hashes,
the runtime hash, per-process evidence, and the unchanged-source check. The
tested Service SHA-256 is
051ec6d5f55be7c6c9013560a43117646ba44df908f89382db204eacaa1ff841,
and the Range SHA-256 is
dd185e9bd4a15a40cae0ebc60567d6d19b2bebf1680bf42f819a75c0b5a5516c.

The final remote artifacts are under
/tmp/bili-ordinal-transaction-yeY47i/review-final. The driver requires a fresh
output directory and runs only on Linux through SSH. Earlier intermediate
reports are preserved as ordinal-transaction-before-index-result.json and
ordinal-transaction-index-before-review-result.json; the latter predates the
independent timeout-marker assertion and is superseded by the final report.

No production defect was found by this regression. These synthetic results
establish local transaction behavior under the stated fixtures, not a live
server charge result or independent proof of server-side batch semantics.
