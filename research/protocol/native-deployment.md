# Native wasm3 deployment for KOReader

Research date: 2026-09-12.

This document reviews source portability and build inputs. It does not establish successful execution on an Android, Kobo, Kindle, PocketBook, or other ARM device. No local build, test, validation suite, or runtime probe was performed. Source inspection and the isolated Zig verification recorded below ran through `ssh test-env`. The illustrative CMake recipes were not executed.

## Decision

wasm3 is a plausible native interpreter for the pinned Go/js WebAssembly modules. Its interpreter is C99, supports both 32-bit and 64-bit ARM, and does not require a JIT or executable guest-memory allocation. The missing Go/js imports still require the custom host: enabling WASI does not implement `gojs` or `syscall/js`.

The current `bilicomics/protocol/native/biliwasm.c` implements both a process-per-request CLI and a shared C ABI, `biliwasm_run` / `biliwasm_free`. Each API invocation creates and releases an independent host/runtime; the caller releases its returned JSON with `biliwasm_free`. The shared interface is implemented, but Android target-device loading remains unverified. The CLI is suitable for supported Linux devices; the shared interface fits Android LuaJIT FFI more directly.

Recommended initial configuration:

- Pin wasm3 to the exact commit below.
- Build with optimization, a target-specific toolchain, `BUILD_NATIVE=OFF`, and `BUILD_WASI=none`.
- Set `d_m3GuardedMemory=0` explicitly in both wasm3 and its host.
- Keep validation, memory bounds checks, stack checks, and floating-point support enabled.
- Target Android API 21 or later. The selected NDK r27c build requires the ARM32 `M3_HAS_TAIL_CALL=0` fallback; r29 is the upstream option for guaranteed ARM32 dispatch tail calls.
- Treat each Linux device ABI and libc baseline as a separate output. An arbitrary `arm-linux-gnueabihf` binary is not a universal KOReader binary.

## Inspected upstream snapshot

The remote checkout at `/tmp/bili-native-protocol-20260912/wasm3` had origin `https://github.com/wasm3/wasm3.git` and HEAD `5fe766c933c7595d728d6172bb1a197607d85b4e`, authored on 2026-09-10. The checkout is a development snapshot, not a claim that an older tagged wasm3 release has the same API or features.

The project uses the MIT license. Distributions containing the interpreter must retain its copyright and permission notice. Its README still describes a minimal-maintenance phase; release planning should use the pinned source and project-owned compatibility evidence, not an assumption of future upstream maintenance. Sources: [pinned license](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/LICENSE), [pinned README](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/README.md).

