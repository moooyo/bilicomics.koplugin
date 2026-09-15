# Native UI review gallery

This directory contains the offline gallery builder and browser interface for reviewing the current BiliComics KOReader plugin. Screenshots come from real KOReader framebuffer rendering with synthetic account, comic, purchase, and image fixtures. They are evidence of the captured UI state, not a new design prototype or evidence of live service behavior. English comic titles can appear inside a Chinese interface because fixture content is synthetic.

The follow-up [comprehensive UI/UX review](deep-review.md) consolidates all 203 representative scenes and source inspection into 24 improvement workstreams. Its linked navigation, transaction, account/reader, and visual-system reports contain detailed evidence and confidence limits. The [initial review](initial-review.md) remains the record of the earlier 30-image sample.

## Build on the remote test environment

The builder requires Python 3.10 or later, Pillow, and a CJK font for Chinese contact sheets. Run generation and verification through `ssh test-env`; local verification is not authorized for this task. The output directory must be outside the captures directory.

```sh
python3 design/ui-review/build_gallery.py --captures /path/to/captures --output /path/to/gallery --font /path/to/NotoSansCJKsc-Regular.otf
```

The font can also be selected through `UI_REVIEW_FONT`. If neither option is supplied, the builder checks common installed Noto, WenQuanYi, and Windows CJK font paths. It reports a missing font instead of generating unreadable Chinese labels.

The builder reads `review-capture-manifest.json` and `capture-summary.json` when available, then scans PNG files so additional supplement and reader captures are included. Fixture, profile, and home directories are excluded. Supported layouts include `suites/native-600x800/name.png` and `suites/bookshelf-finishing/zh_CN-600x800/name.png`. Locale directory names take precedence over metadata: `C` means English and `zh_CN` means Simplified Chinese. Runners with a known Chinese default are handled when metadata is absent.

The generated output contains:

- `index.html`, `styles.css`, and `app.js`: an offline interface without CDN dependencies.
- `data.js`: the manifest as a JavaScript assignment, allowing direct `file://` use without fetching JSON.
- `manifest.json`: scene groups, stable ASCII identifiers, variants, provenance, and contact sheet records.
- `screens/`: all original screenshot PNG files with their source directory structure preserved.
- `overview.png`: the six main plugin pages and the reader page when captured.
- `group-*.png`: contact sheets, each containing at most 20 scenes.
- Capture metadata files when supplied by the capture runner.

Open the generated `index.html` in a modern browser, or serve the generated directory through a static server. No application server, external service, account access, or network connection is needed to browse the gallery.

## Review workflow

The initial view shows the main flow in Simplified Chinese at 600 by 800 pixels. Page groups, view filters, language, dimensions, keywords, and review marks narrow the gallery. Missing capture variants are omitted rather than relabeled or synthesized. Choosing a page group switches to all its captured scenes.

Open any screenshot to inspect it at fitted size or original pixels. The left and right arrow keys move through the current filtered set. Escape closes the viewer. The original image link opens the unmodified PNG. A screenshot-specific hash in the URL can be shared with the same generated gallery.

Review marks and notes are attached to a stable scene identifier, locale, and resolution. They persist in the current browser's `localStorage`. The export action downloads a JSON document with identifiers, source paths, status, notes, and timestamps. If browser storage is unavailable, records remain in memory and the interface asks the reviewer to export them before closing. Exported records can be used as review input; this interface does not modify plugin files or send notes anywhere.

## Manifest format

Each `screens` record has `id`, `number`, `title`, `filename`, `suite`, `group`, `kind`, and `variants`. A variant records `locale`, `resolution`, `width`, `height`, `src`, `capturePath`, and `sha256`. `src` is relative to the generated gallery. Scene identifiers are stable across resolution and locale variants. If a duplicate scene, language, and size occurs at another source path, a path hash distinguishes it and preserves both originals.

Contact sheets use Chinese headings, captions, and language labels. Each screenshot has its scene number and Chinese title followed by the stable ASCII identifier. Captions are truncated by measured text width when necessary; the browser retains the full title and identifier. Contact sheets select Chinese 600 by 800 captures first, then explicitly label any available fallback.

## Verification status

The 2026-09-14 review contains 203 scenes, 616 original screenshots, and 14 contact sheets. Every scene has Chinese 600 by 800 and 480 by 640 captures. Bookshelf and Bookstore also include English, 720 by 960, and 960 by 720 variants. All captures use the current production source at base commit `91a7405f2d83957b59bcc4b30280dc5531a3f392`; production files were not changed for this review.

All 15 capture tasks completed successfully on `test-env` using KOReader v2026.07.1. Five older strict synthetic controllers needed a no-op `cancelPendingRead` method, and the expanded Bookstore fixture needed current feed identity and heading expectations. The capture manifest preserves the earlier attempts and selects the latest successful evidence. Supplementary captures add search, input, loading, empty and error states, startup messages, purchase transitions, and native reader overlays.

Remote Chromium review verified the seven-page overview, all 203 Chinese scenes at both small sizes, search, original-pixel viewing, review marks, persisted notes, JSON export, and a 390-pixel browser viewport without horizontal overflow or JavaScript errors. See `gallery-verification.json`. Contact sheets were also visually inspected after the final Chinese caption rendering. No local tests, builds, browser probes, or runtime verification were performed.

This evidence covers a Linux emulator with synthetic records and original fixture art. It does not establish real service, payment, or physical e-ink behavior. The initial visual findings in `initial-review.md` separate direct observations from design discussion items.

## Regenerate native captures

Upload the current plugin source and `spec/ui` scripts to an isolated directory on `test-env`, then run the capture orchestrator there. Use a fresh output path; `--tasks` can select only failed or changed capture tasks for a subsequent run.

```powershell
ssh test-env 'python3 /path/to/source/spec/ui/run_review_capture.py /path/to/koreader /path/to/source /path/to/new-captures --pillow /path/to/python-deps'
```

The runner uses separate profiles and isolated network namespaces. Its default matrix includes the supplemental and reader capture scripts. Gallery generation is a separate step, using the builder and Chinese font option described above.
