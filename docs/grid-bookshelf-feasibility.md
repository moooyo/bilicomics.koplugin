# Cover-grid bookshelf feasibility

Date: 2026-09-13. Scope: source inspection in response to the user's cover-grid
reference and their question about Reading versus Following. No production UI
change or runtime validation was performed for this investigation.

## Native support

The inspected official KOReader v2026.07.1 runtime on `test-env` includes
`plugins/coverbrowser.koplugin/mosaicmenu.lua`. It implements configurable grid
rows and columns, image covers, progress bars, tap/hold selection, pagination and
focus navigation. Its grid uses the ordinary native HorizontalGroup,
VerticalGroup, ImageWidget, TextBoxWidget and input-container primitives.

The plugin already wraps those layout and image primitives in
`bilicomics/ui/widgets.lua`. Its current horizontal card is an application layout
choice. Cover-first cards with a title and reading position below are supported
without modifying KOReader core or replacing ReaderUI.

Use the native primitives for the comic library. The stock cover browser is
coupled to local document files and BookInfoManager; importing its complete menu
implementation is unnecessary for account-backed comic records.

Source references:

- [Native mosaic layout](https://github.com/koreader/koreader/blob/v2026.07.1/plugins/coverbrowser.koplugin/mosaicmenu.lua): grid dimensions, item construction, progress, input and focus handling.
- [Native image widget](https://github.com/koreader/koreader/blob/v2026.07.1/frontend/ui/widget/imagewidget.lua): bounded image area and aspect-preserving scaling.
- Current plugin `screens.lua:_comicCard`, `_library`, `_paginate` and `widgets.lua:cover`.

## Current navigation and data semantics

Reading currently selects the history collection, puts the most recent comic in
a prominent resume card, and lists the remaining history below it. Following
selects account favorites, including comics without any reading history. A comic
may belong to both collections; an unfollowed comic may still appear in history.

Ordinary following cards currently display `latest_episode_title` or
`latest_order`. Only the prominent resume card replaces that subtitle with the
current chapter and local source-image position. Thus the update title in the
user's screenshot is not evidence of their current reading position.

The catalog already exposes current chapter identity, local
`reading_position.page/index`, and local progress provenance. Chapter records
provide title and `total_pages` when a descriptor exists. No schema migration is
required to show the local chapter and page. Server history can provide a chapter
when local progress is absent, but a favorites-only record may have no known
reading state; unknown must not be silently labeled unread. Latest update and
reading position must remain separate fields.

## Proposed presentation

Rename Following to Bookshelf and Reading to History or Continue reading. A
bookshelf filter can select All, Unread and In progress once its reading-state
semantics distinguish unknown records. Keep Search and Downloads as separate
destinations.

Each card should contain a portrait cover, a title of at most two lines, and an
explicit current chapter/page label. Show latest-update or completion status
separately. Prefer local precise progress; show chapter-only server progress
without inventing a page number. Use two columns on narrower displays and three
when cover and text widths permit, with native pagination and grayscale-safe
status indicators. Final sizing requires native layout acceptance.

Preserve both immediate read/resume and access to chapters. Register focus rows
in the same order as the visual grid and retain page-key navigation. Render only
cached cover files; acquisition remains asynchronous and limited to visible cards.

The current cover placeholder has a separate cause: the real account run hit
the existing 4 MiB cover-response budget. There is also a 4-million-pixel decode
budget. A grid must use a suitably sized verified cover source and local cache;
simply enlarging the widget or dropping those budgets does not resolve that
acquisition failure. Any CDN thumbnail transformation must first be confirmed
from current official behavior.

Likely implementation files are `ui/screens.lua` for grid pagination/actions,
`ui/widgets.lua` for cover cards, `ui/model.lua` for progress labels, and the
localization files for user-visible wording. Cover acquisition may need a
separate verified thumbnail adapter. This proposal changes business screens;
the existing native chapter reader, download and purchase contracts remain.
