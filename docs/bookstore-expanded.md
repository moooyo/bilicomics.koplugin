# Expanded Bookstore and compact browsing

Date: 2026-09-13. Version: `0.1.0-dev`.

This records the compact homepage-feed revision. The subsequent
[subject-browsing revision](bookstore-categories.md) adds official categories.
The package hash and acceptance totals below retain their original snapshot.

The initial Bookstore showed only the homepage recommendation block and two
large cards at 600 by 800. The user requested more recommendations and more
content on screen. This revision expands both the feed and its native layout.
Bookshelf remains the default first tab, followed by Bookstore, Search and
Downloads. Bookshelf reading progress and its existing card layout are retained.

## Content and interaction

One anonymous `GET https://manga.bilibili.com/index.pageContext.json` now reads
four real homepage sections in their official order: recommendations,
bestsellers, trending comics and completed picks. Each grouped section keeps
its first/second group order. The first valid occurrence of a comic wins across
all sections, so later local pages do not repeat the same comic. Banner links,
advertising cards and separate rankings are not mixed into this feed.

The initial expanded observation contained 37 section entries and 34 unique
comics, compared with the previous seven-entry recommendation block. Counts
can change with the official response. The screen shows the current total.
This is a public homepage selection, not an account-personalized feed. The
snapshot is bounded at 96 comics and still exposes no server continuation.
See [the protocol evidence](../spec/protocol/recommendations-expanded-verification.json).

Bookstore cards use a portrait cover, a fixed two-line title and one short
source/tag line. A 600 by 800 screen displays three columns and two rows, or six
comics at once. Compact 480 by 640 screens use two columns and two rows; the
960 by 720 landscape layout uses four columns and two rows. Loading or cached
error messages reduce cover height while retaining the same page capacity.
The compact page controls stay above the covers and the bottom has one
navigation row.

Tap opens the existing chapter catalog. Hold opens the cached full synopsis in
KOReader's native text viewer, keeping longer descriptions available without
reserving that space on every card. Both actions respect retired card callbacks
after navigation, refresh or pagination. Only visible covers are requested.

## Cache compatibility

The storage key remains stable. New snapshots use schema version 2; valid
version-1 snapshots can still be browsed offline but are marked stale so the
next online visit fetches the expanded selection immediately. Fresh version-2
snapshots retain the six-hour cache policy. Refresh failures preserve the
previous feed. The four source identifiers are allowlisted display metadata;
the completed-picks source does not change a comic's publication or reading
completion state. Recommendation metadata is replaced atomically without
altering favorites or reading anchors.

## Verification and delivery

Verification runs only through `ssh test-env` using official KOReader
v2026.07.1. Evidence scopes are recorded separately:

- [Protocol expansion](../spec/protocol/recommendations-expanded-verification.json):
  exact anonymous request, official fields, four-section ordering, deduplication,
  malformed optional groups, legacy contexts, response limits and a live fixture.
- [Controller expansion](../spec/controller/bookstore-expanded-controller-verification.json):
  schema migration, 96-item bounds, source sanitization, atomic metadata updates
  and preservation of account reading/favorite data.
- [Native layouts](../spec/ui/bookstore-expanded.md): expanded synthetic grids,
  synopsis interaction, page coverage, visible-cover acquisition, loading,
  offline retry and unchanged Bookshelf behavior.
- [Real native browsing](../spec/ui/bookstore-expanded-live-verification.json):
  the final anonymous 600 by 800 run returned 35 recommendations, displayed six
  cards on each of two consecutive pages, and loaded all 12 covers through 13
  successful GET requests. Counts differ from the earlier 34-comic observation
  because the homepage selection changes between responses. Both actual
  framebuffers are retained in `spec/ui/screens/bookstore-expanded-live/`.
- [Delivery binding](../spec/package/bookstore-expanded-source-evidence.json):
  final public source, archive entries, focused evidence and actual anonymous
  Bookstore framebuffers.

The canonical candidate remains `dist/bilicomics-0.1.0-dev.zip`. The previous
104-file candidate and its original evidence archive are retained in
`dist/history/bookstore-43a82cca/`. Its seven-comic/two-card acceptance remains
historical evidence, not a current layout claim. This revision does not add
local-window, account-reading, purchasing or physical-device acceptance.

The final package contains 104 files, with SHA-256
`c6fca6feebf8845e36c58fcda5df4f1def4f8555db33c2f084b24ea0912b8e39`.
The delivery binding matches all 204 public production files, each ZIP entry,
the executed source subsets and both real framebuffers. Final verification
passed 1,600 native Bookstore assertions, 760 Bookshelf assertions, 23 directed
controller cases, 69 controller and 33 cover regression assertions, 153 protocol
assertions and 27 deterministic packaging checks. These counts identify scoped
evidence rather than a repeat of the older full account-reading acceptance.
