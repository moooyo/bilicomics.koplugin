# BiliComics for KOReader

A Bilibili Comics plugin with its own comic library UI and KOReader's native reader. The implementation follows [the agreed plan](docs/implementation-plan.md) and [the UI design](design/ui-spec.md).

## Development status

The plugin is a development implementation, not a completed release. A complete real free chapter passes [native online reading, prefetch, retained download and new-process offline reopening](docs/reading-only-test-report.md): 45 pages, 92,022,101 image bytes, 51 online checks and 30 offline checks. Downloading continued after reader closure; offline reopening restored the source anchor with no session, no network routes and zero worker activity.

On 2026-09-13 the user authorized all operations other than actual purchasing. Authenticated quote and wallet reads and isolated synthetic purchase checks have now run. No actual purchase, coupon consumption, rental, recharge or account write was performed. See [the non-purchase integration report](docs/nonpurchase-integration-report.md) and [implementation status](docs/implementation-status.md) for exact evidence scopes.

The integrated [quote-selection adapter](docs/quote-selection-implementation.md) supports single chapters and strict standard-currency ordinal batches. Real captured responses successfully constructed both a positive batch offer and an explicit remaining-range offer. The UI distinguishes the server-supported range from its currently expected chapters; the server does not echo an atomically fixed member list. Additional discounts remain advisory. Actual charging and physical Scribe acceptance remain unverified.

The target first release includes online reading with prefetch, complete offline downloads, and explicit purchases using existing account assets. Recharge and automatic purchasing are excluded. No WeRead implementation is reused.

QR sign-in and session renewal are now implemented in the development source. A dedicated account session manager serializes renewal, saves replacement credentials before confirmation, and preserves business receipts independently of cookie persistence. See [the authentication implementation and verification boundaries](docs/session-renewal.md). Real mobile-app sign-in and authenticated renewal still require acceptance; synthetic checks do not establish an unlimited login lifetime.

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

The development archive is `dist/bilicomics-0.1.0-dev.zip`; its adjacent manifest records the exact file count, bytes and SHA-256. [The source binding](spec/package/source-evidence.json) and [package checks](spec/package/remote-results.json) identify the current artifacts and applicable focused evidence. The earlier live reading, version-replacement and ARM results keep their original scopes. No session, acquired comic content or diagnostic loader is included.

The archive retains the session file importer, reader prefetch policy and previously live-tested image protocol fixes. Same-snapshot recovery verifies historical image bytes before updating mutable addresses. Unknown or changed content requires the separate [new-version confirmation](docs/partial-download-recovery.md): both versions remain pinned and independently removable, the new version starts from the beginning, and the old version reads cached pages only. The current [ordinal range contract](docs/ordinal-range-contract.md) has focused construction, UI and transaction-recovery evidence. The complete live reading workflow was not repeated for this revision, and synthetic purchase outcomes do not establish real charging behavior.

To prepare the private account input for read-only integration, follow [browser session import](docs/session-import.md). Do not place session contents in Git or messages.
