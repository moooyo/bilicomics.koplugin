# Chapter Reading Defaults

BiliComics applies account settings `reading_mode` (`auto`, `page`, `strip`) and
`reading_direction` (`ltr`, `rtl`) only when a chapter has no previous reading
state. `page` fits the page and uses paginated view. `strip` fits page width and
uses continuous view. `auto` selects strip when the first page's height/width is
at least 2.5; otherwise it selects page. The built-in defaults remain `auto` and
`ltr`.

Precedence is evaluated by setting:

1. Native per-document zoom, scroll, reading order and page traversal settings
   take precedence, including an explicitly saved false or zero value. These
   values are preserved even if the BiliComics initialization marker is absent.
2. A valid stored chapter anchor supplies mode and zoom values missing from an
   older document's native settings. Its source position is restored after mode
   setup. A free-zoom anchor restores its scale only when the document has not
   explicitly selected a different zoom mode.
3. BiliComics account defaults apply only to a new chapter. An initialization
   marker, native reading progress, an existing document, or a valid anchor
   prevents changed account defaults from resetting that chapter.
4. New chapters in `auto` use image geometry. Ordinary PDF global defaults in
   KOReader do not replace BiliComics account defaults. Existing chapters retain
   their native loading behavior for fields without saved values or anchors.

The actual plugin captures settings during KOReader's `DocSettingsLoad` event,
before `ReadSettings` migrates or fills native values. No KOReader class or global
reader configuration is patched. The provider's native `Configurable` belongs to
each document instance.

Absolute LTR/RTL turning uses `ReaderView:onToggleReadingOrder`, accounting for
KOReader's mirrored interface. This rebuilds native touch zones and controls real
swipes. Page traversal uses the native `ReaderZooming:onSetZoomPan` contract with
the current zoom parameters preserved: RTL begins a zoomed page at its right
edge and advances left. Saved `kopt_writing_direction` is restored before native
view initialization. Page order and chapter descriptors are unchanged.

This provider intentionally has no `ReaderConfig`, the module that normally
persists `kopt_page_scroll` and `kopt_writing_direction`. The integration saves
these standard keys during native `SaveSettings` and before close. Temporary
native page-flipping or skim modes do not replace the actual scroll preference.

## Remote Native Verification

`defaults_run.py` runs separate official KOReader processes with private XDG
directories and synthetic image/account services. `defaults_spec.lua` loads the
actual production `main.lua` hooks and integration, not a replacement reader.
Coverage includes auto/explicit modes, conflicting native settings, old anchor
mode recovery, native UI changes, process restarts, free zoom, mirrored LTR/RTL,
registered tap handlers, real swipe handlers, and RTL page-height viewport
progression. No credentials, Bilibili requests, or physical devices are involved.

```powershell
ssh test-env 'python3 /tmp/bilicomics-reader-defaults/plugin/spec/reader/defaults_run.py --runtime /tmp/bilicomics-native-_duimwe7/lib/koreader --plugin /tmp/bilicomics-reader-defaults/plugin --output /tmp/bilicomics-reader-defaults/output --pillow /tmp/bilicomics-native-_duimwe7/backend-probe/python-deps'
```

Use a fresh output directory for each complete run. All verification runs on the
authorized remote host; no local tests or runtime probes are required.

The recorded `v2026.07.1` run in `defaults-results.json` passes all 18 native
processes and 247 assertions. `defaults-regression-results.json` records the
existing provider/ReaderUI suite after the defaults change: all 9 processes and
314 assertions pass, including geometry correction, EOF transition, thumbnail
isolation, continuous/page/free-pan restart anchors, and close behavior.
