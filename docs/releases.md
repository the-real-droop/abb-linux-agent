# Automated GitHub releases

The **Test DKMS module build** workflow builds and verifies the installer,
runs the version regression tests, and tests all seven kernels. Its release
job runs only after every build and test job succeeds. Ordinary branch pushes
and manual runs with publication disabled produce Actions artifacts.

## Publish the configured version

1. Merge the version and source changes into the default branch (`master`).
   The agent release and build in `build-tools/patches/variables.sh` determine
   the release version, currently `3.2.1-5060`.
2. Open **Actions → Test DKMS module build → Run workflow**.
3. Select the default branch and enable **Publish the configured agent version
   after all tests pass**.
4. Run the workflow. After its tests pass, the release job creates
   `v3.2.1-5060` at the exact tested commit and publishes it as the latest release.

No personal access token or additional repository secret is needed. Only the
release job has `contents: write`; the build and kernel jobs have read access.

Alternatively, push a tag matching the configured version:

```bash
git fetch origin
git tag v3.2.1-5060 origin/master
git push origin v3.2.1-5060
```

Use one publication method for a version. Tag pushes trigger the same complete
build and test pipeline. A tag that disagrees with the configured version or
points to a different commit is rejected by the publisher.

## Attached assets

Each release contains:

- `install.run`: the complete installer.
- `synology-active-backup-business-agent-3.2.1-5060-amd64.deb`: the agent package.
- `synosnap-0.12.13.deb`: the patched DKMS module package.
- `SHA256SUMS`: checksums for the three files above.

The agent DEB has a filename without spaces for GitHub Releases, since GitHub
can rename uploaded files containing special characters. Its bytes and package
metadata are unchanged. The release checksum manifest uses the release
filenames. Actions artifacts retain the original filename and their own
matching manifest; keep each set with its corresponding checksum file.

Download all three binary files and the manifest into one directory, then run:

```bash
sha256sum --check SHA256SUMS
bash install.run --check
sudo bash install.run
```

## Interrupted publication

The publisher creates a draft, uploads and checks all four assets, and only
then publishes. If an upload fails, the release stays a draft. Re-run the
failed release job from the same workflow run to retry that exact tested
commit and its artifacts. A draft for a different commit is rejected.

Published releases are never overwritten. Corrections to an already published
installer require a new version and tag. The published release notes link to
the tested commit, workflow run and installation notes.
