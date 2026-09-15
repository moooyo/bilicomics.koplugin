# Purchase and Download UI/UX Review

Reviewed on 2026-09-15 against the current `Screens`, `Model`, `Controller`, purchase service, and capture manifest. The manifest records 203 scenes and 616 native screenshots. This review covers the four purchase/download contact sheets, representing 80 scenes, plus 24 full-resolution Chinese captures at 480 x 640 or 600 x 800. It includes quote loading, candidates, range/payment selection, confirmation, insufficient balance, submission, rejection, unknown results, confirmed access, continuation failures, download states, removal, source verification, and version replacement.

The captures use synthetic data in the official KOReader Linux runtime. Synthetic comic names, transaction identifiers, amounts, and large option counts are fixtures, not evidence of production content quality or frequency. No application code was changed and no tests or runtime probes were executed for this review. Static observations do not establish touch-error rates, time on task, response latency, or physical E-ink readability.

Priority means design/recovery priority: **P1** affects transaction understanding or successful recovery; **P2** affects recognition, navigation, or decision effort; **P3** is a smaller feedback improvement. **Confirmed visual** means the state is visible in an inspected capture. **Confirmed source** means the behavior follows from the current code; when no matching capture exists, that limitation is explicit. User-impact statements are reasoned risks, not measured usability results.

## Purchase findings

### TX-01 — P1: Make the transaction state the leading heading

**Evidence status:** Confirmed visual and source.

The same purchase-review heading remains above loading, submission, rejection, pending results, and confirmed access. In Chinese it reads as a confirmation instruction. During submission the only changed status is the disabled action near the bottom; after rejection the top still asks for confirmation. The actual state competes with the comic title and the planned continuation. This makes a completed or unresolved action look like an action still awaiting approval.

Use a distinct heading for each state: reviewing an offer, getting a quote, submitting, checking a result, result pending, rejected, and access confirmed. Keep the amount/asset and selected chapter immediately beneath the state when relevant. Place secondary selection controls below that summary. For an unverified offer, keep the inability to submit explicit. Never rename entitlement-only evidence to purchase success; an unresolved range must continue to say that access and transaction results differ.

**Screenshots:** `native-purchase` — [480 x 640](screens/suites/native-480x640/purchase.png); `review-supplement-purchase-submitting` — [480 x 640](screens/suites/review-supplement/zh_CN-480x640/purchase-submitting.png); `review-supplement-purchase-rejected` — [600 x 800](screens/suites/review-supplement/zh_CN-600x800/purchase-rejected.png); `ordinal-range-range-outcome-pending` — [480 x 640](screens/suites/ordinal-range/480x640/range-outcome-pending.png).

**Source:** `Screens:_purchaseDialog`, `bilicomics/ui/screens.lua:1927`, `:1930`, `:1946`, `:2048`; transaction evidence selection at `:1949`.

### TX-02 — P1: Show reconciliation failures even when a saved purchase exists

**Evidence status:** Confirmed source; the exact failing branch is not captured.

The reconciliation callback displays a notice only when `error and not value`. The controller deliberately returns both an existing intent and an error when authentication is unavailable or a known result cannot be persisted. Those errors are therefore hidden behind the unchanged pending-result screen. The user can repeatedly refresh without learning that sign-in or storage needs attention.

Keep the saved intent visible and independently present the recovery error. Offer the applicable next step, such as opening Account for authentication, while preserving the pending transaction and the prohibition on resubmission. Distinguish waiting for the service from waiting for local durable storage. Do not erase a previous intent merely to make an error display.

**Related screenshots, not proof of the missing branch:** `review-supplement-purchase-checking-result` — [600 x 800](screens/suites/review-supplement/zh_CN-600x800/purchase-checking-result.png); `native-purchase-unknown` — [480 x 640](screens/suites/native-480x640/purchase-unknown.png). Add review captures for an existing intent returned with authentication, storage, and network errors.

