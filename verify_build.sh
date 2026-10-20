#!/bin/bash
# Verify the rebuilt installer without installing packages or loading a module.
# Usage: bash verify_build.sh [path/to/install.run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNFILE="${1:-$SCRIPT_DIR/install.run}"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK: $*"; }
require_file() { [ -f "$1" ] || fail "Missing file: $1"; }

# Read literal assignments without executing package/maintainer scripts.
assignment() {
    local file="$1" key="$2" value
    value=$(sed 's/\r$//' "$file" |
        sed -n "s/^${key}=\"\\([^\"]*\\)\"$/\\1/p")
    [ -n "$value" ] && [[ "$value" != *$'\n'* ]] ||
        fail "Expected one quoted $key assignment in $file"
    printf '%s\n' "$value"
}

for command in bash dpkg-deb tar gzip sha256sum md5sum perl cmp; do
    command -v "$command" >/dev/null || fail "Required command not found: $command"
done
require_file "$RUNFILE"
RUNFILE="$(cd "$(dirname "$RUNFILE")" && pwd)/$(basename "$RUNFILE")"

bash "$RUNFILE" --check
bash "$RUNFILE" --extract "$WORK_DIR/payload"
PAYLOAD="$WORK_DIR/payload"
for file in install.sh dkms_common.postinst variables.sh; do
    require_file "$PAYLOAD/$file"
    bash -n "$PAYLOAD/$file"
done
pass "Installer integrity and extraction-only interface"

AGENT_FILE=$(assignment "$PAYLOAD/variables.sh" AGENT_PACKAGE)
SNAP_FILE=$(assignment "$PAYLOAD/variables.sh" DATTOBD_PACKAGE)
[[ "$AGENT_FILE" != */* && "$SNAP_FILE" != */* ]] ||
    fail "Package filenames must be relative basenames"
