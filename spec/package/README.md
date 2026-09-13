# Integrated development package verification

The latest default archive is the categorized Bookstore revision. Its
[source binding](bookstore-categories-source-evidence.json), [package checks](bookstore-categories-results.json)
and [implementation/acceptance record](../../docs/bookstore-categories.md) supersede the
default archive references below. The preceding 102-file compact bookshelf
archive remains under `dist/history/bookshelf-60ea9d6a/`, with its original
[source binding](bookshelf-source-evidence.json). The 101-file stabilization
archive remains under `dist/history/stabilization-45385c6f/`.

The initial 104-file Bookstore package, manifest and original evidence archive
remain under `dist/history/bookstore-43a82cca/`. Its seven-comic feed and two-card
layout are superseded by the current four-section, compact-grid implementation.

The 104-file expanded homepage candidate and its evidence are retained under
`dist/history/bookstore-c6fca6fe/`. The current candidate adds official subject
browsing and independently scoped category-cache and protocol evidence.

This is the historical 96-file integrated build record. The preceding stabilization
candidate and its exact production/reading bindings are recorded in
[stabilization-source-evidence.json](stabilization-source-evidence.json), with
[package checks](stabilization-results.json) and the
[unified regression](../integration/stabilization-regression-results.json).
The default ZIP filename has been reused for that newer candidate; the historical
hash and file count below continue to identify the earlier artifact only.

The subsequent [progress recovery](../../docs/progress-recovery.md) rechecked
the then-current stabilization delivery against the merged production tree and both acceptance
bindings through `ssh test-env`, without rerunning behavioral suites.

That historical default archive contained **96 files** and integrated the quote
and ordinal-range UI. At that snapshot, `dist/bilicomics-quote-preview.zip` was an
identical-byte alias of `dist/bilicomics-0.1.0-dev.zip`. The preview still identifies
the older snapshot; it is not an alias of the subsequent 101-file stabilization candidate.
Both historical archives had SHA256
`8891f287f3cc87904589bee378afdfb0b0bc1cdb5257dc6cece79968d18e6530`
and contain 2,446,099 bytes. Their separate manifests name their respective ZIPs.

The final source is `/tmp/bilicomics-integrated-final-zi6GBKDF/stage/plugin`.
Its eight changed Lua files passed remote syntax compilation with application
execution disabled, and `package-final/result.json` passed all **27 package
checks**. The checker builds the allowlist twice and compares complete ZIP bytes,
checks every manifest entry, verifies all 14 native libraries against their
platform manifests, and checks redistribution notices and startup dependencies.
When the collector requires `purchase/range`, that dependency must be present.
The ARM ELF check requires adjacent REL/JMPREL tables, immediate binding and
GNU RELRO. Synthetic packaging fixtures cover private-directory exclusions,
misplaced account-data filenames and symlink refusal; no actual session is read.

The final Service source is
`051ec6d5f55be7c6c9013560a43117646ba44df908f89382db204eacaa1ff841`.
Relative to the previous 95-file preview, seven existing files changed and
`bilicomics/purchase/range.lua` was added. The other 88 baseline files retain
their exact bytes. Client-only candidates and the earlier `bee9a0d9` integrated
candidate remain remote intermediate artifacts and were not published.

## Evidence boundaries

[The combined binding](integrated-quote-source-binding.json) records the report
hashes and exact module or function identities below. [Staging](integrated-quote-staging.json),
[syntax](integrated-quote-syntax.json), and [package checks](remote-results.json)
remain separate records. `source-evidence.json` and
`quote-preview-source-evidence.json` are current indexes into that binding.

| Evidence | Precisely retained scope |
| --- | --- |
| Identity, 115 assertions | Three unchanged Client function slices: `id`, `responseId`, and `purchaseInfo`. The older Client/Fetch combination is not claimed for the new collector. |
| Range, 240 assertions | Current Range/Fetch/Quote and their selection/value dependencies, using synthetic catalogs and fake collection responses. |
| Native UI, 212 assertions | Current Model, Screens and locale with synthetic quote/controller data: 106 checks at each of 600x800 and 480x640. |
| Synthetic transactions | 11 processes and 66 cases. Nine ordinal processes contribute 489 counted assertions; this number excludes other ordinary assertions. Current Service, request construction, conflict handling and SQLite restarts use synthetic outcomes. Crypto/transport replacements and load-only modules remain explicitly limited in the binding. |
| Reading connectivity, 25 cases | Unchanged Controller, DownloadService and Runner versions; the report's wider source inventory is not treated as additional behavior coverage. |
| Read-only live construction | Seven business requests, including four quote reads, and one public signing asset. Two locally constructed ranges contain 20 and 123 chapters. Fetch then uses captured memo responses; Service and submission are not executed. |
| Inherited ARM evidence | The two ARM binary hashes are unchanged from earlier primitive checks under the diagnostic glibc 2.20 loader and glibc 2.41. No physical-device acceptance is added. |

The live launcher records source hashes at copy time, with no after-run source
map. Its original public report pair has no observation digest or shared run ID;
the binding preserves both supplied report hashes and this limitation. A local
`submittable` decision follows the documented ordinal contract and quote/catalog
consistency checks. It does not mean the server echoed the chapter IDs, confirmed
atomic range delivery, or completed a purchase. No actual purchase, full-artifact
live acceptance, physical-device verification or local visible-window acceptance
is claimed by these records. Earlier expired-session observations remain failure
history and are not included as passing evidence.

## Reproduction

Run through `ssh test-env`, using a new output directory. The source snapshot
must include the production allowlist, `tools/package.py`, and the package scripts.

```sh
python3 -I -B spec/package/stage_integrated_quote_revision.py \
  --source /absolute/frozen/source \
  --baseline /absolute/previous-preview.manifest.json \
  --runtime /tmp/bilicomics-native-_duimwe7/lib/koreader \
  --output /tmp/new-integrated-stage
python3 -I -B spec/package/verify_package.py \
  --source /tmp/new-integrated-stage/plugin \
  --output /tmp/new-integrated-package
```

`bind_integrated_quote_revision.py` consumes the produced manifest, alias
manifest, stage and package reports, plus the specifically scoped public
evidence. It rechecks the fixed baseline, all artifact bytes, the changed paths,
syntax and proof identities. It does not perform application or API operations.

## Preserved history

The last separate reading and preview archives and their manifests are retained
under `dist/history/reading-1aa7c223/` and `dist/history/preview-38a01da1/`.
The older `bilicomics-reading-2f337b48.zip` also remains. The four preceding
current package/provenance reports are preserved with
`-before-ordinal-integration.json` names.

Earlier `-before-connectivity`, `-before-arm`, and `reading-revision-*` records
retain their original scopes. They distinguish the earlier source-refresh and
version-replacement integration, ARM binary update, reading connectivity/expiry
update, and syntax-only preview stages. Those historical claims are not rewritten
as acceptance results for the new integrated package.
