# Reading and download completion audit

Original audit date: 2026-09-12. Status update: 2026-09-13. The bounded audit read
[implementation-plan.md](implementation-plan.md), [ui-spec.md](../design/ui-spec.md),
the then-current source and existing result/source records. This document-only
update runs no test, target, account operation or local WSL process. The detailed
M0/M3 review and physical-device acceptance remain outside this reading audit.

The core reading and retained-download paths are implemented. The original
audit found two omissions in its fixed package snapshots: temporary entitlement
expiry was not displayed, and direct download/resume lacked the connectivity
gate already used by reader acquisition. They are preserved below. This is not a
claim that M1/M2 or the full first release has passed every acceptance case.

The two omissions above describe the fixed archive snapshots audited below.
The subsequent [connectivity correction](download-connectivity.md) now has 25
focused passing cases, and the [expiry display correction](entitlement-display-update.md)
has 132 passing checks at each of two native UI sizes. These are bounded reading
results; their package binding and original live/device limitations remain
separate. The requirement matrix is retained as the pre-correction audit record.

As of 2026-09-13, the user permits all operations except actual purchasing.
Authenticated quote/wallet observations and isolated synthetic checks have
executed; see the [non-purchase integration report](nonpurchase-integration-report.md).
Standard coin/no-extra-discount positive and remaining ordinal ranges are now
implemented and have [real production construction from authenticated read data](../research/protocol/ordinal-range-live-result.json).
The [ordinal-range contract](ordinal-range-contract.md) retains
`server_confirmed_ids=false`; extra discounts remain advisory. Real BuyEpisode
HTTP calls/purchases remain zero, and actual charging and Scribe acceptance
remain unverified. These later facts do not relabel the earlier reading
snapshots as newly executed full application or physical-device acceptance.

## Snapshot and evidence boundary

The then-default 91-file reading archive is recorded as SHA256
`b7b27290dda31834d593bd0e4234079602f807e7093be5b396d78d18a35691b4` in
[audited provenance](../spec/package/source-evidence-before-connectivity.json). Its preceding
[Lua provenance](../spec/package/source-evidence-before-arm.json) binds the
reading modules and UI to the 19-scenario version integration and native UI
snapshot. The subsequent six-file ARM update preserves all Lua bytes.

The 95-file quote preview is recorded as SHA256
`37127a655a2da25417cb29a8a6871a0ea8de78a97e328f1a2807bc5d8e8a537e` in
[audited preview provenance](../spec/package/quote-preview-source-evidence-before-connectivity.json). Its
Controller, Worker, Client, Screens and Model differ from the default reading
archive; the changed Lua has [syntax-only provenance](../spec/package/quote-preview-source-evidence-before-arm.json).
At the original audit, the workspace matched that preview for the inspected
files. Shared reader, storage, Catalog, Runner and DownloadService bytes matched
between those two archives. The syntax-only label belongs to that earlier
snapshot, not to all later quote verification. Neither packaging nor syntax
alone established the preview's complete reading UI behavior. Source references
below name functions in the audited workspace; the table is a historical
package/evidence comparison, not a claim about today's entire workspace.

Static archive-byte comparisons, without executing any Lua, confirmed these
default-package hashes against
[version integration](../spec/integration/version-replacement-workflow-results.json):

| Module | SHA256 in the default reading archive |
| --- | --- |
| reader/document.lua | `c9ae3202c1c3a9d6f6951a749b723cc06af8ff2b48e1e6ad306f784973db426c` |
| reader/integration.lua | `9f2d8d10ba6ccc16a7e7c8e66114a938391791c0edbb4426f12432e2756af8ce` |
| reader/defaults.lua | `ffa7a3720532a5d3088591ea257c636366e0bd36ab8273e24f1dda89ce188a24` |
| controller.lua | `b0666af44dd3832ebb4447cd350682f2ff79130e5741882105055b41b42b9b20` |
| jobs/download_service.lua | `264f0fccb41ecda611d4c11d91275df148c9f292b128a5d873c119e9aca70d21` |
| jobs/runner.lua | `f13c95c384fed95a6e672a1343bb915e90a0695f57a27ff17ac3fb89833cce27` |
| jobs/worker.lua | `30cd38440c7f39cecff279626144d228d14bbe8eb3c561a1d86b955c2a72bbb5` |
| catalog/init.lua | `ae9e63930089c69a13cdda563f9eaccc12c5346c9608b946cdfcf9238be4a2b3` |
| storage/page_store.lua | `8c672b632d8e228f1e536c14321743fb49596c60b8f482c061158cf40701833a` |
| storage/store.lua | `59c45d65d134369dacd3dfc55a52ea9a4d74f22e06a1bd1e4607e7b5e0fcec38` |

