# Background job verification

Run these suites only through `ssh test-env`. They execute KOReader's bundled
LuaJIT, FFI, real POSIX processes and pipes, and real SQLite/PageStore storage in
an isolated remote output directory. They do not use account credentials,
contact Bilibili, or submit a purchase.

`runner_spec.lua` uses a small event scheduler in place of the UI and the real
KOReader subprocess helpers. It checks a 1 MiB frame against the actual Linux
pipe capacity, cancellation, timeout, preemption, resource limits, standby
ownership, suspended scheduling, child reaping, and file descriptor cleanup.
The process-group regression uses a real KOReader after-fork hook to hold the
child before `setpgid`, then requires immediate close to terminate it promptly.
Retry scenarios use real child-written attempt logs to verify the three-attempt
error limit, increasing backoff, error classification, purchase exclusion,
timeout recovery, idle scheduling, cancellation, suspension, and urgent work.
The error-retry budget is distinct from internal preemption of cancelable reads.

`download_service_spec.lua` uses the real account database and atomic page
commits, with generated valid PNGs and an asynchronous runner double. It covers
shared acquisition ownership, cache reuse, complete retained downloads,
pause/resume races, obsolete page and preparation generations, account teardown,
temporary-file cleanup, storage-owned commit recovery journals, refreshed offline
rights, missing completed downloads, and reopened database recovery. Obsolete
results must neither restore removed files nor cache failures against a new read.
Live retry and download resume must recover journal-owned images before fetching
again, announce recovered pages, preserve other workers' partial files, and
isolate storage failures to the affected chapter. Space-limit scenarios verify
that cached and recoverable content remains usable, manual downloads pause, and
automatic cleanup preserves pinned or actively read pages.

`worker_spec.lua` injects the protocol client at the worker boundary. It covers
the read-only operation allowlist, library pagination and deduplication, quote
and purchase boundaries, exact error propagation without purchase retries, real
image-header parsing, EXIF geometry, transfer limits, and failed-file cleanup.
These checks establish worker routing and storage behavior; they do not prove
the live Bilibili protocol, actual download throughput, or physical device power
management.

`worker_extensions_spec.lua` adds favorite mutations and local diagnostics.
Favorite tests exercise the production Client with an injected transport,
checking `AddFavorite`/`DeleteFavorite`, the string `comic_ids` payload, and
business or transport failures that must not become confirmations. Diagnostics
tests verify anonymous construction, a transport that rejects real Client
request paths, strict output fields, private-value filtering, exception
redaction, and versions from the real KOReader runtime and staged `_meta.lua`.
Runner scenarios separately prove favorite mutations are not preempted or
automatically resent after suspension, timeout, or a retryable transport error.

`storage_budget_spec.lua` calls the real `statvfs` ABI with valid, nonexistent,
and invalid-component paths. It verifies that a failed query never reuses an old
capacity result and that workers stop before constructing a protocol client when
the reserve cannot fit. These scenarios request a numerical reserve larger than
the filesystem capacity; they never fill the filesystem with test data.

`parent_exit_spec.py` runs an independent Lua parent under a Linux child-subreaper
supervisor. The parent exits through `_exit` without runner or UI cleanup. An
already executing worker must terminate with `SIGKILL` before its delayed file
write. A second case delays the real KOReader after-fork hook until after parent
exit and verifies that the saved parent-PID check prevents the worker body from
running. The supervisor reaps each adopted child and records whether any forced
cleanup was necessary. This verifies direct worker lifetime; it does not claim
that a permanently blocked pre-registration hook or arbitrary external helper
descendants are covered by the parent-death signal.

The following PowerShell commands transfer sources and invoke remote verification.
Use a fresh isolated output directory for every execution.

```powershell
$jobRemoteRoot = (ssh test-env 'mktemp -d /tmp/bilicomics-jobs-XXXXXX').Trim()
ssh test-env "mkdir -p $jobRemoteRoot/source/spec"
scp -r bilicomics "test-env:$jobRemoteRoot/source/"
scp _meta.lua "test-env:$jobRemoteRoot/source/"
scp -r spec/jobs "test-env:$jobRemoteRoot/source/spec/"
ssh test-env "python3 $jobRemoteRoot/source/spec/jobs/run_remote.py --runtime /tmp/bilicomics-native-_duimwe7/lib/koreader --source $jobRemoteRoot/source --output $jobRemoteRoot/results"
scp "test-env:$jobRemoteRoot/results/results.json" spec/jobs/remote-results.json
```

`run_remote.py` records the runtime version, production-source SHA-256 digests,
per-suite results, and failure logs. A failing assertion yields a nonzero exit
status. The standalone `cancel_race.lua` also reproduces the original
process-group race independently of the larger suite.

The recorded `remote-results.json` run used KOReader `v2026.07.1` on `test-env`.
All 22 native runner scenarios, 24 download-service scenarios, 81 worker boundary
assertions, 16 worker-extension scenarios, 10 real storage-budget scenarios, and 2 ungraceful-parent-exit
scenarios passed. The report pins the tested production and test
source digests; later source edits require verification appropriate to their
affected behavior.

The latest extension run reports KOReader `v2026.07.1`, plugin `0.1.0-dev`, and
target `linux-x86_64`. Its source digests include the production Client, platform
detector, and `_meta.lua` in addition to the existing jobs and storage modules.
This extension was verified on the host KOReader runtime through `ssh test-env`;
no APK operation occurred. The separate Android report retains its earlier
explicit source snapshot and does not claim Android coverage for the new
favorite or diagnostics operations.

The separate `cover-policy-results.json` records the later cover-budget change:
all 81 Worker assertions, 16 extension scenarios, 10 storage-budget scenarios,
and 7 new cover scenarios passed on the affected source snapshot. Its digests
also include `bilicomics/image_policy.lua`, the image header parser, and the
production image inspector. The earlier complete baseline remains in
`remote-results.json`; unchanged Runner and download-service groups were not
repeated for this Worker-only change.

`cover_policy_spec.lua` verifies the inclusive 4,000,000-pixel cover limit,
rejection and removal of a 6,000,000-pixel cover, independent header checking
when a client lies about dimensions, and normal chapter acquisition without the
cover-only limit. It also exercises production Client downloads and
`Image.inspect` with injected transfers. The PNGs are generated by streaming
grayscale rows into zlib: the 6 MP fixture occupies 5,908 bytes and the 4 MP
fixture occupies 3,958 bytes. No bitmap is allocated or image decoded. No
Android APK operation was performed for this follow-up.
