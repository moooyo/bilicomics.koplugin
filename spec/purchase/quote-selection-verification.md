# Quote Selection Verification

On 2026-09-13, the separately authorized non-spending synthetic check passed
23 focused groups and 259 assertions. The test ran through `ssh test-env` in a
distinct `unshare -n` network namespace with the official KOReader `v2026.07.1`
LuaJIT runtime. The tested 95-file quote preview has SHA-256
`38a01da12c74271a631af57e9ac45c9e90b48472e390bd4aae5ded42e37f8383`.

The [recorded result](quote-selection-result.json) includes archive, module,
runtime and harness hashes. All staged production bytes remained unchanged.
There were 66 fake Client calls, zero `BuyEpisode` calls and zero attempts to
load forbidden account, transport or submission modules. Real Client and
transport modules remained unloaded; the harness does not present a static
zero as a measured transport-request count. No user session or private profile
was read.

Coverage includes normalization and copying of selections, original offer
positions, distinct basic/scoped responses, complete price vectors, exact
calculated-price keys, missing evidence, scoped asset identities, free-gold
count/credit separation, context mismatch rejection, and coupon-ID display
copying. It also checks ordinary single/coupon quote construction and the
fingerprint changes caused by different terms. Every batch, zero-limit and
extra-discount candidate remains non-submittable; the harness never supplies
an exact-scope proof and never calls a submission service. It does not exercise
a future adapter that could supply such a proof.

This is module behavior evidence with controlled responses. It does not verify
live server fields, authoritative batch membership, asset consumption, an
actual purchase, Controller confirmation lifecycle, or rendered purchase UI.
The older broad purchase suites were not run as part of this focused check.

To reproduce with an approved remote environment, upload the two test files
and the preview ZIP/manifest to a new isolated directory, then run:

```powershell
ssh test-env 'python3 /tmp/quote-selection/run_quote_selection.py --runtime /tmp/bilicomics-native-_duimwe7/lib/koreader --archive /tmp/quote-selection/bilicomics-quote-preview.zip --manifest /tmp/quote-selection/bilicomics-quote-preview.manifest.json --output /tmp/quote-selection/result'
```

The output directory must not exist. The driver validates and extracts the ZIP
itself, uses isolated XDG directories and a minimal environment, and invokes
only `quote_selection_spec.lua`. The Lua harness rejects real Client,
transport, session, Worker and purchase-service modules before loading the
target modules; its fake Client hard-rejects `BuyEpisode`.
