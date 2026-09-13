# Bounded live authentication acceptance

The finishing revision has passed a [fresh QR login](finishing-live-login-results.json)
and [independent restart](finishing-live-restart-results.json), including official
site initialization, durable saving and the automatic bookshelf. See
[the complete acceptance](../../docs/finishing-acceptance.md) for the following
real reading/download/offline run and its input handoff evidence.

Run this harness only through `ssh test-env`. Local execution is not authorized.
Preparing the harness does not generate a QR code or access an account. Start a
live attempt only after the operator is ready to scan and confirm in the official
Bilibili mobile app. Every attempt uses a fresh private directory; the harness
does not import an existing session or modify a reader installation.

The current driver loads the production main entry, constructs the registered
plugin, opens Bookshelf through its real menu callback, and opens Account through
the same menu item's account callback. It invokes the native account QR button,
then uses the real Controller, Runner, Worker, QRLogin/QRWidget, SessionManager
and SessionStorage. It retains production connectivity and TLS behavior.
After phone confirmation it returns through the production Bookshelf entry,
waits for automatic favorites/history synchronization and visible cover workers,
and records their outcomes. No synthetic account or response enters a live run.
This is native callback execution, not physical input or device acceptance.
Only the anonymous QR dialog is captured; no authenticated screen is exported.

The [isolated scope regression](live-harness-scope-results.json) checks the actual
Auth/Client request constructors and strict transport/submission decisions with
no real network access. The [native rehearsal](live-authentication-rehearsal-results.json)
records its own earlier source/harness hashes and the complete menu-to-QR error
path; later guard changes have separate scope evidence. These checks do not
represent a real phone confirmation on the new implementation.

## Preparation and offline rehearsal

```powershell
ssh test-env 'python3 /tmp/plugin-source/spec/integration/run_live_authentication.py prepare --runtime /tmp/bilicomics-native-_duimwe7/lib/koreader --source /tmp/plugin-source --work /tmp/auth-prepared'
```

Preparation freezes production files, the two harness files and selected runtime
hashes, compiles Python and Lua remotely, and writes `preparation.json`. Use a
fresh work directory for an offline rehearsal:

```powershell
ssh test-env 'python3 /tmp/plugin-source/spec/integration/run_live_authentication.py prepare --runtime /tmp/bilicomics-native-_duimwe7/lib/koreader --source /tmp/plugin-source --work /tmp/auth-rehearsal'
ssh test-env 'python3 /tmp/auth-rehearsal/spec/integration/run_live_authentication.py rehearse --work /tmp/auth-rehearsal --timeout 30'
ssh test-env 'python3 /tmp/auth-rehearsal/spec/integration/run_live_authentication.py status --work /tmp/auth-rehearsal'
```

Rehearsal runs the native controller and QR generation worker in an isolated
network namespace. The transport guard rejects the generation request before
transmission, and the native error state must terminate cleanly. This checks
bootstrap, the real worker boundary, rejection, supervision and shutdown. It does
not test real QR rendering, login, cookies or renewal. A rehearsal directory is
not reusable for a live attempt; prepare a new directory.

## QR login, durable save, and restart

```powershell
ssh test-env 'python3 /tmp/auth-prepared/spec/integration/run_live_authentication.py start --work /tmp/auth-prepared --execute-live-auth --timeout 180'
ssh test-env 'python3 /tmp/auth-prepared/spec/integration/run_live_authentication.py status --work /tmp/auth-prepared'
```

`start` returns promptly while a supervisor owns the polling process. `status`
checks the recorded process identity against `/proc` and, while the native code
is visible, returns the private `qr_path`. Retrieve only that image for the
operator. Treat the temporary image as a login credential; do not commit it,
publish it, retain it after the attempt, or copy the private directory into a
report. The native QRLogin controls its three-second polling cadence. There is
no automatic regeneration, and the launcher limits the entire phase to at most
300 seconds. The screenshot is removed on success, failure, cancellation or
timeout. The caller must remove any displayed local copy too.

