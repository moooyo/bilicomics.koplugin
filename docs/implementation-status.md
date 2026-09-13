# Implementation status

Date: 2026-09-13. Version: `0.1.0-dev`.

Current follow-up: [architecture stabilization](architecture-stabilization.md)
tracks the reviewed dispatch/completion fixes, common-source regression,
canonical packaging, and live/device acceptance. The user confirmed that the
physical Scribe is currently unavailable. Historical results below must not be
promoted to evidence for an unverified later candidate.

The subsequent [QR sign-in and renewable-session change](session-renewal.md) is implemented in the current source and an authentication development candidate. It adds private refresh credentials, serialized maintenance, crash markers, and native QR UI. Its own remote synthetic evidence is separate from the older integrated package and reading evidence below. Real QR confirmation, authenticated refresh/confirmation, long-duration retention, and physical Scribe execution remain unverified.

This is a development implementation, not a completed release. A complete real free chapter passes the production plugin's native online reading, prefetch, retained download and new-process offline reopening workflow: 45 pages and 92,022,101 image bytes, with 51 online and 30 offline checks. The independent comic UI, reader integration, storage, workers and explicit-purchase state workflow are implemented. Standard coin batches now support the strict ordinal range primitive, including positive and remaining ranges; extra discount/card choices remain advisory. The user has authorized operations other than actual purchases. Read-only live quotation and isolated synthetic transaction regressions have run, while actual charging and physical target-device acceptance remain unverified.

