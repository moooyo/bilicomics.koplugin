# BiliComics KOReader Plugin: Implementation Plan

Status: implementation baseline. Date: 2026-09-12.

This document is the authoritative implementation plan. It incorporates the [product/protocol research](product-and-protocol-research.md) and the [native-reader investigation and remote prototype](native-reader-integration-research.md). Research scripts remain evidence, not production modules.

## 1. Product and architecture decisions

Build `bilicomics.koplugin` as a local KOReader plugin with independently designed comic-oriented business screens. Use native `ReaderUI` for reading and MuPDF for image rendering through a dedicated `Document` provider. Do not depend on WeRead code.

Online reading, background prefetch, complete offline downloads, and explicit purchase are mandatory parts of the first release. Recharge is excluded.

The delivery target is a local plugin with an isolated local protocol adapter. A companion server is not a default dependency. Current Bilibili signing, response processing and image conversion have not been reproduced end to end; milestone M0 must establish a deliverable local implementation and its exact dependencies. Pure-Lua protocol portability is not assumed. If target platforms cannot support those dependencies, that is a release blocker requiring an evidence-based plan revision, not permission to silently add a service or remove requirements.

Initial compatibility baseline: the official KOReader `v2026.07.1` used in the remote prototype. Declare other versions and device platforms supported only after their compatibility checks pass. Current-master source inspection is separate evidence from release execution.

## 2. First-release scope

| Area | Required behavior |
| --- | --- |
| Account | Import and validate an existing Bilibili web session; retain a stable local account identity; show session expiry and allow replacement |
| Library | Following, reading history, continue reading, search, and comic details |
| Chapters | Complete ordered catalog, special-episode ordering, reading state, access state, storage state, and selection |
| Online reading | Open a prepared chapter descriptor before the whole chapter downloads; requested images take priority |
| Prefetch | Fetch upcoming images to disk and warm the beginning of the next already-readable chapter |
| Offline reading | Open complete pinned downloads without login refresh, token retrieval or an acquisition service |
| Native reader | Page fit, width fit, direction, zoom/pan, native controls, chapter actions, local resume |
| Downloads | Selected chapters, pause/resume/cancel, restart recovery, failed-page retry, pinning and removal |
| Purchase | Single-chapter purchase using existing currency or eligible reading coupons; currency purchase for server-supported batch offers |
| Existing temporary access | Display and honor access type and expiry; allow reading according to verified online/offline terms |
| Settings | Reader defaults, prefetch, automatic cache limit, storage status, account/session and diagnostics |

Session import is the first-release authentication path. QR login is a later convenience, not an unverified dependency of first-release reading or purchase.

The first release does not initiate new wait-free/rental/item/silver entitlements or support arbitrary noncontiguous chapters as one atomic purchase. Batch coupon payment is not promised without an explicit server contract; do not emulate an atomic batch with hidden repeated single-chapter charges. Existing temporary entitlements remain correctly represented.

CBZ export is an optional subsequent feature; it is not required for the primary offline path. Automatic purchasing and changing the account's auto-buy configuration are excluded.

## 3. UI and user flows

### 3.1 Navigation

| Screen | Content and primary actions |
| --- | --- |
| Continue | Recent comics, precise local position, latest available chapter; Resume and Open chapters |
| Following | Followed comics with updates and publication state; Read next and Open details |
| Search | Search results and direct comic-ID lookup; Open details and Follow |
| Downloads | Active jobs and complete offline chapters; Read, Pause, Resume, Retry and Remove |
| Account/settings | Session state, asset balances, reader defaults and storage controls |

Use native KOReader widgets, pagination, large touch targets and grayscale-readable labels. Keep native reader menus and gestures. Add a compact BiliComics reader menu for chapter selection, details, download, purchase and return to the plugin library.

Chapter rows show three independent dimensions: reading (`unread/in_progress/finished`), access (`free/owned/temporary/locked/unavailable/unknown`), and storage (`absent/partial/queued/downloading/complete/failed`). Preserve server episode IDs and exact order values, including fractional special episodes.

### 3.2 Online open

1. Resolve the selected account, comic, chapter and local reading anchor.
2. Reuse a valid local descriptor. If one does not exist, obtain the chapter index and enough metadata to define ordered pages and local geometry.
3. Check the known access state before acquisition; locked content opens a purchase action instead of a read/download task.
4. Open the stable descriptor through native `ReaderUI` immediately after that preparation. Do not wait for all chapter images.
5. The provider renders committed local images or a transient loading/error state; the scheduler prioritizes missing visible content.
6. Worker completion commits content, increments the persistent page generation and notifies the active reader. Repaint without resetting unchanged geometry or viewport.

