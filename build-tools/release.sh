#!/bin/bash
# Publish the artifacts from this tested workflow run, leaving failed uploads draft.
# Usage: bash build-tools/release.sh ARTIFACT_DIRECTORY
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ $# -eq 1 ]] || fail "Usage: $0 ARTIFACT_DIRECTORY"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARTIFACTS=$(cd "$1" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
for command in gh jq git bash sha256sum cmp; do
    command -v "$command" >/dev/null || fail "Required command not found: $command"
done

assignment() {
    local value
    value=$(sed 's/\r$//' "$ROOT/build-tools/patches/variables.sh" |
        sed -n "s/^$1=\"\\([^\"]*\\)\"$/\\1/p")
    [[ -n "$value" && "$value" != *$'\n'* ]] || fail "Invalid $1 assignment"
    printf '%s\n' "$value"
}
VERSION="$(assignment AGENT_RELEASE)-$(assignment AGENT_VERSION)"
SNAP_VERSION="$(assignment DATTOBD_VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]{4}$ ]] || fail "Invalid agent version"
TAG="v$VERSION"
AGENT_PACKAGE=$(assignment AGENT_PACKAGE)
SNAP_PACKAGE=$(assignment DATTOBD_PACKAGE)
[[ "$AGENT_PACKAGE" != */* && "$SNAP_PACKAGE" != */* ]] || fail "Invalid package filename"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_REF:?GITHUB_REF is required}"
: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    fail "Invalid repository"
[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "Expected a full commit SHA"
[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$GITHUB_SHA" ]] ||
    fail "Checkout does not match the tested commit"
case "$GITHUB_EVENT_NAME" in
    push) [[ "$GITHUB_REF" == "refs/tags/$TAG" ]] ||
        fail "Pushed tag must match configured version $TAG" ;;
    workflow_dispatch)
        : "${DEFAULT_BRANCH:?DEFAULT_BRANCH is required for a manual release}"
        [[ "$GITHUB_REF" == "refs/heads/$DEFAULT_BRANCH" ]] ||
            fail "Manual releases must run on the default branch" ;;
    *) fail "Release requires a version tag push or manual workflow dispatch" ;;
esac

# Check exactly the expected files. Do not let an artifact-supplied manifest
# select arbitrary paths, and do not mix externally supplied DEBs with the runfile.
(
    cd "$ARTIFACTS"
    sha256sum install.run "$SNAP_PACKAGE" "$AGENT_PACKAGE" > "$WORK/expected.sha256"
)
cmp -s "$WORK/expected.sha256" "$ARTIFACTS/SHA256SUMS" ||
    fail "Artifact SHA256SUMS does not match the three expected files"
bash "$ROOT/verify_build.sh" "$ARTIFACTS/install.run"
bash "$ARTIFACTS/install.run" --extract "$WORK/payload"
for package in "$SNAP_PACKAGE" "$AGENT_PACKAGE"; do
    cmp -s "$ARTIFACTS/$package" "$WORK/payload/$package" ||
        fail "Standalone DEB differs from verified installer: $package"
done

# GitHub normalizes spaces in release asset names. Choose stable names ourselves
# and regenerate the manifest for those names without changing any package bytes.
STAGED="$WORK/assets"
mkdir "$STAGED"
SAFE_AGENT="synology-active-backup-business-agent-${VERSION}-amd64.deb"
cp "$ARTIFACTS/install.run" "$STAGED/install.run"
cp "$ARTIFACTS/$SNAP_PACKAGE" "$STAGED/$SNAP_PACKAGE"
cp "$ARTIFACTS/$AGENT_PACKAGE" "$STAGED/$SAFE_AGENT"
ASSETS=(install.run "$SNAP_PACKAGE" "$SAFE_AGENT" SHA256SUMS)
(cd "$STAGED" && sha256sum "${ASSETS[@]:0:3}" > SHA256SUMS)

