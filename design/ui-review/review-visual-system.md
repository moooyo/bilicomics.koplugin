# Native visual system review

## Decision

Refine the existing monochrome KOReader interface rather than replace its visual language. The strongest direction is a reading index: clear comic identity, a deliberate current-reading marker, readable state labels, and quiet supporting controls. Use the existing native type families, white background, square in-page controls, native dialogs, and four-item bottom navigation.

The major opportunity is hierarchy. Several screens spend their strongest contrast on interchangeable button outlines or a disabled primary control, while facts that determine the next action are rendered as secondary gray text. Improving that ordering will do more than adding ornament.

This is a design review, not an implemented redesign. All production code and gallery assets remain unchanged. No local tests, builds, or runtime probes were run for this review.

## Evidence and limits

Reviewed the main overview and all 13 existing group contact sheets: both Bookshelf, Bookstore, Downloads, Account, and Purchase sheets, plus Search, Chapters, and Reader. Inspected original 600 by 800 and 480 by 640 main-page images, representative purchase and selection states, and the 960 by 720 Bookshelf and Bookstore captures. Source references below refer to the current `widgets.lua` and `screens.lua` snapshot, with reader dialog references in `controller.lua`.

These are native KOReader framebuffer captures with synthetic data. The English comic titles, cover typography, and printed borders inside fixture artwork are not evidence of production localization or visual defects. In particular, do not remove a product focus border because a synthetic cover contains its own printed frame. English controls inside native TextViewer/FileChooser captures need verification with the full host locale before being classified as localization defects.

Screenshots establish relative hierarchy, spacing, and clipping in the captured environment. They do not establish physical touch-target size, reading comfort on every e-ink panel, refresh quality, or contrast under ambient lighting. Treat the proposed values below as starting tokens for remote comparison and subsequent device review.

## Preserve the differences that serve the task

| Surface | Primary task | Visual emphasis to retain |
| --- | --- | --- |
| Bookshelf | Recognize a followed comic and resume reading | Larger covers, a readable title, a precise reading position, and a quiet surrounding page. A partially empty page is acceptable. |
| Bookstore | Compare more unfamiliar comics | A denser cover grid with compact titles and one supporting tag line. It should remain denser than Bookshelf. |
| Search | Enter a known title or choose a direct result | One clear search entry and a compact vertical results list. A cover grid is unnecessary here. |
| Chapters | Identify a chapter and distinguish reading, access, and storage states | A strong current-chapter marker, aligned status fields, and scannable chapter rows. Keep the three state axes separate. |
| Downloads | Assess task state and continue or recover a task | A readable state before its controls; separate progress operations from destructive removal. |
| Account | Understand account health and adjust settings | A compact account summary followed by consistent settings rows. Ordinary maintenance should not look like a wall of equally urgent actions. |
| Purchase and recovery | Understand the current decision and its consequences | A short state heading, a structured summary, and a clear next action. Keep exact amount and scope visible before confirmation. |
| Reader | Read content and handle chapter boundaries | Preserve the native reader canvas and existing host menus. Plugin prompts should use the same summary/action grammar as other native dialogs. |

## Proposed token direction

Geometry tokens are logical values consumed once by `W.scale`, which delegates to `Screen:scaleBySize` at `widgets.lua:24`. They are not CSS pixels or physical millimeters. Text values are native face-size arguments to `Font:getFace` / `Button.text_font_size`; do not wrap them in `W.scale` as an additional scaling step. Derive final line and row heights from rendered native widget sizes, especially with localization and user font settings.

