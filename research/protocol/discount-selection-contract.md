# Discount and Asset Selection Contract

Current status: 2026-09-13. Ordinary-currency batches with no selected extra
discount now use the [ordinal range contract](../../docs/ordinal-range-contract.md)
to construct and independently recompute an intended-range proof. The contract
is `bilibili_pc_ordinal_range_v1`, with provenance
`primary_sdk_ordinal_contract_and_quote_catalog_consistency`; a server-echoed
member list is not its prerequisite. Additional discount/card/credit selections
retain the advisory boundary documented here.

The [sanitized live construction result](ordinal-range-live-result.json)
records `submittable=true` for a 20-chapter positive offer and a 123-chapter
remaining offer, with server amounts, preserved range limits and confirmation
fingerprints. It records seven business requests, four quote responses, one
public asset request and zero blocked requests. Both constructions retain
`server_confirmed_ids=false` and `real_submit_executed=false`. Actual debit,
ownership delivery and additional-asset consumption have not been established.

The first-party extraction below was recorded on 2026-09-12. No SDK code,
quote/wallet/purchase function, test or account request was executed, and no
user session was read during that static review. Its mappings and source
locators remain unchanged evidence; the former implementation boundary is
marked as historical. This document supplements
[the batch quote contract](batch-quote-contract.md).

## Source identity and reproduction

The source is the
[official reader bundle](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/reader.1ffe7bbf9d.js).
Its existing remote original is
`/tmp/bilicomics-protocol-source-h7g249d3/reader.js`:
3,616,526 bytes, SHA-256
`3faf2f5de5c77884669dc749b0123343313c973d5eb2fc9edee1911cae191f1e`.

All numeric locators below are zero-based Python string indices in the existing
decoded copy, `/tmp/bili-m1-nc9Uf7/reader-strings-decoded.js`:
3,379,092 UTF-8 bytes, 3,364,216 Python string characters, SHA-256
`e4d850d436d5140d4fb9f35d35a4f0cf0e8e7ad0796099b25aaf39dd4aaab0ec`.
They are not byte offsets in the deployed bundle or UTF-16 offsets.
For example, the following is a file-reading operation, not SDK execution:

```python
from pathlib import Path
text = Path("/tmp/bili-m1-nc9Uf7/reader-strings-decoded.js").read_text()
print(text[2404090:2404950])
```

Decorators map wire names to model properties. Declared model types and
constructor defaults do not establish wire-field presence, eligibility, or
requiredness. Missing, explicit null, false, and actual numeric zero must remain
distinguishable in a production adapter.

## Request and response entry points

All five routes use the existing comic service POST wrapper:

| Method | Wire route/body | Response model or observed shape | Locator |
| --- | --- | --- | ---: |
| `getEpisodePurchaseInfo` | `GetEpisodeBuyInfo`, `{ep_id}` | `_0x3be4b2`, exported as `xx` | 2404090–2404518; export 3065090 |
| `getEpisodeDiscounts` | `GetEpisodeBuyInfo?getEpisodeDiscounts`, `{ep_id,buy_type,batch_limit,order}` | The same `xx` model | 2404518–2404950 |
| `getDiscountList` | `GetDiscountList`, `{comic_id,order,original_values}` | `vRSY.e3`: `discount_cards[]` | 2451465–2451900; 3220283–3220684 |
| `getFreeGoldCardList` | `GetComicFreeGoldCard`, `{comic_id,ep_id,chapter_id?,buy_type,batch_limit}` | `vRSY.ag`: aggregate scope/ban information | 2451894–2452480; 3220700–3221592 |
| `calDiscountPrice` | `CalDiscountPrice`, `{id,original_values}` | Raw `data` indexed by original amount; wrapper reconstructs an array | 2454190–2454850 |

The route prefix is `/twirp/comic.v1.Comic/`. Sharing `xx` does not prove that
the range response contains a full copy of the basic information. The observed
range consumer copies `data.discounts` and reads `data.remainCard`
(1360670–1362075); it does not replace the original `purchaseInfo.batchBuy`.
Keep the basic snapshot and its offer order separate from range-specific
discount observations.

Request enum values are `Single=1`, `Batch=2`, `Full=3`; discount sorting is
`Discount=1`, `Expire=2` (3260887–3261260). Chapter ordinal is not this
`order` field.

The free-gold-card request has a significant difference: the UI supplies
`batchLimit=discountState.amount` (1358460–1358780), not
`discountState.batch_limit`. The reachable batch-selection watcher obtains
that amount from the selected usable offer's `amount` (2167207). The call
supplies comic ID, episode ID, and buy type, but no chapter ID; undefined
`chapter_id` is consequently omitted by normal JSON serialization. Do not
invent a single/full amount or substitute the nominal batch limit when this
selection context is missing.

