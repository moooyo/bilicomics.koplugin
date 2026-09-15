# Comprehensive UI/UX Review

Reviewed on 2026-09-15. This report consolidates the native screenshot review and current source inspection. The recommended direction is a quiet, reading-centered monochrome interface with clearer state, predictable navigation, and stronger action hierarchy.

## Evidence and scope

The source gallery contains **203 scenes and 616 original captures**. The functional reviewers covered all 203 representative scenes through the group contact sheets: 75 navigation/discovery/catalog scenes, 80 purchase/download scenes, and 48 account/reader scenes. Selected original 480 x 640 and 600 x 800 images were enlarged for text and action review; Bookshelf and Bookstore additionally received larger-screen and landscape inspection. This is complete coverage of the captured scene inventory, not a claim that every possible runtime state is captured.

Current production code was inspected alongside the images. A still image establishes presentation; code establishes the referenced branch or navigation contract. Findings that have not been replayed interactively remain labeled as source observations in the detailed reports. The exact reconciliation-error, confirmation-time changed/expired-quote, and delayed post-purchase continuation branches need dedicated future captures.

The screenshots use synthetic records and original art in the official KOReader Linux runtime. Synthetic English titles, author names, balances, and unusual option counts are not product defects. Native host-widget English labels in this harness are not established plugin localization bugs. No production UI was changed during this review. Physical e-ink contrast, ghosting, device latency, scanning reliability, target size in millimeters, and user error rates have not been measured.

## Main assessment

The product already distinguishes difficult domain states: reading position, entitlement, offline availability, unresolved purchases, retained versions, and recovery stages. Those distinctions should survive a redesign. The largest opportunity is to translate that state into a smaller set of recognizable decisions.

Three structural problems recur across screens:

1. **The main task competes with utilities.** The chapter screen presents six similarly weighted tools, while reading is implicit in a chapter title. Download rows present several equivalent-looking actions. Account combines identity, authentication, balance, storage, and low-frequency diagnostics at similar prominence.
2. **Visual and interaction rules vary by surface.** Whole cards are interactive on the grids, but only titles are interactive in search rows. Some setting rows open a choice, while others change the value immediately. Filters cycle silently on some screens and open a picker on others. A disabled primary action can still be the strongest black region.
3. **Important state is either weak or lacks a matching next step.** The image-loading screen has no loading message. Search, downloads, and chapters inherit bookshelf empty copy. Several recovery messages name a destination the buttons do not reach. A purchase result can retain a confirmation heading or hide a reconciliation error.

The visual work should make the reading task and the state easier to recognize. Keeping native KOReader conventions, monochrome surfaces, and restrained decoration is appropriate. A new visual framework or replacement reader is not required by these findings.

## Consolidated priorities

The table uses rollout order rather than security severity. **First** means resolve misleading or missing feedback and broken context; **Next** means improve frequent decisions and consistency; **Refine** means tune presentation after those behaviors are stable. Detailed reports use their own P1-P3 labels, which are local to their stated scope and should not be summed as unique defects.