| Role | Proposed initial token | Application |
| --- | --- | --- |
| `page_title` | Native `cfont`, 25, bold | One consistent screen heading. Preserve the existing centered title between Back and More. |
| `section_title` | Native `cfont`, 20 or 21, bold | Account sections and meaningful content groups. |
| `comic_title` | Existing native title face, 22 to 24, bold | Detail-page comic identity; do not exceed the page heading without a content reason. |
| `item_title` | Native `cfont`, 18 to 20 | Chapters, search results, and download items. Use bold for hierarchy or the current item rather than every row. |
| `compact_card_title` | Native `cfont`, 16, bold; up to two lines | Bookstore discovery cards. Bookshelf can retain 18 and its larger covers. |
| `body` | Native `cfont`, 18 | Meaningful explanatory text. Native dialog body sizing should follow host behavior and measured fit. |
| `state` / `metadata` | Native `cfont`, 16 | State uses black; author, optional tag, and routine explanatory metadata may use the existing dark gray. |
| `micro` | Native `cfont`, 14 as an initial minimum for plugin helper text | Counts and optional hints. Avoid relying on the existing 12 to 13 size for recovery guidance or important status. This is a comparison proposal, not a universal legibility standard. |
| `ink` | `BB.COLOR_BLACK` | Titles, actionable state, important amount and scope, active controls. |
| `secondary` | Existing `BB.COLOR_DARK_GRAY` | Optional supporting content only. Do not give a required state the same visual weight as disabled navigation. |
| `separator` | `BB.COLOR_LIGHT_GRAY`, `W.scale(1)` | Row boundaries and quiet chrome. |
| `focus_stroke` | Black, `W.scale(2)` | A stable outer focus frame independent of whether the control is primary, selected, or disabled. |
| `space` | Logical 4, 8, 12, 16 | Inside a group, between related rows, between content groups, and outer margin. Preserve deliberate exceptions rather than replacing every value mechanically. |
| `control_height` | Start from current logical 30; reserve 36 for the search entry and major actions when space permits | Let measured label height expand controls. Do not shrink text to keep a fixed number of controls per row. |
| `cover_ratio` | Existing height/width ratio 1.34 | Keep covers undistorted. Assign a task-specific minimum recognizable cover size and calculate grid rows from available height. |
| `current_marker` | Existing black vertical mark, `W.scale(2)` to `W.scale(3)` stroke where geometry is explicit | Use the existing chapter reading-position mark as the signature. Extend it to a current reading position only where that state is known; do not mark every card. |

Use three distinct state signals: bottom-navigation underline for the current destination, an outer frame for keyboard focus, and the native checkbox/checkmark pattern for a selected option. The reading-position mark remains a fourth, content-specific signal. A black primary fill means that a meaningful action is currently available. It must not double as a disabled or selected-state indicator.

## Eight concrete improvements

### V1 — P1: Make primary appearance depend on availability

**Evidence.** `review-supplement-chapters-selection-empty` shows the disabled zero-selection download control as the strongest black rectangle on the page. The selected variant uses the same black mass for an available action. The current disabled text treatment changes the label but leaves the primary surface intact.

**Source.** `W.button`, `widgets.lua:48`, sets `enabled` at line 54 and applies `button[1].invert = true` unconditionally for `primary` at line 57. `Screens:_comic`, `screens.lua:1011`, creates a primary control whose `enabled` condition is the selected count. Existing card focus is independently drawn in `CoverCard:onFocus`, `widgets.lua:145`.

**Recommendation.** Define normal, enabled-primary, disabled, focused, and selected appearances as separate states. Use the black primary fill only when the action is enabled. An unavailable zero-selection action can retain a normal outlined shape and disabled label; keyboard focus should be an independent outer indicator, not a change that makes availability ambiguous. Preserve the visible selected count.

**Acceptance.** At 480 and 600, compare no selection, one selection, unavailable chapters, and submission/loading states. The zero-selection control must not look more actionable than enabled controls. Selected state and focus must remain identifiable independently. No disabled activation behavior changes are required for this visual adjustment.

**Originals.** [No selection](screens/suites/review-supplement/zh_CN-600x800/chapters-selection-empty.png), [selected chapters](screens/suites/review-supplement/zh_CN-600x800/chapters-selection-selected.png).

### V2 — P1: Promote consequential states out of the metadata gray

**Evidence.** The original Chapters page renders saved-image counts and downloaded state with almost the same visual strength as a disabled Previous control. Downloads uses gray for the entire combined state/progress line. Account uses the same gray for routine purchase information and session or balance conditions requiring attention.

**Source.** `Screens:_chapterRow`, `screens.lua:947` and `screens.lua:949`; `Screens:_jobRow`, `screens.lua:1116`; account state and balance information in `Screens:_account`, `screens.lua:1529` through line 1537. The shared color switch is `W.text`, `widgets.lua:35`.

