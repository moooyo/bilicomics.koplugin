# Authentication protocol evidence

Reviewed on 2026-09-13. Protocol research and verification ran through
`ssh test-env`. No existing account credentials were read or used. No account
login, refresh, confirmation, or logout write request was made. The official
cryptographic component was executed offline with synthetic inputs and an
intercepted fetch that could only return its previously downloaded WASM file.

## Official sources

- [MiniLogin SDK](https://s1.hdslb.com/bfs/seed/jinkela/short/mini-login-v2/miniLogin.umd.min.js)
- [Passport login component](https://s1.hdslb.com/bfs/static/2233-monorepo/passport/static/js/async/560.4903185b.js)
- [Current shared page header](https://s1.hdslb.com/bfs/seed/laputa-header/bili-header.umd.js)
- [Login token handoff helper](https://s1.hdslb.com/bfs/static/jinkela/long/wasm/correspond.js)
- [RSA WASM wrapper](https://s1.hdslb.com/bfs/static/jinkela/long/wasm/wasm_ras_umd.js)
- [RSA WASM binary](https://s1.hdslb.com/bfs/static/jinkela/long/wasm/wasm_rsa_encrypt_bg.wasm)

These are implementation evidence, not a public stability guarantee. Asset URLs
without content hashes can change. The downloaded RSA binary had SHA-256
`cf63e0fe9e81fff73443866089dd703551eb65f1bd2ce07fc5c182c5205f4e3c`.

## Confirmed QR login contract

The API origin is `https://passport.bilibili.com`.

| Operation | Method and path | Parameters |
| --- | --- | --- |
| Generate | `GET /x/passport-login/web/qrcode/generate` | `source`; MiniLogin also supplies `go_url` |
| Poll | `GET /x/passport-login/web/qrcode/poll` | `qrcode_key`, `source` |

The standalone Passport component defaults `source` to `main_web`. MiniLogin
uses its caller-provided origin. Anonymous generation and polling also succeeded
without `source`, but using one consistent explicit source follows the browser
implementation more closely.

Generation returned an envelope with `code: 0`, `message: "OK"`, `ttl: 1`, and
`data` containing `url` and `qrcode_key`. The observed key had 32 characters.
The QR URL pointed to
`https://account.bilibili.com/h5/account-h5/auth/scan-web` with query parameters.
Use the returned URL; do not construct a replacement login URL.

Poll status is nested inside `data.code`, separately from the envelope code:

| `data.code` | Meaning | Official browser behavior |
| --- | --- | --- |
| `86101` | Waiting for a scan | Continue polling |
| `86090` | Scanned; waiting for phone confirmation | Continue polling |
| `86038` | QR code expired | Stop polling and offer a new QR code |
| `0` | Login completed | Stop polling and process the login result |

The browser schedules polls every 2 seconds. On success it consumes
`data.refresh_token`, `data.timestamp`, and `data.url`. This success branch is
confirmed from official source, but a real successful login response was not
obtained during this review. In particular, successful `Set-Cookie` contents
and cross-domain completion were not verified with an account.

Anonymous pending responses contained empty `url` and `refresh_token`, a zero
`timestamp`, and `data.code: 86101`. The same QR was still pending after 102
seconds and expired when checked after 221 seconds. This bounds one observed
lifetime; it does not establish an exact 180-second contract. Respect the server
status. Neither the envelope `ttl: 1` nor the polling interval establishes a
Cookie lifetime.

## Confirmed refresh entry and separate credential

The shared header defines
`GET https://passport.bilibili.com/x/passport-login/web/cookie/info` with CSRF
query injection enabled. On mounting, it checks this endpoint after a successful
login-state response when the page enables `tokenSupport` and WASM is supported.
Only `data.refresh: true` triggers the next step. The header takes
`data.timestamp`, encrypts `refresh_<timestamp>`, and loads
`https://www.bilibili.com/correspond/1/<ciphertext>` in a hidden iframe.

An anonymous `cookie/info` request returned envelope `code: -101` and an
unauthenticated-account message. A successful authenticated response was not
obtained. The observed browser source does not establish a fixed Cookie TTL or
a daily check interval.

Login code receives `refresh_token` independently of browser Cookies. The
official handoff helper passes it as `longToken` to a main-site iframe through
`postMessage`. Therefore a copied Cookie request header does not contain the
whole browser renewal state. The current sources reviewed here do not establish
the iframe's local-storage key; `ac_time_value` remains unconfirmed in this
review.

## Confirmed correspondence encryption

The public key modulus was extracted from the official WASM. Its public
exponent is 65537. An offline official-WASM vector matched an independent
Python implementation using all of these parameters:

- RSA modulus length: 1024 bits.
- Padding: RSA-OAEP.
- Message digest: SHA-256.
- MGF: MGF1 with SHA-256.
- OAEP label: empty bytes.
- OAEP seed: 32 cryptographically random bytes per operation.
- Message: UTF-8 bytes of `refresh_` followed by the server-provided timestamp.
- Result: 128 ciphertext bytes encoded as 256 lowercase hexadecimal characters.

The browser wrapper accepts the message as hexadecimal text; that is its input
encoding, not an additional application-level hash or a different plaintext.

```pem
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDLgd2OAkcGVtoE3ThUREbio0Eg
Uc/prcajMKXvkCKFCWhJYJcLkcM2DKKcSeFpD/j6Boy538YXnR6VhcuUJOhH2x71
nzPjfdTcqMz7djHum0qSZA0AyCBDABUqCrfNgCiJ00Ra7GmRj+YCK1NJEuewlb40
JNrRuoEUXpabUzGB8QIDAQAB
-----END PUBLIC KEY-----
```

The following deterministic vector is for tests only. Production encryption
must never reuse this seed.

```text
message = refresh_1700000000000
seed = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
ciphertext = ba7125952a10520b948f6f64ab5a24ddc09b9cfa0c5590e404ec24c5c42e6c098c30d27d6c023d5438f3955eb3cc7411a1994f03ec9175d3031958f42d20d0f123bbd5a4ad35b72fb2dbf7aefbff69f5c3dde0349c31254345db8b385cb7285a6fb9b4d070f4f523545aea4a11fd1c4bccfb468ae5116545deb070ca4f24a568
```

## Refresh integration that still needs authenticated verification

Anonymous requests to correctly encrypted correspondence paths returned HTTP
404. Neither a refresh iframe body nor its internal script was obtained.
This is an access boundary, not evidence that the verified RSA parameters are
incorrect. It does not prove exactly which additional server conditions apply.

The implementation's remaining flow follows the historical protocol contract:

1. Extract `refresh_csrf` from the correspondence response element `div#1-name`.
2. POST `/x/passport-login/web/cookie/refresh` with `csrf`, `refresh_csrf`,
   `source=main_web`, and the previous `refresh_token`.
3. Retain the replacement Cookies and returned `refresh_token` together.
4. POST `/x/passport-login/web/confirm/refresh` with the new `bili_jct` as `csrf`
   and the previous refresh token as `refresh_token`.

The iframe selector, these POST parameter contracts, successful response
shapes, confirmation order, and exact old-session invalidation semantics were
not confirmed from a current official iframe or successful account response in
this review. Synthetic tests verify the implemented state machine, persistence,
and failure handling; they do not constitute a real renewal verification.

An authenticated integration run must establish successful QR completion,
Cookie collection, renewal, and confirmation before claiming the whole flow
works against the live service. Preserve recoverable credentials when a
network, parsing, persistence, or confirmation step fails. In particular, do
not describe one exported Cookie becoming unauthenticated the next day as proof
of a one-day TTL or proof that browser renewal invalidated it.
