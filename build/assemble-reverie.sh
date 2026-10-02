#!/bin/bash
set -euo pipefail

# ==============================================================================
# Reverie OS v1.0 Master Image Assembler
# Assembles a bootable Reverie OS image (MBR / FAT32 BOOT + Btrfs rootfs)
# using official Valve Deckard base and Reverie system overlays.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OVERLAY_DIR="${REPO_DIR}/overlay"
PLUGINS_DIR="${REPO_DIR}/plugins"
UPDATER_SRC="${REPO_DIR}/updater/reverie-updater"
INSTALLER_SRC="${SCRIPT_DIR}/reverie-installer.py"

WORK_DIR="${WORK_DIR:-${REPO_DIR}/build_output}"
OUTPUT_IMG="${1:-${WORK_DIR}/reverie-os-v1.0.img}"
OUTPUT_ZST="${OUTPUT_IMG}.zst"
OUTPUT_SHA="${OUTPUT_ZST}.sha256"

VANILLA_ROOTFS="${VANILLA_ROOTFS:-${WORK_DIR}/rootfs_vanilla.img}"
BUILD_ROOTFS="${WORK_DIR}/rootfs_build.img"

echo "=========================================================="
echo " Reverie OS Image Assembler"
echo " Repo Dir: ${REPO_DIR}"
echo " Output:   ${OUTPUT_IMG}"
echo "=========================================================="

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Must be run with sudo/root." >&2
    exit 1
fi

mkdir -p "${WORK_DIR}"

# 1. Acquire clean Valve Deckard rootfs
if [[ ! -f "${VANILLA_ROOTFS}" ]]; then
    if [[ -f "${SCRIPT_DIR}/rootfs.img.caibx" && -x "${SCRIPT_DIR}/extract_rootfs.py" ]]; then
        echo "=== Vanilla rootfs not found. Extracting via Valve casync index... ==="
        python3 "${SCRIPT_DIR}/extract_rootfs.py" \
            --caibx "${SCRIPT_DIR}/rootfs.img.caibx" \
            --output "${VANILLA_ROOTFS}" \
            --workers 8
    else
        echo "ERROR: Vanilla rootfs not found at ${VANILLA_ROOTFS}" >&2
        echo "Please provide a valid rootfs_vanilla.img or ensure rootfs.img.caibx is present." >&2
        exit 1
    fi
fi

MNT_ROOTFS=$(mktemp -d -t reverie_rootfs.XXXXXX)
MNT_ESP=$(mktemp -d -t reverie_esp.XXXXXX)

cleanup() {
    echo "=== Cleaning up loop mounts and temp dirs ==="
    sync || true
    if mountpoint -q "${MNT_ROOTFS}" 2>/dev/null; then umount -R "${MNT_ROOTFS}" 2>/dev/null || true; fi
    if mountpoint -q "${MNT_ESP}" 2>/dev/null; then umount "${MNT_ESP}" 2>/dev/null || true; fi
    if [ -n "${LOOP_ROOTFS:-}" ]; then losetup -d "${LOOP_ROOTFS}" 2>/dev/null || true; fi
    if [ -n "${LOOP_DISK:-}" ]; then losetup -d "${LOOP_DISK}" 2>/dev/null || true; fi
    rm -rf "${MNT_ROOTFS}" "${MNT_ESP}" "${BUILD_ROOTFS}" 2>/dev/null || true
}
trap cleanup EXIT ERR INT TERM

# ------------------------------------------------------------------------------
# 1. Prepare Rootfs from Vanilla Deckard
# ------------------------------------------------------------------------------
echo "=== Step 1: Cloning clean Deckard rootfs ==="
cp --reflink=auto "${VANILLA_ROOTFS}" "${BUILD_ROOTFS}"

LOOP_ROOTFS=$(losetup -fP --show "${BUILD_ROOTFS}")
mount -t btrfs -o subvolid=5,nodiscard "${LOOP_ROOTFS}" "${MNT_ROOTFS}"
btrfs property set "${MNT_ROOTFS}" ro false || true
mount -o remount,rw,nodiscard "${MNT_ROOTFS}"

