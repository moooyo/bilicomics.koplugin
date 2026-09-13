# Bookshelf finishing UI verification

Date: 2026-09-13. All execution took place through `ssh test-env` in the official
KOReader v2026.07.1 Linux emulator. No local Windows tests, builds or runtime
probes were run. Previous grid/category reports remain historical evidence of
their recorded source versions.

## Final UI behavior

The bookshelf now presents Back, its title and More without permanent refresh,
default-filter or gesture-instruction bars. Cards contain an aspect-preserving
cover, at most two title lines and one reading-position line. Latest chapter
details remain available through the chapter catalogue. A nondefault filter is
shown explicitly with a direct Clear filter action.

More retains manual synchronization, the last successful synchronization time,
failure status, filtering, ordering, the last keyboard-selected comic's chapter
catalogue, account/settings and repeatable help. Initial help is acknowledged
once per account. The Bookshelf/Bookstore/Search/Downloads navigation uses
borderless native touch targets, a light separator and selected text/underline.
The category bookstore retains its compact two-row grid and existing controls.

View state is saved before navigation, reading and destruction using the
account-scoped Controller interface. Existing order IDs are retained during
cover/background updates. A manual refresh or sort action deliberately applies
a new order. Recent ordering uses only a positive timestamp with local progress
provenance; unknown and server-only timestamps retain source order.

Successful reading initiated from the bookshelf keeps a same-account, same-comic
return intent while closing the plugin view. `onReaderClosed` restores the
remembered bookshelf directly; explicit plugin close and account changes retire
the intent. This UI check invokes that event after the controlled read handoff.
The Controller's active-reader/opening/generation gates are verified separately.

Account settings include Concurrent image downloads with values 1, 2, 3 and 4,
defaulting to 2. The existing Controller setting key is `download_concurrency`.
The UI explains that the setting includes online cache and downloads and that
already-running images finish when the value is lowered. Successful changes
refresh the confirmed selection and account label; a storage failure retains
the last confirmed value.

## Native matrix

`bookshelf_finishing_spec.lua` uses account-scoped synthetic sync/view state,
controlled callbacks and original covers visibly labeled `SYNTHETIC ORIGINAL
ART`. Each case has isolated XDG directories and an isolated network namespace.
No account credentials, real HTTP, comic reading contents or purchases are used.

| Language | Resolution | Assertions | Result |
| --- | --- | ---: | --- |
| Chinese | 480 by 640 | 138 | Passed |
| Chinese | 600 by 800 | 139 | Passed |
| Chinese | 720 by 960 | 157 | Passed |
| Chinese | 960 by 720 | 143 | Passed |
| English | 480 by 640 | 138 | Passed |
| English | 600 by 800 | 139 | Passed |
| English | 720 by 960 | 157 | Passed |
| English | 960 by 720 | 143 | Passed |

All **1,154 assertions passed**, retaining the original 986 assertions. Coverage includes the quiet default, compact
captions, underline navigation, More actions, keyboard-selected chapter access,
visible/clearable filtering, stable background order and explicit reorder,
account-isolated view state, actual UI return-event handling, first-use/repeated
help, retained offline cards, missing/confirmed/filtered empty states, category
grid preservation, concurrency values and failure recovery.

The connectivity correction adds 21 checks per matrix case, including native
bounds for the new state screenshots. Authentication and synchronization
availability are independent: an authenticated offline account retains its
cached cards and sees connection guidance in More; an empty offline cache shows
the same guidance with a disabled Retry sync action. A temporary synchronization
restriction displays its own status instead of requesting login or connection.
Reconnection enables retry and a successful result displays cards. Anonymous
accounts retain QR sign-in. Disabled manual synchronization also rejects a stale
callback without dispatching work.

The corrected cases use explicit `authenticated=true`, `offline=true` and
`can_sync=false` together. The earlier simulated network-response failure case
remains intact; it does not substitute for an actual offline state. The prior
986-assertion report, harness and screenshots are preserved in
[`history/bookshelf-finishing-986/`](history/bookshelf-finishing-986/README.md).

Native rendering initially exposed an eight-pixel overflow on the 720 by 960
two-row bookshelf and a 15-pixel overflow on the landscape account screen. A
small multi-row cover allowance and tighter account spacing resolved these
without changing the bookstore layout or shrinking touch targets. The final
matrix passed screen/dialog bounds and representative default, More, filter,
help, category and concurrency screens were visually inspected.

`bookshelf-finishing-verification.json` binds the tested production/UI harness
hashes and case outcomes. Full records are in `bookshelf-finishing-results/` and
the native screenshots are in `screens/bookshelf-finishing/`. These are native
UI results, not claims about live account synchronization, real scheduler
throughput, fresh QR authentication or physical e-ink hardware; those are
covered by their separate finishing reports.

Remote output: `/var/tmp/bilicomics-finishing-OHQWOHTS/ui-finishing-connectivity-pass1`.

## Reproduction

Run only on `test-env` with a new output directory:

```powershell
ssh test-env 'PYTHONPATH=/var/tmp/bilicomics-bookstore-protocol-7g7nf8co/python-deps python3 /var/tmp/bilicomics-finishing-OHQWOHTS/source/spec/ui/run_bookshelf_finishing.py /var/tmp/bilicomics-bookstore-protocol-7g7nf8co/runtime/lib/koreader /var/tmp/bilicomics-finishing-OHQWOHTS/source /var/tmp/bilicomics-bookshelf-finishing-new-output'
```
