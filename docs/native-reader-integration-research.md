# Native KOReader Integration: Detailed Research and Remote Evidence

Date: 2026-09-12.

Use the [implementation plan](implementation-plan.md) for the finalized architecture, first-release scope, module ownership and delivery gates.

This report refines [the product and protocol research](product-and-protocol-research.md). The product requirements remain: independent comic-oriented business UI, native KOReader reading where practical, online reading with prefetch, complete offline downloads, and explicit purchase without recharge.

## 1. Decision

Use **native `ReaderUI` with a comic `Document` provider and a composite backend that renders completed local images through MuPDF**. Independently implement the library, chapter, purchase and download screens. Keep network acquisition outside synchronous native layout and painting.

This is now supported by a running research prototype, not only by source inspection. On `test-env`, the provider opened in the official KOReader reader, rendered a region inside a long image, advanced through the image using native paging, restored the relative position after a process restart, and replaced a missing page when its file became available without resetting the viewport.

The research prototype is not the plugin implementation. It uses synthetic images, disables bundled plugins to isolate native core behavior, and simulates image arrival by committing a file from an event-loop callback. It does not implement HTTP, authentication, purchase, a download queue, real worker IPC, thumbnail recovery, or all reader features.

## 2. Evidence boundaries

| Evidence | Exact environment | What it establishes |
| --- | --- | --- |
| Static native-reader inspection | `koreader@c5c6f2d39264b0248ee8216780f842b0ea3c9488` | Current source contracts, event ordering, cache and position mechanisms |
| Static native-backend inspection | `koreader-base@dd0e2522a1c2535c49b69f151a65fd506663c3a7`, MuPDF 1.27.2 and bundled patches | Image-format, drawing and decoding behavior |
| Provider and ReaderUI execution | Official KOReader `v2026.07.1`, Linux x86_64, Xvfb, 600 by 800 SDL screen on `test-env` | The tested integration behavior works in that release and environment |
| Backend execution | The same release's MuPDF 1.27.2, separate Lua processes, generated JPG/PNG/WebP | Format opening, directory/CBZ opening, regional rendering, DPI behavior and sample memory peaks |