# --include lets us distinguish a missing release/tag from authentication,
# rate-limit, network and server failures. Never treat every gh failure as 404.
api_get() {
    local endpoint="$1" result status
    result=0
    gh api --include "$endpoint" > "$WORK/response" 2> "$WORK/api-error" || result=$?
    status=$(head -n 1 "$WORK/response" | tr -d '\r')
    if [[ "$status" =~ ^HTTP/[^[:space:]]+[[:space:]]+404([[:space:]]|$) ]]; then
        return 44
    fi
    if [[ "$result" != 0 || ! "$status" =~ ^HTTP/[^[:space:]]+[[:space:]]+200([[:space:]]|$) ]]; then
        cat "$WORK/api-error" >&2
        fail "GitHub API request failed: $endpoint ($status)"
    fi
    # Headers end with an empty CRLF or LF line; preserve the JSON body.
    sed '1,/^\r\{0,1\}$/d' "$WORK/response"
}
BASE="repos/$GITHUB_REPOSITORY"
# Drafts with an uncreated tag can expose a synthetic tag or "untagged-*" URL.
# GitHub CLI resolves their pending tag through GraphQL, then reads REST by ID.
find_release() {
    local response id release draft
    # GraphQL variables must reach gh literally; they are not shell variables.
    # shellcheck disable=SC2016
    response=$(gh api graphql \
        -f query='query($owner: String!, $name: String!, $tag: String!) {
            repository(owner: $owner, name: $name) {
                release(tagName: $tag) { databaseId isDraft }
            }
        }' \
        -f owner="${GITHUB_REPOSITORY%/*}" -f name="${GITHUB_REPOSITORY#*/}" -f tag="$TAG") ||
        fail "GitHub GraphQL release lookup failed"
    jq -e '((.errors // []) | length) == 0 and
        (.data.repository | type == "object" and has("release"))' <<< "$response" >/dev/null ||
        fail "Invalid GitHub GraphQL release response"
    [[ "$(jq -r '.data.repository.release == null' <<< "$response")" != true ]] || return 44
    id=$(jq -er '.data.repository.release.databaseId | numbers' <<< "$response") ||
        fail "Invalid GitHub release ID"
    [[ "$id" =~ ^[0-9]+$ ]] || fail "Invalid GitHub release ID"
    draft=$(jq -r '.data.repository.release.isDraft' <<< "$response")
    [[ "$draft" == true || "$draft" == false ]] || fail "Invalid GitHub draft state"
    release=$(api_get "$BASE/releases/$id") || fail "Could not read resolved GitHub release $id"
    [[ "$(jq -r '.id' <<< "$release")" == "$id" &&
        "$(jq -r '.draft' <<< "$release")" == "$draft" ]] ||
        fail "Release identity changed during lookup"
    if [[ "$draft" == false ]]; then
        [[ "$(jq -r '.tag_name' <<< "$release")" == "$TAG" ]] ||
            fail "Published release has an unexpected tag"
    fi
    # This local field records the pending tag confirmed by GraphQL; retain the
    # raw REST tag_name for the separate check after publication.
    jq --arg tag "$TAG" '. + {verified_tag_name: $tag}' <<< "$release" ||
        fail "Invalid GitHub release metadata"
}
check_tag() {
    local object type sha depth=0 result=0
    object=$(api_get "$BASE/git/ref/tags/$TAG") || result=$?
    if [[ "$result" == 44 ]]; then
        # A manual release's new draft may not create its tag until publication.
        [[ "$GITHUB_EVENT_NAME" != push ]] || fail "Pushed release tag no longer exists"
        return 0
    fi
    [[ "$result" == 0 ]] || return "$result"
    type=$(jq -er '.object.type' <<< "$object")
    sha=$(jq -er '.object.sha' <<< "$object")
    while [[ "$type" == tag ]]; do
        ((depth+=1))
        [[ "$depth" -le 10 ]] || fail "Too many nested annotated tags"
        object=$(api_get "$BASE/git/tags/$sha")
        type=$(jq -er '.object.type' <<< "$object")
        sha=$(jq -er '.object.sha' <<< "$object")
    done
    [[ "$type" == commit && "$sha" == "$GITHUB_SHA" ]] ||
        fail "Existing tag $TAG does not point to the tested commit"
}
check_tag
result=0
RELEASE=$(find_release) || result=$?
if [[ "$result" == 44 ]]; then
    cat > "$WORK/notes.md" <<EOF
Synology Active Backup for Business Agent $VERSION with synosnap $SNAP_VERSION.

