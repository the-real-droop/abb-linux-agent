# Ubuntu 26.04 / Linux 7.0.0-38

This build targets **Ubuntu 26.04, amd64 (x86-64), kernel
`7.0.0-38-generic`**, from Ubuntu's `7.0.0-38.38` packages. The requested
`7.0.0.38` is interpreted as that Ubuntu ABI release. Confirm with `uname -r`.

The installer packages agent **3.2.0-5056** and DKMS module **0.12.13**.
It retains the repository's official Synology **3.2.0-5053** binary base.
It is a community patch, not an official Synology release.

## Installation

Copy `install.run` to the target Ubuntu machine. `SHA256SUMS` covers all three
binary assets, so keep both DEBs alongside it if checking the whole manifest.

```bash
uname -r
uname -m
bash install.run --check
# Optional, with all three assets present:
sha256sum -c SHA256SUMS

sudo apt update
sudo apt install build-essential dkms "linux-headers-$(uname -r)" "linux-modules-$(uname -r)"
sudo bash install.run

dkms status synosnap
modinfo -F version synosnap
lsmod | grep synosnap
```

Expected module version: `0.12.13`. The installer builds the module locally for
the installed kernel; it does not ship a precompiled `.ko`. Use `install.run`
for deployment. The standalone DEBs are also provided for inspection and
advanced packaging, but the vendor synosnap maintainer scripts depend on
installer-provided files/environment.

If Secure Boot rejects the locally built module, enroll the key used by Ubuntu
DKMS and follow Ubuntu's module-signing procedure. Secure Boot was not exercised
in the VM tests. Do not treat a successful compilation as proof that the target
machine has loaded the module.

Connect/configure the agent with your NAS using the normal Synology procedure.
A full NAS backup and restore should be validated on the target system before
relying on it. No NAS credentials or server were available during this build.

## Changes

- The temporary FIEMAP mapping uses the kernel's VMA allocator and free
  functions when available. Linux 7.0 initializes per-VMA locks and reference
  counts there; directly zeroing a slab object bypassed that initialization.
- Feature detection selects `vm_flags_init` where supported. Mapping flags,
  unlock paths and teardown of inserted mappings are corrected.
- Modern block-device allocation failures are handled as error pointers.
- Configuration uses a matching target-kernel System.map. It refuses
  `/proc/kallsyms` from another running kernel and maps with no usable `kfree`.
  It no longer downloads debug packages implicitly during configuration.
- A real compiler/header sanity check must pass before feature probes.
  Failed configuration removes stale headers; per-probe logs are retained.
  Ubuntu ABI identification uses `include/config/kernel.release`.
- Versions, agent build strings, DRIVER_INFO and DEB checksums are consistent.
  The archive verifies its payload before extraction or installation.
- CI covers the exact Ubuntu package version and mainline 7.0 in addition to
  the existing kernel matrix.

Relevant upstream sources:

- [Linux 7.0 VMA allocation and initialization](https://github.com/torvalds/linux/blob/v7.0/mm/vma_init.c)
- [Linux 7.0 block disk allocation](https://github.com/torvalds/linux/blob/v7.0/block/genhd.c)
- [Ubuntu target header package](https://packages.ubuntu.com/resolute-updates/linux-headers-7.0.0-38-generic)

## Validation on 2026-10-20

The final packaged synosnap source was extracted from its DEB and built using
DKMS 3.2.2 in an Ubuntu 26.04 container, GCC 15.2.0, the exact Ubuntu headers
and the matching System.map. Module metadata reports version `0.12.13` and
vermagic beginning `7.0.0-38-generic`.

A disposable QEMU VM booted Ubuntu's exact `7.0.0-38-generic` kernel. On an
ext4 filesystem backed by a virtio test disk it verified:

1. Module loading and control-device access.
2. Snapshot creation, live writes and byte-for-byte original snapshot contents.
3. Tracked unmount/remount (states `3 → 1 → 3`) and preserved snapshot data.
4. Incremental transition, including a repeated idempotent transition.
5. A second snapshot with sequence number 2 and preserved contents after writes.
6. Snapshot destruction, release of the minor number and clean module unloading.

The test found no kernel BUG, WARNING, Oops or panic. All snapshot info checks
reported `error=0`. Package/source checks, payload checks and six negative
configuration tests also passed.

These tests cover module behavior, not a full Synology NAS backup/restore or a
complete agent installation on a booted Ubuntu desktop/server. Other
filesystems, storage configurations, Secure Boot and all older kernel matrix
entries were not tested locally. Hosted CI results are separate from the local
validation described here.

## Reproduce

Download the original x64 DEB ZIP from the
[official Synology archive](https://archive.synology.com/download/Utility/ActiveBackupBusinessAgent/3.2.0-5053).
The ZIP used here has SHA-256:

```text
b6625ae7b8a5bfdcb03647f8335b7de70d6bb51d11da2c27ea3fec036a68a22f
```

```bash
OUTPUT_DIR="$PWD/artifacts" bash build-tools/build.sh /path/to/original/install.run
bash verify_build.sh artifacts/install.run
bash artifacts/install.run --extract /path/to/empty-inspection-directory
```

For offline DKMS builds, provide the target kernel's System.map from its matching
`linux-modules` package under `/boot/System.map-KERNEL`. An explicit
`SYSTEM_MAP_FILE` override is available; the caller must ensure it belongs to
the target kernel. A headers-only build cannot safely substitute host symbols.

The CI workflow documents dependency and package extraction commands. The
QEMU fixture takes a kernel image, an uncompressed built module and an output
log path; it creates its own disposable disk and never loads the module on the
host:

```bash
bash build-tools/tests/qemu-smoke.sh /path/to/vmlinuz-7.0.0-38-generic \
    /path/to/synosnap.ko qemu-snapshot.log
```