**Recommendation.** Keep the short state label in black: downloading, downloaded, failed, retained version, needs sign-in, and balance may be outdated. Supporting counts or the longer explanation can remain secondary. Keep access, reading, and storage as distinct columns; do not combine them into an overloaded status badge. A warning should gain typographic emphasis and a precise label, not depend on a new color or icon alone.

**Acceptance.** In 480 and 600 captures, state and availability can be understood before reading the buttons. Disabled navigation remains visibly lower priority than useful state text. Ordinary author/tag text stays quiet, so the result is not simply an indiscriminate darkening of every label.

**Originals.** [Chapters](screens/suites/native-600x800/chapters.png), [Downloads at 480](screens/suites/native-480x640/downloads.png), [Account at 480](screens/suites/native-480x640/account.png), [stale balance](screens/suites/review-supplement/zh_CN-600x800/account-stale-balance.png).

### V3 — P2: Separate view controls, progress actions, and maintenance actions

**Evidence.** Chapters displays six identical outlined controls in a two-row matrix before the chapter list. Account mixes navigational settings, cyclic value controls, refresh actions, imports, and cache deletion in similar rectangles. A failed download may expose four adjacent controls with equal border weight. The primary action must be found by reading each label.

**Source.** `Screens:_buttons`, `screens.lua:365`, always gives sibling entries equal widths. Chapter controls and actions start at `screens.lua:993` and `screens.lua:1022`; download actions at `screens.lua:1097`; account rows at `screens.lua:1538` and `screens.lua:1548`. `W.button` already supports `borderless`, alignment, and primary emphasis at `widgets.lua:48`.

**Recommendation.** Treat filter and sort as compact borderless view controls with explicit current values; retain their full native hit rectangles. Give selection mode and the currently useful task action an outlined or primary treatment. Keep removal and less frequent recovery/maintenance options visually secondary and separated from pause/resume. Use a consistent label/value/chevron grammar for settings rows where the native widgets support it, while keeping immediate actions recognizable as actions. This is a task-specific hierarchy, not a rule that every page gets the same control count or density.

**Acceptance.** The current chapter and comic identity remain the first content landmarks. View controls are distinguishable from operations without shrinking their text. At 480, no download row needs four equally narrow, equally emphasized buttons. Do not increase the chapter toolbar height while restyling it; if a control moves into a native menu, its route and keyboard access must remain explicit.

**Originals.** [Chapters at 480](screens/suites/native-480x640/chapters.png), [Account](screens/suites/native-600x800/account.png), [download failure](screens/suites/download-recovery/600x800/failed-download.png).

### V4 — P2: Rebalance the Bookstore landscape grid using available height

**Evidence.** The 600 by 800 Bookstore has recognizable portrait covers and compact metadata. At 960 by 720, the same grid holds four columns and two rows, but covers become small islands inside wide cells while title text grows with device scaling. The title blocks compete with the cover image. In contrast, the three-column landscape Bookshelf retains a clear cover/title/progress relationship.

**Source.** `Screens:_coverGrid`, `screens.lua:601` through line 619. Bookstore chooses four columns from the raw screen-width threshold at line 602, forces the browsing-row policy at line 617, and reserves scaled metadata height before computing cover height. `CoverCard:init`, `widgets.lua:110` and lines 115 to 120, controls cover ratio and compact caption blocks.

**Recommendation.** Calculate the grid from the actual usable rectangle and rendered title/tag blocks, including orientation, instead of independently fixing column count, row count, and scaled metadata reservation. First reduce unnecessary vertical chrome and caption gaps in a landscape profile; then evaluate the densest layout whose covers remain identifiable. Preserve two browsing rows where they remain useful, but do not make eight visible items an absolute requirement if it produces token-sized cover art. Keep Bookshelf as a separate resume-oriented layout.

**Acceptance.** Compare 480 portrait, 600 portrait, 720 portrait, and 960 landscape with both short and two-line titles. No distorted artwork, clipped caption, or collision with navigation. The Bookstore cover must still read as a primary recognition cue, and the metadata must fit below it. Report the resulting visible-item count alongside the screenshots rather than calling lower density a failure by itself. Bookshelf must not be forced into Bookstore density.

