# Navigation and discovery UI/UX review

## Scope and evidence

This review covers the 75 gallery scenes assigned to Bookshelf (21), Bookstore (21), Search (13), and Chapters (20). All six relevant contact sheets were inspected, followed by individual native PNGs at 480 x 640, selected 600 x 800 captures, and the 720 x 960 bookshelf. Current source was read to distinguish visible design issues from navigation behavior that cannot be established by a still image. No production UI was changed and no local tests or runtime probes were executed.

The gallery contains synthetic records and original fixture art. English story titles, authors, genre names, and account names are not localization findings. Native TextViewer controls such as Find and Close appear in English in the captured synopsis, but these controls belong to KOReader and the fixture's native locale initialization has not been established as equivalent to an actual Chinese device. This review does not classify that observation as a plugin localization defect. Physical E-ink contrast, touch accuracy, and refresh behavior remain unmeasured.

Priorities: P2 means a material usability problem worth addressing in the next UI pass; P3 means a smaller refinement or product choice. No P0 or P1 issue was established in this scope. Confidence distinguishes what the screenshot/code proves from the predicted user impact.

## Findings

### N1. Returning from a chapter discards a search filter

- Priority: P2.
- Confidence: High from source; the transition was not replayed in this review.
- Evidence scenes: `review-supplement-search-ongoing-filter`, `review-supplement-search-results-next-page`, `native-chapters`.
- Screenshot: [Filtered search](screens/suites/review-supplement/zh_CN-480x640/search-ongoing-filter.png), [result page two](screens/suites/review-supplement/zh_CN-480x640/search-results-next-page.png).
- Source: `Screens:showComic`, `bilicomics/ui/screens.lua:69`, stores only the origin route and page. `Screens:_back`, line 308, calls `showSearch()` and restores the page. `Screens:_navigate`, line 54, resets `filter` to `all`.
- Observed behavior: Open a chapter catalog from an ongoing/completed search and return. The filter becomes All while the previous page number is restored. That page can contain different comics.
- Impact: Browsing a candidate interrupts the user's place in a filtered result set. The interface appears to have changed the search without a request.
- Recommendation: Store and restore route state as one unit: query, filter, page, and focused comic. Do not restore a page number into a different result set.

### N2. Recent searches become unreachable after the first query

- Priority: P2.
- Confidence: High from source; no interaction replay was performed.
- Evidence scenes: `review-supplement-search-recent-history`, `review-supplement-search-results`, `review-supplement-search-input-keyboard`.
- Screenshot: [Recent searches](screens/suites/review-supplement/zh_CN-480x640/search-recent-history.png), [results](screens/suites/review-supplement/zh_CN-480x640/search-results.png).
- Source: `Screens:_search`, `bilicomics/ui/screens.lua:1341`, renders history only when `query == ""`. `Screens:_editSearch`, lines 1319-1322, closes the input dialog and returns on an empty input without clearing the previous query. Navigation does not clear the query.
- Observed behavior: There is no visible action to clear the active query or return to search history. Deleting the input and submitting it leaves the old search in place.
- Impact: The history feature stops being useful within the same plugin session. A user must retype a previous query rather than select it.
- Recommendation: Add a clear/search-home action to the query field, or allow an empty submission to reset search state. Keep history reachable after a search.

### N3. Search rows look like one target but only the title is actionable

- Priority: P2.
- Confidence: High that the hit target differs; the amount of resulting user error requires usability testing.
- Evidence scene: `review-supplement-search-results`.
- Screenshot: [Search results](screens/suites/review-supplement/zh_CN-480x640/search-results.png).
- Source: `Screens:_comicCard`, `bilicomics/ui/screens.lua:489`, creates a callback on the title Button only. The cover, subtitle, row, and separator are ordinary widgets. By comparison, `W.CoverCard:init`, `bilicomics/ui/widgets.lua:137`, attaches tap/hold gestures to the complete card dimensions.
- Observed behavior: Tapping the search-result cover or update line does not use the title's callback. In the adjacent discovery surfaces, the entire cover card is interactive.
- Impact: A natural attempt to open a result by its thumbnail can appear ignored. The usable hit area is smaller than the apparent row.
- Recommendation: Make the result row, including cover and metadata, one action target with one focus state. Apply the same principle to chapter title/status rows while keeping a separate purchase/download action distinct.

