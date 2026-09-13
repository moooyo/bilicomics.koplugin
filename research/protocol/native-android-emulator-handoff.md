# Android emulator handoff for native plugin verification

Date: 2026-09-12. All downloads, archive checks, executable probes, installation, and guest operations ran on `test-env`. No local verification or global SDK installation was performed. Production native source, binaries, and manifests were not changed by this setup.

## Current state

An isolated API 30 x86 Android emulator is running with KVM, software graphics, and no host window. The official KOReader v2026.07.1 x86 APK is installed without modifying its binary or signature. KOReader was not launched by the bootstrap, no account was added, and the native plugin loading/golden checks remain a separate handoff task.

| Item | Observed value |
| --- | --- |
| Workspace | `/var/tmp/bili-android-emulator-20260912` |
| SDK | `/var/tmp/bili-android-emulator-20260912/sdk` |
| adb executable | `/var/tmp/bili-android-emulator-20260912/sdk/platform-tools/adb` |
| adb server port | `5038` |
| adb server socket | `tcp:127.0.0.1:5038` |
| Emulator serial | `emulator-5580` |
| Emulator console / transport ports | `5580` / `5581` |
| Emulator process ID | `1154381` |
| AVD | `/var/tmp/bili-android-emulator-20260912/avd/bili-koreader-api30-x86.avd` |
| Runtime log | `/var/tmp/bili-android-emulator-20260912/emulator.log` |
| Bootstrap and state | `bootstrap.py`, `session.json`, `download-manifest.json` in the workspace |
| Boot completion | `sys.boot_completed=1`; emulator log reported 58,564 ms |
| Android API | `30` |
| Guest kernel architecture | `i686` |
| Guest ABI list | `x86,armeabi-v7a,armeabi` |
| Page size | `4096` bytes |
| SELinux | `Enforcing` |

The emulator process was confirmed as `qemu-system-x86_64-headless`, running the 32-bit Android image. The host QEMU executable's name does not make the Android application process 64-bit.

The current state is saved in [the session record](native-android-emulator-session.json), with package provenance in [the download record](native-android-emulator-downloads.json) and [APK inspection](native-android-emulator-apk.json). These records are snapshots; use adb to confirm liveness when resuming later.

## Why this ABI and image

The official [v2026.07.1 release](https://github.com/koreader/koreader/releases/tag/v2026.07.1) provides Android `arm`, `arm64`, and `x86` APKs, but no `x86_64` APK. The selected x86 APK contains only `lib/x86` libraries, and all five inspected native members are ELF32 / EM_386. It cannot load an x86_64 native plugin library. This route requires matching `android-x86` plugin libraries built with `i686-linux-android21-clang`; the existing x86_64 artifacts retain their own separate build status.

API 30 Google APIs x86 was selected because it matches the official APK's process ABI and exercises Android 10-and-later executable-code restrictions without depending on ARM translation. It does not cover API 35 or physical ARM-device behavior.

## Official inputs and download cost

SDK package records came from Google's [SDK repository metadata](https://dl.google.com/android/repository/repository2-3.xml) and [Google APIs image metadata](https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-3.xml). The stable emulator channel was used. Each archive's byte count and SHA-1 were checked against that metadata before extraction, and a SHA-256 was recorded independently.

| Package | Official archive | Bytes | Official SHA-1 |
| --- | --- | ---: | --- |
| Emulator 37.1.11 | [Linux archive](https://dl.google.com/android/repository/emulator-linux_x64-15917651.zip) | 334,378,080 | `1b1f78891abf8ec268264356e1365c25519e8379` |
| Platform-tools 37.0.1 | [Linux archive](https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip) | 9,054,187 | `477254aa5f903c15cf51001717bdf347fb6b53e0` |
| API 30 Google APIs x86, revision 16 | [System image](https://dl.google.com/android/repository/sys-img/google_apis/x86-30_r16.zip) | 1,240,551,553 | `a58447e540a8581394dd04ee419c6771d62723d8` |

These three SDK archives total 1,583,983,820 bytes, approximately 1.475 GiB. Their uncompressed members total 4,262,481,490 bytes before AVD writable data. The AVD data partition is configured for 2 GiB. The workspace uses `/var/tmp` disk storage rather than the smaller `/tmp` tmpfs.

The [official x86 APK](https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-android-x86-v2026.07.1.apk) is 30,674,543 bytes and matched the GitHub release asset SHA-256, `3cd979cc6474308ce37c408a8753fce27898249599e6ec6875d34ecd9b3d4144`. It remains at `/var/tmp/bili-android-emulator-plan-20260912/koreader-android-x86-v2026.07.1.apk`. Total downloaded bytes including the APK are 1,614,658,363.

Extraction checks resolved each member path and symlink target inside its designated extraction root. Only the three pinned archives were unpacked. No SDK manager, command-line tools package, Android Studio, Java installation, or global package install was needed. The bootstrap writes a small AVD definition directly and keeps adb authentication material under the isolated Android user directory.

## Connecting to the running guest

Use the dedicated adb port explicitly. These commands are PowerShell commands that execute on `test-env`:

```powershell
ssh test-env '/var/tmp/bili-android-emulator-20260912/sdk/platform-tools/adb -P 5038 devices'
ssh test-env '/var/tmp/bili-android-emulator-20260912/sdk/platform-tools/adb -P 5038 -s emulator-5580 shell getprop sys.boot_completed'
ssh test-env '/var/tmp/bili-android-emulator-20260912/sdk/platform-tools/adb -P 5038 -s emulator-5580 shell getprop ro.product.cpu.abilist'
```

The bootstrap's emulator command uses `-no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -accel on -port 5580 -memory 2048 -cores 2`. The isolated environment supplies `ANDROID_USER_HOME`, `ANDROID_EMULATOR_HOME`, `ANDROID_AVD_HOME`, `ADB_SERVER_SOCKET`, and `ANDROID_ADB_SERVER_PORT`. The launch process is detached from the completed bootstrap; it was intentionally left running for the plugin test. See the [official command-line reference](https://developer.android.com/studio/run/emulator-commandline) and [acceleration reference](https://developer.android.com/studio/run/emulator-acceleration).

For a later explicit shutdown, target this guest with `adb -P 5038 -s emulator-5580 emu kill`. Do not stop another task's adb server or use unqualified process-name termination. Stop the server on port 5038 only when this environment is no longer needed.

## Native loading test boundary

The adb-shell mount snapshot shows `/storage/emulated` and `/mnt/user/0/emulated` backed by FUSE with `noexec`; `/storage` is also mounted with `noexec`. SELinux was not disabled and storage was not remounted. These are relevant inputs to the planned shared-library `PROT_EXEC` mapping test, not a substitute for the application-process result.

The next task must launch the unmodified official KOReader app, complete only the storage access needed for the test, discover its actual data/plugin directory, and exercise both native libraries through that app's LuaJIT process. Record the selected ABI, absolute library paths, exact `ffi.load` result or linker error, and fixed expected-output checks. Keep the native libraries in the real plugin directory for the first observation so that the intended deployment location is what gets tested.

Loading a library from an adb shell, `/data/local/tmp`, a root process, or a different app-private directory would answer a different deployment question. Neither the completed boot nor APK installation promotes any native artifact from `built_only`. Any production change suggested by the resulting loader evidence must be reported separately while the current production package remains frozen.

The reusable setup script is [native-android-emulator-bootstrap.py](native-android-emulator-bootstrap.py). It should not be rerun against the live session merely to inspect status, because its provisioning flow launches an emulator; use the existing adb endpoint and state files for handoff.
