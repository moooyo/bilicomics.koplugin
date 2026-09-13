# Purchase service

The service owns explicit purchase quotes and the durable purchase journal. It never recharges, changes auto-buy settings, selects a fallback asset, or replays a purchase request. `quote`, `submit`, and `reconcile` are synchronous convenience methods for controlled execution; they must not be called on the native UI thread with the network client.

## Main-process integration

Use the following split operations with the job runner:

1. Normalize the complete scope/payment with `Selection.normalize` before dispatch. Run `quote_fetch.run` in the quote worker to obtain basic information, detail, scoped discount information and explicitly selected auxiliary price/asset reads. Pass its results to `buildQuote(episode_id, scope, payment, raw_info, raw_detail, context)` in the main process. The synchronous convenience method uses the same collector.
2. Display the exact quote. After explicit confirmation, fetch the same selection again and call `buildQuote` to create a fresh quote. The controller must reject obsolete account/request generations before accepting either result.
3. Call `prepareSubmission(confirmed_quote, {confirmed=true, purpose="read"|"download"}, fresh_quote)`. It returns `intent, payload` or `nil, error`. Immediately before the queued worker starts, call `authorizeSubmission(intent.id)` against the durable journal. Both must succeed before dispatching `Client:buyEpisode(payload)` once; waiting does not extend the quote lifetime.
4. Pass the worker response to `completeSubmission(intent_id, response, error)`. Pass entitlement refresh results to `completeReconciliation(intent_id, episodes, wallet, error)`; `episodes` may be a normalized episode array or a `{episodes=...}` object. The optional wallet argument only records an explicit `wallet.error`; its numeric balances never establish payment.
5. Resume the original action only for `access_confirmed`, or for an individually confirmed chapter in a partial batch. Preserve the unresolved subset.

All mutating journal methods require a top-level transaction. They reject the production store's active `_depth > 0`; releasing a nested savepoint cannot authorize network transmission. Startup `recover()` is local and must run after old workers have been terminated or reaped. It changes interrupted `submitting` records to `outcome_unknown` and performs no network work.

`prepareSubmission` rejects reuse of the original quote ID and requires equal structural fingerprints. The controller is responsible for supplying genuinely fresh worker responses after confirmation; an ID or fingerprint is not evidence of a new server request. The fingerprint is a deterministic length-prefixed encoding of the exact selection and payment terms, not a hash, authentication signature, server receipt, or idempotency key.

When a response is known but its journal update fails, the process retains the observed result with `persistence_pending=true`. A subsequent completion or reconciliation attempts to persist it again. The previous durable `submitting` record continues blocking replay; a later process restart conservatively treats it as unknown. Arbitrary exception messages, raw transport responses, credentials, and signed URLs are never copied into intents.

A refused new dispatch is not a receipt about an earlier attempt. For an intent
that has already left `submitting`, completion with `transmitted=false` preserves
the existing unknown/accepted/access-confirmed result and any range hold. It may
persist an already observed in-memory result, but cannot replace historical
uncertainty with a rejection.

## Quote fields

```lua
{
    schema_version = 1,
    id = "...",
    account_key = "...",
    episode_id = "10",
    comic_id = "1",
    episode_ids = {"10"},
    scope = {kind = "single"},
    payment = {method = "coin"},
    method = "coin",
    amount = 30,
    balance = 100,
    can_afford = true,
    before_access = {["10"] = {access = "locked"}},
    expected_access = {["10"] = {access = "owned"}},
    payload = {ep_id = "10", buy_method = 3, pay_amount = 30},
    created_at = 1000,
    expires_at = 1120,
    fingerprint = "...",
    scopes = {{kind = "single"}},
    payments = {
        {method = "coin", available = true},
        {method = "coupon", available = false},
    },
}
```

The default scope/payment are `single`/`coin`. A coupon selection is `{method="coupon", coupon_ids={...}}`; omitted coupon IDs use the server's recommendations. Only IDs explicitly in the current eligible/recommended set can be used. Reading coupons are sent as the `coupon_ids` array; `coupon_id` is not substituted for it.

Selections now retain `scope.order`, the original `scope.offer_index`, and `payment.discount={kind,id?}`. See [the selection contract](selection-contract.md). The quote, fresh quote and fingerprint preserve canonical selection, distinct amount observations and selected-asset metadata. Controller confirmation uses its saved quote snapshot, never a caller's replacement table. Candidates are not saved as confirmable quotes.

