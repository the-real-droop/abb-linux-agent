#!/bin/bash
# Reject a mislabeled old semantic release even with current package metadata,
# build tags, file checksums and installer integrity. Nothing is installed.
# Usage: bash tests/agent-version.sh INSTALL.RUN ORIGINAL-3.2.0-5053-AGENT.DEB
set -euo pipefail
[[ $# == 2 ]] || {
    echo "Usage: $0 INSTALL.RUN ORIGINAL-3.2.0-5053-AGENT.DEB" >&2
    exit 2
}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
RUNFILE="$(realpath "$1")"
OLD_AGENT="$(realpath "$2")"
[[ "$(dpkg-deb -f "$OLD_AGENT" Version)" == 3.2.0-5053 ]] || {
    echo "FAIL: regression fixture must be the official agent 3.2.0-5053 DEB" >&2
    exit 1
}
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
bash "$REPO_DIR/verify_build.sh" "$RUNFILE"
bash "$RUNFILE" --extract "$WORK_DIR/payload"
AGENT_FILE=$(sed -n 's/^AGENT_PACKAGE="\([^"]*\)"$/\1/p' \
    "$WORK_DIR/payload/variables.sh")
AGENT_BUILD=$(sed -n 's/^AGENT_VERSION="\([^"]*\)"$/\1/p' \
    "$WORK_DIR/payload/variables.sh")
dpkg-deb -R "$WORK_DIR/payload/$AGENT_FILE" "$WORK_DIR/agent"
dpkg-deb -x "$OLD_AGENT" "$WORK_DIR/old-agent"

# Retain the current package and replace one executable with the old semantic
# release, changing its build string to the current value. A build-only
# verifier would incorrectly accept this package.
cp "$WORK_DIR/old-agent/bin/abb-cli" "$WORK_DIR/agent/bin/abb-cli"
AGENT_BUILD="$AGENT_BUILD" perl -0777 -pi -e '
    my $count = s/build\x005053\x00/"build\0".$ENV{AGENT_BUILD}."\0"/ge;
    die "Old fixture build tag missing or ambiguous\n" unless $count == 1;
' "$WORK_DIR/agent/bin/abb-cli"
(
    cd "$WORK_DIR/agent"
    find . -path './DEBIAN' -prune -o -type f -printf '%P\0' |
        sort -z | xargs -0 -r md5sum > DEBIAN/md5sums
)
dpkg-deb --root-owner-group -b "$WORK_DIR/agent" \
    "$WORK_DIR/payload/$AGENT_FILE"
tar -C "$WORK_DIR/payload" -czf "$WORK_DIR/payload.tar.gz" .
PAYLOAD_SHA256=$(sha256sum "$WORK_DIR/payload.tar.gz" | awk '{print $1}')
HEADER_LINES=$(awk '/^__ARCHIVE_BELOW__$/ {print NR; exit}' "$RUNFILE")
[[ "$HEADER_LINES" =~ ^[0-9]+$ ]] || {
    echo "FAIL: installer archive marker missing" >&2
    exit 1
}
head -n "$HEADER_LINES" "$RUNFILE" |
    sed "s/^PAYLOAD_SHA256=.*/PAYLOAD_SHA256='$PAYLOAD_SHA256'/" \
    > "$WORK_DIR/old-release.run"
cat "$WORK_DIR/payload.tar.gz" >> "$WORK_DIR/old-release.run"

if bash "$REPO_DIR/verify_build.sh" "$WORK_DIR/old-release.run" \
    > "$WORK_DIR/rejected.log" 2>&1; then
    echo "FAIL: verifier accepted an old 3.2.0 executable with build $AGENT_BUILD" >&2
    exit 1
fi
grep -Fq "Agent binaries do not match official release 3.2.1" \
    "$WORK_DIR/rejected.log" || {
    echo "FAIL: mislabeled old binary was rejected for the wrong reason" >&2
    cat "$WORK_DIR/rejected.log" >&2
    exit 1
}
echo "PASS: verifier rejected agent 3.2.0 with current build $AGENT_BUILD and valid package metadata."
