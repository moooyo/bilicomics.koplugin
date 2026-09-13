# Native business UI verification

`bilicomics/ui/screens.lua` exports `Screens.new({ controller })`. Its public screens match the development contract. `refresh()` repaints local state without changing navigation, selection, or purchase state. All network-bearing actions use the injected asynchronous controller; no network module is imported by the UI. Cached cover paths are optional, and unavailable covers display the actual comic title in a native book-cover frame.

The additional controller operations include `getPendingPurchases()`, `removeDownload(job_id, callback)`, `lookupComicID(input, callback)`, `resolveReadingEpisode(comic_id, callback)`, `setFavorite(comic_id, favorite, callback)`, and `getDiagnostics(callback)`. Deleting an offline chapter needs an explicit dialog confirmation. The controller owns current-reader protection and preserves purchase rights and reading anchors. The settings keys used by this UI are `prefetch_pages`, `cache_limit_mb`, `search_history`, `reading_mode`, and `reading_direction`.

Following cards keep the title linked to details and add a direct reading action without increasing row height. The controller resolves an unknown catalog and the correct next chapter; a locked target opens the explicit quote dialog. Comic details show Follow/Unfollow and disable repeated clicks while confirmation is pending. Download selection uses `offline_allowed`, falling back to free/owned access only when that field is absent; online-only temporary access is not selected. A separate ID dialog leaves ordinary numeric title searches unchanged and ignores obsolete lookup results.

Reader defaults and local diagnostics use independent native dialogs so the account screen stays usable at 480 by 640. Diagnostics explicitly distinguish local checks from server verification. Cover rendering reads a bounded image header and checks the shared pixel policy before constructing an ImageWidget, including for previously cached files; rejected covers use the existing title placeholder.

Locked chapter rows provide a separate Buy then download action. It quotes the selected single chapter and displays the intended continuation before payment confirmation; it neither changes multi-selection eligibility nor offers a batch purchase in this flow. The controller receives `purchase(quote, purpose, callback)`. Pending transactions restore their persisted purpose, even when reopened from a different action. After durable access confirmation, only an explicit Read chapter or Download chapter action continues the original selected chapter. Download failures retain confirmed access and offer Retry download without requesting a new quote. Closed dialogs, changed accounts and obsolete payment selections cannot activate old confirmation or continuation callbacks. A result with `transaction_evidence="server_accepted"` may say Purchase confirmed; entitlement-only evidence says Chapter access confirmed.

Production localization uses English message IDs with a private Chinese translation table in `l10n/bilicomics_zh_CN.lua`. It does not overwrite KOReader's global gettext translations. English remains the fallback for other locales. Production code contains no demonstration comics, wallet amounts, purchase results, cover art, or reader content.

Session import retains the masked paste input and adds Import from file in both the account controls and paste dialog. The native FileChooser navigates folders and accepts a clicked `.txt`, `.json` or `.cookies` file. Its file list is independent of book reading-status filters. `session_input.lua` rejects nonregular files, final symlinks, empty/binary input and files larger than 128 KiB, verifies the opened file identity, and reads at most 128 KiB plus one byte before rejecting growth. It returns fixed error categories without paths or content. The unchanged Controller parses and validates the selected content, including a UTF-8 BOM and supported browser/Netscape exports. Navigation, cancellation and account generations retire unsubmitted selections and obsolete feedback. Closing a validation status does not undo the import already explicitly dispatched by the selected file.

## Focused session-file import verification

`session_import_spec.lua` exercises real native FileChooser/InputDialog widgets and the production Controller, Session parser and SQLite storage with synthetic files. Its controlled runner accepts only `validateSession`; unrelated payment, quote and wallet methods fail immediately if called. The test does not access a real session file or the Bilibili service.

The focused runs passed 42 assertions each at 600 by 800, 480 by 640 and 1860 by 2480. They cover plain text, UTF-8 BOM, JSON and Netscape exports, the 128 KiB boundary, oversized/directory/link/FIFO/binary rejection, native cancel and folder navigation, successful validation and local persistence, private errors, account changes, closed dialogs and feedback layering. `session-import-result*.json` records these results and `screens/session-file-*.png` contains the native screenshots. The largest framebuffer matches the Scribe screen dimensions for layout inspection; it is a Linux emulator run, not evidence of Kindle hardware or firmware compatibility.

Run this focused harness only through the authorized remote host, with a fresh output directory:

```powershell
ssh test-env 'python3 /tmp/bilicomics-session-file-import/plugin/spec/ui/run_session_import.py /tmp/bilicomics-native-_duimwe7/lib/koreader /tmp/bilicomics-session-file-import/plugin /tmp/bilicomics-session-file-import/new-import-output --width 600 --height 800'
```

The broad native probe below predates the file-import addition. It was not rerun during this task because its scenarios include purchase flows, which were outside the authorized verification scope.

## Native probe

`native_probe.lua` constructs actual KOReader widgets under Xvfb, registers them with `UIManager`, repaints the actual screen stack, and saves framebuffer PNGs. The injected controller uses synthetic records and delayed callbacks to exercise navigation, selection, account settings, private session input, purchase confirmation, server-priced batches, insufficient balance, pending-result persistence, result reconciliation, and stale callback dismissal. It deliberately does not make network requests or spend account assets.

Run only through the authorized remote environment, after uploading the plugin to its isolated workspace:

```powershell
ssh test-env 'python3 /tmp/bilicomics-ui-implementation/plugin/spec/ui/run_native.py /tmp/bilicomics-native-_duimwe7/lib/koreader /tmp/bilicomics-ui-implementation/plugin /tmp/bilicomics-ui-implementation/output'
ssh test-env 'python3 /tmp/bilicomics-ui-implementation/plugin/spec/ui/run_native.py /tmp/bilicomics-native-_duimwe7/lib/koreader /tmp/bilicomics-ui-implementation/plugin /tmp/bilicomics-ui-implementation/output-480 --width 480 --height 640'
```

The harness provides separate XDG directories and does not modify runtime source or global dependencies. The recorded runs passed 98 assertions each at 600 by 800 and 480 by 640. `result.json` and `result-480.json` record the results; `screens/` contains 21 base framebuffer images and compact-screen examples. Screen and modal bounds are checked, including the locked-chapter download action, single/batch confirmation with its continuation label, and a failed download after confirmed access. A real 6-megapixel PNG fixture is rejected before any ImageWidget constructor runs. These probes establish native UI behavior with an injected controller. They do not establish current Bilibili protocol support, real account acquisition, real purchases, real cover downloading, or physical e-ink device behavior; those belong to integration and device acceptance.
