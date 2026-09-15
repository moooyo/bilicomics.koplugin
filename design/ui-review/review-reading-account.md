# Account, Settings, and Reader UX Review

## Scope and confidence

This review covers all 48 representative scenes in the account and reader contact sheets: account scenes **116-146** and reader scenes **187-203**. It uses [account sheet 1](group-account-01.png), [account sheet 2](group-account-02.png), and the [reader sheet](group-reader.png), with selected original 480 x 640 and 600 x 800 screenshots enlarged to inspect text, actions, and spacing. It also reads the production UI and controller paths that implement the visible interactions.

The images are native KOReader framebuffer captures from the remote Linux environment, with synthetic records and original fixture artwork. This is a visual and source review, not a new execution of the application. No local tests, runtime probes, or production edits were performed. Synthetic titles, usernames, balances, filenames, and the injected position of chapter-boundary dialogs are not treated as product defects.

**Confirmed observation** means the screenshot and/or cited source establish the stated presentation or interaction. It does not establish the frequency or severity experienced by users. **Design hypothesis** means the proposed improvement requires a product decision, usability evidence, or protocol verification. P1 addresses missing state or misleading recovery during interrupted reading; P2 addresses inconsistent interaction or avoidable recovery work; P3 addresses orientation and visual refinement.

Reader and account coverage is limited to these two portrait resolutions. The review cannot establish landscape layout, larger-screen behavior, physical touch targets, real E-ink contrast or ghosting, animation cost, device response time, QR scanning reliability, or live-service behavior. The captured reader menu is the plugin action dialog inside ReaderUI; the complete native KOReader menu was not captured. Its plugin entry is inspected in source.

## Priority overview

| ID | Priority | Confidence | Recommendation |
| --- | --- | --- | --- |
| RA01 | P1 | Confirmed observation | Make image acquisition visibly different from a blank or stalled reader. |
| RA02 | P1 | Confirmed observation | Make each recovery action lead to the destination named in its explanation. |
| RA03 | P2 | Confirmed observation | Give local image-rendering failure a specific explanation and appropriate recovery. |
| RA04 | P2 | Confirmed observation | Give related settings a consistent selection contract and show cache-change results. |
| RA05 | P2 | Confirmed observation | Define whether closing session validation cancels import or continues it in the background. |
| RA06 | P2 | Confirmed observation | Align authentication guidance with QR sign-in and make actionable account states prominent. |
| RA07 | P2 | Design hypothesis | Recover a temporary QR status-check failure without automatically starting a new scan. |
| RA08 | P2 | Confirmed observation | Make the native chapter-catalog entry match the action it actually performs. |
| RA09 | P3 | Design hypothesis | Expose the distinction between current-chapter controls and defaults for new chapters. |
| RA10 | P3 | Design hypothesis | Add chapter context and a clear stopping destination at chapter boundaries. |

## Findings

### RA01 - P1: Image loading has no recognizable status

**Confirmed observation.** The image-loading scene is a nearly empty gray page with a narrow stripe and the native page indicator. It does not identify acquisition as the reason for the missing content. The placeholder source paints these shapes and requests the page, but supplies no visible loading explanation.

**Impact.** During a slow acquisition, a reader has no reliable visual distinction between waiting, missing content, and an unresponsive reader. This is more consequential than decorative refinement because it affects the user's next action.

**Recommendation.** Use a static, high-contrast message such as "Loading image 3 of 12" with an explicit waiting state. Keep it distinct from a failure state. Do not require animation to make the state intelligible. If a longer wait is detected, expose a safe route back to the catalog or downloads while retaining the reading position; the threshold and cancellation behavior need implementation design.

**Evidence.** Scene **200**, `review-reader-reader-image-loading`: [480 x 640](screens/suites/review-reader/480x640/reader-image-loading.png), [600 x 800](screens/suites/review-reader/600x800/reader-image-loading.png).

**Source.** `ComicDocument:_placeholder`, `bilicomics/reader/document.lua:213`; page acquisition is requested at `bilicomics/reader/document.lua:220`.

