# Local native KOReader acceptance

## Current candidate acceptance

On 2026-09-13 the user explicitly authorized local verification for this task and
selected actual local KOReader acceptance instead of a physical Scribe gate.
The current canonical candidate is the 101-file archive with SHA256
`45385c6ff3cc99d2639f92575fb6db0ac363ab20aa76800aa7bbdbdbe93f5342`.

- [Visible startup and native restart](candidate-startup-result.json) passed in
  WSLg at 720x960 and 600x800; [anonymous layout review](candidate-layout-review.json)
  found no clipped or overlapping controls.
- [Native session acceptance](native-session-result.json) used the newly
  confirmed real QR session, production import/validation, a private 0600 save,
  native exit and a new-process restart. Its one-time input was removed.
- [The first online request after restoration](renewable-online-result.json)
  completed real cookie information, identity validation and favorites reads.
  The server required no credential rotation. The final visible process has
  the temporary observer and import hook disabled.
- [Complete local reading](live-reading.md) passed 51 online and 30 independent
  offline checks for 45 real pages, using the exact packaged candidate as an
  ordinary WSL user. Its profile is separate from the visible application.
- The updated [authentication guard](authentication-guard-results.json) passed
  162 cases and 279 assertions. It permits only the exact supported
  authentication routes and approved reads; real purchases remain blocked.

The authenticated visible instance uses the isolated profile
`/home/moooyo/.local/share/bilicomics-acceptance/candidate-45385c6f-rg5l4bo5/profile`.
The historical default profile was not changed. To reopen this specific instance,
use the current local launcher with that explicit profile:

```powershell
wsl.exe -d Debian -u moooyo --exec python3 /mnt/d/Code/bilicomics.koplugin/spec/local/launch_koreader.py --runtime /home/moooyo/.local/share/bilicomics-acceptance/runtime-v2026.07.1/lib/koreader --plugin /mnt/d/Code/bilicomics.koplugin/dist/bilicomics-0.1.0-dev.zip --profile /home/moooyo/.local/share/bilicomics-acceptance/candidate-45385c6f-rg5l4bo5/profile
```

The user explicitly deferred actual credential rotation and old-token
confirmation after the live service returned `refresh=false`. Local acceptance
does not establish physical Kindle behavior or successful real payment.
The [final source/evidence addendum](../package/local-acceptance-source-evidence.json)
records completion of the revised local task and keeps those deferred claims
separate from the passing checks.

## Historical setup and evidence

The sections below retain their original runtime, archive and authorization
snapshots. References to an earlier "current" build apply to that recorded
snapshot, not to the canonical candidate above.

These acceptance-only helpers use the unchanged official Linux KOReader runtime under WSLg. They are not production plugin modules and do not inject UI records, protocol responses or chapter images. The user requested local KOReader acceptance, authorizing local execution for this task. The initial visible startup passed: the real Chinese plugin UI rendered at 720x960, the guarded process remained running, and all 87 staged production files matched the then-current prefetch archive. See [the sanitized startup result](startup-result.json). The visible app was not automatically replaced with later recovery builds. No session was imported by the launcher, and no purchase test was executed. Local live-account reading remains manual; the earlier complete account workflow was verified on `test-env`.

The Windows entry is [start-local-koreader.ps1](../../tools/start-local-koreader.ps1). It prepares the digest-pinned official runtime if needed and starts, inspects or stops this isolated app:

```powershell
& D:\Code\bilicomics.koplugin\tools\start-local-koreader.ps1
& D:\Code\bilicomics.koplugin\tools\start-local-koreader.ps1 -Action Status
& D:\Code\bilicomics.koplugin\tools\start-local-koreader.ps1 -Action Stop
```

Run as the ordinary WSL desktop user `moooyo`, not root. No global dependency installation is performed. The launcher copies a packaged plugin into a private profile, uses that profile as `KO_HOME`, and launches official `luajit reader.lua`. A supported early user patch installs the read-only guard before Runtime, lets native PluginLoader construct the real plugin, and opens its normal `onShowBiliComics` entry. The default desktop window is 720x960, with Chinese UI and X11 through WSLg `DISPLAY=:0`.