**Originals.** [Bookstore at 600](screens/suites/bookstore-expanded/zh_CN-600x800/synthetic-bookstore-expanded-recommendations.png), [Bookstore landscape](screens/suites/bookstore-expanded/zh_CN-960x720/synthetic-bookstore-expanded-recommendations.png), [Bookshelf landscape](screens/suites/bookshelf-finishing/zh_CN-960x720/synthetic-bookshelf-finishing-default.png).

### V5 — P2: Give lists a measured body budget and a consistent paginator

**Evidence.** Chapters and Downloads stop well above the persistent bottom navigation, even when more chapter content exists. Their full-width three-button paginator looks like another action row, including a framed disabled page count. Cover grids instead use a quiet top-right count and arrows. These visual systems describe the same page-navigation concept with different affordances.

**Source.** `Screens:_render`, `screens.lua:435` through line 458, reserves a fixed body budget and fills the remaining area. `Screens:_paginate`, `screens.lua:378`, subtracts another fixed reserve and renders the count as a disabled button at line 394. Chapters additionally supplies the fixed content budget at `screens.lua:1046`; grid pagination uses text and arrows at `screens.lua:633`.

**Recommendation.** Derive the list budget from measured header, toolbar, row, paginator, and navigation heights. Use a shared paginator grammar: directional controls with a noninteractive page-count label, consistent disabled appearance, and a predictable gap from the content. The paginator can remain beside the grid header and beneath lists if those placements serve the task, but it should not change from metadata to a fake action. Reclaim space for extra chapter rows only after preserving readable row spacing. Do not fill empty Search, Account, or a short Bookshelf just to remove white space.

**Acceptance.** A mixed normal/temporary-entitlement chapter list, long download titles, and 480/600 sizes fit the computed body without clipping. Any extra rows are justified by actual measured space. Empty and single-page lists do not show a row of three disabled-looking boxes. The bottom navigation remains anchored, and page navigation has the same visual vocabulary across lists and grids.

**Originals.** [Chapters](screens/suites/native-600x800/chapters.png), [Downloads](screens/suites/native-600x800/downloads.png), [Search results](screens/suites/review-supplement/zh_CN-600x800/search-results.png), [empty Downloads](screens/suites/review-supplement/zh_CN-600x800/downloads-empty.png).

### V6 — P2: Consolidate type roles, spacing, and chrome weight

**Evidence.** Similar information uses many adjacent type sizes: account identity is 27, page title 25, detail comic title 24, section title 21, search result 20, download title 19, and cover title 16 or 18. Some differences serve the task, but the current system has no explicit role boundary. Header separators also change from a light Bookshelf rule to a dark rule elsewhere without indicating a different hierarchy. Tiny placeholder covers repeat truncated titles that are already available immediately beside them.

**Source.** `W.text`, `widgets.lua:31`; cover fallback at `widgets.lua:95`; compact and Bookshelf captions at `widgets.lua:115`; route chrome at `screens.lua:440` and `screens.lua:457`; comic detail identity at `screens.lua:988`; account identity at `screens.lua:1526`.

**Recommendation.** Introduce a small role table based on the proposed tokens, retaining explicit compact-card exceptions. Normalize spacing to a few related values and reserve the strongest rules for state/focus or meaningful group boundaries. Give all route headers the same rule treatment. A small missing-cover placeholder should use a quiet, identifiable cover silhouette or a short native text label, not another clipped copy of the title. Keep native faces and native glyph support; do not introduce a custom web-font visual identity.

**Acceptance.** Side-by-side pages have the same heading, body, state, and metadata roles while Bookstore remains compact. Two-line English and Chinese title fixtures fit their assigned caption blocks without vertical cut-off. A missing cover does not make the title area look broken or duplicate an ellipsis. Use original images to distinguish product frames from borders printed into cover artwork.

**Originals.** [native cover fallback](screens/suites/native-600x800/bookshelf.png), [detail fallback](screens/suites/native-600x800/chapters.png), [Account](screens/suites/native-600x800/account.png), [Bookshelf](screens/suites/bookshelf-finishing/zh_CN-600x800/synthetic-bookshelf-finishing-default.png).

### V7 — P1: Structure native dialogs around state, scope, and next action

**Evidence.** Purchase, recovery, and generic error dialogs place their heading and full explanation into a single `ButtonDialog.title` string. In the 480 batch-purchase capture, the comic name, next action, price, access duration, balance, and uncertainty explanation have nearly the same text treatment. Several equally weighted action rows follow. A reader chapter-boundary dialog already has a much simpler structure worth retaining.

