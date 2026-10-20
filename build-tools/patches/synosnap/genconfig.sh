#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Generate feature and symbol definitions for the target kernel, not the host.
set -euo pipefail

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
OUTPUT_FILE="$SRC_DIR/kernel-config.h"
FEATURE_TEST_DIR="$SRC_DIR/configure-tests/feature-tests"
KERNEL_VERSION="${1:-$(uname -r)}"
KDIR="${KDIR:-/lib/modules/$KERNEL_VERSION/build}"
MAKE_FLAGS="${2:-}"
MAX_THREADS="${SYNOSNAP_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
if [[ "$MAKE_FLAGS" =~ -j[[:space:]]*([0-9]+) ]]; then
    MAX_THREADS="${BASH_REMATCH[1]}"
fi
[[ "$MAX_THREADS" =~ ^[1-9][0-9]*$ ]] || MAX_THREADS=1
# Each probe invokes kbuild; avoid launching hundreds of compiler processes.
(( MAX_THREADS <= 8 )) || MAX_THREADS=8

fail() { echo "synosnap configure: $*" >&2; exit 1; }
# Never leave a previously generated header usable after a failed configure.
rm -f "$OUTPUT_FILE"
[[ -f "$KDIR/Makefile" ]] || fail "Missing headers for $KERNEL_VERSION: $KDIR"
# Ubuntu's Makefile can report the upstream stable version (e.g. 7.0.14),
# whereas this generated file records the actual distribution ABI release.
if [[ -r "$KDIR/include/config/kernel.release" ]]; then
    ACTUAL_VERSION=$(cat "$KDIR/include/config/kernel.release")
else
    ACTUAL_VERSION=$(make -s -C "$KDIR" kernelrelease)
fi
[[ "$ACTUAL_VERSION" == "$KERNEL_VERSION" ]] ||
    fail "Header release $ACTUAL_VERSION does not match $KERNEL_VERSION"

# These addresses are used to relocate unexported functions relative to kfree.
# A map from a different kernel can compile but call arbitrary kernel addresses.
# /proc/kallsyms is valid ONLY when building for the running kernel.
SYSTEM_MAP_FILE="${SYSTEM_MAP_FILE:-}"
if [[ -z "$SYSTEM_MAP_FILE" ]]; then
    for candidate in "/lib/modules/$KERNEL_VERSION/System.map" \
        "/boot/System.map-$KERNEL_VERSION" \
        "/usr/lib/debug/boot/System.map-$KERNEL_VERSION"; do
        if [[ -r "$candidate" ]] &&
            awk '$3 == "kfree" && $1 ~ /[1-9a-fA-F]/ { found=1 } END { exit !found }' "$candidate"; then
            SYSTEM_MAP_FILE="$candidate"
            break
        fi
    done
fi
if [[ -z "$SYSTEM_MAP_FILE" && "$(uname -r)" == "$KERNEL_VERSION" ]]; then
    SYSTEM_MAP_FILE=/proc/kallsyms
fi
[[ -n "$SYSTEM_MAP_FILE" && -r "$SYSTEM_MAP_FILE" ]] ||
    fail "No readable System.map for $KERNEL_VERSION. Install its matching kernel modules/debug package, or set SYSTEM_MAP_FILE to its matching map."
if [[ "$SYSTEM_MAP_FILE" == /proc/kallsyms && "$(uname -r)" != "$KERNEL_VERSION" ]]; then
    fail "Refusing running-kernel symbols for a different target kernel."
fi
awk '$3 == "kfree" && $1 ~ /[1-9a-fA-F]/ { found=1 } END { exit !found }' "$SYSTEM_MAP_FILE" ||
    fail "No usable kfree address in $SYSTEM_MAP_FILE (root may be required)."

echo "Generating configuration for $KERNEL_VERSION using $SYSTEM_MAP_FILE"
BUILD_DIR="$FEATURE_TEST_DIR/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/sanity"
printf 'obj-m := sanity.o\n' > "$BUILD_DIR/sanity/Makefile"
printf '#include <linux/module.h>\nMODULE_LICENSE("GPL");\n' > "$BUILD_DIR/sanity/sanity.c"
if ! make -C "$KDIR" M="$BUILD_DIR/sanity" modules > "$BUILD_DIR/sanity.log" 2>&1; then
    cat "$BUILD_DIR/sanity.log" >&2
    fail "Kernel/compiler sanity check failed; feature tests were not run."
fi

run_one_test() {
    local test macro result_dir
    test=$(basename "$1" .c)
    macro="HAVE_${test^^}"
    result_dir="$FEATURE_TEST_DIR/build"
    if make -C "$FEATURE_TEST_DIR" TEST_NAME="$test" KERNELVERSION="$KERNEL_VERSION" \
        KDIR="$KDIR" > "$result_dir/$test.log" 2>&1; then
        printf '#define %s\n' "$macro" > "$result_dir/$test.result"
        echo "performing configure test: $macro - present"
    else
        : > "$result_dir/$test.result"
        echo "performing configure test: $macro - not present"
    fi
}
export -f run_one_test
export FEATURE_TEST_DIR KERNEL_VERSION KDIR
printf '%s\0' "$FEATURE_TEST_DIR"/*.c |
    xargs -0 -P "$MAX_THREADS" -n 1 bash -c 'run_one_test "$1"' _

TEMP_HEADER=$(mktemp "$SRC_DIR/kernel-config.h.XXXXXX")
trap 'rm -f "$TEMP_HEADER"' EXIT
{
    echo "// Generated for $KERNEL_VERSION. Do not edit."
    echo '#ifndef ELASTIO_SNAP_KERNEL_CONFIG_H'
    echo '#define ELASTIO_SNAP_KERNEL_CONFIG_H'
    cat "$BUILD_DIR"/*.result
    while read -r symbol; do
        symbol="${symbol%$'\r'}"
        [[ -n "$symbol" ]] || continue
        address=$(awk -v symbol="$symbol" '$3 == symbol { print $1; exit }' "$SYSTEM_MAP_FILE")
        printf '#define %s_ADDR 0x%s\n' "${symbol^^}" "${address:-0}"
    done < "$SRC_DIR/configure-tests/symbol-tests"
    SYSTEM_CONFIG_FILE="${SYSTEM_CONFIG_FILE:-$KDIR/.config}"
    [[ -r "$SYSTEM_CONFIG_FILE" ]] || SYSTEM_CONFIG_FILE="/boot/config-$KERNEL_VERSION"
    [[ -r "$SYSTEM_CONFIG_FILE" ]] || fail "No configuration for $KERNEL_VERSION"
    while read -r option; do
        option="${option%$'\r'}"
        [[ -n "$option" ]] || continue
        value=$(awk -F= -v option="$option" '$1 == option { print $2; exit }' "$SYSTEM_CONFIG_FILE")
        [[ -z "$value" ]] || printf '#define %s %s\n' "$option" "$value"
    done < "$SRC_DIR/configure-tests/config-tests"
    if mount -V 2>&1 | grep -q "fd-based-mount"; then
        echo '#define USE_NEW_MOUNT_API'
    fi
    echo '#endif'
} > "$TEMP_HEADER"
mv "$TEMP_HEADER" "$OUTPUT_FILE"
