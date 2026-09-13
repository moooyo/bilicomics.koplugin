# Android APK native-library execution evidence

Date: 2026-09-12. All downloads, builds, emulation, and runtime checks took place
on the authorized remote `test-env`. No local runtime verification was performed.

## Result

The unmodified official KOReader v2026.07.1 x86 APK successfully loads both
plugin native libraries after the plugin copies their verified bytes into the
application's private files directory. The official signing WASM, AES-256,
and P-256 fixed-input checks all pass in the actual KOReader LuaJIT process.

Direct `ffi.load` from the external plugin directory fails for both libraries
with an Android `classloader-namespace` accessibility error. The successful
research route established a necessary Android loader change. The parent task
then implemented the shared production staging helper, which now passes the
actual APK checks on both initial cache creation and an application restart.
The native binary artifacts remained unchanged. The research probes did not
edit production code; the parent task owned the reviewed loader change.

## Environment

| Item | Observed value |
| --- | --- |
| Android image | Official Google APIs Android 11 / API 30 x86, revision 16 |
| Virtualization | KVM, headless official Android Emulator 37.1.11 |
| Guest architecture | `i686`; KOReader `ffi.arch == "x86"` |
| Android page size | 4096 bytes |
| SELinux | `Enforcing` |
| APK | Official `koreader-android-x86-v2026.07.1.apk` |
| APK version | `v2026.07.1`, versionCode `119463`, minSdk `18`, targetSdk `30` |
| APK SHA-256 | `3cd979cc6474308ce37c408a8753fce27898249599e6ec6875d34ecd9b3d4144` |
| Application | `org.koreader.launcher/.MainActivity` |
| Observed app UID | `10167` |
| Observed SELinux context | `u:r:untrusted_app:s0:c167,c256,c512,c768` |

The APK digest matched the official GitHub release's digest. Its five packaged
native libraries are ELF32 for x86, explaining why a separate `android-x86`
build is required even though an `android-x86_64` library also exists.
The APK was neither modified nor re-signed. The test granted its declared
all-files-access operation within the disposable emulator so it could read its
ordinary external plugin directory. No account login was performed.

The source APK is the
[official KOReader release asset](https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-android-x86-v2026.07.1.apk).
SDK/image checksums and the emulator setup are recorded in
`native-android-emulator-handoff.md` and its companion JSON files.

## Library identity

| Library | Bytes | SHA-256 |
| --- | --- | --- |
| `libbiliwasm.so`, Android x86 | 348004 | `e5241398edae74d2e7dd1eaa1be427e0771099a55339adaeec016f510c38ace4` |
| `libbilicrypto.so`, Android x86 | 75652 | `fcf59f168d51e12be9eddaed014ee447c12a399e1f42b22e53ff93b555486c94` |

Both are unchanged production artifacts built against NDK r27c / API 21.
The ordinary KOReader PluginLoader loads the research plugin from
`/storage/emulated/0/koreader/plugins/bili-native-probe.koplugin`.
The research scripts never log private-key material; the curve fixture uses
the public test scalar one.

## Direct external-directory failure

The initial research plugin calls `ffi.load` with absolute paths below its
external `native` subdirectory. Both calls fail before a callback runs:

```text
... is not accessible for the namespace "classloader-namespace"
```

The paths resolve below `/storage/emulated/0/koreader/plugins/`, and the calling
object is the official APK's `lib/x86/libluajit.so`. This was a real app-UID
call, not `adb shell` pretending to be the application. The raw result is
`native-android-external-plugin-result.json`.

External storage is separately observed to use FUSE with `noexec`. The actual
returned loader error is a namespace error; this investigation does not replace
that observed error with an inferred `mmap` error.

## Successful private-files route

The official APK's `assets/android.lua` initializes `android.dir` from Java
`Context.getFilesDir().getAbsolutePath()`. It is the private application files
directory, distinct from external `DataStorage:getDataDir()` and from the APK's
read-only `android.nativeLibraryDir`.

Observed paths and permissions:

```text
android.dir:
  /data/user/0/org.koreader.launcher/files

research staging directory, app UID 10167, mode 0700:
  /data/user/0/org.koreader.launcher/files/bili-native-probe

staged files, app UID 10167, mode 0600:
  .../bili-native-probe/libbiliwasm.so
  .../bili-native-probe/libbilicrypto.so
```

The application Lua code creates the directory, reads each already-verified
external library, writes a `.part` file, reads it back and compares every byte,
then atomically renames it to its final path. It subsequently calls `ffi.load`
on that private absolute path. It does not request executable file bits, remount
storage, alter SELinux, use a privileged app process, or modify the APK.
The official signing WASM stays in the external plugin directory because the
native interpreter only reads it as data.

The completed report contains seven successful checks:

1. Both copies pass byte comparison before atomic rename.
2. `libbiliwasm.so` loads from private files.
3. `libbilicrypto.so` loads from private files.
4. The official WASM deterministic signature matches the Node oracle.
5. The official WASM argument-count error matches the Node oracle.
6. FIPS AES-256 ECB encryption and decryption match the fixed vector.
7. P-256 public-key derivation and ECDH match the generator fixture.

The raw result is `native-android-private-plugin-result.json`. The executable
research plugin is `native-android-private-plugin-main.lua`; the direct-path
comparison is `native-android-plugin-main.lua`. The installer/launcher is
`native-android-run-probe.py`.

## Loading from a held descriptor

