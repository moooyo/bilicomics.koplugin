# Native Comic Reader Adapter

This directory implements a local-only paged `Document` provider for immutable `.bcomic` descriptors. It uses KOReader's native ReaderUI and MuPDF image backend. Network acquisition, account state, purchase, scheduling and file commits remain outside the reader.

## Integration

Register the provider once during plugin initialization:

```lua
local Provider = require("bilicomics/reader/document")
Provider:setServicesResolver(function(account_key)
    return account_services[account_key]
end)
Provider:register()
```

The resolver returns `{store, pages, authorizeDescriptor, requestPage?, onReaderEvent?, settings?, isCurrent?}`. `store` and `pages` implement `docs/development-contracts.md`. `authorizeDescriptor(descriptor)` is a required local-only permission check and returns `true` or `nil,error`. Opening fails closed without it, before reading page state or decoding. Rendering checks it again before using ready files or previously rendered tiles. Temporary thumbnail snapshots retain their expiration deadline; the parent rechecks permissions before accepting child results. `requestPage(descriptor,index,options)` is a nonblocking acquisition hint. `isCurrent()` rejects callbacks after an account/session switch. Supply `settings` as a plain table containing optional decode limits.

`ReaderUI:showReader(path, Provider)` opens asynchronously. During the plugin's `onReaderReady` handler, or a registered post-reader-ready callback, call:

```lua
local Integration = require("bilicomics/reader/integration")
local integration, err = Integration.attach(reader)
```

The attachment is idempotent for a reader instance. It installs narrow instance guards, takes one `PageStore:setActiveEpisode(...,true)` reference, restores a source anchor and issues visible/adjacent acquisition hints. Closing releases that reference once, captures progress, detaches the reader's work and restores guarded methods. Explicit downloads belong to the account service and may continue.

After a committed page update call `integration:notifyPageReady(page)`. Content changes repaint without resetting layout. Geometry changes recompute native layout and restore the normalized source position. `page` must carry `episode_id`, `revision`, `index`, oriented `width/height` and persisted content/geometry generations.

`onReaderEvent(name,event)` receives `{descriptor,reader_generation,reader,...}`. Names are `opened`, `position`, `near_end`, `end_of_book`, `page_error`, `anchor_error`, `suspend`, `resume`, and `closed`. Position events include `anchor`; near-end events include `index`; error events include a safe structured `error`. `closed` cancels reader-owned acquisition work in the account service. Suspend/resume scheduling and connectivity checks are also service responsibilities.

An end-of-book request is emitted at most once until `integration:finishTransition()` is called. The service should open the next readable chapter or show its explicit purchase action. Reset the pending transition if the user remains in the current chapter. End-of-book handling never purchases anything.

## Cold startup

Registration in a normal plugin initializer is too late when KOReader starts directly with a `.bcomic` last file. Official `reader.lua` selects the provider before it instantiates ReaderUI plugins. Moving registration to the top level of the plugin does not fix that ordering.

Production startup uses `bilicomics/bootstrap.lua` and the bundled `patches/2-bilicomics-provider.lua`. `Bootstrap.register(plugin_path?)` is idempotent and supplies a lazy resolver. The resolver initializes `Runtime.get(nil)` only when an actual descriptor is opened, checks the requested account key, and returns the active account's reader services. Controller initialization may replace that resolver without recursive lookup.

`Bootstrap.installStartupPatch(plugin_path)` copies the owned bootstrap into `DataStorage:getPatchesDir()` using an atomic rename and fsync. It returns `{path,installed,changed}` or `nil,error`. It preserves unrelated same-name files and rejects symlinks. The patch uses KOReader's supported late hook, after UIManager/CanvasContext initialization and before last-file selection. It registers a provider without replacing KOReader methods. Discovery checks the installed preferred plugin path, the standard plugins directory, user-data plugins and configured extra plugin roots, respecting disabled-plugin settings.

`Bootstrap.startupCapability()` reports a capability error for disabled patches and the F-Droid build, which disables the native user-patch mechanism. When bootstrap is unavailable, main should call `Bootstrap.prepareFallback()` after ReaderReady and on FlushSettings, with Exit as an additional hook. It removes and flushes only the `lastfile` entry for a descriptor inside this plugin's account document namespace. It preserves the user's `start_with` preference, native history, descriptor and source anchor. `start_with=last` with no `lastfile` takes KOReader to FileManager; the plugin can then reopen its cached chapter normally. Recheck capability at flush time so disabling patches during reading is handled. `Bootstrap.isOwnedDescriptor(path,data_root?)` exposes the ownership predicate; an optional explicit data root supports isolated integration tests.