## Basic/range PurchaseInfo wire mapping

The common model is `_0x3be4b2`. A scope discriminator, selected asset, and
field-presence record must accompany any normalized view.

| Raw field | SDK property | Decorator locator |
| --- | --- | ---: |
| `comic_id` | `seasonId` | 3083860–3084090 |
| `optional_discount_list` | `discounts[]` | 3081670–3082040 |
| `batch_buy` | `batchBuy[]` | Element declaration 3081756–3081820; binding 3085795 |
| `prime_info` | `primeInfo` | 3082050–3082250 |
| `remain_coupon` | `remainCoupon` | 3082288 |
| `remain_gold` | `remainGold` | 3082469 |
| `remain_silver` | `remainSilver` | 3082644 |
| `ep_silver` | `epSilver` | 3082787 |
| `recommend_coupon_ids` | `recommendCouponIds[]` | 3082948 |
| `ep_pay_coupons` | `epPayCoupons` | 3083129 |
| `recommend_item_id` | `recommendLimitedFreeCouponId` | 3083310 |
| `remain_lock_ep_num` | `remainLockedEpisodeCount` | 3083486 |
| `auto_pay_gold_status` | `autoPayGoldStatus` | 3083660 |
| `auto_pay_coupons_status` | `autoPayCouponsStatus` | 3083817 |
| `is_locked` | `isLocked` | 3084175 |
| `allow_coupon` | `isAllowCoupons` | 3084338 |
| `discount_type` | `seasonDiscountType` | 3084440–3084610 |
| `discount` | `seasonDiscount` | 3084610–3084780 |
| `original_gold` | `seasonOriginalGold` | 3084835 |
| `remain_lock_ep_gold` | `seasonPayGold` | 3084999 |
| `ep_discount_type` | `episodeDiscountType` | 3085140–3085320 |
| `ep_discount` | `episodeDiscount` | 3085320–3085480 |
| `ep_original_gold` | `episodeOriginalGold` | 3085534 |
| `pay_gold` | `episodePayGold` | 3085691 |
| `allow_item` | `allowItem` | 3086044 |
| `remain_item` | `remainItem` | 3086213 |
| `total_discount_card` | `totalDiscountCard` | 3086693 |
| `total_free_gold` | `totalFreeGold` | 3086868 |
| `allow_wait_free` | `allowWaitFree` | 3087031 |
| `wait_free_at` | `_waitFreeAt` | 3087212 |
| `recommend_discount_id` | `recommendDiscountId` | 3087369 |
| `recommend_discount` | `recommendDiscount` | 3087531 |
| `remain_card` | `remainCard` | 3087683 |
| `discount_ep_gold` | `discountEpGold` | 3087858 |
| `discount_remain_gold` | `discountRemainGold` | 3088020 |

The model also maps `first_image_url` and `first_image_token` to private
preview properties (3086310–3086570). These are acquisition fields, not evidence
of scope or selected assets; the token does not belong in durable quote records.
Auto-payment, wait-free, item, and silver fields must not turn into automatic
asset use merely because they appear in the response model.

Top-level `original_gold` is a season amount, whereas
`ep_original_gold` is a single-episode amount. Neither is the
`batch_buy[].original_gold` of a selected offer.

### Batch offers

`batch_buy[]` uses `_0x43e04b`:

| Raw field | SDK property | Declared type | Locator |
| --- | --- | --- | ---: |
| `batch_limit` | `batchLimit` | Number | 3069520 |
| `amount` | `amount` | Number | 3069666 |
| `original_gold` | `originalGold` | Number | 3069844 |
| `pay_gold` | `payGold` | Number | 3070006 |
| `discount_type` | `discountType` | Number | 3070187 |
| `discount` | `discount` | Number | 3070332 |
| `discount_batch_gold` | `discountBatchGold` | Number | 3070516 |
| `usable` | `usable` | Boolean | 3070674 |

Numeric defaults are zero and `usable` defaults false. The display-only
`discountStr` formats `discount / 10`; that is not a payable-price formula.
The batch enum contains 20, 50, and `TheRestEpisodes=0`
(3066740–3066890). Zero denotes the website's remaining-offer intent, not a
proved server chapter set. The separate batch submit handler computes
`limit = batchLimit > amount ? 0 : batchLimit` and preserves the anchor
ordinal. The static extraction alone did not establish server-processed
membership. The current ordinal contract supplies a bounded intended-set
construction for positive and explicit remaining offers; actual membership
delivery and zero-limit transaction behavior remain untested.

