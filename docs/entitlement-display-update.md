# Entitlement display update

This update adds two display-only changes. It does not change access authorization, quote selection, price acceptance, coupon selection or purchase submission. The actual localization resource is `l10n/bilicomics_zh_CN.lua`; this repository does not use `l10n/zh_CN.po`.

## Reading-only expiry display

`Model.entitlementExpiry(episode)` formats only `access="temporary"` records and reads only the normalized `episode.expires_at` field. Existing protocol and authorization code treats this field as Unix seconds. Positive integral numeric values are displayed as a complete `YYYY-MM-DD HH:MM:SS` instant explicitly labeled UTC. UTC is the presentation reference, not an inferred server or device timezone. The UI does not parse raw date strings, inspect `extra` for a guessed date, divide presumed milliseconds, or infer a duration.

Missing, zero, nonnumeric, nonfinite, fractional or unsupported timestamps display a fixed unknown-expiry label. The formatter checks the UTC calendar result against the original Unix second count to reject platform time-range wrapping. A past instant is displayed as recorded; this helper does not change the access state or decide whether reading is authorized. Free and owned records do not receive an expiry line.

`Screens:_chapterRow` preserves the three independent short status columns and adds a full-width expiry line for temporary access. `Screens:_comic` uses the same `row_height` for pagination and current-chapter positioning: 105 when the catalog contains temporary access, otherwise the existing 79. The complete time is not squeezed into the narrow entitlement column. The separate reading-only native display check covers both 600x800 and 480x640 layouts.

The reading package can migrate these exact units without importing payment-preview code:

- Insert the complete `Model.entitlementExpiry` function after `Model.entitlement` and before `Model.storage`; its nested helpers are contained in that function.
- Replace the complete shared `Screens:_chapterRow` and `Screens:_comic` functions.
- Add only `Temporary access expiry is unknown.` and `Temporary access expires: %s (UTC)` to the existing localization table.

## Coupon identifiers in confirmation details

`Model.couponIdentifiers(quote)` reads only an existing noncandidate quote's `payment.coupon_ids`. It preserves complete ID strings, including leading zeros and order, and does not manufacture coupon names, expiration dates or other attributes. Malformed or absent identifiers are reported as unavailable rather than replaced with invented values.

The existing confirmation-details TextViewer passes the displayed quote snapshot to `Screens:_purchaseSelectionText`, which lists each ID below an identification-only label. The compact payment selector and unverified candidate view keep their existing count-only summary; a potentially long ID list is not added to a fixed-height selection dialog. This change introduces no manual coupon selector and does not adopt a changed price or affect any submission gate.

Coupon-only units are `Model.couponIdentifiers`, the optional snapshot parameter in `Screens:_purchaseSelectionText`, its existing confirmation-details call site, and the localization keys `Coupon IDs (identification only):` and `Coupon identifiers are unavailable in this quote.` They belong only in the payment-preview package.

## Verification boundary

The coupon change has static implementation/review evidence only. No coupon helper, quote, confirmation, wallet or purchase scenario is executed by this task. The parent task owns any remote LuaJIT bytecode syntax compilation.

The separately authorized expiry check passed 132 assertions at each of 600x800 and 480x640 on the unchanged official KOReader v2026.07.1 runtime through `ssh test-env`. It uses only `Model.entitlementExpiry`, the existing short access labels and native chapter display with synthetic temporary/free/owned records. Cases include exact UTC instants, leap dates, past times, unknown/invalid input, formatter failure and range wrapping, full-width text, pagination/current-chapter positioning and unchanged ordinary access labels. Business services remain unloaded. No local WSL profile or account session is used.

[The verification record](../spec/ui/entitlement-display-verification.json) contains `passed=true`, `source_unchanged=true`, `purchase_tests_executed=false`, and the three source-file SHA-256 values. [Base-size results](../spec/ui/entitlement-display-result.json) and [narrow-size results](../spec/ui/entitlement-display-result-480.json) provide individual checks. Native screenshots are retained under `spec/ui/screens/entitlement-display/`. The recorded remote output is `/tmp/bilicomics-entitlement-display/run-1/`; `spec/ui/run_entitlement_display.py` runs the focused spec with isolated data directories. These display results do not establish coupon behavior, current server entitlement validity or physical Scribe acceptance.