# ------------------------------------------------------------------------------
# 2. VR Headset Neutralization & Fstab Cleanup
# ------------------------------------------------------------------------------
echo "=== Step 2: Masking VR Headset services & cleaning fstab ==="
for unit in \
    deckard-fpga.service \
    fpga-config.service \
    deckard-audio-setup.service \
    deckard-charger.service \
    deckard-fan-control.service \
    deckard-led-control.service \
    deckard-typec-logger.service \
    tcpm-log.service \
    ensure-v4l2loopback.service \
    steamvr-program-ble.service \
    steamvr-set-kernel-thread-priorities.service \
    steamvr-v4l2loopback.service \
    vrble-programmer.service \
    predistart-images.service \
    home.mount \
    var.mount \
    var-log.mount \
    var-tmp.mount \
    efi.mount \
    efi.automount \
    syspersist.mount \
    syspersist.automount \
    persist.mount \
    persist.automount \
    fstrim.service \
    fstrim.timer \
    systemd-repart.service \
    systemd-fsck@dev-disk-by\\x2dpartlabel-syspersist.service \
    systemd-fsck@dev-disk-by\\x2dpartsets-shared-home.service \
    systemd-journal-flush.service \
    steamos-offload.target \
    steamos-boot-registration.service \
    growfs-root.service \
    growfs-home.service \
    usb-ncm-gadget@.service \
    usb-ncm-gadget@usb0.service \
    usb-ncm-dnsmasq@.service \
    usb-ncm-dnsmasq@usb0.service; do
    ln -sf /dev/null "${MNT_ROOTFS}/etc/systemd/system/${unit}" 2>/dev/null || true
done

sed -i '/\/home /d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/var /d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/var\/log /d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/var\/tmp /d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/efi /d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/persist /d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/syspersist /d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 3. Apply System Overlays from Repository
# ------------------------------------------------------------------------------
echo "=== Step 3: Applying system overlays from repository ==="
if [[ -d "${OVERLAY_DIR}" ]]; then
    cp -a "${OVERLAY_DIR}/"* "${MNT_ROOTFS}/"
fi

# Ensure executable permissions on scripts
chmod 0755 "${MNT_ROOTFS}/usr/lib/reverie/"* 2>/dev/null || true
chmod 0755 "${MNT_ROOTFS}/usr/lib/steamos/"* 2>/dev/null || true
chmod 0755 "${MNT_ROOTFS}/usr/local/bin/"* 2>/dev/null || true

# ------------------------------------------------------------------------------
# 4. Enable Systemd Units
# ------------------------------------------------------------------------------
echo "=== Step 4: Enabling essential services ==="
mkdir -p "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/reverie-growfs.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/reverie-growfs.service"
ln -sf /usr/lib/systemd/system/reverie-steamclient-fix.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/reverie-steamclient-fix.service"
ln -sf /etc/systemd/system/ayaneo-keys.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/ayaneo-keys.service"

# Remove any previous expansion flags for fresh first boot
rm -f "${MNT_ROOTFS}/etc/reverie/fs-expanded"

# ------------------------------------------------------------------------------
# 5. Install Updater, Installer and Plugins
# ------------------------------------------------------------------------------
echo "=== Step 5: Installing Reverie Updater, Installer & Decky Plugin ==="
mkdir -p "${MNT_ROOTFS}/usr/bin"
cp -f "${UPDATER_SRC}" "${MNT_ROOTFS}/usr/bin/reverie-updater"
chmod 0755 "${MNT_ROOTFS}/usr/bin/reverie-updater"
ln -sf /usr/bin/reverie-updater "${MNT_ROOTFS}/usr/bin/steamos-update"

