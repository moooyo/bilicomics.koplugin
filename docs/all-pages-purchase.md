# Purchase handoff audit

The E1–E5 requirements come from the Scribe handoff README and the corresponding
HTML artboards in `D:\Code\design_handoff_bilicomics_scribe`. The HTML remains a
reference; production UI uses the existing Lua and KOReader widgets.

| Design state | Requirements checked | Changes and evidence |
| --- | --- | --- |
| E1: quote review | 84 × 112 dp cover; chapter ordinal and purpose; 80 dp scope and payment rows; price and original-price hierarchy; coin/coupon availability; total panel; explicit confirmation | Added expected chapter counts, original-price metadata, chapter ordinals, wallet availability for both methods, single-chapter coupon restriction, grouped amounts and a single method row preserving the selected asset IDs. Scribe ready and coupon quotes each fit one page. |
| E2: insufficient balance | Selected range; 2 dp total border; 44 dp amount; balance and deficit; refresh/recharge footer | Removed the artificial bottom body reserve that pushed the total onto a second page. The 3,132-coin fixture shows a 2,852-coin deficit above the action bar on one Scribe page. Confirmation is absent. |
| E3: submitting | No header actions; locked tag; frozen scope/payment/amount/time rows; submitting explanation; disabled footer | Tags use their natural label width and 16 dp text. Added the table top rule and explicit single-chapter scope. Matched the 14 dp separation before the submission explanation. Both footer actions remain disabled. |
| E4: pending result | Pending tag and 36 dp heading; submitted chapter/quote/time/record; payment disclaimer; close/reconcile footer | Corrected tag, heading, table and disclaimer spacing. The submitted record is preserved. Reconciliation sends no second purchase request. |
| E5: confirmed access | 88 dp confirmation mark; 36 dp heading; chapter access explanation; amount/balance/time rows; catalog/download/read footer | Added ordinal and permanent-unlock copy only when observed `access_evidence` proves owned access. Access-only, unresolved-range and persistence-pending outcomes retain their distinct evidence and recovery rules. |

The audit also renders loading, result checking, rejected, expired, changed,
coupon, missing coupon balance, access-only, range-pending, persistence-pending,
payment options and record details. Small displays and landscape use the native
page partitioning; the acceptance walks and captures every page in both directions,
returns to the first page, and exercises the retained controls and guards.

## Preserved evidence and behavior

- An unselected offer's display amount is marked as a reference; it is not a
  verified final charge. An original-price line is omitted when equal to the
  selected amount, and coin metadata is not applied to a coupon total.
- E5 uses `Confirmed quote` for server acceptance and `Submitted quote` when
  only access was confirmed. The service has no separate charge receipt, so the
  design's `Paid` label is not claimed from a quoted amount.
- Missing coupon balance stays unknown. A coin balance is never displayed as a
  coupon count. The selected coupon IDs remain frozen in the quote.
- An unselected range without an adapter-supplied amount displays `Price
  unavailable`. Selecting it requests a new quote instead of inventing a price.
- Existing exact/expected chapter and saved-record controls remain available
  below the corresponding content. These are additional review entries compared
  with the artboards, preserving the established recovery and scope workflow.
- Every selection requests a new quote. Existing account, generation, request,
  visible-dialog and pending-result guards remain intact. No real purchase,
  recharge or account access is performed by this acceptance.

## Reproducible verification

`spec/ui/all_pages_purchase_spec.lua` is an extra module for the shared native
Scribe harness. `spec/ui/run_all_pages_purchase.py` selects the purchase domain
and runs that module with the standard runner arguments. Use an authorized WSL
or Linux KOReader runtime and an output directory outside the repository:

```text
python3 spec/ui/run_all_pages_purchase.py RUNTIME PLUGIN OUTPUT --languages zh_CN C
```

The verification matrix is 1860 × 2480, 480 × 640, 600 × 800 and 960 × 720, each
in Chinese and English. Each case uses the actual KOReader framebuffer, an
isolated profile, a network namespace with no routes, controlled callbacks and
original synthetic cover fixtures. Per-case results and screenshots are stored
under the size/language directory; the aggregate report is
`scribe-handoff-verification.json`.

The final frozen-source acceptance reran this module in the
[shared native matrix](../spec/ui/scribe-handoff-verification.json), which passed
7,958 assertions and produced 1,014 screenshots across all eight combinations.
Its production and test-source hashes were unchanged before and after the run.
Coverage includes a 20-chapter pending record, payment/range option pages,
coupon IDs preserved after repricing, one explicit submission after returning
through pages, reconciliation without a second purchase, and stale/covered/account
generation callback protection.

The [complete-page coverage receipt](../spec/ui/all-pages-acceptance.json)
requires current source identity and a full-frame native capture for every
E1-E5 page at all eight combinations. Earlier domain runs made during parallel
editing are not the final source-stability evidence.
