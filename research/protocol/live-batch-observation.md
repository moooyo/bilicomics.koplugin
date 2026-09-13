# Live Batch Quote Observation

Observation date: 2026-09-13. **Current status: strict ordinal-range construction
is implemented and has passed with newly acquired authenticated responses for
20-chapter positive and 123-chapter explicit-zero remaining ranges. Both quotes
were submittable, with no actual submission.** The earlier seven-quote evidence
below remains historical evidence of field and aggregate relationships; it is
not a server echo of members or a charging test. The companion
[sanitized observations](live-batch-observation.json) contain only field types,
counts, booleans and equality results, with no account, comic, episode or asset
identities, monetary values, titles, acquisition URLs or raw response text.

## Evidence boundary

The parent reports seven initial business requests and one pinned public WASM
request, with four successful HTTP 200 quote responses, followed by three
successful bounded quote reads. The initial analysis independently read the
following six already captured JSON files on `test-env`, under
`/tmp/bili-quote-live-J7fPZ05L/run2`:

- `basic-decoded-private.json`, `single-decoded-private.json`,
  `batch-1-decoded-private.json`, `batch-2-decoded-private.json`;
- `catalog-decoded-private.json`, `selection-private.json`.

The follow-up analysis additionally read `selection-extra-private.json` in
that directory and only `interior-basic-decoded-private.json`,
`interior-scoped-decoded-private.json`, `tail-basic-decoded-private.json` under
the sibling `ranges` directory, alongside the existing catalog. No additional
private capture or account file was inspected.

The historical HTTP acquisition report is attributed to the parent; HTTP logs and request
captures were not read. The private files were parsed as JSON on the remote
host and only aggregate observations were emitted. No session/nav file was
read, no SDK was executed, no API request or purchase test was made, and no
production file was changed. No raw captures were copied into the repository.

The latest review separately read only the designated public result,
`/tmp/bili-range-live-NZvtNRY5/run2/observation-public.json`, now preserved as
[ordinal-range-live-result.json](ordinal-range-live-result.json). It inspected
the current Range/Fetch/Quote sources but did not read any private file from
that run, execute an API or modify production. The earlier seven raw quote
observations are not replaced or retrospectively counted as successful
construction tests.

The source comparison uses the existing first-party evidence in
[the batch contract](batch-quote-contract.md) and
[the discount contract](discount-selection-contract.md). Locators below are
zero-based character offsets in the pinned decoded SDK described there.

## Initial four responses

All four responses omit raw `ep_id` and return a `comic_id` matching the
selection. The selected anchor is unique and locked in the matching catalog.
Consequently the request context supplies anchor identity; a normalized
fallback `ep_id` must not be described as a server echo.

Each response contains three usable `batch_buy` offers. The complete array,
including original order, is equal across basic, single and both batch reads.
`batch_limit`, `amount`, price and discount fields are JSON numbers; `usable`
is a Boolean. The first two offers have positive `batch_limit == amount`; the
third has `batch_limit == 0 < amount`. No offer exercises `batch_limit > amount`.
All corresponding `original_gold` and `pay_gold` values are equal, including
the single-episode fields. No missing-to-zero conversion is needed for these
observed fields. This is a sample-specific equality, not a general pricing rule.

The catalog has 171 unique episode IDs, 123 explicitly locked chapters and one
fractional ordinal. Reversing its original array yields ascending ordinals.
The anchor is the first locked chapter: there are no locked chapters before
it, and 123 locked chapters from it inclusively, versus 122 exclusively.
There are 46 unlocked chapters after the anchor; no temporary-free flag or
nonzero expiry is present in this sample. The locked tail has uniform catalog
prices, each equal to the anchor's original quote price.

For each positive offer, the SDK's predicted chapter count equals `amount`,
includes the anchor, and has a catalog-price sum equal to the offer's original
price. However, these two predicted prefixes skip no unlocked chapters and
contain no fractional ordinal. Taking a plain contiguous prefix produces the
same IDs here. Thus this sample does not distinguish the locked-filter rule
from a contiguous-prefix rule for positive batches.

The zero offer's `amount` and price equal the locked tail's count and catalog
price sum. They also equal the whole catalog's locked count and price sum,
because no locked chapter precedes this anchor. These equalities therefore
cannot distinguish anchor-relative remaining chapters from all unowned
chapters in the comic.

## Additional fields are aggregates, not exact scope

