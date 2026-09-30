# Account, sign-in, and recharge handoff audit

## Reference and acceptance method

The G1-G4, H1-H3, and I1-I4 artboards in
`D:\Code\design_handoff_bilicomics_scribe\BiliComics 设计稿.dc.html` and the
corresponding README sections were read together. The HTML was treated as a
design reference, not as application source. No HTML, CSS, browser font, striped
image placeholder, or fictional exchange rate was shipped.

Verification uses the official KOReader v2026.07.1 runtime in the user-authorized
local WSL Debian environment. Every case has a private KOReader profile and a
network namespace with no external route. Controllers, sessions, orders, and QR
URLs are synthetic. The native Lua widgets paint the actual framebuffer; the
screenshots do not come from an HTML approximation. Production transport,
session, purchase, and recharge modules are forbidden in the focused native
suite.

The audit includes every native page of each paginated state. Its assertions
check the framebuffer, full-page header/action-bar geometry, button and custom
tap-target bounds, official amounts, order creation counts, neutral paid focus,
expiry timers, late callbacks, and the open receipt's asynchronous wallet update.
Screenshots and layout checks serve different purposes: a passing state does not
imply pixel equality with a browser font renderer.

## Page-by-page evidence

Screenshot names below are relative to each case output directory. Every name
with `page-1` has further numbered screenshots when that case requires them.

| Artboard | Native evidence | What was checked or fixed |
| --- | --- | --- |
| G1 | `G1-account-signed-in-page-1.png` | Account identity, sign-in tag, balance hierarchy, 14 dp action gaps, grouped settings, inactive four-tab navigation. Long balance freshness warnings now wrap instead of losing their meaning in an ellipsis. |
| G1 variants | `account-checking-page-1.png`, `account-refreshing-page-1.png`, `account-pending_confirmation-page-1.png`, `account-reauth_required-page-1.png`, `account-error-page-1.png`, `account-imported-stale-balance-page-1.png` | Maintenance disables balance refresh, renewal and reauthentication copy remain visible, and imported/stale-account content fits the native page. |
| G2 | `G2-account-signed-out-page-1.png`, `account-expired-offline-page-1.png` | QR remains the primary entry, imports remain available, and the purchase/recharge group is absent while signed out. |
| G3 | `G3-storage-page-1.png`, `storage-reduction-canceled-page-1.png`, `storage-reduction-applied-page-1.png`, `storage-increase-applied-page-1.png` | Real usage values, manual/automatic/free legend, segmented choices, explicit reduction confirmation, immediate increase, and retention of the current native page after a setting change. Presets use exact SI byte values through the existing `cache_limit_bytes` setting. A legacy 256 MiB limit remains 268.4 MB and is not silently lowered or falsely shown as the 256 MB preset. |
| G3 cleanup | `storage-cleanup-confirmation.png`, `storage-cleanup-result-page-1.png`, `storage-cleanup-no-op.png`, `storage-cleanup-protected.png`, `storage-cleanup-error.png` | Confirmation, freed bytes, no-op result, protected content, and writable-storage failure. Manual downloads are preserved. |
| G4 | `G4-reader-defaults-auto-page-1.png`, `G4-reader-defaults-page-page-1.png`, `G4-reader-defaults-strip-page-1.png`, `reader-defaults-rtl-page-1.png`, `reader-defaults-no-preload-page-1.png`, `reader-defaults-five-preload-page-1.png` | Three 204 dp mode cards, native rectangle diagrams, exact saved enums, direction/preload/concurrency choices. English card descriptions now wrap into the available two-line region; the diagram region adapts without enlarging the card. |
| G imports | `account-other-sign-in.png`, `account-session-paste-input.png`, `account-native-session-file-picker.png`, `account-session-file-too-large.png`, `account-session-file-regular_file.png`, `account-session-file-format.png`, `account-session-file-read.png` | Existing masked InputDialog and native FileChooser are retained; plugin feedback uses square native primitive frames. |
| G import states | `account-session-validating.png`, `account-session-background-validation-page-1.png`, `account-session-background-notice.png`, `account-session-background-result-page-1.png`, `account-session-import-success.png`, `account-session-import-auth-error.png`, `account-session-import-network-error.png` | Foreground/background validation, explicit result review, retry paths, and obsolete-generation rejection. The transient completion notice no longer introduces a rounded frame or info icon. |
| G diagnostics | `diagnostics-loading.png`, `diagnostics-result-page-1.png`, `diagnostics-error.png` | Static loading, locally available/unavailable/unchecked capability rows, paginated results, storage failure, and rejection of a callback after the view closes. |
| H1 | `H1-qr-waiting.png`, `qr-loading.png` | Three steps, a native QRWidget inside the 480 dp frame, explicit validity text, and the two secondary footer actions. On Scribe the frame is measured at x=225 dp, y=269 dp, width=height=480 dp. |
| H2 | `H2-qr-scanned.png` | Steps 1-2 show checks, step 3 is outlined and bold, the confirmation card has the prescribed insets/padding, and only Cancel remains in the footer. Same-flow status updates use the normal UI refresh. |
| H3 | `H3-qr-expired.png`, `qr-local-expiry.png`, `qr-inflight-local-expiry.png`, `qr-network-error.png` | Server expiry, local expiry, expiry during a slow outstanding request, request error, and explicit retrieval of a new code. Expiry invalidates the old callback sequence; terminal error/expired states stop timers. |
| H completion | `qr-confirmed-returns-bookshelf.png` | Sign-in returns to its source route and starts the existing bookshelf sync. An unchanged QR poll preserves the current surface. Cancel ignores a late confirmation. |
| I1 | `I1-recharge-options-page-1.png`, `recharge-options-page-two-page-1.png`, `recharge-config-loading.png`, `recharge-config-error-page-1.png` | Official tiers only, three columns of 150 dp tiles, the original account-row/header spacing, 34/16 dp section/grid gaps, local fetched time, payment safety notes, and a plain left-aligned amount summary outside the focus order. |
| I1 input | `recharge-native-amount-input.png`, `recharge-input-validation-error.png` | Native numeric input and rejection of an unlisted amount before confirmation. |
| I2 | `I2-recharge-review-page-1.png`, `recharge-creating-request-page-1.png` | Exact official amount/coin data, readable key/value columns, explicit creation, neutral initial focus, and one synthetic request despite a repeated callback. English labels no longer collide with values. |
| I3 | `I3-recharge-code-no-expiry-page-1.png`, `recharge-code-server-expiry-page-1.png`, `recharge-checking-page-1.png` | Native QRWidget in a measured 460 dp frame, the complete official URL, amount/order/account data, accurate expiry text, and Check credit on the left with Close on the right. |
| I3 variants | `recharge-network-check-error-page-1.png`, `recharge-unknown-page-1.png`, `recharge-unknown-valid-code-page-1.png`, `recharge-unverified-code-page-1.png`, `recharge-code-too-long-page-1.png`, `recharge-expired-page-1.png`, `recharge-failed_not_submitted-page-1.png`, `recharge-creating-page-1.png`, `recharge-unsaved-page-1.png` | Network uncertainty, validated/unvalidated codes, an unrenderable long URL, expiry, known non-submission, creation still in progress, and an unsaved result. None automatically creates a replacement order. |
| I4 | `recharge-credited-wallet-refreshing-page-1.png`, `I4-recharge-credited-page-1.png` | Receipt evidence is separate from wallet freshness. The still-open receipt updates when the wallet arrives later, without another order request; it retains the current page and close focus. |
| I history | `recharge-history-empty-page-1.png`, `recharge-history-page-one-page-1.png`, `recharge-history-page-two-page-1.png`, `recharge-history-unsaved-page-1.png`, `recharge-new-order-notice-page-1.png`, `recharge-creation-unknown-page-1.png`, `recharge-definitive-not-submitted-page-1.png` | Empty and multi-page history, explicit separate-order notice, creation/unsaved blocks on New recharge, unknown creation with no resend, and definitive non-submission. |

