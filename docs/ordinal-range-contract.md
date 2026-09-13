# Ordinal Range Contract

Implementation date: 2026-09-13. This document describes a supported intended
range, not server-returned member IDs or a verified purchase transaction.
No real purchase is part of this implementation or its synthetic checks.

Current validation: production Fetch/Range/Quote construction has also passed
against newly acquired authenticated responses for a 20-chapter positive offer
and an explicit-zero remaining offer containing 123 intended chapters. Both
returned `submittable=true`; no purchase request was sent. See
[the public live construction result](../research/protocol/ordinal-range-live-result.json).
Unsupported or inconsistent inputs remain advisory; batch construction is no
longer universally advisory or awaiting permission for quote observation.

## Decision and evidence

The [implementation plan](implementation-plan.md), sections 3.4 and 8, requires
an exact intended chapter set and the original server-supported scope. It does
not require the server to echo chapter IDs. The earlier research condition
that an explicit server ID list was necessary was stronger than that plan.
This implementation instead derives a reproducible intended set under the
official ordinal-range contract and checks fresh quote/catalog consistency.

The existing [primary-source contract](../research/protocol/batch-quote-contract.md)
records the official PC SDK's original catalog reversal (decoded offsets
2771640–2772300), batch `with_ord_scope/start_ord/limit` request and original-price
reference (2808540–2810080), positive-limit intended-ID helper
(2811878–2812540), and `TheRestEpisodes=0` enum (3066740–3066890).
The [sanitized live observations](../research/protocol/live-batch-observation.md)
distinguish anchor-inclusive remaining aggregates from whole-comic aggregates
at additional anchors. They also show shortened positive offers marked
unusable and a separately usable zero offer.

The proof markers are fixed:

```text
contract: bilibili_pc_ordinal_range_v1
provenance: primary_sdk_ordinal_contract_and_quote_catalog_consistency
server_confirmed_ids: false
```

Positive IDs follow the SDK helper. Zero IDs are derived from the official
remaining-range structure and the observed anchor-relative aggregate contract;
the SDK's positive-count success helper does not enumerate zero-range IDs.

## Resolver input and conservative limits

`bilicomics/purchase/range.lua` exports:

```lua
local proof, err = Range.resolve{
    info = basic_info,
    range_info = scoped_info,
    raw_detail = detail,
    comic_id = comic_id,
    episode_id = anchor_id,
    selection = normalized_selection,
}
local equal = Range.matches(proof, independently_recomputed_proof)
```

Only `coin` with `discount.kind="none"` is supported by this resolver. The
account may have optional discounts; inventory alone does not prevent choosing
ordinary currency. The generated payload has no coupon/card/credit fields.
Discounted or additional-asset selections retain the existing advisory path.

The required original source is `detail.extra.ep_list`, with matching raw and
normalized comic identity. A normalized/stored episode list, a synthesized
default ordinal, or an unverified alternative `episodes` field is insufficient.
The original array must be nonempty, dense and at most 20,000 entries. Every
row needs a unique positive decimal episode ID, unique finite numeric `ord`,
literal Boolean `is_locked`, and finite nonnegative numeric `pay_gold`.
Reversing that original array must already be strictly ascending by ordinal;
the resolver does not sort a conflicting response into an apparently valid one.
Fractional ordinals are preserved without rounding.

The anchor must be an ordinary paid, locked chapter. Every row from the anchor
to the end of the original reversed catalog must be unambiguously ordinary
locked, permanently owned, or free. The known `pay_mode` values are 0/1 and
`unlock_type` values for this path are 0/1. Temporary flags, unknown combinations,
unavailable content, conflicting purchase flags and unknown expiry reject the
range. Missing or string-valued lock flags, including `"FALSE"`, are not false.
Expiry accepts only absence, empty text, numeric zero or the exact
`0000-00-00 00:00:00` sentinel; other dates are not assigned a guessed timezone.
Rows before the anchor still contribute explicit locked counts/prices and
structural identity/order validation, but are not prospective batch members.

## Offer, aggregate and price checks

Both basic and scoped responses must match the comic and, when present, anchor
ID; both must explicitly report the anchor locked. Raw server `ep_id` omission
is not represented as a server echo. Full offer arrays must be dense, bounded
to 512 entries and semantically identical in original order across both reads.
Every row retains `batch_limit`, `amount`, `usable`, original/display prices,
and the original discount fields. Unusable rows remain in the array and price
vector. Missing and zero remain different.

Select the exact original offer index and limit. Without an index, duplicate
matching limits are ambiguous. The chosen row must have literal
`usable=true` and positive integer `amount`.

- A positive limit selects the first N explicitly locked chapters from the
  anchor inclusively, skipping known free/owned rows. Require
  `N == batch_limit == offer.amount == selected_count`.
- Zero selects every explicitly locked chapter from the anchor inclusively.
  It requires an explicitly usable zero offer and
  `offer.amount == selected_count == after_lock_ep_num`.

For both forms, the selected catalog-price sum must equal both server
`offer.original_gold` and `offer.pay_gold`. The payable reference is always the
server offer, never single price multiplied by chapter count. Finite amounts
and sums must remain within the exact supported numeric bound; no rounding or
tolerance silently accepts a discrepancy.

Both quote responses must also agree with the catalog's layers:

