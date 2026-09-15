# Initial UI/UX Review

These are initial observations from a visual sample of 30 Chinese screenshots at 480 x 640 and 600 x 800. The sample covers the bookshelf, bookstore, search, chapter catalog, downloads, account settings, QR sign-in, purchase offers and results, and reader loading, error, and chapter-boundary states.

The screenshots are native KOReader framebuffer captures from the Linux environment accessed through `ssh test-env`, using synthetic records and original fixture images. They are not design mockups. This review does not establish physical E-ink contrast, refresh quality, touch accuracy, response time, QR scanning reliability, live-service behavior, or purchase behavior. English comic and account names are synthetic fixture content and are not localization findings. No production code was changed for this review.

## Confirmed issues

### 1. Reader image loading has no recognizable status

**Observation:** The loading screenshot is almost entirely a gray placeholder with the native page indicator. There is no visible message distinguishing an image being acquired from an unresponsive reader or an empty page.

**Impact:** Readers cannot readily tell whether to wait or seek recovery, especially when a page takes longer to arrive.

**Direction:** Add a static loading message that identifies the image or page being acquired. Avoid requiring animation to communicate progress.

**Evidence:** [Reader image loading, 480 x 640](screens/suites/review-reader/480x640/reader-image-loading.png).

**Source:** `ComicDocument:_placeholder`, `bilicomics/reader/document.lua:213`. The placeholder paints a gray rectangle and a stripe, then requests the page.

### 2. Search with no results displays bookshelf-oriented empty-state copy

**Observation:** The search screen shows the query and zero results, but its body tells the user to refresh the bookshelf or search for a comic.

**Impact:** The suggested next step does not explain the current search outcome or help refine the query.

**Direction:** Give search-specific guidance for no matches and no matches after filtering. Keep loading distinct from either empty state.

**Evidence:** [Search with no results, 600 x 800](screens/suites/review-supplement/zh_CN-600x800/search-no-results.png).

**Source:** `Screens:_search`, `bilicomics/ui/screens.lua:1372`, calls `Screens:_paginate` without an empty-state override. The shared fallback appears at `bilicomics/ui/screens.lua:388`.

### 3. The reader's low-storage recovery message lacks a matching action

**Observation:** The low-storage dialog instructs the user to remove downloads or clear automatic cache, but offers only image retry and close.

**Impact:** The user must discover how to reach the required storage controls before retrying can help.

**Direction:** Provide an entry to download management or cache settings alongside retry, while preserving the current reading context.

**Evidence:** [Reader low-storage error, 600 x 800](screens/suites/review-reader/600x800/reader-error-low-space.png).

**Source:** `Controller:_pageError`, `bilicomics/controller.lua:2046`, routes this error through the generic image-retry branch. `Model.error`, `bilicomics/ui/model.lua:245`, supplies the storage-cleanup instruction.

### 4. A pending purchase result retains the pre-submission confirmation title

**Observation:** After submission, the body says the purchase result is pending, while the dialog title still asks the user to confirm a purchase.

**Impact:** The title and body communicate different stages of the transaction. The existing explanation that the purchase will not be submitted again helps, but does not resolve the heading mismatch.

**Direction:** Use distinct headings for offer review, submission, pending result, rejection, and confirmed access.

**Evidence:** [Pending submission result, 480 x 640](screens/suites/quote-selection/480x640/synthetic-submission-result.png).

**Source:** `Screens:_purchaseDialog`, `bilicomics/ui/screens.lua:1927`, assigns the generic purchase-review heading before the intent-state branch at `bilicomics/ui/screens.lua:1946`. The Chinese translation of that heading is defined at `l10n/bilicomics_zh_CN.lua:333`.

## Discussion hypotheses

The following observations are visible in the sample, but their proposed changes require a product decision or additional usability evidence. They should not be treated as confirmed functional defects.

### 5. Unverified offers could expose the user's current selection more clearly

**Observation:** The single-chapter and batch candidate dialogs have nearly identical summaries. Their main surfaces do not directly identify which range the user selected. The Chinese single-chapter action also reads as a purchase action, although its callback requests another quote.

**Hypothesis:** Showing the requested range and payment choice, explicitly marked as unverified, would help users understand their current choice without implying that the exact purchasable chapters or final charge are established. A label equivalent to "Switch to a single-chapter quote" could better describe the action.

**Constraint:** Preserve the clear prohibition against submitting an unverified offer. Do not present the requested range as confirmed transaction scope.

**Evidence:** [Single candidate, 480 x 640](screens/suites/quote-selection/480x640/single-candidate.png) and [batch candidate, 480 x 640](screens/suites/quote-selection/480x640/batch-candidate.png).

