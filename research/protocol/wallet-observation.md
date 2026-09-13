# Single read-only wallet observation

Date: 2026-09-13. The separately authorized observation completed on `ssh
test-env` using the official KOReader v2026.07.1 runtime and the supplied
production preview source. The source snapshot contained 96 files; their
SHA256 values, plus the observer and launcher hashes, are recorded in
[wallet-observation-result.json](wallet-observation-result.json).

Exactly one request reached the unchanged production Transport through
`Client.wallet`:

```text
POST https://manga.bilibili.com/twirp/user.v1.User/GetWallet?device=pc&platform=web&nov=27&a=810
Body: {}
```

The observer globally intercepts Transport requests, matches the complete URL,
method and literal body, and consumes a persistent single-use allowance before
forwarding to the captured production method. All other requests and any second
attempt are rejected. Peer/hostname TLS verification and disabled redirects
remain production behavior. There was no navigation/session-validation request,
image or public-asset request, automatic retry, account mutation or purchase.

| Field | Wallet shape | Existing basic-record shape | Comparison |
| --- | --- | --- | --- |
| remain_gold | Present, number | Present, number | Evaluated; equal |
| remain_coupon | Present, number | Present, number | Evaluated; equal |

The comparison uses only these two fields from the previously captured
`run2/basic-decoded-private.json`. Missing or differently typed fields cannot
become zero by default and cannot produce a false equality. No amount, account
identifier, header, Cookie or raw response is included in the public result.
This establishes wallet field shapes and agreement at observation time, not a
purchase or asset-consumption result.

The launcher uses a minimal environment, private HOME/XDG directories and
`LUA_CPATH=./?.so;./libs/?.so`, with the official runtime as its working directory.
Its single Lua child terminated and was reaped. The temporary credential copy
was removed in the final cleanup path; the approved original credential and the
comparison record retained their file identity and metadata. The source snapshot
also remained unchanged.

Private raw/normalized responses and process logs were recorded under
`/tmp/bili-quote-live-J7fPZ05L/wallet-readonly`, then removed by the root's
[coordinated cleanup](quote-observation-cleanup.json) after analysis.
The public result reports `request_count=1`, `blocked_requests=0`,
`purchase_submitted=false`, `real_purchases=false`,
`child_terminal_and_reaped=true` and `credential_copy_removed=true`.

The independent scripts are [wallet-observation.lua](wallet-observation.lua)
and [run_wallet_observation.py](run_wallet_observation.py). They were remotely
syntax-checked before this single execution. They do not modify production or
the existing quote observer.