**Source:** `Screens:_purchaseDialog`, `bilicomics/ui/screens.lua:1984` and `:1988`; `Controller:reconcilePurchase`, `bilicomics/controller.lua:1815`, `:1827`, `:1839`; `Model.error`, `bilicomics/ui/model.lua:230`.

### TX-03 — P1: Explain quote changes at the confirmation boundary

**Evidence status:** Confirmed source, with related visual evidence; the expired/changed-quote error branch is not captured.

The purchase service distinguishes an expired quote, changed quote, and insufficient balance. Changed terms can include a refreshed quote. `Model.error` does not map `quote_expired`, `quote_changed`, or `insufficient_balance`, so these confirmation-boundary failures become a generic operation failure. This differs from the clear pre-confirmation insufficient-balance screen. The existing changed-price screenshot shows the newly displayed amount, but is not evidence of the error delivered when confirmation detects a change.

Explain what happened and whether submission started: the quote expired or the terms changed before submission. Preserve the user's requested range/payment choice, show the refreshed terms and any verified differences, and require a new explicit confirmation. Never automatically accept a changed price, scope, asset, or entitlement. Use purchase-specific network copy here: quote retrieval failed and no new purchase was sent; the generic suggestion about reading downloaded chapters does not resolve a quote decision.

**Screenshots:** `ordinal-range-changed-price-needs-confirmation` — [480 x 640](screens/suites/ordinal-range/480x640/changed-price-needs-confirmation.png), contextual updated quote; `quote-selection-insufficient-balance` — [600 x 800](screens/suites/quote-selection/600x800/insufficient-balance.png); `review-supplement-purchase-quote-error` — [480 x 640](screens/suites/review-supplement/zh_CN-480x640/purchase-quote-error.png).

**Source:** `Service:_validateQuote`, `bilicomics/purchase/service.lua:131`; `Service:prepareSubmission`, `:152` and `:155`; `Controller:purchase`, `bilicomics/controller.lua:1774`; `Screens:_purchaseDialog`, `bilicomics/ui/screens.lua:1932` and `:2063`; `Model.error`, `bilicomics/ui/model.lua:193`, `:241`, `:250`.

### TX-04 — P2: Keep a recognizable purchase record after submission

**Evidence status:** Confirmed visual and source.

After an intent exists, the result dialog drops the quoted amount, asset, anchor chapter, and scope-details entry. The pending list principally identifies transactions by internal intent ID. A user reviewing several unresolved transactions must open them individually, and even the result screen does not retain the submitted terms. The range-pending screen adds a purchase pause but offers only reading and closing, without explaining how that unresolved record can be inspected later.

Give pending rows a comic/anchor-chapter label, submission time, purpose, and concise state; place the internal ID in details. Retain a read-only submitted-quote summary and scope-details action in every result state. Label amounts as submitted quote terms, not a receipt or proof of a deduction. For access-confirmed/range-pending records, explain why further purchases are paused and where the record remains available. Do not add a reassuring refresh action unless the backend can acquire new evidence: `reconcilePurchase` currently returns an access-confirmed intent immediately.

**Screenshots:** `ordinal-range-pending-purchase-list` — [480 x 640](screens/suites/ordinal-range/480x640/pending-purchase-list.png); `ordinal-range-range-outcome-pending` — [480 x 640](screens/suites/ordinal-range/480x640/range-outcome-pending.png); `native-purchase-confirmed` — [600 x 800](screens/suites/native-600x800/purchase-confirmed.png).

**Source:** `Screens:_pendingList`, `bilicomics/ui/screens.lua:1657` and `:1663`; intent branch of `Screens:_purchaseDialog`, `:1945`; `Controller:reconcilePurchase`, `bilicomics/controller.lua:1822`; stored quote, purpose, and timestamps in `Service:prepareSubmission`, `bilicomics/purchase/service.lua:187`.

### TX-05 — P2: Distinguish requested selections from verified terms on the main quote screen

**Evidence status:** Confirmed visual and source; the proposed grouping needs usability review.

