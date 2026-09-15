# BiliComics for KOReader

A Bilibili Comics plugin with its own comic library UI and KOReader's native reader. The implementation follows [the agreed plan](docs/implementation-plan.md) and [the UI design](design/ui-spec.md).

## Development status

The latest approved UI is implemented in the native plugin, including the compact
bookshelf and QR recharge flow. The payment-code view uses one action row with
Check credit on the left and Close on the right. Manual recharge input must match
an amount from the current official configuration. The installable candidate is
generated as `dist/bilicomics-ui-recharge-20260915.zip`, with an adjacent
`.manifest.json` file. These local build artifacts are excluded from Git; use
the remote packaging workflow below to reproduce them. The
[package checks](spec/package/ui-recharge-results.json) record the delivered
archive. See the
[native previews](design/recharge-preview/index.html) and
[recharge implementation evidence](docs/recharge-api-investigation.md).
Remote synthetic checks cover both 600 by 800 and 480 by 640 layouts; real
recharge creation and payment have not been exercised.

The earlier [finishing work](docs/finishing-plan.md) adds QR-session site
initialization, the quiet bookshelf with automatic synchronization and restored
view state, and 1–4 concurrent image downloads (default 2). All 34 common
synthetic suites pass; actual parallel workers and focused UI/controller checks
also pass. Fresh phone-confirmed login, restart, and a complete real 45-page
online/download/offline workflow passed on the same production source, including
observed two-image concurrency. See [the final acceptance](docs/finishing-acceptance.md).
The canonical archive and `dist/bilicomics-finishing-preview.zip` have identical bytes.

The current [Bookstore subject browsing](docs/bookstore-categories.md) adds the
official category selector to the compact recommendation grid. Navigation is Bookshelf,
Bookstore, Search and Downloads; the cover-grid Bookshelf remains the default.
Bookshelf cards show the title and current reading position. Bookstore
combines four official homepage sections with deduplication, showing six cards
at 600 by 800. Cards show the title, source and tag; tap opens chapters and hold
opens the full synopsis. All recommendations uses one anonymous homepage request.
Choosing a subject loads its official popularity-ordered catalog, with separate
cached pages and anonymous device initialization. Saved results remain browsable
offline, and the existing next-page arrow loads additional category results.
Both grids use bounded official cover thumbnails for visible cards only.

The earlier [architecture stabilization](docs/architecture-stabilization.md)
fixes purchase dispatch expiry and download completion during persistent storage
failures. All 34 unified remote suites pass, and the matching production tree
passes real 45-page online/download/offline workflows remotely and on local
KOReader under WSL. Real QR login, private saving and independent-process login
restoration also pass. The user selected local KOReader acceptance instead of a
physical Scribe gate and deferred actual credential rotation after the service
reported that renewal was unnecessary. Actual payment and physical-device
compatibility are not claimed.
Historical results below retain their original source snapshots.

That completed work was merged into `main` at `e86f894`. See the
[progress recovery record](docs/progress-recovery.md) for its historical delivery,
its evidence, and the explicitly deferred release work.

The plugin is a development implementation, not a completed release. A complete real free chapter passes [native online reading, prefetch, retained download and new-process offline reopening](docs/reading-only-test-report.md): 45 pages, 92,022,101 image bytes, 51 online checks and 30 offline checks. Downloading continued after reader closure; offline reopening restored the source anchor with no session, no network routes and zero worker activity.

On 2026-09-13 the user authorized all operations other than actual purchasing. Authenticated quote and wallet reads and isolated synthetic purchase checks have now run. No actual purchase, coupon consumption, rental, recharge or account write was performed. See [the non-purchase integration report](docs/nonpurchase-integration-report.md) and [implementation status](docs/implementation-status.md) for exact evidence scopes.

The integrated [quote-selection adapter](docs/quote-selection-implementation.md) supports single chapters and strict standard-currency ordinal batches. Real captured responses successfully constructed both a positive batch offer and an explicit remaining-range offer. The UI distinguishes the server-supported range from its currently expected chapters; the server does not echo an atomically fixed member list. Additional discounts remain advisory. Actual charging and physical Scribe acceptance remain unverified.

The target first release includes online reading with prefetch, complete offline downloads, and explicit purchases using existing account assets. The approved development UI additionally implements explicit QR recharge. Automatic purchasing remains excluded. No WeRead implementation is reused.

QR sign-in and session renewal are implemented in the development source. A dedicated account session manager serializes renewal, saves replacement credentials before confirmation, and preserves business receipts independently of cookie persistence. See [the authentication implementation and verification boundaries](docs/session-renewal.md). Real mobile-app sign-in, private persistence, restart and the normal session check have passed. The service returned `refresh=false`; actual rotation and old-token confirmation remain deferred acceptance, and no unlimited login lifetime is promised.

## Installation target

