#!/bin/bash
# Repackage the official 3.2.1-5059 amd64 installer with the repository patches.
# Usage: bash build-tools/build.sh <original-install.run | extracted-directory>
# OUTPUT_DIR selects the directory for install.run, both DEBs and SHA256SUMS.
# TEMP_DIR selects a Linux scratch directory; no installation is performed.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)}"
TEMP_DIR="${TEMP_DIR:-/tmp}"
SOURCE_AGENT_VERSION="3.2.1-5059"
SOURCE_AGENT_RELEASE="${SOURCE_AGENT_VERSION%-*}"
SOURCE_AGENT_BUILD="${SOURCE_AGENT_VERSION##*-}"
SOURCE_SYNOSNAP_VERSION="0.12.10"

info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ $# == 1 ]] || fail "Usage: $0 <original-install.run | extracted-directory>"
for tool in dpkg-deb tar gzip perl sha256sum md5sum awk sed find sort xargs; do
    command -v "$tool" >/dev/null || fail "Required build tool not found: $tool"
done

# Keep package filenames and all version tags in one place. Normalize CRLF from
# Windows checkouts before reading these repository-owned variables.
source <(sed 's/\r$//' "$PATCHES_DIR/variables.sh")
AGENT_BUILD_TAG="$AGENT_VERSION"
FULL_AGENT_VERSION="${AGENT_PACKAGE#Synology Active Backup for Business Agent-}"
FULL_AGENT_VERSION="${FULL_AGENT_VERSION%.deb}"
SYNOSNAP_VERSION="$DATTOBD_VERSION"
[[ "$AGENT_RELEASE" == "$SOURCE_AGENT_RELEASE" ]] ||
    fail "Agent release must match the official binary base $SOURCE_AGENT_RELEASE"
[[ "$FULL_AGENT_VERSION" == "$AGENT_RELEASE-$AGENT_BUILD_TAG" ]] ||
    fail "Agent package filename, release and build tag disagree in variables.sh"
[[ "$DATTOBD_PACKAGE" == "synosnap-$SYNOSNAP_VERSION.deb" ]] ||
    fail "synosnap package filename and version disagree in variables.sh"
[[ "$AGENT_BUILD_TAG" =~ ^[0-9]{4}$ ]] ||
    fail "The binary build tag must remain four digits"

INPUT="$1"
mkdir -p "$OUTPUT_DIR" "$TEMP_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORKDIR="$(mktemp -d "$TEMP_DIR/abb-rebuild.XXXXXX")"
trap 'rm -rf -- "$WORKDIR"' EXIT
info "Work directory: $WORKDIR"

# Extract the payload without executing any code from the input installer.
if [[ -d "$INPUT" ]]; then
    if [[ -f "$INPUT/install.sh" ]]; then
        EXTRACTED="$INPUT"
    else
        EXTRACTED="$INPUT/extracted"
    fi
elif [[ -f "$INPUT" ]]; then
    EXTRACTED="$WORKDIR/extracted"
    mkdir -p "$EXTRACTED"
    ARCHIVE_LINE="$(awk '/^__ARCHIVE_BELOW__$/ {print NR + 1; exit}' "$INPUT")"
    if [[ -z "$ARCHIVE_LINE" ]]; then
        # Synology's Makeself header declares the number of lines to skip.
        SKIP_LINES="$(sed -n 's/^skip="\([0-9][0-9]*\)"$/\1/p' "$INPUT" | head -n 1)"
        [[ "$SKIP_LINES" =~ ^[0-9]+$ ]] ||
            fail "Unsupported installer format: no archive marker or Makeself skip count"
        ARCHIVE_LINE="$((10#$SKIP_LINES + 1))"
    fi
    tail -n +"$ARCHIVE_LINE" "$INPUT" | tar xzf - -C "$EXTRACTED"
else
    fail "Input '$INPUT' is neither a file nor a directory"
fi
for file in install.sh variables.sh dkms_common.postinst; do
    [[ -f "$EXTRACTED/$file" ]] || fail "Missing installer payload file: $file"
