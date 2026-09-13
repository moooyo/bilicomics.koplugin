# Ordinal batch-range UI verification

This focused update separates the platform's ordinal purchase rule from the
chapter list predicted by the current catalog. It does not change quote
construction, purchase submission, transaction reconciliation, or controller
behavior.

`Model.ordinalRange` recognizes the top-level `quote.range_proof` contract
`bilibili_pc_ordinal_range_v1` and provenance
`primary_sdk_ordinal_contract_and_quote_catalog_consistency`. A candidate marked
`submittable=false` is not promoted by this display helper. Neither proof data
nor its internal identifiers appear in the product UI.

For recognized batch quotes, the confirmation screen leads with the first N
locked chapters starting at the selected chapter. A zero limit means remaining
locked chapters from that chapter, including the anchor when eligible; it does
not mean the entire comic. The total charge, payment balance, expected access and
explicit confirmation remain visible. The batch chapter viewer is labeled as
the current expected list and explains that catalog updates or purchases on
another client can change the actual members. It identifies the selected
starting chapter using existing catalog titles. Single-chapter confirmation
keeps its existing chapter list and wording.

The scope selector also names zero-limit offers as remaining chapters from the
selected chapter. Scope and payment changes still request a new quote. No
server amount or range proof is copied into selection arguments by these UI
changes.

When `intent.range_outcome_pending=true`, confirmed reading access is not
presented as a confirmed purchase. The result screen explains that the range
transaction remains unknown and further purchases for that comic are paused.
The pending list includes the same reason. Existing read/download continuation
buttons remain available; this UI adds no receipt, retry-submission or manual
clear operation.

## Focused test boundary

`ordinal_range_spec.lua` uses synthetic quotes and a strict fake controller in
an independent native KOReader process. `run_ordinal_range.py` starts only this
spec at 600 × 800 and 480 × 640 through `unshare -n`, with isolated HOME, KO_HOME,
and XDG directories. The spec checks the network namespace and empty routing
table, and prohibits loading actual Controller, Runtime, Client, Transport,
Session, PurchaseService and quote modules.

The fixtures cover positive and zero ranges, current expected chapter labels,
anchor titles, absent or mismatched proof markers, candidate behavior, changed
quote amounts requiring a new explicit confirmation, stale confirmation
callbacks, and unchanged single-chapter presentation. They do not validate live
server range membership or perform an actual purchase. The earlier 141-case
quote-selection runs are preserved separately and are not repeated by this
runner.

Evidence files are `ordinal-range-verification.json`,
`ordinal-range-result.json`, and `ordinal-range-result-480.json`. Native
framebuffer captures are stored below `screens/ordinal-range/`.

The final run passed 106 assertions at each size. Every isolated process made
one explicit fake submission and zero actual purchases. All 11 prohibited
business modules remained unloaded, and production source hashes were unchanged
during the run. Both sizes' range summaries and unresolved-result views were
visually inspected; the narrow range picker, expected-list details and pending
row were also inspected. The pending range row reserves enough height for its
two-line reason instead of shrinking it into a normal one-line row.

The successful remote evidence directory is
`/tmp/bilicomics-ordinal-range-ui-Jsxcm4/run-2`. Relative result paths in the
verification JSON refer to this original directory. The preceding run also
passed, then the pending-row height was adjusted after inspecting the screenshot
and the focused checks were rerun against that final source. No earlier broad
UI suite was executed.
