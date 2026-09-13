# Source refresh workflow integration

This focused suite uses the official KOReader v2026.07.1 Linux runtime on
`test-env`, with a fresh `unshare -n` network namespace for each case. It does
not run on the local workstation or use an account session. Only synthetic
nav, ComicDetail, GetImageIndex, ImageToken and PNG CDN responses are supplied
at `Transport.request`. The production-pinned public signing WASM is copied
from an existing fixture and checked against its manifest SHA256.

Production sources for Controller, DownloadService, the coordinator,
SourceRefresh, SQLite Store, PageStore, Worker, Client and Runner are copied
unchanged. Runner uses its default worker and creates real forked processes with
IPC. The real UIManager schedules work while an isolated Xvfb display holds a
small test widget. A one-worker Runner configuration makes priority preemption
deterministic. Transparent submit/start observations do not replace responses
or application helpers.

## Scenarios

- A partial immutable R1 contains ready A, evicted B with a retained committed
  digest, and never-downloaded C. Real Client normalization produces rotated
  index paths and IDs. The coordinator verifies A and B, then Controller resumes
  downloads for B and C using the new sources. R1 descriptor bytes/path, anchor,
  ready A's bytes/file identity, pin and current_revision remain unchanged;
  there is one version and one source-generation increment per page.
- A changed B candidate, a changed ordered page geometry, unknown legacy
  history, and a precise native page_positions entry on C each reject the
  refresh and preserve the old content/mappings/descriptor/anchor/pin.
- Explicit cancel, suspend and account close occur with a real proof child
  blocked after writing a 23-byte partial. The suite checks callback lifetime,
  queued/active tasks, candidate removal and preserved snapshot. Account close
  reopens the real account Store to inspect durable state.
- A persisted interrupted marker and orphan partial are recovered on Controller
  reconstruction without dispatching source/image workers.
- A higher-priority safe nav task preempts the proof. The same proof task
  restarts in a new PID at attempt 2, replays its own partial, and completes.
- A targeted final job-update hook temporarily enables SQLite query_only after
  adoption. The actual update fails, but exactly one storage error reaches the
  caller, the operation/lease are released, and no automatic download starts.
  The adopted source mappings remain; recovery clears the persisted marker.
- A targeted post-adoption resume hook throws. The caller receives the adopted
  summary plus one error, with no missing-page worker or unfinished marker.
- An initially unpinned preflight rejection leaves its pin false. During an
  unpinned blocked proof, automatic eviction preserves A via the transient
  source-refresh lease. Cancel releases the lease without setting a pin, after
  which automatic eviction can remove A again.

No purchase, quote, wallet, follow, history-write or broader UI scenarios run.
The fixture exercises plain PNG image responses; encrypted production images,
real service locator expiry and hardware device behavior are outside its scope.

## Evidence

`source-refresh-workflow-before-fix.json` preserves the first full run against
the original frozen source: nine scenarios passed and suspend failed because a
canceled proof was left queued. Runner.suspend overwrote cancel with preempt,
making the canceled operation replayable. The failed run is not rewritten.

`source-refresh-workflow-results.json` records the final **14 scenarios / 185
assertions / 44 real worker starts**, all passing. Every tracked process was
terminal and the run's source snapshot was unchanged. The remote result is
`/tmp/bili-refresh-workflow-cxg00B47/run4/results.json`; its copied production
source is `/tmp/bili-refresh-workflow-cxg00B47/run4/source`.

The final run adds the four concrete regressions above, explicit real Client
index-rotation observations, ready-file metadata preservation and terminal PID
checks. A test-only snapshot correction encodes sparse native page_positions
keys before canonical comparison; it changes no production behavior or rejection
criterion. Every run uses a new isolated directory and never resumes an earlier
fixture Store.

## Remote command

```sh
python3 spec/integration/run_source_refresh_workflow.py \
  --runtime /tmp/bilicomics-native-_duimwe7/lib/koreader \
  --source /absolute/frozen/source \
  --assets /tmp/bilicomics-protocol-tests-vlh4afyq/run5/assets \
  --work /absolute/new/isolated/work
```

The launcher copies production Lua into a fixed run snapshot, records source,
runtime, launcher and WASM hashes, checks source immutability, and saves a
per-case report plus the combined `results.json`. Logs contain synthetic data
only. Each report records real worker starts, event-loop ticks and teardown
status. Timeout handling records failure and terminates only tracked processes
whose PID/start-time identity still matches, plus the launcher's own process
group; the final successful run did not exercise this timeout path. The selected
endpoints are an explicit allowlist; any other transport request or worker kind
fails the case. No original session file or local WSL reader window is accessed.