Built from [commit $GITHUB_SHA](${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/commit/$GITHUB_SHA) after installer verification and the complete kernel test matrix, including Ubuntu 26.04 / 7.0.0-38-generic.

Workflow run: ${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/${GITHUB_RUN_ID:-unknown}

The official vendor agent binaries are patched to report $VERSION. The synosnap $SNAP_VERSION driver passes the Ubuntu 7.0.0-38-generic snapshot test.

Download install.run and run:

\`\`\`sh
bash install.run --check
sudo bash install.run
\`\`\`

SHA256SUMS covers install.run and both standalone Debian packages. The standalone agent package has a filename suitable for GitHub release assets; its contents are identical to the package inside install.run.

See the [installation instructions](${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/blob/$GITHUB_SHA/docs/ubuntu-26.04.md) for prerequisites and Secure Boot. NAS-side latest-version recognition and Secure Boot loading still require validation on your system.
EOF
    gh release create "$TAG" --repo "$GITHUB_REPOSITORY" --draft \
        --target "$GITHUB_SHA" --title "$VERSION — Ubuntu 26.04 / Linux 7.0" \
        --notes-file "$WORK/notes.md"
    RELEASE=$(find_release) || fail "Created draft could not be resolved by its pending tag"
elif [[ "$result" != 0 ]]; then
    exit "$result"
fi
[[ "$(jq -r '.draft' <<< "$RELEASE")" == true ]] ||
    fail "Release $TAG is already published; refusing to overwrite it"
[[ "$(jq -r '.target_commitish' <<< "$RELEASE")" == "$GITHUB_SHA" ]] ||
    fail "Existing draft does not target the exact tested commit $GITHUB_SHA; review and retarget that draft before retrying"
[[ "$(jq -r '.verified_tag_name' <<< "$RELEASE")" == "$TAG" ]] ||
    fail "Unexpected release tag"
RELEASE_ID=$(jq -er '.id | numbers' <<< "$RELEASE")
# A retry may replace our four files in a partial draft, but must not publish
# unrelated assets that somebody attached manually.
while IFS= read -r name; do
    [[ " ${ASSETS[*]} " == *" $name "* ]] || fail "Unexpected draft asset: $name"
done < <(jq -r '.assets[].name' <<< "$RELEASE")
UPLOADS=()
for name in "${ASSETS[@]}"; do UPLOADS+=("$STAGED/$name"); done
gh release upload "$TAG" --repo "$GITHUB_REPOSITORY" --clobber "${UPLOADS[@]}"
RELEASE=$(find_release) || fail "Draft disappeared after upload"
[[ "$(jq -r '.draft' <<< "$RELEASE")" == true &&
    "$(jq -r '.id' <<< "$RELEASE")" == "$RELEASE_ID" &&
    "$(jq -r '.target_commitish' <<< "$RELEASE")" == "$GITHUB_SHA" &&
    "$(jq -r '.verified_tag_name' <<< "$RELEASE")" == "$TAG" ]] ||
    fail "Draft was changed during upload"
[[ "$(jq '.assets | length' <<< "$RELEASE")" == 4 ]] ||
    fail "Expected four uploaded release assets"
for name in "${ASSETS[@]}"; do
    asset=$(jq -ce --arg name "$name" '[.assets[] | select(.name == $name)] |
        if length == 1 then .[0] else error("missing or duplicate asset") end' <<< "$RELEASE")
    [[ "$(jq -r '.state' <<< "$asset")" == uploaded ]] ||
        fail "Asset upload is incomplete: $name"
    [[ "$(jq -r '.size' <<< "$asset")" == "$(wc -c < "$STAGED/$name" | tr -d ' ')" ]] ||
        fail "Uploaded asset size differs: $name"
    expected=$(sha256sum "$STAGED/$name" | cut -d ' ' -f 1)
    digest=$(jq -r '.digest // empty' <<< "$asset")
    if [[ -n "$digest" ]]; then
        [[ "$digest" == "sha256:$expected" ]] || fail "Uploaded asset hash differs: $name"
    else
        # Older GitHub API versions do not expose digest. Verify the actual bytes.
        id=$(jq -er '.id | numbers' <<< "$asset")
        gh api -H 'Accept: application/octet-stream' "$BASE/releases/assets/$id" > "$WORK/download"
        [[ "$(sha256sum "$WORK/download" | cut -d ' ' -f 1)" == "$expected" ]] ||
            fail "Downloaded asset hash differs: $name"
    fi
done
check_tag
# Re-resolve the pending tag immediately before publication, so a retagged or
# replaced draft cannot be published after its assets have been checked.
RELEASE=$(find_release) || fail "Draft disappeared before publication"
[[ "$(jq -r '.draft' <<< "$RELEASE")" == true &&
    "$(jq -r '.id' <<< "$RELEASE")" == "$RELEASE_ID" &&
    "$(jq -r '.target_commitish' <<< "$RELEASE")" == "$GITHUB_SHA" ]] ||
    fail "Draft was changed before publication"
gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --tag "$TAG" \
    --target "$GITHUB_SHA" --draft=false --latest
RELEASE=$(api_get "$BASE/releases/$RELEASE_ID")
[[ "$(jq -r '.draft' <<< "$RELEASE")" == false ]] || fail "Release is still a draft"
[[ "$(jq -r '.tag_name' <<< "$RELEASE")" == "$TAG" ]] || fail "Published release has an unexpected tag"
# Unlike a draft, a published release must have an actual matching Git ref.
GITHUB_EVENT_NAME=push check_tag
echo "Published https://github.com/$GITHUB_REPOSITORY/releases/tag/$TAG"