Opening can require index/geometry preparation. The first-image promise is independence from whole-chapter download, not an unmeasured latency guarantee.

### 3.3 Explicit download and offline open

Selecting Download creates durable chapter jobs, pins their page sets, and reuses images already obtained during online reading. A chapter is complete only when every required page is committed, usable and consistent with its content revision.

Offline opening uses the same descriptor and provider. It must not call login, wallet, catalog, token or remote geometry APIs first. Native document identity and reading settings remain unchanged. Known temporary-access terms still apply; partial chapters show available content and explicit gaps, not a complete-offline badge.

### 3.4 Purchase and continuation

Show the exact chapter or server-supported range, expected entitlement, eligible asset type, selected coupons if applicable, server total and usable balance. Changing selection or payment method creates a new quote and requires explicit confirmation.

After confirmed access, resume the original Read or Download intent. Insufficient balance preserves the selection and exposes Refresh balance; no recharge flow is implemented. Prefetch and download actions do not confer purchase authorization.

## 4. Components and ownership

| Component | Responsibility |
| --- | --- |
| Plugin entry and service registry | Menu registration; create/reuse process-scoped services independently of ReaderUI instances |
| `SessionStore` | Session import/validation, credential isolation and stable account namespace |
| `ProtocolAdapter` | Current request contracts, signing, error normalization, encrypted responses and native/runtime bindings |
| `CatalogService` | Following/history/search, comic metadata and chapter ordering |
| `EntitlementService` | Access type, expiry, stale/unknown state and post-purchase reconciliation |
| `ImageResolver` | Image index, token refresh, conversion requirements and usable acquisition results |
| `StateStore` | Schema migrations and transactional metadata, jobs, page generations and purchase journal |
| `PageStore` | Descriptor creation, committed image files, checksums, pinning, space limits and eviction |
| `DownloadService` | Durable jobs, foreground priority, request merging, workers, retries and recovery |
| `ComicDocument` | Native paged-document contract and missing/ready content behavior |
| `ImageBackend` / `GeometryMapper` | MuPDF image ownership, native-unit mapping, orientation and supported pixel transformations |
| `ReaderIntegration` | Native lifecycle, progress, chapter transitions and page-ready notifications |
| `CompatibilityAdapter` | Small, version-tested instance adaptations for chapter endings and native thumbnail paths |
| `PurchaseService` | Quotes, serialized explicit submission, durable outcomes and reconciliation |
| Business views | Library, details, chapters, purchase, downloads and settings |

The main process owns user-visible state, the write database connection and the scheduler. Workers perform bounded network, verification and image-preparation tasks. Worker processes do not use the parent's inherited database connection or mutate reader objects.

## 5. Storage and durable identity

Use KOReader's bundled `lua-ljsqlite3/init` binding. There is one main-process writer, explicit transactions and schema-versioned migrations. Enable WAL only when the device supports it; follow the platform-aware pattern used by the [official statistics plugin](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/plugins/statistics.koplugin/main.lua).

Keep data under KOReader's data directory:

```text
bilicomics/
  settings.lua
  accounts/<account_key>/
    session.dat
    state.sqlite3
    documents/<comic_id>/<episode_id>/<revision>/chapter.bcomic
    pages/<episode_id>/<revision>/<image_id>.<format>
    temporary/<job_id>.part
```

`account_key` is derived from a verified stable account identity, not from an expiring session cookie. Store credentials separately from ordinary state, redact them and temporary signed URLs from diagnostics, and do not include them in descriptors or purchase journals.

Android is an exception to the `session.dat` location shown above. Its shared DataStorage filesystem does not provide ordinary Unix ownership and chmod guarantees, as measured in the official APK. Keep the structured session under `android.dir/bilicomics/accounts/<account_key>/session.dat`, where `android.dir` comes from Java `Context.getFilesDir()`. Require app ownership, private directory/file permissions and no symbolic-link traversal. Ordinary SQLite state, descriptors and cached images retain the DataStorage layout. Do not silently reactivate a legacy session from shared storage; a newly validated import must be saved privately before its known old session file can be removed.

The immutable `.bcomic` descriptor contains a schema version, account namespace, comic/chapter identity, content revision, ordered source-image identities and initial logical geometry. Mutable titles, progress, paths, download state, access state and tokens belong in separate storage. Do not rewrite the descriptor when files arrive or purchases complete: native document settings can depend on both its path and content hash.