## Discount union and nested assets

`optional_discount_list[]` uses `_0x106516`:

| Raw field | SDK property/type | Locator |
| --- | --- | ---: |
| `discount_type` | `discountType:Number` | 3076716 |
| `discount_info` | `discountInfo:_0x39a5c1` | 3076893 |
| `discount_act_info` | `discountActInfo:_0x24686a` | 3077077 |
| `free_gold_card` | `freeGoldCard:_0x1da2f3` | 3077261 |

The outer discriminator is `None=-1 / DiscountActivity=0 / DiscountCard=1 /
FreeGoldCard=2` (3076206–3076350). All three nested objects are created by
default, so object presence is not an eligibility or selection signal.

| Payload | Raw → SDK fields | Locators |
| --- | --- | --- |
| `discount_info` | `id→id`, `discount→discount`, `discount_limit→discountLimit`, `reason_desc→reasonDesc`, `expire_time→expireTime`, `type→type`, `amount→amount`, `is_usable→isUsable`, `reason→reason`, `discount_gold→discountGold` | 3071189–3072638 |
| `discount_act_info` | `id→id`, `discount→discount`, `expire_time→expireTime`, `is_usable→isUsable`, `reason→reason`, `type→type`, `saved_gold→savedGold` | 3073337–3074366 |
| `free_gold_card` | `card_id→id`, `total→total`, `is_expired_soon→isExpiredSoon`, `expired_total→expiredTotal`, `expire_time→expireTime`, `is_usable→isUsable`, `reason→reason`, `prime_gold_count→primeGoldCount` | 3074867–3075981 |

Discount-card IDs are declared Number; free-gold-card IDs are declared String.
Expiry/reason fields are String, usability and `is_expired_soon` are Boolean,
`discount_gold` is Object, and the remaining listed numeric amount/rate fields
are Number. Keep expiry text and response presence; this extraction does not
establish the server timezone for dates without an explicit offset.

Do not merge distinct enum domains:

- Activity's nested `type` is `None=0 / SeasonDiscount=1 / OtherDiscount=2`
  (3072780–3073000).
- Episode price `ep_discount_type` maps to `None=0 / Discount=1`
  (module `5PxE`, 937950–938140).
- Season price `discount_type` maps to `None=0`, `Discount=1`,
  `FreeForLimit=2`, `FreeForAppointChapters=3`, `UniversalCardLimitFree=4`,
  `UniversalCardEpisoLimitFree=5`, `VolumeLimitFree=6`,
  `UniversalCardVolumeLimitFree=7`, `PreleaseFree=8`
  (module `FGOM`, 1428810–1429620).
- The card's own `type` is not the outer asset discriminator. The
  `GetDiscountList` card constructor defaults it to `SitewideDiscountCoupon`;
  no new eligibility rule should be derived from that default.

`prime_info` has a further model hierarchy (3077410–3079430):
`batch.batch_buy[].free_gold_card_prime_gold` maps to
`primeInfo.batch.batchBuy[].freeGoldCardPrimeGold`, and
`whole.free_gold_card_prime_gold` maps to `primeInfo.whole.wholeGoldCount`.
These are separate from both a card's aggregate `total` and the selected
range card's `prime_gold_count`. Missing rows must not be reconstructed from
another amount with a similar name.

## Auxiliary eligibility and price responses

`GetDiscountList` returns `discount_cards[]`. Its element model
`EsA9.qx = _0x21812b` has the same named fields as `discount_info` above
(1396965–1398940). The reader sorts this list by `expireTime`
(1354440–1356150); range processing uses it to add unusable card information.
It does not substitute this inventory for the range-specific optional list.

`GetComicFreeGoldCard` returns the following aggregate object:

| Raw field | SDK property | Declared type | Locator |
| --- | --- | --- | ---: |
| `is_ban` | `isBan` | Boolean | 3220830–3220990 |
| `ban_reason` | `banReason` | String | 3220990–3221180 |
| `total` | `total` | Number | 3221180–3221360 |
| `expire_time` | `expireTime` | String | 3221360–3221592 |

This response has no selected card ID in the inspected model. When banned,
`processFreeGoldCardDiscount` creates/replaces an unusable placeholder with
`isUsable = !isBan`, ban reason, total, and expiry
(1369793–1371070). The actual selected card ID and `primeGoldCount` come from
the range list's `freeGoldCard`, not from this aggregate response.

The original amount vector is:

```text
[episodeOriginalGold, seasonOriginalGold, ...original batchBuy order's originalGold]
```

