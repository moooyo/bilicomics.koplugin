# Batch Purchase Quote Contract

Current status: 2026-09-13. The
[ordinal range contract](../../docs/ordinal-range-contract.md) now supports
recomputable intended chapter sets for strictly checked ordinary-currency
batch offers. It replaces the earlier requirement for server-echoed chapter
IDs with the official SDK range contract plus quote/catalog consistency.
The contract is `bilibili_pc_ordinal_range_v1`, with provenance
`primary_sdk_ordinal_contract_and_quote_catalog_consistency`.

The [sanitized live construction result](ordinal-range-live-result.json)
records `submittable=true` quotes for a 20-chapter positive offer and a
123-chapter remaining offer. Both preserve the server amount and original
range limit and have a confirmation fingerprint. The acquisition recorded
seven business requests, four quote responses, one public asset request and
zero blocked requests. `server_confirmed_ids=false` and
`real_submit_executed=false`: quote construction does not establish actual
debit, delivered ownership or atomic server membership. Extra-asset selections
and evidence that fails the current contract retain the advisory path.

The source extraction below was recorded on 2026-09-12. Its request formulas,
field mappings and decoded-source locators remain primary-source evidence.
The decision, implementation gaps and preview sections are historical records;
their former submission restrictions are not the current range contract.

## Historical decision before the ordinal range contract

The static review established the official client's range request, price
selection and predicted chapter list, but no server-confirmed `episode_ids`
list. At that stage the adapter required `exact_scope_verified=true` with an
explicit member list, so batch submission remained gated. The current
ordinal range contract supersedes that implementation requirement; it retains
the distinction between intended IDs and server-confirmed membership.

## Source and reproducible locators

Primary source:

- [Official PC reader SDK](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/reader.1ffe7bbf9d.js)
- Downloaded original SHA-256:
  `3faf2f5de5c77884669dc749b0123343313c973d5eb2fc9edee1911cae191f1e`
- Existing original copy on `test-env`:
  `/tmp/bilicomics-protocol-source-h7g249d3/reader.js`
- Existing string-decoded inspection copy on `test-env`:
  `/tmp/bili-m1-nc9Uf7/reader-strings-decoded.js`

The offsets below are zero-based character offsets in the **decoded inspection
copy**, not line numbers or offsets in the original deployment asset. Prefer
the method/property markers when reproducing the inspection. String decoding
does not establish reachability by itself; the price conclusions below follow
the component event, parent handler, and request wrapper together.

| Area | Locator | Decoded offset |
| --- | --- | ---: |
| Basic purchase information | `class _0x107fba`, `getEpisodePurchaseInfo` | 2404030 approximately |
| Range-dependent information | `getEpisodeDiscounts` | 2404518–2405000 |
| Purchase-method/body wrapper | `purchaseEpisode`, `payGoldAmount`, `withOrdScope` | 2406470–2407500 |
| Batch selection state | `onWatchSelectedIndex`, `selectedBatchIndex`, `batch_limit` | 2167030 |
| Displayed batch price | `selectedPayGold`, `selectedDiscountedGold` | 2170260–2175350 |
| Child purchase event | `do-purchase-batch(selectedIndex)` | 2187988 |
| Parent event binding | `do-purchase-batch` to `doPurchaseBatch` | 903411–903539 |
| Actual batch submission | `doPurchaseBatch`, `batchLimit`, `payGoldAmount` | 2806288–2810940 |
| Catalog order used by the panel | `reverseEpisodeListData` | 2771640–2772300 |
| Predicted purchased IDs | `onPurchaseSuccess` | 2811880–2812540 |
| Original price vector | `prices`, `setDiscountPrice` | 2775440–2776030 |
| Discount price request/result handling | `originalValues`, `CalDiscountPrice`, `setDiscountPrice` | 1382300, 2454293 |
| Discount response consumption | `discounts`, `remainCard` | 1360670 |
| Discount sort changes | `onWatchOrder`, `getEpisodeDiscounts` | 1371554 |
| Purchase/sort enums | `Single`, `Batch`, `Full`, `Discount`, `Expire` | 3260887–3261260 |

The earlier product research provides the endpoint inventory and explicitly
separates source observations from live-account validation:
[product and protocol research](../../docs/product-and-protocol-research.md).

## Verified request mapping

The official client obtains basic information with:

```text
POST /twirp/comic.v1.Comic/GetEpisodeBuyInfo
body: { ep_id }
```

For the selected purchase range and discount ordering, it uses:

```text
POST /twirp/comic.v1.Comic/GetEpisodeBuyInfo?getEpisodeDiscounts
body: { ep_id, buy_type, batch_limit, order }
```

The established meanings are:

| Field | Source-supported mapping |
| --- | --- |
| `ep_id` | The current anchor episode from `discountState.ep_id` |
| `buy_type` | `Single=1`, `Batch=2`, `Full=3` |
| `batch_limit` | The selected usable offer's `batchLimit` |
| `order` | Discount ordering: `Discount=1`, `Expire=2` |
| `amount` | Retained by the UI, but not sent in this range-information request |

`order` is **not** `episodeOrd` or `start_ord`. A plugin mapping from its own
`scope` object must not put the chapter ordinal in that field.

The actual currency purchase constructs:

```javascript
const limit = offer.batchLimit > offer.amount ? 0 : offer.batchLimit;

const payload = {
    buy_method: 3,
    comic_id: purchaseInfo.seasonId,
    with_ord_scope: true,
    start_ord: episodeOrd,
    limit,
};
```

The comparison is strictly `>`. `start_ord` is the current episode ordinal,
without incrementing, decrementing, or rounding it. The range request does not
send `amount` or an explicit `episode_ids` array. A batch with a zero `limit`
must not be silently equated with the separate full-comic purchase form.

The official UI also carries auto-payment preferences in its purchase object.
Those fields are outside this plugin's authorized ordinary purchase behavior
and must not be copied into its payload merely to reproduce the website object.

## Price selection and the unresolved display/submission difference

The displayed no-extra-discount value reads `offer.payGold`. However, the
connected parent submission handler selects `payGoldAmount` as follows:

```javascript
const payGoldAmount =
    discount.id === 0 || discount.type === FreeGoldCard
        ? offer.originalGold
        : discount.type === DiscountActivity
            ? offer.originalGold - discount.savedGold
            : discount.price.batch[index];
```

The wrapper maps this value to `pay_amount` only when it is truthy. Thus a zero
value is omitted by that wrapper; missing data must not be converted into a
zero-price quote by the plugin.

For a free-gold card, the original amount remains in this calculation and the
request separately carries `free_gold_card_id` and
`free_gold_amount=primeGoldCount`. The amount displayed after the card deduction
cannot simply replace the amount sent alongside those additional asset fields.

These observations come from the same reachable child-event-to-parent-submit
chain. They cannot be dismissed as two proven mutually exclusive generations
of the payment UI. At the static-review stage, the live relationship between
`original_gold` and `pay_gold` still required authenticated responses. The
current ordinary-currency samples show equality, and the ordinal resolver
requires it for the selected offer; this does not establish a general rule
for other prices or additional assets.

For calculated card discounts:

```text
CalDiscountPrice request: { id, original_values }
original_values:
  [episodeOriginalGold, seasonOriginalGold, ...batchBuy.map(originalGold)]
```

The returned amounts are associated with that input vector. The UI maps the
first two entries to episode/season amounts and the remaining entries to
`discount.price.batch`. Offer filtering or reordering must preserve this
association; a new array index is not automatically the original quote index.

The inspected `getEpisodeDiscounts` UI path mainly consumes `discounts` and
`remainCard`; it does not replace the complete `purchaseInfo.batchBuy` array with
a newly verified payable batch model. `GetDiscountList` and `CalDiscountPrice`
wrappers existing in the plugin therefore do not establish that the complete
range/asset quotation workflow has been integrated.

`discount_batch_gold` was found in model declaration/construction, but no actual
submission price read was established. It must not be selected as
`final_pay_amount` based on its name. Multiplying a single-chapter price by a
batch count is likewise unsupported.

## Predicted chapter scope is not server-confirmed scope

The panel defines its working chapter order as:

```javascript
const reversed = mangaSeason.episodeList.slice().reverse();
```

After a successful nonzero-limit batch response, `onPurchaseSuccess` starts at
the current episode's position and accumulates the first `limit` chapters whose
`isLocked` flag is truthy. It emits these IDs for local updates; the reader then
refreshes comic data.

This is evidence of the client's intended/predicted scope. It is not evidence
that the service returned or confirmed those exact IDs in a pre-purchase quote.
The same helper collects no IDs when `limit=0`, so it cannot establish the
server's zero-limit semantics.

The plugin's `comicDetail().episodes` is numerically sorted. It must not be used
as though it were the unmodified SDK order. Any future comparison with the
website's prediction must retain the original catalog order, available in the
raw detail snapshot, and preserve IDs and fractional ordinals. The prediction
alone must not be relabeled `exact_scope_verified`.

The current ordinal resolver combines the official intended-range contract
with explicit catalog, offer and aggregate checks. Its proof remains distinct
from server-confirmed IDs and does not claim that the service atomically fixes
the member set at quote time.

## Historical production gaps before selection integration

These describe the earlier implementation, not the current resolver:

1. [`Quote.batchScope`](../../bilicomics/purchase/quote.lua) required a usable
   offer with `exact_scope_verified=true`, explicit `episode_ids`, `start_ord`,
   and `final_pay_amount`. No production adapter then derived these fields
   from a demonstrated server contract. Synthetic fixtures carrying them are
   tests of the purchase state machine, not evidence of production batch support.
2. [`Worker` quote handling](../../bilicomics/jobs/worker.lua) then retrieved
   `purchaseInfo` and `comicDetail`. The request-only translation in
   [`Client.purchaseInfo`](../../bilicomics/protocol/client.lua) recognized
   `{kind="batch", batch_limit, start_ord}` as described below. Discount
   selection, price-vector association, final asset amounts, and authoritative
   scope confirmation were not yet integrated.

These gaps did not remove the batch feature from the agreed first-release
scope. The current ordinal contract documents the implemented replacement
for the earlier member-list gate and the remaining transaction limits.

## Historical evidence plan and remaining transaction coverage

The following read plan preceded the live observations and ordinal resolver.
The latest linked result covers bounded ordinary-currency quote construction;
additional asset behavior and actual transaction delivery remain separate work.

Use an explicitly authorized session for read-only responses first. Do not issue
`BuyEpisode`, consume coupons/cards, or change auto-payment settings during this
step. Retain private raw captures outside ordinary research artifacts; publish
only sanitized contract observations.

The minimum useful response set is:

- Basic `GetEpisodeBuyInfo` and the full, original-order `ComicDetail` catalog
  for the same anchor episode.
- Batch range-information responses with `buy_type=2`, the exact selected
  `batch_limit`, and the documented discount sort values. Establish the actual
  `batch_buy`, `amount`, eligibility, and discount response shapes.
- Matching `GetDiscountList`/`CalDiscountPrice` responses when an eligible
  discount is involved. Confirm price-vector association and distinguish the
  displayed amount, the submitted amount, and separately consumed assets.
- Cases with `batch_limit <= amount` and `batch_limit > amount`, plus catalogs
  containing already-owned/free chapters, temporary access, unavailable content,
  and special/fractional chapter ordering where those cases are available.

The original open questions were:

1. Whether the quote exposes an authoritative exact chapter set or another
   verifiable scope representation.
2. How positive `limit` counts eligible chapters and what `limit=0` means.
3. Which final amount and additional asset fields apply when `original_gold`
   and `pay_gold` differ.
4. How scope, eligibility, and price changes between quote and submit are
   detected and require renewed confirmation.

An explicit server member list is no longer a prerequisite for the current
intended-range proof. Actual range-transaction acceptance still requires a
separately authorized concrete transaction and before/after entitlement
comparison for the proposed chapter set. That later check must not be inferred
from a wallet change alone or from a successful quote construction, and it
cannot be performed under this read-only review's authorization.

No production file was changed and no authenticated or charging request was
executed during the review recorded here.

## Historical additional static audit

The following findings use the same first-party reader bundle and decoded
character-offset convention above. No requests, tests, or production changes
were performed during this follow-up.

- **Zero is also an explicit offer type.** The enum contains
  `Episode20=20`, `Episode50=50`, and `TheRestEpisodes=0`
  (3066740–3066890); the zero branch displays the remaining `amount`
  (2183939). Thus zero can originate directly from an offer, as well as from
  `batchLimit > amount`. This establishes UI intent only. The positive-limit
  success loop (2811878) assumes a present anchor and enough subsequent locked
  chapters; it is not a complete server-scope algorithm. Neither branch proves
  an authoritative exact set or justifies enabling `exact_scope_verified`.
- **Calculated prices are keyed by original amount.** `CalDiscountPrice`
  returns a map; the SDK constructs
  `originalValues.map(value => raw.data[value] || 0)`
  (2454190–2454850), then assigns episode, season, and batch entries
  (2775440–2776030). Preserve the original offer positions and input-price
  association. A missing key must remain an invalid/incomplete quote in this
  plugin, never become zero. At this audit stage, `Client.discountPrice`
  returned the raw map without performing that association.
- **Free-gold-card eligibility has another scoped request.** The SDK calls
  `GetComicFreeGoldCard` (2446581, 2451894–2452480); its UI call passes
  `discountState.amount` as `batch_limit` (1358460–1358780), unlike the
  ordinary range-information request's selected `batchLimit`. This wrapper
  and selection workflow are absent. The reachable submission branches use
  numeric `coupon_id` for DiscountCard (`type=1`), and string
  `free_gold_card_id` plus `free_gold_amount=primeGoldCount` for FreeGoldCard
  (`type=2`), subject to the wrapper's truthy checks
  (2809500–2810080, 2406870–2407620). These are additional assets on
  `buy_method=3`, not interchangeable with reading-coupon `coupon_ids`.