Core database records:

| Record | Important fields |
| --- | --- |
| Comics/episodes | Remote identity, exact ordering, metadata freshness and publication state |
| Access snapshots | Entitlement kind, expiry, confirmation time and uncertainty |
| Pages | Source identity, revision, local path, format, dimensions, content digest, availability, content generation, geometry generation |
| Downloads/jobs | Origin, scope, state, priority, progress, retry data and ownership |
| Pins | Explicit retention intent independent of automatic-cache access time |
| Anchors | Chapter/image identity, normalized source position, view mode and geometry version |
| Purchase intents | Quote and exact scope, assets, prior and expected entitlement, purpose, submission state and timestamps |

### File commit protocol

1. A worker writes only its assigned `.part` file, verifies the acquisition response and returns metadata through IPC.
2. The main process checks job/account generation, file identity, integrity and usability, then atomically renames the file into the final page store.
3. A database transaction records the committed path/digest, increments durable content/geometry generations as appropriate and marks the page ready.
4. Notify subscribers only after the database commit.

On restart, reconcile interrupted work: a database-ready page with no valid file becomes missing/failed; a committed but unindexed file is verified before adoption; incomplete files are resumed only when the transport contract supports it, otherwise restarted. An episode cannot retain a complete badge after an invalid page is detected.

Persistent page generations survive restart and participate in native cache keys. Reader/account/job generations reject stale in-flight callbacks and serve a different purpose.

## 6. Native reading implementation

### 6.1 Provider

Derive `ComicDocument` from `document/document`; register `bilicomics_document` for `.bcomic`. Use native `ReaderUI` and a composite backend whose page objects own real MuPDF single-image documents/pages. Close page and owning document correctly; maintain DocumentRegistry reference counts.

Expose a full page count and synchronous local geometry for all pages. Native zoom, scrolling and adjacent-page hinting may inspect an image before it is downloaded. No layout, geometry, draw, cover or thumbnail method may start blocking network work.

Use explicit capability flags and numeric defaults. `is_locked` remains the native document-password flag and must never represent purchase requirements. Initially disable unsupported text reflow, OCR and text selection features and provide correct empty-result method contracts. Native metadata/TOC methods return tables; absent text boxes return `nil`.

Handle loading in provider draw paths before invoking native rendering. Real content alone may enter completed-page caches. Implement ordinary, inverted and scaled-fragment paths intentionally; do not reuse a generic viewport tile for incompatible render requests.

### 6.2 Geometry and memory

Use oriented source-image logical pixels for page identity and normalized reading anchors. `GeometryMapper` explicitly maps those units to MuPDF native units, handling DPI, unequal-axis resolution and orientation metadata. Do not assume one uniform scale always suffices. Derived geometry and its generation live in the database.

Use validated index dimensions initially. If image headers require a geometry correction, retain the descriptor identity, save the current normalized anchor, update derived geometry, invalidate dependent caches, rebuild layout and restore the anchor. This correction must not silently jump the reader to the image start.

Use one active source-image decode/preparation operation initially and avoid parallel full-image decode prefetch. Prefetch compressed files to disk. Release native handles promptly and budget additional buffers by bytes.

Before decoding, apply a device-profile pixel/format memory check. PNG/WebP may decode a whole source even for a tiny viewport; the remote 1200 by 16000 sample exceeded 118 MiB in the minimal backend process. Prefer a verified lower-resolution or segmented source when available. Otherwise use a proven bounded preparation path; if none fits, expose an actionable unsupported-size state instead of attempting an allocation likely to crash. Record supported limits from representative target-device measurements.

### 6.3 Reading modes and progress

Default page comics to native page fit with an explicit reading direction. Default long strips to native width fit and continuous mode, retaining page-key/tap viewport advancement and overlap.

Use native `last_page/page_positions` for continuous-mode restoration. Store supplemental normalized source anchors for ordinary page mode, horizontal panning and geometry changes. Capture anchors after settled navigation, on reader close and before suspend; avoid a disk write on every paint.

Online and pinned offline reading retain the same descriptor and provider. Exported CBZ files are separate documents; automatic native-progress interchange is not a first-release promise.

### 6.4 Cache and lifecycle integration

Include descriptor revision and persistent page/geometry generations in render identities. A same-second completion cannot rely solely on `resetTileCacheValidity()`. For unchanged geometry, repaint the current reader without a general page-layout reset.

