# BiliComics UI Design 01

This is an interactive visual prototype for the [implementation plan](../docs/implementation-plan.md), not the KOReader plugin. It uses fictional comics, balances, prices and download state. It does not call Bilibili or make purchases.

## Design direction

The interface is designed for a portrait e-ink screen, with 600 by 800 as the base layout and a larger-screen preview. Black and white are structural: a solid fill marks a primary action, an active navigation item or new content. Muted gray is reserved for secondary metadata and surfaces, never the only indication of state.

The signature element is a small clipped reading bookmark on the current comic. It identifies the resume point rather than decorating every card. Original monochrome cover art gives the library its visual character while preserving large text and quiet controls.

| Token | Value or role |
| --- | --- |
| Paper | `#FFFFFF` |
| Ink | `#191B1A` |
| Secondary text | `#5B605D` |
| Divider | `#D0D4D1` |
| Quiet surface | `#F0F2EF` |
| Review canvas | `#E7EAE9`, outside the product screen |
| Interface typography | Chinese sans-serif stack; primary screen title 29 px at the base size |
| Comic titles | Chinese serif stack used sparingly on covers and the resume/detail title |
| Utility typography | Small sans-serif/tabular numbers for page counts, status and prices |
| Primary controls | Approximately 46 px high; chapter rows and navigation provide larger effective hit areas |
| Motion | No animated navigation, scrolling effects or decorative transitions |

The surrounding review shell is separate from the proposed plugin. Its page shortcuts, device size, connectivity toggle, purchase scenarios and reset control are design-review tools.

## Screens

### Continue reading

One prominent resume card combines cover, chapter, source-image position and a primary Read action. Recent comics appear below. Update discovery is a small secondary action rather than a second competing hero.

### Following

A paginated list shows the latest chapter independently of local reading progress. All, Updated and Completed filters narrow the collection. Selecting a cover/title opens comic details; the reading action resumes directly.

### Comic details and chapters

A compact cover/header preserves space for the chapter catalog. Rows show reading, entitlement and storage state separately. The current chapter has a narrow leading marker. Filters, sort direction and a current-chapter shortcut are visible controls.

Download selection is a distinct mode with checkboxes. Locked chapters cannot be selected for download. The confirm bar shows the selected count. Existing cached content is reused, and selecting chapters does not authorize a purchase.

### Purchase

The modal shows the work, exact chapter or supported batch range, payment choice, usable assets and total. The confirmation button includes the asset amount. Pending submission freezes scope and payment selection.

Review scenarios include normal purchase, insufficient balance, unknown result and a completed purchase with image-loading failure. Unknown results preserve the unresolved transaction when the dialog is reopened. Their action is Refresh result, not Buy again. Insufficient balance offers Refresh balance without a recharge entry.

The prototype transaction is entirely in memory; production persistence and reconciliation must follow the implementation plan.

### Downloads

In-progress work shows image counts, pause/resume and partial completion. Complete offline content has a separate section and can be opened without connectivity. Removal preserves the conceptual reading and purchase state. The displayed storage totals track the demo's retained items.

### Search

Direct search, recent searches, result filtering and an actionable empty result. No recommendation feed is required to reach a chapter.

### Account and settings

Account state, existing balances, session replacement, prefetch and automatic-cache controls live outside the four primary navigation destinations. Clearing automatic cache preserves explicit offline downloads.

### Native reader context

The reader screen is an illustrative integration context, not a pixel-accurate replacement for KOReader. The adjacent design note makes this boundary explicit. It demonstrates the plugin menu, chapter boundary, prefetch/offline status and missing-cache behavior. Production reading controls remain native.

## Source and assets

The prototype is in `design/ui-prototype/`. HTML, CSS, JavaScript identifiers/comments and documentation are English; Chinese interface copy is maintained as localization data in `locales/zh-CN.json`.

All four cover SVGs and the comic-page SVG are original assets produced for this prototype. The fictional titles are supplied by the localization layer; the SVG files contain no baked-in title text. No third-party manga pages or account content are included.

## Verification

Browser checks run only on `ssh test-env`, using an isolated Playwright dependency and an HTTP server bound to that remote host's loopback interface. They cover navigation, chapter download selection, pending-purchase controls, insufficient balance, unknown-result continuity, paid-content retry, offline access, search and narrow-screen horizontal overflow. Screenshots are used for visual inspection.

The final recorded run passed 30 checks with no browser script errors. Base Continue, Following, Details and Downloads pages fit without vertical content overflow; the checked standard and narrow layouts have no horizontal overflow. See [the result record](screens/verification.json) and [the two-screen design board](screens/ui-overview.png).

The browser prototype is not evidence that the corresponding KOReader widgets or Bilibili APIs have been implemented. Its job is to make layout, copy and interaction choices reviewable before Lua UI implementation.
