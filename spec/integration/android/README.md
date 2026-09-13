# Android APK Reader Integration

## Verified boundary

The final run uses the unmodified official KOReader v2026.07.1 x86 APK on the
existing API 30 emulator, in the APK's ordinary UID. Production main.lua,
Runtime, Controller, ReaderUI, MuPDF provider, SQLite Store, PageStore and real
Runner fork/IPC execute together. Only the documented Runner worker dependency
and connectivity result are synthetic. The test performs no Bilibili request,
account access, recharge or purchase.

Both final runs use the frozen production tree at
/tmp/bilicomics-final-Ei7yAG/source, staged without production edits at
/var/tmp/bili-android-final-xfnTqb3F/source. The results record complete production
SHA-256 manifests, deployed bytes, and source hashes rechecked from the app.
Later purchase purpose/UI wording changes are outside this snapshot; this report
does not attribute their validation to the APK runs.

The 62 workflow assertions comprise 47 online assertions and 15 assertions after
a real APK process restart:

| Requirement | Observed evidence |
| --- | --- |
| Native online opening | The chapter opens before its first image; actual framebuffer pixels show the missing-image state |
| Responsive event loop | A child-written marker proves the first image worker is blocked; 14 real UI heartbeats execute with a maximum gap of 59.39 ms, including an overdue-current-gap check |
| Image arrival | Main-process PageStore commit replaces the native placeholder with expected image pixels before chapter completion |
| Prefetch | Page two completes without navigating from the first source image |
| No implicit purchase | Locked download dispatches no worker; reading/prefetch/download create no purchase request or journal |
| Download ownership | Explicit free and already-owned chapter jobs remain active after reader closure; five new image workers start and six complete after closure |
| Complete pinned content | Both chapters finish, validate as complete and remain pinned; the descriptor path and bytes stay unchanged |
| Local diagnostics | Real production Worker.execute completes in a real child while the primary network Runner is suspended; diagnostics use their separate Runner, send no session, report android-x86 and private credential storage, and mark server_checked false |
| New reader defaults | A new 600 by 2400 chapter with auto/LTR uses page-width zoom, continuous mode and native LTR direction |
| Existing reader settings | Explicit native page mode and the source anchor survive restart despite the global auto default |
| Session isolation | Only a new dedicated synthetic account is used; its session is saved through production SessionStorage in app-private storage and removed before restart |
| Actual restart | Online PID 15765 and offline PID 15873 both belong to org.koreader.launcher, UID 10167 |
| Offline reading | The new process has no session, restores the same source anchor and descriptor, displays the expected free/owned image pixels, and submits zero workers |

Source/UID assertions and setup/cleanup checks are recorded separately from those
62 workflow assertions. The display is the emulator's actual 800 by 1280 Android
surface. The installed APK is versionCode 119463, SELinux remains Enforcing,
and the APK hash before and after execution is
3cd979cc6474308ce37c408a8753fce27898249599e6ec6875d34ecd9b3d4144.

The observed_view field in intermediate chain reports is diagnostic state
captured at a transition, possibly before native repaint. Completed pixel checks
are the guarded assertions and saved offline reference, not that transition snapshot.

The mode observation waits for the opened event from the same Reader instance
and reader_generation. An exploratory assertion ran at the read callback,
before Integration's next-tick default restoration. Its trace showed a new
document with no saved settings or anchor and no opened event. The final driver
moves only the observation point; it retains strict auto/continuous/LTR
assertions and does not wait for the expected mode itself. No production default
code changed. In the passing run, read_callback occurred at 1789188483.625833
and opened generation 1 at 1789188483.645913.

## Actual default-directory cold startup

cold-results.json records a separate production installation and native
lastfile startup. The real plugin directory was initially absent. The launcher
temporarily installs the frozen production tree at
/storage/emulated/0/koreader/plugins/bilicomics.koplugin. DataStorage paths,
Runtime's default root and startup-patch discovery are not redirected.

Four separate ordinary app processes execute:

| Phase | PID | Evidence |
| --- | --- | --- |
| Prepare | 16765 | Real Store and PageStore seed one complete pinned owned chapter and anchor in the default namespace; no Runtime, Controller or provider is initialized |
| Install | 16895 | Native PluginLoader instantiates actual production main; main installs its exact production 2-bilicomics-provider.lua; start_with=last and the seeded lastfile are saved |
| Cold | 17003 | After force-stop/restart, official startup loads the normal production patch and ReaderUI automatically opens the saved chapter |
| Cleanup | 17171 | The app restores original native settings and confirms that this no-session account never created private credentials |

The actual production patch is
/storage/emulated/0/koreader/patches/2-bilicomics-provider.lua. Its installed
digest is c985a04cb2a23b595ea42dad9cab295e7bb2135911a59915d94234614320cc9f.
The automatically selected descriptor is
/storage/emulated/0/koreader/bilicomics/accounts/bili_986543178918880590758945457014930/documents/984201/98420101/cold_1/chapter.bcomic.

A unique earlier late userpatch observes startup and hard-fails any Runner
submission. Before production registration, it confirms an empty custom registry
and uninitialized Runtime. At the one native showReader call, the production
provider is registered and Runtime is still uninitialized; normal lazy service
resolution then opens the document. The observer delegates to the original
ReaderUI method and never calls register, installStartupPatch or an active
document-open function. Actual production main performs installation in the
preceding process.

