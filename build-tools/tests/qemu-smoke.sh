#!/bin/bash
# Boot a disposable VM with the target kernel and verify snapshot data integrity.
# Usage: qemu-smoke.sh /path/to/vmlinuz /path/to/synosnap.ko /path/to/log
# Requires qemu-system-x86_64, busybox (static), gcc, cpio, gzip, mkfs.ext4.
# No module is loaded and no block device is modified on the build host.
set -euo pipefail
[[ $# == 3 ]] || { echo "Usage: $0 KERNEL MODULE LOG" >&2; exit 2; }
KERNEL=$(realpath "$1")
MODULE=$(realpath "$2")
LOG=$(realpath -m "$3")
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
ROOT="$WORK/root"
mkdir -p "$ROOT"/{bin,sbin,proc,sys,dev,tmp,mnt/test,mnt/snapshot}
cp "$(command -v busybox)" "$ROOT/bin/busybox"
for cmd in sh mount umount insmod rmmod cat echo dmesg sync sleep poweroff \
    sha256sum dd cmp grep head; do
    ln -s busybox "$ROOT/bin/$cmd"
done
gcc -O2 -Wall -Wextra -Werror -static -o "$ROOT/bin/snapshot-smoke" "$SCRIPT_DIR/snapshot-smoke.c"
cp "$MODULE" "$ROOT/synosnap.ko"
cat > "$ROOT/init" <<'EOF'
#!/bin/sh
export PATH=/bin:/sbin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
echo "ABB_GUEST_KERNEL=$(cat /proc/sys/kernel/osrelease)"
# Run in a separate shell so errexit remains effective for every assertion.
sh -e /test
RESULT=$?
if [ "$RESULT" = 0 ]; then
    echo ABB_SNAPSHOT_SMOKE_PASS
else
    echo "ABB_SNAPSHOT_SMOKE_FAIL=$RESULT"
fi
dmesg
poweroff -f
EOF
cat > "$ROOT/test" <<'EOF'
#!/bin/sh
set -eu
insmod /synosnap.ko
echo ABB_MODULE_LOAD_OK
mount -t ext4 /dev/vda /mnt/test
dd if=/dev/urandom of=/tmp/original bs=4096 count=256
cat /tmp/original > /mnt/test/payload
sync
snapshot-smoke setup 0 /dev/vda /mnt/test/cow 32
snapshot-smoke info 0
dd if=/dev/zero of=/mnt/test/payload bs=4096 count=256 conv=notrunc
sync
mount -t ext4 -o ro,noload /dev/synosnap0 /mnt/snapshot
cmp /tmp/original /mnt/snapshot/payload
echo ABB_SNAPSHOT_ORIGINAL_DATA_OK
umount /mnt/snapshot
snapshot-smoke info 0
# Closing a tracked mount forces COW extent/FIEMAP handling through the VMA
# allocation path; remounting must resume tracking without losing the snapshot.
umount /mnt/test
snapshot-smoke info 0 | grep 'state=1 error=0'
mount -t ext4 /dev/vda /mnt/test
snapshot-smoke info 0 | grep 'state=3 error=0'
mount -t ext4 -o ro,noload /dev/synosnap0 /mnt/snapshot
cmp /tmp/original /mnt/snapshot/payload
umount /mnt/snapshot
echo ABB_DORMANT_REMOUNT_DATA_OK
snapshot-smoke inc 0
# Repeated transitions are expected during agent cleanup and are idempotent.
snapshot-smoke inc 0
snapshot-smoke info 0
cat /tmp/original > /mnt/test/payload
sync
snapshot-smoke snap 0 /mnt/test/cow2 32
snapshot-smoke info 0
dd if=/dev/zero of=/mnt/test/payload bs=4096 count=256 conv=notrunc
sync
mount -t ext4 -o ro,noload /dev/synosnap0 /mnt/snapshot
cmp /tmp/original /mnt/snapshot/payload
echo ABB_SECOND_SNAPSHOT_DATA_OK
umount /mnt/snapshot
snapshot-smoke destroy 0
snapshot-smoke free | grep 'free_minor=0'
umount /mnt/test
rmmod synosnap
echo ABB_MODULE_UNLOAD_OK
EOF
chmod +x "$ROOT/init" "$ROOT/test"
(cd "$ROOT" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -1) > "$WORK/initramfs.gz"
truncate -s 256M "$WORK/test-disk.img"
mkfs.ext4 -q -F "$WORK/test-disk.img"
timeout 180 qemu-system-x86_64 -machine accel=tcg -cpu max -m 1024 -smp 2 \
    -kernel "$KERNEL" -initrd "$WORK/initramfs.gz" \
    -drive "file=$WORK/test-disk.img,format=raw,if=virtio" \
    -append 'console=ttyS0 rdinit=/init panic=-1' \
    -display none -serial stdio -no-reboot > "$LOG" 2>&1
grep -E 'ABB_|BUG:|WARNING:|Oops|panic|error=' "$LOG" || true
grep -q '^ABB_SNAPSHOT_SMOKE_PASS' "$LOG"
if grep -Eq 'BUG:|WARNING:|Oops:|Kernel panic' "$LOG"; then
    echo "Kernel diagnostic found; inspect $LOG" >&2
    exit 1
fi
