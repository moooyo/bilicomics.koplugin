# QR recharge API investigation

Research date: 2026-09-15.

## Implementation and verification status

The plugin now implements the recharge protocol, service, controller, and UI. Current first-party web assets show one manga-coin payment QR code that supports scanning with either WeChat or Alipay. The implementation follows that observed web-client flow. No real recharge order or payment has been tested, and this investigation does not establish an externally supported API contract.

The following checks passed in the isolated environment accessed through `ssh test-env`. Each linked report records its source scope and synthetic execution evidence.

| Area | Implementation | Verification |
| --- | --- | --- |
| Protocol | Implemented | [12 tests passed](../design/recharge-preview/evidence/protocol.json) |
| Recharge service | Implemented | [42 scenarios and 196 assertions passed](../design/recharge-preview/evidence/service.json) |
| Controller integration | Implemented | [13 scenarios and 84 assertions passed](../design/recharge-preview/evidence/controller.json) |
| Native worker runner | Implemented | [28 tests passed](../design/recharge-preview/evidence/runner.json), including six recharge lifecycle and real-pipe cases |
| Existing purchase, session, and QR behavior | Retained | [42 groups and 219 assertions passed](../design/recharge-preview/evidence/existing-regressions.json) |
| Recharge UI | Implemented | 190 assertions and 30 native captures at each of two sizes; [UI evidence](../design/recharge-preview/evidence/ui.json) |
| Worker dispatch | Implemented | 107 assertions passed, including 20 recharge boundaries; [worker evidence](../design/recharge-preview/evidence/worker.json) |
| Real account order creation and payment | Not exercised | Not tested |

The protocol checks include a definitive pre-transmission TLS failure. The runner checks preserve complete recharge receipts across close and timeout, recover buffered receipts with a bounded pipe drain, reject invalid frame identities, and prevent automatic mutation replay. Native captures cover 600 by 800 and 480 by 640 screens. QR images measure 222 and 148 pixels respectively, with four-module white quiet zones verified from the framebuffer. Oversized payment URLs are never silently truncated into a different QR payload. These synthetic checks do not establish real payment behavior.