```powershell
wsl.exe -d Debian -u moooyo --exec python3 /mnt/d/Code/bilicomics.koplugin/spec/local/launch_koreader.py --runtime /home/moooyo/.local/share/bilicomics-acceptance/runtime-v2026.07.1/lib/koreader --plugin /mnt/d/Code/bilicomics.koplugin/dist/bilicomics-0.1.0-dev.zip --profile /home/moooyo/.local/share/bilicomics-acceptance/profile
wsl.exe -d Debian -u moooyo --exec python3 /mnt/d/Code/bilicomics.koplugin/spec/local/launch_koreader.py --profile /home/moooyo/.local/share/bilicomics-acceptance/profile --status
wsl.exe -d Debian -u moooyo --exec python3 /mnt/d/Code/bilicomics.koplugin/spec/local/launch_koreader.py --profile /home/moooyo/.local/share/bilicomics-acceptance/profile --stop
```

The profile contains private KOReader data, staged code, `koreader-private.log`, process identity and optional `native-ui-before-import.png`. The screenshot uses KOReader's own framebuffer and is created only for an anonymous account without a session. It does not capture the desktop. Treat the profile and log as private; never copy raw logs, sessions, signed URLs or acquired comic content into the repository. Status and stop compare UID, process start time, process group and an acceptance marker before affecting the recorded process. Stop targets only that verified process group and does not delete profile data.

## Manual session import and non-purchase acceptance

1. Wait for the real BiliComics library window. `native-ui-ready.json` records successful UI opening; startup errors remain in the private log.
2. Open Account and settings, then Import from file. Use the native file chooser to navigate to `/mnt/d/Code/test/` and select `bilibili.txt`. This corresponds to the user's existing Windows file at `D:\Code\test\bilibili.txt`. The launcher never reads or imports it.
3. Wait for the validated-session feedback. Browse existing following/history, search or open a comic ID. Use only free or already-owned chapters for this acceptance run; inspect online opening, prefetch, explicit download and offline reopening manually.
4. The user expanded authorization on 2026-09-13 to allow non-purchase operations. The updated guard permits reading purchase quotes, discount/card eligibility information and the existing wallet balance. Viewing those records does not authorize spending. Purchase submission, rental/recharge, automatic-purchase settings and following/history mutations remain blocked by this acceptance guard.

The earlier local startup/upgrade records used a reading-only scope that also
blocked quote and wallet access. That historical restriction is not the current
authorization and those records do not verify the expanded guard.

The test-only guard retains exact navigation, existing favorites/history,
search, comic-detail, image-index, token and reading-recovery routes. It now also
admits these POST reads on `manga.bilibili.com`:

| Route | Accepted body |
| --- | --- |
| `comic.v1.Comic/GetEpisodeBuyInfo` | Numeric `ep_id`; explicit scoped reads add `buy_type`, `order` and an optional bounded `batch_limit` (required for type 2). |
| `user.v1.User/GetWallet` | Empty object. |
| `comic.v1.Comic/GetDiscountList` | Numeric `comic_id`, order 1/2 and the original finite nonnegative amount vector. |
| `comic.v1.Comic/CalDiscountPrice` | Numeric `id` and the original amount vector. |
| `comic.v1.Comic/GetComicFreeGoldCard` | Numeric `comic_id`, `ep_id`, type 1/2/3 and bounded `batch_limit`. |

These five reads accept only the fixed base query
`device=pc&platform=web&nov=27&a=810`. The bare `getEpisodeDiscounts` flag is allowed
once, only on an explicitly scoped GetEpisodeBuyInfo request; the valued form
and misplaced/duplicate flags are rejected. The amount vector is a dense array
of 2 through 514 numeric values, matching the quote collector's two base amounts
and up to 512 original offers. This guard supplies that bound even though the
Client's two auxiliary discount helpers do not validate all arguments themselves.
Purchase body fields cannot be attached to another reading route.

