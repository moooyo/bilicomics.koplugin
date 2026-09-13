# Download connectivity gates

This focused verification is limited to reading acquisition and job lifecycle.
It uses the official KOReader v2026.07.1 Linux runtime on `ssh test-env` in an
isolated `unshare -n` network namespace. It never reads a real session, calls a
remote API, or runs a purchase, quote, wallet or broader historical suite.

Two complementary scopes are reported separately:

- `download_connectivity_spec.lua` uses actual Controller, DownloadService,
  SQLite and PageStore with synthetic PNG bytes. An asynchronous runner double
  exposes exact page/index submission and completion boundaries. Tests cover
  offline enqueue without a descriptor, partial resume, cached-first behavior,
  complete local chapters without a session, predicate exceptions, disconnection
  after preparation or between pages, network/timeout outcomes, explicit retry,
  cancellation, closure, account replacement and production-injected guards.
- `download_connectivity_runner_spec.lua` uses the actual Runner and real
  subprocesses with synthetic workers. It checks the parent-side start guard
  before queued, retry and preempted work, plus synchronous guard rejection and
  suspend/close reentry. Child reaping and standby balance are part of this
  Runner evidence; no production HTTP worker or live service is involved.

Ready cache hits remain local and precede network/session checks. Offline
incomplete jobs persist as paused with a network reason. They need an explicit
resume once connected; this change adds no polling, reconnect auto-enqueue or
background operating-system service. A valid page already arriving may commit,
but another missing-page worker must not start after connection loss.

The launcher copies a fixed source snapshot and records repository-relative
SHA256 values, including Controller, DownloadService and Runner. Each suite has
an isolated profile and result, and the combined report states which components
are real and which are controlled. This evidence is not full live-service or
device acceptance. The completed result and exact counts are recorded in
`download-connectivity-results.json`: **25 cases / 135 assertions passed**
(service/Controller 16/50; real Runner 9/85). The Runner made seven real forks,
reaped all seven children itself, and balanced seven standby holds/releases.
The fixed remote snapshot is
`/tmp/bili-download-connectivity-HSBOktRP/run2/source`; the combined report is
`/tmp/bili-download-connectivity-HSBOktRP/run2/results.json`.

`download-connectivity-before-assertion-fix.json` preserves the initial result.
Its service suite passed; four Runner success assertions incorrectly required
`err == nil`, whereas the existing successful Runner completion expression can
return the falsy value `false`. The final assertions require `not err`, matching
production caller semantics. No production file changed for this correction.
The already-started final two-suite run completed before the instruction to
avoid repeating the green service phase arrived; no additional run followed.

```sh
python3 spec/jobs/run_download_connectivity.py \
  --runtime /tmp/bilicomics-native-_duimwe7/lib/koreader \
  --source /absolute/frozen/source \
  --work /absolute/new/isolated/work
```
