# Purchase completion audit

Original audit date: 2026-09-12. Status update: 2026-09-13. The original scope
was the purchase portions of implementation-plan sections 2, 3.4, 8, 10, and
11 against the then-current quote-preview source tree. The original matrix is
preserved below; it is not a current release acceptance result.

No production file was changed. No test, Lua module, SDK, API, wallet, quote,
purchase operation, session, or WSL environment was executed or accessed for
this audit. Existing source and research documents were read. Historical test
records and syntax-only evidence are not treated as current purchasing
acceptance. At that original audit date, the user's restriction also excluded
synthetic purchase scenarios. That restriction is historical: as of 2026-09-13,
the user permits all operations except actual purchasing.

The matrix below is the pre-correction audit snapshot. The identified coupon-ID
display omission was subsequently implemented in the separate preview; see
[the display update](entitlement-display-update.md). That payment display
initially had static/syntax evidence only. The statements that quote/wallet and
synthetic behavior were untested describe that earlier snapshot, not the
subsequent results summarized next.

## Current status as of 2026-09-13

- Authenticated quote observations and a separately guarded wallet read have
  executed. Their sampled fields and comparisons, and the earlier captured-data
  replay, are recorded in the [non-purchase integration report](nonpurchase-integration-report.md).
- Isolated synthetic checks have executed: [quote selection](../spec/purchase/quote-selection-verification.md)
  passed 23 groups/259 assertions, [native quote UI](../spec/ui/quote-selection.md)
  passed 141 assertions per size, and the [ordinal resolver](ordinal-range-contract.md)
  passed 15 groups/240 assertions. The [ordinal transaction regression](../spec/purchase/ordinal-transaction-verification.md)
  separately covers synthetic state, serialization and SQLite restart behavior.
  Its fake transport calls are not real `BuyEpisode` requests.
- Standard `coin` with `discount.kind="none"` now has a production ordinal-range
  resolver, independent collector/quote reconstruction and a supported intended
  chapter set. Fresh authenticated read data also produced real production
  construction of both positive and remaining-range quotes in the
  [live construction record](../research/protocol/ordinal-range-live-result.json).
  The earlier all-batches-advisory limitation is superseded for this branch.
- The [ordinal-range contract](ordinal-range-contract.md) explicitly retains
  `server_confirmed_ids=false`: the intended set is derived from the primary SDK
  contract and fresh quote/catalog consistency, not a server-returned member
  list or atomic server guarantee. Extra discounts/assets remain advisory.
- Real `BuyEpisode` HTTP calls and actual purchases remain **zero**. Actual
  charging, asset consumption, delivered ownership and payment recovery are
  unverified. Physical Scribe acceptance also remains unperformed. The broader
  non-purchase authorization and synthetic results do not close those gates.

## Classification used by the original audit

- **Code present; unverified:** a concrete production path exists, but current
  evidence does not prove its live behavior or complete acceptance scenarios.
- **Implementation plus protocol gate:** part of the intended path is
  deliberately non-submittable, and more contract evidence and production
  integration are needed. This is not merely an unexecuted test.
- **Presentation gap:** existing state supports a clearer required display or
  recovery action without inventing a server contract.
- **Optional extension:** useful behavior not explicitly required by the cited
  plan; its absence must not enlarge or redefine the first release.

## Requirement matrix: 2026-09-12 historical snapshot

References to then-current code, unexecuted tests and missing range proof in
this matrix describe the original audit. The dated status above supersedes
those limitations where later implementation/evidence is cited, without
rewriting what the original audit observed.

