# Native download source recovery UI

The focused `download_recovery_spec.lua` exercises actual KOReader widgets with an allowlisted, asynchronous fake controller. It does not load the production Controller, Runtime, protocol transport, client or purchase service. Only download-state getters and explicit download controls are available. No network request or monetary operation is executed, and the broader native UI probe is not run.

The final remote run used the unmodified official KOReader v2026.07.1 runtime and passed 159 checks at each of 600x800 and 480x640. Results are in `download-recovery-result.json` and `download-recovery-result-480.json`; `screens/download-recovery/` contains 19 base screenshots and compact-screen examples. Each download action row has at most four buttons. Screen and dialog dimensions, native stacking and safe localized text are checked. Paused/canceled jobs now use Recovery options to reach explicit source refresh; this source-only fixture leaves the optional version-replacement API unavailable.

Coverage includes explicit source-refresh confirmation, cancellation before dispatch, prevention of repeat confirmation, index and historical-image progress, cancellation during verification, removal after a separate confirmation, successful controller-reported resumption, HTTP 400 without automatic source refresh, and obsolete account/closed-screen callbacks. Seven typed failures have specific Chinese messages without raw URLs, paths or SDK text: `content_changed`, `unknown_history`, `unverified_position`, `reference_changed`, `stale_source_refresh`, `source_refresh_interrupted`, and `busy` with `code="chapter_active"`.

The UI explains that previously saved images are downloaded again for verification and that the existing cache and reading position are retained. Unknown or different content does not apply refreshed sources. Source verification never silently switches versions; the separate explicit new-version workflow is covered in [version-replacement.md](version-replacement.md). The actual byte verification, source adoption, account isolation and job resumption remain Controller/storage/worker integration responsibilities; this UI fixture does not establish those service results.

Run only on the authorized SSH host with a fresh output directory:

```powershell
ssh test-env 'python3 /tmp/bilicomics-version-replacement-ui/plugin/spec/ui/run_download_recovery.py /tmp/bilicomics-native-_duimwe7/lib/koreader /tmp/bilicomics-version-replacement-ui/plugin /tmp/bilicomics-version-replacement-ui/new-source-output'
```

The latest passing output is `/tmp/bilicomics-version-replacement-ui/source-regression-1/`. Every run uses isolated XDG directories and leaves the installed runtime unchanged. The running local WSL acceptance application and its profile were not accessed.