done

shopt -s nullglob
AGENT_DEBS=("$EXTRACTED"/Synology\ Active\ Backup\ for\ Business\ Agent-*.deb)
SNAP_DEBS=("$EXTRACTED"/synosnap-*.deb)
[[ ${#AGENT_DEBS[@]} == 1 && ${#SNAP_DEBS[@]} == 1 ]] ||
    fail "Expected exactly one agent DEB and one synosnap DEB"
ORIG_AGENT_DEB="${AGENT_DEBS[0]}"
ORIG_SYNOSNAP_DEB="${SNAP_DEBS[0]}"
[[ "$(dpkg-deb -f "$ORIG_AGENT_DEB" Package)" == "$AGENT_PACKAGE_NAME" &&
   "$(dpkg-deb -f "$ORIG_AGENT_DEB" Version)" == "$SOURCE_AGENT_VERSION" &&
   "$(dpkg-deb -f "$ORIG_AGENT_DEB" Architecture)" == amd64 ]] ||
    fail "Expected the official amd64 agent package $SOURCE_AGENT_VERSION"
[[ "$(dpkg-deb -f "$ORIG_SYNOSNAP_DEB" Package)" == "$DATTOBD_PACKAGE_NAME" &&
   "$(dpkg-deb -f "$ORIG_SYNOSNAP_DEB" Version)" == "$SOURCE_SYNOSNAP_VERSION" &&
   "$(dpkg-deb -f "$ORIG_SYNOSNAP_DEB" Architecture)" == amd64 ]] ||
    fail "Expected the official amd64 synosnap package $SOURCE_SYNOSNAP_VERSION"

# Update package checksums and installed size after every content modification.
refresh_metadata() {
    local root="$1" size
    (
        cd "$root"
        find . -path './DEBIAN' -prune -o -type f -printf '%P\0' |
            sort -z | xargs -0 -r md5sum > DEBIAN/md5sums
    )
    size="$(du -sk --exclude=DEBIAN "$root" | awk '{print $1}')"
    sed -i "s/^Installed-Size: .*/Installed-Size: $size/" "$root/DEBIAN/control"
    chmod 0755 "$root/DEBIAN"
    chmod 0644 "$root/DEBIAN/control" "$root/DEBIAN/md5sums"
}

info "Repacking synosnap $SYNOSNAP_VERSION"
SNAP_ROOT="$WORKDIR/synosnap"
dpkg-deb -R "$ORIG_SYNOSNAP_DEB" "$SNAP_ROOT"
SNAP_SRC="$SNAP_ROOT/usr/src/synosnap-$SYNOSNAP_VERSION"
mv "$SNAP_ROOT/usr/src/synosnap-$SOURCE_SYNOSNAP_VERSION" "$SNAP_SRC"
sed -i "s/^Version: .*/Version: $SYNOSNAP_VERSION/" "$SNAP_ROOT/DEBIAN/control"

# Overlay the entire maintained patch tree, including dkms.conf and its hooks.
# Source files use fixed modes because DrvFS checkouts can report every file as
# executable. Existing vendor files outside this patch set remain untouched.
while IFS= read -r -d '' file; do
    relative="${file#"$PATCHES_DIR/synosnap/"}"
    mkdir -p "$(dirname "$SNAP_SRC/$relative")"
    sed 's/\r$//' "$file" > "$SNAP_SRC/$relative"
    chmod 0644 "$SNAP_SRC/$relative"
done < <(find "$PATCHES_DIR/synosnap" -type f -print0)
chmod 0755 "$SNAP_SRC/genconfig.sh" "$SNAP_SRC/dkms_pre_install"
grep -qx "PACKAGE_VERSION=\"$SYNOSNAP_VERSION\"" "$SNAP_SRC/dkms.conf" ||
    fail "dkms.conf PACKAGE_VERSION disagrees with variables.sh"

# The vendor Debian 12+ workaround disables autoinstall. Preserve it so a future
# kernel upgrade rebuilds the patched module automatically.
sed -i \
    -e "s|sed -i '/AUTOINSTALL=\"yes\"/d' /usr/src/|# Keep AUTOINSTALL for kernel upgrades: /usr/src/|" \
    -e 's/Debian 12+ detected, disable DKMS autoinstall/Debian 12+ detected, retain DKMS autoinstall/' \
    "$SNAP_ROOT/DEBIAN/postinst"
refresh_metadata "$SNAP_ROOT"
PATCHED_SYNOSNAP_DEB="$WORKDIR/$DATTOBD_PACKAGE"
dpkg-deb --root-owner-group -b "$SNAP_ROOT" "$PATCHED_SYNOSNAP_DEB"

info "Repacking agent $FULL_AGENT_VERSION"
AGENT_ROOT="$WORKDIR/agent"
dpkg-deb -R "$ORIG_AGENT_DEB" "$AGENT_ROOT"
# Pin the compiled release too: DEB metadata alone cannot establish which
# semantic version the embedded agent code will report.
(cd "$AGENT_ROOT" && sha256sum --check "$SCRIPT_DIR/agent-binaries.sha256")
sed -i "s/^Version: .*/Version: $FULL_AGENT_VERSION/" "$AGENT_ROOT/DEBIAN/control"
DRIVER_INFO="$AGENT_ROOT/opt/Synology/ActiveBackupforBusiness/data/DRIVER_INFO"
[[ -f "$DRIVER_INFO" ]] || fail "Agent DRIVER_INFO is missing"
SYNOSNAP_VERSION="$SYNOSNAP_VERSION" AGENT_BUILD_TAG="$AGENT_BUILD_TAG" \
    perl -0777 -pi -e '
        s/("version"\s*:\s*")[^"]+(")/$1$ENV{SYNOSNAP_VERSION}-$ENV{AGENT_BUILD_TAG}$2/
            or die "DRIVER_INFO version not found\n";
    ' "$DRIVER_INFO"

# The semantic release is compiled into the vendor binaries. Use a matching
# official release and change only its existing fixed-length build string.
# Fail on unexpected layouts rather than silently reporting mixed versions.
for binary in \
    "$AGENT_ROOT/bin/abb-cli" \
    "$AGENT_ROOT/opt/Synology/ActiveBackupforBusiness/bin/service-ctrl" \
    "$AGENT_ROOT/opt/Synology/ActiveBackupforBusiness/bin/synology-backupd"; do
    [[ -f "$binary" ]] || fail "Missing agent binary: $binary"
    SOURCE_AGENT_BUILD="$SOURCE_AGENT_BUILD" AGENT_BUILD_TAG="$AGENT_BUILD_TAG" \
        perl -0777 -pi -e '
        my $old = "build\0".$ENV{SOURCE_AGENT_BUILD}."\0";
        my $count = s/\Q$old\E/"build\0".$ENV{AGENT_BUILD_TAG}."\0"/ge;
        $count == 1 or die "Expected one original build tag in $ARGV; found $count\n";
    ' "$binary"
done
refresh_metadata "$AGENT_ROOT"
PATCHED_AGENT_DEB="$WORKDIR/$AGENT_PACKAGE"
dpkg-deb --root-owner-group -b "$AGENT_ROOT" "$PATCHED_AGENT_DEB"

info "Building install.run"
PAYLOAD_DIR="$WORKDIR/payload"
mkdir -p "$PAYLOAD_DIR"
for file in install.sh dkms_common.postinst; do
    sed 's/\r$//' "$EXTRACTED/$file" > "$PAYLOAD_DIR/$file"
    chmod 0755 "$PAYLOAD_DIR/$file"
done
sed 's/\r$//' "$PATCHES_DIR/variables.sh" > "$PAYLOAD_DIR/variables.sh"
cp "$PATCHED_SYNOSNAP_DEB" "$PATCHED_AGENT_DEB" "$PAYLOAD_DIR/"
chmod 0644 "$PAYLOAD_DIR/variables.sh" "$PAYLOAD_DIR/"*.deb
PAYLOAD_TAR="$WORKDIR/payload.tar.gz"
tar -C "$PAYLOAD_DIR" --owner=0 --group=0 --numeric-owner -czf "$PAYLOAD_TAR" .
PAYLOAD_SHA256="$(sha256sum "$PAYLOAD_TAR" | awk '{print $1}')"

# One archive format on every build host; inspection never executes install.sh.
OUTPUT_FILE="$WORKDIR/install.run"
cat > "$OUTPUT_FILE" <<'HEADER'
#!/bin/bash
# Community-patched Synology Active Backup for Business Agent installer.
set -euo pipefail
PAYLOAD_SHA256='@PAYLOAD_SHA256@'
VERSION='@VERSION@'
usage() {
    printf '%s\n' \
        "Synology Active Backup for Business Agent $VERSION" \
        "Usage: sudo bash install.run [installer arguments]" \
        "       bash install.run --check" \
        "       bash install.run --noexec --target DIRECTORY" \
        "       bash install.run --extract DIRECTORY"
}
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
MODE=install
TARGET=''
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --check) [[ $# == 1 ]] || fail "--check takes no arguments"; MODE=check ;;
    --extract)
        [[ $# == 2 && -n "$2" ]] || fail "--extract requires a directory"
        MODE=extract; TARGET="$2" ;;
    --noexec)
        [[ $# == 3 && "$2" == --target && -n "$3" ]] ||
            fail "Use --noexec --target DIRECTORY"
        MODE=extract; TARGET="$3" ;;
esac
for tool in sha256sum tail awk tar mktemp; do
    command -v "$tool" >/dev/null || fail "Required command not found: $tool"
done
ARCHIVE="$(awk '/^__ARCHIVE_BELOW__$/ {print NR + 1; exit}' "$0")"
[[ "$ARCHIVE" =~ ^[0-9]+$ ]] || fail "Archive marker is missing"
ACTUAL_SHA256="$(tail -n +"$ARCHIVE" "$0" | sha256sum | awk '{print $1}')"
[[ "$ACTUAL_SHA256" == "$PAYLOAD_SHA256" ]] || fail "Payload SHA-256 mismatch"
if [[ "$MODE" == check ]]; then
    printf 'Payload SHA-256 verified.\n'
    exit 0
fi
if [[ "$MODE" == extract ]]; then
    if [[ -e "$TARGET" ]]; then
        [[ -d "$TARGET" && -z "$(ls -A "$TARGET")" ]] ||
            fail "Extraction target must be an empty directory"
    else
        mkdir -p -- "$TARGET"
    fi
    tail -n +"$ARCHIVE" "$0" | tar xzf - -C "$TARGET"
    printf 'Extracted to %s\n' "$TARGET"
    exit 0
fi
[[ "$EUID" == 0 ]] || fail "Run installation as root: sudo bash install.run"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/abb-install.XXXXXX")"
trap 'rm -rf -- "$WORKDIR"' EXIT
tail -n +"$ARCHIVE" "$0" | tar xzf - -C "$WORKDIR"
cd "$WORKDIR"
bash ./install.sh "$@"
exit $?
__ARCHIVE_BELOW__
HEADER
sed -i -e "s/@PAYLOAD_SHA256@/$PAYLOAD_SHA256/" \
    -e "s/@VERSION@/$FULL_AGENT_VERSION/" "$OUTPUT_FILE"
cat "$PAYLOAD_TAR" >> "$OUTPUT_FILE"
chmod 0755 "$OUTPUT_FILE"
bash "$OUTPUT_FILE" --check

cp "$OUTPUT_FILE" "$PATCHED_SYNOSNAP_DEB" "$PATCHED_AGENT_DEB" "$OUTPUT_DIR/"
(
    cd "$OUTPUT_DIR"
    sha256sum install.run "$DATTOBD_PACKAGE" "$AGENT_PACKAGE" > SHA256SUMS
)
info "Created install.run, both DEBs and SHA256SUMS in $OUTPUT_DIR"
info "Verify with: sha256sum -c SHA256SUMS"
info "Install with: sudo bash install.run"