| Plan requirement | Source observed at the original audit | Classification at that time |
| --- | --- | --- |
| Single-episode coin payment from existing balance (§2, §8) | `Quote.build` supports the no-extra-discount branch only when present `ep_original_gold` and `pay_gold` agree, uses the episode quote's `remain_gold`, and constructs `buy_method=3`. Different or missing amounts produce an advisory candidate. | Code present for the ordinary agreeing-price branch; live quoting and debit behavior remain unverified. Disagreeing-price cases are a protocol gate, not demonstrated support. |
| Single-episode eligible reading coupons (§2) | `Selection.normalize` accepts explicit `coupon_ids`; `Quote.build` otherwise uses `recommend_coupon_ids`, checks count and membership against the supplied eligible/recommended set, and constructs `buy_method=2` with the array. | Code present; current live eligibility, recommendation shape, and consumption are unverified. The generic `eligible_coupon_ids` adapter field has no established production population in the inspected contract. Do not claim access to all account coupons from this field. |
| Show the selected coupons (§3.4) | Quote and intent retain concrete coupon IDs. `Screens:_purchaseSelectionText` currently displays only `Selected coupons: N`; the payment picker exposes method/discount options, not the individual reading-coupon identities. | Presentation gap. An explicit review of the IDs already selected by the server recommendation is independently implementable. Names, expiry, or alternative inventory choices require actual corresponding metadata; they must not be invented. |
| Server-supported batch coin offers (§2, §8) | `quote_fetch`, `Candidate.describe`, and UI range choices preserve original offer index, nominal limit, fractional anchor order, and discount order. `Quote.build` requires the offer proof and matching context `exact_scope_verified`; the production collector provides no such proof. Zero-limit offers remain advisory. | Implementation plus protocol gate. Exact positive/zero membership and final payable amount are unresolved, and a proven production scope adapter is still missing. Keep this mandatory first-release feature open; do not relabel its advisory UI as support. |
| Server-supported discounts and selected extra assets (§8) | Fresh basic/range observations, calculated-price maps, selected discount/card identity, and scoped free-gold-card queries are implemented. `Candidate.describe` separates original, display, submission-reference, and free-gold amounts. `Quote.build` returns advisory for every non-none discount choice. | Implementation plus protocol gate. Actual extra-asset consumption semantics remain unverified and the confirmable quote/payload path for these branches is deliberately absent. Source-derived arithmetic alone is insufficient to enable it. |
| Exact scope, entitlement, asset, total and usable balance in confirmation (§3.4) | A submittable quote carries exact `episode_ids`, expected `owned` snapshots, method, amount, and balance. UI shows those values and an exact-chapter review. Advisory candidates explicitly lack a payable confirmation action. | Code present with the selected-coupon presentation gap above. Actual server totals and batch membership remain acceptance gates. |
| Selection/payment changes require a new quote and confirmation (§3.4, §8) | UI changes call `_quote`; normalized immutable selection and matching context are carried through collection. Controller saves the displayed quote snapshot and uses that saved snapshot during submission. Fingerprints include scope, payment, amounts and selected asset observations. | Code present; current behavioral acceptance is unverified. Do not silently reuse an old confirmation when a range, card, coupon set, sort, or amount changes. |
| Changed quote before transmission (§8, §11) | `Service:prepareSubmission` compares the fresh fingerprint and returns `quote_changed` with the new quote before creating/transmitting the purchase. `Controller:purchase` propagates it. UI stores the error and offers Refresh quote; it does not use `error.quote`. `Model.error` has no specific `quote_changed` branch. | The required submission guard and renewed-confirmation route are present. A clear price/terms-changed message and direct presentation of the already returned fresh quote are independently implementable presentation improvements. Current generic feedback should not be described as missing payment safety. |
| Insufficient balance preserves selection and offers refresh (§3.4) | Quote sets `can_afford`; UI disables confirmation, preserves scope/payment, and offers Refresh balance followed by a fresh quote. `prepareSubmission` also rejects insufficient balance. | Code present; live balance units, spendability, and failure acceptance remain unverified. No recharge is required or present. |
| Persist intent before network transmission and serialize submissions (§8) | `prepareSubmission` records account, exact scope, selected assets, before/expected access, purpose, and `submitting` in its own committed transaction; active submission checks run before returning a payload. Controller then dispatches one noncancelable purchase worker. | Code present; current end-to-end failure acceptance remains unverified. Historical synthetic checks do not establish current live payment support. |
| Lost response or restart never automatically resubmits (§8, §11) | Service distinguishes accepted, unknown, rejected, and access-confirmed states. `recover` turns interrupted submitting records into unknown; unresolved overlaps block another submission. Controller retains unpersisted response observations for a local write retry. | At the original audit, crash/lost-response acceptance was unverified and new synthetic execution was outside that authorization. Later isolated transaction results are cited above; live lost-response behavior remains unverified. |
| Reconcile exact permanent entitlement; wallet changes are insufficient (§8) | `completeReconciliation` checks each intended episode for explicit owned access without a positive expiry. It retains confirmed/unresolved subsets and does not derive payment success from wallet totals. An access-only confirmation keeps absent transaction evidence explicit. | Code present; actual delayed entitlement delivery and temporary-access distinctions require acceptance evidence. |
| Preserve accepted payment when later work fails (§8, §11) | Accepted transaction evidence is separate from entitlement/wallet refresh errors. Known results survive local persistence failures in process memory, with the durable earlier intent continuing to prevent replay after restart. | Code present; current fault acceptance remains unverified. No additional speculative implementation defect was established in this audit. |
| Resume the original read/download intent (§3.4) | Intent stores `purpose`. After complete entitlement confirmation the UI offers the corresponding action and retries loading/downloading without repurchasing. Reading resumes the anchor episode. | Code present for the original single-chapter read/download action. A second explicit action button is the implemented continuation behavior; the plan does not explicitly require automatically launching it without that action. |
| Partial batch result and delayed entitlement (§8, §11) | Service preserves `confirmed_episode_ids` and `unresolved_episode_ids` and continues blocking unresolved overlaps. Pending UI presents the aggregate pending result and Refresh result; it does not show the subsets or offer a confirmed-anchor continuation there. | Backend state is implemented. Exposing the existing partial result in the pending UI is independently implementable. The ordinary refreshed chapter catalog can still expose already-owned chapters; do not claim a missing entitlement model. |
| Balance display and account assets (§2, §3.4) | `Client` uses `device=pc` and `platform=web`. `wallet()` preserves sanitized raw fields; Account renders `remain_gold` and `remain_coupon`. The purchase sheet uses the selected episode quote's balances, not the general wallet total as proof of eligibility. | Core balance display is implemented. A protocol-context label and an unavailable-balance row when actually present are useful presentation additions. Per-operating-system account ledgers are not an explicit release requirement and are not proved by the inspected fields. |
| No recharge, automatic purchase, silent asset substitution or auto-buy setting changes (§2, §8) | Selection accepts only supported explicit methods; purchase payload construction excludes auto-pay fields; worker purchase submission requires a persisted intent; generic read operations do not submit purchases. | Code boundaries are present. The plan's separate requirement to establish that read/acquisition requests do not unexpectedly consume assets remains a service/account behavior verification gate. |
| M0 single/batch quote and eligibility gate (§10) | At the original audit, request collection and candidate mapping existed, but no authenticated quote or wallet response evidence had been collected. | Read-only observations and standard ordinal construction were still pending then. They have since executed as cited above; actual debit and additional-asset semantics remain separate. |
| M3 purchase and continuation acceptance (§10) | UI, journal, workers and reconciliation paths existed, but the original batch/discount gates remained and no actual authorized charge was established. | Open at the original audit. Its restriction included synthetic tests; the 2026-09-13 authorization superseded that restriction. Actual purchasing remains prohibited and unverified. |
| Required purchase failure cases (§11) | Concrete branches existed for quote changes, insufficient balance, ineligible coupons, duplicate submissions, lost responses, restart recovery, partial batches, delayed access, and post-acceptance refresh errors. | At the original audit, new behavioral verification had not run. Later isolated selection/transaction/UI records are separate, executed evidence; they are not live charging acceptance. |
| Other M0/M4 reading, packaging and device gates (§10–11) | Separate status and reading reports contain non-purchase evidence. This audit inspected the purchase boundary only. | Outside this bounded acceptance audit. Their existence does not prove M3, and this report makes no new claim that those independent gates are complete. |