The reader document, geometry, anchors, integration, defaults and compatibility
files also match the earlier live reading result's production hashes. The
Controller/Worker/storage files changed after that live run; the live run must
not be represented as a fresh full-account run of today's whole package.

## Requirement matrix: original package snapshots

“Implemented” means the concrete source path exists. “Observed” names the scope
of an existing result, not universal coverage. Broad historical reports may
contain other scenarios; this audit only reads their relevant assertions and
does not execute them or extend current authorization.

| Requirement | Source | Existing evidence | Status |
| --- | --- | --- | --- |
| M1: account-scoped state, immutable descriptor and durable page generations; plan §§5/6.1 | [Store](../bilicomics/storage/store.lua), [PageStore](../bilicomics/storage/page_store.lua) `ensureDescriptor`, `commitPage`, `reconcile`; [Document](../bilicomics/reader/document.lua) `init/getPageGeneration` | [Storage history](../spec/storage/remote-results.json); [source proof](../spec/storage/source-refresh-results.json), 47 cases/855 assertions; [version publication](../spec/storage/version_replacement_results.json), 32/395; current-package version integration hashes above | Implemented. Atomic publication, recovery and old/new identity separation have focused real-SQLite evidence. |
| M1: native MuPDF image ownership, JPG/PNG/WebP, DPI/orientation and bounded decoding; plan §§6.1/6.2 | [ImageBackend](../bilicomics/reader/image_backend.lua), [Geometry](../bilicomics/reader/geometry.lua) `new/plan`, [image headers](../bilicomics/storage/image_header.lua) | [Native results](../spec/reader/native-results.json), 314 assertions across render/UI/reopen/thumbnail phases; [real-image local results](../spec/integration/real-image-local-results.json), 54 checks | Implemented with explicit supported-format/size limits. Real acquired JPEG pixels were rendered; the format/DPI/orientation matrix is synthetic/local evidence, not a live image-format matrix. Oversized unsupported images are refused, not silently claimed readable. |
| Native page/width/continuous defaults, LTR/RTL, saved user settings; plan §6.3 and UI native context | [Defaults](../bilicomics/reader/defaults.lua) `capture/apply/save`, [main](../main.lua) `onDocSettingsLoad`, Screens `_readerDefaults` | [Defaults](../spec/reader/defaults-results.json), 247 assertions; [regression](../spec/reader/defaults-regression-results.json), 314; Android integration includes auto/LTR and saved-mode reopen | Implemented. Native saved settings and anchors take precedence; normal comics and strips have distinct defaults. No replacement reader control system is required. |
| Settled progress, pan/continuous resume, close/suspend save and geometry-correction restore; plan §§6.2/6.3 | [Anchors](../bilicomics/reader/anchors.lua), [Integration](../bilicomics/reader/integration.lua) `scheduleSave/saveAnchor/notifyPageReady/close` | Native/default reopen phases; [live reading](../spec/integration/live-reading-results.json) offline source-anchor restoration; current version integration exercises old/new native reading | Implemented. Precise progress remains local and revision-specific; it is not inferred from a remote chapter history entry. |
| Open before full download and repaint arriving images without replacing document identity; plan §3.2/M2 | Controller `prepareEpisode/readEpisode/_openPrepared`; Document `renderPage/drawPage`; Integration `notifyPageReady` | Live run: 51 online checks, reader open before first image, placeholder replaced and same descriptor retained; [synthetic integration](../spec/integration/remote-results.json), 65 checks | Implemented and observed with actual ReaderUI/fork/Worker. The live result covers one complete free chapter, not arbitrary accounts or catalogs. |
| Visible-page priority, deduplication, upcoming images and readable next-chapter prefetch; plan §7 | Controller `_requestReaderPage/_prefetchConfigured/_preloadNext`; DownloadService `requestPage`; [Runner](../bilicomics/jobs/runner.lua) `_pump/promote` | Live next-image prefetch; [prefetch policy](../spec/controller/prefetch-result.json), 33 controlled checks; [source workflow](../spec/integration/source-refresh-workflow-results.json), real priority preemption | Implemented. Zero/disabled counts and stale reader/account/retired-version boundaries are checked. No prefetch path authorizes purchase. |
| Generation-aware rendering and local-only thumbnail handling; plan §6.4 | Document `getFullPageHash/getPagePartHash/hintPage`; [Compatibility](../bilicomics/reader/compatibility.lua); Integration `notifyPageReady` | Native render/thumbnail assertions include generation changes and rejection of corrupt/missing thumbnail results | Implemented. The historical native matrix is not independently hash-labelled, but the packaged reader files match later hash-labelled live and version integrations. |
| Same descriptor/provider for complete offline reading, no login/token/catalog/geometry request; partial gaps remain explicit; plan §3.3 | Controller `readEpisode/readDownload/authorizeDescriptor`; Document local page access | Live offline phase: 30 checks, 45 pages, no session, no routes, zero transports/workers; synthetic owned chapter offline reopen; historical Controller partial-gap assertions | Implemented and observed. A complete live already-owned chapter was not downloaded in this evidence; owned images have separate sample and synthetic chapter coverage. |
| Complete ordered catalog, fractional special chapters, three state axes, filters/current shortcut; plan §3.1 and UI chapters | [Catalog](../bilicomics/catalog/init.lua) `ingestDetail/getEpisodes`; [Screens](../bilicomics/ui/screens.lua) `_comic/_chapterRow`; [Model](../bilicomics/ui/model.lua) | [Catalog](../spec/controller/catalog-result.json); [product features](../spec/controller/product-features-result.json), including fractional next chapter; native UI historical selection/layout assertions | Implemented. Catalog normalizes stored `finished/in_progress` into the UI's `complete/reading` values; these are not missing reading states. |
| Independent multi-chapter download selection, locked exclusion, selected count and cached-page reuse; UI chapters and plan §3.3 | Screens `_chapterRow/_comic`; Controller `downloadEpisodes` validates the entire entitlement selection before enqueue; DownloadService `enqueue/requestPage` | UI assertions `locked_and_online_only_chapters_never_selected` and `selection_dispatches_exact_ids`; synthetic 65-check integration downloads multiple chapters and reuses the online descriptor | Implemented. Selected chapters are individual durable jobs; the plan does not require the selection to become one atomic monetary or download transaction. |
| Download image counts, pause/resume/cancel/retry/remove and separate complete content; plan §2/UI Downloads | Screens `_jobRow/_downloads/_downloadRecovery`; Controller job methods; DownloadService `_run/pause/resume/recover` | Historical jobs tests plus current 14-scenario recovery and 19-scenario version integrations; [recovery UI](../spec/ui/download-recovery-result.json), 159 checks per size; [version UI](../spec/ui/version-replacement-result.json), 144 per size | Implemented, except the direct offline-resume dispatch gate described below. Partial reading remains available through the chapter route; complete and retired jobs also expose direct reading actions. |
| Connectivity available before network resume; plan §7 | Controller `resume` and reader request paths check `_connected`; direct `resumeJob/downloadEpisodes` enter DownloadService without that callback | Existing prefetch/auth/suspend tests prove their own gates. The audited DownloadService constructor has no connection predicate; no existing result proves the missing direct-download gate | **Implementation gap.** A valid session plus a prepared partial chapter can reach `runner:submit(download_page)` from a Downloads Resume click while disconnected. Static reachable path, not a new executed reproduction. |
| Existing temporary rights: type, expiry, online/offline terms; plan §2/§3.3 | Catalog `access/ingestDetail/getEpisodes`; Controller `authorizeDescriptor/readEpisode`; Document `checkAuthorization`; Model `entitlement` | Historical Controller assertions cover temporary online reconfirmation and expired descriptor rejection; Catalog test covers expiry/absence of a permanent offline badge | Enforcement is implemented conservatively: ordinary temporary access remains online-only, with fresh process-local online grants. No live temporary entitlement or server-authorized temporary offline contract is proved. **UI gap:** expiry is persisted but not displayed. |
| Reader close keeps explicit work; app exit/suspend pauses; workers reap and standby holds balance; plan §7 | Controller `_readerEvent/suspend/_closeAccount`; DownloadService `releaseReader/suspend/close`; Runner terminal paths | Live run completed 43 pages after reader close, with 42 new image workers; actual-fork source workflow checks cancellation/suspend/preemption; version workflow includes account close/switch | Implemented and observed within the stated process lifecycle. Restart recovery intentionally leaves jobs paused for explicit resume. |
| Cache limit/headroom, pinned and active retention, clear automatic cache, low-space pause; plan §7/UI Account | [Settings](../bilicomics/settings.lua), [Budget](../bilicomics/jobs/storage_budget.lua), PageStore `_protected/evictToLimit`, DownloadService `_ensureSpace`; Screens `_account` | Historical budget/storage checks; current recovery/version workflows verify transient leases and old/new persistent pins; [getter measurements](../spec/performance/cache-getters-results.json) | Implemented. Cache bytes and retained totals are displayed; unsupported storage pressure has an actionable pause/error path. |
| Stable account identity, validate/replace session, stale completion isolation; plan §2/§5 | Controller `importSession/_openAccount/_closeAccount/_invalidateAuthentication`; [SessionStorage](../bilicomics/session_storage.lua); Screens import/file import | [Authentication](../spec/controller/authentication-result.json), 26 checks; historical Controller account isolation; current version workflow account-switch case; [session-file UI](../spec/ui/session-import-result.json), 42 checks per size | Implemented. Identity survives a changed cookie; Android stores sessions privately. These are synthetic/local isolation checks plus the earlier real session validation, not new account access in this audit. |
| Continue/Following/history/search/details, direct ID lookup and source position; UI navigation | Catalog library/current-progress methods; Screens `_library/_comicCard/_search/_lookupComicID`; Controller `resolveReadingEpisode` | Catalog and product-features results; actual native UI fixtures; earlier guarded real favorites/history/catalog calls | Implemented. Following update state is separate from local source progress; recent search state is account-scoped. |
| Native chapter boundary/menu and return to the plugin library; plan §§3.1/6.4 | Integration `onEndOfBook/finishTransition`; Controller `_chapterBoundary/showReaderMenu`; main `onShowBiliComics` | Native interception tests and historical Controller chapter-end assertions; installed startup/cold-open records | Implemented. Catalog, current download and Downloads use the compact chapter menu; the standard BiliComics main-menu item directly returns to Continue. No missing return path was identified. |
| Source expiration/content change recovery without corrupting retained content/progress; plan §5/§7 | [SourceRefresh](../bilicomics/storage/source_refresh.lua), [VersionReplacement](../bilicomics/storage/version_replacement.lua), corresponding jobs coordinators, revision-aware Catalog/Store | Source workflow: 14 scenarios/185 assertions/44 starts; version workflow: 19/258/58; source storage 47/855; version publication 32/395; progress isolation 13 groups | Implemented with explicit proof or independent replacement, rather than guessed identity from dimensions. Current package binding covers the version workflow. Actual service locator expiry was not observed, so that occurrence is not claimed. |
| Cold start through the actual plugin and safe fallback when patches are disabled; M1/native identity | [Bootstrap](../bilicomics/bootstrap.lua), bundled managed patch, main ReaderReady/FlushSettings hooks | [Production startup](../spec/reader/production-startup-results.json), [fallback](../spec/reader/fallback-results.json), [Android installed cold start](../spec/integration/android/cold-results.json) | Implemented. The cold-start evidence uses actual startup ordering, not manual provider registration substituted for installation. |