The primary device is Kindle Scribe, first generation, running Kindle firmware 5.19.3. The user described the installed KOReader as the latest; the exact installed build remains unverified. The official release used by the recorded runtime checks is [v2026.07.1](https://github.com/koreader/koreader/releases/tag/v2026.07.1). No plugin execution on the physical Scribe has been established by the Linux, Android or ARM emulation evidence.

The [quote-selection and ordinal implementation](quote-selection-implementation.md) now has focused module, native UI, transaction-state and SQLite restart evidence. Production Range/Fetch/Quote also constructed submittable positive and remaining quotes from newly captured authenticated reads. The proof retains server_confirmed_ids=false: the UI presents the ordinal rule and current expected episode list, not a server receipt. Extra-asset consumption and live post-purchase membership remain untested.

The integrated default development package includes the bounded [download connectivity correction](download-connectivity.md), [temporary-access expiry display](entitlement-display-update.md), and quote-selection/ordinal changes. Twenty-five focused connectivity cases passed, including real queue retries and callback suspension, and 132 native display checks passed at each of two screen sizes. These reading results retain their original snapshots. Package manifests and source provenance identify the integrated build; earlier reading and preview archives are historical variants. The current integrated revision has no local interactive or physical Scribe execution evidence.

The [official koxtoolchain target guidance](https://github.com/koreader/koxtoolchain/blob/2026.08/README.md) maps firmware >= 5.16.3 to `kindlehf`, making that the package choice for the stated 5.19.3 firmware. The toolchain loader's original failure is now traced to its old Thumb load-bias code; a private diagnostic correction permits startup. A separate old-glibc BIND_NOW relocation-gap failure in the plugin ARM libraries is fixed by their link layout. Rebuilt libraries passed nine bounded QEMU primitive checks each with that diagnostic glibc 2.20 environment and unmodified Debian glibc 2.41. The loader correction is not packaged. These results do not establish the Scribe's actual libc or physical execution. The softfp branch remains incompatible. See [the correction and evidence](kindle-native-compatibility-fix.md).

## Evidence and remaining gates

| Area | Implemented and verified remotely | Still required |
| --- | --- | --- |
| Native reading | Production Document provider and ReaderUI; PNG/JPEG/WebP, DPI/orientation, missing content, persistent generations, geometry corrections, anchors, thumbnail isolation and chapter boundaries | Representative physical devices, memory budgets, physical keys and e-ink refresh behavior |
| Online/offline integration | Actual main/Runtime/Controller/Runner/default Worker/Store/PageStore/ReaderUI with real responses: all 45 free-chapter pages retained, 43 completed after reader closure; independent-process offline reopen restored the same descriptor and source anchor with no session, no routes and zero requests or workers | Physical Scribe execution; broader entitled-chapter and device lifecycle acceptance |
| Storage and jobs | Real SQLite, atomic file journals, crash recovery, source-history proofs and epochs; 14 earlier source-recovery scenarios and 19 current independent-version scenarios, including old/new pins, exact native reading, cancel/suspend and persistence failures | Real-service changed-content recovery and device-specific filesystem/power-management acceptance |
| Account and UI | Native Chinese business screens and account namespaces; session validation and existing favorites/history/catalog reads; native text-file import passed 42 focused checks at each of 600x800, 480x640 and 1860x2480; Android private-session ownership/restart verified separately | Native account import and usability on the actual Scribe; the largest tested layout is emulator evidence |
| Purchase | Authenticated basic/single/positive/remaining quote reads; standard coin ordinal construction; focused selection, identity, native UI and synthetic transaction/SQLite recovery checks; no actual purchase | Actual debit, coupon/card consumption and live post-purchase range membership remain untested; extra discounts remain advisory |
| Protocol | Authenticated signing/response decoding, bounded quote reads and index/token retrieval; all 45 real chapter JPEG responses passed after the production image fixes; earlier free/owned samples and synthetic encrypted versions 3/5/6/7/8 remain separate evidence | No live encrypted-container wire was observed; discount-asset consumption and live charging are unverified |
| Packaging | Deterministic integrated development ZIP, startup patch, 14 ABI-specific native libraries and redistribution notices; the manifest and package report identify the current file set and source bindings | Device execution evidence for each advertised target; archive checks alone do not establish native startup |

An earlier anonymous signed metadata request returned business code `99`; navigation returned `-101`. Authenticated read-only requests now succeed, but that contrast alone does not establish the precise cause of the earlier rejection. The latest [ordinal quote observation](../research/protocol/ordinal-range-live-result.json) completed seven business requests and one pinned signing-asset request. Four quote reads covered basic, single, positive batch and remaining batch; production Range/Fetch/Quote consumed the captures and built submittable 20-chapter and 123-chapter remaining quotes. That run made zero BuyEpisode, wallet, image or account-mutation requests. No actual chapter purchase, coupon use, rental or recharge has been established.

The live catalog exposed the exact zero-date value `0000-00-00 00:00:00` on permanent-access records. The normalizer now treats that value as no expiry and prioritizes explicit locked state over contradictory free/owned fields. Other unparsed date values remain unknown. This fixes the observed misclassification of already-owned chapters without broadening temporary rights.

The complete live workflow also exposed two image-protocol defects. Production Client URL construction now appends the official `code=DanmakuInfo` marker to complete image URLs without re-encoding signed parameters; direct cover URLs retain the ordinary URL path. The Backend recognizes an HTTP `image/*` response before encrypted-container conversion, because a token marked `hit_encrpyt=true` can return a regular JPEG. Existing image inspection, digests and size budgets remain enforced. The corrected fourth page and the full chapter passed without request overrides or skipped pages; related regressions cover 24 image-protocol groups and eight cover-policy groups. See [the reading-only report](reading-only-test-report.md).

The 51-check online phase opened native ReaderUI before the first image arrived, observed real prefetch and finished the explicit retained download after reader closure. The 30-check offline phase ran in a separate process with no session and no network routes, rendered cached pixels and restored the original source anchor with zero transport requests, worker starts or worker submissions. This complete scenario covers one free chapter; already-owned content has earlier sample evidence. Successful integrity checks do not imply page-by-page visual inspection of the entire chapter or live encrypted-container transformation.

The subsequent prefetch correction checks the configured next-chapter count before requesting its index, and checks the current account, reader, connectivity, session and lifecycle again before dispatching images. Setting the count to zero prevents index preparation. Retired older versions also suppress next-chapter prefetch before and after index completion. Thirty-three focused Controller checks passed remotely without an account, network traffic or purchase scenario.

Explicit recovery handles rotated sources when every historical image can be proved against a fresh index. It keeps descriptor identity, ready files, verified reading positions and pins, and resumes missing-page downloads with source-generation and expected-checksum checks. Unknown legacy history, changed content and unproved positions require a separate explicit new-version confirmation. That path now creates a unique local snapshot and new download, retains both versions with independent pins/removal, and isolates their reading progress. Retired versions are cache-only, while each job resumes/opens its own revision. The 19-scenario integration uses actual Controller/Worker/Runner/SQLite and native ReaderUI with controlled reading responses. Actual service source expiry or changed-content replacement was not observed. No content identity is inferred from `last_modified`, `cpx` or geometry alone; see [partial-download recovery](partial-download-recovery.md).

## Verification records

The protocol, core integration and build evidence was produced on `test-env` through SSH. The native reader baseline is the unmodified official KOReader `v2026.07.1` Linux x86_64 runtime in isolated data directories. After the user requested local KOReader acceptance, its official Linux runtime was also launched under local Debian WSL2/WSLg. The initial Chinese UI rendered at 720x960 with a read-only guard and the historical prefetch build. A separate two-boot SDL-dummy check subsequently verified selection of the earlier reading build recorded in the upgrade report, the provider-patch update, both recovery APIs and a retained synthetic profile marker. Both disposable processes stopped. The launcher did not import the user's session or execute purchase tests; local account reading remains manual. Those recorded local boots predate the integrated ordinal build and do not establish its interactive execution. These local checks do not establish physical Scribe compatibility.

The broad Controller, native UI, purchase and synthetic integration suites listed below retain their historical snapshots. Later authorization permitted non-spending synthetic transaction checks and bounded authenticated quote reads. Current focused evidence is listed separately below; it does not retroactively extend earlier Android, reading-only or preview results. Individual result scopes and source hashes remain authoritative.

- [Native document and geometry](../spec/reader/native-results.json).
- [Official startup entry](../spec/reader/production-startup-results.json) and [disabled-patch fallback](../spec/reader/fallback-results.json).
- [Real storage and recovery](../spec/storage/remote-results.json).
- [Worker, download and lifecycle checks](../spec/jobs/remote-results.json).
- [Historical Controller integration](../spec/controller/controller-result.json): 66 assertions, including durable purchase purpose, restart recovery and the actual single-chapter download continuation; [catalog state](../spec/controller/catalog-result.json).
- [ID lookup, following, reader preferences and local diagnostics](../spec/controller/product-features-result.json): 45 controller assertions; [actual local diagnostics worker](../spec/controller/diagnostics-native-result.json): 7 assertions.
- [Authentication invalidation and cleanup](../spec/controller/authentication-result.json).
- [Android private sessions and restart](../spec/controller/android-session-result.json).
- [Whole-plugin online, download and cross-process offline integration](../spec/integration/remote-results.json): 65 assertions with synthetic protocol data and real native reader/fork/storage.
- [Historical native UI at 600 by 800](../spec/ui/result.json) and [480 by 640](../spec/ui/result-480.json): 98 assertions each, including purchase/download continuation, obsolete confirmations and entitlement-only result wording.
- [Focused native session-file import](../spec/ui/session-import-result.json), [480 by 640](../spec/ui/session-import-result-480.json) and [1860 by 2480](../spec/ui/session-import-result-scribe-size.json): 42 checks each with synthetic inputs, real Controller/Session/SQLite and controlled session validation only. No purchase, quote or wallet operation was called.
- [Native reader default precedence, RTL navigation and restart](../spec/reader/defaults-results.json): 247 assertions, plus the [existing 314-assertion reader regression](../spec/reader/defaults-regression-results.json).
- [Historical purchase state and protocol boundary](../spec/purchase/verification-results.json), preserved unchanged; the later [non-spending regression](../spec/purchase/nonspending-regression-result.json) and current ordinal transaction report provide separately scoped state/protocol/restart evidence.
- [Protocol and encrypted acquisition](../research/protocol/protocol-validation.json) and [image golden comparisons](../research/protocol/image-validation.json).
- [Earlier authenticated reading-only samples](../research/protocol/authenticated-readonly-result.json): successful login, favorites/history/catalog, one free and one already-owned image index, and three valid JPEG images from each episode. The transport guard excludes all payment and account-mutating endpoints.
- [Real acquired images in the native reader](../spec/integration/real-image-local-results.json): 54 checks across four isolated processes, using synthetic local identities and the two acquired first images. This establishes native local rendering/scroll/reopen, not an entire real chapter or live background download workflow.
- [Complete live chapter workflow](../spec/integration/live-reading-results.json) and [compact archive/source summary](../spec/integration/live-reading-summary.json): 51 online plus 30 offline checks, 45 retained pages and 92,022,101 image bytes. Real responses and the default production worker were used; offline reopening had no session, no routes and zero workers.
- [Image request/response regression](../spec/protocol/image-response-result.json) and [direct cover URL/pixel-policy regression](../spec/jobs/cover-url-result.json): 24 and eight groups respectively, retaining existing encrypted-container fixtures without payment tests.
- [Kindle ARM compatibility correction](kindle-native-compatibility-fix.md): nine primitive checks each on glibc 2.20 with a diagnostic loader and unmodified Debian glibc 2.41. Source and instruction evidence distinguish the toolchain bootstrap defect from the corrected native-library relocation layout; no physical Scribe test.
- [Entitlement normalization regression](../spec/protocol/entitlement-result.json): seven targeted groups; the separate 12-case catalog regression also passed. No purchase suite was run for this fix.
- [Development archive checks](../spec/package/remote-results.json).
- [Next-chapter prefetch policy](../spec/controller/prefetch-result.json): 33 focused checks for disabled settings, reader/account lifecycle changes, retired versions and bounded image dispatch; no account or network access.
- [Requested local native UI startup](../spec/local/startup-result.json) and [manual acceptance instructions](../spec/local/README.md): official Linux KOReader under Windows WSLg, isolated profile, the historical prefetch package, anonymous Chinese UI and acceptance-only request guard.
- [Local acceptance build upgrade](../spec/local/upgrade-result.json): two real native boots in one disposable SDL-dummy profile, selected-build and provider-patch checks, and preservation of a synthetic data marker. The updated phase used the earlier reading archive recorded in that result; the user's visible app was left unchanged.
- [Source recovery integration](../spec/integration/source-refresh-workflow-results.json): 14 scenarios, 185 assertions and 44 real worker starts; all children terminated. Controlled read responses only, including explicit cancel/suspend, fresh entitlement, rejected changes and storage failures.
- [Source proof storage](../spec/storage/source-refresh-results.json), [verification Worker](../spec/jobs/source-verification-result.json) and [native recovery UI](../spec/ui/download-recovery-result.json): 47 storage cases, 17 worker groups and 159 current UI checks per size. No monetary operations were tested.
- [Independent version integration](../spec/integration/version-replacement-workflow-results.json): 19 scenarios, 258 assertions and 58 real worker starts; exact old/new native reading, isolated progress, independent removal, lifecycle cancellation and database/resume failures.
- [Atomic version publication](../spec/storage/version_replacement_results.json), [version progress](../spec/catalog/version_progress_result.json) and [native replacement UI](../spec/ui/version-replacement-result.json): 32 storage cases/395 assertions, 13 progress groups and 144 UI checks per size, with synthetic reading inputs only.
- [Historical quote-selection syntax](../spec/purchase/selection-syntax-result.json) and [original preview provenance](../spec/package/quote-preview-source-evidence-before-arm.json): syntax and archive evidence for the earlier preview, before the later behavioral runs. Their limited scope remains unchanged.
- [Earlier selection modules](../spec/purchase/quote-selection-result.json): 259 assertions in 23 groups for copied selection, basic/scoped separation, original vectors, identity/amount preservation and advisory behavior. Its all-batch-advisory result belongs to that earlier preview and does not describe the current ordinal adapter.
- [Client quote-response identity](../spec/protocol/purchase-info-identity-result.json): 115 assertions with actual Client/Fetch and strict fake inputs, covering absent-ID fallback, malformed/mismatched IDs and numeric normalization. This report retains its earlier source hashes.
- [Ordinal Range/Fetch/Quote](../spec/purchase/ordinal-range-result.json): 15 groups and 240 assertions with synthetic raw catalogs and responses; real proof derivation without Client, Service or live transport.
- [Ordinal transaction and SQLite recovery](../spec/purchase/ordinal-transaction-result.json): 489 ordinal assertions across 12 groups and eight persistence stages, plus 34 state-machine and 12 protocol cases in 11 isolated processes. Real Client serialization used strict in-memory transport; actual network attempts were zero. Same-comic uncertainty, late results, atomic index/journal rollback and index reconstruction passed.
- [Ordinal native UI](../spec/ui/ordinal-range-verification.json): 106 assertions at each of 600x800 and 480x640, including rule/expected-list wording and readable access with an unresolved range outcome; synthetic quotes and fake Controller only. The [earlier selection UI](../spec/ui/quote-selection-verification.json) retains its separate 141 assertions per size.
- [Acceptance request guard](../spec/local/readonly-guard-results.json): 209 assertions in 123 cases with actual Client request construction and strict fake Transport/Runner originals. Read admission and mutation denial passed with no real session or network; this is not Service/UI acceptance.
- [Current authenticated ordinal quote observation](../research/protocol/ordinal-range-live-result.json): four quote reads within seven business requests and one pinned asset request; two production range constructions were submittable, actual submissions zero, server_confirmed_ids=false.
- [Official Android APK native loader and crypto](../research/protocol/native-android-apk-verification.md).
- [Official Android APK worker lifecycle](../spec/jobs/android/remote-results.json): 44 assertions with real fork/IPC and synthetic workers.
- [Android reader/download/offline integration](../spec/integration/android/remote-results.json): 62 workflow assertions on `/tmp/bilicomics-final-Ei7yAG/source`, including actual local diagnostics with the network runner suspended, new-chapter auto/LTR defaults and saved-mode restoration across APK processes. The later purchase-continuation changes to Controller, Screens and Chinese localization have separate Linux/controller/native-UI evidence; they are not included in this Android snapshot.
- [Android installed-plugin cold startup](../spec/integration/android/cold-results.json): the actual plugin installs its production startup patch, native startup reopens the default-namespace cached chapter before Runtime initialization, restores the original source position and renders the expected pixels with no session and zero workers. All four APK phases and complete environment restoration passed on the same Android snapshot.
- [Cover source-size policy](../spec/jobs/cover-policy-results.json): oversized compressed covers are rejected before UI decoding, without applying the cover limit to chapters.
- [Cache verification measurements](../spec/performance/README.md): UI getters perform no full-image hashing; the redundant cold complete-chapter checksum pass was removed without removing forced integrity checks.

Each record describes its scope. Counts from independent suites should not be treated as one end-to-end acceptance result. Later changes require the affected evidence to be refreshed; source hashes identify snapshots where provided.

The integrated default artifact is dist/bilicomics-0.1.0-dev.zip. Its
[manifest](../dist/bilicomics-0.1.0-dev.manifest.json),
[package report](../spec/package/remote-results.json) and
[source provenance](../spec/package/source-evidence.json) identify the current
file set, archive hash and bounded source evidence. Earlier reading and
quote-preview archives retain their original evidence; their counts and hashes
must not be used to identify the integrated artifact. Package checks do not
establish a full live account workflow or physical/local interactive startup.

Standard coin batches with no extra discount now use the supported ordinal
primitive. Range derives intended IDs from the original catalog and consistent
basic/scoped offers, validates eligibility, counts and exact price sums, and
preserves the original offer position and fractional start ordinal. Positive
limits count eligible locked chapters from the anchor; zero means the remaining
locked chapters from that anchor. Fetch supplies the proof, and Quote recomputes
it before accepting it. The contract records server_confirmed_ids=false and
does not claim a server-returned exact episode set. Missing, unsupported or
contradictory evidence cannot produce a submittable quote. Extra discount/card
choices remain advisory. Single coin quotes require equal present
original/display amounts and a usable balance.

An uncertain ordinal transaction retains its original action and intended IDs
and blocks further purchases of the same comic. If those IDs become owned,
reading can proceed while the range outcome remains pending. Definitive outcomes
clear the flag; late acceptance preserves confirmed reading access. The journal
and range-pending index commit atomically, startup rebuilds the index once, and
ordinary pending refreshes avoid full-history scans. The focused synthetic
regression establishes these state and persistence rules without actual debit.

The earlier [quote-observation preparation](../research/protocol/quote-observation-preparation.md)
records the initial unexecuted proposal. Its permission wait and syntax-only
status are historical: the user later authorized non-purchase operations and
the bounded [live observation](../research/protocol/ordinal-range-live-result.json)
has completed. The latest run built the positive 20-chapter and remaining
123-chapter quotes from captured reads, with no actual submission. Actual debit,
additional-asset consumption and live post-purchase membership remain outside
the verified results. See [the implementation and evidence](quote-selection-implementation.md).

## Native dependencies

The package contains local `libbiliwasm` and `libbilicrypto` libraries. There is no production browser, Node process or companion server requirement. Public signing WASM is acquired by a worker and hash checked on first online use; cached offline reading does not acquire it.

The manifests distinguish compiled targets from executed devices. Linux artifacts target x86_64, ARM hard-float and AArch64 with a glibc 2.17 baseline. Android artifacts target ARM64, ARMv7, x86_64 and x86 with an API 21 baseline. Those artifact names do not imply support for every Kindle, Kobo or Android firmware. In particular, another C library, older glibc or ARM soft-float ABI needs its own deliverable and verification.

The Android API 30 x86 emulator exposed Bionic's refusal to load shared-storage native libraries. The production loader now verifies the packaged bytes, stages each ABI/hash in the app-private directory, serializes concurrent publication, and loads through a retained descriptor. Official APK cold and cached runs passed signing, AES, P-256 and synthetic version-8 image checks. Forty repeated loads retained the same two library descriptors with no additional FD growth. Linux loading behavior remains unchanged.

The same APK demonstrated that shared-storage mode bits do not provide normal Unix ownership guarantees. Android sessions now use app-private storage with verified ownership, directory mode 0700 and file mode 0600. Shared legacy sessions are not automatically adopted; new validated import and account switching must succeed before cleanup of that account's old credential file. Ordinary account databases, descriptors and images keep their DataStorage locations.

The historical Android Runner checks covered large-pipe transfer, UI heartbeat, cancellation, timeout, suspend/resume, child reaping and synthetic purchase non-repetition. The later Linux ordinal state and protocol regressions do not refresh this Android snapshot. The combined Android reader/download/offline scenario used synthetic data. An independent real-directory installation also passed native `start_with=last` cold startup through the production managed patch; its observer neither registered the provider nor initialized Runtime in advance. These Android snapshots do not establish physical e-ink behavior, execution on the user's ARM device, Android authenticated-network acceptance or a real purchase.

Image processing applies bounded compressed-input and pixel/format limits. Initial defaults are safeguards based on remote measurements, not published device capacity claims. An oversized unsupported image is reported rather than decoded without a bound.

## Next integration steps

1. Validate installation, native startup, session file import, reading, memory pressure, suspend/resume, touch and e-ink refresh on the declared physical Scribe. The complete live chapter workflow already passes on the official Linux runtime.
2. Preserve the prohibition on actual purchases. Read-only quote/wallet operations and non-spending synthetic checks are authorized, but they do not establish actual deduction, coupon/card consumption or delivered post-purchase range membership. Keep extra discounts advisory until their contract is established.
3. Resolve any further observed read-protocol or device incompatibility using actual evidence. Do not silently add a companion service, widen access eligibility or mark a rejected request successful.
4. Complete the declared KOReader/device acceptance matrix before promoting the development package to a release.