The release asset was `koreader-linux-x86_64-v2026.07.1.tar.xz`, SHA256 `299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0`. It was downloaded from the [official release](https://github.com/koreader/koreader/releases/tag/v2026.07.1), verified against the release asset digest, and extracted to an isolated remote temporary directory. The runtime source was not modified, and no global dependency installation was performed.

All runtime probes ran remotely. No local tests, builds or runtime verification ran. Results do not establish Kindle/Kobo/Android behavior, real e-ink refresh quality, battery behavior, or successful Bilibili access.

## 3. What was actually verified

### 3.1 Native reader integration

The [provider result file](../research/native-reader/provider-probe-results.json) records 21 passing assertions across four separate Lua processes/modes.

| Probe | Observation |
| --- | --- |
| Composite document | Two logical pages were exposed through a real registered provider |
| Geometry of missing content | Dimensions of the unavailable second image were answered without opening its native image backend |
| Native regional drawing | A region in the middle of a 600 by 2400 PNG contained the expected source pixels |
| Missing-page behavior | Drawing unavailable content used a temporary surface state and did not call the native backend |
| Completion in the same document | Committing the image made the same logical page render real pixels |
| Cache identity | A page generation changed the render key even within the same second |
| ReaderUI integration | Native paging and zoom modules initialized with the provider |
| Within-image advance | One native viewport advance remained on image 1, at relative y `0.3145833333333333` |
| Process restart | Native continuous-mode restoration returned y `0.31458333333333` on the same image |
| End-of-document integration | An instance-scoped child intercepted the event without adding a stock end dialog |
| Asynchronous completion simulation | The native UI displayed and moved within a missing image; a later callback committed it and repainted it |
| Viewport preservation | Relative y remained exactly `0.471875` before and after simulated completion |
| Close lifecycle | The native reader and registry references closed cleanly in the tested paths |

The completion simulation demonstrates that a worker-completion callback can update native content without reopening the reader. It does not demonstrate network transfer responsiveness or worker cancellation. Those remain separate engineering and verification tasks.

Screenshots contain deliberately simple grayscale test bands, not manga content: [waiting state](../research/native-reader/ui-waiting.png), [completed state](../research/native-reader/ui-online.png).

### 3.2 Native format and geometry handling

The [backend result file](../research/native-reader/backend-probe-results.json) records successful opening and regional pixel checks for JPG, PNG and WebP single images; a mixed-format three-page CBZ; and a directory containing the same images.

Direct `ffi/mupdf.openDocument` can identify WebP in this release, even though extension registration in `PdfDocument` differs. Provider routing should be explicit rather than relying on the generic image-extension association.

**MuPDF image geometry is not always expressed in original image pixels.** A 360 by 1200 image at 72 DPI returned 360 by 1200 native units; the same dimensions at 300 DPI returned 86.4 by 288. Scaling by target width divided by native width produced correct cropped content.

The provider prototype uses 72 DPI fixtures. It has not implemented general DPI normalization. Production integration must define a consistent geometry contract between API pixel dimensions, image-header resolution, native page units, zoom, and source anchors. Do not copy the prototype's pixel-sized manifest into production without this work. Anisotropic resolution and orientation metadata also need explicit handling.

### 3.3 Long-image memory

Separate native-backend processes rendered only a 600 by 120 viewport from the same 1200 by 16000 source pattern:

| Format | Process VmHWM | Approximate MiB |
| --- | ---: | ---: |
| JPG | 10,352 KiB | 10.1 |
| PNG | 120,864 KiB | 118.0 |
| WebP | 121,208 KiB | 118.4 |

These are observed high-water marks for the specific synthetic samples and minimal backend processes, not full-reader memory budgets or device benchmarks. Compressed sizes were very different, and the lossless sample compressed especially well; neither compressed file size nor viewport dimensions predicts the source decode allocation.

Static code explains the result: PNG and the bundled WebP path decode the full source image; the WebP patch can briefly hold decoded RGB/RGBA data and a same-sized MuPDF pixmap. JPEG can use native subsampling and stream filtering. Native viewport rendering limits destination buffers but is not a general bound on source decoding.

The first implementation needs a pixel/format-aware oversized-image policy. Prefer supported source resolution/segmentation if available. If transformation is necessary, the transformation itself must fit the device budget or run in a separately supported acquisition environment. Splitting an image after first decoding the whole thing does not remove the initial peak. This issue persists whether the reader UI is native or custom.

## 4. Recommended content representation

Use one immutable episode descriptor for both online and pinned offline reading. It identifies the account namespace, comic, episode, content revision, ordered source-image identities and initial geometry. Use a dedicated extension and provider key. The `.bcomic` extension in the probe is only a research placeholder.

Keep mutable state in a separate store:

- Image availability, file paths/checksums and download progress.
- Temporary CDN tokens and session data.
- Access terms, purchase outcomes and entitlement refresh time.
- Pinning, retry state and per-page generation.
- Supplemental source anchors if the selected native mode needs them.

Both the descriptor path and its content should remain stable for a content revision. Native metadata can be keyed by path or by a partial content hash, depending on user settings. Rewriting download progress into the document descriptor can therefore change its metadata identity even at the same path.

Explicit download means completing and pinning this same page set. Offline opening then uses the same provider and descriptor, with zero network work for available content whose access terms permit offline reading. Do not automatically switch to a new CBZ pathname at completion: that creates another document-settings identity and requires a progress bridge.

Complete CBZ export remains directly supported. MuPDF can also open a complete image directory, as verified, but `ReaderUI:showReader` expects a file and the directory's page list is formed when opened. Directory support is a backend option, not a ready-made solution to dynamic online page discovery.

## 5. Document provider contract

Prefer extending `document/document` and composing a local MuPDF backend. Inheriting `PdfDocument` while replacing only its initializer retains PDF/KOpt/annotation/writeback assumptions that are not necessary for a comic provider.

### 5.1 Opening and capabilities

```text
ReaderUI:showReader(stable_descriptor, provider)
  -> DocumentRegistry:openDocument
  -> Document:_init -> provider:init
  -> ReaderUI modules and document settings
  -> layout -> ReaderReady -> native paint
```

Use `DocumentRegistry:addProvider(extension, mimetype, provider, weight)` or an explicit provider. There is no `registerDocumentProvider` API in the inspected source.

Paged documents do not use the reflowable document `loadDocument`/`render` opening path. `init()` must finish with a valid full page count and geometry that can be queried without downloading images.

| Field | Required treatment |
| --- | --- |
| `provider`, `provider_name` | Stable provider identity |
| `info.has_pages` | `true` |
| `info.number_of_pages` | Full ordered count from the prepared index |
| `info.configurable` | Initially `false` if KOpt configuration is not implemented |
| `is_open` | True only after successful initialization |
| `is_locked` | Native password-lock flag; never reuse for purchase requirements |
| `is_pdf` / `is_djvu` / `is_reflowable` | Do not claim unsupported capabilities |
| `is_pic` | Deliberate choice; the stock statistics plugin treats image documents specially |
| `mod_time`, `render_mode` | Valid values required by inherited render hashing |
| `configurable` | Still requires real defaults despite `info.configurable=false` |

Initialize supported numeric options, including `text_wrap=0`, `writing_direction`, `trim_page`, `page_margin`, `background_cleanup`, and `page_scroll`. Call native color-rendering initialization and keep the image backend consistent with it.

### 5.2 Minimum methods and return shapes

| Responsibility | Methods and contract |
| --- | --- |
| Metadata | `getDocumentProps()` returns a table; `getToc()` returns an array, even when empty |
| Geometry | `getNativePageDimensions()` returns positive `Geom.w/h`; `getUsedBBox()` returns valid `x0/y0/x1/y1`, including for missing images |
| Count | Inherited `getPageCount()` reads `info.number_of_pages` |
| Ready-image rendering | Composite backend `openPage(n)` opens the local image with MuPDF; page drawing supports context, offsets and close |
| Missing images | Guard drawing before native image opening; present transient loading/error state |
| Native hint | `hintPage()` supplies a queue hint rather than synchronous network work |
| Resource release | Close page and owning native image document; preserve DocumentRegistry reference-count semantics |

The composite engine can be a Lua object. It does not need to pretend to be a single native MuPDF document, provided its pages delegate the actual drawing operations to a correctly owned native page.

Geometry queries are part of layout, scrolling, zooming and adjacent-page hinting. Overriding `hintPage` alone is insufficient: `ReaderHinting` obtains the next page's zoom first, which can request missing-page dimensions and bounds.

Text and image-selection stubs have different shapes. `getTextBoxes()` must return `nil` for no text, not `{}`, because a native line-count path dereferences the first entry of a truthy table. Explicitly handle absent methods such as `getWordFromPosition`, `getOCRText`, `getPanelFromPage`, `getPageBlock`, and position-selection helpers. Free zoom additionally needs numeric `page_margin`. Empty metadata and TOC, unlike absent text, must be tables.

The probe covers enough of this contract to initialize native core and execute its tested modes. It is not a complete capability implementation for every menu, gesture or third-party plugin.

## 6. Missing pages, caches and workers

### 6.1 Rendering paths must be distinguished

Native `renderPage` can request a full page (`rect=nil`), an ordinary page rectangle, or an explicitly scaled fragment (`rect.scaled_rect`). It normally prefers a full scaled tile and only falls back to the visible rectangle when the cache budget rejects a full tile.

Do not return a generic screen-sized tile for every request. For an ordinary placeholder tile, `bb` dimensions and `excerpt` must match the requested rectangle because native blitting subtracts the excerpt origin. Fragment requests and full-page hint requests follow different contracts.

A simpler guarded path, used in the research prototype, draws a missing-state rectangle directly in provider `drawPage`, and lets only ready pages enter inherited native rendering. Production work must also cover inverted drawing, fragment/image selection, covers, page browser and thumbnails; guarding ordinary `drawPage` alone is not complete.

### 6.2 Generations, not only timestamps

Native render keys include document identity, modification time, page and render parameters. Use a per-page content generation for completed/replaced content. Keep geometry stable where known; refresh dependent geometry if it genuinely changes.

`resetTileCacheValidity()` is not sufficient by itself. It uses second-resolution time and accepts a tile with `created_ts >= validity_ts`, so a same-second replacement can retain an old tile. It also does not clear cached dimensions. The probe changes cache keys with a generation; it does not establish full production eviction/recovery behavior.

For unchanged geometry, update availability/generation and call `UIManager:setDirty(reader.dialog, "partial")`. The remote completion probe verified that this preserves the existing relative viewport. Avoid a blanket `RedrawCurrentPage`/`PageUpdate`, which can rebuild layout. A real geometry correction should save an anchor, recalculate and restore deliberately.

### 6.3 Thumbnail processes are separate

`ReaderThumbnail` forks and renders using a copied reader/document state. A provider call inside that child cannot update the parent's ordinary Lua queue. Completion should be coordinated in the parent or use explicit IPC.

Prevent missing-image thumbnails from becoming durable success results. Thumbnail cache invalidation must also reject stale in-flight results: clearing a cache or canceling callbacks does not necessarily terminate the child that is already rendering, and its returned image can otherwise repopulate the cache.

For the first implementation, permit thumbnails only for ready files and provide a distinct unavailable state. Full online thumbnail generation requires request generations and completion filtering.

### 6.4 Service lifetime

Use an account-scoped download service separate from each ReaderUI/plugin instance. A reader session owns priority hints and subscriptions; explicit downloads can outlive closing that reader. On `CloseDocument`, detach callbacks and cancel reader-owned prefetch. Account changes invalidate account generations so old results cannot affect the new account.

Before suspend, pause relevant network work; after resume, wait for actual connectivity. Pair standby acquisition/release exactly once per job. A standby lock does not mean a user-initiated suspend cannot occur.

## 7. Native progress and chapter transitions

### 7.1 Progress

Native paging persists `last_page` and `page_positions`. Continuous mode stores a relative vertical position within the source page; ordinary page mode's `getTopPosition()` returns zero. Native runtime location objects can preserve more viewport state but are mode-dependent and are not a universal cross-mode persistence format.

The recommended initial long-strip mode is **width fit with native continuous mode**, using tap/page-key viewport advancement. That combines native image navigation with native relative-position persistence, and the remote restart probe confirmed it for the synthetic chapter.

For precise resume in ordinary page mode, horizontal panning, arbitrary mode changes or source revisions, add supplemental normalized source anchors. Do not advertise those untested behaviors as already covered by the successful continuous-mode test.

### 7.2 Chapter ending

The stock ReaderStatus is registered before ordinary plugin instances. A normal plugin `onEndOfBook` handler may therefore run after a stock dialog or action has already occurred.

An instance-scoped solution is to insert a narrow child event listener at the front of the current reader's `status` container, intercept only `EndOfBook` for this provider, and return true. The remote probe confirmed that this path intercepts the event without adding a stock dialog. This is container-based integration, not a dedicated stable EndOfBook registration API; include it in version-compatibility checks.

Schedule the actual next-episode reader opening on the next UI tick, following the stock reader's lifecycle pattern. The probe did not implement a real next-episode open or purchase screen. Before enabling automatic chapter advance, verify lifecycle teardown, event duplication, pending workers and the stock next/delete actions.

At a locked boundary, show the explicit purchase action. Neither native hinting nor the download service may purchase automatically. Successful purchase refreshes access before resuming the pending read/download operation.

## 8. Work remaining before production

The native reading route has passed its initial feasibility gate. The remaining work has clear boundaries:

1. Verify the current Bilibili signed, authorized acquisition path and actual image metadata. Previous protocol research still applies; these native probes do not resolve authentication or image conversion.
2. Implement geometry normalization, orientation handling and a format-aware oversized-image policy. Test real chapter assets only under authorized access.
3. Replace the prototype's file-arrival simulation with real workers, bounded download scheduling, deduplication, cancellation, recovery and parent/child IPC.
4. Complete provider capabilities: all supported zoom/pan modes, inverted rendering, fragments, thumbnails, page browser, covers and native settings combinations.
5. Implement stable descriptor/mutable-state separation, pins, corruption handling, content revisions and supplemental anchors where needed.
6. Integrate following/history/search, purchase and download UI with the native reader lifecycle.
7. Verify representative e-ink Linux and Android targets, including limited memory, suspend/resume, network switching, rapid navigation and third-party plugin coexistence.

The scripts in [the research directory](../research/native-reader/README.md) are reproducible evidence and starting points for a focused implementation spike. They are intentionally not installed as a `.koplugin`.

## 9. Primary source map

All KOReader links below are pinned to the inspected revision.

- [ReaderUI opening and module ordering](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/apps/reader/readerui.lua)
- [Document and render contract](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/document/document.lua)
- [DocumentRegistry and reference counting](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/document/documentregistry.lua)
- [DocSettings path/hash identity](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/docsettings.lua)
- [Native zoom](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/apps/reader/modules/readerzooming.lua)
- [Native paging and persisted positions](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/apps/reader/modules/readerpaging.lua)
- [ReaderView rendering](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/apps/reader/modules/readerview.lua)
- [Synchronous hinting](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/apps/reader/modules/readerhinting.lua)
- [Thumbnail subprocess and caches](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/apps/reader/modules/readerthumbnail.lua)
- [ReaderStatus end actions](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/apps/reader/modules/readerstatus.lua)
- [WidgetContainer event propagation](https://github.com/koreader/koreader/blob/c5c6f2d39264b0248ee8216780f842b0ea3c9488/frontend/ui/widget/container/widgetcontainer.lua)
- [MuPDF Lua bridge](https://github.com/koreader/koreader-base/blob/dd0e2522a1c2535c49b69f151a65fd506663c3a7/ffi/mupdf.lua)
- [PicPage drawing implementation](https://github.com/koreader/koreader-base/blob/dd0e2522a1c2535c49b69f151a65fd506663c3a7/ffi/pic.lua)
- [MuPDF build and patches](https://github.com/koreader/koreader-base/blob/dd0e2522a1c2535c49b69f151a65fd506663c3a7/thirdparty/mupdf/CMakeLists.txt)
- [Bundled WebP support](https://github.com/koreader/koreader-base/blob/dd0e2522a1c2535c49b69f151a65fd506663c3a7/thirdparty/mupdf/webp-upstream-697749.patch)
- [MuPDF source image decoding](https://github.com/ArtifexSoftware/mupdf/blob/1.27.2/source/fitz/image.c)
- [MuPDF directory/archive opening](https://github.com/ArtifexSoftware/mupdf/blob/1.27.2/source/fitz/document.c)
- [MuPDF CBZ handler](https://github.com/ArtifexSoftware/mupdf/blob/1.27.2/source/cbz/mucbz.c)