`account-setting-key-focus.png`, `reader-mode-key-focus.png`, and
`recharge-tier-key-focus.png` add actual focus-state screenshots and framebuffer
pixel assertions for the 2 dp inner outline. The selected recharge tile retains
a visible gap around that outline. The suite also revisits earlier flow pages:
recharge pagination now retains the owner identity and native text resources
instead of closing a surface whose body is about to be reused.

## Focused native runner

```text
python3 spec/ui/run_all_pages_ghi.py \
  /home/moooyo/.local/share/bilicomics-acceptance/runtime-v2026.07.1/lib/koreader \
  /mnt/c/Users/moooyo/.codex/worktrees/0171/bilicomics.koplugin \
  /home/moooyo/.local/share/bilicomics-acceptance/all-pages-ghi-accepted \
  --sizes 1860x2480 480x640 600x800 960x720 --languages zh_CN C
```

The runner emits source hashes, namespace/runtime evidence, per-state assertions,
scenario completion status, measured geometry, and the PNG manifest. Outputs
remain outside the repository. Use a fresh output directory for each run.

The final frozen-source audit passed all 6,236 assertions and produced
760 native screenshots across all eight language/size cases. The aggregate
report records `passed=true`, `source_unchanged=true`, and
`all_required_sizes_covered=true`. The current receipt is
[all-pages-ghi-verification.json](../spec/ui/all-pages-ghi-verification.json),
identifying the external `all-pages-final-ghi` reports and captures. The
[complete-page coverage receipt](../spec/ui/all-pages-acceptance.json) verifies
the current hashes and every required G/H/I page at all eight combinations.
Each case's result contains its individual screenshots, completed scenarios,
native measurements, and assertion evidence. A later application-source change
requires a fresh run before those hashes can be treated as final evidence.

## Reference conflicts and limits

The G3/G4 HTML artboards omit a footer, while the README's explicit global screen
stack says storage and reader-default settings use a 108 dp bottom action bar.
The implementation follows that global instruction and keeps the native Close
bar. This is a recorded reference conflict, not a hidden claim of pixel equality.

KOReader's bundled Noto/CJK fallback renders the text and generates the real QR
matrix; browser glyph metrics and the striped prototype QR image are not copied.
Data such as balances, storage size, exchange rates, account identities, order
IDs, timestamps, and supported amounts comes from existing models/services.
The native file chooser and keyboard keep their existing KOReader presentation.
Synthetic state coverage does not prove a live service login, payment, or
credited transaction.
