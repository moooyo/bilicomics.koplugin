# Scribe design fidelity audit

The follow-up audit found that the initial implementation was not a complete
visual restoration. Its passing interaction suite did not establish fidelity.
This audit read the supplied HTML and README, measured actual painted KOReader
widgets at 1860x2480, and reviewed native framebuffer screenshots before and
after correction. It did not execute the reference HTML in a browser: the
browser's local-file URL policy rejected that action, and no workaround was used.

## Corrected differences

| Surface | Before | Corrected behavior |
| --- | --- | --- |
| Header | Return action text was inset too far | Handoff side padding and 54 dp action targets |
| Bookshelf | Glyph extents increased the hero height | Cover at x=56, y=150, size=216x288 dp; actions end at the cover baseline; grid starts at y=555 dp |
| Bookstore | Third-row metadata was covered by navigation | Fixed single-line metrics; 240 dp cover slots; all 12 titles and metadata remain visible |
| Search input | Default native dialog geometry | 818 dp outer width, y=160 dp, 24 dp title, 70 dp input, 64 dp actions, native keyboard |
| Chapter jump | Separate input and results dialogs; tapping jumped immediately | One native input dialog; results select a target; a separate primary Locate action confirms the jump |
| Purchase | Summary cover at y=172 dp; amount unit used 48 dp | Cover at y=144 dp; amount uses 48 dp and unit 20 dp; total box about 105 dp high |
| Purchase result | Five key-value rows displaced the approved layout | Three 66 dp rows and an 88x88 dp confirmation mark; record and transaction evidence remain in details |
| Downloads | Task rows about 191.5 dp; primary controls 190 dp wide; mixed states required two pages | Rows about 131.5 dp; regular controls 150x58 dp; left progress bars 644 dp; mixed fixture fits one page |
| Account | Eight settings rows needed two pages | Scribe shows all eight rows on one page; balance, unit, and update time share a baseline |
| Storage | Usage and device free space on separate lines; missing rules | Shared baseline, section rules, and legend dividers |
| Reader defaults | Labels above the diagrams and centered | Diagrams above left-aligned labels and descriptions; section hints share their heading row |
| Recharge | Coin count and unit on separate lines; key-value baselines misaligned | Shared baselines; amount-entry rules; vertically centered values and right-aligned receipt values |
| Reader overlays | Separate progress count; missing row chevrons; next-chapter price below the text | Inline progress and count, top rule and chevrons, price at right, approved padding and action spacing |

`W.line` now uses a native TextWidget inside a fixed layout box. Unlike a fixed
height TextBoxWidget, it does not add fallback-glyph extents to the allocated
layout height. This fixes the underlying cause of several density deviations.

## Verification

The final native matrix passed 4,228 assertions and generated 528 screenshots:
Chinese and English at 1860x2480, 480x640, 600x800, and 960x720. It includes
design-coordinate assertions, the Search native keyboard, and the complete
chapter-jump selection/confirmation flow. Sources were unchanged during the run.
See [the current matrix receipt](../spec/ui/scribe-handoff-verification.json).

Additional affected checks passed: shared widgets and reader overlays (29),
account and recharge (1,548 across eight cases), forced recharge pagination (19),
quote selection (116 at each of 600x800 and 480x640), download recovery (393 at
each of Scribe, 600x800, and 480x640), and version replacement (400 per size).
These retain transaction, source revision, stale callback, and account guards.

## Remaining intentional differences and limits

- Native bundled Noto fonts and FreeType rasterization approximate the HTML's
  Noto Sans SC; this is not a browser-to-framebuffer pixel-equality claim.
- Fictional comic names, covers, prices, balances, timestamps, QR patterns, and
  record counts are supplied by the real services or synthetic test records.
  They are not copied into production as fixed mock values.
- The bookstore HTML specifies roughly 186x240 dp slots while another rule asks
  for a 3:4 cover. The slot follows the HTML and the native image keeps its 3:4
  aspect ratio, without stretching.
- The HTML omits action bars on storage/default settings, while the README's
  global rules require them. The implementation follows the global flow rule.
- The controller does not expose first-sync cover counters or reliable selected
  download-byte estimates. The UI gives an honest loading/count description
  instead of inventing a percentage or size.
- Actual charged amounts are not inferred from a quote or wallet change.
  Unreceipted amounts are labeled confirmed quotes; entitlement-only success
  does not claim payment. Detailed evidence remains reachable.

The core page structure and the measured dimensions are now close to the
approved handoff. Unsupported data fields and the above reference conflicts
prevent an honest claim of unconditional 100% pixel restoration. Physical
e-ink rendering and real payment outcomes were not exercised.