Native thumbnail children read ready local images only. They must not trigger downloads. Check content/geometry/account generations before inserting returned thumbnails into their cache, not only before displaying them. Do not persist a missing-content placeholder as a successful thumbnail.

Use the verified narrow instance-level EndOfBook interception in `CompatibilityAdapter`. Only one chapter transition may be pending per reader session. On the next UI tick, confirm session validity, then open the next readable chapter or present the purchase action. Verify interception ahead of stock next/delete/dialog actions for every supported version.

## 7. Download service and prefetch policy

Initial configurable policy:

| Work | Priority and behavior |
| --- | --- |
| Visible missing image | Highest; reserve transfer capacity or cancel safe low-priority read-only work |
| Next images | Prefetch the next three source images to disk; retain recently visited content |
| Next chapter | Near the current chapter end, prefetch the first two images only if that chapter is already readable |
| Explicit downloads | Durable work below visible-page demand; complete and pin chosen chapters |
| Covers/metadata | Lowest priority during reading |

Start with at most two acquisition transfers and one image-preparation task. Deduplicate by account, content revision and image identity; a foreground request promotes existing work. Counts are initial defaults to tune against target devices, not measured throughput claims.

The automatic-cache budget is user-configurable. Select a conservative default from the target-device storage profile, maintain free-space headroom, and never evict pinned or actively rendered content. Manual downloads consume real storage and may pause for insufficient space even though they are exempt from automatic-cache eviction.

Read-only acquisition uses bounded retry/backoff, with token refresh only for classified token-expiry conditions. Authentication failures pause dependent network work; permission failures do not loop through token refresh. Purchase requests never use generic automatic retry middleware.

Workers use bounded framed messages carrying job and account generation. A completion from an obsolete account/session cannot commit into new state. Reader closure cancels reader-owned prefetch and subscriptions; explicit downloads continue while KOReader remains running. App exit/suspend persists and pauses work; this plan does not add a separate background operating-system service.

Every worker terminal path must reap the child and release its standby hold exactly once. Resume network work only after connectivity is available. Crash recovery resumes durable jobs without replaying purchases.

## 8. Purchase transaction protocol

M0 validates `GetEpisodeBuyInfo`, supported batch offers, asset eligibility, access semantics and request construction before the purchase UI is implemented. Use server quotes, including server-supported discounts; never calculate a payable batch by multiplying a displayed single price or inventing a `limit=0` scope.

Persist a purchase intent containing:

- Account identity, exact intended chapter set and original server-supported scope.
- Asset type, chosen coupon identifiers, server amount and quote fingerprint.
- Before-purchase access snapshot and expected entitlement kind.
- Original action (`read` or `download`), state and timestamps.

Persist `submitting` before network transmission. Only one purchase submission may be in flight per account. The local intent is a recovery journal, not a server idempotency key.

```text
selected -> quoted -> explicitly_confirmed -> submitting
submitting -> accepted -> refreshing_access -> access_confirmed -> resume_action
submitting -> rejected -> actionable_error_or_new_quote
submitting -> outcome_unknown -> reconcile_without_resubmission
```

After a lost response or uncertain crash, do not resubmit automatically. Unknown results block another submission for the same unresolved chapters. Reconcile the exact expected entitlement; a changed wallet balance is insufficient proof, and temporary access is not proof of permanent ownership.

If expected access is established without conclusive transaction evidence, record `access_confirmed` and allow reading; do not fabricate a payment receipt. Partial batches retain their unresolved subset. A subsequent attempt requires a new quote and explicit confirmation, and delayed server updates must be considered before classifying the earlier request as failed.

A received successful purchase response remains accepted even if wallet refresh or image loading fails afterward. Keep those failures separate from payment state. `GetPayOrders` is a recharge-history API in the inspected client and is not used as a chapter-purchase status query.

Neither a worker nor a prefetch callback can initiate purchase, spend a coupon, switch the payment method, or alter auto-buy settings. Validate that the chosen read/acquisition requests do not unexpectedly consume assets under the supported account configuration.

## 9. Source layout

```text
bilicomics.koplugin/
  _meta.lua
  main.lua
  bilicomics/
    services.lua
    settings.lua
    protocol/         # Session, requests, signing, response/image adapters
    catalog/          # Library, comic and episode repositories
    storage/          # Database, migrations, descriptors and page files
    jobs/             # Scheduler, worker entry and IPC
    reader/           # Document, image backend, geometry and integration
    purchase/         # Quotes, durable intents and reconciliation
    ui/               # Comic-oriented business screens
  spec/               # Targeted logic and integration tests run remotely
  research/           # Existing evidence; not shipped as plugin runtime
  docs/
```