| Quote layer | Required association |
| --- | --- |
| `ep_original_gold`, `pay_gold` | Anchor catalog price |
| `original_gold`, `remain_lock_ep_gold` | Sum of all explicitly locked catalog prices |
| `remain_lock_ep_num` | Count of all explicitly locked catalog chapters |
| `after_lock_ep_gold` | Sum of locked prices from the anchor inclusively |
| `after_lock_ep_num` | Count of locked chapters from the anchor inclusively |

Top-level discount fields are preserved in the semantic evidence and must be
consistent across basic/scoped reads. Their enum values do not select another
price formula. Optional fields that are present must have their supported
numeric type. Any failed condition remains advisory.

The implementation does not convert an unusable or shortened positive offer
to zero and does not equate zero with Full. It does not use `prime_info` defaults
as chapter counts. The existing complete original-price vector remains
`[ep_original_gold, original_gold, ...all_original_offers.original_gold]`.

## Collection, independent reconstruction and confirmation

`quote_fetch.lua` calls the resolver for standard-currency batch selections
after the existing basic/detail/scoped collection. It returns the proof in
`context.range_proof`; failure carries a compact error classification and
leaves the existing candidate path available. The original detail is returned
once, not copied into the proof.

`Service.buildQuote` must forward the complete detail as `Quote.build.raw_detail`.
`Quote.build` independently calls the same pure resolver against that detail,
basic response and matching scoped response. The recomputed structured result
must exactly match the collector proof. Neither a caller's
`exact_scope_verified=true`, injected `episode_ids` nor `final_pay_amount`
authorizes a batch. Normalized selected access must also remain locked.

The proof includes contract/provenance, a SHA-256 basis digest, comic and anchor,
the exact original ordinal scope and offer index, intended IDs, count, server
amount and the selected server-offer fields. The digest streams canonical
semantic catalog rows and a compact header containing the complete ordered
offer list and aggregate relationships. It excludes URLs, titles, credentials,
timestamps and display-only text. This binds evidence without placing the
large original catalog in the quote or its confirmation fingerprint.

`quote.range_proof` participates in `Quote.fingerprint`, together with the
existing account, selection, expected access, amounts and payload. Account
identity is bound at that quote/journal boundary. The current exact scope is
stored in `quote.episode_ids`; the official wire scope remains
`{comic_id, with_ord_scope=true, start_ord, limit}`. Zero remains zero. A fresh
post-confirmation collection must reproduce the same semantic fingerprint;
changed members, order, eligibility, relevant price or discount fields require
renewed confirmation. Local SHA-256 consistency is not a server signature or
idempotency key.

## Remaining transaction boundary

There is no server-provided atomic range version. Concurrent unlocks or catalog
changes can alter which members the server processes after the last read,
including same-price changes invisible to totals alone. This implementation
establishes the intended set and supported request representation, not an
atomic server guarantee.

Actual debit, additional-asset consumption, delivery of ownership and zero-limit
purchase execution have not been tested. Persist before transmission, serialize
submissions, never automatically replay uncertain results, and reconcile each
intended chapter's permanent access. An unresolved ordinal transaction must
also conservatively block potentially overlapping purchases in the same comic;
checking only the old intended-ID intersection cannot cover a shifted range.
Ownership may permit reading without establishing a transaction receipt.

These are transaction and delivery evidence limits, not a requirement to keep
every supported range permanently disabled. The dedicated synthetic checks in
`spec/purchase/ordinal_range_spec.lua` run only under remote `unshare -n`, with
real Client, Transport, Session and Service modules forbidden. Their result is
recorded separately and does not claim a real purchase.

The final focused run passed 15 groups and 240 assertions on the pinned
official KOReader v2026.07.1 runtime. It recorded zero forbidden-module attempts
and zero purchase calls, with unchanged source snapshots. See the
[focused result](../spec/purchase/ordinal-range-result.json); the remote report
is `/tmp/bili-ordinal-spec-A5ycTZ0C-02/results.json`.

## Authenticated-response construction result

The latest public observation records seven business requests, four of them
quote reads, and one pinned public WASM download. All listed HTTP statuses are
200 and `blocked_requests=0`. From the collected responses, the production
collector and Quote builder returned these results:

| Case | Intended chapter count | Original offer index | Submittable | Fingerprint available |
| --- | ---: | ---: | --- | --- |
| Positive range | 20 | 1 | true | true |
| Explicit-zero remaining range | 123 | 3 | true | true |

For both cases the report confirms that the payload preserves the range limit
and uses the server amount. It retains the documented contract/provenance and
`server_confirmed_ids=false`; `real_submit_executed=false` for both cases.
The report's legacy `exact_scope_verified=false` is consistent with these
results: current construction checks the independently recomputed ordinal
proof and never upgrades or trusts that Boolean flag.
The three captured-response read callbacks per construction are not additional
HTTP requests. This validates production construction using real response
shapes, not a purchase or an independent second acquisition by Fetch.

The tested candidate uses the unchanged `range.lua` (`dd185e9b...`),
`quote_fetch.lua` (`ca01b376...`) and `quote.lua` (`aa3fcb46...`) sources recorded
by the focused verification. This documentation review inspected the current
modules and only the designated public observation; it did not access the new
private responses or session, execute an API, or change production code.
Actual debit, ownership delivery and atomic server membership remain outside
this evidence. Ordinary confirmation and transaction recovery requirements
still apply; a successful constructed quote does not itself authorize charging.
