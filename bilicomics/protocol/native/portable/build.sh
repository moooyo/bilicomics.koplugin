#!/bin/sh
set -eu

# Build only on test-env or an explicitly authorized build host.
CC=${CC:-cc}
OUTPUT=${OUTPUT:-libbilicrypto.so}
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEPENDENCY_DIR=${DEPENDENCY_DIR:-"$SOURCE_DIR/../legacy_v5"}
set --
while IFS= read -r source || [ -n "$source" ]; do
    set -- "$@" "$DEPENDENCY_DIR/$source"
done < "$DEPENDENCY_DIR/sources.list"

# Keep Linux ARM32 REL tables adjacent for glibc versions affected by BZ 14341.
# shellcheck disable=SC2086
bili_target_macros=$("$CC" ${CFLAGS:-} -dM -E -x c /dev/null)
if printf '%s\n' "$bili_target_macros" | grep -q '^#define __arm__ ' \
    && printf '%s\n' "$bili_target_macros" | grep -q '^#define __linux__ ' \
    && ! printf '%s\n' "$bili_target_macros" | grep -q '^#define __ANDROID__ '; then
    set -- "$@" "-Wl,-T,$SOURCE_DIR/../arm-relocations.ld"
fi

# The pinned Mbed TLS configuration enables only the required primitive modules.
# No platform OpenSSL, TLS stack, certificates, or runtime download is involved.
# shellcheck disable=SC2086
"$CC" -std=c99 -O2 -g0 -D_GNU_SOURCE -fPIC -shared -fvisibility=hidden \
    -ffunction-sections -fdata-sections -fstack-protector-strong \
    '-DMBEDTLS_CONFIG_FILE="bili_mbedtls_config.h"' \
    -I"$SOURCE_DIR" -I"$DEPENDENCY_DIR" \
    -I"$DEPENDENCY_DIR/vendor/mbedtls/include" -I"$DEPENDENCY_DIR/vendor/mbedtls/library" \
    ${CFLAGS:-} "$SOURCE_DIR/bilicrypto.c" "$@" \
    -Wl,--gc-sections -Wl,-s -Wl,-z,defs -Wl,-z,relro,-z,now \
    "-Wl,--version-script=$SOURCE_DIR/bilicrypto.exports.map" \
    ${LDFLAGS:-} -o "$OUTPUT"
