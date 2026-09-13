# Explicit version replacement workflow integration

This focused driver runs only on the authorized remote `test-env`, using the
official KOReader v2026.07.1 Linux runtime. Every case has a fresh data directory,
an isolated Xvfb display, and a distinct `unshare -n` network namespace. It never
uses the workstation's WSL reader, a user session, or a production account.

Only synthetic free-chapter responses are supplied at `Transport.request`.
The endpoint allowlist contains nav, ComicDetail, GetImageIndex, ImageToken, and
PNG CDN reads. Any other endpoint or worker kind fails immediately. No purchase,
quote, wallet, account-write, follow, or history-write scenario is executed.
Synthetic session import creates private local fixture stores and validates
them with a synthetic read-only nav response.

Controller, DownloadService, both replacement layers, Catalog, SQLite Store,
PageStore, the default Worker, Client, Runner, and native ReaderUI remain
production code. Runner starts real child processes and delivers real IPC
results. Transparent wrappers observe worker submissions, process IDs, native
decodes, and calls to chapter preparation. The two fault cases inject a real
SQLite write failure and a post-publication resume exception at their designated
boundaries without replacing application or worker results.

## Scenarios

- A retained partial version has a ready image with old bytes, unknown legacy
  history for missing pages, a finished local anchor, a pin, native page positions,
  and two duplicate download rows. Replacement creates one independent local
  descriptor and job, retires both predecessor rows, resets current progress,
  keeps old data and native settings, and acquires every new image.
- The same normalized opaque index identity and the same unsigned source paths
  still produce an independent local snapshot. Changed page count is accepted
  without relying on old page identities, progress, or image bytes.
- Controller reconstruction opens exact old and new jobs through real ReaderUI
  while disconnected. An additional native direct reopening exercises the old
  descriptor while connected. Retired missing pages, including one with no source
  path, perform no worker dispatch or global chapter preparation. Native image
  decode is observed. Reading old content changes only its own anchor. Removing
  either old duplicate retires both rows and preserves the new pin, bytes and
  anchor; the new version can subsequently be removed independently.
- Explicit cancel, suspend, account close, and public synthetic account switch
  occur while a real index child is blocked. Each reports one canceled completion,
  preserves old state, reaps its children, and never replays canceled index work.
  The second account's fresh local store remains empty.
- A changed job generation and a changed captured anchor reject stale index
  completion or stale publication. Source refresh cannot overlap active version
  replacement. Recovery clears a persisted interrupted marker without workers.
- Missing fresh free-chapter access, invalid fresh image index, and a real SQLite
  publication write failure do not publish a new descriptor/job or lose old data.
- A thrown resume call after successful publication returns the published value
  plus an error, leaving a paused new job that completes after explicit retry.
- Initially unpinned retained images receive a temporary eviction lease while
  the fresh index waits. Automatic cleanup cannot remove them. Cancel releases
  the lease without adding a pin; successful publication pins both versions.
  The real SQLite publication failure also starts unpinned and preserves that
  state while releasing the operation and lease.
- An ordinary bound job retains its own revision when the catalog selects another
  descriptor. A first unbound enqueue still calls real preparation, obtains a
  normalized index through Client, and binds that descriptor before downloading.

## Evidence and reproduction

`version-replacement-workflow-results.json` records **19 scenarios, 258
assertions, and 58 real worker starts**, all passing. Every child was reaped;
every tracked process was terminal; and the production source snapshot was
unchanged. The final remote report is
`/tmp/bili-version-workflow-waqSS3Li/run3/results.json`, with its copied source
under `/tmp/bili-version-workflow-waqSS3Li/run3/source`. The source archive SHA256
is `6f7b16efd1a1cb877ea8c71b6cdeb3593b00f66e9f8c0148a394370734038ef0`.

`version-replacement-workflow-first-run.json` preserves the initial run: 17
scenarios passed, while two driver assumptions failed. The resume exception
hook initially intercepted the separate assertion that retired jobs reject
resume; it now throws only for the new job. A second native opening legitimately
reused KOReader's render cache, so the driver now clears only its isolated
`KO_HOME/cache` before each open and still requires a real native decode. It does
not clear PageStore images, descriptor settings, or reading anchors. Both
corrected scenarios passed separately in `run2` before the full final matrix.
All production Lua hashes are identical between the initial and final runs.

The final transport audit contained 20 nav, 16 ComicDetail, 16 GetImageIndex,
21 ImageToken, and 21 PNG CDN reads, with no other endpoints. The purchase,
quote, wallet, and remote account-write endpoints were never exercised.

The launcher records source, runtime, signing-fixture and launcher SHA256 hashes;
checks source immutability; and writes per-case assertions plus a combined JSON
report. Every tracked PID includes its process start time to avoid terminating a
reused PID. Case timeouts are bounded, and cleanup targets only matching owned
processes and the launcher's own process group. All worker children must be
reaped and terminal for a case to pass.

```sh
python3 spec/integration/run_version_replacement_workflow.py \
  --runtime /tmp/bilicomics-native-_duimwe7/lib/koreader \
  --source /absolute/frozen/source \
  --assets /tmp/bilicomics-protocol-tests-vlh4afyq/run5/assets \
  --work /absolute/new/isolated/work \
  --package /absolute/source/archive.tar.gz
```

This fixture covers plain PNG images and synthetic read responses. It does not
claim real-service locator freshness, encrypted-image coverage, purchase
behavior, or hardware-device validation.