## Follow-ups identified by the original audit

| Priority | Classification | Bounded work | Why it does not require a new server assumption |
| --- | --- | --- | --- |
| 1 | Required display correction | Show the exact reading-coupon IDs already in the displayed quote and retain that display through refresh/errors. | The identities are already present in the quote and journal. This completes the selected-asset display without inventing a coupon inventory. |
| 2 | Optional presentation improvement | Handle `quote_changed` explicitly, displaying changed terms and the returned fresh quote before any new confirmation. | The service already returns that quote and prevents transmission. An advisory fresh result must remain non-submittable. The existing Refresh quote plus new confirmation route already satisfies the required guard. |
| 3 | Optional partial-result convenience | Display confirmed/unresolved chapter subsets in the pending result, and expose an already-confirmed original anchor action while retaining unresolved purchase protection. | The state machine already records the exact subsets. A continuation must use confirmed IDs and must not retry or replace the purchase. Dedicated subset controls are not an additional release requirement. |
| 4 | Optional balance-context clarification | Label balances as the current web-protocol context, and show `unusable_gold` only if the sanitized response actually contains a valid value. | The protocol context is explicit in the client, and the existing official Wallet model maps that field. Its cause must not be labeled iOS/Android without evidence. |

These were independent implementation/presentation suggestions at the original
audit date. The selected-coupon display and later non-purchase checks have their
own records above. Presentation work does not establish charging or consumption,
and authorization comes from the user's current instructions rather than this
historical document.