Successful phone confirmation must pass production site initialization, identity
validation, a durable session save, and automatic Bookshelf synchronization.
The controller closes before `login-results.json` can pass. Cover success and
failure counts are recorded separately, so a settled fallback is not reported
as a downloaded cover. The private `session-input-path.json` records only the
production SessionStorage path for the later complete-reading launcher; that
path record must not be copied into public evidence.
The session remains only under the isolated private data directory in a 0600
file, ready for this separate process:

```powershell
ssh test-env 'python3 /tmp/auth-prepared/spec/integration/run_live_authentication.py restart --work /tmp/auth-prepared --execute-live-auth --timeout 180'
ssh test-env 'python3 /tmp/auth-prepared/spec/integration/run_live_authentication.py status --work /tmp/auth-prepared'
```

The new Runtime must load the saved session, then its production SessionManager
runs `cookieInfo` and its normal maintenance path. No force flag, synthetic
timestamp, refresh-token substitution or server-result override is used. If the
service reports `refresh=false`, only identity validation and durable check-state
save are expected: renewal and confirmation remain unverified. It then opens
the Bookshelf and verifies the persisted library counts. A fresh cache need not
cause another library request. If the service reports `refresh=true`, the
harness records code `24`, `deferred=true` and `passed=false`, then stops before
forwarding that result to SessionManager. Real credential rotation remains
deferred: challenge, refresh and confirmation HTTP requests are always denied.
The no-refresh `refreshSession` method is admitted only with the exact previously
observed `refresh=false` information; its method name is not evidence of rotation.
Each prepared directory allows one restart
attempt. A new acceptance run requires a fresh QR login and work directory.

## Cancellation, containment, and evidence

```powershell
ssh test-env 'python3 /tmp/auth-prepared/spec/integration/run_live_authentication.py stop --work /tmp/auth-prepared'
```

The supervisor requests native shutdown, then bounds cleanup with TERM/KILL on
pidfds for the owned native session and adopted children. PID start times and
session IDs prevent a stale supervisor record from targeting a reused PID.
Results report whether every owned child stopped. Credentials remain private
after a cancelled post-login restart so uncertain renewal state is not lost.
After collecting sanitized reports, remove the entire explicitly named remote
work directory when it is no longer needed. No account logout request is sent.

The Runner guard admits bounded authentication maintenance, favorites/history
reads and declared visible cover jobs. The transport guard adds only the exact
anonymous `GET https://manga.bilibili.com/ductape/buvid`, production library
request bodies and headers, and the exact cover URL/output path observed from
native rendering. Library reads keep the production 50-item pages and 200-page
maximum. QR generation is limited to one attempt and polling to 100 jobs;
maintenance and each library class are limited to two jobs per phase, covers
to 24. Purchases, quotes, wallet, catalog, credential rotation and unrelated
account operations remain rejected. Raw subprocess output is discarded, and the harness never writes
credentials, account identity, QR URL/key, request bodies or response bodies to
logs or public evidence. `private/config.json` and process controls are private;
the public JSON contains only fixed codes, booleans, counts, numeric service
codes, and code hashes. Never include the private directory in Git evidence.

Status codes: `1` prepared; `10` starting; `11` waiting for scan; `12` awaiting
phone confirmation; `20` login saved; `21` restart checked without required
renewal; `23` offline rehearsal passed; `24` server-required rotation deferred;
`40` authentication request failed; `41` QR expired; `42` cancelled;
`49` harness/precondition failure. Always inspect `passed` and cleanup booleans;
the status code alone is not a completion claim.

No live execution evidence is established merely by adding or preparing this
harness. The historical [real login](stabilization-auth-login-results.json) and
[independent restart](stabilization-auth-restart-results.json) passed on the
earlier stabilization production tree. They predate the current main-menu,
site-initialization and automatic synchronization coverage. The server returned refresh=false, so a
naturally required rotation and confirmation remain unobserved. The user has
replaced the physical Scribe gate for this task with local KOReader acceptance;
physical-device compatibility is not established by that change.
