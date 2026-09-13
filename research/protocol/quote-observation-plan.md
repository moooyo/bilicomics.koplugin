# Bounded Quote Observation Plan

Original status: proposed and not yet authorized or executed. The request
budget below preserves that initial preparation record for one account, one
comic and one anchor; it is not a purchasing acceptance test.

Status as of 2026-09-13: the user permits all operations except actual
purchasing. Authenticated quote observations, a separately guarded wallet read
and isolated synthetic checks have executed; see the
[non-purchase integration report](../../docs/nonpurchase-integration-report.md).
Standard coin/no-extra-discount positive and remaining ranges now have a
production [ordinal-range contract](../../docs/ordinal-range-contract.md) and
[real production construction from authenticated read data](ordinal-range-live-result.json).
This derives an intended chapter set, with `server_confirmed_ids=false`;
extra discounts remain advisory. Real `BuyEpisode` HTTP calls and actual
purchases remain zero. Actual charging and physical Scribe acceptance remain
unverified. These later observations do not widen the original observer's
request budget or turn its historical scope flags into server guarantees.

The existing [batch](batch-quote-contract.md) and
[discount-selection](discount-selection-contract.md) contracts supply the
first-party evidence: reader SDK methods `getEpisodePurchaseInfo` and
`getEpisodeDiscounts`, decoded offsets 2404090–2404950; PurchaseInfo fields
3081670–3088020; batch fields 3069520–3070674; discount union 3076716–3077261.

## Historical budget of the initial observation

Let `M=https://manga.bilibili.com/twirp/` and
`Q=device=pc&platform=web&nov=27&a=810`. `C` and `E` are the same privately
selected comic and anchor IDs throughout, encoded as the positive JSON numbers
accepted by `Client`. Do not put the signing input `eot=812` into the wire query.
Use current production authentication and signing without publishing their
values. Stop on failed login, identity mismatch, malformed response or an
unsuccessful response; do not retry or discover additional comics automatically.

| Step | Method and exact URL expression | JSON body |
| --- | --- | --- |
| 1 | `GET https://api.bilibili.com/x/web-interface/nav` | No body or query. Require `isLogin=true` for the account represented by the user-supplied session file; production identity validation must pass. |
| 2 | `POST M+bookshelf.v1.Bookshelf/ListFavorite?Q` | `{"page_num":1,"page_size":20,"order":1,"wait_free":0,"time_limit_free":0,"type":0,"from":"web","source":"web"}` |
| 3 | `POST M+comic.v1.Comic/ComicDetail?Q&ultra_sign=S` | `{"comic_id":C,"m2":P}` |
| 4 | `POST M+comic.v1.Comic/GetEpisodeBuyInfo?Q` | `{"ep_id":E}` |
| 5 | `POST M+comic.v1.Comic/GetEpisodeBuyInfo?Q&getEpisodeDiscounts` | `{"ep_id":E,"buy_type":1,"order":1}`; omit `batch_limit`. |
| 6, optional | Same scoped URL as step 5 | `{"ep_id":E,"buy_type":2,"batch_limit":N,"order":1}` |
| 7, optional | Same scoped URL as step 5 | Either `{"ep_id":E,"buy_type":2,"batch_limit":0,"order":1}` or `{"ep_id":E,"buy_type":2,"batch_limit":N,"order":2}`, as bounded below. |

The prepared observer uses the first comic returned by step 2 and its first
locked chapter. It stops if either is absent, without trying another comic.
Authorization refers to the account represented by the user's existing
`D:\Code\test\bilibili.txt`; no additional expected account ID is assumed.
Production session validation still rejects a conflicting `DedeUserID` when
that cookie is present. Preserve the original `ComicDetail.ep_list` and
require exactly one matching `E`, including its original ordinal. `P` is the
unchanged production `prepareCatalog` result; `S` and `x-bili-data-sn` are
computed over the exact encoded body by the production signer. Do not invent
or replace these values. Quote requests do not add a signature query field.

