# Unified synthetic release regression

Run `run_release_regression.py` only through `ssh test-env`. It rejects local
execution, requires a fresh `/tmp` output directory, and uses the pinned official
KOReader `v2026.07.1` runtime. Prepare a frozen source snapshot containing
`main.lua`, `_meta.lua`, `bilicomics`, `l10n`, `patches`, `tools`, and `spec`.
Do not copy `.secrets`, user accounts, or runtime profiles into that snapshot.

The command below runs on the remote host. Substitute the source snapshot, base
commit, dependency, and public asset paths with the inspected values for the run.
No dependency installation or public asset download occurs in this entry point.

```sh
python3 /tmp/SOURCE/spec/integration/run_release_regression.py \
  --runtime /tmp/bilicomics-native-_duimwe7/lib/koreader \
  --source /tmp/SOURCE \
  --output /tmp/FRESH-RELEASE-RESULTS \
  --pillow-root /tmp/bilicomics-auth-root-20260913/dependencies \
  --assets /tmp/PUBLIC-PINNED-ASSETS \
  --base-commit FULL_40_CHARACTER_COMMIT_ID \
  --revision candidate-label \
  --jobs 3
```

The matrix includes authentication protocol and crypto, session maintenance,
private storage and import, both QR languages and display sizes, protocol client
and native crypto, broad and focused Controller checks, every default jobs suite,
download connectivity, storage crash/recovery, complete source refresh and version
replacement workflows, synthetic single and ordinal purchase transactions,
archive-backed quote selection, native reader geometry/defaults, production and
fallback startup, cross-layer reading, and deterministic packaging. The old
authentication aggregator is expanded into individual suites so its internal
parallelism cannot exceed the global limit of three suites.

Every suite has a separate output directory and log. The launcher requires fresh
network and PID namespaces, an isolated synthetic profile, and a bounded timeout.
Killing the suite process group kills its namespace init and all descendants,
including workers that start their own sessions. Namespace creation failure fails
the suite; the launcher never falls back to network-enabled execution.

`release-regression.json` records the full production tree and all Lua/Python test
sources and tools with SHA256 hashes, plus a canonical combined snapshot digest.
The base commit is caller-supplied provenance; the content digest is the exact
tested identity, including uncommitted fixes. Inputs are rehashed after execution.
The produced package is the same archive consumed by quote-selection tests.
Individual report hashes, explicit pass markers, nonempty assertions, complete
case matrices, expected crash exits, and nested results are checked. Exit code zero
alone is insufficient. Missing reports, skipped dependencies, failed assertions,
incomplete matrices, or changed inputs make the overall result fail.

A passing matrix proves only this synthetic Linux regression scope. Real mobile QR
confirmation, real renewal, live chapter delivery, physical Scribe/Android behavior,
and actual payment remain separate acceptance gates. Historical research image
acquisition is excluded because it requires separately selected research fixtures.
The report lists these exclusions and their relevant documentation or independent
command. Never supply a user session or real purchase input to this runner.