The response includes `after_lock_ep_num`/`after_lock_ep_gold`, both Number,
alongside `remain_lock_ep_num`/`remain_lock_ep_gold`. In all four responses,
both count fields equal the anchor-inclusive locked count and whole locked
count; both price fields equal the corresponding catalog-price sums. They do
not equal the anchor-exclusive count/sum. This suggests an inclusive aggregate
for this sample, but does not prove its general meaning, eligibility rules or
membership. Field names alone do not establish a protocol contract.

`prime_info.batch.batch_buy` contains three aligned rows. Each row's `ep_cnt`
equals the corresponding offer's `amount`, and `origin_price` equals that
offer's `original_gold`. These are useful observed associations for a future
presence-aware adapter, not independent scope proof. Both
`optional_discount_list` and `recommend_coupon_ids` are empty, so no selected
discount/card behavior or actual asset consumption is covered.

The four structured responses contain only these array paths:
`batch_buy`, `prime_info.batch.batch_buy`, `optional_discount_list`, and
`recommend_coupon_ids`. There is no explicit `episode_ids`, `ep_ids`, `ep_list`,
`start_ord`, `end_ord`, `scope_revision`, `quote_id`, `final_pay_amount` or
`exact_scope_verified` field. The separate `one_gold_comic_buy_info` object has
zero `chapter_id`/`limit`, empty `start`/`end` and false `is_locked`; it supplies
no batch range in this observation. Presentation strings and preview image
fields are not treated as an alternative membership contract.

## Source comparison and limits of the historical observation

The SDK computes the submit reference `limit = batchLimit > amount ? 0 :
batchLimit` (2808540–2810080). After a reported purchase success, its helper
starts at the anchor in `episodeList.slice().reverse()` and predicts the first
`limit` entries with truthy `isLocked`, including the anchor
(2771640–2772300, 2811878–2812540). This is client-side prediction after success,
not a server-confirmed list in these read responses. With zero limit the loop
predicts an empty list. The distinct Full path omits the batch range tuple and
uses different reference-price branches (2803200–2804700); zero must not be
relabeled Full.

For the sampled no-extra-discount case, the SDK's batch submit reference uses
the selected offer's `originalGold` (2808540–2810080). The observed equality to
displayed price removes that particular ambiguity for this sample. It does
not establish a debit: all locked catalog prices are equal, so many different
chapter sets of the same size have the same total. A matching count and sum
cannot identify the exact set. Multiplying the anchor price by `amount` also
matches here, but must not become a general price calculation.

Still unproved are positive membership outside these nondiscriminating
prefixes; zero-limit membership; usable submission through the
`batchLimit > amount` branch; treatment
of fractional, temporarily unlocked or unavailable chapters; nonuniform
prices; quote-to-submit freshness; and actual debit or asset consumption.
These historical count/price observations alone do not justify a
server-confirmed episode list or the old `exact_scope_verified` flag. The later
[ordinal-range contract](../../docs/ordinal-range-contract.md) combines the
official request/intent algorithm with independently recomputed fresh evidence
to construct a supported intended range. It does not require a server ID echo,
and it does not turn read observations into charging verification.

## Follow-up selection and actual observation

At the parent's request, two anchors were derived from the same captured
catalog. Their actual IDs and unchanged ordinals were written only to
`selection-extra-private.json` in the existing private capture directory,
using exclusive creation, mode 0600 and a flushed write. This analysis called
no further API. The safe selection summary is:

| Label | Available | Locked before | Locked remaining, inclusive | Locked after |
| --- | --- | ---: | ---: | ---: |
| `interior` | true | 61 | 62 | 61 |
| `tail` | true | 104 | 19 | 18 |

The parent subsequently performed three reads: interior basic and zero scoped,
then tail basic. The tail scoped request was correctly skipped because no
positive offer met both the usability and shortened-amount conditions. This
was the intended bounded stop, not a failed request; the four-read maximum was
not exhausted by a substitute query.

All three raw responses again match the selected comic, omit `ep_id`, and
provide no explicit chapter-list or scope-proof fields.

In all three responses, `after_lock_ep_num` equals the captured anchor-inclusive
remaining locked count and differs from both the exclusive and whole locked
counts. `after_lock_ep_gold` equals the inclusive remaining catalog-price sum
and differs from the whole locked price sum. In contrast,
`remain_lock_ep_num`, `remain_lock_ep_gold` and top-level `original_gold`
continue to match the whole locked count/sum. This resolves the original
sample's whole-versus-remaining ambiguity at the level of these quote
aggregates. It does not establish general eligibility rules.