Single and batch unverified candidates have nearly identical main summaries. The requested range/payment information is mostly inside details. The fallback action uses the single-chapter purchase wording although its callback only requests a quote. Sorting controls also occupy a full row on ordinary single-chapter offers, with no explanation of what they sort. A user may lose track of the requested option or overestimate the effect of the fallback action.

Show a short, explicitly unverified requested-selection summary before candidate details. For a verified quote, show the applicable range, payment asset, and selected discount near the total. Rename the fallback action to the equivalent of requesting a single-chapter quote. Move discount/expiry ordering into payment selection with an explanatory label, retaining the underlying preference and quote refresh. Do not turn a requested batch count into a confirmed chapter set or present a platform reference price as the final charge.

**Screenshots:** `quote-selection-single-candidate` — [480 x 640](screens/suites/quote-selection/480x640/single-candidate.png); `quote-selection-batch-candidate` — [480 x 640](screens/suites/quote-selection/480x640/batch-candidate.png); `native-purchase` — [480 x 640](screens/suites/native-480x640/purchase.png); `native-purchase-batch` — [600 x 800](screens/suites/native-600x800/purchase-batch.png).

**Source:** `Screens:_purchaseSelectionText`, `bilicomics/ui/screens.lua:1755`; `Screens:_purchaseSelectionButtons`, `:1897`; candidate branch of `Screens:_purchaseDialog`, `:1994` and `:2003`; quote summary at `:2008`.

### TX-06 — P2: Make range and payment options distinguishable without cross-referencing serial numbers

**Evidence status:** Confirmed visual and source; actual option counts are fixture-dependent.

Each choice page displays two descriptive blocks and then separate buttons repeating generic option numbers. Payment descriptions mainly expose a discount type and ID; scope descriptions expose raw reference values. The captured payment chooser requires five pages and the range chooser four. The production candidate model already provides expiry and unavailable-reason fields that the chooser does not display. An unavailable option can be visibly disabled without explaining why.

Put each option's meaningful description and selection control together, with an unambiguous single-selection indicator. Prefer a verified discount type, expiry, availability reason, and requested range over an ordinal label; keep asset IDs in optional details. Keep the selected option visible when reopening, as the current code does. Consider a compact list with expandable detail before increasing page size. Any displayed price that is not confirmed must retain its reference-only label. Do not infer that the stress-fixture option count is common in live accounts.

**Screenshots:** `quote-selection-payment-options-page-2` — [480 x 640](screens/suites/quote-selection/480x640/payment-options-page-2.png); `quote-selection-payment-options-page-5` — [600 x 800](screens/suites/quote-selection/600x800/payment-options-page-5.png); `quote-selection-range-options-page-2` — [480 x 640](screens/suites/quote-selection/480x640/range-options-page-2.png).

**Source:** `Screens:_purchaseChoices`, `bilicomics/ui/screens.lua:1823`, `:1846`, `:1853`, `:1856`, `:1877`; candidate option metadata in `bilicomics/purchase/candidate.lua:191`.

### TX-07 — P3: Give content continuation its own progress language

**Evidence status:** Confirmed source; the busy continuation itself lacks a dedicated capture. Retry wording is visually confirmed.

After confirmed access, clicking Read or Download sets `state.continuing` and disables the same action, but does not rename it or show a processing message. The result body remains a static access explanation, and the download path uses image-loading copy oriented toward reading. The existing retry screen correctly avoids asking for another purchase, but the handoff could look inactive while content preparation is pending.

Show opening the chapter or creating the download as a separate content-operation status. On failure, retain the access result above an operation-specific error and retry action. Identify the target chapter and keep duplicate continuation clicks disabled. A short, persistent transition back to the download queue should make successful handoff clear; do not imply that a purchase is still running.

**Screenshots:** `native-download-access-confirmed` — [480 x 640](screens/suites/native-480x640/download-access-confirmed.png); `native-download-continuation-retry` — [600 x 800](screens/suites/native-600x800/download-continuation-retry.png). Add a delayed read/download continuation capture to assess busy feedback.

