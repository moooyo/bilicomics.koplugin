# Explicit local version replacement

`bilicomics/storage/version_replacement.lua` publishes an independent local
snapshot after the user explicitly requests a replacement download. It never
uses an index's transient revision or page identifiers as the new local
identity, copies old images, or migrates an old reading anchor.

## API

```lua
local basis, err = Replacement.capture(pages, old_job_id)
local result, err = Replacement.publish(pages, basis, normalized_index)
-- result = { job, descriptor, path, replaced_job_id }
```

`validateIndex(basis, normalized_index)` is also available for an early index
shape check. The coordinator must pause the selected job before capture. Its
optional `payload.version_replacement` marker must already be persisted because
the selected job, including its payload, is part of the captured comparison.
The new job is published paused; the coordinator decides when to resume it.

Capture and publication own their outer SQLite transactions. The basis is tied
to the same PageStore instance and sealed privately against caller mutation;
successful publication consumes it. A canceled or changed operation must obtain
a new basis. The API performs metadata reads, including the small descriptor
file, but no image hashing, image decoding or network operations.

The checks reject active readers of any version of the chapter, queued/running
chapter jobs, pending chapter commits, source verification, competing replacement
markers, retired or removed selected jobs, and invalid chapter identity. Local
offline rights are rechecked at capture and publication. The coordinator remains
responsible for obtaining fresh server metadata before publication; this module
cannot attest that a stored permission was recently fetched.

The comparison covers the selected job and same-chapter jobs, descriptor bytes
and file identity, old page records and ready-file metadata, stored anchor, old
pin and local revision/progress markers. Fresh catalog title/access updates are
allowed when offline permission remains valid. Unknown historical image digests
and a precise old anchor on an unverified page do not block a new independent
version, because no old content or anchor is adopted.

## Atomic publication

A transaction-local account counter allocates `local-snapshot-N` and
`version-download-N`. Occupied descriptor/job/page/anchor/pin identities and
existing version directories, including failed preparation remnants, are
skipped. This also avoids reusing a directory with native sidecar settings.
The normalized index must contain a bounded dense ordered list with matching
chapter identity, positive integer dimensions and unique nonempty source paths.
Its topology may differ from the old snapshot.

One outer transaction publishes:

- A new descriptor and entirely missing pages, each with independent local page
  identity, zero generations, its new source path and `content_history_version=1`.
  No old digest, expected source checksum, image path or geometry cache is copied.
- A pinned, paused job with `payload.replaces_job_id` naming the selected job,
  and a persistent pin for the retained old version. An old unpinned snapshot
  becomes pinned only when the entire publication commits successfully.
- Cancellation and `payload.replaced_by` for every retained job of the old
  revision, clearing their replacement markers and advancing run generations.
  Removed siblings and other revisions remain unchanged.
- New `current_revision`, `local_revision` and `source_replacement_revision`,
  `progress_source="local"`, cleared `local_finished_at`, and `read=false`.

Old descriptors, pages, Store/native anchors and comic-level progress are not
rewritten. Failed publication preserves the original old pin, including false;
successful publication pins both versions so subsequent downloads cannot evict
the retained old files automatically. Catalog isolates the new revision from old
progress fallback. No new stored or native anchor is created.

Descriptor preparation uses the existing PageStore filesystem contract inside
the outer transaction. A later error may leave an unreferenced descriptor file,
but all database publication rolls back together. Reconcile and Catalog enumerate
database descriptors, so that file is not selected as a version. A retry skips
its directory and creates another namespace with new never-downloaded history.
This module deliberately does not delete failure remnants or old user data.

## Focused verification

`version_replacement_results.json` records **32 cases / 395 assertions**, all
passing on official KOReader v2026.07.1 at
`/tmp/bili-version-replacement-lj5rV8pY/run3/results.json`. The copied source was
unchanged during execution. The test uses actual SQLite, PageStore, Catalog and
native DocSettings with synthetic PNG bytes in an isolated `unshare -n` process.
No account session, worker, purchase, quote or wallet scenario is executed, and
the local workstation/WSL reader is untouched.

Coverage includes changed topology, identical service-index repetition, all old
job siblings, unpinned and unknown-history records, old Store/native anchors,
fresh permission changes, malformed indexes, stale local state, chapter activity
and source/commit races, namespace collisions, and two real SQLite trigger
failures (second new page and final episode update). The final-update failure
starts with an unpinned old version and verifies rollback keeps it unpinned;
successful publication explicitly upgrades that pin. A separate filesystem fault
after descriptor preparation proves the same rollback/restart/retry behavior.

The first run exposed a Lua multiple-return interaction when `Files.parent` was
passed directly to `lfs.symlinkattributes` for an existing directory. The module
now assigns the directory first. The trigger fixture also uses one prepared SQL
statement because this SQLite binding's convenience `exec` splits semicolons.
Neither issue is present in the final passing snapshot.

```sh
python3 spec/storage/version_replacement_remote.py \
  --runtime /tmp/bilicomics-native-_duimwe7/lib/koreader \
  --source /absolute/frozen/source \
  --work /absolute/new/isolated/work
```