### N4. The default bookshelf hides the update information it already knows

- Priority: P2.
- Confidence: High, visible and directly supported by source.
- Evidence scenes: `bookshelf-finishing-default`, `review-supplement-bookshelf-updated-filter`.
- Screenshot: [Default bookshelf](screens/suites/bookshelf-finishing/zh_CN-480x640/synthetic-bookshelf-finishing-default.png), [updated filter](screens/suites/review-supplement/zh_CN-480x640/bookshelf-updated-filter.png).
- Source: `Screens:_coverGrid`, `bilicomics/ui/screens.lua:675`, passes `Model.comicUpdate(comic)` to the card. The bookshelf branch of `W.CoverCard:init`, `bilicomics/ui/widgets.lua:121`, renders only title and reading position, omitting `self.update`. The updated filter exists at `Screens:_bookshelfFilter`, line 518.
- Observed behavior: Even a card selected by the Updated filter has no card-level update marker or latest-chapter information. The default shelf shows only where the user read previously.
- Impact: A user maintaining followed series cannot scan the default shelf to see what is new. They must open More, apply a filter, or inspect individual catalogs.
- Recommendation: Add one compact, high-contrast update badge or a short latest-chapter line. Keep saved reading progress separate; do not replace trusted reading history with update status.

### N5. Settings and reading return behavior does not consistently preserve the originating task

- Priority: P2.
- Confidence: High from source; the final host screen after native reader close was not observed in this review.
- Evidence scenes: `bookshelf-finishing-more`, `bookstore-expanded-recommendations`, `review-supplement-search-results`, `native-chapters`.
- Screenshot: [More menu](screens/suites/bookshelf-finishing/zh_CN-480x640/synthetic-bookshelf-finishing-more.png), [discovery catalog](screens/suites/bookstore-expanded/zh_CN-480x640/synthetic-bookstore-expanded-chapters.png).
- Source: `Screens:_more`, `bilicomics/ui/screens.lua:243`, opens Account from any route. `Screens:_back`, line 316, returns Account directly to Bookshelf. `Screens:_read`, line 911, creates an automatic reader-return intent only for Bookshelf or a catalog originating there. `Screens:onReaderClosed`, line 125, handles only that intent.
- Observed behavior: Entering settings from Bookstore or Search and pressing Back moves to Bookshelf. Automatic restoration after reading exists for the bookshelf journey but not the discovery/search journey.
- Impact: A short detour to sign-in/settings, or sampling a discovered comic, can break the previous browsing context.
- Recommendation: Use an explicit return context for settings and reader handoff. Restore the source route with its filter/page/focus when it remains valid for the same account. Preserve the existing account-change guards.

### N6. The chapter page gives utility actions more visual weight than reading

- Priority: P2 design direction.
- Confidence: High for the visual hierarchy; medium for the proposed behavioral benefit.
- Evidence scenes: `native-chapters`, `bookstore-expanded-chapters`, `review-supplement-chapters-newest-first`.
- Screenshot: [Latest chapters](screens/suites/review-supplement/zh_CN-480x640/chapters-newest-first.png), [newly discovered comic](screens/suites/bookstore-expanded/zh_CN-480x640/synthetic-bookstore-expanded-chapters.png).
- Source: `Screens:_comic`, `bilicomics/ui/screens.lua:993`, places six equal-weight filter/sort/download/locate/refresh/follow controls before the list. The Current chapter action at line 1023 locates a row; it does not resume reading. `Screens:_chapterRow`, line 928, exposes a visible Buy then download button for locked rows; tapping the plain chapter title triggers purchase for reading through `_read` at line 905.
- Observed behavior: The page has no prominent Start reading/Continue reading action. The only explicit purchase action beside a locked row is download-oriented, while the reading purchase action is implicit in the chapter title.
- Impact: The main task has to be inferred from row text, while less frequent utilities have clear button affordances. Users may misread the available purchase path as download-only.
- Recommendation: Add a primary Start/Continue reading action near the comic identity, keep Follow secondary, and group filters/sorting in a quieter toolbar. Give locked-row reading and download options clear, distinct labels without adding duplicate purchase confirmations.

