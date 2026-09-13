#!/bin/sh
set -eu

# Run on the authorized remote build host with the verified NDK r27c.
: "${NDK_ROOT:?Set NDK_ROOT to the verified Android NDK r27c directory}"
: "${WASM3_ROOT:?Set WASM3_ROOT to the pinned wasm3 checkout}"
: "${CJSON_ROOT:?Set CJSON_ROOT to the pinned cJSON checkout}"
ANDROID_API=${ANDROID_API:-21}
case "$ANDROID_API" in
    ''|*[!0-9]*) printf '%s\n' "ANDROID_API must be an integer" >&2; exit 1 ;;
esac
if [ "$ANDROID_API" -lt 21 ]; then
    printf '%s\n' "This build requires Android API 21 or newer" >&2
    exit 1
fi
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_ROOT=${OUTPUT_ROOT:-"$SOURCE_DIR/bin"}
TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"

build_one() {
    platform=$1
    compiler=$2
    target_cflags=$3
    mkdir -p "$OUTPUT_ROOT/$platform"
    CC="$TOOLCHAIN/$compiler" TARGET=shared \
        OUTPUT="$OUTPUT_ROOT/$platform/libbiliwasm.so" \
        CFLAGS="${CFLAGS:-} $target_cflags" \
        LDFLAGS="${LDFLAGS:-} -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -Wl,-soname,libbiliwasm.so" \
        sh "$SOURCE_DIR/build.sh"
}

build_one android-arm64-v8a "aarch64-linux-android${ANDROID_API}-clang" ""
# The pinned interpreter's ARM32 musttail dispatch requires a newer compiler.
build_one android-armeabi-v7a "armv7a-linux-androideabi${ANDROID_API}-clang" "-DM3_HAS_TAIL_CALL=0"
build_one android-x86_64 "x86_64-linux-android${ANDROID_API}-clang" ""
# Official KOReader x86 APKs contain a 32-bit process.
build_one android-x86 "i686-linux-android${ANDROID_API}-clang" ""