`CalDiscountPrice` sends that vector unchanged. The exact short wrapper
expression is `originalValues.map(value => raw.data[value] || 0)`
(2454190–2454850). This is an original-amount-keyed map, not an array indexed by
offer position. The parent then assigns entries 0/1/the remainder to
`discount.price.episode/season/batch` (2775440–2776030).
The plugin must reject missing mapping entries instead of copying the SDK's
zero fallback. Preserve original offer positions through usability filtering;
the filtered UI position is not automatically the original price-vector index.

## Selection and expenditure fields

`getEpisodeDiscounts` starts the two auxiliary eligibility reads, obtains the
range optional list, merges unusable-card information, and stores
`discountState.remain_card` (1360670–1362075). `resetDiscounts` starts from
the processed list's first entry or retains a previous matching selection;
when all entries are unusable it selects no discount
(1373580–1375720). The inspected `recommendDiscountId/recommendDiscount`
properties have no established live selection read.

`selectCard` emits the selected type and ID plus branch-specific fields:
card `rate/limit`, activity `rate/savedGold`, or free-gold-card
`freeGold=total/primeGoldCount` (1376400–1379560). Its optional third argument is
rejected only when `isUsable === false`; internal reset calls can omit that
argument. This permissiveness is not evidence that an absent eligibility field
means usable. These client choices are not authority to auto-consume a user's
assets in the plugin.

The reachable coin submission handlers preserve different amount formulas:

| Scope | Source-selected `payGoldAmount` | Locator |
| --- | --- | ---: |
| Single episode | ID zero or FreeGoldCard: `episodeOriginalGold`; activity: that original minus `savedGold`; otherwise `discount.price.episode` | `doPurchaseEpisodeGold`, 2797350–2798200 |
| Batch | ID zero or FreeGoldCard: selected offer `originalGold`; activity: that original minus `savedGold`; otherwise `discount.price.batch[originalOfferIndex]` | `doPurchaseBatch`, 2808540–2810080 |
| Separate whole-comic form | FreeGoldCard: `seasonOriginalGold`; activity: that original minus `savedGold`; DiscountCard: `discount.fullBuyGold`; otherwise `seasonPayGold` | `doPurchaseSeason`, 2803200–2804700; event binding 903387 |

The full form's `fullBuyGold` is set through
`discountInfo.discountGold[this.discount.primeGoldCount.toString()]` in
`selectCard`. Do not replace it with `discount.price.season` or equate this
form with batch `limit=0`; the combination still needs live contract evidence.

For the coin handlers, the selected additional assets map as follows:

| Selected branch | Wire fields |
| --- | --- |
| DiscountCard (`type=1`) with a Number ID | `coupon_id` |
| FreeGoldCard (`type=2`) with a String ID | `free_gold_card_id` and `free_gold_amount=primeGoldCount` |
| Activity or no extra discount | No card ID added by these branches |

The body wrapper sends `pay_amount` and the additional asset fields only when
their source values are truthy (2406470–2407620). Zero omission is observed
serialization behavior; absent data is not a verified zero-price purchase.
Reading coupons are a separate `buy_method=2`/`coupon_ids` path; the
`coupon_id` discount card above remains an extra asset on `buy_method=3`.
Auto-payment settings present in the website objects are outside the local
selection contract and must not be copied incidentally.

## Historical candidate boundary and current unresolved evidence

At the static-extraction stage, the following were candidates for
non-submittable construction:
explicit raw-name mappings with presence/type checks; separately retained basic
and range observations; original offer/price-vector association; typed selected
asset identity; scoped auxiliary request arguments; and a display of known
eligibility plus unknown fields. Each selection change must refresh its matching
scope/asset observations rather than reuse another selection's amounts.

The implemented ordinal contract now permits supported ordinary-currency batch
quotes when the complete catalog, selected offer, basic/scoped amounts and
aggregate relationships agree. It preserves raw top-level `discount_type`,
`discount`, `ep_discount_type`, `ep_discount`, `discount_ep_gold` and
`discount_remain_gold` in the semantic basis. Missing fields remain missing;
present fields must be finite numbers and agree between basic/scoped reads.
Their values do not authorize another price formula or extra asset use.
An unsupported selection or failed consistency check remains advisory.

Beyond the observed ordinary-currency samples, remaining questions include
per-route field availability, server expiry/timezone semantics, additional-asset
eligibility and the relationship between displayed `pay_gold`, source-selected
`pay_amount` and final debit. No server atomic range version or actual
positive/zero transaction delivery has been established. Constructor defaults,
inventory entries and recommendations do not resolve those limits. The static
extraction alone is not a submitted transaction or a server-confirmed member
list; the current proof separately checks the complete quote/catalog evidence.
Amounts remain in source units, without invented rounding, multiplication or
cross-asset conversion.
