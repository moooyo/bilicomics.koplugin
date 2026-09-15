# Native recharge preview

This offline gallery displays screenshots captured by `spec/recharge/ui_spec.lua` in the remote KOReader test environment. All configuration, account, amount, coin, order, and settlement data is synthetic. Example QR codes cannot be used to pay. No real recharge order, payment, or live settlement was validated by these screenshots.

## Files and capture layout

Keep these files together:

- `index.html`, `styles.css`, and `app.js`: the browser interface, with no external CDN or library dependency.
- `zh-CN.js`: all Chinese interface copy and the known scene titles and notes.
- `manifest.js`: capture inventory, loaded as JavaScript to support direct `file://` browsing.
- `screens/600x800/<scene>.png` and `screens/480x640/<scene>.png`: original native PNG captures.

Scene identifiers must match screenshot filenames without the `.png` extension. The locale catalog contains the six main-flow scenes followed by known additional states. The browser merges that catalog with the generated capture inventory, so new filenames are included even before a translated title is added. Unknown scenes retain their exact ASCII filename and receive an explicit generic Chinese label. No screenshot is substituted for another scene or size.

## Build the capture inventory on test-env

After copying the remote captures into the two size directories, run the following on `test-env`:

```sh
python3 design/recharge-preview/build_manifest.py \
  --screens /path/to/recharge-preview/screens \
  --output /path/to/recharge-preview/manifest.js
```

The inventory helper uses only the Python standard library. It indexes filenames and dimensions-directory membership; it does not create images, call payment services, or execute the plugin. The generated inventory contains 30 states and 60 native captures. Expected but missing captures remain visible as explicit missing-image states.

Open `index.html` directly in a modern browser, or serve the folder with a static server. The complete folder is portable and has no required files outside it.

## Review controls

The payment-code view places Check credit on the left and Close on the right in a single action row. Close receives initial focus. Recharge creation and saved-order navigation remain available from Account and the recharge-order list. Completed orders offer Close.

Use the thumbnail navigation or search to select a scene. Choose 600 by 800 or 480 by 640 to inspect the corresponding native capture. The arrow buttons and keyboard left/right keys move through matching scenes. Open Original displays the unchanged PNG, while Zoom provides a fitted view and original-pixel mode. Escape closes the large-image viewer.

Missing files and unexpected image dimensions produce a visible error; the interface does not retain the previous scene or fall back to another file. Loading failures in thumbnail images are also labeled explicitly. The gallery does not send payment requests, poll orders, save account data, or maintain review notes.

## Verification boundary

All executable verification ran through `ssh test-env`. The native UI suite passed 190 assertions per size, including minimum QR image dimensions, four-module white quiet zones, account changes, stale callbacks, and unresolved orders. The offline gallery passed 60 image checks, desktop/mobile layout, zoom controls, and an actual missing-image check; no network request was made. Reports are saved in `evidence/`. No local tests or runtime probes were run. Passing synthetic checks does not establish that a live payment succeeds or that a particular amount is offered by the real service.
