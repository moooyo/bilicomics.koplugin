#!/bin/sh
set -eu

# This standalone build is for test-env or an explicitly authorized build host.
# Production packaging links sources.list into the portable libbilicrypto.so.
CC=${CC:-cc}
OUTPUT=${OUTPUT:-libbilicrypto-v5.so}
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
set --
while IFS= read -r source || [ -n "$source" ]; do
    set -- "$@" "$SOURCE_DIR/$source"
done < "$SOURCE_DIR/sources.list"

# shellcheck disable=SC2086
"$CC" -std=c99 -O2 -fPIC -shared -fvisibility=hidden \
    -ffunction-sections -fdata-sections -fstack-protector-strong \
    '-DMBEDTLS_CONFIG_FILE="bili_mbedtls_config.h"' \
    -I"$SOURCE_DIR" -I"$SOURCE_DIR/vendor/mbedtls/include" \
    -I"$SOURCE_DIR/vendor/mbedtls/library" \
    ${CFLAGS:-} "$@" \
    -Wl,--gc-sections -Wl,-z,defs -Wl,-z,relro,-z,now \
    "-Wl,--version-script=$SOURCE_DIR/bili_v5.exports.map" \
    ${LDFLAGS:-} -o "$OUTPUT"
