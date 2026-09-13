# Native version replacement UI

`version_replacement_spec.lua` exercises actual KOReader widgets with a strictly allowlisted fake controller. It forbids production Controller, Runtime, Client, Transport and purchase-service loading. No account/session, quote, wallet, purchase or network operation is performed. The recorded SSH run passed 144 checks at each of 600x800 and 480x640; results are in `version-replacement-result.json` and `version-replacement-result-480.json`. Fourteen base screenshots and compact-screen examples are in `screens/version-replacement/`.

Retained partial jobs expose Recovery options or Failure details. The dialog keeps source verification available and adds Redownload as new version. Explicit confirmation describes a full download, additional storage/network use, a new reading position from the beginning, and the old cache/position retained in a separate version row. Opening or canceling confirmation does not dispatch an operation. Confirmation rechecks the latest job, preventing simultaneous source verification and version preparation.

The controller contract is `replaceDownloadVersion(job_id, callback)`, `cancelVersionReplacement(job_id)`, and `readDownload(job_id, callback)`. `payload.version_replacement` shows Preparing new version and Cancel preparation. A successful controller result supplies the new queue state through ordinary getters. New jobs reference `payload.replaces_job_id`; the former job references `payload.replaced_by` and is displayed as Older version retained. That row only offers Read retained version and Remove download. Both retained and complete current downloads read by exact job ID, preserving revision selection. Older versions are excluded from the active/complete filters and pending-download count.

Checks cover confirmation/cancellation, duplicate and obsolete callbacks, preparation progress, exact old-job reading/removal, new-job preservation, account changes, source-verification controls and mutual exclusion, and direct recovery choices after `unknown_history`, `content_changed` or `unverified_position`. The new `version_replaced`, `source_unavailable` and `version_replacement_interrupted` errors have fixed Chinese messages without raw paths, URLs, tokens or SDK output. Each action row stays within four buttons; dialogs fit both native screen sizes and remain above the underlying screen.

These are UI behavior checks with synthetic job transitions. Real descriptor creation, retained-version grouping, byte preservation, atomic job linkage, exact native reopening and download execution are separate coordinator/storage/controller integration responsibilities.

Run only in the authorized remote environment with a fresh output directory:

```powershell
ssh test-env 'python3 /tmp/bilicomics-version-replacement-ui/plugin/spec/ui/run_version_replacement.py /tmp/bilicomics-native-_duimwe7/lib/koreader /tmp/bilicomics-version-replacement-ui/plugin /tmp/bilicomics-version-replacement-ui/new-output'
```

The passing output is `/tmp/bilicomics-version-replacement-ui/replacement-1/`. The existing source-recovery UI regression also passed 159 checks per size in `source-regression-1/`. All data and XDG directories were isolated, and the official runtime remained unchanged. No local WSL window, profile or helper was accessed.