### RA02 - P1: Recovery explanations and action destinations do not consistently match

**Confirmed observation.** The unavailable-source message explicitly tells the reader to open Downloads and choose a recovery option, but its action opens the chapter catalog. The low-storage message tells the reader to remove downloads or clear automatic cache, but offers only image retry and close. By contrast, the authentication error does provide the account destination named in its recovery path.

**Impact.** Users must reconstruct the missing steps while reading is interrupted. Retrying a low-storage operation before freeing space does not address the stated prerequisite.

**Recommendation.** Map each error to the action that fulfills its instruction: unavailable source to the affected download's recovery controls; insufficient space to storage management or cache settings; changed or retired content to the appropriate catalog/version choice. If recovery requires the current chapter to close, say so before navigating and preserve its position. Reserve image retry as the primary action for states that retry can plausibly resolve.

**Evidence.** Scene **196**, `review-reader-reader-error-source-unavailable`: [480 x 640](screens/suites/review-reader/480x640/reader-error-source-unavailable.png). Scene **194**, `review-reader-reader-error-low-space`: [480 x 640](screens/suites/review-reader/480x640/reader-error-low-space.png), [600 x 800](screens/suites/review-reader/600x800/reader-error-low-space.png). Comparison: scene **191**, [authentication error](screens/suites/review-reader/480x640/reader-error-auth.png).

**Source.** `Model.error`, `bilicomics/ui/model.lua:204` and `bilicomics/ui/model.lua:245`; `Controller:_pageError`, `bilicomics/controller.lua:2037`, `bilicomics/controller.lua:2041`, and `bilicomics/controller.lua:2046`.

### RA03 - P2: Local image-rendering failure loses its useful diagnosis

**Confirmed observation.** The image-decode scene displays the generic operation-failed message and advises refreshing the page. The source records an `image_decode` error with `retryable = false`, but the UI model has no corresponding message and the reader dialog still uses its generic image-retry action.

**Impact.** The reader is told neither that a local image could not be rendered nor how this differs from a connection failure. An undifferentiated retry action suggests that all missing-image states have the same remedy.

**Recommendation.** Identify the failed image and explain that its local copy could not be opened. Choose an explicit, supported recovery path, such as reviewing the download or replacing its damaged content, while preserving unaffected pages. Honor the distinction between retryable acquisition errors and local rendering failures. The effectiveness of the existing retry path was not executed or established by this review.

**Evidence.** Scene **193**, `review-reader-reader-error-image-decode`: [480 x 640](screens/suites/review-reader/480x640/reader-error-image-decode.png). Compare scene **195**, [connection failure](screens/suites/review-reader/480x640/reader-error-network.png).

**Source.** `ComicDocument:_draw`, `bilicomics/reader/document.lua:271`; `Model.error` fallback, `bilicomics/ui/model.lua:250`; `Controller:_pageError`, `bilicomics/controller.lua:2046`.

### RA04 - P2: Similar settings controls have different mutation behavior

**Confirmed observation.** Preload count and automatic-cache limit immediately cycle through values on tap. The adjacent concurrency control, with the same visual treatment, opens a selector instead. Changing the cache limit also immediately calls cache eviction. The wrap from 2048 MiB to 256 MiB is therefore materially different from merely opening a settings detail.

**Impact.** Users cannot infer which controls open choices and which immediately change behavior. They cannot see the next value before tapping or select an arbitrary value directly. The cache-lowering effect is particularly easy to overlook.

**Recommendation.** Reuse the explicit concurrency-selection pattern for preload and cache limits. Show current values and supported choices. Explain immediate effects when lowering the cache limit, and use a clear apply contract or an equally clear immediate-save convention. After explicit cache clearing, report the amount released and whether protected reading content remains; the current UI discards the successful operation's result and only refreshes aggregate numbers. This is a feedback improvement, not a claim that protected cache was deleted.