For step 6, choose the first explicitly usable positive integer `batch_limit=N`
in the basic response's original offer order, with valid positive `amount`.
Retain its original array position and report duplicate limits; do not filter
or reorder the base array. Step 7 queries zero only if the same basic response
supplies an explicitly usable zero-limit offer with positive `amount`;
otherwise it repeats `N` with expiry sort `order=2`. If there is no positive
offer, query an explicitly usable zero offer once in step 6, if present, and
omit step 7. If neither exists, omit both. Zero is remaining-offer UI intent only.
Neither `start_ord`, `offer_index`, `amount`, prices nor asset IDs belong in
these request bodies. The budget is seven business requests maximum, four of
them quote reads. There is no pagination, retry or auxiliary business request.
If absent locally, the only additional requests are one anonymous GET each to
the production-pinned [signing WASM](https://s1.hdslb.com/bfs/manga-static/manga-pc/efae82c96a7eef44bee5.wasm)
and [response WASM](https://s1.hdslb.com/bfs/manga-static/manga-pc/e461bfa6b471a22c06fc.wasm),
with no body/query/authentication or redirect, checked against
[`assets.lua`](../../bilicomics/protocol/assets.lua) hashes. Total network
budget: nine requests maximum.

## Observation record and disclosure

Record raw wire-field presence **before** defaults, normalization or
`Client.purchaseInfo`'s fallback `ep_id`. Distinguish absent, null, false, zero,
numeric string and JSON number. Public output may contain route/step, HTTP and
business status, field names/types, bounded array counts, boolean validity and
equality results, and run-local labels in place of identities. Retain:

- **Identity/catalog:** server-supplied `ep_id`/`comic_id` presence and match;
  anchor uniqueness and ordinal type/fractionality; raw `is_locked`,
  `is_in_free`, `pay_mode`, `unlock_type`, `unlock_expire_at` types;
  basic/scoped `is_locked` presence and equality. A client-injected ID is not a
  server echo.
- **Base offers/prices:** original `batch_buy` order/count; for every row,
  `batch_limit`, `amount`, `usable`, `original_gold`, `pay_gold`,
  `discount_type`, `discount`, `discount_batch_gold` presence/types. Report
  positive/zero limit class, `limit < / = / > amount`, and original/display
  equality. Also retain `ep_original_gold`, `pay_gold`, `original_gold`,
  `remain_lock_ep_gold`, `discount_ep_gold`, `discount_remain_gold` presence,
  numeric validity and basic/scoped equality where both exist. Preserve the
  complete original-price vector and its `offer_index + 2` association
  privately; publicly report completeness, length and equality only.
- **Scoped assets:** `optional_discount_list` presence/count and discriminator
  counts (`-1/0/1/2/unknown`); corresponding nested object presence;
  `id`/`card_id` types, uniqueness and equality across scopes. Observe
  `is_usable`, `expire_time`, `discount`, `discount_limit`, `amount`,
  `saved_gold`, `prime_gold_count`, `total`, `expired_total`,
  `is_expired_soon`, nested `type` and `discount_gold` shape. Observe
  `recommend_discount_id`/`recommend_discount` presence and whether their
  identity resolves uniquely, without selecting an asset. Retain
  `prime_info.batch.batch_buy[].free_gold_card_prime_gold` and
  `prime_info.whole.free_gold_card_prime_gold` presence/count/type separately.
- **Other eligibility:** types/presence of `allow_coupon`, `ep_pay_coupons`,
  `recommend_coupon_ids` (count/uniqueness), `remain_coupon`, `remain_gold`,
  `remain_card`, `total_discount_card`, `total_free_gold`, `allow_wait_free`,
  `wait_free_at`, and auto-payment flags. Recommendations and returned settings
  authorize no consumption or setting change.

If explicit scope/episode-list or final-amount fields appear, record their
names, presence/types and list counts/duplicates/anchor inclusion without
assuming they are authoritative or promoting them into candidate proof.

Raw responses, account/comic/episode/asset IDs, titles, catalog order/ordinals,
amounts/balances, recommendation values, expiry/reason text, cookies, headers,
signing material, image URLs/tokens and any opaque identifiers remain private.
Do not publish hashes of low-entropy private values as substitutes. Record
unexpected fields by name/type only; do not automatically fetch their URLs.

The prepared observer automatically emits a compact subset of this list:
decoded field types, original offer positions/counts, display/original and
limit/count comparisons, server identity matches, and nested discount field
types. It also retains complete wire, decoded and normalized responses in the
private output directory. The remaining comparisons above, including complete
price-vector associations, cross-scope equality and asset-ID uniqueness, are
subsequent static analysis of those private captures. The compact report alone
must not be claimed to establish every listed contract. Field types are sampled
before `Client` injects a fallback episode ID; unexpected field names and opaque
values are not automatically published.

## Original observer execution boundary

[`quote-readonly.lua`](quote-readonly.lua) calls only the listed Client methods.
Each business request consumes one exact operation ticket. The guard matches
the URL, default query values, optional bare quote flag, method, approved body
values and catalog signing fields before dispatch. It permits only the two
digest-pinned anonymous WASM downloads as additional resources. No global CDN
allowance, auxiliary quote collector, wallet call or purchase service is used
by this observer. The later wallet read used its own exact one-request guard.

[`run_quote_observation.py`](run_quote_observation.py) requires SSH on Linux,
the recorded KOReader version, an explicit execution flag and a new private
output directory. Its input source is bound to the reviewed 95-file preview
archive, SHA-256 `38a01da12c74271a631af57e9ac45c9e90b48472e390bd4aae5ded42e37f8383`.
It verifies source members before copying the private session input, uses an
isolated data directory and minimal process environment, captures subprocess
logs privately, and removes its credential copy after completion or handled
cancellation. The originally supplied input is not modified. Private response
captures must be removed after the authorized analysis is finished. Neither
the flag nor this document supplies user authorization; execution subsequently
used the user's 2026-09-13 authorization. The completed cleanup is recorded in
the non-purchase integration report.

## Original comparison scope and current limits

Compare the observations statically with `Client.purchaseInfo`,
`Selection.requestScope`, the `rawOffer`/`originalValues` helpers in
[`quote_fetch.lua`](../../bilicomics/purchase/quote_fetch.lua), and
`describeOffers`/`describeDiscounts`/`vectorMatches` in
[`candidate.lua`](../../bilicomics/purchase/candidate.lua). Basic offers
remain the base snapshot; scoped data supplies matching discount observations.
Missing amounts never become zero, and card totals are not scoped credits.
The original observer did not invoke the general `Fetch.run`, which repeats
basic/detail reads and may call auxiliary asset APIs. The preparation stage
ran no candidate, quote, wallet or SDK function. Later captured-data replay,
synthetic isolation checks and guarded production quote construction are
separate results, linked above.

Only the routes above belonged to the initial observer. Its budget excluded
wallet, calculated-price, card-inventory, free-gold-card, image, purchase,
rental, history-write and settings requests. Its observations establish sampled
response shapes and field associations, not actual debit, asset consumption,
submission-time freshness or server-confirmed exact batch membership. They do
not verify calculated discounts or auxiliary eligibility, and did not by
themselves set `exact_scope_verified` or remove a submission gate.

The later ordinal contract supports production construction for standard coin
with `discount.kind="none"`, including positive and remaining ranges, through
independent reconstruction and fresh quote/catalog consistency. That result
does not retroactively change the original observer's scope flags or prove
atomic server selection. Extra discounts/assets remain advisory, and actual
purchase execution remains outside the user's authorization.
