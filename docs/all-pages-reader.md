# Reader handoff audit

The reader audit covers every J1-J5 artboard in the supplied Scribe README and
HTML, plus every existing image-error destination. It uses the official native
KOReader runtime with original synthetic pages, isolated profiles and a network
namespace without external routes. The comic image and footer remain native
ReaderUI components, as the handoff requires. No account, image acquisition,
purchase submission or recharge creation is involved.

## Per-artboard evidence

All measurements use the handoff's 930x1240 design coordinates. On Scribe,
one design pixel equals two device pixels. Geometry assertions inspect painted
widget rectangles, not only declared constants. Font size tolerance is two
device pixels because KOReader's face scaling rounds independently.

| Artboard | Native screenshot | Verified requirements and correction |
| --- | --- | --- |
| J1 Comic actions | `J1-comic-actions.png` | Full-width bottom sheet; 56 dp side margins; five 72 dp rows including their divider; inline 8 dp progress bar and real page count; cached-image and running-task counts; native settings entry; 68 dp return action. Corrected single-line geometry, row stride and top-border allocation. |
| J2 Next chapter readable | `J2-next-readable.png` | 30 dp heading; actual completed chapter identity; 25 dp next-chapter title; entitlement, online status and actual preload state; 68 dp primary action; three 64 dp secondary actions; 34/56/38 dp padding. Primary reads and releases the transition; returning to the shelf closes ReaderUI before navigation. |
| J3 Next chapter locked | `J3-next-purchase.png` | Same bottom-sheet structure; 18 dp bordered price at the right of the next-chapter title; explicit quote action; 16 dp no-automatic-purchase notice. Rendering never submits or reads; the action opens the quote only. |
| J4 Image loading | `J4-image-loading.png`, `J4-bounded-placeholder.png`, `J4-cropped-placeholder.png` | Static 28 dp heading with actual 9/24 count; 18 dp detail with 12 dp gap; 1 dp grayscale frame inside the native page region. Corrected detail size and spacing. Pixel checks prove the entire external guard ring is untouched, including cropped tiles. Full-page unavailable rendering still returns nil. |
| J5 Connection failed | `J5-connection-failed.png`, `J5-unavailable-page.png` | 700 dp dialog at left 115/top 320; 2 dp border; 38/40/36 dp padding; 28 dp heading; 17 dp page/chapter metadata after 6 dp; 20 dp body after 16 dp; 28 dp gap before 66 dp actions; 12 dp action gaps. Replaced the generic menu layout. The failed-page background has a muted 17 dp notice 40 dp from the top of the unavailable region. |

J2 also has explicit native captures for the final chapter, uncached offline
chapter, cached offline chapter and an online-only temporary entitlement.
An offline chapter is offered as readable only when its entitlement permits
offline reading and an actual local image file exists. Partial cache copy says
only cached images are available; offline state never claims live preloading.

## Every additional reader error

The same J5 frame, type scale, gaps and bounded native actions are checked for
each error below. Primary and secondary destinations are invoked and counted
independently; the return action preserves the native page and reader.

| Error state | Native screenshot | Primary destination | Secondary destination |
| --- | --- | --- | --- |
| Sign-in required | `J5-error-auth.png` | Account | Return to reading |
| Low free space | `J5-error-low-space.png` | Close chapter, then storage | Close chapter, then downloads |
| Storage operation failed | `J5-error-storage.png` | Retry image | Close chapter, then downloads |
| Image decode failure | `J5-error-image-decode.png` | Close chapter, then downloads | Return to reading |
| Oversized image | `J5-error-unsupported-image-size.png` | Chapter catalog | Return to reading |
| Changed chapter content | `J5-error-content-changed.png` | Chapter catalog | Close chapter, then downloads |
| Retained older version | `J5-error-version-replaced.png` | Chapter catalog | Close chapter, then downloads |
| Unavailable image source | `J5-error-source-unavailable.png` | Close chapter, then downloads | Return to reading |

Navigation and recovery callbacks reject a stale account. Image-error callbacks and direct reader
events reject a stale reader generation. Every reader overlay records its owner
generation; actual external native reader closure removes only those overlays.
A delayed close from an older reader leaves newer overlays open. A chapter
dialog's dismissal closes its own identity and finishes its own transition.

Chapter captions use the separately stored chapter number and title, without
duplicating a localized chapter label already in the title. This restores the Scribe chapter
identity even when the service returns only a bare title.

## Reproduction and evidence

Run `spec/ui/run_all_pages_reader.py` with the authorized native runtime,
plugin directory and a fresh output directory outside the repository. Its
default matrix is Chinese and English at 1860x2480, 480x640, 600x800 and 960x720.
Each case writes an actual framebuffer screenshot and a structured report with
painted dimensions, assertions and callback results. The runner binds the
receipt to source hashes before and after the complete matrix.

The final matrix passed 1,640 assertions and produced 168 native screenshots
across eight cases, with identical source hashes before and after verification.
The current receipt is [all-pages-reader-verification.json](../spec/ui/all-pages-reader-verification.json); the native
case reports and screenshots are retained outside the repository in the
authorized acceptance workspace. The audit compares the supplied HTML's
structure, measurements and copy with native rendering. It does not claim
browser/framebuffer pixel equality or physical e-ink verification. Native
reader page geometry, footer settings, bundled font rasterization and actual
service values are intentional contextual differences specified by the handoff.