### N7. Multi-select does not explain selections outside the current page or filter

- Priority: P2 design direction.
- Confidence: High for selection scope; medium for predicted confusion.
- Evidence scenes: `review-supplement-chapters-selection-selected`, `review-supplement-chapters-downloaded-filter`.
- Screenshot: [Seven selected, four visible](screens/suites/review-supplement/zh_CN-480x640/chapters-selection-selected.png).
- Source: `Screens:_comic`, `bilicomics/ui/screens.lua:1008`, selects every downloadable item in the complete filtered list, not just the displayed page. The count at line 1011 covers the entire selected map. Changing filters does not clear it, and submission at line 1014 iterates all chapters.
- Observed behavior: Four rows can be visible while the primary action shows seven selected. Hidden selections can also survive a change to another filter.
- Impact: Users cannot review the full set from the current viewport and may be uncertain what the download action covers.
- Recommendation: State the scope explicitly: select all matching chapters versus this page. Add Clear selection and a concise selected-summary view, including an off-page count. Preserve intentional cross-page selection rather than silently dropping it.

### N8. Large collections and catalogs have no direct jump action

- Priority: P2 for long catalogs; P3 for small libraries.
- Confidence: High that the capability is absent; benefit depends on collection size.
- Evidence scenes: `bookshelf-finishing-default`, `native-chapters`, `review-supplement-chapters-newest-first`.
- Screenshot: [Bookshelf page one of twelve](screens/suites/bookshelf-finishing/zh_CN-480x640/synthetic-bookshelf-finishing-default.png), [chapter page one of five](screens/suites/review-supplement/zh_CN-480x640/chapters-newest-first.png).
- Source: `Screens:_paginate`, `bilicomics/ui/screens.lua:392`, renders a disabled page counter. Grid pagination at line 635 renders a non-interactive text counter. Only previous/next, ordering, and current-chapter location are provided.
- Observed behavior: The user cannot jump to a page or named/numbered chapter. Moving to a known middle chapter requires repeated page turns.
- Impact: The navigation cost grows directly with catalog size, even after the existing row-density issue is improved.
- Recommendation: Make the counter open a page/chapter jump dialog. For chapters, prefer chapter number/title search over page numbers that depend on layout. Keep native page keys and previous/next arrows as quick controls.

### N9. Discovery lacks a shared comic overview

- Priority: P2 design direction.
- Confidence: High for current content/access paths; medium for the preferred redesign.
- Evidence scenes: `review-supplement-search-results`, `bookstore-expanded-synopsis`, `bookstore-expanded-chapters`.
- Screenshot: [Search result metadata](screens/suites/review-supplement/zh_CN-480x640/search-results.png), [synopsis](screens/suites/bookstore-expanded/zh_CN-480x640/synthetic-bookstore-expanded-synopsis.png), [catalog](screens/suites/bookstore-expanded/zh_CN-480x640/synthetic-bookstore-expanded-chapters.png).
- Source: `_comicCard` at `bilicomics/ui/screens.lua:489` displays title and latest chapter, but no author despite Search accepting author queries. `_bookstoreSynopsis` at line 888 is reached from the bookstore hold callback at line 682. `_comic` at line 961 contains identity and chapters but no synopsis entry.
- Observed behavior: Search results omit author metadata useful for identifying an author match. Synopsis access is confined to a bookstore long press, then a standalone TextViewer with no direct chapter/read action.
- Impact: Evaluating a found comic requires remembering gesture-specific paths and bouncing between disconnected views. Search users cannot reach the same synopsis surface from the catalog.
- Recommendation: Provide a compact shared overview from all discovery routes: cover, full title, author, status, expandable synopsis, and read/follow actions, with the chapter list below or on a clearly labeled secondary view. Allow a synopsis view to proceed directly to chapters.

### N10. Filter buttons hide their options behind cyclic behavior