**Evidence.** Scene **116**, `native-account`: [480 x 640](screens/suites/native-480x640/account.png), [600 x 800](screens/suites/native-600x800/account.png). Concurrency comparison: scene **9**, `bookshelf-finishing-concurrency`, [480 x 640](screens/suites/bookshelf-finishing/zh_CN-480x640/synthetic-bookshelf-finishing-concurrency.png). Scene **130**, `review-supplement-cache-clear-confirmation`: [480 x 640](screens/suites/review-supplement/zh_CN-480x640/cache-clear-confirmation.png).

**Source.** `Screens:_account`, `bilicomics/ui/screens.lua:1553`, `bilicomics/ui/screens.lua:1559`, and `bilicomics/ui/screens.lua:1568`; `Screens:_imageConcurrency`, `bilicomics/ui/screens.lua:1583`; `Controller:setSetting`, `bilicomics/controller.lua:1663`; `Controller:clearAutomaticCache`, `bilicomics/controller.lua:1683`.

### RA05 - P2: Closing session validation has an unstated background contract

**Confirmed observation.** The file-validation dialog offers only Close. Closing clears the screen's session-input state, but does not cancel the controller's session validation or subsequent adoption of a successfully validated account. The UI completion callback then rejects the stale screen state, so it does not show the success dialog. The underlying account may still update; the finding is the unexplained relationship between dismissal and the operation, not a claim that every account change is invisible.

**Impact.** Users cannot tell whether Close means cancel, stop waiting, or continue importing in the background. This is a meaningful ambiguity for an operation that can replace the active account.

**Recommendation.** Choose and label one contract: "Cancel import" should prevent later adoption from that request; "Continue in background" should keep a visible completion or failure result. Also improve the start and retry steps: explain accepted file formats and the 128 KiB limit before selection, and provide a direct "Choose another file" action after a file error. The current error screen only offers Close.

**Evidence.** Scene **146**, `session-import-session-file-validating`: [480 x 640](screens/suites/session-import-480x640/session-file-validating.png). Scene **145**, `session-import-session-file-picker`: [480 x 640](screens/suites/session-import-480x640/session-file-picker.png). Scene **143**, `session-import-session-file-error`: [480 x 640](screens/suites/session-import-480x640/session-file-error.png).

**Source.** `Screens:_closeDialog`, `bilicomics/ui/screens.lua:98`; `Screens:_sessionFileCurrent`, `bilicomics/ui/screens.lua:1418`; `Screens:_sessionFileError`, `bilicomics/ui/screens.lua:1425`; `Screens:_importSessionFile`, `bilicomics/ui/screens.lua:1446` and `bilicomics/ui/screens.lua:1462`; `Controller:importSession`, `bilicomics/controller.lua:1223`.

### RA06 - P2: Authentication recovery needs one consistent user-facing story

**Confirmed observation.** A generic authentication failure still directs users to import a web session, while Account presents QR sign-in as the primary action. The renewal-error explanation says to retry or sign in again, but Account exposes no explicitly named renewal-retry action. Renewal progress, healthy automatic renewal, and errors share the same muted explanatory treatment.

**Impact.** Users receive conflicting guidance about the preferred sign-in method and an incomplete instruction for retrying renewal. An actionable error is visually similar to routine account metadata.

**Recommendation.** Guide ordinary reauthentication to QR sign-in and keep manual import as an alternate method. Either expose a real renewal-retry action or remove the unsupported instruction to retry. Give states requiring attention a black-text status label or other non-color cue, while retaining the lighter treatment for routine explanations. Keep the account identity and existing balances distinct from the sign-in status; synthetic balances in these screenshots are not evidence of a data bug.

**Evidence.** Scene **122**, `qr-login-qr-account-renewal-error`: [480 x 640](screens/suites/qr-login/480x640/qr-account-renewal-error.png). Scene **120**, `qr-login-qr-account-reauthentication`: [480 x 640](screens/suites/qr-login/480x640/qr-account-reauthentication.png). Scene **133**, `review-supplement-generic-error-auth`: [480 x 640](screens/suites/review-supplement/zh_CN-480x640/generic-error-auth.png). Scene **191**, [reader authentication error](screens/suites/review-reader/480x640/reader-error-auth.png).

