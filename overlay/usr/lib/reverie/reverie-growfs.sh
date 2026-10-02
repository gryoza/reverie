#!/bin/bash
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin
LOG_FILE="/var/log/reverie-growfs.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== [$(date)] reverie-growfs execution check ==="

# 1. Detect root mount device safely
ROOT_RAW=$(findmnt -n -o SOURCE / 2>/dev/null || true)
ROOT_CLEAN="${ROOT_RAW%%\[*}"

if [ -z "$ROOT_CLEAN" ]; then
    echo "Error: Could not determine root source device. Aborting."
    exit 0
fi

REAL_ROOT=$(readlink -f "$ROOT_CLEAN" 2>/dev/null || echo "$ROOT_CLEAN")
echo "Root device detected: $REAL_ROOT (raw: $ROOT_RAW)"

# 2. CRITICAL SAFETY CHECK: Only proceed on MicroSD card (/dev/mmcblk0p2)
# NEVER touch internal storage (/dev/sd*, /dev/nvme*, UFS chip)
if [[ "$REAL_ROOT" != /dev/mmcblk0p2 ]]; then
    echo "Safety notice: Root device is not /dev/mmcblk0p2. Skipping SD expansion."
    exit 0
fi

PARENT_DEV="/dev/mmcblk0"
PART_NUM=2

# 3. Dynamic check: is there unallocated space at the end of the SD card?
DISK_SECTORS=$(cat /sys/class/block/mmcblk0/size 2>/dev/null || echo 0)
PART_START=$(cat /sys/class/block/mmcblk0p2/start 2>/dev/null || echo 0)
PART_SECTORS=$(cat /sys/class/block/mmcblk0p2/size 2>/dev/null || echo 0)
PART_END=$((PART_START + PART_SECTORS))
FREE_SECTORS=$((DISK_SECTORS - PART_END))

echo "Disk sectors: $DISK_SECTORS, Part2 end: $PART_END, Free sectors: $FREE_SECTORS"

# If free space is less than 2048 sectors (~1 MB), disk is already at 100%
if [ "$FREE_SECTORS" -lt 2048 ]; then
    echo "Partition already covers full disk. Nothing to do."
    exit 0
fi

# 4. Verify DOS partition table
if ! sfdisk -d "$PARENT_DEV" 2>/dev/null | grep -q "label: dos"; then
    echo "Safety notice: $PARENT_DEV does not have a DOS partition table. Skipping."
    exit 0
fi

echo "Free space of $FREE_SECTORS sectors ($((FREE_SECTORS * 512 / 1024 / 1024)) MB) detected!"
echo "Expanding partition $PART_NUM on $PARENT_DEV to 100%..."
echo ", +" | sfdisk -N "$PART_NUM" --no-reread "$PARENT_DEV" || true

echo "Informing kernel of partition update..."
partx -u "$REAL_ROOT" 2>/dev/null || partprobe "$PARENT_DEV" 2>/dev/null || true

echo "Resizing Btrfs filesystem to max..."
btrfs filesystem resize max / || {
    echo "Warning: Btrfs resize reported non-zero status."
}

echo "=== MicroSD auto-expansion completed successfully ==="
exit 0
