# Kindle Scribe UI redesign

The native Lua UI follows the supplied BiliComics Scribe handoff's chosen
directions: 1b (resume block and five-column bookshelf), 1d (chapter table), and
1h (full-page purchase). The HTML is a reference and is not shipped.

## Layout and controls

The reference is 930 by 1240 design pixels. `W.dp` scales that reference to the
device's shorter screen edge; `W.fontSize` compensates KOReader's internal font
scaling. All text uses bundled `cfont`. The page uses 56 dp horizontal margins,
a 116 dp header with device status, an 88 dp navigation bar, and 108 dp action
bars for full-page flows. Existing KOReader widget primitives provide square
frames, grayscale fills, text, images, native buttons, and focus handling.

The Scribe bookshelf shows a local reading anchor and ten covers without
repeating the resume comic. Bookstore pages show twelve covers. The chapter
table separates progress, entitlement, and local storage, with ten rows on the
Scribe. Smaller and landscape screens use fewer items per page. Long prose,
settings, and choices paginate with touch controls, swipes, and page keys.

Purchase, recovery, QR sign-in, recharge, and settings flows occupy a full page.
Reader actions and chapter transitions use bottom sheets over native ReaderUI.
Loading remains static text. Covers use the existing thumbnail pipeline; QR
codes use the native QR widget. No mock prices, balances, exchange rates, or
reading positions enter production state.

Only confirmed local anchors supply page-level reading progress. Offline
availability depends on current chapter entitlement and local completeness.
When synchronization does not expose progress counters, the first-sync view
shows an honest loading description. Filesystem free space and capacity come
from a fresh `statvfs` read when available.

Purchases still require an explicit confirmed quote, begin with non-paying key
focus, and never resend an unknown transaction. Recharge creation and credit
checks retain account, sequence, and order guards. The payment-code footer keeps
Check credit on the left and Close on the right. Closing stops polling without
canceling an existing order. Download recovery preserves revision, source-proof,
and journal safeguards.

## Acceptance

The user authorized local verification for this task. Tests ran under the
official KOReader v2026.07.1 Linux emulator in local WSL, with isolated profiles.
Synthetic UI tests use a network namespace and original fixture art; they do
not import an account, execute a real purchase, or create a real recharge order.

The follow-up UI matrix passed 4,228 assertions and produced 528 native
framebuffer screenshots: Chinese and English at 1860x2480, 480x640, 600x800, and
960x720. The receipt is
[`scribe-handoff-verification.json`](../spec/ui/scribe-handoff-verification.json).
It records unchanged UI source hashes and the pinned runtime identity.
The initial interaction acceptance did not establish complete visual fidelity;
the later [fidelity audit](scribe-ui-fidelity.md) documents the measured
deviations, corrections, and remaining reference/data differences.

Shared widget and reader-overlay checks passed 29 assertions, native reader
regressions passed 327 assertions across nine modes, and the existing controller
suite passed 69 assertions. Session-file import passed 47 assertions at each of
600x800 and 480x640, including privacy and stale-account checks. Forced recharge
pagination passed 19 assertions with working footer callbacks. Quote selection passed 116 assertions at each of
600x800 and 480x640; ordinal-range checks passed 106 assertions per size, download
recovery passed 392 per size, and version replacement passed 399 per size. A deterministic
123-file production ZIP loaded through the native PluginLoader at Scribe size,
opened the anonymous bookshelf and account screens, and exited normally.
The packaged candidate identity and aggregate results are recorded in
[`scribe-ui-acceptance.json`](../spec/package/scribe-ui-acceptance.json).

These checks establish emulator layout and synthetic interaction behavior.
They do not establish physical e-ink refresh behavior or actual payment outcomes.

## Reproduce

Use the designated verification host, or local WSL when explicitly authorized.
Keep output profiles outside the repository. With the runtime and Pillow already
prepared, run the following from PowerShell:

```powershell
wsl.exe -d Debian -u moooyo --exec python3 /path/to/plugin/spec/ui/run_scribe_handoff.py /path/to/koreader /path/to/plugin /path/to/output --languages zh_CN C
wsl.exe -d Debian -u moooyo --exec unshare --user --map-root-user --net -- python3 /path/to/plugin/spec/ui/run_widget_layout.py --runtime /path/to/koreader --plugin /path/to/plugin --output /path/to/output
```

Supply absolute WSL paths for the scripts and all positional paths. The Scribe
runner selects the required network namespace and checks source identity before
and after the run. The local launcher accepts Scribe dimensions and can select
the packaged candidate in a fresh anonymous profile.
