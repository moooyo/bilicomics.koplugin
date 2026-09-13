# Quote selection and ordinal batch implementation

Date: 2026-09-13. The current implementation supports single-episode coin and
reading-coupon quotes, plus standard coin batch quotes under the strict ordinal
range contract. Extra discount/card choices remain advisory. The user has
authorized operations other than actual purchases; read-only live quotation
and isolated synthetic transaction tests have now run. No actual purchase was
submitted, and neither live debit nor physical Scribe acceptance is established.

## Selection and read collection

Selection.normalize copies and validates scope/payment before worker dispatch.
It preserves discount order, the original one-based batch_buy offer index,
fractional anchor order, reading-coupon IDs and explicitly selected discount
kind/ID. Price, eligibility, proof and extra-asset amount inputs are rejected.
The none option cannot carry an asset ID.

quote_fetch.run is shared by the default quote worker and synchronous service
API. It obtains basic purchase info, the matching current raw catalog, and a
separate scoped response. It keeps base offer order and the complete original
price vector. Only an explicitly selected discount card requests calculated
prices. A selected free-gold card uses the established batch offer.amount
eligibility query; single/full counts are not invented. Context binds comic,
episode and the exact normalized selection. Read collection does not submit a
purchase or consume a coupon/card.

Candidate.describe keeps original price, platform display price, submission
formula reference and free-gold credit as distinct observations. It consumes
the optional_discount_list union using its explicit discriminator and usability
fields. Constructor defaults, aggregate card totals and similar field names
cannot replace missing evidence. Calculated prices require the same complete
original vector and an exact original-amount key; missing/conflicting entries
remain unknown. No real asset is automatically selected.

Client.purchaseInfo accepts the observed absent ep_id response by binding it to
the requested episode. A present malformed or different episode ID is rejected,
as is a malformed present comic ID. Valid numeric and string identities are
normalized without scientific notation. An absent comic ID still requires the
matching catalog in Fetch.

## Confirmable quotes and ordinal ranges

Quote.build preserves canonical selection and amount/asset observations in
confirmation fingerprints. Single-episode coin payment requires present, equal
ep_original_gold and pay_gold, plus a usable balance. Different or missing
amounts produce an advisory candidate. Reading coupons keep their separate
ID/eligibility path. Extra discount/card choices remain non-submittable until
their consumption contract is established.

For standard coin payment with no extra discount, production Range derives the
intended range from the original raw catalog, basic/scoped quote consistency,
the selected original offer position, eligibility, counts and exact price sums.
It preserves fractional ordinals. Positive limit N means the first N eligible
locked chapters beginning at the selected anchor. Zero means the remaining
locked chapters from that anchor, including it when eligible; it is not a
separate whole-comic selection. Client preserves the resulting start_ord and
positive/zero limit in the ordinal request form.

Fetch supplies context.range_proof, and Quote independently recomputes it from
the same raw evidence and requires an exact match. The proof contract is
bilibili_pc_ordinal_range_v1, with provenance
primary_sdk_ordinal_contract_and_quote_catalog_consistency. It explicitly keeps
server_confirmed_ids=false. This is a supported ordinal purchase primitive and
a current expected episode list, not a claim that the server returned those
exact IDs. No caller-supplied Boolean or predicted ID array grants permission.
Missing, contradictory or unsupported evidence cannot produce a submittable
quote. The obsolete blanket restriction that all production batches remain
advisory applies only to the earlier preview snapshots.

Advisory objects have submittable=false, fixed blockers and selectable options,
but no purchase payload, confirmed payable total or confirmation fingerprint.
Controller does not save them as confirmable quotes, Service rejects them, and
UI provides no purchase confirmation action for them.

Controller refreshes the same copied selection and uses its stored confirmation
snapshot rather than caller-mutated quote tables. Selection, scope, original
offer position, prices, assets, range proof and current access participate in the
fresh structural comparison. Changed terms require new explicit confirmation.

## Pending outcomes and presentation

Service journals the original intended IDs and action before dispatch. An
uncertain ordinal outcome blocks further purchases of the same comic, including
disjoint quoted IDs; a new ordinal request also conflicts with an existing
same-comic pending single purchase. Other comics are not blocked by that
uncertain outcome, although an active submission still blocks all new
submissions. If all original IDs become owned, reading can continue while
range_outcome_pending and the same-comic purchase lock remain until a definitive
transaction outcome.
Late acceptance clears that flag without discarding confirmed access. Definitive
rejection or a proven not-transmitted result clears the flag; accepted intents
remain pending until access is reconciled.