require_file "$PAYLOAD/$AGENT_FILE"
require_file "$PAYLOAD/$SNAP_FILE"
shopt -s nullglob
PACKAGES=("$PAYLOAD"/*.deb)
[ "${#PACKAGES[@]}" -eq 2 ] || fail "Expected exactly two payload DEBs"

AGENT_VERSION=$(dpkg-deb -f "$PAYLOAD/$AGENT_FILE" Version)
SNAP_VERSION=$(dpkg-deb -f "$PAYLOAD/$SNAP_FILE" Version)
AGENT_BUILD="${AGENT_VERSION##*-}"
AGENT_RELEASE="${AGENT_VERSION%-*}"
[[ "$AGENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]{4}$ ]] ||
    fail "Unexpected agent version format: $AGENT_VERSION"
[ "$(dpkg-deb -f "$PAYLOAD/$AGENT_FILE" Package)" = \
    "$(assignment "$PAYLOAD/variables.sh" AGENT_PACKAGE_NAME)" ] ||
    fail "Agent package name does not match variables.sh"
[ "$(dpkg-deb -f "$PAYLOAD/$SNAP_FILE" Package)" = \
    "$(assignment "$PAYLOAD/variables.sh" DATTOBD_PACKAGE_NAME)" ] ||
    fail "Synosnap package name does not match variables.sh"
[ "$AGENT_FILE" = "Synology Active Backup for Business Agent-${AGENT_VERSION}.deb" ] ||
    fail "Agent DEB filename/version mismatch"
[ "$SNAP_FILE" = "synosnap-${SNAP_VERSION}.deb" ] ||
    fail "Synosnap DEB filename/version mismatch"
[ "$(assignment "$PAYLOAD/variables.sh" AGENT_VERSION)" = "$AGENT_BUILD" ] ||
    fail "Installer agent build does not match DEB metadata"
[ "$(assignment "$PAYLOAD/variables.sh" AGENT_RELEASE)" = "$AGENT_RELEASE" ] ||
    fail "Installer agent release does not match DEB metadata"
[ "$(assignment "$PAYLOAD/variables.sh" DATTOBD_VERSION)" = "$SNAP_VERSION" ] ||
    fail "Installer synosnap version does not match DEB metadata"
REPO_VARIABLES="$SCRIPT_DIR/build-tools/patches/variables.sh"
require_file "$REPO_VARIABLES"
for key in AGENT_PACKAGE AGENT_RELEASE AGENT_VERSION AGENT_PACKAGE_NAME \
    DATTOBD_PACKAGE DATTOBD_VERSION DATTOBD_PACKAGE_NAME; do
    [ "$(assignment "$PAYLOAD/variables.sh" "$key")" = \
        "$(assignment "$REPO_VARIABLES" "$key")" ] ||
        fail "Installer $key does not match the maintained variables.sh"
done
pass "Package metadata: agent $AGENT_VERSION; synosnap $SNAP_VERSION"

dpkg-deb -R "$PAYLOAD/$AGENT_FILE" "$WORK_DIR/agent"
dpkg-deb -R "$PAYLOAD/$SNAP_FILE" "$WORK_DIR/synosnap"
for package in agent synosnap; do
    require_file "$WORK_DIR/$package/DEBIAN/md5sums"
    (cd "$WORK_DIR/$package" && md5sum --check --quiet DEBIAN/md5sums)
    for script in preinst postinst prerm postrm; do
        if [ -f "$WORK_DIR/$package/DEBIAN/$script" ]; then
            bash -n "$WORK_DIR/$package/DEBIAN/$script"
        fi
    done
done
pass "Package file checksums and maintainer-script syntax"

SNAP_SRC="$WORK_DIR/synosnap/usr/src/synosnap-${SNAP_VERSION}"
require_file "$SNAP_SRC/dkms.conf"
bash -n "$SNAP_SRC/dkms.conf"
[ "$(assignment "$SNAP_SRC/dkms.conf" PACKAGE_NAME)" = "synosnap" ] ||
    fail "Unexpected DKMS package name"
[ "$(assignment "$SNAP_SRC/dkms.conf" PACKAGE_VERSION)" = "$SNAP_VERSION" ] ||
    fail "DKMS version does not match DEB metadata"
[ "$(assignment "$SNAP_SRC/dkms.conf" AUTOINSTALL)" = "yes" ] ||
    fail "DKMS autoinstall is disabled"
grep -Fq "#define ELASTIO_SNAP_VERSION \"$SNAP_VERSION\"" "$SNAP_SRC/elastio-snap.h" ||
    fail "Embedded module version does not match DEB metadata"
require_file "$SNAP_SRC/genconfig.sh"
[ -x "$SNAP_SRC/genconfig.sh" ] || fail "DKMS feature detector is not executable"
bash -n "$SNAP_SRC/genconfig.sh"

# Verify all maintained sources, including future feature probes. The builder
# updates the version declarations in dkms.conf and elastio-snap.h.
PATCH_DIR="$SCRIPT_DIR/build-tools/patches/synosnap"
if [ -d "$PATCH_DIR" ]; then
    while IFS= read -r -d '' source; do
        relative="${source#"$PATCH_DIR/"}"
        require_file "$SNAP_SRC/$relative"
        sed -e 's/\r$//' \
            -e "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"$SNAP_VERSION\"/" \
            -e "s/^#define ELASTIO_SNAP_VERSION .*/#define ELASTIO_SNAP_VERSION \"$SNAP_VERSION\"/" \
            "$source" > "$WORK_DIR/expected-source"
        cmp -s "$WORK_DIR/expected-source" "$SNAP_SRC/$relative" ||
            fail "Packaged source differs from maintained patch: $relative"
    done < <(find "$PATCH_DIR" -type f -print0)
    pass "All maintained kernel patches are present and current"
else
    fail "Run this verifier from a repository checkout containing build-tools/patches/synosnap"
fi

# The semantic release is compiled into the executables; changing a build tag
# alone leaves the old major/minor/patch values. Normalize only the four-digit
# build tag, then require the exact official 3.2.1-5059 binaries. This checks all
# three executables without installing packages or starting the backup service.
UPSTREAM_AGENT_RELEASE="3.2.1"
UPSTREAM_AGENT_BUILD="5059"
[ "$AGENT_RELEASE" = "$UPSTREAM_AGENT_RELEASE" ] ||
    fail "No binary provenance manifest for agent release $AGENT_RELEASE"
MANIFEST="$SCRIPT_DIR/build-tools/agent-binaries.sha256"
require_file "$MANIFEST"
NORMALIZED_ROOT="$WORK_DIR/agent-version"
mkdir -p "$NORMALIZED_ROOT"
for binary in bin/abb-cli \
    opt/Synology/ActiveBackupforBusiness/bin/service-ctrl \
    opt/Synology/ActiveBackupforBusiness/bin/synology-backupd; do
    require_file "$WORK_DIR/agent/$binary"
    mkdir -p "$NORMALIZED_ROOT/$(dirname "$binary")"
    EXPECTED_BUILD="$AGENT_BUILD" UPSTREAM_BUILD="$UPSTREAM_AGENT_BUILD" \
        perl -0777 -ne '
            my $tag = "build\0".$ENV{EXPECTED_BUILD}."\0";
            my $count = s/\Q$tag\E/"build\0".$ENV{UPSTREAM_BUILD}."\0"/ge;
            die "Expected exactly one build tag in $ARGV\n" unless $count == 1;
            print;
        ' "$WORK_DIR/agent/$binary" > "$NORMALIZED_ROOT/$binary" ||
        fail "Embedded agent build does not match DEB metadata in $binary"
done
(cd "$NORMALIZED_ROOT" && sha256sum --check "$MANIFEST") ||
    fail "Agent binaries do not match official release $UPSTREAM_AGENT_RELEASE"
DRIVER_INFO="$WORK_DIR/agent/opt/Synology/ActiveBackupforBusiness/data/DRIVER_INFO"
require_file "$DRIVER_INFO"
grep -Eq "\"version\"[[:space:]]*:[[:space:]]*\"${SNAP_VERSION//./\\.}-${AGENT_BUILD}\"" "$DRIVER_INFO" ||
    fail "DRIVER_INFO does not match the patched driver and agent versions"
pass "All agent binaries contain release $AGENT_RELEASE and build $AGENT_BUILD; DRIVER_INFO matches"

echo "PASS: installer and package verification complete (no packages installed)."
