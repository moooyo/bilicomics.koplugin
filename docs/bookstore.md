# Native Bookstore

Date: 2026-09-13. Version: `0.1.0-dev`.

This records the initial seven-comic Bookstore revision. The subsequent
[expanded Bookstore](bookstore-expanded.md) adds more official sections and a
denser browsing layout. Counts and package hashes below identify this earlier
snapshot only.

The user removed the need for a separate History destination and requested a
Bookstore for discovering recommended comics. The four tabs are now Bookshelf,
Bookstore, Search and Downloads. Bookshelf remains the default first tab.
Legacy history/continue entry arguments return to Bookshelf; existing favorites,
chapter-level history and exact local reading anchors remain stored. Removing
the tab does not erase progress or alter chapter access and purchase rules.

## Recommendation source and behavior

The source is the public [official homepage](https://manga.bilibili.com/) page
context at `https://manga.bilibili.com/index.pageContext.json`. The official
page consumes `pageContext.data.recommendation.comics`. The protocol observation
returned seven items; that is an observation, not a fixed product limit or a
promise that every response contains the same comics. This is public editorial
recommendation data, not personalized recommendations from the user's account.
See [protocol observations](../spec/protocol/recommendations.md).

Bookstore opens a native cover grid. Each card has a cover, title, description
and available tags. A compact source/refresh row appears above the grid. Local
page controls appear beside the interaction hint only when needed; there is one
bottom navigation row. Selecting a recommendation opens its chapter catalog.
Reading, following or purchasing still requires the corresponding existing
explicit action. No recommendations are marked as already followed or read.

Opening a missing or stale feed starts one asynchronous refresh. The ordered
account-scoped snapshot stores at most 32 items and is fresh for six hours.
The response exposes no continuation cursor; local pagination only divides the
received snapshot and never invents further server pages. Failed and offline
refreshes preserve saved recommendations with a visible status. An empty-cache
failure exposes Retry. Duplicate refreshes are coalesced, and obsolete account
or navigation callbacks cannot replace the current screen or cache.

Both the recommendation request and its visible-cover requests are public,
anonymous worker operations. They do not renew, validate, send or invalidate an
account session. The controller permits only the exact recommendation operation
and current-feed covers through this public dispatch path. Existing authenticated
catalog, reader and account operations retain their normal session handling.
Cover acquisition uses the existing bounded thumbnail and atomic-cache policy.

The earlier [bookshelf toolbar proposal](bookshelf-experience-proposal.md)
remains a design proposal. This change adds Bookstore and removes the History
destination; it does not implement that separate toolbar redesign.

## Verification and delivery

All current verification runs through `ssh test-env` with official KOReader
v2026.07.1. No local runtime verification, new account reading, purchase or
physical-device acceptance is claimed for this change.

- [Protocol](../spec/protocol/recommendations-verification.json): anonymous real
  homepage response, 89 directed assertions, 87 worker assertions and 12 Client
  regression cases.
- [Controller](../spec/controller/bookstore-controller-verification.json):
  20 durable-cache, exact recommendation replacement, safe cached metadata and
  anonymous-dispatch cases, plus 69 controller and 33 cover regression assertions
  on the final source. Bookshelf progress remains intact.
- [Native Bookstore](../spec/ui/bookstore-verification.json): eight Chinese and
  English portrait/landscape configurations, 348 assertions using synthetic
  fixtures with blocked network access.
- [Native Bookshelf](../spec/ui/bookshelf-grid-verification.json): eight
  configurations, 760 assertions for the shared cover grid and navigation.
- [Real native Bookstore](../spec/ui/bookstore-live-verification.json): actual
  Runtime, Controller, Screens, Runner and TLS transport in an isolated anonymous
  profile at 600 by 800. Seven recommendations and both first-screen covers
  loaded through one recommendation GET and two visible-thumbnail GETs, all
  returning HTTP 200. No credentials, chapter image or account operation was
  used. The [native framebuffer](../spec/ui/screens/bookstore-live/600x800.png)
  shows the actual public response; it is not a synthetic layout fixture.
- [Package and source binding](../spec/package/bookstore-source-evidence.json):
  the exact delivered ZIP, production file hashes and current evidence scopes.

The canonical package is `dist/bilicomics-0.1.0-dev.zip`, containing 104 files.
Its SHA-256 is `43a82ccaffacfacd475e92e5aef09507d7bac3dccf7945fd49136063ab4ab38d`.
The final binding matches all 204 public production files to the remote source,
all archive entries to the delivered manifest, and the real screenshot to its
framebuffer receipt. All 27 deterministic packaging checks passed.
The preceding compact
bookshelf candidate remains in `dist/history/bookshelf-60ea9d6a/`. Earlier live
whole-chapter and QR acceptance records retain their original source snapshots.
The known missing automatic `buvid3` site initialization after fresh QR sign-in
remains outside this change; anonymous recommendations do not depend on it.
