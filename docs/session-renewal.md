# QR sign-in and renewable sessions

Date: 2026-09-13. This development change adds native QR sign-in and account-session maintenance. It does not promise a fixed or unlimited credential lifetime. Server revocation, incomplete renewal transactions, or an expired session after a long offline period can still require a new sign-in.

## Sign-in

Account and settings exposes **Sign in with QR code**. The official QR URL is rendered by KOReader's existing QRWidget, without a remote QR-image service. Polling starts only after the previous request completes and waits three seconds between requests. The server determines expiry; no fixed countdown is invented. Closing the dialog, starting another sign-in/import, suspending, or switching accounts retires pending callbacks. A confirmed response must include session and CSRF cookies plus a renewal credential, and the official navigation endpoint must verify the identity before a private save and account switch.

The previous account stays selected until successful validation and storage. Existing header, browser JSON, and Netscape imports remain compatible. A plain Cookie header has no independent renewal token; importing it alone cannot enable automatic renewal. A structured JSON export may carry `refresh_token` beside `cookies`. The private `session.dat` format now uses schema 2 and still reads schema 1.

## Maintenance and transaction boundaries

`SessionManager` owns maintenance for one account. The first online business request after opening or resuming checks a renewable session; subsequent requests share one check and use a six-hour client-side interval. That interval is a scheduling choice, not a server TTL. Offline reading and local account getters do not trigger maintenance.

`SessionRunner` wraps all account jobs, including direct image downloads. It waits for maintenance and supplies the latest credentials when a queued worker actually starts. An authentication failure may trigger one forced maintenance and one replay of a read operation. A purchase or favorite mutation that has already been sent is never replayed. Auxiliary cookies do not count as a new authentication generation.

The rotation sequence is: read `cookieInfo`; persist an uncertainty marker before a needed rotation; acquire and verify replacement cookies; atomically save the new cookies, new refresh token, and pending old token; then confirm the old token. Only a successful confirmation permits clearing the pending token. A response lost after possible rotation leaves automatic rotation blocked across restart. A confirmation attempted without a conclusive reply likewise cannot be automatically repeated forever: the saved new session remains usable, while another rotation requires a fresh sign-in. In-memory candidates survive a storage failure for a later save attempt; they never authorize confirmation before durable persistence.

Normal API Set-Cookie responses are parsed with origin/domain restrictions and returned through a private worker-pipe field. They do not enter business records, diagnostics, or purchase journals. Late responses cannot replace newer credentials. Cookie persistence errors cannot erase a received purchase success or turn it into a not-transmitted transaction. Pre-dispatch maintenance failures explicitly describe the business operation as not transmitted.

## Evidence and limits

[The protocol research](auth-protocol.md) records first-party QR endpoints, response states, the refresh initiation path, and an RSA-OAEP implementation matching the official WASM. The authenticated refresh iframe was not available anonymously. Its refresh form, challenge element, and confirmation contract therefore remain implementation assumptions from the historical protocol, awaiting a real-account acceptance check.

Remote synthetic checks cover the protocol, official cryptographic vector, QR account lifecycle, private storage, cookie parsing, real subprocess pipes, maintenance concurrency, failure recovery, and native QR widgets in Chinese and English at 480x640 and 600x800. The integrated runner records exact production source hashes and isolates every suite from the network:

```powershell
ssh test-env 'python3 /tmp/isolated-source/spec/controller/run_auth_regression.py /tmp/bilicomics-native-_duimwe7/lib/koreader /tmp/isolated-source /tmp/auth-regression-output'
```

The final integrated run passed all ten suite entries on official KOReader v2026.07.1. [The complete report](../spec/controller/authentication-regression.json) binds each production Lua file to its executed SHA-256. The old client harness additionally requires Pillow for synthetic image fixtures; it was supplied in an isolated remote dependency directory, not added as a plugin dependency.

| Coverage | Passing checks |
| --- | ---: |
| Authentication protocol / official RSA vector and boundaries | 33 / 11 groups |
| Session maintenance and concurrent worker behavior | 70 assertions |
| QR Controller lifecycle | 13 groups, 50 assertions |
| Session storage, cookies, mutation receipts and real worker pipes | 18 groups, 97 assertions |
| Existing private-session storage / file importer | 28 / 42 assertions |
| Native QR UI: Chinese and English, two screen sizes each | 50 assertions per configuration, 200 total |
| Existing client protocol contract | 12 groups |
| Raw runner / storage budget / worker extensions | 22 / 10 / 16 groups |

The [package verification](../spec/package/authentication-results.json) passed 27 checks, including identical repeated archive bytes, manifests, native artifacts, dependency inclusion and private-data exclusions. The development candidate is `dist/bilicomics-0.1.0-dev-auth.zip`, with 101 files and SHA-256 `0e64139984ff1203289775f009d2c3465a63a15bb23da6f41a55b687b089ad60`. The verification archive used the shorter `bilicomics-0.1.0-dev.zip` filename; the delivered authentication candidate contains those exact archive bytes. Its filename-specific manifest is adjacent in `dist`.

No synthetic result proves an actual mobile-app scan, a live authenticated refresh/confirmation, long-duration session retention, or physical Kindle Scribe acceptance. Those remain explicit acceptance steps. Real purchases are unnecessary for authentication acceptance and were not performed.

Two older broad controller harnesses were also attempted and compared with unchanged commit `06e794b`: `controller_spec.lua` already fails at its automatic missing-source recovery expectation, and `authentication_spec.lua` already fails at its old quote fixture. Both fail at the same locations before and after this change. The focused authentication regression exercises the current interfaces; the historical broad harness failures have not been relabeled as passes.
