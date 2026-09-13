# Storage integration checks

Run these checks only through `ssh test-env`. They use the real `lua-ljsqlite3/init` binding and file system in an isolated official KOReader runtime. No runtime source files or global dependencies are modified.

The `root` option passed to both `Store.open` and `PageStore.new` is the already resolved account directory. Services owns the `accounts/<account_key>` path selection. An account identity marker prevents reopening a database as a different account. The SQLite connection is restricted to the process that opened it; workers and native thumbnail children must not use an inherited connection.

## Reproduction

Upload the production `bilicomics/storage` directory and this `spec/storage` directory to an isolated source directory. Recheck the runtime and fixture dependency paths before using the recorded example:

```powershell
ssh test-env 'python3 /tmp/bilicomics-storage-20260912/src/spec/storage/run_remote.py /tmp/bilicomics-native-_duimwe7/lib/koreader /tmp/bilicomics-storage-20260912/src /tmp/bilicomics-storage-20260912/new-output --pillow-root /tmp/bilicomics-native-_duimwe7/backend-probe/python-deps'
```

The output directory must be new. The isolated Pillow dependency is used only to generate synthetic JPEG/PNG/WebP and EXIF fixtures. Runtime modules do not depend on Python or Pillow. JSON results record individual assertions and subprocess exit codes.

## Covered behavior

- Real SQLite schema migration, WAL/TRUNCATE selection, safe parameter binding, transactions, nested savepoints, account isolation, durable jobs, purchase uncertainty, settings and precise anchors.
- Immutable canonical descriptors, independent content revisions, page completeness, SHA-256 verification, file format and EXIF checks, geometry generations and persistent content generations.
- Automatic eviction, durable pins, active-reader references, explicit removal, cancellation of pending commits, and stale worker generations.
- Actual SQLite read-only failures leave active-reader reference counts and page access timestamps unchanged.
- Journal-only recovery preserves unrelated open worker files, orphan files, descriptors and page state while acquiring new content.
- Process termination using `_exit(73)` after the durable journal, final rename and database commit. A subsequent independent process verifies and completes recovery exactly once.
- A corrupted interrupted acquisition is discarded. Injected transient rename, directory-sync and SQLite-write failures retain the verified file and recovery journal until a later attempt succeeds.
- A real SQLite `SQLITE_FULL` condition induced by `max_page_count` rolls back incomplete writes and preserves earlier committed data.
- Symlink parent rejection and a complete-chapter check detecting equal-length corruption with unchanged file timestamps.

## Integration requirements and limits

`PageStore:commitPage` accepts a worker-verified temporary file, a SHA-256 checksum, actual format, oriented logical width/height and optional geometry. Workers must finish and relinquish their file before the main process commits it. Main-process verification rechecks the digest, bounded format structure, source dimensions and EXIF orientation; it is not a substitute for worker-side image decode verification.

Capture `page.content_generation` when dispatching acquisition and provide it as `context.expected_content_generation` on completion. Also reject obsolete account/job results in the scheduler. Every journal records its base generation, and removal invalidates all pages, including unfinished ones.

Readers acquire `setActiveEpisode(episode_id, revision, true)` once and release it with `false` once. Calls are reference counted. Activation owns its database transaction and publishes its in-memory reference only after a successful commit; an activation inside an existing transaction is rejected. Release does not require a writable database.

`recoverPendingCommits()` returns `{recovered, recovered_pages, discarded, remaining, errors={{key,message}}}`. `recovered_pages` contains committed page records that the caller can use for ordinary page-ready notifications after the method returns. It only processes persistent recovery journals and their exclusively owned image files, performs no directory sweeps, and never starts network work. Call it from the main process before resuming a failed commit while other workers continue writing unrelated files. It rejects invocation inside an existing transaction. Invalid or canceled journals are discarded without deleting their files; startup cleanup will remove these unreferenced files. Recoverable operation failures retain the journal and its files and contribute to `remaining` and `errors`. Check remaining journals for the target chapter before dispatching new acquisition; another chapter's pending journal must not block unrelated work.

If an old ready file disappears during replacement recovery, corruption invalidation atomically advances both its missing-page generation and the still-current replacement journal. This preserves the already verified replacement while forcing fresh reader cache identities. Explicit removal first deletes the journal and remains a cancellation.

`evictToLimit(bytes)` protects active, pinned and interrupted-commit content. `removeEpisode` preserves descriptors and anchors and requires the chapter to be inactive. Run `reconcile()` only before starting workers; it reuses journal recovery and then removes abandoned temporary files that are not protected by a recovery journal. It is unsafe during active acquisitions.

`isComplete` verifies every image checksum, including same-size, same-timestamp changes. Ordinary `getPage` calls cache verification against file metadata for rendering. Checking many downloaded chapters therefore performs disk reads proportional to their compressed content size; aggregate UI refresh frequency should remain bounded.

Complete-chapter checks read the row directly and perform one forced file check,
avoiding a second cold checksum through `getPage`. The current UI aggregate
getters use metadata and do not call this full-file check. The 24 MiB remote
comparison in `spec/performance` confirmed one checksum pass per image and no
digest calls from the measured UI getters. The updated storage run retains all
128 assertions, including equal-size, equal-timestamp corruption detection.

The tests validate process-crash windows, not actual power-loss behavior. The implementation checks file and directory `fsync` results, including newly created directory levels. Device-specific filesystem durability, filesystem-wide disk-full behavior, live Bilibili acquisitions, and real e-ink performance remain release-integration work.