**Source.** `Screens:_account`, `bilicomics/ui/screens.lua:1529` and `bilicomics/ui/screens.lua:1538`; `Model.error`, `bilicomics/ui/model.lua:228` and `bilicomics/ui/model.lua:231`; shared muted color, `bilicomics/ui/widgets.lua:22`.

### RA07 - P2: QR status-check failures could preserve the current sign-in attempt

**Confirmed behavior; design hypothesis for the remedy.** A polling error enters the same error view used for other sign-in failures. The QR code is removed and the available recovery obtains a new code. A user who already scanned does not have an explicit way to retry checking the current attempt's confirmation status.

**Recommendation.** Distinguish failure to obtain a code from failure to check an existing code. If the service protocol permits safely checking the still-valid attempt again, offer that operation without requiring a second scan. Ask for a new code after confirmed expiry or an invalidated attempt. Protocol support and account-state handling must be verified before adopting this change; the current capture cannot establish whether the service supports that recovery.

**Evidence.** Scene **124**, `qr-login-qr-error`: [480 x 640](screens/suites/qr-login/480x640/qr-error.png). Scene **127**, `qr-login-qr-scanned`: [480 x 640](screens/suites/qr-login/480x640/qr-scanned.png). Scene **125**, `qr-login-qr-expired`: [480 x 640](screens/suites/qr-login/480x640/qr-expired.png).

**Source.** `QRLogin:_poll`, `bilicomics/ui/qr_login.lua:94` and `bilicomics/ui/qr_login.lua:106`; `QRLogin:_show`, `bilicomics/ui/qr_login.lua:46`, `bilicomics/ui/qr_login.lua:54`, and `bilicomics/ui/qr_login.lua:65`; `QRLogin:start`, `bilicomics/ui/qr_login.lua:122`.

### RA08 - P2: The native chapter-catalog entry opens an intermediate action menu

**Confirmed observation from source and the captured destination.** The plugin's native navigation entry is named Chapter catalog, but invokes `showReaderMenu`. Its destination is an action dialog that contains another Chapter catalog action. Thus the entry promises a catalog but first requires another selection.

**Impact.** A frequent navigation action costs an avoidable extra decision, and the label does not describe its immediate destination.

**Recommendation.** Either make the native entry open the chapter catalog directly, or rename it to communicate that it opens comic actions. If the action dialog remains, distinguish "Download this chapter" from "Manage downloads" and consider identifying the current comic and chapter in its heading. Close currently dismisses only this dialog, which is normal for a menu; any future exit-reading action should be named separately.

**Evidence.** Scene **201**, `review-reader-reader-menu`: [480 x 640](screens/suites/review-reader/480x640/reader-menu.png), [600 x 800](screens/suites/review-reader/600x800/reader-menu.png). The originating full native menu is source evidence only, not an additional captured scene.

**Source.** `BiliComics:addToMainMenu`, `main.lua:61`; `Controller:showReaderMenu`, `bilicomics/controller.lua:2061`, especially actions at `bilicomics/controller.lua:2069` and `bilicomics/controller.lua:2075`.

### RA09 - P3: Current-chapter controls and new-chapter defaults need an easier connection

**Confirmed distinction; design hypothesis about discoverability.** The defaults dialog correctly explains that saved chapter settings remain unchanged. The implementation also deliberately preserves native per-document settings. However, the plugin reader action dialog does not link to current-chapter display controls or explain where those controls live, and global defaults are reached through Account and settings.

**Impact hypothesis.** Someone trying to change the page currently on screen may reach global defaults, change a value, and correctly see no effect on that chapter while still lacking a convenient path to the intended setting.

**Recommendation.** Preserve the correct scope contract. Add a concise connection to the native controls for the current chapter, or an explicit current-chapter display entry if supported by the host UI. Label the existing dialog "Defaults for new chapters" at its entry point. Treat return navigation as part of this flow: Account Back currently goes to the bookshelf, so an account page opened from reading does not explicitly offer a direct return to the interrupted reader. A visible "Back to reading" affordance should be evaluated without weakening account-change protections.

