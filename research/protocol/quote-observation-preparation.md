# Quote observation preparation

This is the historical preparation record. The [bounded observation plan](quote-observation-plan.md),
[Lua observer](quote-readonly.lua) and [private launcher](run_quote_observation.py)
were prepared for scope clarification and had not been executed at that
stage. The user's restriction then excluded purchase tests, and the earlier
reading-only scope omitted quote and wallet reads. The preparation itself
did not infer permission to perform those reads.

As of 2026-09-13, the user permits all operations except actual purchasing.
Authenticated quote observations, a separately guarded wallet read and
isolated synthetic checks have executed; see the
[non-purchase integration report](../../docs/nonpurchase-integration-report.md).
Standard coin/no-extra-discount positive and remaining ranges are implemented
under the [ordinal-range contract](../../docs/ordinal-range-contract.md), with
[real production construction from authenticated read data](ordinal-range-live-result.json).
The contract retains `server_confirmed_ids=false`; extra discounts remain
advisory. Real `BuyEpisode` HTTP calls and actual purchases remain zero.
Actual charging and physical Scribe acceptance remain unverified. The original
syntax-only preparation below is not the full later verification record.

Independent static review checked the request ticket budget, catalog signing
fields, pre-normalization identity checks, private capture/public-summary
boundary, pinned archive source and process/credential cleanup. Identified
issues were corrected before the final review: optional offers require positive
integral amounts, present malformed identities stop the flow, catalog `m2` is
required, the ZIP is inspected from its already hashed bytes, and cancellation
signals set a flag so process creation cannot lose the child handle.

[Remote syntax preparation](quote-observation-syntax-result.json) passed using
the official KOReader v2026.07.1 LuaJIT compiler in an isolated network namespace
and Python `ast.parse`. During that preparation, the Lua observer, Python
launcher, guard, Client and purchase functions were not executed. No session
input was opened or copied during that stage.
The source snapshot and result are retained at
`/tmp/bili-quote-observation-prepare-ojxIGWeV` on `test-env`.

The initial observer retained its concrete budget when later authorized: one
account from the supplied session file, the first favorite comic and first
locked chapter, at most seven business reads including four quote reads, plus
at most two pinned public WASM resources. Its budget excluded wallet, image
acquisition, order, coupon consumption, rental, recharge and account writes.
The later wallet observation used a separate one-request guard; it did not
widen this original budget. Neither the preparation nor the subsequent
non-purchase observations verify actual payment or asset consumption. The
current ordinal-range evidence and its remaining limits are linked above.