**Source.** `Screens:_purchaseDialog`, `screens.lua:1927`, constructs the compound title; amount and scope appear at `screens.lua:2009` through line 2030; confirmation is added at `screens.lua:2048`; final construction is at `screens.lua:2071`. `Screens:_downloadRecovery`, `screens.lua:1180`, and `Screens:_error`, `screens.lua:329`, use the same title/body concatenation. Reader boundary and error entry points are `Controller:_chapterBoundary`, `controller.lua:1986`, and `Controller:_pageError`, `controller.lua:2022`.

**Recommendation.** Build a reusable native dialog composition: short state heading, comic/context label, a grouped amount-and-scope summary where applicable, brief supporting explanation, and a separated action area. Keep the important amount and chapter scope adjacent and readable before confirmation. Use native widgets and host dismissal/focus behavior. Keep detailed verification text available in the existing native viewer, but never hide the final charge, scope uncertainty, or unknown-result state behind a details link. Emphasize the currently appropriate action without making a paid confirmation the automatic focus or default action.

**Acceptance.** At 480 and 600, confirmed quote, unverified candidate, insufficient balance, submitting, unknown result, confirmed access, and retry states remain visibly distinct. Unknown result has no apparent repeat-purchase action. Exact amount and scope fit without being truncated. Long explanation text expands or scrolls through native mechanisms while the relevant actions remain reachable. Reader dialogs retain their native overlay behavior and do not add persistent chrome over the reading canvas.

**Originals.** [batch purchase at 480](screens/suites/native-480x640/purchase-batch.png), [unknown result](screens/suites/native-600x800/purchase-unknown.png), [reader menu](screens/suites/review-reader/600x800/reader-menu.png), [locked next chapter](screens/suites/review-reader/600x800/reader-next-locked.png).

### V8 — P2: Make Search and empty states read as deliberate entry points

**Evidence.** Search begins with two full-width outlined rectangles of almost equal emphasis: the main title/author entry and the alternate ID route. The no-history state places a normal-weight instruction immediately below a recent-history heading. Empty list states elsewhere can inherit generic guidance and a disabled paginator, making them look like a partially rendered list instead of an intentional state.

**Source.** `Screens:_search`, `screens.lua:1337` through line 1355; generic list empty text at `screens.lua:387`; cover-grid empty content at `screens.lua:696`; Bookshelf empty-state/action decisions at `screens.lua:577` through line 592.

**Recommendation.** Keep the search entry as the obvious first action; make the ID route a secondary borderless native control. Show the recent-history heading only when history content exists, or use an explicitly named empty-history section with quieter copy. Use a shared empty-state composition across lists and grids: short state title, concise contextual explanation, and one relevant recovery or entry action when available. Place it near the normal content start rather than vertically stretching it to occupy the page. Preserve calm unused space.

**Acceptance.** At 480 and 600, the search entry is identifiable before reading both labels. The ID route retains its full interaction and keyboard target. Loading, no results, no history, no download tasks, and failed refresh look intentional and distinguishable. No empty state claims there are results or presents a fictitious page action. The changes do not introduce decorative illustrations, animations, or a second navigation system.

**Originals.** [Search at 480](screens/suites/native-480x640/search.png), [no history](screens/suites/review-supplement/zh_CN-600x800/search-empty-history.png), [no results](screens/suites/review-supplement/zh_CN-600x800/search-no-results.png), [empty Bookshelf](screens/suites/bookshelf-finishing/zh_CN-600x800/synthetic-bookshelf-finishing-confirmed-empty.png).

## Suggested review order

First compare V1, V2, and V7 because they affect interpretation of availability, recovery, and transaction state. Then compare the action zoning and measured layout changes before fine-tuning typography and spacing. Capture the same fixtures and state variants in `ssh test-env`, keeping the existing native reader and source behavior intact. Review the resulting originals at 480, 600, and landscape sizes; device-level comfort and refresh behavior remain a separate acceptance step.

Do not treat the 616-image gallery's successful capture checks as evidence that every proposed visual change is correct. This document recommends focused before/after comparisons; it does not claim new runtime or accessibility verification.