The actual official `reader.lua` startup was tested in separate processes with the production plugin, Runtime, Controller, Store and a cached synthetic free chapter. The provider existed before normal plugins loaded, runtime creation stayed lazy, the native reader and integration attached, and expected image pixels were displayed. A separate two-process scenario disabled patches, exercised normal reader close, verified FileManager startup with history/anchors retained, and reopened the cached chapter at the same position. See the startup result files under `spec/reader/`.

## Geometry and native ownership

The acquisition worker supplies validated source dimensions and orientation:

```lua
{
    width = oriented_width,
    height = oriented_height,
    geometry = {
        source_width = raw_width,
        source_height = raw_height,
        exif_orientation = 1, -- EXIF 1..8
    },
}
```

Orientations 5 through 8 exchange the logical width and height. Native DPI units are measured locally when opening the image and mapped to those logical pixels. Worker-side DPI arithmetic is unnecessary. Persist the source metadata with the page; do not infer orientation from dimensions alone.

On official KOReader v2026.07.1, the JPEG backend applies EXIF orientation; PNG eXIf and WebP EXIF are ignored by the backend. The adapter compensates for the latter. All eight directions were rendered with synthetic fixtures in each format. `geometry.native_orientation` is an explicit override for another native implementation and must represent measured behavior.

The common unrotated, equal-axis path renders directly through MuPDF. Other orientations and unequal-axis DPI use a bounded cropped intermediate buffer with nearest-neighbor sampling. This avoids allocating a full *destination* image, but cannot prevent a codec from decoding its full *source*. Native page and owning image-document handles are closed together, including render exceptions. Only one image handle is active per provider at a time. Prefetch acquires compressed files without decoding them.

Default limits are 4,000,000 source pixels for PNG/WebP, 32,000,000 for JPEG, 16 MiB per destination tile and 2,000,000 additional intermediate pixels. These are conservative guards, not device benchmarks. Override `max_lossless_pixels`, `max_jpeg_pixels`, `max_tile_bytes` and `max_intermediate_pixels` only for a validated device profile. Oversized or unusable local content produces an explicit unavailable state and a `page_error` event. The account UI can explain the need for a smaller or segmented source. No unbounded conversion fallback is attempted.

## Missing content and caches

All page geometry queries are synchronous local reads. Ready image files alone enter completed render caches. Hashes include immutable descriptor identity and stored content/geometry generations. Corrupt-image failure state is scoped to that generation.

Ordinary and inverted draws paint an unavailable region without opening an image backend. Full-page/cover and selection requests return `nil` while missing. Direct partial `renderPage` requests return a correctly sized nonpersistent `comic_transient` tile; a direct caller owns that transient tile and must call `onFree()` after use. The provider's ordinary draw paths bypass this allocation. Missing cover or thumbnail results are never stored as successful content.

Native thumbnail children receive a parent snapshot and use only ready local files. They cannot query the parent's SQLite connection or enqueue acquisition. Each request includes the reader and page generations. The instance wrapper rejects stale results **before cache insertion**, and keeps that guard until an already-running child is collected after reader close. Native subprocess collection and standby handling remain in KOReader's thumbnail module.

## Progress

Long images default to native width fit plus continuous mode; other pages default to page fit. Existing per-document settings remain in effect after initialization. Anchors retain normalized un-oriented source coordinates, page identity, reader mode and the geometry generation. Ordinary page mode, continuous mode and free zoom with horizontal panning have separate process-restart tests. Geometry correction preserves the source anchor. Capture occurs after settled navigation, at close and before suspend, never on every paint.

## Verified scope and remaining limits

The executable suite runs only on `ssh test-env`, against the unmodified official Linux x86_64 KOReader v2026.07.1 runtime with a 600 by 800 SDL screen. It uses synthetic assets and disables bundled plugins to isolate core behavior. See `spec/reader/native-results.json` and `spec/reader/README.md`.

This evidence does not establish physical e-ink refresh behavior, Kindle/Kobo/Android memory limits, other KOReader releases, or compatibility with every third-party plugin. The anisotropic/orientation fallback uses nearest-neighbor sampling; its speed and visual quality need target-device measurement. Oversized inputs require a supported acquisition/preparation strategy. Actual Bilibili content access and purchases are separate integration gates.