- Priority: P3.
- Confidence: High for behavior; medium for impact.
- Evidence scenes: `review-supplement-search-ongoing-filter`, `review-supplement-chapters-downloaded-filter`, `bookshelf-finishing-filter`.
- Screenshot: [Search filter](screens/suites/review-supplement/zh_CN-480x640/search-ongoing-filter.png), [chapter filter](screens/suites/review-supplement/zh_CN-480x640/chapters-downloaded-filter.png).
- Source: Search at `bilicomics/ui/screens.lua:1363` cycles All/Ongoing/Completed. Chapters at line 994 cycle All/Unread/Downloaded. Bookshelf instead uses an explicit choice dialog at line 518.
- Observed behavior: The button label describes the current state, but does not show the next state or that other choices exist. The same filtering concept has different interaction models across pages.
- Recommendation: Use the existing explicit choice pattern consistently, or a compact segmented control where three choices fit. Keep the current choice and a Clear filter affordance visible.

### N11. Category metadata can repeat the selected category verbatim

- Priority: P3.
- Confidence: High for the duplicated label; occurrence depends on service metadata.
- Evidence scene: `bookstore-categories-appended`.
- Screenshot: [Repeated category and first tag](screens/suites/bookstore-categories/zh_CN-480x640/synthetic-bookstore-categories-appended.png).
- Source: `Screens:_bookstore`, `bilicomics/ui/screens.lua:836`, concatenates the category/section name and the first tag without deduplicating them.
- Observed behavior: The fixture demonstrates category and first tag producing the same label twice. The issue is repetition, not the fixture's English language.
- Impact: A scarce metadata line looks busier without communicating additional information.
- Recommendation: Remove duplicate tags and omit the already-selected category from each card unless it adds useful context. Reserve the line for completion status, author, or a distinct tag.

### N12. Search and chapter empty/loading states reuse a library instruction

- Priority: P2, extension of initial review item 2 rather than a separate defect count.
- Confidence: High, visible and directly supported by source.
- Evidence scenes: `review-supplement-search-loading`, `review-supplement-search-no-results`, `review-supplement-chapters-empty`.
- Screenshot: [Search still loading](screens/suites/review-supplement/zh_CN-480x640/search-loading.png), [empty chapter catalog](screens/suites/review-supplement/zh_CN-480x640/chapters-empty.png).
- Source: The default message in `Screens:_paginate`, `bilicomics/ui/screens.lua:388`, is inherited by `_search` at line 1372 and `_comic` at line 1046.
- Observed behavior: Search loading simultaneously says Updating and no content. An empty chapter catalog suggests refreshing the bookshelf or searching for another comic, rather than explaining the catalog state.
- Recommendation: Separate initial/loading/error/true-empty/filter-empty states per route. Keep the active query or comic context and supply the appropriate retry, clear-filter, or edit-search action. Hide meaningless 1/1 pagination when there is no content.

## Visual and structural improvements to explore

These are product/design choices, not confirmed functional defects.

1. **Offer comfortable and compact bookshelf density.** The 480/600 bookshelf shows two large covers with blank space below them; the 720 layout shows six items. `Screens:_coverGrid` at line 597 sets the column threshold and calculates row count. Preserve the large-cover option for readers who prefer it, but let large collections choose a denser mode. Keep progress legible and do not treat physical-pixel counts as validated touch sizes. Evidence: `bookshelf-finishing-default`, [480 capture](screens/suites/bookshelf-finishing/zh_CN-480x640/synthetic-bookshelf-finishing-default.png), [720 capture](screens/suites/bookshelf-finishing/zh_CN-720x960/synthetic-bookshelf-finishing-default.png). P3; high observation confidence, medium design confidence.

2. **Use one predictable pagination zone and hierarchy.** Grid arrows are small controls near the top right; list pagination is a three-button row below the current content. A stable location above bottom navigation, with a clear page/jump control, would reduce visual searching. Do not remove physical page-key support. Source: `_coverGrid:635`, `_paginate:392`, `W.Panel:init:164`. P3; medium confidence in benefit.

