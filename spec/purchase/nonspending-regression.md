# Non-Spending Purchase-State Regression

On 2026-09-13, the separately authorized synthetic regression passed on
ssh test-env with the official KOReader v2026.07.1 runtime. Every Lua process
ran in a distinct unshare -n network namespace. The
[new result](nonspending-regression-result.json) preserves runtime, production
source, fixture and guard hashes; the historical verification-results.json
has not been overwritten.

The bounded run covers:

- 34 state-machine cases: single-episode coin/coupon confirmation, changed or
  unverified fresh quotes, insufficient/ineligible assets, duplicate/concurrent
  intents, lost responses, reconciliation, cross-account isolation and result
  preservation after storage failures.
- 12 protocol-boundary cases: actual Client:buyEpisode request construction
  and response parsing with an explicitly injected memory-only transport.
  The transport checks the exact URL, method, synthetic cookie, single call
  and complete per-case body. It returns only fixed synthetic responses.
  Batch metadata is rejected before reaching even this fake route.
- Eight independent SQLite processes: prepare, recover, confirm and inspect,
  separately for original read and download purposes. Recovery never invokes
  a client, preserves the original chapter and purpose, blocks overlapping
  resubmission and retains the absence of a payment receipt.

Fixture prices now provide equal ep_original_gold and pay_gold where a
single coin quote is intended to be usable. Changing both prices tests fresh
confirmation; changing only the display price tests rejection of incomplete
evidence. The retained multi-episode reconciliation case starts from a directly
seeded historical accepted journal, explicitly marked with its origin. It does
not create a new batch quote or supply context.exact_scope_verified.

The nonspending_entry.lua wrapper replaces production Transport.request before
loading the tests and blocks socket HTTP/TLS, native acquisition and Worker
modules. Real/fallback transport and forbidden-module attempts were zero.
Synthetic Service clients and the protocol fake transport remain distinct
from real network operations. No user session, external account or physical
device was used, and no actual charge or coupon consumption was possible.

These results validate state and wire construction with synthetic outcomes.
They do not establish a real transaction, live entitlement delivery, exact
batch membership, or execution of Controller/UI continuation actions.
The 259-assertion pure quote suite and 115-assertion identity suite were not
rerun as part of this regression.

To reproduce after copying the production source and the five test/launcher
files to an isolated remote directory:

    ssh test-env 'python3 /tmp/nonspending/run_nonspending_regression.py --runtime /tmp/bilicomics-native-_duimwe7/lib/koreader --source /tmp/nonspending/source --output /tmp/nonspending/results'

The output directory must not exist. The driver copies only the required
production modules, uses isolated XDG data and records every process result.
