# Bounded live authentication acceptance

Run this harness only through `ssh test-env`. Local execution is not authorized.
Preparing the harness does not generate a QR code or access an account. Start a
live attempt only after the operator is ready to scan and confirm in the official
Bilibili mobile app. Every attempt uses a fresh private directory; the harness
does not import an existing session or modify a reader installation.

The driver uses the production Controller, Runner and Worker, QRLogin with native
KOReader QRWidget, SessionManager, and SessionStorage. Connectivity is reported
as available by the harness; actual transport success still requires production
TLS verification. The harness does not use the plugin main entry point or the
full account screen. It instantiates the real controller and QR dialog directly,
so a successful run does not establish menu navigation or physical device UI
behavior. Account details are never drawn into the exported QR screenshot.

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

Successful phone confirmation must pass the production identity check and a
durable session save. The controller closes before `login-results.json` can pass.
The session remains only under the isolated private data directory in a 0600
file, ready for this separate process:

```powershell
ssh test-env 'python3 /tmp/auth-prepared/spec/integration/run_live_authentication.py restart --work /tmp/auth-prepared --execute-live-auth --timeout 180'
ssh test-env 'python3 /tmp/auth-prepared/spec/integration/run_live_authentication.py status --work /tmp/auth-prepared'
```

The new Controller must load the saved session, then its production SessionManager
runs `cookieInfo` and its normal maintenance path. No force flag, synthetic
timestamp, refresh-token substitution or server-result override is used. If the
service reports `refresh=false`, only identity validation and durable check-state
save are expected: renewal and confirmation remain unverified. If it reports
`refresh=true`, the actual challenge, refresh, durable candidate/confirmation
marker saves, confirm request and final save must all succeed to pass. Unknown
refresh or confirmation outcomes are preserved by production crash markers;
this harness never replays them. Each prepared directory allows one restart
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

The Runner guard accepts only authentication tasks. The transport guard permits
only QR generation/poll and identity checks during login, and cookie information,
identity checks plus server-required refresh/confirmation during restart.
Purchases, quotes, favorites, wallet, catalog and all other account operations
are rejected. Raw subprocess output is discarded, and the harness never writes
credentials, account identity, QR URL/key, request bodies or response bodies to
logs or public evidence. `private/config.json` and process controls are private;
the public JSON contains only fixed codes, booleans, counts, numeric service
codes, and code hashes. Never include the private directory in Git evidence.

Status codes: `1` prepared; `10` starting; `11` waiting for scan; `12` awaiting
phone confirmation; `20` login saved; `21` restart checked without required
renewal; `22` restart renewed and confirmed; `23` offline rehearsal passed;
`40` authentication request failed; `41` QR expired; `42` cancelled;
`49` harness/precondition failure. Always inspect `passed` and cleanup booleans;
the status code alone is not a completion claim.

No live execution evidence is included merely by adding or preparing this
harness. Full acceptance still needs real phone confirmation, a successful
separate-process restart, and a naturally required renewal. Kindle Scribe
startup, suspend/resume, refresh quality and memory behavior require a separate
physical-device session.