cp -f "${INSTALLER_SRC}" "${MNT_ROOTFS}/usr/bin/reverie-installer"
chmod 0755 "${MNT_ROOTFS}/usr/bin/reverie-installer"

mkdir -p "${MNT_ROOTFS}/home/steamos/homebrew/plugins"
if [[ -d "${PLUGINS_DIR}/Reverie-Power" ]]; then
    cp -a "${PLUGINS_DIR}/Reverie-Power" "${MNT_ROOTFS}/home/steamos/homebrew/plugins/"
    chown -R 1000:1000 "${MNT_ROOTFS}/home/steamos/homebrew" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 6. Set Credentials (password: reverie)
# ------------------------------------------------------------------------------
echo "=== Step 6: Setting default credentials (password: reverie) ==="
HASH_REVERIE='$6$reveriesalt$TVHrOrcI8OliP4LuqohgUi3GGqQm/tGNGqJR8mSwvWePreM1rgRQsLvBz6rWuDOCEwse90JoZVkHLbFkP8NY.0'

if [ -f "${MNT_ROOTFS}/etc/shadow" ]; then
    sed -i "s|^steamos:[^:]*:|steamos:${HASH_REVERIE}:|" "${MNT_ROOTFS}/etc/shadow"
    sed -i "s|^root:[^:]*:|root:${HASH_REVERIE}:|" "${MNT_ROOTFS}/etc/shadow"
fi

if [ -f "${MNT_ROOTFS}/etc/group" ]; then
    if ! grep -E "^wheel:.*steamos" "${MNT_ROOTFS}/etc/group" >/dev/null 2>&1; then
        sed -i 's/^wheel:x:[0-9]*:/&steamos,/' "${MNT_ROOTFS}/etc/group" 2>/dev/null || true
    fi
fi

mkdir -p "${MNT_ROOTFS}/etc/sudoers.d"
echo "%wheel ALL=(ALL:ALL) ALL" > "${MNT_ROOTFS}/etc/sudoers.d/wheel"
chmod 0440 "${MNT_ROOTFS}/etc/sudoers.d/wheel"

# ------------------------------------------------------------------------------
# 7. Package Final Disk Image
# ------------------------------------------------------------------------------
echo "=== Step 7: Packaging 12 GiB bootable disk image ==="
sync
umount -R "${MNT_ROOTFS}"
losetup -d "${LOOP_ROOTFS}"
unset LOOP_ROOTFS

truncate -s 12G "${OUTPUT_IMG}"
sfdisk "${OUTPUT_IMG}" << 'EOF_SFDISK'
label: dos
2048,2097152,c,*
2099200,23066624,83
EOF_SFDISK

LOOP_DISK=$(losetup -fP --show "${OUTPUT_IMG}")
mkfs.vfat -F 32 -n REVERIE "${LOOP_DISK}p1"
dd if="${BUILD_ROOTFS}" of="${LOOP_DISK}p2" bs=4M status=progress conv=fsync

# Copy KERNEL to Partition 1 if available
mount "${LOOP_DISK}p1" "${MNT_ESP}"
if [[ -f "${KERNEL_PATH:-}" ]]; then
    cp -f "${KERNEL_PATH}" "${MNT_ESP}/KERNEL"
elif [[ -f "${SCRIPT_DIR}/KERNEL" ]]; then
    cp -f "${SCRIPT_DIR}/KERNEL" "${MNT_ESP}/KERNEL"
fi
sync
umount "${MNT_ESP}"

losetup -d "${LOOP_DISK}"
unset LOOP_DISK

echo "=== Step 8: Compressing image with Zstandard ==="
zstd -T0 -3 -f -k "${OUTPUT_IMG}" -o "${OUTPUT_ZST}"
sha256sum "${OUTPUT_ZST}" > "${OUTPUT_SHA}"

echo "=========================================================="
echo " BUILD SUCCESSFUL!"
echo " Image:   ${OUTPUT_IMG}"
echo " Archive: ${OUTPUT_ZST}"
echo "=========================================================="
