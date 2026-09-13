# Native cover-grid bookshelf

Date: 2026-09-13. This records the user's approved cover-first library design.
The subsequent [Bookstore change](bookstore.md) replaces its original History
destination. The package and acceptance records below retain this bookshelf
revision's original snapshot.

## Navigation and cards

The plugin opens Bookshelf by default. The current bottom navigation order is
Bookshelf, Bookstore, Search and Downloads. Account-to-library, legacy
history/continue and reader fallback entries all return to Bookshelf.

Bookshelf uses native KOReader widgets, with two columns below 720 pixels and
three on wider displays. Each card contains a portrait cover, a two-line title,
a reading-position label and independent latest-update information. Text slots
have fixed heights so short and long titles share the same cover and text
baselines. Landscape layouts preserve portrait cover frames.

Following visual feedback, pagination is a compact borderless arrow/page-count
control beside the hint above the covers. It is hidden for one-page and empty
bookshelves. The bottom edge contains only the four navigation tabs; no second
full-width pagination bar is rendered below the cards.

Tap a card to read or resume through the existing chapter/access checks. Hold it
to open the chapter catalog. Hardware focus follows visual grid rows, and page
keys operate pagination. Background cover arrival preserves the current focus.
Navigation, filtering and pagination retire callbacks for obsolete cards and
pending read intents; already opened readers and durable downloads are separate.

The original revision retained a separate History page. That destination has
now been removed at the user's request; existing reading records remain stored
and available to bookshelf progress labels.

## Reading state

The bookshelf distinguishes All, Currently reading, No reading record, Updated
and Completed series. Missing account history is not proof that a comic has
never been read. Completed series describes publication, not reading completion.

Local source-image progress takes precedence. A chapter/page-total ratio is shown
only when the anchor and chapter describe the same content revision. Server-only
history provides chapter-level information; it does not invent page positions.
Reading completion of one chapter remains distinct from finishing the series.
Latest chapter titles are shown separately from the current reading position.

## Covers and scope

The [cover-thumbnail change](cover-thumbnails.md) requests official 480-pixel
variants for visible cards and details, with the existing byte/pixel limits,
asynchronous worker, cache and account isolation. Downloading the original cover
is no longer required for ordinary supported cover URLs.

This change does not add automatic QR site initialization. The separately
recorded [QR session gap](live-ui-reading-2026-09-13.md) remains open. No payment
or account-content request was needed for the synthetic layout acceptance.

Verification runs on `test-env` with the official KOReader v2026.07.1 runtime.
The native layout previews use original synthetic illustrations and controlled
reading positions; they are not screenshots of the user's account. Anonymous
public-CDN thumbnail checks are recorded separately from those layout previews.

## Verification and delivery

The final [source/package binding](../spec/package/bookshelf-source-evidence.json)
matches all 202 production files to the checked remote source and all 102 packaged
files to the delivered archive. Its SHA256 is
`60ea9d6a698750988384af9b40ddfb126dd63f50333d336e03e26fd01fcfcd25`.

- Eight native configurations (Chinese/English at 480x640, 600x800, 720x960 and
  960x720): 744 assertions, including out-of-order rapid card selection and
  compact pagination placement, visibility, bounds and vertical alignment.
- Reading labels: 22 semantic cases, including real Catalog/SQLite metadata.
- Pending reading cancellation: 14 controlled asynchronous cases and the existing
  69-assertion Controller regression. The original opener-busy test now explicitly
  drains preparation before its second open request; preparing a newer selection
  is tested separately.
- Cover acquisition: 33 focused assertions on the final Controller, with earlier
  scoped anonymous thumbnail and eight-case image-policy receipts retained.
- Deterministic packaging: 27 checks.

The source/package binding above retains this revision's original evidence
digests and counts. [The native UI report](../spec/ui/bookshelf-grid.md) now
describes the subsequent Bookstore revision and its fresh native, session and
QR regressions; those current reports do not change this earlier package hash.

The remote `/tmp` filesystem became too full for the existing storage-headroom
check during the broad Controller run. Moving the new output directory to
`/var/tmp` allowed that check to complete without reducing its storage budget.
No local execution was substituted.

The initial bookshelf archive with the separate lower pagination bar is retained
under `dist/history/bookshelf-4f9bf912/`. Its earlier package and source receipts
use the `bookshelf-before-compact-pagination` prefix in `spec/package/`.