**Source:** `Screens:_purchaseDialog`, `bilicomics/ui/screens.lua:1953`, `:1957`, `:1960`, `:1967`.

## Download and recovery findings

### DL-01 — P1: Choose recovery actions from the failure, not only from the job state

**Evidence status:** Confirmed visual and source.

Content mismatch, missing image history, an unverifiable position, and an open chapter all lead to a recovery dialog that can put Refresh image sources first. The availability checks consider job state and capabilities, not the error's prerequisite. For missing history or incompatible content, retrying the same verification without a changed basis may repeat the failure; for an open chapter, the body says to close it while the prominent action attempts recovery immediately. The two recovery mechanisms require different decisions, yet their initial explanation is technical and brief.

Lead with the practical outcome: cached images and position remain preserved, and describe the unmet prerequisite. For a transient refresh interruption, offer retry after the prerequisite. For missing history, incompatible content, or an unverifiable position, explain the separate-new-version path and its tradeoffs, with retained-content reading when available. Keep source verification as an advanced retry only when useful, not as an unconditional first choice. Do not bypass verification or transfer an unverified reading position to the new version.

**Screenshots:** `version-replacement-source-error-unknown-history` — [480 x 640](screens/suites/version-replacement/480x640/source-error-unknown_history.png); `version-replacement-source-error-content-changed` — [600 x 800](screens/suites/version-replacement/600x800/source-error-content_changed.png); `download-recovery-error-chapter-active` — [600 x 800](screens/suites/download-recovery/600x800/error-chapter_active.png); `download-recovery-refresh-confirmation` — [600 x 800](screens/suites/download-recovery/600x800/refresh-confirmation.png).

**Source:** `Screens:_canRefreshSources`, `bilicomics/ui/screens.lua:1136`; `Screens:_canReplaceVersion`, `:1142`; `Screens:_downloadRecovery`, `:1156`; recovery escalation at `:1204`; `Model.error`, `bilicomics/ui/model.lua:208`, `:210`, `:212`, `:220`; prerequisites in `Controller:refreshDownloadSources`, `bilicomics/controller.lua:1521`.

### DL-02 — P1: Identify the exact chapter and version in removal/recovery confirmations

**Evidence status:** Confirmed visual and source. Misidentification risk is a hypothesis, not an observed accidental deletion.

The confirmation text says this chapter without naming the comic, chapter, or version. This applies to removal, source refresh, and replacement. The background can contain multiple rows, including two rows with identical comic/chapter names, while the modal does not repeat which row was selected. Removal preserves rights and progress, but deletes a specific offline copy; that distinction needs an identifiable target.

Repeat the comic title, chapter title, and current/retained-version label inside the confirmation. For removal, state which cached copy will be removed and what is preserved. For source refresh and replacement, separate the consequence summary into short lines: data will be downloaded, storage will be used, and the new reading position starts at the beginning. Show known image counts or actual retained bytes if available; do not invent network or free-space estimates. Preserve explicit confirmation and active-reader protection.

**Screenshots:** `review-supplement-download-remove-confirmation` — [480 x 640](screens/suites/review-supplement/zh_CN-480x640/download-remove-confirmation.png); `download-recovery-remove-during-verification` — [600 x 800](screens/suites/download-recovery/600x800/remove-during-verification.png); `version-replacement-replacement-confirmation` — [480 x 640](screens/suites/version-replacement/480x640/replacement-confirmation.png).

**Source:** `Screens:_confirmRemoveDownload`, `bilicomics/ui/screens.lua:1264`; `Screens:_confirmSourceRefresh`, `:1185`; `Screens:_confirmVersionReplacement`, `:1223`; `Controller:removeDownload`, `bilicomics/controller.lua:1603`.

### DL-03 — P2: Separate running, resumable, canceled, and removable states in the controls

**Evidence status:** Confirmed visual and source; touch-error risk requires device evaluation.

