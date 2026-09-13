# QR login and persisted-session site initialization

The QR login path now initializes the official manga site's device context before
validating and publishing the confirmed session. This addresses the missing
`buvid3` path recorded in `live-ui-reading-2026-09-13.md`; the implementation is
separate from category browsing's temporary anonymous guest.

`protocol/site_context.lua` uses only the exact anonymous
`GET https://manga.bilibili.com/ductape/buvid` request. It sends no login Cookie,
Authorization header, CSRF credential or request body. It selects only valid
`buvid3` Set-Cookie entries, then applies the existing Session domain, path and
lifetime checks to a scratch session. Other cookies from that response cannot
replace login cookies, account identity, renewal tokens or renewal markers.
Conflicting values, invalid domains, non-root paths and expired values fail.
An existing device cookie that is valid for the manga host is reused without a
network request.

`Auth:pollQR()` first builds a fresh candidate from the confirmed passport
response. It ensures the manga device context, validates account identity with
nav, and confirms that nav retained the device cookie. Only then can it return
`status = "confirmed"`. Initialization or validation failure leaves the prior
Auth session unchanged and returns no publishable candidate. Retrying can start
a fresh QR flow; no incomplete login is saved by this path.

Previously saved verified sessions use `Auth:ensureSiteContext()` through the
existing SessionManager worker lifecycle. Its successful-ready gate also covers
static imported sessions, a recent maintenance check, and renewal-blocked or
confirmation-blocked sessions. Normal renewal and confirmation retain their
original ordering and durable markers; device initialization does not run between
a successful credential-rotation response and its durable save.

Device recovery remains single-flight. SessionManager validates that the returned
session differs only in `buvid3` and its domain, saves it through the existing
account-scoped callback, and only then releases queued business requests. A failed
save retains its candidate for a storage-only retry. Forced maintenance requested
during site recovery or its save retries still runs afterward. Site-only saves do
not update the renewal-check timestamp or increment the credential generation.
Cancellation, suspension and account changes continue to invalidate obsolete
worker callbacks through the existing active/epoch/source checks.

The Worker and desktop read-only guard admit the new `ensureSiteContext` auth
method. Category browsing's temporary device cookie and cookie-free homepage
recommendations remain unchanged.

## Verification scope

All checks ran through `ssh test-env` in isolated network namespaces with synthetic
credentials and controlled responses. No real account, QR scan, credential
rotation or confirmation operation was performed by this verification.

- Site protocol: 11 groups and 86 assertions, including QR publication order,
  existing and sibling-scoped device cookies, initialization failure and retry,
  nav failure or device removal, Set-Cookie boundaries, credential preservation,
  saved-session recovery and actual Worker dispatch.
- Existing Auth protocol: all 33 groups passed.
- New SessionManager lifecycle: all 86 assertions passed, including single-flight,
  save retry, forced-maintenance continuation, cancellation and account isolation.
- Existing SessionManager lifecycle: all 70 assertions passed.
- Desktop read-only guard: 465 cases and 916 assertions passed.
- Affected default-fixture regressions: Controller 69, authentication 28 and
  session storage 28 assertions passed; only their already-usable synthetic
  session fixtures gained a device cookie, with original assertions retained.

`spec/protocol/site-context-verification.json` records the source identities and
focused evidence. The original missing-device live report is historical evidence,
not proof of a new real QR acceptance run. Fresh user-confirmed QR and reading
acceptance is coordinated separately by the root task. All real session rotation,
actual purchase and physical Scribe acceptance remain deferred for this phase;
normal production renewal capability is not disabled.