The journal and purchase.range_pending_ids index are written atomically. Startup
rebuilds the index from history once; ordinary pending-list refreshes use
filtered states and indexed held IDs instead of scanning completed history.

The native UI has paginated range/payment selection, discount/expiry ordering,
candidate details, exact reading-coupon ID details and recovery from changed
selections. Ordinal confirmation leads with the range rule and labels IDs as the
current expected list. It explains that catalog changes or purchases on another
client can alter the actual members. Readable access with an unresolved range
outcome remains visibly pending. These views have isolated native rendering and
callback evidence at 600x800 and 480x640.

## Evidence and deliverables

The latest [live read-only observation](../research/protocol/ordinal-range-live-result.json)
completed seven business requests and one pinned signing-asset request, including
four quotes: basic, single, positive batch and remaining batch. Production
Range/Fetch/Quote then consumed the captured reads and returned submittable
standard coin quotes for the positive 20-chapter and remaining 123-chapter
ranges. Both retained the original offer index and range limit. The report
records server_confirmed_ids=false and zero actual submissions. This bounded
run made no wallet, image or account-mutation request; that is its measured
scope, not a continuing prohibition on read-only wallet operations.

| Evidence | Scope and limit |
| --- | --- |
| [Ordinal range modules](../spec/purchase/ordinal-range-result.json) | 15 groups and 240 assertions through production Range/Fetch/Quote with synthetic raw catalogs and quote responses; no live submission. |
| [Ordinal transaction regression](../spec/purchase/ordinal-transaction-result.json) and [scope](../spec/purchase/ordinal-transaction-verification.md) | 489 ordinal assertions across 12 groups and eight SQLite stages, plus affected 34 state-machine and 12 protocol cases; 11 isolated processes, real range derivation, strict in-memory Client transport, real-network attempts zero. |
| [Ordinal native UI](../spec/ui/ordinal-range-verification.json) | 106 assertions at each of 600x800 and 480x640; synthetic quotes and fake Controller, one explicit fake submission per process, no actual purchase. |
| [Earlier selection modules](../spec/purchase/quote-selection-result.json) | 259 assertions in the earlier preview: selection copying, basic/scoped separation, original vectors, identity/amount preservation and advisory behavior. Its all-batch-advisory result is historical, not the current Range contract. |
| [Client response identity](../spec/protocol/purchase-info-identity-result.json) | 115 assertions with real Client/Fetch and strict fake quote/catalog inputs; absent-ID compatibility and malformed/mismatched-ID rejection. The report retains its earlier source hashes. |
| [Acceptance request guard](../spec/local/readonly-guard-results.json) | 209 assertions for exact read admission and mutation denial using real Client request construction and strict fake Transport/Runner originals; no real session or network. This is guard evidence, not Service/UI acceptance. |
| [Earlier native selection UI](../spec/ui/quote-selection-verification.json) | 141 assertions per size for pagination, advisory details, retained selection, coupon IDs and stale confirmation callbacks; synthetic Controller only. |

These checks ran remotely through ssh test-env. Synthetic executions used
unshare -n and isolated profiles. Individual reports retain their original
source hashes and boundaries; their counts are not one end-to-end transaction.
The earlier [syntax result](../spec/purchase/selection-syntax-result.json) and
[preview provenance](../spec/package/quote-preview-source-evidence-before-arm.json)
remain historical preparation evidence and are not presented as the current
behavioral limit.

The integrated default development artifact is dist/bilicomics-0.1.0-dev.zip.
Use its [manifest](../dist/bilicomics-0.1.0-dev.manifest.json),
[package verification](../spec/package/remote-results.json) and
[source provenance](../spec/package/source-evidence.json) for the current file
set and hashes. Earlier quote-preview and reading archives retain their own
snapshot evidence; their file counts and digests do not identify the integrated
artifact. Package verification does not establish local interactive startup or
physical device execution.

## Remaining acceptance

Actual coin deduction, coupon/card consumption and live post-purchase range
membership remain untested because actual purchases are prohibited. Extra
discount assets remain advisory. The supported ordinal proof does not turn its
expected IDs into a server receipt. Physical Scribe installation, lifecycle,
memory and e-ink acceptance remain separate open work. This is a development
implementation, not a completed release.