The cold phase passes 18 behavior/environment assertions plus 185 source-byte
checks. It proves the actual plugin instance, unchanged default namespace, no
session, immutable descriptor, complete pinned content, source anchor y=0.3,
continuous page-width presentation, framebuffer pixel 100 and zero workers.
Preparation has 13 behavior/environment assertions, installation has 6 and
cleanup has 2; each non-cleanup phase also checks all 185 production files.
Repeated source checks are not counted as additional feature scenarios. The
host rechecks the cold report after force-stop for late worker errors.

## Research driver adaptations

- The combined driver temporarily returns the actual production plugin
  class. The native PluginLoader and ReaderUI instantiate it normally.
- Production files live in a new UUID bundle beneath the research plugin.
  A next-tick search-path addition compensates for PluginLoader restoring its
  package path after loading a plugin; no KOReader method is replaced.
- Runtime's existing root argument selects a UUID directory beneath shared
  DataStorage. Production database, descriptor, image commit, fsync and cache
  operations use that actual shared filesystem.
- Only DataStorage:getPatchesDir() is directed to the test root so production
  startup-patch installation does not alter a global startup hook.
- Setup temporarily selects FileManager startup and disables other plugins.
  The original native settings file and its .old companion are saved and
  restored by the ordinary app process. No other account or session is read.
- The synthetic worker performs bounded delayed copies of a 600 by 2400 PNG
  with grayscale bands 40, 100, 160 and 220. It runs in real app-UID child
  processes and writes PID/timing audits. The diagnostics branch calls the real
  production worker, whose diagnostics transport blocks network access.
- A background research widget keeps the app alive for host PID verification
  after the actual reader and Runtime have closed. It does not render pages or
  replace the real event loop.

Two exploratory runs exposed driver issues, not production defects: the nested
bundle path was initially lost after PluginLoader completed, and a delayed
library display could cover the faster offline reader. Both were corrected.
The final runs also handle native settings under shared DataStorage rather than
android.dir, and PluginLoader's valid double slash in a plugin source path.
No production modules were changed for these driver adaptations.
The final run includes additional recovery guards: missing setup ownership
cannot be accepted after successful setup, and a damaged production bundle
cannot prevent attempted native-settings recovery.

## Exclusive slot, backup and restoration

Use only ssh test-env, the dedicated adb port 5038 and serial emulator-5580.
Obtain an explicit APK-slot handoff from the current operator before running;
the launcher also takes the host lock at
/var/tmp/bili-android-emulator-20260912/apk-operation.lock.

The launcher checks the official installed APK digest and never modifies,
installs or signs an APK. It fully archives the research plugin before replacing
its main/input files and adding the new UUID bundle. It also saves the named
native shared-state files and directories that real ReaderUI may update:
history, settings, cache, reader settings and defaults companions. Backup
traversal refuses account directories and session files.

The cold launcher additionally saves default plugin settings and its owned
startup patch, refuses an occupied production plugin directory or foreign
startup-patch file, and uses only a new synthetic shared/private account identity.

Setup, online, offline and cleanup each run in a separate APK process with a
45-second host deadline. Cleanup always runs after driver installation. It
deletes only the owned synthetic account's session, restores the original
native settings and verifies the result. Without an ownership record it never
deletes a candidate account file. The host then force-stops the APK, restores
shared state and the complete research plugin, verifies byte/hash inventories,
removes only its validated UUID bundle, and releases the lock.

Both reports confirm all restoration checks. Cold restoration additionally
confirms default plugin settings and the original startup-patch state, removal
of the temporary actual plugin, unique observer patch, owned synthetic account
and only originally absent empty parent directories. No synthetic session
remains. The APK hash is unchanged, both launchers exited successfully, the APK
is left force-stopped and the operator slot was returned to the parent task.
The emulator and dedicated evidence/backups remain available for audit.

## Files and reproduction

- main.lua: official-app research driver and native-setting cleanup.
- chain.lua: Android adaptation of the existing online/offline integration.
- run_apk.py: exclusive deployment, observation, restart and restoration.
- remote-results.json: final evidence, source manifests, PIDs and restore checks.
- cold_main.lua: preparation, actual installation observation and cleanup.
- cold_guard.lua: earlier late-patch observer and zero-worker guard.
- run_cold.py: exclusive actual-plugin installation and cold-start launcher.
- cold-results.json: native automatic startup and full restoration evidence.

After staging a frozen production tree plus these tests on the remote host:

    ssh test-env 'python3 /path/to/snapshot/spec/integration/android/run_apk.py --snapshot /path/to/snapshot --output /var/tmp/new-android-integration-output --fixture /path/to/synthetic-page-1.png --slot-confirmed'
    ssh test-env 'python3 /path/to/snapshot/spec/integration/android/run_cold.py --snapshot /path/to/snapshot --output /var/tmp/new-android-cold-output --fixture /path/to/synthetic-page-1.png --slot-confirmed'

The output must be a fresh directory outside the source snapshot. Revalidate
the emulator and handoff before every run. Complete logs and backups from the
recorded runs are under /var/tmp/bili-android-final-xfnTqb3F/combo-final and
/var/tmp/bili-android-final-xfnTqb3F/cold. The earlier 83-file/53-assertion baseline
under /var/tmp/bili-android-integration-3ILLW2Yo/run5 is superseded here.

This evidence does not establish real Bilibili protocol compatibility, payment
success, physical e-ink refresh quality, API 35 behavior, ARM execution, or
memory limits on physical Android/Kindle/Kobo devices.
