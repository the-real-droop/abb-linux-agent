#!/bin/bash
# Exercise publication sequencing and rejection paths with real build artifacts.
# Only gh is mocked; package/installer verification runs unchanged.
# Usage: bash tests/release.sh ARTIFACT_DIRECTORY
set -euo pipefail
[[ $# -eq 1 ]] || { echo "Usage: $0 ARTIFACT_DIRECTORY" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARTIFACTS=$(cd "$1" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir "$WORK/bin"
export MOCK_STATE="$WORK/state"
export PATH="$WORK/bin:$PATH"
export GITHUB_REPOSITORY="fixture/abb-linux-agent"
export GITHUB_SHA
GITHUB_SHA=$(git -C "$ROOT" rev-parse HEAD)
export GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/master
export DEFAULT_BRANCH=master GH_TOKEN=fixture-token
configured() {
    sed 's/\r$//' "$ROOT/build-tools/patches/variables.sh" |
        sed -n "s/^$1=\"\\([^\"]*\\)\"$/\\1/p"
}
MOCK_VERSION="$(configured AGENT_RELEASE)-$(configured AGENT_VERSION)"
export MOCK_VERSION
AGENT_PACKAGE=$(configured AGENT_PACKAGE)
SNAP_PACKAGE=$(configured DATTOBD_PACKAGE)
cat > "$WORK/bin/gh" <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["MOCK_STATE"])
root.mkdir(exist_ok=True)
state_file = root / "state.json"
state = json.loads(state_file.read_text()) if state_file.exists() else {}
args = sys.argv[1:]
case = os.environ["MOCK_CASE"]
sha = os.environ["GITHUB_SHA"]
version = os.environ["MOCK_VERSION"]
with (root / "calls.jsonl").open("a") as out:
    out.write(json.dumps(args) + "\n")

def save():
    state_file.write_text(json.dumps(state))

def response(code, data):
    print(f"HTTP/2.0 {code} Mock\r\nX-Mock: true\r\n\r")
    print(json.dumps(data))
    sys.exit(0 if code == 200 else 1)

def release():
    return {
        "id": 42,
        "draft": not state.get("published", False) and case != "published",
        "target_commitish": "f" * 40 if case == "wrong-draft" else sha,
        "tag_name": "v" + version,
        "assets": state.get("assets", [{"name": "install.run"}] if case == "draft" else []),
    }

if args[:2] == ["api", "--include"]:
    endpoint = args[2]
    if case == "api-403":
        response(403, {"message": "Forbidden"})
    if case == "api-network":
        sys.stderr.write("network unavailable\n")
        sys.exit(1)
    if "/git/ref/tags/" in endpoint:
        if case == "bad-tag" or (case == "tag-race" and state.get("assets")):
            response(200, {"object": {"type": "commit", "sha": "f" * 40}})
        if case == "annotated":
            response(200, {"object": {"type": "tag", "sha": "a" * 40}})
        response(404, {"message": "Not Found"})
    if "/git/tags/" in endpoint:
        response(200, {"object": {"type": "commit", "sha": sha}})
    if "/releases?per_page=" in endpoint:
        if not state.get("created") and case not in ("draft", "wrong-draft", "published"):
            response(200, [])
        response(200, [release()])
    if endpoint.endswith("/releases/42"):
        response(200, release())
    if "/releases/tags/" in endpoint:
        response(404, {"message": "Not Found"})
    raise AssertionError(args)
if args[:2] == ["release", "create"]:
    assert "--draft" in args
    assert args[args.index("--target") + 1] == sha
    state["created"] = True
    save()
elif args[:2] == ["release", "upload"]:
    assert not state.get("published")
    if case == "upload-failure":
        sys.exit(1)
    names = args[args.index("--clobber") + 1:]
    assert len(names) == 4
    assets = []
    for index, path in enumerate(names):
        path = Path(path)
        data = path.read_bytes()
        name = path.name
        assert " " not in name
        (root / name).write_bytes(data)
        assets.append({
            "id": index + 1, "name": name, "state": "uploaded",
            "size": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
        })
    if case == "missing-asset":
        assets.pop()
    if case == "bad-hash":
        assets[0]["digest"] = "sha256:" + "0" * 64
    if case == "no-digest":
        for asset in assets:
            asset["digest"] = None
    state["assets"] = assets
    save()
elif args[:2] == ["api", "-H"]:
    assert args[2] == "Accept: application/octet-stream"
    asset = state["assets"][int(args[3].rsplit("/", 1)[1]) - 1]
    sys.stdout.buffer.write((root / asset["name"]).read_bytes())
elif args[:2] == ["release", "edit"]:
    assert "--draft=false" in args and "--latest" in args
    assert len(state["assets"]) == 4
    state["published"] = True
    save()
else:
    raise AssertionError(args)
PY
chmod +x "$WORK/bin/gh"

run_case() {
    local name="$1" message="$2" mutations="$3" directory="${4:-$ARTIFACTS}"
    rm -rf -- "$MOCK_STATE"
    export MOCK_CASE="$name"
    local status=0
    bash "$ROOT/build-tools/release.sh" "$directory" > "$WORK/$name.log" 2>&1 || status=$?
    if [[ "$message" == success ]]; then
        [[ "$status" == 0 ]] || { cat "$WORK/$name.log" >&2; exit 1; }
    else
        if [[ "$status" == 0 ]] || ! grep -Fq "$message" "$WORK/$name.log"; then
            cat "$WORK/$name.log" >&2
            echo "FAIL: $name" >&2
            exit 1
        fi
    fi
    python3 - "$MOCK_STATE" "$mutations" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()] if (root / "calls.jsonl").exists() else []
writes = [call[1] for call in calls if call[0] == "release"]
mode = sys.argv[2]
if mode == "none":
    assert not writes, writes
elif mode == "draft-only":
    assert "edit" not in writes, writes
elif mode == "publish":
    assert writes[-2:] == ["upload", "edit"], writes
    manifest = (root / "SHA256SUMS").read_text()
    import os
    assert f"synology-active-backup-business-agent-{os.environ['MOCK_VERSION']}-amd64.deb" in manifest
    assert "Synology Active" not in manifest
    import hashlib
    for line in manifest.splitlines():
        digest, name = line.split("  ", 1)
        assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
PY
    echo "PASS: $name"
}