| ID | Order | Current issue | Recommended outcome | Evidence |
| --- | --- | --- | --- | --- |
| R01 | First | Loading an unavailable image produces an almost blank gray page. | A static loading message identifies the page; waiting and failed acquisition are visually distinct. | [RA01](review-reading-account.md#ra01---p1-image-loading-has-no-recognizable-status), scene 200 |
| R02 | First | Search, chapter, and download empty views reuse bookshelf guidance; loading can coexist with empty copy. | Route-specific initial/loading/error/empty/filter-empty content with one applicable next action; no empty 1/1 pagination. | [N12](review-navigation.md#n12-search-and-chapter-emptyloading-states-reuse-a-library-instruction), [DL-05](review-transactions.md#dl-05--p2-give-the-download-empty-state-a-relevant-explanation-and-action) |
| R03 | First | Returning from a catalog drops a search filter; settings and reader return do not consistently restore the source task. | Restore query, filter, page, focus, and originating route together, only while valid for the same account. | [N1/N5](review-navigation.md), source observations |
| R04 | First | A successful search has no ordinary route back to recent searches. | A visible clear/search-home action makes history reachable within the same session. | [N2](review-navigation.md#n2-recent-searches-become-unreachable-after-the-first-query) |
| R05 | First | Recovery instructions and offered destinations diverge; job state alone selects recovery actions. | Offer actions that satisfy the failed prerequisite, identify any required reader close, and preserve position/cached content. | [RA02](review-reading-account.md), [DL-01](review-transactions.md) |
| R06 | First | Purchase loading, submission, rejection, pending result, and success share a confirmation-oriented heading. | The leading heading identifies the transaction stage; access confirmation remains distinct from payment confirmation. | [TX-01](review-transactions.md) |
| R07 | First | Reconciliation errors can be hidden when an existing intent is returned; confirmation-time quote errors become generic. | Retain the saved transaction and independently explain authentication/storage/quote changes with the applicable recovery. | [TX-02/TX-03](review-transactions.md), source-only branches need added captures |
| R08 | First | Removal, source refresh, and new-version confirmations do not name the selected comic/chapter/version. | Repeat the exact target and relevant consequences inside the confirmation itself. | [DL-02](review-transactions.md) |
| R09 | Next | Bookshelf computes update information but its card branch omits it. | A compact update cue is visible beside the independent saved reading position. | [N4](review-navigation.md#n4-the-default-bookshelf-hides-the-update-information-it-already-knows) |
| R10 | Next | Chapter utilities outrank reading, and long catalogs have no direct jump. | A clear Start/Continue reading action, a quieter tool row, and a chapter-number/title jump. | [N6/N8](review-navigation.md) |
| R11 | Next | Search covers and subtitles look actionable but are not part of the title's hit target. | Whole-result and whole-chapter rows have a predictable primary action/focus region; independent actions stay distinct. | [N3](review-navigation.md) |
| R12 | Next | Filter controls silently cycle through options. | Use a consistent explicit picker or a clearly visible short set of choices, with current filter and clear action. | [N10](review-navigation.md) |
| R13 | Next | Preload/cache settings immediately cycle values while adjacent concurrency opens a selector. | One setting-row contract shows label, current value, choices, and save behavior; clearing cache reports its result. | [RA04](review-reading-account.md) |
| R14 | Next | Closing session validation can allow adoption to continue without explaining background behavior. | Clearly distinguish dismissal from cancellation; if work continues, retain an accessible completion/failure result. | [RA05](review-reading-account.md) |
| R15 | Next | Cross-page and hidden filtered download selections are not explained. | Explicit selection scope, off-page count, selected-items review, and Clear selection. | [N7](review-navigation.md) |
| R16 | Next | Disabled primary controls retain black emphasis; focus, selected, active, and unavailable cues compete. | Black fill indicates an available primary action; focus and selection have separate, consistent non-color cues. | [Visual-system review](review-visual-system.md), empty versus selected download captures |
| R17 | Next | Candidate offers omit the requested-selection summary; option controls require matching descriptions to numbers. | A labeled requested-versus-verified summary, meaningful option rows, selected choice, expiry, and unavailability reason where known. | [TX-05/TX-06](review-transactions.md) |
| R18 | Next | Pending/result views lose recognizable submitted terms; list entries favor internal IDs. | Read-only comic/chapter/quote/purpose/time context, internal IDs in details, and honest unresolved-range guidance. | [TX-04](review-transactions.md) |
| R19 | Next | Canceled tasks still expose Cancel; In progress includes failed/canceled work; old/new copies are visually similar. | An action matrix follows task state; unfinished work is labeled honestly; related copies have clear version identity. | [DL-03/DL-04](review-transactions.md) |
| R20 | Next | Authentication guidance favors import in one context and QR in another; the host catalog entry opens an extra menu. | QR is the consistent ordinary recovery path; entry labels match their actual destination. | [RA06/RA08](review-reading-account.md) |
| R21 | Refine | Important reading, storage, and account errors use the same muted treatment as ordinary metadata. | Dark text and a redundant marker identify important state; muted gray is reserved for nonessential explanation. | [Visual-system review](review-visual-system.md), [RA06](review-reading-account.md) |
| R22 | Refine | Fixed row reservations and forced grid rows distort actual content density, especially in landscape. | Determine capacity from measured content constraints; improve density without shrinking essential text. | [Visual-system review](review-visual-system.md), initial review item 6 |
| R23 | Refine | Search, synopsis, and catalog expose different subsets of comic information. | One compact shared identity/overview model, with full title, author, publication status, and expandable synopsis where available. | [N9/N11](review-navigation.md) |
| R24 | Refine | Chapter boundaries and display-default entries lack some context about next chapter, stopping, and settings scope. | Name the next chapter, offer a clear stopping destination, and distinguish this chapter's display settings from new-chapter defaults. | [RA09/RA10](review-reading-account.md) |

## Recommended visual system

### Reading position as the visual anchor

Use a single restrained reading marker consistently on bookshelf cards, current chapter rows, and the Continue action. Preserve a separate update cue: latest publication and saved reading position answer different questions. Keep the cover art as the main visual identity in browsing surfaces; reading content should remain free of permanent product chrome.

### Roles before individual sizes

Use a small role-based type scale: screen title, comic/section title, body/action, and secondary metadata. Reuse the native KOReader faces and existing scaling facilities. Starting values should be calibrated against current native rendering, with roughly 22-24 for screen titles, 18-20 for strong content/actions, 16-18 for body/status, and 13-14 for truly secondary metadata. These are candidate native face-size roles, not physical measurements or a claim that CSS pixels map to device pixels. Long titles must have a route to their full text.

Adopt one spacing rhythm based on existing scaled units: approximately 4 for related text, 8 for controls within a group, 12 for row/card separation, and 16-20 for separate sections. A small number of roles is more valuable than enforcing these starting numbers everywhere.

### Contrast and state

Use black for primary text, critical status, and focus. Use a dark secondary tone such as `#444444` or `#555555` for metadata users need to read. Reserve lighter tones for dividers, unavailable controls, and nonessential explanation. Keep selected/disabled/focused states distinguishable through labels, marks, borders, or weight rather than gray alone.

The inspected runtime defines `BB.COLOR_DARK_GRAY` as `Color8(0x88)`; the shared `W.muted` uses that token. Interpreted as sRGB `#888888` on white, its digital contrast ratio is approximately **3.545:1**. W3C's web guidance uses 4.5:1 for ordinary text and 3:1 for qualifying large text. This is a useful reference for strengthening important small status text, not a claim of WCAG conformance/nonconformance for the native app or a measurement of an e-ink panel. [W3C text contrast guidance](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html).

The W3C target-size criterion describes CSS-pixel dimensions and spacing exceptions. It should not be copied as a 24-device-pixel rule into native KOReader. Review actual widget hit regions, keyboard focus, scaling, and physical-device interaction instead. [W3C target-size guidance](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html).

### Action hierarchy

Within one decision group, use one available primary action in black. Use an outlined secondary action and quieter utility actions. A destructive action should name the object and consequence and remain visually distinct from Resume/Retry. A disabled action must not attract more attention than available actions. The shared widget layer should own these state rules so individual pages do not improvise them.

### Density follows the task

Bookshelf supports recognition and resuming a few followed works; Bookstore supports scanning candidates. Their densities can legitimately differ. On the shelf, first use the existing caption budget to expose reading/update information. In the store, retain compact browsing while checking cover-to-caption proportions in landscape. In the catalog, improve the relationship between toolbar height, actual row height, and page capacity. Avoid solving every overflow by reducing type size.

## Page-level direction

| Surface | Main user question | Suggested leading structure |
| --- | --- | --- |
| Bookshelf | What should I continue, and what updated? | Cover, readable title, trusted progress, distinct update cue; discoverable filter/sort and full-row focus. |
| Bookstore | Which comic should I inspect? | Category and result context, compact covers, concise nonduplicate metadata, stable pagination and recovery. |
| Search | Did I find the right work? | Editable/clearable query, accessible history, explicit filter, fully actionable results, contextual empty states. |
| Comic and chapters | Where do I start or resume? | Compact identity, Start/Continue, quieter tools, readable state rows, jump, clearly separate download selection mode. |
| Downloads | What is available, running, or needs help? | Group/state summary, identifiable chapter/version, progress and primary next action, separate secondary removal. |
| Account/settings | Am I signed in, and what will this setting change? | Identity and auth status, primary auth recovery, alternate import, grouped reading/cache settings, diagnostics as a support path. |
| Purchase | What did I select, what is confirmed, and what happens next? | State-specific heading, comic/chapter, requested/verified terms, amount/asset, one next action, retained record. |
| Reader | Can I keep reading or recover without losing my place? | Unobstructed content, recognizable loading/errors, matched recovery actions, contextual chapter boundaries. |

## Suggested implementation sequence

1. **Repair state and context.** Address R01-R08 together with the most localized high-value corrections: update visibility, search-row targets, explicit filter/settings choices, and disabled-primary styling. Add dedicated remote captures for the previously uncaptured transaction-error branches.
2. **Unify reusable UI behavior.** Introduce consistent action/state roles, contextual empty views, route return state, selection summaries, and task-specific recovery actions. Use current widgets and native dialogs; preserve controller transaction/reader guards.
3. **Recompose the chapter and download screens.** Use one complete chapter screen to settle type, action hierarchy, spacing, and measured row layout, then apply the same rules to other routes. The conversation's chapter concept is an exploratory layout, not a native implementation or verified capacity.
4. **Tune density and device behavior.** Compare 480 x 640, 600 x 800, portrait/landscape, larger fonts, key navigation, and focus. Perform any application validation only through `ssh test-env` unless local verification is explicitly authorized. Physical e-ink acceptance is a separate step on an authorized device.

## Acceptance criteria for the next UI pass

- Each route differentiates initial, loading, failed, true-empty, and filter-empty states. Every proposed action fulfills the message's instruction.
- Returning from catalog/settings/reading restores a valid originating context without leaking state across accounts.
- Tapping a visible result/card row behaves consistently with its apparent hit area; focus is visible and separate from persistent selection.
- Reading position, publication update, entitlement, and local storage remain separate facts.
- The purchase UI never presents a candidate as submittable, an access-only result as a confirmed charge, or a pending result as permission to resubmit. New terms require new confirmation.
- Every irreversible/removal confirmation identifies the target chapter and version; reversible pause does not gain unnecessary confirmation steps.
- Settings and background operations make their effect and cancellation/dismissal contract visible.
- Essential text and controls remain visible at all approved sizes without truncation hiding a required decision. Larger density never comes only from shrinking essential text.

## Detailed evidence

- [Navigation, discovery, and chapter review](review-navigation.md): 12 findings covering 75 captured scenes.
- [Purchase and download review](review-transactions.md): 12 findings covering 80 captured scenes.
- [Account, settings, and reader review](review-reading-account.md): 10 findings covering 48 captured scenes.
- [Visual-system review](review-visual-system.md): cross-screen hierarchy, typography, state styling, and responsive layout.
- [Original gallery](index.html): all source images, sizes, scene identifiers, and screenshot notes.

## Strengths to retain

Keep Bookshelf as the default destination and preserve the four primary navigation tabs. Retain QR's waiting/scanned/expired distinction and quiet zone. Keep native ReaderUI behavior and saved per-chapter settings. Preserve explicit unknown-result handling, immutable pending purchase purpose, conservative unverified offers, read/download separation, current-reader protection, and separate retained copies. Those are useful product guarantees that should become clearer through the redesign.