## Original scope distinctions, with current limits

The combined batch-download flow and optional UI observations below are
preserved from the original scope audit. Standard coin ordinal construction is
now implemented; this does not itself expand those product requirements or
prove a live purchase.

| Question | Finding |
| --- | --- |
| Must the first release include an arbitrary manual reading-coupon browser? | The plan requires eligible reading-coupon payment and visibility of selected coupons. It does not explicitly require browsing/selecting any coupon in the account. Current service input can retain explicit IDs; UI currently uses server recommendations. Full manual selection needs an established inventory/eligibility source and must not be added as an inferred release gate. |
| Is batch reading continuation wholly missing? | No. A fully confirmed batch retains an anchor and can continue reading it; native chapter flow can subsequently use refreshed access. Standard coin ordinal construction is now implemented under the linked contract; actual batch charging and delivery remain unverified. |
| Can the purchase dialog buy a server batch and resume downloading that whole batch? | Not currently. Download purpose forces a single scope in `_quote` and hides batch choices; continuation passes only the anchor to `downloadEpisodes`. This is a concrete absent combined flow. The cited plan promises batch purchase and preservation of an original read/download intent, but does not explicitly define a new batch-download intent from this single-chapter purchase entry. Do not silently call the combined flow supported, or expand the release gate without resolving that product interpretation. |
| Is automatic immediate continuation required? | The plan says to resume the original intent but does not explicitly specify automatic launch versus the existing matching action button. Durable purpose and correct continuation are implemented; automatic launch is not a separately established requirement. |
| Does `unusable_gold` prove a particular operating-system balance? | No. The inspected source maps an unavailable amount separately from `remain_gold`; it does not justify inventing per-OS accounts, currency conversion, or an added recharge flow. |
| Are every discount-card/free-gold-item feature and full-comic purchase mandatory? | The plan includes server-supported discount quoting but explicitly excludes new wait-free/rental/item/silver entitlements, arbitrary noncontiguous atomic purchases, unverified batch coupons, and automatic purchasing. The distinct whole-comic purchase form must not be equated with an unverified zero-limit batch. |

## Source map

- [Implementation plan](implementation-plan.md), sections 2, 3.4, 8, 10, and 11.
- [Quote selection implementation](quote-selection-implementation.md), including
  its dated snapshot history and advisory extra-discount candidates.
- [Current non-purchase integration](nonpurchase-integration-report.md) and
  [ordinal-range contract](ordinal-range-contract.md), which supersede the
  original authorization/execution and standard-batch-proof limitations.
- [Batch quote contract](../research/protocol/batch-quote-contract.md) and
  [discount/asset selection contract](../research/protocol/discount-selection-contract.md).
- [Quote](../bilicomics/purchase/quote.lua): exact-scope checks, payment branches,
  recommendation resolution, selected-asset persistence, and advisory returns.
- [Quote collection](../bilicomics/purchase/quote_fetch.lua),
  [selection](../bilicomics/purchase/selection.lua), and
  [candidate metadata](../bilicomics/purchase/candidate.lua): context binding,
  original offer identity, price-vector association, and explicit unknowns.
- [Purchase service](../bilicomics/purchase/service.lua): durable state machine,
  changed-quote guard, partial results, and no-replay recovery.
- [Controller](../bilicomics/controller.lua): `getWallet`, `refreshWallet`,
  `_fetchQuote`, `purchase`, and `reconcilePurchase`.
- [UI screens](../bilicomics/ui/screens.lua): `_account`, `_quote`,
  `_purchaseSelectionText`, `_purchaseChoices`, and `_purchaseDialog`;
  [UI model](../bilicomics/ui/model.lua): error and selection presentation.
- [Protocol client](../bilicomics/protocol/client.lua): fixed PC/web request
  context, sanitized wallet data, quotation routes, and purchase payload boundary.

The unavailable-wallet-field observation was cross-checked by reading the
already saved official string-inspection file at
`C:/Users/moooyo/AppData/Local/Temp/bilicomics-reader-image-research-static.txt`,
using the `class _0x7f6577` Wallet model and the
`unusable_gold` to `unuseableGold` decorator mapping. That source was not
executed. Constructor defaults were not treated as actual response values.