**Evidence.** Scene **190**, `native-reader-defaults`: [480 x 640](screens/suites/native-480x640/reader-defaults.png), [600 x 800](screens/suites/native-600x800/reader-defaults.png). Scene **201**, [reader actions](screens/suites/review-reader/480x640/reader-menu.png). Scene **116**, [account settings](screens/suites/native-480x640/account.png).

**Source.** `Screens:_readerDefaults`, `bilicomics/ui/screens.lua:1601` and scope explanation at `bilicomics/ui/screens.lua:1611`; `Defaults.apply`, `bilicomics/reader/defaults.lua:52`; `Controller:showReaderMenu`, `bilicomics/controller.lua:2068`; `Screens:_back`, `bilicomics/ui/screens.lua:316`.

### RA10 - P3: Chapter boundaries can provide more context and a better stopping destination

**Confirmed presentation; design hypothesis about improvement.** The boundary dialogs distinguish a readable next chapter, a locked next chapter, and no next chapter. Their headings and actions are generic: they do not identify the current or next chapter, and the final-chapter view offers catalog or stay, with no direct bookshelf destination.

**Recommendation.** Keep the existing safe distinction between reading the next chapter and reviewing a purchase quote. Add the next chapter's title or ordinal where known, and consider a direct bookshelf action when the user reaches the currently known last chapter. If the catalog may be stale, explain that this is the last known chapter and provide an intentional check for updates rather than implying the series itself is complete. Use a clearer hierarchy for continuing, browsing the catalog, and stopping without adding decoration over the comic artwork.

**Evidence.** Scene **202**, `review-reader-reader-next-free`: [600 x 800](screens/suites/review-reader/600x800/reader-next-free.png). Scene **203**, `review-reader-reader-next-locked`: [480 x 640](screens/suites/review-reader/480x640/reader-next-locked.png). Scene **199**, `review-reader-reader-final-chapter`: [480 x 640](screens/suites/review-reader/480x640/reader-final-chapter.png). These dialogs are injected over fixture pages; their background page number is not evidence of incorrect boundary detection.

**Source.** `Controller:_chapterBoundary`, `bilicomics/controller.lua:1986`, next-chapter actions at `bilicomics/controller.lua:1998` and `bilicomics/controller.lua:2004`, final actions and heading at `bilicomics/controller.lua:2013`.

## Visual direction and strengths to preserve

- Keep the native monochrome character, clear black typography, and restrained dividers. Prioritize meaningful status and action hierarchy over additional borders, icons, or filled panels.
- Use one visual pattern for setting rows: label, current value, and a consistent affordance for choosing another value. The existing concurrency selector already demonstrates the explicit-choice behavior.
- Give attention states stronger text weight than routine account metadata. Do not use a change of gray alone to communicate an error, expiry, selection, or success. Physical E-ink readability still needs separate device review.
- QR waiting, scanned, and expired states already describe the user's next step. Preserve the white quiet zone and avoid visual decoration inside the code area. This review does not establish scanning reliability.
- Preserve masked session input, explicit protection of manual downloads and current reading content during cache clearing, and the defaults dialog's explanation that saved chapter settings are retained.
- Preserve the uninterrupted artwork presentation in page-fit, strip, and zoom scenes. The fixture images are insufficient to judge real comic text legibility or the best default zoom for varied artwork. The captured error and boundary dialogs fit within the inspected portrait images; this is not a landscape or physical-device validation.
- Local diagnostics correctly distinguish local capability checks from actual service, permission, or payment outcomes. Keep that distinction, and expose diagnostics as a support path rather than requiring users to understand implementation details before reading.

## Remaining review boundaries

Future interaction verification should cover cancel-versus-background import, returning to the same reading context after account recovery, transient QR polling failures, changing settings while work is active, and recovery that first requires closing the current chapter. These are proposed follow-up scenarios, not checks executed in this review. Portrait screenshots also do not establish keyboard-only navigation, screen rotation, larger font preferences, enlarged display scaling, physical E-ink behavior, or the complete host menu experience.
