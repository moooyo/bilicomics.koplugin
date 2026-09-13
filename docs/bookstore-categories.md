# Bookstore subject browsing

Date: 2026-09-13. Version: `0.1.0-dev`.

Bookstore adds a subject selector to its existing compact toolbar. The default
selection is All recommendations, which keeps the four-section homepage feed.
Choosing a subject opens the official catalog for that subject in the site's
popularity order. The selector uses the current official subject list, rather
than inferring official categories from the homepage's descriptive tags.
Bookshelf remains the default first tab and the 600 by 800 grid keeps six cards.

## Official source and anonymous device context

The official `/classify` application uses `AllLabel` for subjects and `ClassPage`
for results. The observed metadata contained 16 subjects, including Hot blood
(`999`) and Science fiction (`1015`). The service's current list determines the
available choices; names or identifiers from earlier site snapshots are not
hardcoded into the selector. The first implementation uses order `0`, the
official popularity recommendation order.

`ClassPage` is signed and encrypted. A strict request without cookies returned
HTTP 200 with business code 99. The same public request succeeded after the
official `/ductape/buvid` initialization, using only the newly issued anonymous
`buvid3` value. That isolated value exists only in memory for the classification
request. It is separate from login cookies, the parent protocol client's session
and durable account credentials. This public-device initialization does not
repair or replace the separately documented QR-session initialization path.

The result uses `season_id` as comic identity and `styles` as subject labels.
A comic's `total` field is its chapter count, not the number of catalog results.
The site requests 18 comics per page and treats a nonempty array as evidence
that another page can be requested. No total-page or cursor contract is inferred.

## Navigation, paging and cache

The subject picker is a native dialog with the current selection marked. Choosing
a subject resets the local page position. Refresh applies to that subject;
All recommendations restores the independent homepage feed. Tap opens chapters
and hold opens the cached synopsis. Background cover or feed completion cannot
cover the picker or synopsis with a new underlying screen.

The existing top page arrow moves through cached comics. At the last cached
page it can request the next remote page. Appended comics first fill any partial
visible page; a previously full page advances so no newly loaded comics are skipped.
Category views show a current page number without claiming a server page total.
Up to five remote pages, or 90 comics, are retained per subject/order selection;
the local loading limit remains distinct from the server's continuation state.

Category snapshots are isolated by account, subject and ordering. They retain
their own descriptions and labels so category responses cannot erase homepage
editorial metadata. A successful first-page refresh replaces that category's
previous pages atomically; failures retain the previous snapshot. An obsolete
append cannot enter a refreshed snapshot. Late responses for another category
may update only that category's cache and cannot replace the current screen.

Visible-cover requests carry the account, query and snapshot revision. They
must remain members of the same snapshot before dispatch and before commit.
Completed images may be reused, while requests from retired snapshots cannot
authorize unrelated covers. Offline browsing shows only the selected feed's
saved results; an uncached category remains an explicit retryable empty state.

## Verification and delivery

All runtime verification runs through `ssh test-env` with official KOReader
v2026.07.1. Focused protocol, cache and native UI reports record the exact source
subsets, and the final delivery binding identifies the package and real category
framebuffers. No real account, purchase or local Windows runtime is used for
this feature's verification.

- [Protocol and public source](../spec/protocol/bookstore-categories-verification.json):
  541 assertions, the anonymous-device control and production AllLabel/ClassPage
  calls through the acceptance guard.
- [Category cache](../spec/controller/bookstore-categories-controller-verification.json):
  25 focused cases, plus 23 homepage cases and 69 controller/33 cover regression
  assertions on the final source.
- [Native category UI](../spec/ui/bookstore-categories.md): 1,632 assertions in
  eight language/size configurations, with 760 Bookshelf regression assertions.
- [Real selection](../spec/ui/bookstore-categories-live-verification.json): the
  native category-button and picker callbacks select subject 999 from 16 official
  choices and load 18 comics. All six visible covers load successfully. The ten
  public requests comprise the three category-service operations, six covers and
  one cold, pinned signing asset. The capture begins on the category entry route;
  the previous homepage live evidence retains its separate scope.
- [Acceptance guard](../spec/local/category-guard-results.json): 915 assertions
  covering allowed anonymous reads and rejected unrelated operations.
- [Final delivery binding](../spec/package/bookstore-categories-source-evidence.json):
  all 206 public production files, all 106 archive entries, source-specific
  evidence and both actual framebuffers match. All 27 packaging checks pass.

The actual screenshots are [the subject picker](../spec/ui/screens/bookstore-categories-live/bookstore-categories-live-picker.png)
and [the Hot blood results](../spec/ui/screens/bookstore-categories-live/bookstore-categories-live-heat.png).
The canonical archive SHA-256 is
`d0dcc11e32bed4cb045e5c2bf2e0570af8565a70e222a8af7ad1c477d6b63fcc`.

The canonical filename remains `dist/bilicomics-0.1.0-dev.zip`. The preceding
expanded homepage candidate and its evidence are retained under
`dist/history/bookstore-c6fca6fe/`; its 35-comic observation and package digest
remain historical evidence for that revision.
