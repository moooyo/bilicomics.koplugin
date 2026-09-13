# Non-purchase integration report

Date: 2026-09-13. The user explicitly allowed operations other than actual
purchasing. This report covers authenticated read-only observations and
isolated tests with synthetic or privately captured response data. No real
purchase, coupon use, recharge or account write was performed.

## Authenticated observations

The initial observer failed after successful navigation/session validation and
following-list reads because its isolated Lua C-module search path omitted the
runtime root pattern needed by `libs/libkoreader-lfs`. No quote request was sent
in that attempt. An offline diagnostic reproduced the launcher configuration
error, and adding the runtime-root pattern corrected it without changing the
production request or crypto code. The failed attempt is retained in
[its public record](../research/protocol/quote-observation-first-attempt.json).

The subsequent [initial observation](../research/protocol/quote-observation-live-result.json)
completed seven business reads and one pinned public signing-WASM download.
It selected one locked chapter in the first followed comic, then read the basic
quote, the single-chapter scoped quote, a usable positive batch offer and the
explicitly usable remaining offer. All eight HTTP responses succeeded and the
guard recorded no blocked request. Each quote's server comic identity matched;
the service omitted `ep_id`, which is distinguished from a server identity echo.

The [range follow-up](../research/protocol/quote-range-live-result.json) read
three more quotes: basic/scoped information at an interior anchor and basic
information near the end. The interior remaining offer's count and price match
the locked chapters from that anchor, rather than all locked chapters in the
comic. The tail's positive offers are explicitly unusable despite containing
amount and price values; no scoped request was made for them. Original offer
positions must be preserved. See the [batch analysis](../research/protocol/live-batch-observation.md)
for the sampled field relationships and remaining contract limits.

One separately guarded [wallet read](../research/protocol/wallet-observation.md)
succeeded. `remain_gold` and `remain_coupon` were numeric and individually
matched the earlier basic quote fields. Raw amounts, account/comic/chapter/asset
identities, titles, cookies, signed URLs and raw captures are not published.

These observations establish sampled read contracts, not purchase execution,
asset consumption, server-confirmed batch membership, or physical-device
compatibility. All observed optional-discount arrays were empty, so they do not
provide a live eligible-discount example.

## Adapter checks and correction

A historical [captured-response replay](../research/protocol/captured-quote-replay-result.json)
passed 40 checks using the real pure Fetch/Quote components in an isolated
network namespace. Single currency quotes retained the response amounts and
balance, coupon eligibility was honored, all five original-price vector entries
kept their positions, and unproved positive/remaining batches remained advisory
without a submission payload. No Client, transport, worker or purchase service
was loaded in that replay.

The separate [synthetic selection checks](../spec/purchase/quote-selection-verification.md)
passed 23 groups and 259 assertions without a real account or service request.
These verify selection/context binding, metadata interpretation and candidate
boundaries; they are not evidence of a real payment.

Response identity handling exposed a production boundary worth correcting:
missing `ep_id` is allowed, but present malformed identities must not be treated
as missing. `Client.purchaseInfo` now rejects invalid or mismatched episode IDs
and malformed comic IDs before normalization. A dedicated decimal conversion
preserves valid 15-digit JSON numbers without Lua's scientific-notation
conversion. The [identity regression](../spec/protocol/purchase-info-identity-result.json)
passed 10 groups and 115 assertions with real Client code and a strict in-memory
transport. The intermediate large-number failure is retained separately.

## Integrated ordinal ranges

The implementation now supports ordinary currency batches through the
platform's ordinal range contract. The authoritative plan permits a
server-supported range; an echoed server ID list is not a prerequisite for
representing that range. The displayed member list remains an intended set
derived from the current catalog, not an atomic server reservation. See
[the strict resolver contract](ordinal-range-contract.md).

The resolver checks the original catalog order and identities, explicit access
states, complete original offer arrays, anchor, whole-comic and remaining
totals, and selected count and price against both basic and scoped responses.
Only explicitly usable offers qualify. An explicit zero limit preserves the
server's remaining-range rule; it cannot be synthesized from an unusable
positive offer. Additional-discount selections remain advisory.