The Runner guard admits the read-only Client methods and `quote`/
`reconcile_purchase` jobs; reconciliation performs only catalog and wallet reads.
It still rejects `purchase_submit`, `set_favorite` and unknown job kinds before
dispatch. Admission by this guard does not add missing methods to the production
Worker's own dispatch list. Unknown/write RPC routes, including BuyEpisode,
remain blocked with `transmitted=false` before the original transport is called.

Only manifest-pinned WASM URLs and anonymous CDN URLs currently being used by
production image acquisition are allowed. Production TLS verification, redirect
rejection, asset hashes, image inspection and budgets remain unchanged. This is
a bounded application acceptance guard, not an OS network sandbox or a claim of
physical Kindle compatibility. Independent guard checks use strict fake originals
on `test-env` with `unshare -n`; their simulated forbidden requests never reach a
network transport and do not execute a real purchase.

The [independent guard result](readonly-guard-results.json) passed **123 cases /
209 assertions** against the fixed guard SHA256
`2832fe41a7f64de9bf8bb5b8b34b33313d64cf7d62c804915d73b40b67fd3c6a`.
The test used real Client wire construction with strict fake Transport/Runner
originals: 26 admitted transport calls and 20 admitted jobs reached only those
fakes, while denied operations reached neither original. It also checks that an
active image URL cannot escape `/bfs/` using raw or encoded dot segments. The
remote evidence is `/tmp/bili-acceptance-guard-H50QHTYd/run1/results.json`.
This confirms guard decisions, not live quote data, UI integration or an update
to an existing local process.

## Updating the acceptance build

Starting while the recorded owned application is active returns its current status and leaves that process unchanged. **An already-open window does not automatically receive a new guard or package.** To select the current archive and guard, close the acceptance app normally, then run the Windows Start entry again. Existing profile settings and account data are retained; they are never replaced with another user's settings or automatically imported from the Windows input file. Each archive is staged separately by digest. Before a new process loads plugins or opens its startup document, the early patch selects the new plugin path and updates the owned provider patch. Startup checks both the native plugin handler's underlying function and Runtime source path against the selected build. The handler still runs through KOReader's native HandlerSandbox.

The [recorded isolated upgrade result](upgrade-result.json) records two real native boots using SDL's dummy video driver in one disposable profile: the 87-file `65b38f` build followed by the 91-file `2f337b48` build. Both opened the native plugin UI, loaded the selected source and matched the provider patch. Source-refresh and version-replacement APIs changed from absent to present, and a synthetic profile marker survived. Both owned test processes stopped. No display server or network listener was started, no session was imported, and the existing visible profile was neither read nor changed. This confirms build selection and preservation of the marker, not a live-account database migration or a new visible-window interaction test. The earlier 87-to-89 build check is preserved in [the historical source-refresh upgrade result](upgrade-source-refresh-result.json).

`verify_upgrade.py` performs that bounded check with explicitly pinned archive identities. Its optional `--video-driver dummy` launcher setting is limited to disposable headless checks; the ordinary visible launch continues to use X11 through WSLg.

The later ARM relocation correction changes only native ARM binaries, manifests and native documentation; all Lua and x86 native bytes remain unchanged. Its ARM probes are separate evidence. The recorded upgrade above remains pinned to its original 2f337b48 archive, now retained at `dist/history/bilicomics-reading-2f337b48.zip` for `verify_upgrade.py` reproduction. The ordinary Start entry continues selecting the current development archive; this ARM-only update did not restart or inspect the interactive profile.

The subsequent reading revision adds a shared download connectivity check and
full-width temporary-access expiry text. Its focused verification runs on
`test-env`: 25 connectivity cases and 132 native display checks at each of
600x800 and 480x640. These results do not replace the historical local startup
or upgrade records. The local launcher status was inspected and returned no
running owned instance; the interactive profile was not restarted or upgraded
automatically. Start selects the current development ZIP when the user launches
it. At the time of that record, the separate quote preview was not selected by
this entry. The current default is the integrated 96-file archive described in
[the package report](../package/README.md); the preview ZIP is now a byte-identical
alias. This package and guard update changes neither the startup script nor its
package path and did not restart or inspect an interactive profile. The next
new process uses the current archive and guard; its interactive execution is
not covered by the historical startup records.
