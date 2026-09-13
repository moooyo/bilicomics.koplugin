# Partial Download Recovery and Index Identity

Updated on 2026-09-12. Explicit source refresh is now implemented for snapshots
whose retained history can be proved against a fresh index. The original static
audit is preserved below; its line locations refer to the pre-repair source.

## Implemented recovery

The Downloads UI offers an explicit source-refresh confirmation. It fetches a
fresh catalog and index, requires current offline access, and compares every
historically committed page with the corresponding new candidate's SHA-256.
Candidates use the real Worker and a separate temporary file. Ready references
are hashed in the child and their file identities are checked again before
publication; no image hashing is added to the metadata capture/adoption paths.

`PageStore` now preserves `last_committed_checksum` across removal, eviction and
corruption. A history-version marker distinguishes a genuinely new, never-bound
page from missing legacy evidence. Repairing an old descriptor's missing row
does not invent that marker. Unknown history and unproved precise Store/native
reading positions reject the refresh.

When the complete ordered topology and all required historical proofs match,
one transaction updates only acquisition paths, source generations and expected
checksums. Descriptor bytes/path, existing ready files, source anchors and pins
remain unchanged. Later acquisition of a historically bound missing page must
still match its expected checksum. Success resumes the same download job;
generic HTTP 400/403 does not start this operation automatically.

Cancellation, suspend, account change and stale completions cannot publish a
new mapping. A temporary cache-protection lease is separate from permanent pins;
failed preflight or canceled verification leaves an originally unpinned snapshot
unpinned. A crash leaves the old mapping or the fully adopted new mapping, and
startup clears the interrupted verification marker without replaying workers.

The integration test found and fixed cancellation being overwritten by suspend
preemption, and verifies terminal callbacks even when final persistence or
post-adoption download resumption fails.

Current evidence:

- [Integrated workflow](../spec/integration/source-refresh-workflow-results.json):
  14 scenarios, 185 assertions and 44 real worker starts, all passing.
- [Storage proof layer](../spec/storage/source-refresh-results.json): 47 cases
  and 855 assertions with real SQLite.
- [Worker verification](../spec/jobs/source-verification-result.json): 17 focused
  groups, including same-path partial replay and current entitlement checks.
- [Native recovery UI](../spec/ui/download-recovery-result.json) and
  [compact UI](../spec/ui/download-recovery-result-480.json): 159 current checks each.
- [Historical fingerprints](../spec/storage/fingerprint-result.json) and
  [source-epoch completion](../spec/jobs/source-epoch-result.json): 14 and 11
  foundational checks respectively, preceding the final integrated run.

These are remote, network-isolated checks with controlled read responses and
real application components. No purchase, quote or wallet scenario was executed.
They do not establish a real service locator lifetime or physical Scribe behavior.

## Independent version recovery

This establishes a coherent current local snapshot, not proof that every
previously unseen server page stayed unchanged. No stable server content-ID or
atomic chapter-version contract has been inferred from `last_modified`, `cpx`,
page counts or dimensions alone.

Unknown legacy history, changed bytes/topology and unverified precise positions
still reject same-snapshot source refresh. The user can now explicitly select
Redownload as new version from Download recovery. Its separate confirmation
explains a complete new download, additional storage/network use, a fresh reading
position and preservation of the old version.

The replacement coordinator pauses the selected job, protects the old cached
images with a temporary lease and acquires a fresh catalog/index through the
existing read-only Worker. Current offline access remains required. Storage
captures the local snapshot and compares it again before publication. One
transaction publishes a unique local descriptor/revision, new page records,
a paused download job, chapter version selection and retirement of all jobs for
the old snapshot. Identical server revisions and opaque paths do not cause
descriptor, page or progress reuse. The new job resumes only after publication.

Successful publication pins both old and new versions; this also retains an
otherwise unpinned legacy cache as explicitly promised by the confirmation.
Cancellation or failure releases the temporary lease and leaves the old pin
unchanged. Old descriptors, ready images and Store/native reading anchors remain
available in a separate retained-version row. The user can read or remove that
version independently. Removal affects all duplicate jobs for its exact
episode/revision and cannot remove the newer version's pin or images.