Current API examples must come from that same commit. In particular, `m3_GetMemory` now takes `IM3Module`, `size_t *`, and a memory index; examples using an `IM3Runtime` first argument are obsolete for this snapshot. Also, `m3_LoadModule` transfers ownership to the runtime even on an instantiation error, so an error path must not separately free that module and then free its runtime. Sources: [wasm3.h](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/source/wasm3.h), [m3_LoadModule ownership](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/source/m3_env.c#L1338).

## Core compilation and dependencies

The authoritative static-library source list contains these 17 translation units:

```text
m3_api_libc.c
m3_api_wasi.c
m3_api_uvwasi.c
m3_api_meta_wasi.c
m3_api_tracer.c
m3_bind.c
m3_code.c
m3_compile.c
m3_core.c
m3_deterministic.c
m3_env.c
m3_exec.c
m3_function.c
m3_info.c
m3_module.c
m3_parse.c
m3_validate.c
```

Use the entire matching `source` directory for headers as well. `m3_host_posix.h` is included by `m3_core.c`; it is not a separate compilation unit. Do not reuse an old wasm3 source list that omits `m3_deterministic.c` or `m3_validate.c`. Source: [source/CMakeLists.txt](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/source/CMakeLists.txt).

The repository's maintained `bilicomics/protocol/native/build.sh` uses the 12 core units and omits the five optional `m3_api_*` wrappers, which the custom Go/js host does not call. It currently sets `d_m3MaxLinearMemoryPages=1024`, a 64 MiB per-memory ceiling; the template below preserves that setting.

The native core needs the target C library and math library. The supplied Go/js host additionally uses cJSON, which must have its own pinned source, include path, and license notice. Its `clock_gettime` calls require `-lrt` on Linux with glibc before 2.17; Android provides these through Bionic. A C ABI consumed with `ffi.cdef` does not require the Lua headers or a Lua C-module entry point. Limit the shared library's public symbols to its host API when packaging. Source: [clock_gettime library requirements](https://man7.org/linux/man-pages/man3/clock_gettime.3.html).

The top-level wasm3 CMake project defaults to `uvwasi`, fetching libuv and uvwasi. Pass `BUILD_WASI=none` to avoid both. Do not define `d_m3HasWASI=0`: its source uses `#if defined(d_m3HasWASI)`, so even a zero definition enables that path. The same caution applies to the other WASI selection macros. The CMake project also defaults to host-native optimization; cross builds need `BUILD_NATIVE=OFF` to prevent inappropriate `-march=native`. Source: [top-level CMakeLists.txt](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/CMakeLists.txt).

With guarded memory disabled, the native core does not need a separate pthread dependency by default on older glibc: its thread-stack probe is disabled there. On Android and musl, pthread support is in the C library. If a build explicitly enables `d_m3HasThreadStackProbe=1` with glibc older than 2.34, link the appropriate pthread library. Source: [m3_host_posix.h](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/source/m3_host_posix.h).

Actual ELF dependencies take precedence over that general source expectation. All three Zig-built glibc artifacts below have a `DT_NEEDED` entry for `libpthread.so.0`.

### Reusable embedding CMake template

The following template builds the core and shared host library without pulling the upstream CLI, WASI implementations, libuv, or uvwasi into the application. Set `BILI_BUILD_SHARED=OFF` for the CLI. Save it as the build project's `CMakeLists.txt`. Provide absolute paths to the pinned wasm3, cJSON, and host sources. This is a recipe, not a second build file maintained by this repository.

```cmake
cmake_minimum_required(VERSION 3.16)
project(biliwasm_native C)

set(WASM3_ROOT "" CACHE PATH "Pinned wasm3 checkout")
set(CJSON_ROOT "" CACHE PATH "Pinned cJSON checkout")
set(BILI_HOST_SOURCE "" CACHE FILEPATH "biliwasm.c source file")
option(BILI_BUILD_SHARED "Build the LuaJIT FFI library" ON)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(BUILD_WASI none)
add_subdirectory("${WASM3_ROOT}/source" "${CMAKE_BINARY_DIR}/wasm3")
target_compile_definitions(m3 PUBLIC
    d_m3GuardedMemory=0
    d_m3MaxLinearMemoryPages=1024)

if(BILI_BUILD_SHARED)
    add_library(biliwasm SHARED
        "${BILI_HOST_SOURCE}"
        "${CJSON_ROOT}/cJSON.c")
    target_compile_definitions(biliwasm PRIVATE BILIWASM_NO_MAIN=1)
    get_filename_component(BILI_HOST_DIR "${BILI_HOST_SOURCE}" DIRECTORY)
    target_link_options(biliwasm PRIVATE
        "-Wl,--version-script=${BILI_HOST_DIR}/biliwasm.exports.map")
else()
    add_executable(biliwasm
        "${BILI_HOST_SOURCE}"
        "${CJSON_ROOT}/cJSON.c")
endif()
target_include_directories(biliwasm PRIVATE "${CJSON_ROOT}")
target_link_libraries(biliwasm PRIVATE m3 m)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND NOT ANDROID)
    target_link_libraries(biliwasm PRIVATE rt)
endif()

if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(m3 PRIVATE -O3 -fvisibility=hidden)
    target_compile_options(biliwasm PRIVATE -O3 -fvisibility=hidden)
    target_link_options(biliwasm PRIVATE -Wl,-z,defs)
endif()
```

`add_subdirectory(source)` reuses the exact upstream list. The `PUBLIC` definition propagates the guarded-memory setting to the host. The template does not activate upstream host-native optimization. `BILIWASM_NO_MAIN` selects the implemented shared ABI, whose failure paths return to the caller. Calls must be serialized as required by `biliwasm.h`; a separate runtime per call is not a promise that the library's dependencies are safe for concurrent invocation.

## Android ARM32, ARM64, and x86_64

The inspected official Android example pins NDK `29.0.14206865`. Its build file explicitly states that r29, using Clang 21, is the first NDK that can tail-call this interpreter's dispatch on `armeabi-v7a`; earlier NDKs produce a `musttail` compilation error for that architecture. The Android README's statement that the NDK is unpinned is stale relative to `app/build.gradle`. Source: [official Android build file](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/platforms/android/app/build.gradle).

| Output | NDK ABI | Compiler target for API 21 |
| --- | --- | --- |
| Android ARM32 | `armeabi-v7a` | `armv7a-linux-androideabi21` |
| Android ARM64 | `arm64-v8a` | `aarch64-linux-android21` |
| Android x86_64 | `x86_64` | `x86_64-linux-android21` |

These target names follow the [NDK toolchain guide](https://developer.android.com/ndk/guides/other_build_systems). Let the NDK CMake toolchain choose ABI flags and sysroot; do not apply a Linux glibc cross-toolchain to Android.

For example, after placing the template and its inputs on `test-env`, these PowerShell commands configure and build the ARM64 artifact remotely. The `/opt` and project paths are explicit example installation paths that must match the actual remote layout:

```powershell
ssh test-env 'cmake -S /tmp/bili-native-build -B /tmp/bili-native-build/out/android-arm64 -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=/opt/android-ndk-r29/build/cmake/android.toolchain.cmake -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-21 -DWASM3_ROOT=/tmp/bili-native-protocol-20260912/wasm3 -DCJSON_ROOT=/tmp/bili-native-build/cJSON -DBILI_HOST_SOURCE=/tmp/bili-native-build/biliwasm.c'
ssh test-env 'cmake --build /tmp/bili-native-build/out/android-arm64 --parallel'
```

For ARM32, use a separate output directory and `-DANDROID_ABI=armeabi-v7a`. The default output is `libbiliwasm.so`. The commands establish a build recipe, not evidence that this library can be loaded from a particular Android plugin directory.

An older compiler can be made to avoid the hard `musttail` requirement with `M3_HAS_TAIL_CALL=0`, but this changes dispatch behavior and native-stack consumption. It is an unverified compatibility experiment, not an equivalent production configuration. Do not force `d_m3CanTailCall=1` without a compiler/target guarantee. Source: [m3_config_platforms.h](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/source/m3_config_platforms.h).

KOReader's inspected base snapshot `dd0e2522a1c2535c49b69f151a65fd506663c3a7` defaults to NDK r23c, API 18 for 32-bit Android, and API 21 for 64-bit Android. The launcher's current build settings also declare `minSdk=18` and `targetSdk=30`. NDK r24 removed API 16-18 support and r26 removed API 19-20 support, so the r29 recipe cannot preserve KOReader's full old-Android range. Sources: [KOReader-base Makefile.defs](https://github.com/koreader/koreader-base/blob/dd0e2522a1c2535c49b69f151a65fd506663c3a7/Makefile.defs), [launcher settings](https://github.com/koreader/android-luajit-launcher/blob/master/build.gradle), [NDK revision history](https://developer.android.com/ndk/downloads/revision_history).

NDK r28 and later provide 16 KiB ELF alignment by default for the `.so`. APK packaging and every packaged dependency must also support the page size; a successful 4 KiB-device load is insufficient evidence. Source: [Android page-size guidance](https://developer.android.com/guide/practices/page-sizes).

### Selected NDK r27c API 21 build

The selected compatibility build uses official NDK r27c, installed only in the remote isolated directory `/var/tmp/bili-android-ndk-20260912/android-ndk-r27c`. Its inspected `source.properties` identifies version `27.2.12479018`, and `meta/platforms.json` declares a minimum platform of 21. The r27c release uses Android LLVM revision `clang-r522817c`. Source: [official r27 changelog](https://github.com/android/ndk/wiki/Changelog-r27#r27c).

The three native builds completed with NDK r27c / Clang 18.0.3. Their status is `built_only`: compilation and ELF inspection passed, but no Android application-process loading or execution result has been established for these three ABI artifacts.

| ABI | Bytes | SHA-256 prefix |
| --- | ---: | --- |
| `arm64-v8a` | 310,808 | `ca890ba1e7e00655` |
| `armeabi-v7a` | 313,396 | `45961992fc646cbf` |
| `x86_64` | 308,288 | `5a0a4ab94c9faa3e` |

Each output has SONAME `libbiliwasm.so`, exactly the two public API exports, four load segments aligned to 16,384 bytes, and no native TLS segment. Their exact `DT_NEEDED` list is `libm.so`, `libdl.so`, and `libc.so`. The Android identity notes record API 21. Full evidence is in `/var/tmp/bili-android-ndk-20260912/host-build/android-build-results.json` on `test-env`.

Use the NDK's API-suffixed Clang entry points under `toolchains/llvm/prebuilt/linux-x86_64/bin`, or equivalent one-executable wrappers around `clang --target=<target>`. Preserve the existing shared build's PIC, symbol visibility, export map, unresolved-symbol rejection, ordinary memory bounds checks, and 64 MiB linear-memory ceiling. Additional target settings are:

| ABI | CC entry point | Additional CFLAGS |
| --- | --- | --- |
| `arm64-v8a` | `aarch64-linux-android21-clang` | None |
| `armeabi-v7a` | `armv7a-linux-androideabi21-clang` | `-DM3_HAS_TAIL_CALL=0` |
| `x86_64` | `x86_64-linux-android21-clang` | None |

The ARM32 fallback avoids the older compiler's hard `musttail` error. It does not establish the same dispatch behavior or performance as the upstream r29 configuration. Do not add `d_m3CanTailCall=1`, host-native CPU flags, or a Linux hard-float target triple to an Android build.

For r27c, add both `-Wl,-z,max-page-size=16384` and `-Wl,-z,common-page-size=16384`. The first controls load-segment alignment; the second matters to the layout of the protected relocation region. Check each `PT_LOAD` alignment and that the end of `PT_GNU_RELRO` is 16 KiB aligned. These ELF properties do not establish APK ZIP alignment or a working 16 KiB device session. Source: [r27-and-earlier page-size settings](https://developer.android.com/guide/practices/page-sizes#compile-r27-lower).

Also set an explicit stable SONAME, for example `-Wl,-soname,libbiliwasm.so`. NDK CMake and ndk-build normally add one, but this repository invokes the compiler directly. The Android loader's documented SONAME requirements apply independently of the output file's path. Preserve the API 21 driver's default relocation and hash settings; do not opt into newer packed-relocation/RELR formats merely to reduce library size. Source: [Bionic changes for native developers](https://android.googlesource.com/platform/bionic/+/refs/heads/main/android-changes-for-ndk-developers.md).

`active_job` and wasm3 use C thread-local storage. At API 21, NDK r27c selects compiler-runtime emulated TLS automatically; ELF TLS only becomes the default when targeting API 29 or later. Do not force `-fno-emulated-tls` or an initial-exec TLS model. The emulated implementation uses Bionic pthread keys, and the compiler driver supplies its runtime support. Keep compiler-runtime implementation symbols private through `biliwasm.exports.map`, and verify that only `biliwasm_run` and `biliwasm_free` are defined dynamic exports. Source: [Bionic TLS availability](https://android.googlesource.com/platform/bionic/+/refs/heads/main/android-changes-for-ndk-developers.md#elf-tls-available-for-api-level-29).

The current native host and wasm3 POSIX implementation need Bionic C/POSIX facilities and `libm`. API 21's NDK `aarch64-linux-android/21/libc.so` stub was inspected and contains `clock_gettime`, `nanosleep`, `pthread_getattr_np`, `pthread_attr_getstack`, `pthread_key_create`, `pthread_getspecific`, `pthread_setspecific`, `strnlen`, `syscall`, `mmap`, and `flock`. The matching Android 5.0 headers also declare the required clock and pthread interfaces. Sources: [Android 5.0 pthread header](https://android.googlesource.com/platform/bionic/+/android-5.0.0_r1/libc/include/pthread.h), [Android 5.0 time header](https://android.googlesource.com/platform/bionic/+/android-5.0.0_r1/libc/include/time.h).

There is no separate Bionic `libpthread` or `librt` requirement, and this pure C FFI interface does not require JNI, `libandroid`, `liblog`, or `libc++_shared`. Exact `DT_NEEDED` entries must still come from the finished artifacts: the NDK driver may add a public system library such as `libdl`. A glibc dependency, `libpthread.so.0`, a host filesystem path in `DT_NEEDED`, or unresolved compiler-runtime TLS support would be a build defect. API 21 is the minimum declared Android OS version for this build, not evidence that KOReader's API 18 installation range is covered.

### Android loading is a separate delivery requirement

KOReader's `ffi.loadlib` searches `android.nativeLibraryDir` on Android. A library placed only in the plugin's directory is not discovered through that helper. An explicit `ffi.load(absolute_path)` can express the intended file, but whether that path permits executable mappings and is permitted by the Android linker/SELinux policy still needs target-device evidence. APK-native-library packaging is the official packaged-code path. Source: [KOReader library loader](https://github.com/koreader/koreader-base/blob/master/ffi/loadlib.lua).

Android 10 blocks `execve` of files in an untrusted application's writable home directory for apps targeting Android 10, and the official guidance says executable code should be embedded in the APK. The current launcher's target SDK makes this directly relevant to a downloaded CLI helper. Neither a shell wrapper nor `chmod` establishes a supported deployment method. Source: [Android 10 executable-code restrictions](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission).

Consequently, the CLI must not be advertised as the Android route. The implemented shared ABI still needs a demonstrated loading route on an actual Android target, or explicit unsupported-platform reporting where loading fails.

## Linux ARM deployment

wasm3's checked-in cross matrix covers ARMv6 hard float, ARMv7 hard float, ARM soft float, and AArch64, with QEMU runners. This establishes upstream build/test intent, not this plugin's pass result or target firmware compatibility. Source: [build-cross.py](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/build-cross.py).

Use the matching KOReader cross-toolchain and compiler sysroot. Important distinctions include ARM generation, hard/soft float calling convention, libc family and symbol baseline, and ELF interpreter availability. The [KOReader toolchain project](https://github.com/koreader/koxtoolchain) documents platform-specific toolchains, including different Kindle generations and different Kobo firmware baselines. Its reference script configures the environment for those toolchains.

For an illustrative Kobo build of the template, use a compiler actually installed for that target; the following paths assume a toolchain rooted at `/opt/x-tools`:

```powershell
ssh test-env 'cmake -S /tmp/bili-native-build -B /tmp/bili-native-build/out/kobo -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm -DCMAKE_C_COMPILER=/opt/x-tools/arm-kobo-linux-gnueabihf/bin/arm-kobo-linux-gnueabihf-gcc -DCMAKE_C_FLAGS=-mfloat-abi=hard -DCMAKE_BUILD_TYPE=Release -DWASM3_ROOT=/tmp/bili-native-protocol-20260912/wasm3 -DCJSON_ROOT=/tmp/bili-native-build/cJSON -DBILI_HOST_SOURCE=/tmp/bili-native-build/biliwasm.c'
ssh test-env 'cmake --build /tmp/bili-native-build/out/kobo --parallel'
```

Add the selected target's architecture flags from KOReader's `Makefile.defs`, or use the corresponding toolchain's configured environment. For example, that snapshot's Kobo target uses ARMv7-A/Cortex-A8, NEON, Thumb, and hard float. Do not reuse those flags for legacy Kindle or soft-float PocketBook targets. The recipe's compiler is an example installation, not evidence that this toolchain exists on `test-env`.

A static musl CLI may avoid glibc version dependencies, but it still needs the correct instruction set, kernel/system-call baseline, executable location, and process-launch integration. A musl-built shared library is not a drop-in replacement for a glibc or Bionic library inside KOReader. Do not use upstream static CLI assets as a shared-library deployment shortcut.

## WebAssembly and embedding risks

The current snapshot implements the common scalar instruction set, bulk memory, sign extension, multi-value, reference types, multiple memories, memory64, and exception handling. Typed references are incomplete and off by default. Fixed-width SIMD, garbage collection, stack switching, and threads/atomics are not implemented. The interpreter's source-supported feature set is broader than old wasm3 release descriptions, but the exact two application modules still need parse, link, execution, and output-comparison evidence. Sources: [feature summary](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/README.md), [configuration](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/source/m3_config.h).

The Go/js ABI is the larger integration risk. The custom host must supply correct value boxing, Go stack-slot layout, strings and byte arrays, entropy, clocks, callback/resume behavior, and every import reached by the pinned modules. A module parsing or registering its exported functions is not enough to establish equivalence to the browser runtime. Every upstream WASM replacement needs an import/feature review and fixed-input comparisons before adoption.

On Linux/Android AArch64, this wasm3 snapshot enables guarded memory automatically. Each memory slot reserves 8 GiB of virtual address space; 128 slots are the default, and the arena is shared without internal locking. POSIX fault handling is installed to turn memory faults into traps. Disabling guarded memory avoids these process-wide signal and large-address-reservation concerns during first KOReader integration. It leaves ordinary bounds checks enabled. This is especially useful when the host is later moved into KOReader's process. Sources: [platform defaults](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/source/m3_config_platforms.h), [guard allocation](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/source/m3_core.c), [POSIX handling](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/source/m3_host_posix.h).

With guarded memory off, linear-memory growth can reallocate the backing buffer. Host code must reacquire memory after guest execution or growth and validate offsets against its current length. The runtime's memory limit covers linear memory, not its full process footprint, Go/js object allocations, interpreter code pages, JSON copies, or image data. A 32-bit process also cannot realize the apparent 4 GiB Wasm32 range; the allocator explicitly checks `SIZE_MAX`. Source: [m3_env.c](https://github.com/wasm3/wasm3/blob/5fe766c933c7595d728d6172bb1a197607d85b4e/source/m3_env.c).

Do not enable the deterministic profile for production protocol entropy: it substitutes deterministic entropy and clocks for WASI. A custom Go/js host still owns its own entropy and clock behavior independently. Likewise, gas accounting cannot interrupt a blocking host function or account for all host allocations. Runtime limits and cancellation must include the host interface, with expensive work kept out of the native reader's UI path.

## Executed isolated Zig verification

On 2026-09-12, Zig 0.13.0 was downloaded from the URL in the [official release index](https://ziglang.org/download/index.json), into `/tmp/bili-native-protocol-20260912/zig` on `test-env`. Its `zig-linux-x86_64-0.13.0.tar.xz` archive was 47,082,308 bytes and matched the index's SHA-256, `d45312e61ebcc48032b77bc4cf7fd6915c11fa16e4aad116b66c9468211230ea`, before extraction. Nothing was installed globally.

The final source, header, maintained `build.sh`, and export map were copied together into `zig-build/source`. Each target used its own executable CC wrapper because `build.sh` treats `CC` as one executable path. The shared-library builds used these targets:

| Artifact | Zig target | Bytes | SHA-256 prefix |
| --- | --- | ---: | --- |
| `libbiliwasm-x86_64-baseline.so` | `x86_64-linux-gnu.2.17` | 1,168,744 | `00f3200a8e276ea8` |
| `libbiliwasm-armhf.so` | `arm-linux-gnueabihf.2.17` | 1,717,544 | `df3bb13afbc85a79` |
| `libbiliwasm-aarch64.so` | `aarch64-linux-gnu.2.17` | 1,252,264 | `989a95fa445482e7` |

ARM32 additionally used `CFLAGS=-DM3_HAS_TAIL_CALL=0`. All targets used the maintained shared build with `-fvisibility=hidden`, `-Wl,-z,defs`, `d_m3GuardedMemory=0`, and the 64 MiB linear-memory ceiling. Zig caches and wrappers stayed under `zig-build`; the pre-existing `libbiliwasm.so` was not replaced by this work.

An initial ARM32 build exposed hundreds of symbols from Zig's compiler runtime despite hidden visibility on the application's C sources. The maintained export map now makes every symbol local except `biliwasm_run` and `biliwasm_free`. Final `nm -D --defined-only` inspection found exactly those two exports on all three artifacts, and all build logs were empty.

ELF inspection found a maximum required GLIBC symbol version of 2.17 for each artifact. ARM32 is ELF32, ARM EABI5, hard-float, with `Tag_CPU_arch: v6`; AArch64 is ELF64. All three depend on `libc.so.6`, `libm.so.6`, and `libpthread.so.0`. The x86_64 and ARM32 libraries also name `ld-linux-x86-64.so.2` and `ld-linux-armhf.so.3`, respectively. These Linux glibc artifacts are not Android Bionic binaries, and the glibc 2.17 target does not cover firmware with an older libc baseline.

The final x86_64 shared library passed seven fixed expected-output cases, seven comparisons with the existing CLI, seven host-failure cases, and 100 repeated FFI calls. Measured resident memory was 31,340 KiB before the repeat loop and 31,344 KiB afterward. The suite completed in 2.936 seconds on the remote host.

The same shared library also matched the official Go/Node decoder for four synthetic plaintext payloads, approximately 32 KiB, 256 KiB, 1 MiB, and 3 MiB. Measured call times were 61, 102, 257, and 638 milliseconds. Those times include launching a Python FFI adapter: the large-input runner normally launches a CLI, so an isolated adapter was used to ensure this check exercised the new baseline `.so`. They are remote-host observations, not ARM-device performance estimates.

The x86_64 run demonstrates loading and execution on the actual `test-env` host with GLIBC symbol requirements bounded at 2.17; it was not a separate runtime trial on an operating system carrying glibc 2.17 itself. The ARM artifacts were cross-compiled and inspected only, without QEMU or target-device execution.

Full target settings, source hashes, artifact hashes, compiler logs, ELF output, and results are preserved on `test-env` under `/tmp/bili-native-protocol-20260912/zig-build`, principally `targets.json`, `input-sha256.json`, `build-results.json`, `elf-summary.json`, `x86_64-baseline.verify.json`, and `x86_64-baseline.large-verify.json`.

## Remaining verification evidence

Required verification belongs on `test-env` or actual target devices, not on the local Windows machine:

1. Build the pinned host and interpreter with each selected toolchain, recording versions and complete effective flags.
2. Inspect the resulting ELF machine, ABI attributes, interpreter, dynamic dependencies, minimum imported symbol versions, and Android segment alignment.
3. Run the pinned modules through the host and compare deterministic operations against the official Go/js reference runtime using fixed test inputs.
4. Exercise malformed input, import failures, guest memory growth, repeated requests, memory/resource limits, and process or shared-library cleanup.
5. Demonstrate the actual KOReader launch/loading route on each claimed platform. Measure responsiveness and peak resident memory on representative ARM hardware.

The source review found no general ARM portability blocker in the interpreter. Android execution packaging, old-Android compiler compatibility, and complete Go/js host behavior remain independent release requirements.