Historical integration locators before selection integration:

| Location | Remaining mapping gap |
| --- | --- |
| `Controller:_fetchQuote`, `controller.lua:895–904`; Worker quote branch, `jobs/worker.lua:78–85` | The worker receives scope but no payment/discount selection, and fetches only purchase information plus detail. |
| `Client.purchaseInfo`, `protocol/client.lua:327`; `Quote.batchScope`, `purchase/quote.lua:27–35` | The request-only internal-scope translation is now implemented. It does not derive exact chapter sets or final prices. Positive and zero submission gates remain unchanged. |
| `Quote.build`, `purchase/quote.lua:122–138`; refresh paths at `controller.lua:931` and `purchase/service.lua:304` | The saved payment retains only method/coupon IDs. Selected discount/card identity, eligibility, and separate asset amounts are absent from the refreshed selection. The fingerprint includes payment/payload/offer containers, but those missing values cannot participate in comparison. |
| `Service.buildQuote`, `purchase/service.lua:65–79` | Only normalized, sorted episodes reach Quote. The original catalog remains available in `Client.comicDetail().extra.ep_list`; sorted episodes must not stand in for the SDK's original order. |

At that stage, the **range-request translator** portion of the bounded
implementation candidate was implemented. Preserving the selected original
offer index and distinct amount fields in a non-submittable candidate model
was follow-up work. The later selection adapter and current ordinal contract
address those implementation layers. Actual delivered membership, additional
asset eligibility and consumption still require their own evidence.

## Historical request-only adapter implementation

At this implementation stage, `Client.purchaseInfo` mapped an internal
`{kind="batch", batch_limit=N, start_ord=ordinal, order=sort}` to the existing
range-information endpoint with `{ep_id, buy_type=2, batch_limit=N, order=sort}`.
`order` accepts only Discount=1 or Expire=2 and defaults to 1. Optional
`start_ord` must be finite and is never sent or substituted for discount order.
The quote limit is a nonnegative integer bounded to 2147483647 by the client;
zero is allowed for the read-only remaining-offer query and is not a submission
permission.

The basic single-information path remains `{ep_id}` for no scope, an empty
scope, or `kind="single"` without explicit range fields. The existing explicit
`buy_type` path supports Single=1, Batch=2, and Full=3 with the same discount
sort validation. Batch requires a limit; explicit Single/Full requests retain
an optional, validated limit. Unknown fields/kinds/enums, conflicting internal
kind and explicit type, invalid limits/ordinals, and unscoped range fields are
rejected locally before request dispatch.

This change does not set `exact_scope_verified`, derive episode IDs, calculate
prices, preserve additional payment selections, or change `BuyEpisode` or
`Quote.batchScope`. Verification for this change is limited to a remote
LuaJIT bytecode-compilation syntax check. No quote function, account request,
wallet operation, or purchase behavior test was executed; runtime behavior and
server acceptance of the adapter remain unverified.

## Historical selection-adapter implementation preview

This preview added a copied `Selection` model, a shared worker/service
read collector, a presence-aware `Candidate` model, and paginated native
selection UI. It carries the original offer index, discount sort, fractional
anchor order and explicit discount/card identity through refreshed quotation.
Only supported range fields reach `GetEpisodeBuyInfo`; selection cannot supply
prices, additional asset amounts, predicted IDs or proof flags.

The collector keeps basic `batch_buy` and its full price vector separate from
scoped `optional_discount_list`. Selected-card price calculation preserves the
original-amount key; selected batch free-gold eligibility uses offer `amount`.
It does not guess missing single/full free-card count semantics or treat global
inventory as scoped eligibility. [The companion field extraction](discount-selection-contract.md)
records the source support for these mappings and the distinct single/batch/full
amount formulas.

The quote retains separate original/display/submission-reference/credit fields
and selected-asset snapshots. Controller uses its saved confirmed snapshot,
then compares fresh canonical scope/payment/amount/asset terms. Ambiguous
single currency amounts, extra discount assets and unproved batch membership
produce `submittable=false` advisory objects without a payload, exact episode
set or confirmation fingerprint. The UI provides no purchase button for them.

At that preview stage, the production collector did not derive
`exact_scope_verified`. Submittable batch construction required explicit
matching context proof in addition to the former verified-offer contract;
omitting context could not bypass that gate. The current ordinal resolver and
independent quote reconstruction replace that requirement for supported
ordinary-currency ranges. Neither stage establishes actual purchase delivery
or verified additional asset consumption.

During that preview check, eleven changed Lua files passed remote `luajit -b`
compilation without being executed as modules. No quote, wallet, purchase or
payment-UI test was performed in that check.
The separate preview archive and exact source evidence are documented in
[quote selection implementation](../../docs/quote-selection-implementation.md).
