#!/bin/bash
# Exercise failures against real kernel headers without changing installed files.
# Usage: bash tests/genconfig.sh SOURCE_DIRECTORY KERNEL_RELEASE [SYSTEM_MAP]
set -euo pipefail
[[ $# -ge 2 && $# -le 3 ]] || {
    echo "Usage: $0 SOURCE_DIRECTORY KERNEL_RELEASE [SYSTEM_MAP]" >&2
    exit 2
}
SOURCE_DIR=$(realpath "$1")
TARGET_KERNEL="$2"
TARGET_MAP=$(realpath "${3:-/boot/System.map-$TARGET_KERNEL}")
TARGET_HEADERS=$(realpath "/lib/modules/$TARGET_KERNEL/build")
[[ -f "$SOURCE_DIR/genconfig.sh" && -f "$TARGET_HEADERS/Makefile" && -r "$TARGET_MAP" ]]
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
cp -a "$SOURCE_DIR" "$TEST_DIR/source"
cd "$TEST_DIR/source"

expect_failure() {
    local name="$1" message="$2"
    shift 2
    # Every failed reconfiguration must invalidate any previous successful one.
    printf '#define STALE_CONFIGURATION\n' > kernel-config.h
    if "$@" > "$TEST_DIR/$name.log" 2>&1; then
        echo "FAIL: $name unexpectedly succeeded" >&2
        cat "$TEST_DIR/$name.log" >&2
        exit 1
    fi
    if ! grep -Fq "$message" "$TEST_DIR/$name.log"; then
        echo "FAIL: $name failed for the wrong reason" >&2
        cat "$TEST_DIR/$name.log" >&2
        exit 1
    fi
    [[ ! -e kernel-config.h ]] || {
        echo "FAIL: $name left a stale kernel-config.h" >&2
        exit 1
    }
    echo "PASS: $name"
}

expect_failure missing-headers "Missing headers" \
    env KDIR="$TEST_DIR/missing" SYSTEM_MAP_FILE="$TARGET_MAP" \
    bash ./genconfig.sh "$TARGET_KERNEL"
expect_failure mismatched-headers "does not match" \
    env KDIR="$TARGET_HEADERS" SYSTEM_MAP_FILE="$TARGET_MAP" \
    bash ./genconfig.sh "${TARGET_KERNEL}-wrong"

if [[ "$(uname -r)" != "$TARGET_KERNEL" ]]; then
    expect_failure wrong-running-kernel "Refusing running-kernel symbols" \
        env KDIR="$TARGET_HEADERS" SYSTEM_MAP_FILE=/proc/kallsyms \
        bash ./genconfig.sh "$TARGET_KERNEL"
else
    echo "SKIP: wrong-running-kernel requires a target different from uname -r"
fi

printf '0000000000000000 T kfree\n' > "$TEST_DIR/zero-symbols"
expect_failure zero-kfree-address "No usable kfree address" \
    env KDIR="$TARGET_HEADERS" SYSTEM_MAP_FILE="$TEST_DIR/zero-symbols" \
    bash ./genconfig.sh "$TARGET_KERNEL"
printf 'ffffffff81000000 T unrelated_symbol\n' > "$TEST_DIR/missing-kfree"
expect_failure missing-kfree-symbol "No usable kfree address" \
    env KDIR="$TARGET_HEADERS" SYSTEM_MAP_FILE="$TEST_DIR/missing-kfree" \
    bash ./genconfig.sh "$TARGET_KERNEL"

# Kbuild overrides environment-only CC. MAKEFLAGS supplies a make command-line
# assignment so that both its top-level and recursive compiler calls must fail.
expect_failure failed-compiler "Kernel/compiler sanity check failed" \
    env KDIR="$TARGET_HEADERS" SYSTEM_MAP_FILE="$TARGET_MAP" \
    MAKEFLAGS='-- CC=/bin/false' CC=/bin/false \
    bash ./genconfig.sh "$TARGET_KERNEL"

echo "PASS: genconfig failure paths preserve no stale configuration."