3. **Group More actions by their scope.** The bookshelf More sheet mixes the currently focused comic, library operations, account settings, and help in one list. Use subtle section labels/separators or place a visible catalog action on the selected comic. Keep focus identity in the title and avoid adding a deep submenu hierarchy. Evidence: `bookshelf-finishing-more`; source `_more:219`. P3; medium confidence in benefit.

4. **Reduce repeated rectangular borders around routine controls.** Chapters and Search put several equal-weight outlined buttons directly above content. Keep borders for actual selection/group boundaries, give the core action one stronger treatment, and use quieter text controls for refresh/sort. Use whitespace, alignment, and a limited type scale rather than decorative gray panels, gradients, or animation. Evidence: `native-chapters`, `review-supplement-search-results`; sources `_comic:993`, `_search:1337`, `W.button:48`. P3; design direction.

5. **Give empty states a recognizable composition with one useful action.** The empty bookshelf has one sentence near the header and an otherwise blank page; its suggested destinations are only in the distant bottom navigation. A concise heading, explanatory line, and Browse Bookstore action can make a successful empty sync visibly different from an unfinished load. Keep sign-in and retry-specific empty states already present. Evidence: `bookshelf-finishing-confirmed-empty`; source `_bookshelf:574`. P3; design direction.

6. **Preserve the three chapter status axes, but simplify their visual encoding.** Reading progress, entitlement, and local storage are correctly separated. A selected/current marker plus short, aligned status labels can reduce the feeling of a diagnostic table. Expiry text can be more readable in the device's timezone, with exact UTC available in details, while preserving source-authoritative access and unknown-expiry states. Do not infer permission solely from a synthetic timestamp. Evidence: `entitlement-display-temporary-first-page`; sources `_chapterRow:943`, `Model.entitlementExpiry:150`. P3; design direction.

7. **Keep recent-search management reachable and modest.** After fixing N2, add Clear recent searches or an item-removal action so old queries do not remain an immutable list. This is account-scoped local convenience, not a reason to add cloud history or extra permission flows. Source: `_search:1344`, `_editSearch:1327`; evidence `review-supplement-search-recent-history`. P3; code-confirmed absence, optional product choice.

## Strengths to preserve

- **Fast resume from the bookshelf.** Tap-to-read is appropriate for a library of already-followed comics. The improvement is clearer discoverability, not forcing every reading session through a details page.
- **Explicit saved-view restoration and account isolation.** Bookshelf filter, sort, page, focused comic, and order are preserved by `_loadBookshelfView`/`_saveBookshelfView` at lines 108/117. The code guards delayed callbacks and avoids restoring another account's reading intent. Extend this model to other routes.
- **Cover-centric discovery with a controlled density.** Bookstore uses two browsing rows, and the compact metadata does not expose operational implementation details. Keep the clean monochrome foundation.
- **Different initial, offline, and unavailable bookshelf states.** The UI keeps cached comics usable and distinguishes no cache from a confirmed empty shelf. The More sheet explains why sync is unavailable and disables unavailable actions.
- **Search preserves query context while showing results.** The query remains visible and editable, and result count/filter information is near the list. Keep this orientation when simplifying the toolbar.
- **Separate reading progress, rights, and storage.** An already-read chapter is not confused with an owned or downloaded chapter. Temporary access has an explicit expiry/unknown-expiry line.
- **Selection excludes chapters without download rights and shows the count.** Keep this clear boundary while making cross-page scope reviewable.
- **Truthful remote pagination.** Category pages show loaded-item counts and an open-ended current page rather than inventing a total. Explicit server-end and cache-limit states distinguish completion from a browsing limit.
- **Preserved offline and recovery context.** Bookstore failures keep cached recommendations visible and provide retry paths; they do not replace useful data with a blank error screen.

## Suggested order

First address the source-confirmed context and affordance issues: N1, N2, N3, N4, and N12. Then revise chapter reading hierarchy and selection scope (N6/N7), retaining existing entitlement and callback guards. Finally prototype overview, density, pagination, and visual grouping choices with both 480 and 600 screenshots before selecting a final direction. Interaction transitions should be verified remotely during implementation; static screenshots alone cannot establish the usability outcome.