The current [official recharge entry](https://manga.bilibili.com/account-center/?show_recharge=true) returned its application shell. That shell references the [account-center entry bundle](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/account-center.3fb118319d.js), whose account-information route loads [the recharge implementation](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/742.e8579b79c1.js).

## Observed coin-recharge contract

| Purpose | Observed request |
| --- | --- |
| Recharge configuration | `POST https://manga.bilibili.com/twirp/pay.v1.Pay/GetPayConfig` |
| Create a QR recharge order | `POST https://manga.bilibili.com/twirp/pay.v1.Pay/CreateOrder` with `pay_type="qr"` and integer-cent `pay_amount` |
| Recharge records | `POST https://manga.bilibili.com/twirp/user.v1.User/GetPayOrders` |

An anonymous `GetPayConfig` request with body `{}` was sent through `ssh test-env` and returned HTTP 401. No credentials were supplied. This establishes the anonymous response only; it does not establish an authenticated configuration response or accepted live order amounts. The web facade itself sets the URL and response-model type without an explicit business-data field.

The configuration model `DRno._N` maps raw `data.pay_amount_ranges` to an array of recharge options. Its other raw fields are `bonus_reason`, `act_send_type`, `first_pay_send_type`, and `show_text`. Each option contains `pay_amount`, `gold_amount`, `first_bonus_amount`, `first_coupon_amount`, `bonus_coupon_amount`, `bonus_gold_amount`, `break_ice_coupon_amount`, `first_txt`, `activity_txt`, `gold_set_amount`, and `free_gold_set_amount`.

Configuration `pay_amount` is denominated in yuan: the web UI displays it directly with a currency prefix. The coin panel multiplies the selected yuan amount by 100 for `CreateOrder.pay_amount`, which the plugin sends as integer cents. The unit of history-item `pay_amount` has not been established and must not be inferred from either of those contracts.

Names and a watcher for `freeChargeRMB` remain in the current source, but the investigation did not establish a currently rendered custom-amount input or its `min`, `max`, or `step` contract. The observed configuration model contains no explicit custom-amount policy. Consequently, the plugin accepts manually entered amounts only when they match a current official preset; these source names do not authorize arbitrary custom amounts.

## Raw response models and completion evidence

The raw-to-model mapping is statically confirmed in the account-center bundle: `/QaS.p` maps raw `pay_params:String` to typed `payParams`. The coin-recharge wrapper parses that JSON string for `codeUrl` and extracts `orderId` directly from the original JSON text without relying on the parsed numeric value. `DRno.eS` is the resulting display model containing `codeUrl` and `orderId`. A separate generic order model, `DRno.Ql`, maps raw `pay_params:String` and `order_id:String`; it is not the response-model selection used by this QR wrapper.

`GetPayOrders` returns its order array directly in the response body's `data`; there is no additional `orders` or `list` container in the observed model path. `DRno.K4` maps `id` as a string and includes `pay_amount`, `product_amount`, `ctime`, `pay_channel`, `pay_channel_name`, `extra_product_amount`, `activity`, and `free_gold`. It has no order-status field. The HTTP wrapper's `status` is an HTTP status, not an order-payment status. The history UI describes `free_gold` as a manga-coin deduction-card bonus.

The web panel renders `codeUrl` as a QR code, polls recharge history every two seconds, and matches the exact current order ID. Its polling request uses `page_num=1`, `page_size=2`, the current year, and `order_month=0`. A matching history ID triggers success and a wallet refresh without a separate order-status filter. The facade's old default year of 2019 is not the year used by this polling call. [Source: current account-information chunk](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/742.e8579b79c1.js).

The [shared payment SDK](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/bili.9409128c39.js) separately exposes `getQrPayUrl`: it calls `/payplatform/qrcode/payQrCode` on `pay.bilibili.com`, constructs a cashier URL from `payToken`, `codeType`, and `decode`, and returns an expiry time. This generic SDK path and its expiry must not be substituted automatically for the coin panel's observed `pay_type="qr"` contract. Other coupon, card, and B-coin branches are separate flows.

## Implemented plugin safeguards

- The protocol preserves exact decimal order IDs as strings and accepts QR destinations only under the strict `https://pay.bilibili.com/` URL boundary.
- The selected option's fingerprint is checked against freshly loaded official configuration before creation. The confirmation identifies the receiving account and amount; a manually entered amount must resolve to an official preset.
- Order creation requires an explicit user action and has no automatic create retry. Creation and history polling remain separate so an uncertain response cannot silently produce another order.
- A complete validated recharge worker receipt takes precedence over later timeout or teardown. Recovery drains at most one permitted pipe frame and retains task/attempt identity checks.
- Completion requires the exact order ID in recharge history. A wallet balance change alone does not prove that a particular order succeeded, and the unknown history-amount unit is not used to infer payment completion.
- The returned official cashier URL is displayed with `QRWidget`; the same QR supports the web flow's advertised WeChat and Alipay scanning paths. Live channel availability remains untested.
- No expiry is inferred from elapsed time, an absent history match, or the separate SDK flow. Closing the QR view does not cancel an outstanding order.

Authenticated recharge behavior, accepted live amounts, server expiry, payment-channel availability, and successful crediting remain unverified in a real payment flow.

## Evidence handling

Public HTML and JavaScript were downloaded through `ssh test-env`. The obfuscated account chunk's string table was statically decoded, and response models were read from the account-center source; no third-party bundle was executed. The only documented live API probe was the anonymous `GetPayConfig` request returning HTTP 401. No credentials or private account data were read, and no real order or payment was created. The linked verification reports use synthetic records and injected transports, separate from that anonymous probe.

Public-source SHA-256 values:

- `account-center.3fb118319d.js`: `7773e748bc38edfbeb142831a02dda55e3a470c9af24b18c56f3c2156acd6589`
- `742.e8579b79c1.js`: `c5543a4ade0aa11fea348ae9332eff893c573911a1e6a1bb350720a8fc4d2df3`
- `bili.9409128c39.js`: `8202851c77a8e8a58dab2fc2529542c09b6b6c296e26fe78390ee1206aae6908`

These are the saved UTF-8 source-text hashes from this investigation. The remote research directory is `/var/tmp/bilicomics-recharge-research-20260915`.

Additional static model and UI fragments in that directory:

| Fragment | Evidence |
| --- | --- |
| `model-drno.txt` | Configuration, history, generic order, and QR display models; `account.js` character offset 52698 |
| `model-raw-pay-response.txt` | `/QaS.p` maps `pay_params` to `payParams`; `account.js` character offset 2399 |
| `ui-config-amount-units.txt` | Configuration amounts displayed directly as yuan |
| `ui-config-recharge-load.txt` | Configuration loading call chain |
| `ui-config-award-label.txt` | Configuration reward labels |
| `history-order-success-filter.txt` | Exact order-ID match establishes the web panel's success state |
| `http-response-list-model-map.txt` | Raw `data` array mapping and HTTP-status distinction |

[Structured API evidence](recharge-api-evidence.json) records the extracted contract, implementation safeguards, verification artifacts, and remaining limits. The raw response mapping is source-confirmed; authenticated wire responses and real payment behavior remain untested.