A canceled download still offers Cancel download. Paused, failed, and canceled jobs share the same Resume/Cancel/Remove/Recovery row. The active filter includes every non-complete job, including canceled and failed jobs, even though its label says In progress. The summary counts those jobs as unfinished. At 480 x 640 the four similar-weight buttons compete for a single row while the differentiating state is muted.

Define a clear action/state matrix. Running/queued jobs need Pause; paused jobs need Resume; failures need the applicable Retry/Recovery; canceled jobs should not offer Cancel again. Either rename the broad filter to unfinished downloads or split running from needs-attention states. Explain that canceling stops the task while keeping cached data, whereas removing deletes the offline copy. Make the likely next step primary and group deletion under a stable secondary action. Preserve the existing immediate pause behavior; extra confirmation for reversible pause is unnecessary.

**Screenshots:** `native-downloads` — [480 x 640](screens/suites/native-480x640/downloads.png); `download-recovery-canceled-download` — [480 x 640](screens/suites/download-recovery/480x640/canceled-download.png); `review-supplement-downloads-active-filter` — [600 x 800](screens/suites/review-supplement/zh_CN-600x800/downloads-active-filter.png); `download-recovery-verification-complete` — [480 x 640](screens/suites/download-recovery/480x640/verification-complete.png).

**Source:** `Screens:_jobRow`, `bilicomics/ui/screens.lua:1094`, `:1098`, `:1117`; `Screens:_downloads`, `:1284` and `:1294`; equal-width actions in `Screens:_buttons`, `:365`; `Controller:cancelJob`, `bilicomics/controller.lua:1496`.

### DL-04 — P2: Make retained and replacement copies recognizable as related versions

**Evidence status:** Confirmed visual and source; the proposed grouping needs usability review.

The old and new copies have identical bold comic/chapter titles. Only a muted status line distinguishes the retained version from the new queued copy. The old copy's 3/12 cached images is visible, but the Read retained version action does not directly say that only those saved images remain available. Version replacement sorts all retained copies after current copies, so related rows need not remain adjacent in a larger queue.

Use a visible current/retained badge or subtitle near the title and show their relationship. Group the retained copy under the same chapter, or provide a clear related-copy link if independent rows are required. Explain partial retained availability before opening it, with a concise count and a path back to the current copy. Keep state/progress contrast stronger than low-priority metadata. Do not imply that the old copy can fetch missing pages or that progress automatically transfers to the new copy.

**Screenshots:** `version-replacement-old-and-new-versions` — [480 x 640](screens/suites/version-replacement/480x640/old-and-new-versions.png) and [600 x 800](screens/suites/version-replacement/600x800/old-and-new-versions.png); `version-replacement-new-version-queue` — [600 x 800](screens/suites/version-replacement/600x800/new-version-queue.png).

**Source:** `Screens:_jobRow`, `bilicomics/ui/screens.lua:1067` and `:1117`; sorting in `Screens:_downloads`, `:1299`; retained-page restriction in `Model.error`, `bilicomics/ui/model.lua:202`, and `Controller:_requestReaderPage`, `bilicomics/controller.lua:1849`.

### DL-05 — P2: Give the download empty state a relevant explanation and action

**Evidence status:** Confirmed visual and source.

An empty download list uses the shared message about refreshing the bookshelf or searching for a comic, while the page's refresh button only repaints local download state. It also displays disabled previous/next controls and 1/1. The same fallback can appear when a selected filter yields no jobs, so the user cannot tell whether there are no downloads or simply none in this category.

Use separate empty states for no saved downloads, no running tasks, and no offline-ready chapters. Offer one relevant action: open the bookshelf/search to choose a chapter, or switch to all downloads when only the current filter is empty. Remove pagination when there is nothing to paginate. Explain how a chapter becomes an offline download without implying that refreshing this screen starts synchronization. The synthetic empty-list fixture's retained-byte total is not treated as a storage-accounting defect.