Download jobs now resume their own persisted revision, and Read download opens
that exact descriptor. Retired versions read cached pages only, including direct
native reopening; neither missing pages nor next-chapter prefetch start network
work. Their own reading positions can change without updating the current
version's chapter-wide progress or finished state. A new version has its own
empty Store/native position and starts at the beginning.

Cancellation, suspend and account switching terminate preparation without
publishing a stale index. Restart clears an interrupted preparation marker
without automatically retrying. A database failure rolls back publication; an
orphan descriptor file is never selected or reused as a later snapshot. If
publication succeeds but resumption fails, the result distinguishes the saved
new version from the download error, allowing an explicit retry.

Focused evidence:

- [Integrated replacement workflow](../spec/integration/version-replacement-workflow-results.json):
  19 scenarios, 258 assertions and 58 real worker starts; exact old/new native
  reading, lifecycle cancellation and independent removal, all passing.
- [Atomic storage publication](../spec/storage/version_replacement_results.json):
  32 cases and 395 assertions using real SQLite, PageStore and native DocSettings.
- [Version progress isolation](../spec/catalog/version_progress_result.json):
  13 groups, including direct Store writes, native-integration-style writes,
  catalog ingestion, duplicate job badges and database reopening.
- [Native replacement UI](../spec/ui/version-replacement-result.json) and
  [compact UI](../spec/ui/version-replacement-result-480.json): 144 checks each.

These checks use synthetic reading inputs in an isolated remote environment.
They do not establish a real service version contract, a current account's
changed-content response or physical Scribe behavior.

## Proven behavior and evidence limits

[Live results](../spec/integration/live-reading-results.json) and the
[summary](../spec/integration/live-reading-summary.json) prove that one real free
chapter completed all 45 pages, remained pinned, and reopened in a new process
without a session or network requests, retaining its descriptor and source anchor.
The successful run reports `live_index_observations=1`. It does not establish
recovery of a partial chapter after a later index or source-address expiry.

The earlier preflight/run comparison observed all 45 opaque source paths changing
for the same chapter, even after query removal. This invalidated the research
driver's original static path whitelist; see [probe history](../spec/integration/live-reading.md).
Path rotation is observed. A particular lifetime, session binding or eventual
rejection of those old paths has not been established by that observation alone.

## Original code and the concrete gap

| Location | Behavior |
| --- | --- |
| [Client:imageIndex](../bilicomics/protocol/client.lua), lines 219–245 | Hashes each `raw.path` into the page ID; hashes those IDs and dimensions into `revision` at lines 237–243. A locator-only change therefore changes content identity. |
| [Controller:prepareEpisode](../bilicomics/controller.lua), lines 604–614 | Reuses the current descriptor when every missing page still has `extra.source_path`; it does not check address freshness or force a new index. |
| [DownloadService:resume/recover](../bilicomics/jobs/download_service.lua), lines 317–349 | Recovers local commit state, clears in-memory failures and invokes ordinary prepare; startup recovery pauses unfinished jobs. Neither operation refreshes the index. |
| [DownloadService:requestPage](../bilicomics/jobs/download_service.lua), lines 120–173 | `retry=true` recovers commit journals; acquisition still uses the persisted `extra.source_path` from line 152. |
| [Worker](../bilicomics/jobs/worker.lua), line 104; [Runner](../bilicomics/jobs/runner.lua), lines 209–232 | Each image worker obtains a fresh ImageToken, but Runner retries the same request and source path. It does not obtain GetImageIndex. |

Concrete conditional failure: R1 has pages 1–3 ready and pages 4–45 missing.
If the server subsequently rejects R1's opaque source addresses, Resume still
selects R1, obtains a token using its old page-4 address, and fails again.
Manual retry or process restart repeats that address. Removing cached images
also preserves descriptor/source metadata and therefore does not guarantee repair.
Automatic retries are bounded; this is repeated stale acquisition, not a proven
unbounded background loop. A short-lived CDN token can already be renewed when
the underlying source address remains valid.

