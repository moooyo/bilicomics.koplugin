# Cache getter performance review

Measured on `ssh test-env` on 2026-09-12 using the unmodified official KOReader
`v2026.07.1` runtime. No local verification, real account, or Bilibili access was
used. The measured production source hashes are recorded in
`cache-getters-before.json` and `cache-getters-results.json`. The only source
change between those runs is `bilicomics/storage/page_store.lua`.

## Finding

The current UI does not repeatedly hash cached images during ordinary refreshes.
`Catalog:getEpisodes()` counts matching ready page records in SQLite;
`Catalog:getLibrary()` reads comic, episode, descriptor, and anchor metadata.
`Controller:getStorageSummary()` sums page metadata directly. These methods do
not call `PageStore:isComplete()` or `PageStore:getSummary()`.

The unused production API `PageStore:getSummary()` is expensive: it calls
`isComplete()` for every descriptor, which forces a full SHA-256 pass over each
ready image. Before the fix, its first call with an empty verification memo
hashed every ready image twice because `isComplete()` first called `getPage()`
and then called `_validFile(..., true)` again. The fix reads the raw Store record
and performs one forced validation. It removes a redundant integrity check;
there was no UI-wide cache scan to fix.

## Current call paths

Line references describe the baseline source snapshot whose hashes are in
`cache-getters-before.json`.

| Entry | Path | Image digest work |
| --- | --- | --- |
| Continue / favorites | `ui/screens.lua:212` -> `Controller:getLibrary` -> `Catalog:getLibrary:384`; visible cards additionally call `getEpisodes` at `screens.lua:182` | None |
| Chapter catalog | `screens.lua:283-285` -> `Controller:getComic/getEpisodes` -> `Catalog:getEpisodes:393` | None |
| Downloads | `screens.lua:406,419` -> `Controller:getDownloads/getStorageSummary`; visible rows query `getComic/getEpisode` at `screens.lua:358-359` | None |
| Account | `screens.lua:514` -> `Controller:getStorageSummary:708` | None |
| Page completion | `jobs/download_service.lua:214` -> `Controller:_notify:55` -> next tick -> `Screens:refresh:40` -> current route builder | No added integrity scan |
| Storage integrity summary | `PageStore:getSummary:419-422` -> `isComplete:248-264` -> `_validFile(force=true)` -> `Files.digest:104` | All ready images reached before an incomplete page |

`Catalog:_snapshot:128` creates a lazy metadata snapshot. `_descriptor:168` and
`_anchor:204` only query Store methods. `Store:getDescriptor/listDescriptors`
decode SQL records; they do not read image files. `Controller:getStorageSummary`
still performs one full metadata scan plus one pin lookup per ready page. That
cost scales with record count, but not with image byte size.

There is no production caller of `PageStore:getSummary()` in the reviewed source;
the only caller found outside its definition is the storage spec. Explicit
operations still call `isComplete()`, including opening a chapter
(`controller.lua:544`), validating an offline download request (`:653`), and
download recovery (`jobs/download_service.lua:344`). Those are integrity or
operation boundaries rather than ordinary screen getters.

## Measurement

The isolated fixture contains 8 valid RGB PNGs, 2048 x 512 pixels each, across
4 complete pinned chapters and 2 comics. Pixel content is deterministic
incompressible noise, encoded as ordinary PNG IDAT data without artificial
padding. The total cache is 25,178,104 bytes (24.012 MiB), below the 64 MiB cap.
The fixture files are moved into the PageStore commit path, avoiding duplicate
fixture/cache disk copies.

The harness uses production Catalog, Controller, PageStore, Files, and SQLite
Store methods. It wraps `Files.digest` to count successful digest calls and
returned byte counts. Startup and fixture commits are excluded. Every scenario
starts with an empty `PageStore.verified` memo, followed by three repeats. The OS
page cache is not flushed; these are not cold-disk benchmarks. Notification
tests use the real `Controller:_notify()` and a screen proxy invoking production
getters; native widget construction and painting are not measured.

Baseline measurements:

| Scenario | First (ms) | Repeat range (ms) | First digest calls / bytes | Each repeat digest calls / bytes |
| --- | ---: | ---: | --- | --- |
| `getEpisodes`, both comics | 0.713 | 0.500-0.649 | 0 / 0 | 0 / 0 |
| `getLibrary`, history and favorites | 0.140 | 0.062-0.234 | 0 / 0 | 0 / 0 |
| `Controller:getStorageSummary` | 0.097 | 0.049-0.087 | 0 / 0 | 0 / 0 |
| Download route getters, all rows | 0.207 | 0.160-0.276 | 0 / 0 | 0 / 0 |
| `_notify`, library getter callback | 0.498 | 0.554-0.670 | 0 / 0 | 0 / 0 |
| `_notify`, downloads getter callback | 0.167 | 0.195-0.236 | 0 / 0 | 0 / 0 |
| `PageStore:getPage`, all pages | 88.561 | 0.128-0.261 | 8 / 25,178,104 | 0 / 0 |
| `PageStore:isComplete`, all chapters | 170.974 | 90.286-94.392 | 16 / 50,356,208 | 8 / 25,178,104 |
| `PageStore:getSummary` | 178.570 | 85.405-86.796 | 16 / 50,356,208 | 8 / 25,178,104 |

After the minimal fix, the same fixture and harness produced:

| Scenario | First (ms) | Repeat range (ms) | First digest calls / bytes | Each repeat digest calls / bytes |
| --- | ---: | ---: | --- | --- |
| `getEpisodes`, both comics | 0.645 | 0.647-0.995 | 0 / 0 | 0 / 0 |
| `getLibrary`, history and favorites | 0.582 | 0.110-0.138 | 0 / 0 | 0 / 0 |
| `Controller:getStorageSummary` | 0.090 | 0.045-0.108 | 0 / 0 | 0 / 0 |
| Download route getters, all rows | 0.218 | 0.180-0.274 | 0 / 0 | 0 / 0 |
| `_notify`, library getter callback | 0.526 | 0.615-0.828 | 0 / 0 | 0 / 0 |
| `_notify`, downloads getter callback | 0.174 | 0.190-0.326 | 0 / 0 | 0 / 0 |
| `PageStore:getPage`, all pages | 88.995 | 0.123-0.276 | 8 / 25,178,104 | 0 / 0 |
| `PageStore:isComplete`, all chapters | 86.340 | 86.711-87.273 | 8 / 25,178,104 | 8 / 25,178,104 |
| `PageStore:getSummary` | 87.564 | 86.710-88.401 | 8 / 25,178,104 | 8 / 25,178,104 |

The first integrity sweep now reads exactly one cache-sized pass: 8 digests /
25,178,104 bytes instead of 16 / 50,356,208. Forced checks on repeat calls remain.
All six UI getter/notification scenarios still perform zero digests on their
first and repeated calls. Synthetic image caches were removed after each run;
the small evidence and logs were preserved.

The structural conclusion is the measured digest count, not a promise of
sub-millisecond response on e-readers. Record count is intentionally small;
large-library database scaling and actual screen rendering were not measured.

## Production change and integrity boundaries

Keep the UI getters as metadata projections. Do not replace
`Controller:getStorageSummary()` with `PageStore:getSummary()`.

The parent task changed `PageStore:isComplete()` to read the raw page record with
`self.store:getPage(pageKey(episode_id, revision, index))`, keeping its existing
ready-state check, forced `_validFile(..., true)`, and `_markMissing(..., true)`
invalidation. The second run confirms this changes the first integrity sweep
from two digests per ready page to one. Repeated integrity sweeps intentionally
remain one digest per page. This performance review owns the measurement files;
production implementation and storage correctness checks belong to the parent
task.

Do not globally remove forced checks from commit, journal recovery, reconcile,
or explicit completeness verification. Those checks validate new or recovered
bytes, detect on-disk corruption, and establish trustworthy offline availability.
The normal `getPage()` memo already avoids a repeated digest when path, size,
modification time, and expected checksum match. A pure display getter should
continue reporting stored state and leave integrity transitions to those
boundaries.

## Reproduction

Copy the current `bilicomics/` tree and this `spec/performance/` directory into a
fresh plugin snapshot on `test-env`. Then run only on that remote host:

```sh
python3 /tmp/PLUGIN/spec/performance/run_cache_getters.py \
  /tmp/bilicomics-native-_duimwe7/lib/koreader \
  /tmp/PLUGIN /tmp/NEW-OUTPUT-DIRECTORY
```

The output directory must not exist. The runner refuses Windows execution,
generates the bounded fixture, launches the official runtime under Xvfb, and
writes `results.json` plus a log. It never starts network workers or imports a
session. The controller is assembled directly so unrelated startup and credential
storage work cannot affect the getter timings.