The next authenticated attempt stopped at the session check with business code
`-101`; no quote was requested. After the user replaced the input file, the
[successful observation](../research/protocol/ordinal-range-live-result.json)
made seven business reads and one pinned public-asset read, including four
quotes. The real Fetch/Range/Quote modules then used those captured reads to
construct the positive and remaining ranges without further network requests.
Both returned submittable quotes with fingerprints, matching server amounts
and preserved range limits. The sampled counts were 20 and 123 chapters.
`server_confirmed_ids` remained false and no submission service or actual
purchase endpoint was invoked. The
[launcher record](../research/protocol/ordinal-range-launcher-result.json)
binds the executed module bytes to the integrated candidate; the later Service
index correction has separate synthetic evidence.

The Service persists an unknown ordinal outcome independently of reading
access. If all expected chapters become readable without conclusive submission
evidence, reading/download continuation can proceed while further purchases for
that comic remain paused. A late conclusive response can clear that hold.
Startup rebuilds the pending index; ordinary pending-list reads do not scan the
entire completed purchase history.

The focused evidence is deliberately separated:

| Boundary | Result | Scope |
| --- | --- | --- |
| [Range/Fetch/Quote](../spec/purchase/ordinal-range-result.json) | 15 groups, 240 assertions | Synthetic catalogs and quotes, no service request |
| [Service, protocol and durable restart](../spec/purchase/ordinal-transaction-verification.md) | 11 isolated processes; 489 ordinal assertions | Real quote construction, Service, SQLite and Client serialization with an in-memory Buy transport; no actual network |
| [Native ordinal UI](../spec/ui/ordinal-range.md) | 106 assertions at each of 600x800 and 480x640 | Synthetic quotes and a fake controller; expected-member and uncertain-outcome wording |
| [Local acceptance guard](../spec/local/readonly-guard-results.json) | 123 cases, 209 assertions | Remote fake forwarding; quote/wallet reads allowed, purchase and account writes blocked |

All runtime checks in this revision ran on `test-env`. The existing local WSL
window and interactive profile were not changed or restarted. The next launch
through the acceptance helper installs its updated read-only guard.

## Remaining gates

The observations establish construction of sampled standard-currency ranges,
not actual `BuyEpisode` execution, atomic batch membership, asset consumption or
real payment recovery. Those limitations remain explicit. Synthetic
state-machine and native quote-UI checks are separate evidence and must not be
described as real transaction acceptance.
Physical Scribe installation, memory, touch, suspend/resume and e-ink behavior
also remain separate from desktop and emulation results.

## Integrated development artifact

The final integrated archive contains 96 files and 2,446,099 bytes, with SHA-256
`8891f287f3cc87904589bee378afdfb0b0bc1cdb5257dc6cece79968d18e6530`.
The eight changed Lua files passed remote syntax compilation, and all 27
[package checks](../spec/package/remote-results.json) passed, including the new
range dependency, deterministic output, native artifact integrity and private
data exclusions. The [source binding](../spec/package/source-evidence.json)
maps each focused result to the module or function bytes it actually covers.

The default installation archive is `dist/bilicomics-0.1.0-dev.zip`.
`dist/bilicomics-quote-preview.zip` is retained as a byte-identical alias, and
the preceding reading/preview artifacts are preserved under `dist/history`.
This consolidation does not turn earlier live-reading, ARM or local-startup
results into a complete runtime test of the final archive. Actual purchases and
physical Scribe execution remain outside the recorded acceptance.

## Private data cleanup

After all read-only launchers terminated and the public records were copied,
the explicitly created remote observation directory was removed. The
[cleanup record](../research/protocol/quote-observation-cleanup.json) records 445
files, 120 directories and 34,927,376 bytes removed, including the remote
credential copy, raw captures, private logs and isolated source/profile copies.
The user's original Windows input was not modified. The published records
contain field shapes, counts and comparisons, not raw account data.

The subsequent expired-session and successful ordinal-construction attempts
used a new private directory. Once both launchers had terminated and their
public records were copied, that directory was also removed. Its
[cleanup record](../research/protocol/ordinal-range-cleanup.json) records 225
files, 60 directories and 18,886,666 bytes removed. Both phases together made
eight business reads, including four quote reads, and one public-asset read;
actual purchase requests remained zero. The original Windows input was left
unchanged by the agent.