Generic HTTP 400/403 is not proof of expiry. Current business errors do not supply
a verified source-expiry classification. Runner recognizes `token_expired`, but
the current production modules do not emit that error kind.

## Why forcing a new revision alone is insufficient

[PageStore:ensureDescriptor](../bilicomics/storage/page_store.lua), lines 53–76,
creates a new descriptor and entirely missing page set for a new revision.
The cache key and [physical path](../bilicomics/storage/page_store.lua), lines
183–198, include revision. There is no cross-revision content reuse.
Anchors and pins are keyed by episode plus revision in
[Store](../bilicomics/storage/store.lua), lines 248–295.

[DownloadService:_run](../bilicomics/jobs/download_service.lua), lines 251–253,
reassigns the job to R2 and pins it without migrating R1's ready pages/anchor or
releasing R1's pin. Old pinned copies remain protected from automatic eviction.
Two records must not simply share one pathname: PageStore `_finishCommit`,
`_evict` and `removeEpisode` unlink files without a blob reference-count model.

## Identity evidence that is still missing

- Episode ID, ordinal, page count and dimensions do not prove identical content;
  edited or reordered images can retain those properties.
- `last_modified` is present in the observed raw index. Neither its presence nor
  an observed equal value establishes a server-supported invalidation guarantee.
- The cached official reader treats `cpx` as a client compatibility version,
  with semantic-version comparison and reload behavior, not a content revision.
- Official `ReaderImage._imageName` is derived from a path basename and used for
  danmaku lookup. No stable image-identity guarantee was found. `bfsLink` performs
  URL/size handling; it is not a demonstrated decoder for the opaque locator.

The source review used the digest-pinned official reader and cached shared/vendor
sources described in [protocol research](../research/protocol/crypto-m2-image.md).
Relevant decoded-reader offsets are 983640/976437 for `_imageName`, 3094425 for
`bfsLink`, and 3272596/3273741/3274183 for compatibility-version handling.
No examined source established a durable per-image ID or content-version contract.

## Repair design retained from the original audit

1. Add an explicit asynchronous index-refresh operation for partial-download
   Resume or an explicit refresh retry. Automatic refresh requires a verified
   expiry classification. Deduplicate by account/episode and bound each recovery
   trigger to one refresh; stop with a useful error if the new attempt fails.
2. Separate immutable local content identity from a mutable acquisition mapping.
   Keep descriptor bytes/path, page IDs, pins and anchors unchanged when reliable
   evidence establishes the same content. Update only source addresses and a
   separate acquisition epoch in a main-process transaction. Retire old requests
   and reject late results from the old epoch; retain existing content/geometry
   generation checks and account/entitlement guards.
3. Require an actual server-supported content identity or a verified equivalence
   procedure before that in-place refresh. Do not implement revision as ordinal
   plus dimensions, or silently promote `last_modified`/`cpx` to that contract.
4. Without sufficient equivalence evidence, retain the old readable snapshot and
   require explicit replacement with a new immutable version. Keep old data until
   replacement succeeds; explicitly resolve old/new job, anchor and pin ownership.
   Reused bytes need independent target filenames or a proper reference-counted
   blob model. Unknown identity must not silently mix versions or reset progress.

## Acceptance targets retained from the original audit

- A complete pinned chapter reopens offline with the same descriptor and anchor,
  zero acquisition and no dependency on source-address validity.
- A partial resume with proven unchanged content rotates every source address,
  keeps ready files/checksums and identity, and downloads only missing pages.
- Expired token with valid source and expired source requiring a new index take
  distinct bounded paths; unclassified 400/403 does not create a refresh loop.
- Unknown identity or a real content/order change preserves R1 and requires the
  replacement path, even when count and dimensions match.
- Crash, cancellation or account change during refresh cannot commit stale work;
  journal recovery, pins and precise anchors remain consistent after restart.
- Replacement completion and removal resolve old pin ownership and never unlink
  another retained version's image. No purchase or wallet scenario is required.
