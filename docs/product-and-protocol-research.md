# Bilibili Comics for KOReader: Product and Protocol Research

Research date: 2026-09-12.

Implementation decisions and delivery gates are consolidated in the [implementation plan](implementation-plan.md).

This document continues the research in [the earlier Codex task](codex://threads/01a092e9-62e1-70b1-866f-a1a48cf5fe61) and replaces its proposed first-release scope. It is a research and design document, not an implemented or validated plugin.

The subsequent [detailed native-reader investigation](native-reader-integration-research.md) includes remote execution evidence and refines the integration details in this overview. It records a working research provider in native ReaderUI, while clearly separating that prototype from production support.

## 1. Agreed product scope

The first release must provide:

- An independently designed Bilibili Comics interface, with no reuse of WeRead plugin code.
- Online reading that displays the requested image without waiting for a complete episode download, including background prefetch.
- Explicit episode downloads and reading from complete local downloads while offline.
- Explicit purchases using supported existing account assets. Recharge is outside the product scope.

Online reading, offline reading, and purchase support are all release requirements. Implementation can be staged, but none of these features should silently move to a later release.

The recommended architecture prioritizes KOReader's existing `ReaderUI` and native reading controls. Independently designing the library, episode, purchase, and download UI does not require replacing the reading UI. Complete CBZ files can be opened directly by KOReader. For immediate online reading, investigate a comic `Document` provider backed by a stable local manifest and shared page store, while retaining `ReaderUI` for navigation, zoom, rendering integration, and reading settings.

A dedicated reader is a fallback only if a concrete, verified native-reader limitation cannot reasonably be adapted. The existence of additional provider integration work is not sufficient evidence to choose a replacement reader.

## 2. Evidence and confidence

The following evidence categories are intentionally separate:

- **Current source:** behavior observed in publicly served first-party JavaScript or official KOReader source. It establishes client behavior, not successful authenticated server interaction.
- **Remote observation:** a specific request executed on `test-env`, with the request conditions and result recorded below.
- **Historical reference:** archived community API documentation. It supplies leads, not a current contract.
- **Design proposal:** a proposed plugin behavior or architecture that still needs implementation and device verification.

No account login, purchase, coupon consumption, or manga image download was performed during this investigation. Public HTML and JavaScript were read as source material; downloaded JavaScript and WASM were not executed.

### 2.1 Current conclusions

| Area | Evidence | Consequence |
| --- | --- | --- |
| Favorites and history | Current homepage JavaScript uses `ListFavorite` and `ListHistory` | Use favorites and history as primary library sources |
| Wallet | Current homepage JavaScript uses `GetWallet` and displays separate account assets | Purchase can use existing assets without implementing recharge |
| Chapter access | Reader source distinguishes normal access, purchase required, and unavailable episodes | Access state must be modeled independently from download state |
| Image acquisition | Current PC reader has signing, encrypted-response handling, and conditional image conversion | The historical index/token flow is incomplete as a current implementation recipe |
| Native CBZ | Official KOReader document provider supports CBZ through MuPDF | Complete local episodes can use the existing reader directly |
| Native page navigation | ReaderZooming and ReaderPaging implement width fit, viewport advancement, overlap and direction | Reuse and configure these features before considering custom interaction |
| Native provider prototype | 21 assertions passed remotely with official KOReader v2026.07.1 and synthetic images | Initial native-reader feasibility is demonstrated; full provider, networking and device behavior remain to implement and verify |
| Online example | OPDS PSE lazily loads images using synchronous HTTP | It does not establish the limitations of ReaderUI or its document-provider extension point |
| Remote legacy request | An anonymous historical-shaped `ComicDetail` request returned business code `99` | That request shape did not succeed; the cause remains unresolved |

### 2.2 Source freshness

The current homepage directly references `chunk-A-ZFq6o-.js`. The current detail page references `bili.9409128c39.js` and `detail.beb8b46661.js`. The current `/mc36215` reader page directly references `reader.1ffe7bbf9d.js`, `bili.9409128c39.js`, and `vendors.c68379b8e3.js`. Deployment references should be checked again before protocol implementation.

The community archive states that its main upstream snapshot was synchronized on 2026-01-24/25. Treat examples from it as historical. A URL still serving an asset is not, by itself, proof that every current client uses it.

## 3. Interface designed around comics

### 3.1 Main navigation

Use a small number of persistent destinations, with paginated content suitable for e-ink:

| Destination | Main content | Primary actions |
| --- | --- | --- |
| Continue | Recently read comics, local reading position, latest update | Resume, open episodes |
| Following | Followed comics, unread updates, publication state | Read next, open details, manage following |
| Discover | Search and direct comic-ID entry; minimal results | Open details, follow |
| Downloads | Pinned offline episodes and queued work | Read, pause, resume, retry, remove download |
| Account and settings | Session state, balances, reader and storage options | Sign in, refresh assets, manage cache |

Avoid copying website hover menus or building a storefront around recharge. Search is sufficient for initial discovery; recommendation feeds and rankings can be added independently.

The continue view should remain useful without connectivity. It uses local metadata and local anchors immediately, with optional online metadata refresh afterward.

### 3.2 Comic details and episode selection

A comic detail view contains a cover, title, authors, publication/update information, a prominent Resume action, and an episode list. A compact action row offers Follow and Download selection. Purchase selection is available from locked episodes and an explicit multi-select flow.

Each episode row expresses three independent dimensions:

| Dimension | Example states |
| --- | --- |
| Reading | Unread, in progress, finished |
| Access | Free, owned, temporarily unlocked, locked, unavailable, unknown |
| Storage | Not cached, partially cached, downloading, complete and pinned, failed |

For example, an episode can be owned, unread, and fully downloaded simultaneously. A single lock/download icon cannot encode all these states. Use text and shape indicators that remain legible in grayscale.

Keep episode IDs as identities. Do not derive identities from titles or round `ord` to an integer: historical examples include fractional special-episode orders. Preserve server ordering and explicit sort metadata when available.

The reader source maps `ComicDetail.read_order` to the last-read episode order. It must not be interpreted as left-to-right or right-to-left reading direction. Reader mode and direction require their own settings and verified source mappings.

### 3.3 Reading interaction

Prioritize the same native `ReaderUI` for online and offline episodes. A proposed comic provider selects the local page first and schedules missing data when network use is allowed. Complete CBZ files already have a native provider; the online provider still requires implementation and verification.

- **Page comics:** use native page fit, zoom, pan, and reading-direction settings. Verify any additional spread requirements separately.
- **Vertical comics:** begin with native width fit and viewport advancement/scroll mode. ReaderPaging already contains within-page advancement and overlap logic; do not infer missing support from the separate ImageViewer widget.
- **Hardware keys:** retain native key handling and verify the selected native mode advances through a long image before changing the source page.
- **Controls:** retain native reader menus and touch zones. Add plugin actions for comic details, episodes, purchase, and download through reader integration.
- **Episode boundary:** integrate native end-of-document events with the next readable episode or an explicit purchase action. Background prefetch cannot trigger a purchase.
- **Errors:** the provider/integration must keep missing-page loading responsive and offer retry without corrupting native page state or caching a placeholder permanently.

Default to native controlled viewport stepping for vertical comics on e-ink, with native scroll mode available where appropriate. Distinguish source-image position from viewport position; an image is not necessarily one screenful. Exact mode defaults, long-image memory, and position restoration need target-device verification, but they do not justify assuming that the reading interaction must be rewritten.

### 3.4 Purchase interaction

A purchase sheet shows the exact selected episodes, the access term if applicable, eligible payment methods, the server-calculated total, available assets, and one explicit confirmation action.

Changing the selection or payment method invalidates the previous quote. A changed price requires an updated confirmation. While a purchase is pending, prevent repeated submission of the same intent.

After success, refresh entitlement and wallet state before continuing reading or download. If the balance is insufficient, preserve the selection and show the shortage with a Refresh balance action. There is no recharge page, payment QR flow, recharge SDK, or automatic redirect in this plugin.

Do not introduce automatic chapter purchase or silent fallback between asset types. Supporting purchase does not imply enabling auto-buy configuration on the user's account.

## 4. Online and offline content architecture

### 4.1 Shared page store

Use a shared `PageStore` with three layers:

1. An immutable episode descriptor for native document identity, plus separate mutable page/access/download metadata. Native hash-based metadata settings make descriptor content stability important as well as path stability.
2. Committed compressed image files: reusable by online reading and offline downloads.
3. Native document/render caches, coordinated with the provider and bounded by measured memory behavior. Avoid adding an independent decoded-image cache that duplicates buffers already owned by the native backend.

Signed CDN URLs are temporary acquisition credentials. They must not become persistent resource identities or the sole contents of an offline download.

A proposed resource key is `account_namespace / comic_id / ep_id / content_revision / image_index`. Retain a source-path fingerprint when useful, but keep temporary tokens out of the identity. Refreshing an index must reconcile old and new manifests instead of mixing pages from different revisions.

Explicit download pins the same episode files used by the online reader. Already committed pages are reused; missing pages are scheduled. Complete pinned downloads are excluded from ordinary automatic-cache eviction.

### 4.2 Request scheduling

The following is a starting policy, not a measured device limit:

| Priority | Work |
| --- | --- |
| Highest | Missing visible image and required access/index/token refresh |
| High | Upcoming images in the current reading direction |
| Medium | First images of the next readable episode near an episode boundary |
| Low | Explicit bulk downloads beyond the immediate reading window |
| Lowest | Offscreen covers and metadata refresh |

Start with one or two network transfers, prefetching roughly two or three upcoming compressed images to disk and retaining a recently visited image. Reconsider these values after device measurements. Disk and decoded-memory budgets must also constrain the window, especially for long images.

Merge duplicate requests from the reader and download manager. A visible-page request promotes existing queued work. Reserve foreground transfer capacity or safely cancel a running lower-priority read-only transfer when all slots are occupied; queue ordering alone does not prevent a long prefetch from blocking a newly requested page. Release the canceled worker/slot and preserve only a resumable partial file whose semantics are known. A jumped-to episode invalidates obsolete display callbacks through an owner/generation token, even if a completed download is retained in the cache.

On a genuine expired-token response, reacquire the token for the affected missing resource. Do not assume a fixed token lifetime from archived documentation, and do not repeatedly request fresh tokens for a permission or signing failure.

Apply bounded retry/backoff to read-only network failures. Pause or cancel prefetch on session changes, reader closure, network changes, low space, and relevant power transitions. Purchase transactions use a separate reconciliation policy.

### 4.3 Background execution

`UIManager:scheduleIn` and `nextTick` schedule callbacks in the main event loop; they do not make synchronous HTTP nonblocking. The UI loop must not perform slow image downloads, image conversion, or archive assembly.

Official `ReaderThumbnail` supplies a useful reference for subprocess work, pipes, polling, cancellation, and paired standby protection. The worker should perform bounded network/file work and report small status messages or committed paths. UI state and network-manager interaction stay in the main process.

`Trapper:dismissableRunInSubprocess` creates a modal trap widget, so it is a poor fit for silent reading prefetch. Its cancellation mechanisms remain a reference rather than an architecture to copy wholesale.

Do not inherit WeRead-specific platform restrictions. Current `runInSubProcess` source does not itself establish that Android is unsupported. Android and native Linux devices still need separate lifecycle, network, cancellation, and memory verification.

### 4.4 Download integrity and recovery

- Write each image into a `.part` file, verify the response and usable image data, then atomically commit it.
- Persist manifest changes atomically and recover interrupted manifests or partial files on restart.
- Track individual missing, pending, ready, and failed pages.
- Mark an episode complete only after every required image is committed and consistent with the manifest.
- Resume missing work rather than restarting a complete episode.
- Keep active reader files protected from eviction; pinning survives process restarts.
- Distinguish clearing automatic cache from deleting explicit downloads.
- Do not present an incomplete cached episode as a complete offline download. Partial offline reading may expose available pages with clear gaps.

Keep account-specific access metadata separate. Temporary access must retain its known expiry; downloading data does not change the access term. Unknown download/expiry semantics must be investigated instead of interpreting `is_download`, `is_locked`, or a successful index request as an unconditional permanent grant.

### 4.5 Long-image memory

Displaying only a cropped viewport does not prove that the decoder loads only that viewport. The earlier ImageWidget/RenderImage inspection found paths that hold the entire compressed file and a decoded frame before scaling. That is not a measurement of the native MuPDF CBZ path; native-reader memory behavior needs separate verification with the selected backend.

As an illustrative upper-bound case, a 1440 by 20000 image requires about 110 MiB for one RGBA buffer alone. Decoder buffers and scaled copies add to that. Pixel dimensions, not compressed file size, determine much of the risk.

Prefetch compressed files rather than decoded chapters. Coordinate native cache ownership and eviction, and validate dimensions before large allocations. If additional provider-owned decoded buffers are necessary, release them explicitly and avoid duplicate full-image copies. A provisional extra decoded-cache budget such as 16-32 MiB is only a tuning candidate, not proof that every image can be decoded within it.

The follow-up native-backend probe confirmed the format distinction: a 1200 by 16000 synthetic source rendered into a 600 by 120 viewport reached process peaks of 10,352 KiB for JPG, 120,864 KiB for PNG, and 121,208 KiB for WebP. These Linux backend-only values are not complete-reader or device budgets. The protocol/device feasibility gate must include a format-aware bounded-memory strategy for oversized images. Pre-splitting an image after a full decode does not solve the initial memory peak. See the [detailed evidence](native-reader-integration-research.md#33-long-image-memory).

### 4.6 Reading position

Persist at least:

```text
account_namespace
comic_id
ep_id
content_revision
image_index
normalized_source_anchor_x
normalized_source_anchor_y
view_mode
reading_direction
updated_at
```

This plugin-level identity/anchor supplements native document settings where needed; it does not require replacing KOReader's position handling. Keep both descriptor path and content stable for the same comic episode revision and prefer the same provider in online and pinned-offline modes. Explicitly bridge positions if opening a separate CBZ representation, because a different path/provider can have different document settings. Native continuous mode persists relative vertical position; ordinary page mode does not guarantee within-image restoration, so precise anchors in that mode remain plugin work. A changed source revision needs a best-effort remap rather than pretending that old image indices remain exact.

Local position is the first-release guarantee. The examined official reader calls `AddHistory` with only `comic_id` and `ep_id`; its page position is stored separately in local IndexedDB as `episode_id` and `page`. This establishes an episode-level history-write contract in the client, not page-level cloud synchronization. Any richer cloud progress feature requires its own verified contract and conflict policy; uploading an episode must not overwrite a more precise local anchor.

## 5. Integration boundaries

Proposed modules:

| Component | Responsibility |
| --- | --- |
| `SessionStore` | Session import/login lifecycle and account separation |
| `ProtocolAdapter` | Request contracts, errors, signing, encrypted responses |
| `LibraryRepository` | Favorites, history, metadata, and episode catalog |
| `EntitlementService` | Readability, purchase requirements, terms and refresh |
| `PurchaseService` | Quotes, explicit submission, pending-intent reconciliation |
| `ImageResolver` | Index retrieval, token refresh, supported image transformation |
| `PageStore` | Shared manifests, files, revisions, pins and eviction |
| `DownloadScheduler` | Priority, deduplication, workers, cancellation and recovery |
| `ComicDocument` | Proposed Document provider mapping stable episode pages to locally available image data |
| `ReaderIntegration` | Native ReaderUI lifecycle, episode actions, loading completion, prefetch hints, and position bridging |
| `LibraryView` / `EpisodeView` / `DownloadView` | Comic-oriented navigation and actions |

Use KOReader's official plugin and widget APIs. No component depends on a WeRead implementation or its EPUB/text-reading model.

### 5.1 Native reader integration options

| Route | Native reuse | Additional work | Role |
| --- | --- | --- | --- |
| Complete CBZ opened through ReaderUI | Existing MuPDF provider, page controls, zoom, direction and document settings | Acquisition, completed archive creation and comic metadata mapping | Direct supported path for completed offline episodes |
| Stable manifest and comic Document provider opened through ReaderUI | Existing reader UI, navigation, configuration and lifecycle | Page metadata/render contract, asynchronous missing-page scheduling, cache invalidation, redraw and module compatibility | Preferred investigation for immediate online reading and the same pinned-offline representation |
| Dedicated reading widget | Only lower-level widget/rendering facilities | New navigation, menus, settings, progress and lifecycle integration | Fallback requiring an evidenced gap in the native-reader routes |

`ReaderUI:showReader(file, provider)` checks that a local file exists. A stable local episode manifest can satisfy that requirement; the check is an integration condition, not a reason that streaming through a provider is impossible. The registry exposes `addProvider(extension, mimetype, provider, weight)`, and ReaderUI can also receive an explicit provider.

The online provider should expose a stable page count and image dimensions from the episode index before opening. It must implement the paged-document contract expected by native modules, delegate rendering to existing facilities where practical, and supply safe empty results/capability flags for inapplicable text functions. Fetching a missing image inside a synchronous draw method would still block the UI, so acquisition stays in workers and completion must invalidate the affected content and request an appropriate repaint or layout update.

The default `Document:drawPage` dereferences the tile returned by `renderPage`; a missing page cannot simply return nil or propagate a network error into painting. The research prototype guards `drawPage` and paints a transient missing state directly, allowing only ready images into native rendering. Full-page, scaled-fragment, inverted-drawing and thumbnail paths require their own handling; a generic viewport-sized tile is not a valid answer to every native render request. Override `hintPage` to provide queue hints without network work inside native synchronous rendering. On completion, check reader generation, update page-generation cache keys, and request repaint; unchanged dimensions should not force a zoom reset. If provisional dimensions changed, also update geometry and scroll page states. Basic missing-to-ready native repaint was verified using simulated file arrival; production worker and thumbnail integration remains open.

Do not assume that an open CBZ can simply grow as pages download. An ordinary incomplete archive and an already-open native document have no verified live-update contract here. The stable-manifest provider is a separate proposal intended to avoid depending on that behavior. Its prototype must verify missing-page handling, native cache invalidation, thumbnail/adjacent-page requests, cancellation, and reading-position preservation before it is treated as working integration.

## 6. Current PC protocol findings

The current first-party PC code is more complex than `GetImageIndex -> ImageToken -> download` alone. Keep the following mechanisms separate in the adapter:

1. Request signing for selected endpoints.
2. Decoding encrypted API responses.
3. Image-request metadata such as `m2` and token fields.
4. Conditional image transformation before an image is usable by the renderer.

The reader's protected-endpoint list includes `ComicDetail`, `ClassPage`, `GetImageIndex`, and `ImageToken`. For these endpoints, its request path calls a signing function and attaches `ultra_sign` and `x-bili-data-sn`. All requests through the shared POST wrapper receive `nov=27` and `a=810`; its PC HTTP client supplies `device=pc`, `platform=web`, and browser credentials. The signing function receives `device=pc&platform=web&nov=27&eot=812` and the serialized request body. This proves that the examined official PC client follows this path; it does not prove that all server clients require an identical signature.

The signing module loads Go WASM before invoking its signing function. Separate WASM modules participate in response decoding and image-related operations. Presence of a normal-image branch means that not every image should automatically be treated as encrypted; the decoder must follow the actual response contract.

### 6.1 Concrete source contracts

All endpoint paths below are relative to `https://manga.bilibili.com` and describe the examined client, not a validated public API.

| Operation | Path | Observed client contract |
| --- | --- | --- |
| Favorites | `/twirp/bookshelf.v1.Bookshelf/ListFavorite` | Uses `page_num`, `page_size`, `order`, filters, and `from/source=web` |
| History list | `/twirp/bookshelf.v1.Bookshelf/ListHistory` | Uses `page_num`, `page_size`, `type` |
| History write | `/twirp/bookshelf.v1.Bookshelf/AddHistory` | Body contains `comic_id` and `ep_id` |
| Image index | `/twirp/comic.v1.Comic/GetImageIndex` | Body contains `ep_id`, `m2`; optional query includes `cpx`, `m1` |
| Image tokens | `/twirp/comic.v1.Comic/ImageToken` | Body contains `urls` as a JSON-encoded path list and `m1` |
| Temporary token wrapper | `/twirp/comic.v1.Comic/ImageTokenTmp` | A wrapper with `paths` exists; no main-reader call site was found |

`GetImageIndex` maps business code `0` to normal access, `1` to purchase required, and `501` to episode unavailable. The current main reader consumes `data.images[]` with `path`, `x`, and `y`; old binary-index decoding helpers remain present but are not evidence that the binary-index path is mandatory today.

The protected-response handler decodes `bytesData` when present, using the actual request context, body, platform, and buvid. It also accepts the appropriate plain/error response branches. A response with `code=0`, null data, and no `bytesData` is treated as an error. Do not require `bytesData` on every response or treat an error payload as a missing decryption result.

The token path generates an ECDH P-256 key pair through WebCrypto. Public-key material becomes `m1`; the private material remains available for image processing. Token results include `token`, `url`, `complete_url`, and the exact field spelling `hit_encrpyt`. When that flag is false, the reader obtains an ordinary Blob; when true, it invokes the image conversion function with the complete URL, private-key material, and image index.

Consequently, a URL suffix cannot establish the usable on-disk format. The adapter must verify that it has a renderable image after the supported transformation. Neither free access nor paid access alone establishes which transformation branch will be used.

`ImageTokenTmp` is not an established fallback. Its presence outside the four-entry signing list does not prove that it is generally usable, unauthenticated, or compatible with the current reader.

### 6.2 Dependency inventory

The readable shared module `59HX` maps the following functions to resources:

| Purpose | Module export and called function | Resource |
| --- | --- | --- |
| Request signing | `I / w -> y1_z2w2a3` | [efae82c96a7eef44bee5.wasm](https://s1.hdslb.com/bfs/manga-static/manga-pc/efae82c96a7eef44bee5.wasm) |
| API response decoding | `D / T -> c1_r9k2m7` | [e461bfa6b471a22c06fc.wasm](https://s1.hdslb.com/bfs/manga-static/manga-pc/e461bfa6b471a22c06fc.wasm) |
| Processing used by the m2 path | `P / A -> a1_o8iso5` | [2ad56ae2f95bd54cf0b8.wasm](https://s1.hdslb.com/bfs/manga-static/manga-pc/2ad56ae2f95bd54cf0b8.wasm) |
| Image conversion | `T / _ -> a1_h17mj9` | [dda35c98742815151e46.wasm](https://s1.hdslb.com/bfs/manga-static/manga-pc/dda35c98742815151e46.wasm) |

The `m2` path also loads [XdNhUHQNH1.js](https://activity.hdslb.com/blackboard/static/20250424/79521623691a9889a71defd0f4d0a43b/XdNhUHQNH1.js) and [oAOxa2eJJd.js](https://i0.hdslb.com/bfs/activity-plat/static/20260129/79521623691a9889a71defd0f4d0a43b/oAOxa2eJJd.js), bridges the `59HX.P` and `59HX.T` exports, and invokes `h1_o8j1i2`. The second script uses VM-style obfuscation and includes environment-dependent logic. A portable implementation of this layer has not been established.

These are source-level dependency identifications. No WASM resource was executed, and no internal WASM algorithm was validated.

### 6.3 Entitlement and prefetch semantics

The reader maps `pay_mode` as `0=Free`, `1=Pay`, and `unlock_type` as `0=Locked`, `1=CoinOrCoupon`, `2=WaitFree`, `3=LimitedFree`. It also carries `is_locked`, `is_in_free`, `unlock_expire_at`, and `allow_wait_free`. Its UI distinguishes permanent access from waiting/free-period access. Preserve the full state rather than interpreting `is_locked=false` as ownership.

The web reader maintains nearby preloading and memory windows, next-episode thresholds, and a local token-refresh timer. In the inspected bundle, those include three nearby preload images in each direction, five nearby memory images in each direction, and a 300000 ms local token timer. These are browser-client choices, not KOReader defaults or proof of the server's exact token TTL. The plugin's disk prefetch and decoded-memory limits should be measured separately.

### 6.4 Packaging decision still open

A clean product UI is therefore feasible independently of the source of the protocol adapter, but a pure-Lua self-contained implementation is not yet established. First prototype the real signed, authorized read path in an isolated adapter. Evaluate a portable implementation and any required native/runtime dependencies before committing to packaging across KOReader devices.

A companion service is an architectural fallback to evaluate, not an assumed requirement or a chosen implementation. It would add deployment, credential-handling, and online availability dependencies. Offline reading must continue to work from completed local images regardless of whether the acquisition adapter is local or remote.

### 6.5 Remote observation

Environment: `ssh test-env`. No local tests or runtime probes were run.

One anonymous, read-only request was issued with these conditions:

```text
POST https://manga.bilibili.com/twirp/comic.v1.Comic/ComicDetail?device=pc&platform=web
Content-Type: application/json
Referer: https://manga.bilibili.com/
User-Agent: Mozilla/5.0
Body: {"comic_id": 36215}
No account cookies and no current PC signature
```

Observed response:

```text
HTTP status: 200
Business code: 99
Data: null
Message meaning: request failed; try again later
```

The probe stopped after that response. No image-index, token, CDN-image, login, wallet, or purchase request followed. The evidence cannot distinguish missing authentication, signing, environment checks, an IP restriction, or another backend condition. It must not be reported as successful free-episode access or proof of a specific rejection cause.

## 7. Purchase protocol without recharge

Current first-party source contains a complete purchase UI and distinct recharge UI. The plugin can implement the former while omitting the latter. This is a source-supported architectural conclusion; authenticated purchasing has not been tested.

### 7.1 Observed endpoints

All paths are relative to `https://manga.bilibili.com` and use POST in the examined client.

| Purpose | Endpoint | Observed business parameters |
| --- | --- | --- |
| Episode purchase information | `/twirp/comic.v1.Comic/GetEpisodeBuyInfo` | `ep_id` |
| Range-dependent purchase information | `/twirp/comic.v1.Comic/GetEpisodeBuyInfo?getEpisodeDiscounts` | `ep_id`, `buy_type`, `batch_limit`, `order` |
| Eligible discount cards | `/twirp/comic.v1.Comic/GetDiscountList` | `comic_id`, `order`, `original_values` |
| Discount calculation | `/twirp/comic.v1.Comic/CalDiscountPrice` | `id`, `original_values` |
| Purchase or wait-free unlock | `/twirp/comic.v1.Comic/BuyEpisode` | See the scope and asset fields below |
| Limited-free item access | `/twirp/comic.v1.Comic/RentEpisode` | `ep_id`, `item_id` |
| Account wallet | `/twirp/user.v1.User/GetWallet` | No business parameters; the base layer supplies `{}` |

The `?getEpisodeDiscounts` suffix is observed in the wrapper; it should not be generalized into an independently documented API version.

`BuyEpisode` always includes `buy_method`. The client constructs different scopes:

- Single episode: `ep_id`.
- Remaining content of a comic: `comic_id`.
- A quoted batch range: `comic_id`, `with_ord_scope=true`, `start_ord`, `limit`.
- Wait-free access: both `ep_id` and `comic_id`.

Depending on the chosen asset path, the wrapper can include `pay_amount`, `coupon_id`, `coupon_ids`, `free_gold_card_id`, and `free_gold_amount`. It can also send `auto_pay_gold_status` and `auto_pay_coupons_status`, which the plugin must not accidentally change during an ordinary purchase.

Observed purchase-method enum values are `1=AutoPurchase`, `2=ByCoupons`, `3=ByGold`, `4=ByWaitFreeChance`, and `5=BySilver`. The source also contains `ByLimitedFreeCard=-1`, but the actual limited-free item UI invokes `RentEpisode`; the enum alone does not justify sending `-1` to `BuyEpisode`.

Implement existing-currency and eligible-coupon purchases for single episodes and server-supported batch offers. Preserve extension points for wait-free, silver, limited-free items, and special discounts, enabling those paths only once their contracts and access terms are verified. These are different ways of obtaining access, not interchangeable permanent purchases.

`BuyEpisode` is outside the four-entry protected-read signing list. That does not establish that it is unauthenticated or exempt from server checks. The shared client uses browser credentials, and the examined purchase layer does not explicitly inject `bili_jct` as `csrf`. Default Axios XSRF support remains present. The actual cookie/CSRF/session requirements need authenticated verification.

### 7.2 Quoting and eligible assets

The purchase-information model includes episode prices and eligible assets, such as `pay_gold`, `ep_original_gold`, `ep_pay_coupons`, `ep_silver`, `remain_gold`, `remain_coupon`, `remain_silver`, `recommend_coupon_ids`, `allow_coupon`, `allow_item`, and `allow_wait_free`.

The `batch_buy` model contains `batch_limit`, `amount`, `original_gold`, `pay_gold`, `discount_type`, `discount`, `discount_batch_gold`, and `usable`. Build selection from supported, usable offers. Do not infer a batch total by multiplying a displayed single-episode price, and do not promise arbitrary noncontiguous multi-episode purchase in one request.

The official client can map `batchLimit > amount` to `limit=0`. The precise server meaning of that zero remains unverified. Reproduce only confirmed scope behavior; do not treat zero as an invented general-purpose wildcard.

Wallet totals are not proof that every asset is spendable on the selected episode. Show the general wallet in Account, but make the purchase sheet rely on current episode/range eligibility and quotation. Keep prices in the service's displayed asset units; do not invent a conversion to fiat currency from field names.

### 7.3 Submission and recovery

A proposed local transaction state machine is:

```text
selection -> quoting -> awaiting_confirmation -> submitting
submitting -> confirmed -> refreshing_access -> resume_original_action
submitting -> rejected -> refreshed_quote_or_actionable_error
submitting -> outcome_unknown -> reconciling
reconciling -> access_confirmed | still_unknown | new_quote_required
```

Persist a local purchase intent before submission, including account, exact intended episode set/scope, chosen assets, and quote fingerprint. This is a recovery journal, not a server idempotency key. No server idempotency key was found in the examined purchase wrapper.

The wrapper distinguishes errors for insufficient coupons (`1`), insufficient currency (`2`), changed auto-purchase settings (`3`), changed amount (`4`), and ineligible coupon use (`5`). Refresh and present the appropriate state; never silently change the payment method or enable auto-buy to work around an error.

If the response is lost, do not resubmit automatically. Refresh the exact requested episodes' access and the current purchase information. A balance change alone cannot prove which operation completed, and temporary access cannot prove a permanent purchase. For a partially unlocked batch, retain the unresolved episode set and obtain a new explicit quote before another submission. If the evidence remains ambiguous, retain `outcome_unknown` and provide a Refresh result action.

`GetPayOrders` is wrapped as `getRechargeHistory` and is polled by the recharge panel to match a recharge order ID. It is not evidence of a chapter-purchase status endpoint. Exclude it from purchase reconciliation until a chapter-specific contract is independently established.

After a confirmed purchase, the official UI reloads the episode, updates its local access model, and fetches comic details. The plugin should explicitly refresh the relevant entitlements, quote, and wallet before resuming the original Read or Download action. Prefetch and download workers never submit purchases themselves.

### 7.4 Source locators for follow-up work

These are zero-based UTF-16 character offsets in the original `reader.1ffe7bbf9d.js`, not line numbers. Prefer the class/method markers because another asset revision will move offsets.

| Area | Original marker | Offset |
| --- | --- | ---: |
| Purchase wrapper | `class _0x107fba` | 2526470 |
| Purchase-method enum | `_0x273109[_0x273109[` | 2701389 |
| Wallet model | `_0x7f6577=class` | 1606598 |
| Purchase-information model | `_0x3be4b2=class` | 3284481 |
| Batch-information model | `_0x43e04b=class` | 3269946 |
| Episode entitlement model | `_0x19d436=class` | 906536 |
| Purchase completion | `['onPurchaseDone']` | 3140426 |

Static string substitution aids inspection but does not prove that every branch in the obfuscated bundle is live. Conclusions above follow the actual wrapper and UI call paths; injected unrelated branches must not become protocol requirements.

## 8. Implementation and verification sequence

These stages are dependencies inside the required first release, not a reduction in feature scope.

1. **Protocol feasibility:** reproduce current signed requests and response handling; verify a free episode and an already-owned episode through a user-authorized session. Determine image transformation requirements and inspect rights/expiry fields. Establish an honest packaging plan for dependencies.
2. **Native reader integration:** build on the completed native-provider research spike. Finish geometry/DPI normalization, complete the native capability contract and real asynchronous acquisition, then verify cancellation, thumbnails, native settings combinations, memory limits and actual target devices. The tested core ReaderUI path does not require a replacement reader.
3. **Durable downloads:** add pinned manifests, queue recovery, cache reuse, full offline reading, storage limits and interruption handling.
4. **Explicit purchase:** implement current quote and submit contracts, asset eligibility, result reconciliation, and entitlement refresh. A real paid transaction requires separate authorization for the concrete transaction; research does not authorize spending.
5. **Product integration:** following/history/search, comic details, episode filters, account assets, and consistent loading/error/empty states.

All runtime verification belongs on `test-env` unless the user explicitly authorizes local verification in this task. KOReader integration and memory claims additionally require a suitable target device or representative remote environment; a generic server request cannot verify device rendering.

### Required acceptance scenarios

| Scenario | Required result |
| --- | --- |
| Open a readable online episode | First image becomes readable before all episode images finish downloading |
| Turn ahead or jump episodes | Foreground work takes priority; stale callbacks do not replace current content |
| Disable connectivity mid-read | Cached images remain readable; missing images report an actionable state |
| Complete and pin an episode eligible for offline access | Entire episode opens without network while its verified access terms remain valid; unknown or expired temporary access is a separate state |
| Restart after interruption | Completed pages survive; incomplete work resumes safely |
| Change reading mode/orientation | Source anchor remains stable within a documented tolerance |
| Encounter an oversized image | Bounded-memory handling or a clear supported-limit error; no unexplained crash |
| Prefetch reaches a locked episode | No purchase, asset deduction, or auto-buy configuration change |
| Quote changes before confirmation | Show the new quote and require a new confirmation |
| Purchase response is lost | Preserve a pending/unknown result and reconcile before any retry |
| Account changes | No mixing of entitlements, pending purchases, or local account metadata |
| Insufficient balance | Show the shortage and allow later balance refresh, without a recharge flow |

## 9. Sources

### Bilibili first-party source

- [Current homepage](https://manga.bilibili.com/)
- [Current example detail page](https://manga.bilibili.com/detail/mc36215)
- [Current example reader page](https://manga.bilibili.com/mc36215)
- [Homepage library and account chunk](https://s1.hdslb.com/bfs/manga-static/manga-pc-ssr/assets/chunks/chunk-A-ZFq6o-.js)
- [PC reader bundle](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/reader.1ffe7bbf9d.js)
- [PC shared signing and WASM integration bundle](https://s1.hdslb.com/bfs/manga-static/manga-pc/static/js/bili.9409128c39.js)

### Official KOReader source

Inspected KOReader revision: `c5c6f2d39264b0248ee8216780f842b0ea3c9488`.
Inspected koreader-base revision: `dd0e2522a1c2535c49b69f151a65fd506663c3a7`.

- [Plugin development guide](https://koreader.rocks/doc/topics/Development_guide.md.html)
- [OPDS online-image example](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/plugins/opds.koplugin/opdspse.lua)
- [ImageViewer](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/ui/widget/imageviewer.lua)
- [ImageWidget](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/ui/widget/imagewidget.lua)
- [RenderImage](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/ui/renderimage.lua)
- [ReaderUI](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/apps/reader/readerui.lua)
- [Native zoom and fit modes](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/apps/reader/modules/readerzooming.lua)
- [Native within-page navigation](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/apps/reader/modules/readerpaging.lua)
- [Native reader view](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/apps/reader/modules/readerview.lua)
- [Document registry](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/document/documentregistry.lua)
- [Document interface](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/document/document.lua)
- [CBZ document support](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/document/pdfdocument.lua)
- [UIManager event loop](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/ui/uimanager.lua)
- [ReaderThumbnail background work](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/apps/reader/modules/readerthumbnail.lua)
- [Trapper](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/ui/trapper.lua)
- [Subprocess and platform utilities](https://github.com/koreader/koreader-base/blob/dd0e2522a1c2535c49b69f151a65fd506663c3a7/ffi/util.lua)
- [Network manager](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/ui/network/manager.lua)

### Historical leads

- [Archive status](https://github.com/pskdje/bilibili-API-collect/blob/main/README.md)
- [Comic metadata](https://github.com/pskdje/bilibili-API-collect/blob/main/docs/manga/Comic.md)
- [Image acquisition](https://github.com/pskdje/bilibili-API-collect/blob/main/docs/manga/Download.md)
- [Account assets and auto-buy records](https://github.com/pskdje/bilibili-API-collect/blob/main/docs/manga/User.md)

`GetAutoBuyComics` must not be treated as a proven exhaustive list of all owned comics. Its historical response includes auto-buy settings and therefore requires separate coverage verification.