# Early failures must never reach mutation APIs.
GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v0.0.0-0000 \
    run_case wrong-version "Pushed tag must match" none
GITHUB_REF=refs/heads/feature \
    run_case wrong-branch "Manual releases must run on the default branch" none
GITHUB_SHA=ffffffffffffffffffffffffffffffffffffffff \
    run_case wrong-commit "Checkout does not match" none
mkdir "$WORK/corrupt"
for file in "$ARTIFACTS"/*.deb "$ARTIFACTS/install.run"; do ln -s "$file" "$WORK/corrupt/"; done
printf 'invalid checksum\n' > "$WORK/corrupt/SHA256SUMS"
run_case corrupt-manifest "Artifact SHA256SUMS does not match" none "$WORK/corrupt"

# A manifest can be valid while its standalone DEB differs from the runfile.
mkdir "$WORK/mixed"
ln -s "$ARTIFACTS/install.run" "$WORK/mixed/install.run"
ln -s "$ARTIFACTS/$SNAP_PACKAGE" "$WORK/mixed/$SNAP_PACKAGE"
cp "$ARTIFACTS/$AGENT_PACKAGE" "$WORK/mixed/$AGENT_PACKAGE"
printf 'mismatched standalone package' >> "$WORK/mixed/$AGENT_PACKAGE"
(cd "$WORK/mixed" && sha256sum install.run "$SNAP_PACKAGE" "$AGENT_PACKAGE" > SHA256SUMS)
run_case mixed-package "Standalone DEB differs from verified installer" none "$WORK/mixed"

run_case new success publish
run_case draft success publish
GITHUB_EVENT_NAME=push GITHUB_REF="refs/tags/v$MOCK_VERSION" \
    run_case annotated success publish
run_case no-digest success publish
run_case bad-tag "does not point to the tested commit" none
run_case published "already published" none
run_case wrong-draft "does not target the exact tested commit" none
run_case api-403 "GitHub API request failed" none
run_case api-network "GitHub API request failed" none
run_case missing-asset "Expected four uploaded release assets" draft-only
run_case bad-hash "Uploaded asset hash differs" draft-only
run_case tag-race "does not point to the tested commit" draft-only
# gh's upload failure itself must leave the release unpublished.
run_case upload-failure "All agent binaries contain release" draft-only
echo "PASS: release publication and failure-path regression tests."