A third research variant opens each completed private library with
`O_RDONLY | O_NOFOLLOW | O_CLOEXEC`, loads `/proc/self/fd/<descriptor>` with
`ffi.load`, and closes the descriptor after that call returns. The official
APK permits this path, and the same seven checks all pass after the descriptors
have been closed. The linker resolves the descriptor to the permitted private
file. This offers a route to validate and load the same held inode without
reopening the original pathname between validation and loading.

`lfs.attributes("/proc/self/fd/<descriptor>")` returns the opened file's mode,
size, UID, permissions, inode, and device. Passing an `io.open` userdata directly
to `lfs.attributes` fails because this KOReader build expects a string path.
The raw observations are `native-android-fd-plugin-result.json`; the exact
research code is `native-android-fd-plugin-main.lua`.

The official NDK r27c's API 21 `fcntl.h` preprocessing yields these values:

| Android ABI | `O_NOFOLLOW` | `O_DIRECTORY` | `O_CLOEXEC` | `O_RDONLY` |
| --- | --- | --- | --- | --- |
| armv7 / aarch64 | 32768 | 16384 | 524288 | 0 |
| x86 / x86-64 | 131072 | 65536 | 524288 | 0 |

The successful descriptor experiment uses x86. The Android ARM constants were
obtained from the matching official target headers, not assumed from x86 or a
generic Linux header.

## Synthetic storage-permission comparison

A follow-up requested by the parent task creates only a synthetic text file in
each directory, using `open(..., 0600)`. It records file and descriptor-path
attributes, calls `fchmod(0600)`, `chmod(0400)`, and `chmod(0600)`, and then
deletes both synthetic files. It never reads or writes a real account/session
file.

| Observation | Shared `DataStorage` | Private `android.dir` |
| --- | --- | --- |
| Calling app UID | 10167 | 10167 |
| Observed file UID/GID | 10161 / 10161 | 10167 / 10167 |
| Mode after requested `open(0600)` | 0600 | 0600 |
| `fchmod(0600)` return | 0 | 0 |
| `chmod(0400)` return | 0 | 0 |
| Actual mode after `chmod(0400)` | **0600, unchanged** | **0400** |
| Mode after restoring `chmod(0600)` | 0600 | 0600 |
| Synthetic file removed | Yes | Yes |

Both directories report 0700, but the shared FUSE directory also reports UID
10161 while the private directory reports the calling app's UID 10167.
The application can create, read, and write the shared file despite its
different reported owner. These observations demonstrate that the shared
storage's displayed mode and successful `chmod` return are not a proof of
ordinary exclusive Unix file permissions. The private-files directory obeys
the requested mode changes in this test.

The evidence supports placing Android session material in the app-private
directory rather than claiming confidentiality solely from `open(0600)` below
shared `DataStorage`. It does not measure other applications' access and should
not be described as such an access test. Source and raw results are
`native-android-storage-plugin-main.lua` and
`native-android-storage-permission-result.json`.

## Verified production integration

The parent task added `bilicomics/protocol/native_library.lua`, shared by the
production `native_backend.lua` and `portable_crypto.lua`. It selects the
packaged ABI, validates manifest size/digest, traverses app-private directories
with held descriptors, copies and verifies before atomic commit, and loads the
verified private file through `/proc/self/fd/<descriptor>`. Its paths include
ABI and content digest. The packaged libraries are unchanged; only their
executable loading location changes.

The real production modules were copied into the external research plugin and
required normally by the official APK. The harness does not replace or copy
the loader implementation. The final module serializes publication with a
version-directory `flock` and retains each successfully loaded library's
descriptor with its cached handle. A renewed cold-publication run and an app
restart with existing cache files pass these seven checks:

1. Production capabilities select `android-x86` and report both backends present.
2. `Backend:signRequest` matches the official deterministic signing oracle.
3. `PortableCrypto` passes AES-256 ECB encryption and decryption vectors.
4. `Backend:prepareTokens` plus `ECDH.deriveSecret` produce matching independent
   P-256 shared secrets, without recording any private key or secret.
5. `Backend:convertImage` produces all 49,363 expected PNG bytes for the official
   v8 synthetic fixture, using an explicitly offline synthetic transport.
6. The production loader's returned digest-specific paths belong to app UID
   10167, with regular single-link files and mode 0600.
7. Each library has exactly one retained descriptor, with distinct numbers
   78 and 79. Forty further cached load calls leave both descriptor sets and
   the total observed process descriptor count unchanged at 77.

The tested production loader SHA-256 is
`91f39552b34b546d4b1605d69186d2f28eaa7539797f7fee51b6b1606008190f`.
The complete loaded-source paths and seven module hashes are in
`native-android-production-final-cold-result.json` and
`native-android-production-final-reuse-result.json`. The earlier six-check
implementation results remain in `native-android-production-result.json` and
`native-android-production-first-result.json` for traceability. The harness is
`native-android-production-plugin-main.lua`, invoked by the same runner with
`BILI_NATIVE_PROBE_VARIANT=production` and explicit cold/reuse cache modes.

The cold reset removes only the two known content-digest native-library files
inside the app's private native cache. It does not remove or inspect account
storage. The final retest was serialized with the account-storage and jobs
probes using the shared emulator's explicit task handoff and a host operation
lock. The successful retained-descriptor behavior is observed on API 30;
API 21/22 compatibility is still a separate runtime claim.

This is API 30 x86 emulator execution evidence. It does not establish physical
ARM-device behavior, Android API 21 runtime behavior, 16 KiB-device execution,
or every encrypted-image format in the production capability list. The actual
APK image transformation here covers v8. Other platform and format claims
require their own evidence. The emulator remains available for the separately
coordinated synthetic account-storage integration checks.
