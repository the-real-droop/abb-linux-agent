> **WARNING:** This project is **not affiliated with, endorsed by, or supported by Synology Inc.**
> No support is provided — use at your own risk.

# Synology Active Backup for Business Agent — Kernel 6.15–7.0 Patches

[![DKMS module build](https://github.com/the-real-droop/abb-linux-agent/actions/workflows/test-dkms.yml/badge.svg)](https://github.com/the-real-droop/abb-linux-agent/actions/workflows/test-dkms.yml)
![GitHub Downloads](https://img.shields.io/github/downloads/the-real-droop/abb-linux-agent/total)

Synology's `3.2.0-5053` release officially added support up to kernel 6.14.
Their `synosnap` DKMS module still fails to compile on 6.15 and later due to
further upstream kernel API changes — leaving users on the latest distributions
(Ubuntu 25.04/25.10) unable to back up their machines. This project patches the
module source and repackages the installer so it works again.

The community build reports **`3.2.1-5060`**, including the installer, DEB
metadata and embedded agent version. It uses the official **`3.2.1-5059`**
agent binaries with their build number updated to `5060` and the kernel patches
described below. Their compiled semantic version is already `3.2.1`.

## Download

For **Ubuntu 26.04 x86-64, kernel `7.0.0-38-generic`** (Ubuntu package
`7.0.0-38.38`), see the [installation and validation notes](docs/ubuntu-26.04.md).
This build packages synosnap `0.12.13`. Each release includes `install.run`,
both DEBs and `SHA256SUMS`, published automatically after the installer checks
and all seven kernel tests pass. Ordinary CI runs also provide these files in
the `linux-installable-assets` Actions artifact.

Pre-built installer ready to deploy:

**[Download install.run](https://github.com/the-real-droop/abb-linux-agent/releases/latest/download/install.run)**

[All release assets and checksums](https://github.com/the-real-droop/abb-linux-agent/releases/latest)

```bash
sudo bash install.run
```

The installer sets up the agent and builds the `synosnap` kernel module via
DKMS, just like the official installer.

### Verified kernel versions

| Kernel | Distribution | Status |
|--------|-------------|--------|
| `6.12.74+deb13+1-amd64` | Debian 13 | Verified |
| `6.14.0-061400-generic` | Ubuntu mainline | CI Tested |
| `6.15.0-061500-generic` | Ubuntu mainline | CI Tested |
| `6.17.0-061700-generic` | Ubuntu mainline | CI Tested |
| `6.17.0-19-generic` | Ubuntu 25.10 | Verified |
| `6.18.0-061800-generic` | Ubuntu 25.10 | CI Tested |
| `6.19.0-061900-generic` | Ubuntu mainline | CI Tested |
| `6.19.10-061910-generic` | Ubuntu 25.10 | Verified |
| `7.0.0-070000-generic` | Ubuntu 25.10 | Verified |
| `7.0.0-14-generic` | Kubuntu 26.04 LTS | Verified |
| `7.0.0-38-generic` | Ubuntu 26.04, `7.0.0-38.38`, x86-64 | DKMS build + QEMU ext4 snapshot tests |

**Status legend:**
- **Verified** — full install tested on real hardware; agent connected and backed up successfully
- **CI Tested** — `synosnap` module compiled successfully against mainline kernel headers in GitHub Actions; not yet confirmed with a live install
- **DKMS build + QEMU ext4 snapshot tests** — exact Ubuntu kernel booted in a
  disposable VM; module loading, data-preserving snapshots, incremental
  transitions, tracked unmount/remount and unloading passed. NAS backup/restore,
  Secure Boot and other filesystems were not tested.

> **Note:** Kernels 6.12–6.13 are officially supported by Synology's `3.2.0-5053` release and are not tested here.

## Secure Boot

Secure Boot requires the locally built module to be signed by a trusted key.
Ubuntu DKMS can sign modules with a local Machine Owner Key (MOK); that key
must also be enrolled. This project's VM tests do not validate Secure Boot.
Check `mokutil --sb-state` and follow Ubuntu's MOK enrollment process if the
module is rejected with a key/signature error.

Running a kernel not listed here? Please
[open an issue](https://github.com/Peppershade/abb-linux-agent/issues)
to report whether it works — this helps others and helps us track compatibility.

## Uninstall

If the DKMS module build fails or you need to remove it cleanly:

```bash
sudo dpkg --remove synosnap
sudo dkms remove synosnap/0.12.13 --all
```

---

## Build it yourself

If you prefer to inspect the source and build from scratch rather than
trusting a pre-built binary:

### Prerequisites

- **Linux** (native or WSL) — the build uses `dpkg-deb`, `tar`, and shell tools
- `dpkg-deb` (from `dpkg` package)
- `tar`, `gzip`
- `perl` (for binary version patching)
- `sha256sum`, `md5sum`, `awk`, `sed`, `find`, `sort`, `xargs` (standard GNU tools)

On Debian/Ubuntu:

```bash
sudo apt install dpkg tar gzip perl
```

### Obtaining the original installer

Download the official **Synology Active Backup for Business Agent 3.2.1-5059**
Linux installer (`.run` file) from the
[Synology Download Center](https://www.synology.com/en-global/support/download).

Navigate to your NAS model, select **Desktop Utilities**, and download
*Active Backup for Business Agent* for Linux (x64 / deb).

### Building

```bash
bash build-tools/build.sh /path/to/original-install.run
```

This will:

1. Extract the official installer payload
2. Unpack the `synosnap` DEB, replace source files with patched versions
3. Repack the agent DEB with the updated version number
4. Produce `install.run`, both DEBs and `SHA256SUMS` in the current directory

The generated archive supports `bash install.run --check` and
`bash install.run --extract /path/to/empty-directory` without installing.
Run `bash verify_build.sh install.run` to verify package metadata and sources.

## Publishing a release

See [the release workflow](docs/releases.md) for the manual publish option,
version tags, attached files and recovery from an interrupted upload.

---

## What is patched

The `synosnap` kernel module source (`/usr/src/synosnap-0.12.13/`) is based on
Synology's `0.12.10` (unchanged between `3.2.0-5053` and `3.2.1-5059`) and patched to handle kernel API
changes from **6.15 through 7.0**:

### Ubuntu 26.04 / kernel 7.0.0-38

- Use the kernel VMA allocator/free functions and `vm_flags_init` when available,
  preserving current per-VMA lock and reference-count initialization.
- Correct FIEMAP temporary mapping flags, cleanup order and lock release.
- Handle error pointers from modern disk allocation.
- Build using the target kernel's System.map; reject an unrelated running
  kernel's symbols and fail early when the compiler/header check fails.
- Keep DKMS, module, agent and installer versions consistent, and verify archive
  integrity before extraction or installation.
- Add exact Ubuntu header CI coverage and a reproducible QEMU snapshot test.

### Kernel 6.17+
- **Data corruption fix** — `synosnap` was marking bios with bit 28 of
  `bio->bi_opf` as a passthrough flag. Kernel 6.17 reclaimed bit 28 as
  `REQ_P2PDMA`, causing NVMe to return `BLK_STS_INVAL` on every tracked write,
  which made ext4 fail unwritten→written extent conversions and silently corrupt
  files. Fixed by replacing the bit-flag with a `current == sd_mrf_thread` check
  (the re-entry from `blk_mq_submit_bio` always runs on that thread synchronously).
- `freeze_super()` / `thaw_super()` gained a third `owner` argument —
  `freeze_super_3.c` feature test added, `main.c` updated with new call path

### Kernel log noise reduction
- **Spurious ioctl errors suppressed** — the agent sends `IOCTL_TRANSITION_INC`
  on devices already in incremental mode during normal backup completion; the
  driver now returns success (idempotent) instead of `-EINVAL`, eliminating the
  repeated `device specified is not in active snapshot mode` / `error during
  transition to incremental ioctl handler` messages.  Similarly, `IOCTL_DESTROY`
  and the elastio-snap info ioctl no longer log errors when the device is already
  gone (`-ENOENT`) — these are normal cleanup calls on agent restart. A copy-paste
  bug in the elastio-snap info error message (which claimed to be the reconfigure
  handler) is also fixed.

### Installer / packaging fixes
- **Debian 12+ DKMS autoinstall** — the original `postinst` stripped
  `AUTOINSTALL="yes"` from `dkms.conf` on Debian 12+, causing DKMS to refuse
  to build the module. That block is now disabled during repackaging.
- **Target-kernel symbols** — `genconfig.sh` accepts `/proc/kallsyms` only for the
  running target kernel. Offline builds use that kernel's matching System.map.
- **synosnap version bump to 0.12.13** — forces reinstallation of the patched
  module on machines that already had `0.12.12` or earlier installed.

## Repository layout

```
build-tools/
  build.sh                       # Main build script
  patches/
    variables.sh                 # Installer version overrides (3.2.1-5060)
    synosnap/                    # Patched kernel module sources
      configure-tests/
        feature-tests/           # Kernel feature detection tests
source/
  install.run                    # Place official 3.2.1-5059 installer here (gitignored)
```

## Disclaimer

This project is **not affiliated with, endorsed by, or supported by Synology Inc.**
It is an independent, community-driven effort to extend kernel compatibility for
the Active Backup for Business Agent.

**No support is provided.** This is a best-effort project — help may be offered
through issues, but there are no guarantees of response time or resolution.
Use at your own risk.

## Contributors

- [Árpád Szász](https://github.com/arpadszasz) — TEMP_DIR support, extraction fix,
  Debian 12+ DKMS autoinstall fix ([#2](https://github.com/Peppershade/abb-linux-agent/pull/2))
- [noidvan](https://github.com/noidvan) — fix data corruption on kernel 6.17+ (REQ_P2PDMA bit 28
  clash in `bio->bi_opf`) ([#14](https://github.com/Peppershade/abb-linux-agent/pull/14))

## License

The patched source files are derived from Synology's `synosnap` kernel module,
which is based on [elastio-snap](https://github.com/Axcient/elastio-snap)
(maintained by Axcient; originally [dattobd](https://github.com/datto/dattobd) by Datto Inc.).
The original code is licensed under the GPL v2. Patches in this repository are
provided under the same license.
