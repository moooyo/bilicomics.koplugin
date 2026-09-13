# Synthetic native quote-selection UI verification

The current quote-preview UI passed 141 assertions at each of 600 × 800 and
480 × 640 using the unchanged official KOReader v2026.07.1 Linux runtime.
This is synthetic UI evidence, not evidence of a live payment or verified
server-side batch pricing.

## Isolation and scope

`run_quote_selection.py` launches each size through `unshare -n`, with its own
HOME, KO_HOME, and XDG directories. The Lua spec checks that its network
namespace differs from the parent namespace and that no IPv4 route entries
exist. Empty and header-only route files are both accepted.

The spec forbids loading production Controller, Runtime, Client, Transport,
Session, PurchaseService, and quote construction/fetch modules. All controller
responses are synthetic, and recorded arguments are deep copies. There are no
account imports, private fixtures, actual API requests, or actual purchases.
Each isolated process invokes the fake controller's purchase callback exactly
once, after an explicit native confirmation-button action. Repeated or stale
confirmation callbacks do not invoke it again.

The focused cases cover:

- Eight scope choices across four pages and nine payment choices across five
  pages, with at most two choices per page and unavailable choices disabled.
- Advisory single and batch candidates without a Confirm action, exact-range
  claim, ownership claim, or confirmed-payable claim. Candidate reference
  amounts remain separately labeled in the details viewer.
- Scope, method, discount, and ordering changes re-quoting the complete retained
  selection, without copying server amount fields into selection arguments.
- Closed, superseded, covered, and account-generation-stale callbacks being
  ignored, including delayed balance refreshes.
- Verified single/coupon details using the synthetic quote snapshot and
  preserving concrete coupon IDs with leading zeros.
- Insufficient balance retaining the selected scope and payment.
- One explicit fake confirmation, submission controls being disabled, and no
  duplicate fake submission.

The production Model, Screens, and Chinese locale hashes were identical before
and after these checks. No production code was modified for this verification.

## Evidence

- `quote-selection-verification.json`: source/test SHA-256 values and both runs.
- `quote-selection-result.json`: the 600 × 800 assertion results.
- `quote-selection-result-480.json`: the 480 × 640 assertion results.
- `screens/quote-selection/600x800/` and `screens/quote-selection/480x640/`:
  actual native framebuffer captures of the synthetic dialogs.

The successful remote run is
`/tmp/bilicomics-quote-selection-ui-zAYEAh/run-2`. Relative result paths in the
verification JSON refer to this original output directory. Representative
captures of both sizes were visually inspected, including the narrow candidate,
choice pagination, coupon IDs, insufficient balance, and confirmation views.

The first harness attempt stopped at the isolation precondition before loading
the UI because it assumed an empty route table always included a header. The
second run uses the corrected empty/header-only check and passed both sizes.

To reproduce on the authorized remote test host with a separately staged source
tree and a fresh output directory:

```sh
python3 /path/to/staged/plugin/spec/ui/run_quote_selection.py \
  /tmp/bilicomics-native-_duimwe7/lib/koreader \
  /path/to/staged/plugin \
  /tmp/a-new-quote-selection-output
```

The fixtures deliberately include synthetic verified scopes and balances to
exercise presentation and callback handling. They do not make unverified
production batch offers submittable, establish asset availability, or test
actual submission, deduction, entitlement reconciliation, or a physical device.