**Source:** Candidate branch of `Screens:_purchaseDialog`, `bilicomics/ui/screens.lua:1994`; single-chapter quote callback at `bilicomics/ui/screens.lua:2003`; Chinese action label at `l10n/bilicomics_zh_CN.lua:424`.

### 6. Chapter pagination reserves more height than some pages use

**Observation:** In the native 480 x 640 catalog sample, a 17-chapter comic shows three chapters per page with substantial blank space below pagination. If any chapter in the catalog has temporary access, the source reserves the taller row estimate for the entire catalog, including pages without an expiry line.

**Hypothesis:** Pagination based on actual visible row heights, or a revised layout for expiry information, could reduce page changes. A stable page capacity may be an intentional tradeoff, so this needs a decision about navigation predictability versus density.

**Evidence:** [Chapter catalog, 480 x 640](screens/suites/native-480x640/chapters.png) and [chapter catalog, 600 x 800](screens/suites/native-600x800/chapters.png).

**Source:** `Screens:_comic`, `bilicomics/ui/screens.lua:972`, selects the catalog-wide row estimate; `Screens:_paginate`, `bilicomics/ui/screens.lua:378`, computes page capacity from that estimate.

### 7. Important status information uses the same muted treatment as secondary metadata

**Observation:** Reading position and cached-image status in the chapter list, as well as the account renewal-error explanation, are visibly lighter than primary text.

**Hypothesis:** Errors, expired access, and offline availability may deserve stronger contrast or another visual cue than ordinary descriptive metadata. Confirm any grayscale changes on physical E-ink hardware before making hardware-readability claims.

**Evidence:** [Chapter status columns, 480 x 640](screens/suites/native-480x640/chapters.png) and [account renewal error, 480 x 640](screens/suites/qr-login/480x640/qr-account-renewal-error.png).

**Source:** Shared muted color in `bilicomics/ui/widgets.lua:22`; `Screens:_chapterRow` at `bilicomics/ui/screens.lua:947` and `bilicomics/ui/screens.lua:949`; account authentication-state explanation in `Screens:_account` at `bilicomics/ui/screens.lua:1530`.

### 8. Bookshelf and bookstore cover gestures have different meanings

**Observation:** A bookshelf cover opens reading on tap and chapters on hold. A bookstore cover opens chapters on tap and a synopsis on hold. The bookstore displays a gesture hint; the bookshelf intentionally suppresses its equivalent hint.

**Hypothesis:** First-use guidance, a lightweight persistent cue, or a visible chapter-catalog action could improve discoverability while retaining quick resume from the bookshelf. The current behavior may be appropriate for experienced readers, so this should be reviewed with the intended audience.

**Evidence:** [Bookshelf, 480 x 640](screens/suites/bookshelf-finishing/zh_CN-480x640/synthetic-bookshelf-finishing-default.png) and [bookstore, 480 x 640](screens/suites/bookstore-expanded/zh_CN-480x640/synthetic-bookstore-expanded-recommendations.png).

**Source:** `Screens:_bookshelf`, `bilicomics/ui/screens.lua:586`, passes an empty gesture hint. Cover tap and hold callbacks in `Screens:_coverGrid` appear at `bilicomics/ui/screens.lua:676` and `bilicomics/ui/screens.lua:680`.

## Strengths to preserve

- QR sign-in distinguishes waiting for a scan, waiting for phone confirmation, and an expired code. The expired state supplies a direct action to obtain another code. See [waiting](screens/suites/qr-login/480x640/qr-waiting.png), [scanned](screens/suites/qr-login/480x640/qr-scanned.png), and [expired](screens/suites/qr-login/480x640/qr-expired.png). Source: `QRLogin:_show`, `bilicomics/ui/qr_login.lua:42`.
- Chapter-boundary dialogs provide different next steps for a readable next chapter, a locked next chapter, and the final chapter. See [readable next chapter](screens/suites/review-reader/600x800/reader-next-free.png), [locked next chapter](screens/suites/review-reader/480x640/reader-next-locked.png), and [final chapter](screens/suites/review-reader/600x800/reader-final-chapter.png). Source: `Controller:_chapterBoundary`, `bilicomics/controller.lua:1987`.
- Pending purchase results explicitly state that the purchase will not be submitted again and provide a result-refresh action. Preserve this distinction when revising transaction headings. See [pending purchase](screens/suites/native-480x640/purchase-unknown.png). Source: `Screens:_purchaseDialog`, `bilicomics/ui/screens.lua:1946`.
