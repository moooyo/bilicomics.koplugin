# Purchase selection contract

`selection.lua` is a pure local selection normalizer. It performs no network,
storage, quote, wallet, SDK, or purchase operation. Accepting a selection does
not establish a valid quote or authorize submission.

## Interfaces

```lua
local selection, err = Selection.normalize(scope, payment)
local request_scope, err = Selection.requestScope(selection.scope)
```

`normalize` returns new tables and preserves no mutable references to caller
tables. The input may be `nil`, an empty table, or the existing `single`, `batch`,
`coin`, and `coupon` string shorthand where applicable. Missing kind/method
defaults to single/coin. A batch still requires an explicit limit.

The normalized selection is:

```lua
{
    scope = {
        kind = "batch",
        batch_limit = 20,
        start_ord = 12.5,
        order = 2,
        offer_index = 3,
    },
    payment = {
        method = "coin",
        discount = {kind = "discount_card", id = "123"},
    },
}
```

`scope.order` is the discount sort enum, `1=Discount` or `2=Expire`, and defaults
to 1. It is never derived from `start_ord`. `offer_index` is the original
one-based Lua index in the complete `batch_buy` array, before filtering or
reordering. It is optional for compatibility with existing verified adapters;
omission never authorizes choosing the first matching offer implicitly.

`batch_limit` is an integer from 0 through 2147483647. Zero remains a read-only
remaining-offer query and is not a permitted purchase scope. `start_ord` is
optional and finite; fractional values are preserved. `offer_index`, when
present, is an integer from 1 through 2147483647. Single selections may contain
discount order but reject all batch range/index fields.

Coin payment defaults to `discount={kind="none"}`. Supported selection kinds
are `none`, `discount_card`, `activity`, and `free_gold_card`. Every non-none
selection requires an explicit ID. The `none` selection rejects an asset ID
instead of retaining a meaningless identity or silently rewriting it. IDs become
strings, must be nonempty, contain no control characters, and occupy at most
256 bytes. Numeric IDs must be exact nonnegative integers within the Lua number
safe-integer range; callers should retain server string IDs as strings.

Reading-coupon payment accepts only its method and optional `coupon_ids` array.
An explicit array must contain 1 through 1024 distinct bounded IDs, without
holes or additional keys. An omitted array leaves recommendation resolution to
the fresh quote response. Coupon order is retained. Coin payment rejects
reading-coupon IDs; reading-coupon payment rejects a discount selection. Batch
reading-coupon payment is rejected.

Unknown fields are rejected, including `price`, `saved_gold`, asset amounts,
eligibility flags, predicted/exact chapter IDs, server proof flags, and raw
purchase payload options. The caller must resolve prices, eligible assets and
their amounts from fresh responses, never from this input model.

## Wire mapping

`requestScope` revalidates the scope and creates only the current
`Client:purchaseInfo` scope fields:

```lua
-- Single selection, including the explicitly preserved discount order:
{kind = "single", buy_type = 1, order = 1}

-- Selected batch:
{kind = "batch", buy_type = 2, batch_limit = 20, start_ord = 12.5, order = 2}
```

`offer_index` is deliberately absent from the request. `Client:purchaseInfo`
consumes these fields, sends the discount-order value as `order`, and keeps
`start_ord` out of that query body. Fetch basic purchase information separately
without a selection scope when the original full offer list is needed; a
range/discount response must not replace that base snapshot by assumption.

## Quote integration requirements

Normalize before dispatching any worker request. Carry the complete immutable
selection through the UI, worker result, quote, refreshed quote, confirmation
fingerprint, and durable intent. Changing any selection field must create a new
quote requiring a new confirmation. Retain original offer position and its
original-price association even if UI candidates are filtered or reordered.

Keep original price, displayed price, submitted amount and separately consumed
assets distinct. A missing response field or missing calculated-price map key
is incomplete evidence and must never become zero. Existing structural
fingerprints cannot detect selection fields that were discarded beforehand.

Candidate construction must not set `exact_scope_verified`. No source inspected
so far proves an authoritative exact batch chapter set. Existing submission
gates for exact membership, usable quote scope, final amount, eligibility, and
explicit confirmation remain required.

This module was added under a restriction against all purchase tests, including
synthetic tests. No runtime execution or behavior verification is recorded by
this document. Static review and any separately authorized syntax-only check
must not be reported as verified account or purchasing behavior.