The initial verified runtime baseline is KOReader v2026.07.1 on the remote Linux emulator. A production package must pass its declared device/platform matrix before other platforms are advertised as supported.

The user-requested local Windows acceptance environment is now available through Debian WSL2/WSLg. [Start the real KOReader UI](tools/start-local-koreader.ps1) with an isolated profile and an acceptance-only guard that rejects purchase and account-mutating requests. Native Chinese UI startup passed locally; session import and manual reading instructions are in [the local acceptance guide](spec/local/README.md). This is separate from physical Scribe acceptance.

The declared target is first-generation Kindle Scribe on firmware 5.19.3. [Official koxtoolchain guidance](https://github.com/koreader/koxtoolchain/blob/2026.08/README.md) selects `kindlehf` for firmware >= 5.16.3. An [ARM compatibility correction](docs/kindle-native-compatibility-fix.md) now keeps native relocation tables adjacent for older glibc while retaining BIND_NOW and GNU RELRO. The rebuilt libraries passed nine QEMU primitive checks each with Debian glibc 2.41 and toolchain glibc 2.20 using a separately corrected diagnostic loader. No loader is packaged, and physical Scribe compatibility remains untested.

Copy the packaged `bilicomics.koplugin` folder into KOReader's `plugins` directory. The entry appears under the Tools menu. In the authentication development build, open Account and settings and choose **Sign in with QR code**, then scan and confirm with the Bilibili mobile app. Existing browser-session import remains available. For Scribe, copy `bilibili.txt` by USB into an accessible Kindle folder you choose, then use **Import from file** and browse to it with KOReader's native file picker. Masked paste remains available; supported text/JSON/cookie files are limited to 128 KiB. See [session import instructions](docs/session-import.md). The original focused importer passed 42 checks at each of 600x800, 480x640 and 1860x2480; the last size is emulated layout evidence.

Session files are account-scoped; Android uses the app's private files directory for sessions and verified native libraries. Downloaded content remains in KOReader's account-specific data directory.

For cold-start restoration of `.bcomic` files, the plugin installs its owned `2-bilicomics-provider.lua` bootstrap into KOReader's supported user-patch directory. This only registers the document provider before KOReader selects its startup file; it does not modify KOReader core code. An unrelated file at the same path is never overwritten. Where startup patches are disabled or unavailable, the plugin preserves reading progress and uses FileManager startup instead of an unregistered comic file. The plugin UI can still open locally stored chapters.

## Architecture

- Native `ReaderUI` with an immutable `.bcomic` descriptor and a MuPDF-backed Document provider.
- SQLite metadata and durable page, download and purchase generations.
- Isolated worker processes for network acquisition; UI/layout paths only read local state.
- Explicit quote confirmation and durable purchase intents, with uncertain-result reconciliation instead of automatic resubmission.

See [development contracts](docs/development-contracts.md) for module interfaces and individual `spec/` documentation for verification scope.

## Verification and packaging

Runtime checks must run through `ssh test-env` unless local verification is explicitly authorized in the current task. Keep credentials in `.secrets/` or another private location; `.secrets/`, research assets, design prototypes and test fixtures are excluded from the production package allowlist.

The packaging script is `tools/package.py`. Execute it on the remote environment after integration checks; it writes a deterministic ZIP and file-hash manifest. Native protocol binaries and their platform compatibility remain explicit package dependencies.

The latest approved UI candidate is `dist/bilicomics-ui-recharge-20260915.zip`.
The preceding finishing candidate remains `dist/bilicomics-0.1.0-dev.zip`, with its exact adjacent
manifest. The [finishing package/source record](spec/package/finishing-acceptance-binding.json)
identifies this revision and its complete remote acceptance. No session, acquired
comic content or diagnostic loader is included.

The earlier 101-file stabilization candidate is retained under
`dist/history/stabilization-45385c6f/`. Its [34-suite regression](spec/integration/stabilization-regression-results.json)
and [local acceptance addendum](spec/package/local-acceptance-source-evidence.json)
remain evidence for that earlier production tree, not a repeat of whole-chapter
or live-account acceptance for the finishing revision. Authentication-only,
ordinal preview and older integrated archives are historical candidates.

The archive retains the session file importer, reader prefetch policy and previously live-tested image protocol fixes. Same-snapshot recovery verifies historical image bytes before updating mutable addresses. Unknown or changed content requires the separate [new-version confirmation](docs/partial-download-recovery.md): both versions remain pinned and independently removable, the new version starts from the beginning, and the old version reads cached pages only. The current [ordinal range contract](docs/ordinal-range-contract.md) has focused construction, UI and transaction-recovery evidence. The earlier ordinal integration did not repeat the complete live reading workflow; the subsequent stabilization records establish that workflow for their preceding candidate. The final finishing run repeats it on the current production tree. Synthetic purchase outcomes do not establish real charging behavior.

To prepare the private account input for read-only integration, follow [browser session import](docs/session-import.md). Do not place session contents in Git or messages.
