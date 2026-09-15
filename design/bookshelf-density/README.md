# Compact bookshelf previews

This revision replaces the bookshelf's separate filter/sort and pagination rows with one toolbar. It renders six comics per page at 600 x 800 and 720 x 960, four at 480 x 640, and eight at 960 x 720 when the list has enough entries. Covers are sized after reserving two rows and measuring the captions and toolbar.

Each card keeps a two-line title and a compact reading position. An Updated overlay appears only when the comic has an explicit update flag. It adds no layout height and does not replace the reading position. The full latest-chapter line is removed from the card. Filters use the toolbar picker; choosing All clears them. Sync and other infrequent actions remain under More.

When capacity changes, the remembered comic ID determines the restored page. A redundant redraw when no automatic sync method exists was removed, preventing duplicate visible-cover requests.

`comparison.html` compares this revision with the previously delivered optimized UI, which still showed two comics and two toolbar rows. `index.html` contains the focused bookshelf state gallery. All images are actual KOReader framebuffer captures with synthetic records and original fixture covers.

The grid and finishing suites passed Chinese and English at four sizes on `test-env`. They cover capacity, card bounds, the single toolbar/focus row, badge geometry, pagination, filtering, account-scoped view restoration, stale callbacks, and reading handoff. Bookstore category, broad native UI, and optimization regressions also passed on the remote host. No local verification or physical-device acceptance was performed.
