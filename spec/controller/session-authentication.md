# QR and private-session regression coverage

The two focused suites run only on the authorized remote `test-env` host. They
use synthetic account credentials and isolated private files. No real Bilibili
request, QR login, refresh, purchase, or account mutation occurs.

`qr_authentication_spec.lua` exercises the production Controller, Session,
SessionStorage, SQLite, and PageStore with controlled authentication worker
callbacks. Its checks cover anonymous and invalidated
accounts, waiting/scanned/confirmed transitions, persistent account replacement,
wrong keys, duplicate polls, expired codes, cancellation, suspension, close,
late responses, connectivity guards, save failure, precedence between pending imports and new QR logins, and
synchronous callback completion. This is account-lifecycle evidence, not a real
mobile-app scan or a rendered QR-widget test.

`session_refresh_spec.lua` covers schema 1 compatibility and schema 2 private
persistence, durable uncertain-confirmation markers, refresh metadata, imported expiry, repeated and comma-joined
Set-Cookie fields, Expires dates, Max-Age precedence, domain isolation, deletion,
atomic rejection, and exclusion of credentials from public summaries and Codec
records. Production Client calls use an injected transport to prove that malformed
optional cookie headers cannot erase successful purchase/favorite receipts or
replace original business/authentication errors. Credential comparison ignores
auxiliary cookie rotation. Real POSIX children and pipes carry ordinary Worker
results and private session updates separately; a retryable error with an update
does not enter a raw retry before the parent can adopt the credentials. The
suite also rejects nonboolean private-update markers and records injected
transport requests separately from actual service requests.

`run_session_authentication.py` creates separate XDG directories for each suite,
applies a process-group timeout, and records the executed source hashes. Run it
inside a dedicated `/tmp` source snapshot on `test-env`:

```sh
python3 /tmp/isolated-source/spec/controller/run_session_authentication.py \
  /tmp/bilicomics-native-_duimwe7/lib/koreader \
  /tmp/isolated-source /tmp/isolated-source/new-results
```

The public records are `qr-authentication-result.json`,
`../protocol/session-refresh-result.json`, and
`session-authentication-summary.json`. The summary binds results to the exact
source files exercised. Changes after that snapshot need their own verification.