The first-party single-episode no-extra-discount handler submits `ep_original_gold`, while its display uses `pay_gold`. The plugin permits its ordinary coin quote only when both fields are present and equal and `remain_gold` is usable. Missing or different amounts return an advisory candidate; a field named `final_pay_amount` does not silently resolve that ambiguity. A known zero still follows the observed omission of `pay_amount`, whose live request behavior remains unverified. No fiat conversion or multiplication is performed.

## Advisory candidates

`Candidate.describe` preserves every original offer position, the corresponding original-price-vector index, scope-specific discount identities, and explicit field presence. It keeps `amounts.original`, `amounts.display`, `amounts.submission` and `amounts.free_gold` separate. A calculated-price response is keyed by the original amount; missing or conflicting exact keys do not become zero. The full input vector retains unusable offer positions too. Auxiliary free-gold eligibility uses the selected batch's `amount`, not its nominal limit; missing single/full count semantics are not invented.

`submittable=false` objects expose candidate choices and fixed blockers but no purchase payload, exact chapter IDs, confirmed payable `amount`, affordability assertion or confirmation fingerprint. The UI can change scope, payment and discount ordering and fetch a new candidate. It offers bounded selection pages and a details view; it does not show a purchase confirmation or permanent-ownership claim for these objects. Extra discount/card choices remain advisory because their final asset-consumption contract is not verified. Reading coupons remain a separate payment method.

Basic and scoped responses are separate snapshots. `optional_discount_list` is the wire name; the SDK's `discounts` is a mapped property. Constructors/default zeros do not prove eligibility. Context binds comic, episode and the complete normalized selection before any scoped asset evidence is consumed. See [the first-party field extraction](../../research/protocol/discount-selection-contract.md).

## Batch capability gate

Production `quote_fetch` and `Range.resolve` support standard coin batches with
`payment.discount.kind="none"`. The selected original offer, basic and scoped
quote responses, and original `detail.extra.ep_list` must reproduce the
[ordinal range contract](../../docs/ordinal-range-contract.md). Quote rebuilds
the proof independently before producing a submittable payload.

A positive `batch_limit` selects that many explicitly locked chapters from the
anchor, skipping known free and owned chapters. An explicit usable zero-limit
offer selects the remaining locked chapters from that anchor. Zero is not a
wildcard for arbitrary chapters or the separate whole-comic purchase form.
Conflicting prices, ambiguous access, unsupported assets, and unproved ranges
remain advisory and have no purchase payload.

The proof uses `contract="bilibili_pc_ordinal_range_v1"` and
`server_confirmed_ids=false`. Its chapter IDs are the current intended members
under the server-supported ordinal rule, not a server reservation or payment
receipt. The UI must disclose that catalog changes and purchases elsewhere can
change the actual delivered members. Extra discounts and batch reading coupons
are not enabled by this proof. See the contract for complete field, ordering,
price, and eligibility requirements.

An uncertain ordinal submission retains `range_outcome_pending`, blocking
further same-comic purchases even if the originally expected IDs do not overlap.
Entitlement reconciliation may permit reading without proving the payment
outcome or clearing that hold.

## Verification

Run verification only through remote `test-env` unless the current task
explicitly authorizes local verification. Synthetic state-machine and protocol
checks use artificial credentials and injected transport inside network
isolation. The [implementation status](../../docs/implementation-status.md) and
[stabilization record](../../docs/architecture-stabilization.md) identify the
applicable source snapshots and results; historical reports do not establish
that a later revision passes.

The following are individual synthetic test entry points, not a complete
release acceptance command:

```sh
./luajit /path/to/plugin/spec/purchase/state_machine.lua /path/to/plugin
./luajit /path/to/plugin/spec/purchase/protocol_boundary.lua /path/to/plugin
./luajit /path/to/plugin/spec/purchase/restart.lua /path/to/plugin /unique/test/data prepare
./luajit /path/to/plugin/spec/purchase/restart.lua /path/to/plugin /unique/test/data recover
./luajit /path/to/plugin/spec/purchase/restart.lua /path/to/plugin /unique/test/data confirm
./luajit /path/to/plugin/spec/purchase/restart.lua /path/to/plugin /unique/test/data inspect
```

State-machine tests use synthetic catalogs and injected clients.
Protocol-boundary tests use the production client with an injected transport
and synthetic credentials. Restart tests use production SQLite in separate
LuaJIT processes. Separate authenticated read-only observations established
positive and remaining-range quote construction; see the
[non-purchase integration report](../../docs/nonpurchase-integration-report.md).
Neither kind of evidence proves actual charges, coupon consumption, or delivered
post-purchase membership. Actual purchases, including zero-price submissions
and coupon spending, require explicit authorization for the concrete account,
chapter, asset, and amount. They are excluded from the stabilization regression.
