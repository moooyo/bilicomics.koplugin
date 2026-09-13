#!/bin/sh
set -eu

# Dependencies must be checked out at the revisions documented in README.md.
# Run this build on test-env or an explicitly authorized target build host.
: "${WASM3_ROOT:?Set WASM3_ROOT to the pinned wasm3 checkout}"
: "${CJSON_ROOT:?Set CJSON_ROOT to the cJSON v1.7.19 checkout}"
CC=${CC:-cc}
OUTPUT=${OUTPUT:-biliwasm}
TARGET=${TARGET:-executable}
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "$TARGET" in
    executable) TARGET_FLAGS=""; set -- ;;
    shared)
        TARGET_FLAGS="-shared -fPIC -DBILIWASM_NO_MAIN -Wl,-z,defs"
        set -- "-Wl,--version-script=$SOURCE_DIR/biliwasm.exports.map"
        ;;
    *) printf '%s\n' "Unsupported TARGET: $TARGET" >&2; exit 1 ;;
esac

if [ "$TARGET" = shared ]; then
    # Old glibc ARM loaders require adjacent dynamic and PLT REL tables.
    # shellcheck disable=SC2086
    bili_target_macros=$("$CC" ${CFLAGS:-} -dM -E -x c /dev/null)
    if printf '%s\n' "$bili_target_macros" | grep -q '^#define __arm__ ' \
        && printf '%s\n' "$bili_target_macros" | grep -q '^#define __linux__ ' \
        && ! printf '%s\n' "$bili_target_macros" | grep -q '^#define __ANDROID__ '; then
        set -- "$@" "-Wl,-T,$SOURCE_DIR/arm-relocations.ld" "-Wl,-z,relro,-z,now"
    fi
fi

# shellcheck disable=SC2086
"$CC" -std=c99 -O2 -fvisibility=hidden $TARGET_FLAGS ${CFLAGS:-} \
    -Dd_m3GuardedMemory=0 -Dd_m3MaxLinearMemoryPages=1024 \
    -I"$WASM3_ROOT/source" -I"$CJSON_ROOT" \
    "$SOURCE_DIR/biliwasm.c" "$CJSON_ROOT/cJSON.c" \
    "$WASM3_ROOT/source/m3_bind.c" \
    "$WASM3_ROOT/source/m3_code.c" \
    "$WASM3_ROOT/source/m3_compile.c" \
    "$WASM3_ROOT/source/m3_core.c" \
    "$WASM3_ROOT/source/m3_deterministic.c" \
    "$WASM3_ROOT/source/m3_env.c" \
    "$WASM3_ROOT/source/m3_exec.c" \
    "$WASM3_ROOT/source/m3_function.c" \
    "$WASM3_ROOT/source/m3_info.c" \
    "$WASM3_ROOT/source/m3_module.c" \
    "$WASM3_ROOT/source/m3_parse.c" \
    "$WASM3_ROOT/source/m3_validate.c" \
    "$@" ${LDFLAGS:-} -lm -o "$OUTPUT"