The interior zero offer is usable; its `amount` and price equal the
anchor-inclusive remaining locked count and price sum, not the whole locked
count/sum. The interior basic and scoped complete batch arrays, `prime_info`,
after-count and after-price are equal. The sampled zero quote therefore has
anchor-relative remaining semantics. It is not evidence for what
`BuyEpisode` does with a submitted zero limit, or proof of explicit members.

Tail basic has two positive-limit offers with `usable=false`. Both have a
positive `amount` smaller than their nominal limit, equal to the remaining
locked count, and both prices equal the remaining catalog-price sum. Its zero
offer is usable and has the same remaining count/price. Thus shortened amount
and a populated price do not make a positive offer selectable. The
`batchLimit > amount` inequality is now observed, but not in a usable positive
offer; it cannot authorize the SDK's hypothetical submit-side conversion to
zero or prove equality with direct-zero/Full submission.

## Price-vector hierarchy in the follow-up

All three basic/scoped responses retain a complete five-entry source vector:
`[ep_original_gold, original_gold, ...batch_buy[].original_gold]`. All entries
are present nonnegative numbers. `prime_info.single.origin_price` equals the
episode original price; `prime_info.whole.origin_price` equals top-level
`original_gold`, which still describes the whole locked catalog. Each batch
prime row's `origin_price` equals its corresponding offer's original price,
and `ep_cnt` equals that offer's `amount`. A zero-limit batch row's original
price now differs from the whole-comic vector entry. Those layers must remain
separate.

At the tail, all three batch original-price values happen to be equal, despite
two offers being unusable. Preserve both unusable rows and every original
position in the vector; filtering them would change the SDK's index
association. Repeated numeric values do not make row identities interchangeable.
The `single.ep_cnt` and `whole.ep_cnt` prime fields are explicit zero in these
responses; they must not replace the actual episode/range count. These are
observed field relationships, not a `CalDiscountPrice` result or evidence of
discount/card consumption. The optional discount arrays remain empty.

The comparisons remain tied to the captured catalog and assume no intervening
catalog or entitlement change; disagreement is evidence to investigate, not a
license to infer a new rule. Uniform prices still allow distinct same-sized
sets to have equal totals. No response count, sum or predicted list by itself
provides exact membership, transaction freshness or actual charging evidence.
The earlier server-echo condition was a research decision, not a quotation of
the user's feature request. It has since been replaced by the documented
recomputation and confirmation conditions in the ordinal-range contract.

## Current live construction, separate from the seven historical quotes

The latest public report records `completed=true`, seven business requests,
four quote reads, one pinned public asset request and zero blocked requests.
Every listed request has HTTP status 200. The production Fetch/Range/Quote path
then constructed two quotes from those collected responses:

| Property | Positive range | Explicit-zero remaining range |
| --- | --- | --- |
| Intended chapter count | 20 | 123 |
| Original offer index | 1 | 3 |
| Collector and Quote returned | true | true |
| `submittable` | true | true |
| Confirmation fingerprint available | true | true |
| Payload preserves range limit | true | true |
| Payload uses server amount | true | true |
| `server_confirmed_ids` | false | false |
| `real_submit_executed` | false | false |

Each construction records three captured-response read callbacks; these are
not additional HTTP requests or a second live catalog/quote collection.
The public legacy `exact_scope_verified` field remains false; successful
construction comes from the independently recomputed ordinal proof, not from
setting or trusting that Boolean flag.
The result uses `bilibili_pc_ordinal_range_v1` and
`primary_sdk_ordinal_contract_and_quote_catalog_consistency`, matching the
current unchanged Range (`dd185e9b...`), Fetch (`ca01b376...`) and Quote
(`aa3fcb46...`) modules identified by the parent and documented in the focused
verification.

This supersedes the old conclusion that every batch must remain advisory or
that read-only quote observation still awaits authorization. Standard-currency
positive and explicit-zero ranges can now pass the implemented proof checks;
unsupported discounts, uncertain access and inconsistent evidence remain
advisory. The report still does not establish locked server IDs, atomic
membership at submission, actual debit, coupon/card consumption, ownership
delivery or executed `BuyEpisode` zero semantics. No wallet, image, account
mutation or purchase request was made in this latest observation.
