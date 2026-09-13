# Source Refresh Proof Storage

`bilicomics/storage/source_refresh.lua` provides a metadata-only admission and
transaction layer. It performs no acquisition or image hashing. The coordinator
must obtain proofs from the real verification worker, freeze same-actor writers,
and validate account, permission and operation lifetimes.

## API

- `fileIdentity(path, root)` returns `{dev, ino, size, modification, change}` or
  `nil, error`. The root must be absolute; linked ancestors, linked path entries
  and non-regular files are rejected. `sameFileIdentity(a, b)` compares all five
  required numeric fields. Metadata comparison does not replace worker SHA checks.
- `capture(pages, episode_id, revision)` returns a basis or a structured error.
  It reads the real descriptor metadata, exact page records, file identities,
  anchor, pin and relevant download-job state. The chapter must be closed, its
  downloads inactive, and its revision free of pending commit journals.
- `validateIndex(basis, index)` returns the complete ordered source-path array.
  It requires the same episode, count, explicit page order and original declared
  dimensions, plus unique nonempty paths. Locator-derived IDs/revisions are not
  treated as proof of stable server content identity.
- `adopt(pages, basis, index, proofs)` rechecks the basis inside one SQLite
  transaction and updates only each page's `extra.source_path`, incremented
  `source_generation` and historical `expected_source_checksum`. It returns
  `{episode_id, revision, updated_pages, verified_pages, source_generations}`.

`basis.pages[i]` contains `record`, `history` (`committed` or `never`), an expected
historical `checksum` when applicable, and `reference_identity` for a retained
ready file. The basis also contains `descriptor`, `path`, `descriptor_bytes`,
`descriptor_identity`, `root`, `account_key`, `episode_id`, `revision`, `anchor`,
`pinned` and stripped job guards. Job guards include ID, revision, state and run
generation; display/progress payload and timestamp changes do not invalidate them.

Pass the original captured basis object back to the same PageStore. The module
seals it privately against caller mutation and cross-instance use. Successful
adoption consumes it. A failed proof may be retried only while its original
basis remains unchanged; reopening storage requires a fresh capture.

`proofs[i] = {checksum, reference_identity}` is required for every historically
committed page, including pages whose files were evicted. Ready references need
the identity verified by the worker before/after hashing; it must still match at
adoption. Never-committed pages require no proof and cannot receive a fabricated
history entry through this API.

Unknown legacy history returns `unknown_history` before acquisition. A precise
anchor on a never-committed page returns `unverified_position`; an unambiguous,
unrotated chapter-start zero anchor is allowed. No position is reset or invented.
Other native document-position metadata remains the coordinator's responsibility.
Topology/digest/proof conflicts use `content_changed`; changed basis uses
`stale_source_refresh`; active work or journals use `busy`; filesystem/SQL errors
use `storage`. Every error includes an English message, code and `retryable=false`.

## Focused remote evidence

[source-refresh-results.json](source-refresh-results.json) records 47 cases and
855 passing assertions on official KOReader v2026.07.1 with real SQLite and
synthetic PNG files, executed through `ssh test-env` in a network namespace.
Only `source_refresh_spec.lua` ran; the core storage suite did not run.

Coverage includes ready/history/never success, database reopen, repeated epochs,
zero-ready historical proofs, unknown legacy rows, anchor admission, topology
and SHA rejection, file replacement, page/descriptor/anchor/pin/job guards,
relevant versus unrelated work, and a second-page SQL failure that rolls back
the first real write and remains rolled back after reopening SQLite.
`Files.digest` is disabled during metadata API calls to verify that they do not
hash image data. Independent test snapshots check complete file bytes and all
relevant stored records outside that API boundary.

The standalone launcher generates its own fixture and records staged source and
runtime hashes. Run only on the authorized remote host with a fresh work path:

    python3 run_source_refresh.py --runtime /path/to/official/koreader --source /path/to/source --work /tmp/new-source-refresh-run

The recorded output is `/tmp/bili-source-refresh-nM9kWHCP/run1`. These results
prove the storage layer, not the separate worker's hashing or the coordinator's
network/cancellation/UI behavior. No purchase scenarios were executed.