## Original findings and subsequent corrections

**Temporary expiry presentation at the original audit.** Catalog stored
`episode.expires_at` and authorization enforced it, but the UI only displayed a
generic temporary label. The audit requested a visible expiry without widening
offline rights. The later [display correction](entitlement-display-update.md)
implemented it and passed its own 132 checks per native UI size.

**Direct download connectivity.** `Controller:resume()` guards restoration with
`_connected()`, and missing-reader/prefetch acquisition has the same check. In the
audited snapshot, `resumeJob()` delegates directly to `DownloadService:resume()`;
`downloadEpisodes()` likewise enqueues work without a service-level connection
predicate. The service checks authentication, entitlement and space, but can
prepare an index or submit a missing-image worker while offline. Gate those
operations in the shared service while allowing ready cached pages and complete
local chapters to succeed. Preserve the current explicit restart/resume policy;
the written scope does not require a new background polling service.

Both findings were reported to root. The original package-snapshot findings
remain distinct from the subsequent source correction recorded below.
No additional release feature, speculative failure matrix or monetary test is
proposed here. The quote-preview runtime evidence gap remains an evidence limit,
not another claim that its already-present reading functions are absent.

## Follow-up: network gate source correction

After the static audit, root added a shared connection predicate to the
DownloadService and a parent-side Runner `before_start` guard, including index
preparation. Ready cached pages and complete local chapters still bypass the
network requirement; incomplete jobs pause with a network/timeout reason.
Guard rejection also respects callback-driven suspend/close reentry. No new
polling or reconnect auto-enqueue policy was introduced.

The separately authorized [focused result](../spec/jobs/download-connectivity-results.json)
passed 25 cases / 135 assertions: 16/50 with actual Controller/SQLite/PageStore
and controlled asynchronous completion, plus 9/85 with actual Runner/fork and
synthetic workers. All seven real children were reaped and standby holds were
balanced. This closes the identified connectivity gap in the tested source,
not retroactively in the earlier archive hashes or live-account evidence.

| Corrected source file | Verified SHA256 |
| --- | --- |
| controller.lua | `5ae6d7c13751cc67a2684131d84a2bbdb0930dbc879a4f693931512947a84b72` |
| jobs/download_service.lua | `6938702d60ae15ec44ce980833375e56f5ae5b6202fc94d1b6d1a38d06e20f0a` |
| jobs/runner.lua | `e04ff2c6bf116487e011a899010db0360acaa2284167ccea45236e1bea4e2991` |

The separate [expiry display correction](entitlement-display-update.md) has also
closed the other original presentation omission with its own source and
evidence. Neither correction retroactively changes the old archive records.
No monetary or live-service operation was used by the connectivity follow-up.