**Screenshots:** `review-supplement-downloads-empty` — [600 x 800](screens/suites/review-supplement/zh_CN-600x800/downloads-empty.png) and [480 x 640](screens/suites/review-supplement/zh_CN-480x640/downloads-empty.png); `download-recovery-removed-download` — [600 x 800](screens/suites/download-recovery/600x800/removed-download.png).

**Source:** `Screens:_downloads`, `bilicomics/ui/screens.lua:1310` and `:1315`; shared empty copy and unconditional pagination in `Screens:_paginate`, `:387` and `:393`.

## Strengths and constraints to preserve

- The confirmed quote and confirmation action repeat the payable amount and asset. Insufficient balance removes the purchase confirmation and offers a balance refresh. Preserve this boundary while improving hierarchy. Evidence: `native-purchase` and `quote-selection-insufficient-balance`; `Screens:_purchaseDialog`, `bilicomics/ui/screens.lua:2038` and `:2048`.
- Unverified candidates cannot be submitted. Reference amounts and detailed blockers are separated from a confirmed payable quote. Preserve that distinction; reducing copy must not hide uncertainty. Evidence: `quote-selection-single-candidate`; `Screens:_candidateDetails`, `bilicomics/ui/screens.lua:1792`, and candidate branch at `:1994`.
- The purchase service refreshes and compares terms immediately before submission, persists intent, and prevents duplicate or conflicting range submissions. A balance change is not treated as a purchase receipt. Source: `Controller:purchase`, `bilicomics/controller.lua:1774`; `Service:prepareSubmission`, `bilicomics/purchase/service.lua:164`; `Service:completeReconciliation`, `:345`.
- Submission and result-checking actions are visibly disabled while in flight. Unknown results explain that the purchase will not be resent. Rejected intents request a new quote; they do not silently retry a charge. Evidence: `review-supplement-purchase-submitting`, `review-supplement-purchase-checking-result`, and `review-supplement-purchase-rejected`; `Screens:_purchaseDialog`, `bilicomics/ui/screens.lua:1955`, `:1975`, `:1981`.
- Purchase confirmation and chapter-access confirmation have different evidence rules. A range may permit reading while remaining unresolved for purchasing. Preserve this distinction in headings, summaries, and navigation. Source: `Screens:_purchaseDialog`, `bilicomics/ui/screens.lua:1946`.
- Read/download purpose is retained in the intent. Confirmed access is preserved across content-operation failures, and retry does not request a new purchase. Evidence: `native-download-continuation-retry`; `Screens:_purchaseFor`, `bilicomics/ui/screens.lua:1686`, and continuation at `:1963`.
- Source verification, new-version preparation, and ordinary image download have different visible stages and cancellation labels. Verification can show checked-image counts. Preserve these explicit stages while raising their visual prominence. Evidence: `download-recovery-verifying-history` — [480 x 640](screens/suites/download-recovery/480x640/verifying-history.png); `version-replacement-preparing-new-version` — [600 x 800](screens/suites/version-replacement/600x800/preparing-new-version.png); `Screens:_jobRow`, `bilicomics/ui/screens.lua:1075`.
- Removal is confirmed, active reader content is protected, and recovery retains existing cache/position until its checks succeed. New versions preserve an independently readable/removable old copy. Do not trade these guarantees for fewer dialog steps. Source: `Screens:_confirmRemoveDownload`, `bilicomics/ui/screens.lua:1264`; `Controller:removeDownload`, `bilicomics/controller.lua:1603`; `Screens:_confirmVersionReplacement`, `bilicomics/ui/screens.lua:1223`.

## Review gaps to keep explicit

The current screenshot set does not demonstrate an existing intent returned together with a reconciliation error, confirmation-time quote expiration/change, or a delayed confirmed-access continuation. Those require additional remote synthetic captures before assessing the revised layout. The effect of similar-weight actions, muted state text, and two-choice pagination on actual mistakes and completion time remains a usability hypothesis. Physical E-ink contrast, refresh behavior, touch accuracy, live availability of option metadata, and common production option counts were not assessed here.
