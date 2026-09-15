# Optimized native UI previews

These images show the implemented BiliComics UI optimization, captured from the production Lua widgets in KOReader v2026.07.1 on `test-env`. The gallery uses synthetic records, balances, transactions, and original image fixtures. It is not a browser mockup of the plugin.

Open `index.html` for the complete optimized gallery. Open `comparison.html` for same-size before/after images. `overview.png` shows the seven principal surfaces. The self-contained comparison copies its selected baseline images into `before/`.

## Implementation

- Shared typography, stronger status contrast, available-primary styling, and whole-row touch/key targets.
- Persistent navigation context, accessible search history, explicit search filters, and route-specific empty/error/loading states.
- Visible bookshelf updates, shelf controls, measured grids, and a landscape Bookstore layout with recognizable covers.
- Compact chapter identity and overview, authoritative Continue/Start reading, chapter jump, whole-row actions, explicit download-selection scope, and measured pagination.
- Download actions follow state and recovery prerequisites. Confirmation names the comic, chapter, and copy. Current and retained copies remain independently protected.
- Grouped account controls, explicit preload/cache choices, feedback after cache changes, and a visible background-import contract.
- Purchase state headings and summaries, descriptive options, read-only submitted terms, visible reconciliation errors, and post-purchase content progress. Closing remains the initial focus instead of a paid confirmation.
- Static reader loading/error text, meaningful recovery destinations, clearer chapter boundaries, and accurately named native comic actions.

Screen implementations are split into catalog, downloads, account, and purchase mixins under `bilicomics/ui/`, sharing navigation, widgets, and localization. All transaction authorization, unknown-result, account-generation, content verification, and reader-protection rules remain in their original services/controllers.

## Verification

The final capture matrix contains 16 passing tasks, 234 scene identifiers, and 677 original screenshots. All main flows cover Chinese 480 x 640 and 600 x 800, with additional English/larger/landscape Bookshelf and Bookstore cases. Pagination can produce additional scenes at the smaller size. `review-capture-manifest.json` records commands, source hashes, individual results, and image hashes.

The optimization regression passed 48 assertions per size. It checks search-context restoration, history controls, row hit-region updates, unavailable primary actions, empty states, cross-page selection, offline eligibility, and purchase-error feedback. The reader regression passed all nine modes and 327 assertions, including native resource ownership, permission expiry, cropped/inverted placeholders, ready content, process-restart anchors, and thumbnail boundaries.

Application checks and screenshot generation ran only on `test-env`. These results do not establish real-service availability, real purchase behavior, physical e-ink contrast/ghosting, or touch accuracy on hardware.

The comparison contains 27 matched scenes and 54 same-size before/after pairs. Remote Chromium verified gallery filtering, original-image viewing, note persistence/export, comparison navigation, size switching, single-side/zoom views, and 390-pixel layouts without horizontal overflow or JavaScript errors. See `artifact-verification.json` and `reader-verification.json` for the corresponding receipts. The optimized gallery uses a separate browser-storage key so baseline review notes do not silently apply to changed screenshots.

## Regeneration

Upload the production source and specs to an isolated remote workspace, then run:

```powershell
ssh test-env 'python3 SOURCE/spec/ui/run_review_capture.py RUNTIME SOURCE CAPTURES --pillow PILLOW'
ssh test-env 'PYTHONPATH=PILLOW python3 SOURCE/design/ui-review-optimized/build_gallery.py --captures CAPTURES --output GALLERY --font CJK_FONT'
ssh test-env 'PYTHONPATH=PILLOW python3 SOURCE/design/ui-review-optimized/build_comparison.py --before BASELINE_GALLERY --after GALLERY --font CJK_FONT'
```

Use fresh capture/output directories. The gallery is static and has no CDN or application-server dependency. Review notes remain in the current browser and can be exported as JSON.