Keep identifiers, source comments and documentation in English. Use KOReader localization conventions for interface text. Package only production runtime modules and their verified dependencies; do not copy the research provider into production without completing its missing contracts.

## 10. Delivery milestones and gates

| Milestone | Deliverables | Exit condition |
| --- | --- | --- |
| M0: Protocol and packaging | Authenticated session import; current signed requests; response/image processing; single/batch quotes; eligibility; dependency/platform manifest | One free and one already-owned chapter yield usable images; quote scopes/terms are understood; the local adapter has a deliverable dependency plan |
| M1: Production document core | State schema, immutable descriptors, geometry mapping, local MuPDF provider and source anchors | Native reader handles real format/DPI cases, long-image limits and close/reopen without corruption or unacceptable position loss |
| M2: Online and offline content | Real workers, scheduler, prefetch, page-ready updates, durable downloads, pins, recovery and thumbnail integration | First image can be read before chapter completion; interruption/restart/offline scenarios pass; no UI-blocking network path |
| M3: Purchase and chapter flow | Single and supported batch quote UI, serialized intents, uncertainty handling, entitlement refresh and next-chapter integration | Quoting/eligibility and failure paths pass; actual authorized purchase behavior is verified before claiming end-to-end payment support |
| M4: Product UI and release | Following/history/search, chapter states, download/account/settings screens, localization and packaging | All mandatory first-release features pass together on the declared KOReader/device matrix |

UI and fixture-based provider work may proceed in parallel with M0, but production API assumptions and package dependencies must not be finalized before that gate passes. M3 is part of the first release, not a deferred optional purchase feature.

M0 can validate authenticated reading and quote contracts without spending. A real charge during M3 verification requires explicit authorization for the concrete account/chapter/asset amount; ordinary implementation work and fixture tests continue independently of that authorization.

## 11. Verification and release acceptance

Run tests and runtime verification only through `ssh test-env` unless the user explicitly authorizes local verification for the current task. Use synthetic fixtures for repeatable core behavior and authorized account content for integration. Do not turn a mock quote or simulated file arrival into a claim of successful production payment or networking.

Current authorization, updated by the user on 2026-09-13: operations other than actual purchasing are allowed. Read-only quote, eligibility and wallet investigation may use the provided session. Synthetic purchase-state and request-construction tests may run with artificial account data, an explicitly injected in-memory transport and network isolation; they must not reach a real purchase endpoint or consume real assets. Actual purchases, including zero-price purchase requests or coupon spending, remain prohibited. Recharge, new rental/item entitlements and automatic-purchase-setting changes remain outside the product scope. The earlier reading-only reports omitted quote and wallet reads under their narrower scope; they are historical evidence, not the current authorization. Purchase implementation remains required, and simulated results must never be presented as successful real transactions.

Required groups:

| Group | Acceptance cases |
| --- | --- |
| Protocol | Session expiry, signed/plain/encrypted response branches, image conversion, expired tokens, locked/unavailable content, quote scope and asset eligibility |
| Geometry/rendering | JPG/PNG/WebP, DPI and orientation, page/width/continuous modes, crop/zoom/inversion, oversized inputs and normalized position restoration |
| Concurrency/cache | Missing visible/adjacent pages, same-second replacement, persistent generation across restart, rapid jumps, shared requests and stale worker/thumbnail results |
| Offline/storage | Complete chapter without network or login refresh, partial gaps, corrupted/missing file, commit crash windows, pins, low space, account separation and content revision changes |
| Lifecycle | Reader close/reopen, one-shot next chapter, native end-action interception, app exit, suspend/resume, worker crash/reaping and balanced standby holds |
| Purchase | Updated quote, insufficient balance, ineligible coupon, duplicate click, lost response, crash before/after sending, partial batch, delayed entitlement, successful purchase with failed subsequent refresh |
| Device compatibility | Declared KOReader versions; representative e-ink Linux and Android devices; physical keys, refresh behavior, memory and supported third-party plugin combinations |

Release requires all four user-visible pillars together: independent comic UI, native online reading with prefetch, reliable offline downloads, and explicit purchase without recharge. The current research validates the native-reader foundation; it does not replace these release checks.
