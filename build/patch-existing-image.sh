#!/bin/bash
set -euo pipefail

# ==============================================================================
# Reverie OS v1.0 — Fast Release Image Patching Utility
# Applies updated overlays, MangoHud presets, plugin fixes and services
# directly into an existing raw disk image in ~2 minutes.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET_IMG="${1:-${WORK_DIR:-/tmp}/reverie-os-v1.0-release.img}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Must be run with sudo/root." >&2
    exit 1
fi

if [[ ! -f "${TARGET_IMG}" ]]; then
    echo "ERROR: Target image not found at ${TARGET_IMG}." >&2
    echo "Usage: sudo $0 <path-to-disk-image>" >&2
    exit 1
fi

echo "=========================================================="
echo " Reverie OS Fast Image Patcher"
echo " Target Image: ${TARGET_IMG}"
echo " Repository:   ${REPO_DIR}"
echo "=========================================================="

MNT_DIR=$(mktemp -d -t reverie_patch.XXXXXX)

cleanup() {
    echo "=== Cleaning up mounts and loop devices ==="
    sync || true
    if mountpoint -q "${MNT_DIR}" 2>/dev/null; then
        umount -R "${MNT_DIR}" 2>/dev/null || true
    fi
    if [ -n "${LOOP_DEV:-}" ]; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
    rm -rf "${MNT_DIR}" 2>/dev/null || true
}
trap cleanup EXIT ERR INT TERM

# 1. Attach loop device
echo "=== Step 1: Mounting partition 2 (Btrfs rootfs) ==="
LOOP_DEV=$(losetup -fP --show "${TARGET_IMG}")
echo "Attached loop device: ${LOOP_DEV}"

# 2. Mount partition 2
mount -t btrfs -o subvolid=5,nodiscard "${LOOP_DEV}p2" "${MNT_DIR}"
btrfs property set "${MNT_DIR}" ro false || true
mount -o remount,rw,nodiscard "${MNT_DIR}"

echo "Mounted rootfs at ${MNT_DIR}"

# 3. Inject MangoHud configs and presets
echo "=== Step 2: Injecting MangoHud configs and Steam QAM presets ==="
mkdir -p "${MNT_DIR}/usr/share/reverie/MangoHud/steam"
mkdir -p "${MNT_DIR}/home/steamos/.config/MangoHud/steam"
mkdir -p "${MNT_DIR}/etc/skel/.config/MangoHud/steam"

cp -a "${REPO_DIR}/overlay/usr/share/reverie/MangoHud/"* "${MNT_DIR}/usr/share/reverie/MangoHud/"
cp -a "${REPO_DIR}/overlay/home/steamos/.config/MangoHud/steam/"* "${MNT_DIR}/home/steamos/.config/MangoHud/steam/"
cp -a "${REPO_DIR}/overlay/etc/skel/.config/MangoHud/steam/"* "${MNT_DIR}/etc/skel/.config/MangoHud/steam/"

# 4. Inject updated system overlays
echo "=== Step 3: Injecting updated system overlays ==="
cp -a "${REPO_DIR}/overlay/"* "${MNT_DIR}/"

# 5. Install updated updater and installer
echo "=== Step 4: Installing updated installer and updater ==="
mkdir -p "${MNT_DIR}/usr/bin"
cp -f "${REPO_DIR}/build/reverie-installer.py" "${MNT_DIR}/usr/bin/reverie-installer"
cp -f "${REPO_DIR}/updater/reverie-updater" "${MNT_DIR}/usr/bin/reverie-updater"
chmod 0755 "${MNT_DIR}/usr/bin/reverie-installer" "${MNT_DIR}/usr/bin/reverie-updater"

# 6. Update Reverie-Power plugin
echo "=== Step 5: Updating Reverie-Power Decky plugin ==="
if [[ -d "${REPO_DIR}/plugins/Reverie-Power" ]]; then
    mkdir -p "${MNT_DIR}/home/steamos/homebrew/plugins"
    cp -a "${REPO_DIR}/plugins/Reverie-Power" "${MNT_DIR}/home/steamos/homebrew/plugins/"
fi

# 7. Ensure Decky Loader and essential services are enabled
echo "=== Step 6: Enabling essential services ==="
mkdir -p "${MNT_DIR}/etc/systemd/system/multi-user.target.wants"
mkdir -p "${MNT_DIR}/etc/systemd/system/basic.target.wants"

ln -sf /usr/lib/systemd/system/plugin_loader.service "${MNT_DIR}/etc/systemd/system/multi-user.target.wants/plugin_loader.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/reverie-growfs.service "${MNT_DIR}/etc/systemd/system/multi-user.target.wants/reverie-growfs.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/reverie-steamclient-fix.service "${MNT_DIR}/etc/systemd/system/multi-user.target.wants/reverie-steamclient-fix.service" 2>/dev/null || true
ln -sf /etc/systemd/system/ayaneo-keys.service "${MNT_DIR}/etc/systemd/system/multi-user.target.wants/ayaneo-keys.service" 2>/dev/null || true
ln -sf /etc/systemd/system/ayaneo-keys.service "${MNT_DIR}/etc/systemd/system/basic.target.wants/ayaneo-keys.service" 2>/dev/null || true

# 8. Set permissions and ownership
echo "=== Step 7: Setting file permissions and ownership ==="
chmod 0755 "${MNT_DIR}/usr/lib/reverie/"* 2>/dev/null || true
chmod 0755 "${MNT_DIR}/usr/lib/steamos/"* 2>/dev/null || true
chmod 0755 "${MNT_DIR}/usr/local/bin/"* 2>/dev/null || true
chmod 0755 "${MNT_DIR}/home/steamos/Desktop/"*.desktop 2>/dev/null || true
chown -R 1000:1000 "${MNT_DIR}/home/steamos" 2>/dev/null || true
chown -R 0:0 "${MNT_DIR}/etc/sudoers.d" "${MNT_DIR}/etc/sudoers" 2>/dev/null || true
chmod 0440 "${MNT_DIR}/etc/sudoers.d/"* 2>/dev/null || true

# 9. Sync and unmount
echo "=== Step 8: Syncing filesystem and detaching loop device ==="
sync
umount -R "${MNT_DIR}"
losetup -d "${LOOP_DEV}"
unset LOOP_DEV

echo "=== PATCHING COMPLETE! ==="

# 10. Compress to .img.gz
OUTPUT_GZ="${TARGET_IMG}.gz"
OUTPUT_SHA="${OUTPUT_GZ}.sha256"
echo "=== Step 9: Compressing patched image to ${OUTPUT_GZ} ==="
if command -v pigz >/dev/null 2>&1; then
    pigz -k -f -6 "${TARGET_IMG}"
else
    gzip -k -f -6 "${TARGET_IMG}"
fi
sha256sum "${OUTPUT_GZ}" > "${OUTPUT_SHA}"

echo "=========================================================="
echo " RELEASE IMAGE READY!"
echo " Image:   ${OUTPUT_GZ}"
echo " SHA256:  $(cat "${OUTPUT_SHA}")"
echo "=========================================================="
