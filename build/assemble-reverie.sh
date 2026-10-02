#!/bin/bash
set -euo pipefail

# Reverie OS Master Image Assembler
# Assembles a bootable image (FAT32 BOOT + Btrfs rootfs) using Valve Deckard base and Reverie overlays.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OVERLAY_DIR="${REPO_DIR}/overlay"
PLUGINS_DIR="${REPO_DIR}/plugins"
UPDATER_SRC="${REPO_DIR}/updater/reverie-updater"
INSTALLER_SRC="${SCRIPT_DIR}/reverie-installer.py"

WORK_DIR="${WORK_DIR:-${REPO_DIR}/build_output}"
OUTPUT_IMG="${1:-${WORK_DIR}/reverie-os-v1.0.img}"
OUTPUT_GZ="${OUTPUT_IMG}.gz"
OUTPUT_GZ_SHA="${OUTPUT_GZ}.sha256"
OUTPUT_ZST="${OUTPUT_IMG}.zst"
OUTPUT_ZST_SHA="${OUTPUT_ZST}.sha256"

# Autodetect vanilla rootfs
VANILLA_ROOTFS="${VANILLA_ROOTFS:-}"
if [[ -z "${VANILLA_ROOTFS}" || ! -f "${VANILLA_ROOTFS}" ]]; then
    for cand in \
        "${WORK_DIR}/rootfs_vanilla.img" \
        "${REPO_DIR}/rootfs_vanilla.img" \
        "${SCRIPT_DIR}/rootfs_vanilla.img"; do
        if [[ -f "$cand" ]]; then
            VANILLA_ROOTFS="$cand"
            break
        fi
    done
fi
VANILLA_ROOTFS="${VANILLA_ROOTFS:-${WORK_DIR}/rootfs_vanilla.img}"

# Autodetect kernel modules
KERNEL_MODULES_DIR="${KERNEL_MODULES_DIR:-}"
if [[ -z "${KERNEL_MODULES_DIR}" || ! -d "${KERNEL_MODULES_DIR}" ]]; then
    for cand in \
        "${WORK_DIR}/kernel_files/lib/modules/7.2.3" \
        "${WORK_DIR}/kernel_files/lib/modules" \
        "${WORK_DIR}/modules" \
        "${REPO_DIR}/modules"; do
        if [[ -d "$cand" ]]; then
            KERNEL_MODULES_DIR="$cand"
            break
        fi
    done
fi

# Autodetect Qualcomm firmware
FIRMWARE_DIR="${FIRMWARE_DIR:-}"
if [[ -z "${FIRMWARE_DIR}" || ! -d "${FIRMWARE_DIR}" ]]; then
    for cand in \
        "${WORK_DIR}/firmware/qcom" \
        "${WORK_DIR}/firmware" \
        "${REPO_DIR}/firmware/qcom" \
        "${REPO_DIR}/firmware"; do
        if [[ -d "$cand" ]]; then
            FIRMWARE_DIR="$cand"
            break
        fi
    done
fi

# Autodetect KERNEL binary
KERNEL_PATH="${KERNEL_PATH:-}"
if [[ -z "${KERNEL_PATH}" || ! -f "${KERNEL_PATH}" ]]; then
    for cand in \
        "${SCRIPT_DIR}/KERNEL" \
        "${WORK_DIR}/KERNEL" \
        "${REPO_DIR}/KERNEL"; do
        if [[ -f "$cand" ]]; then
            KERNEL_PATH="$cand"
            break
        fi
    done
fi
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
    if [[ ! -f "${SCRIPT_DIR}/rootfs.img.caibx" ]]; then
        echo "=== Downloading rootfs.img.caibx from Valve SteamOS store... ==="
        curl -fSL --retry 3 --connect-timeout 15 -o "${SCRIPT_DIR}/rootfs.img.caibx" \
            "https://steamdeck-images.steamos.cloud/vr/20260921.6090922/deckard-20260921.6090922-0.5.0.caibx" 2>/dev/null || true
    fi
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
btrfs filesystem label "${MNT_ROOTFS}" rootfs

# ------------------------------------------------------------------------------
# 2. Kernel Modules and Qualcomm Firmware
# ------------------------------------------------------------------------------
echo "=== Step 2: Injecting SM8550 kernel modules and firmware ==="
if [[ -n "${KERNEL_MODULES_DIR}" && -d "${KERNEL_MODULES_DIR}" ]]; then
    echo "Installing kernel modules from ${KERNEL_MODULES_DIR}..."
    mkdir -p "${MNT_ROOTFS}/usr/lib/modules"
    if [[ -d "${KERNEL_MODULES_DIR}/7.2.3" ]]; then
        cp -a "${KERNEL_MODULES_DIR}/7.2.3" "${MNT_ROOTFS}/usr/lib/modules/"
    elif [[ -f "${KERNEL_MODULES_DIR}/modules.dep" ]]; then
        cp -a "${KERNEL_MODULES_DIR}" "${MNT_ROOTFS}/usr/lib/modules/"
    else
        cp -a "${KERNEL_MODULES_DIR}/"* "${MNT_ROOTFS}/usr/lib/modules/"
    fi
fi

if [[ -n "${FIRMWARE_DIR}" && -d "${FIRMWARE_DIR}" ]]; then
    echo "Installing Qualcomm firmware from ${FIRMWARE_DIR}..."
    mkdir -p "${MNT_ROOTFS}/usr/lib/firmware/qcom"
    cp -a "${FIRMWARE_DIR}/"* "${MNT_ROOTFS}/usr/lib/firmware/qcom/"
fi

# Fallback symlinks for GPU firmware compatibility
if [[ -f "${MNT_ROOTFS}/usr/lib/firmware/qcom/a740_sqe.fw" ]]; then
    ln -sf qcom/a740_sqe.fw "${MNT_ROOTFS}/usr/lib/firmware/a740_sqe.fw" 2>/dev/null || true
fi
if [[ -f "${MNT_ROOTFS}/usr/lib/firmware/qcom/gmu_gen70200.bin" ]]; then
    ln -sf qcom/gmu_gen70200.bin "${MNT_ROOTFS}/usr/lib/firmware/gmu_gen70200.bin" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 3. VR Headset Neutralization & Fstab Cleanup
# ------------------------------------------------------------------------------
echo "=== Step 3: Masking VR Headset services & cleaning fstab ==="
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
    esp.mount \
    esp.automount \
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
    usb-ncm-dnsmasq@usb0.service \
    set-wifi-mac-address.service \
    iwd.service \
    gpu-trace.service; do
    ln -sf /dev/null "${MNT_ROOTFS}/etc/systemd/system/${unit}" 2>/dev/null || true
done

# Mask SteamVR user services
mkdir -p "${MNT_ROOTFS}/etc/systemd/user"
for user_unit in steamvr.service steamvr-logs.service steamvr-nested-desktop.service steamvr-proxmicmute.service steamvr-v4l2cam.service; do
    ln -sf /dev/null "${MNT_ROOTFS}/etc/systemd/user/${user_unit}" 2>/dev/null || true
done

# Disable VR microphone/spatial filters in WirePlumber
if [[ -d "${MNT_ROOTFS}/etc/wireplumber/wireplumber.conf.d" ]]; then
    for conf in 10-access.conf 40-mic-processing.conf 50-alsa-config.conf 51-alsa-disable.conf 60-spatial-audio.conf 70-spatial-node-config.conf 99-sm8550-no-vr-spatial.conf; do
        if [[ -f "${MNT_ROOTFS}/etc/wireplumber/wireplumber.conf.d/${conf}" ]]; then
            mv "${MNT_ROOTFS}/etc/wireplumber/wireplumber.conf.d/${conf}" "${MNT_ROOTFS}/etc/wireplumber/wireplumber.conf.d/${conf}.disabled" 2>/dev/null || true
        fi
    done
fi

# Decouple gamescope-session from steamvr
if [[ -f "${MNT_ROOTFS}/usr/lib/systemd/user/gamescope-session.service" ]]; then
    sed -i 's/PartOf=steamvr.service/#PartOf=steamvr.service/' "${MNT_ROOTFS}/usr/lib/systemd/user/gamescope-session.service" 2>/dev/null || true
    sed -i 's/Requires=steamvr.service/#Requires=steamvr.service/' "${MNT_ROOTFS}/usr/lib/systemd/user/gamescope-session.service" 2>/dev/null || true
fi

# Clean fstab of all VR headset partition sets
sed -i '/by-part/d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/persist/d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/syspersist/d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/home/d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/var/d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/efi/d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/esp/d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true

# Force handheld steamdeck VARIANT_ID so Steam Gamepad UI never switches to VR mode
for _osr in "${MNT_ROOTFS}/etc/os-release" "${MNT_ROOTFS}/usr/lib/os-release"; do
    if [[ -f "$_osr" ]]; then
        sed -i 's/^VARIANT_ID=.*/VARIANT_ID="steamdeck"/' "$_osr" 2>/dev/null || true
        grep -q '^VARIANT_ID=' "$_osr" || echo 'VARIANT_ID="steamdeck"' >> "$_osr"
    fi
done

# ------------------------------------------------------------------------------
# 4. Apply System Overlays from Repository
# ------------------------------------------------------------------------------
echo "=== Step 4: Applying system overlays from repository ==="
if [[ -d "${OVERLAY_DIR}" ]]; then
    cp -a "${OVERLAY_DIR}/"* "${MNT_ROOTFS}/"
fi

# Ensure executable permissions on scripts and binaries
chmod 0755 "${MNT_ROOTFS}/usr/lib/reverie/"* 2>/dev/null || true
chmod 0755 "${MNT_ROOTFS}/usr/lib/steamos/"* 2>/dev/null || true
chmod 0755 "${MNT_ROOTFS}/usr/local/bin/"* 2>/dev/null || true
chmod 0755 "${MNT_ROOTFS}/usr/bin/"* 2>/dev/null || true
chmod 0755 "${MNT_ROOTFS}/home/steamos/Desktop/"*.desktop 2>/dev/null || true
chown -R 1000:1000 "${MNT_ROOTFS}/home/steamos" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 5. Enable Systemd Units
# ------------------------------------------------------------------------------
echo "=== Step 5: Enabling essential services ==="
mkdir -p "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants"
mkdir -p "${MNT_ROOTFS}/etc/systemd/system/basic.target.wants"
mkdir -p "${MNT_ROOTFS}/etc/systemd/system/sound.target.wants"
mkdir -p "${MNT_ROOTFS}/etc/systemd/system/bluetooth.target.wants"
mkdir -p "${MNT_ROOTFS}/etc/systemd/system/NetworkManager.service.wants"
mkdir -p "${MNT_ROOTFS}/etc/systemd/user/default.target.wants"

ln -sf /usr/lib/systemd/system/reverie-growfs.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/reverie-growfs.service"
ln -sf /usr/lib/systemd/system/reverie-steamclient-fix.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/reverie-steamclient-fix.service"
ln -sf /etc/systemd/system/ayaneo-keys.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/ayaneo-keys.service"
ln -sf /etc/systemd/system/ayaneo-keys.service "${MNT_ROOTFS}/etc/systemd/system/basic.target.wants/ayaneo-keys.service"
ln -sf /usr/lib/systemd/system/plugin_loader.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/plugin_loader.service" 2>/dev/null || true

# SM8550 Hardware & Runtime Services
ln -sf /usr/lib/systemd/system/sm8550-restore-privs.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/sm8550-restore-privs.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/sm8550-fixpad.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/sm8550-fixpad.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/sm8550-audio-setup.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/sm8550-audio-setup.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/sm8550-audio-setup.service "${MNT_ROOTFS}/etc/systemd/system/sound.target.wants/sm8550-audio-setup.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/sm8550-bluetooth-setup.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/sm8550-bluetooth-setup.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/sm8550-bluetooth-setup.service "${MNT_ROOTFS}/etc/systemd/system/bluetooth.target.wants/sm8550-bluetooth-setup.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/sm8550-wifi-backend.path "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/sm8550-wifi-backend.path" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/sm8550-wifi-backend.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/sm8550-wifi-backend.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/sm8550-wifi-backend.service "${MNT_ROOTFS}/etc/systemd/system/NetworkManager.service.wants/sm8550-wifi-backend.service" 2>/dev/null || true

# User services
ln -sf /usr/lib/systemd/user/sm8550-audio-pipewire.service "${MNT_ROOTFS}/etc/systemd/user/default.target.wants/sm8550-audio-pipewire.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/user/sm8550-volume-keys.service "${MNT_ROOTFS}/etc/systemd/user/default.target.wants/sm8550-volume-keys.service" 2>/dev/null || true

# Remove any previous expansion flags for fresh first boot
rm -f "${MNT_ROOTFS}/etc/reverie/fs-expanded"

# ------------------------------------------------------------------------------
# 6. Install Updater, Installer and Plugins
# ------------------------------------------------------------------------------
echo "=== Step 6: Installing Reverie Updater, Installer & Decky Plugin ==="
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
# 7. Set Credentials (password: reverie)
# ------------------------------------------------------------------------------
echo "=== Step 7: Setting default credentials (password: reverie) ==="
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
chown -R 0:0 "${MNT_ROOTFS}/etc/sudoers.d" "${MNT_ROOTFS}/etc/sudoers" 2>/dev/null || true
chmod 0440 "${MNT_ROOTFS}/etc/sudoers.d/"* 2>/dev/null || true

# ------------------------------------------------------------------------------
# 8. Package Final Disk Image
# ------------------------------------------------------------------------------
echo "=== Step 8: Packaging 12 GiB bootable disk image ==="
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

# Copy KERNEL to Partition 1
mount "${LOOP_DISK}p1" "${MNT_ESP}"
if [[ -n "${KERNEL_PATH:-}" && -f "${KERNEL_PATH}" ]]; then
    echo "Installing kernel from ${KERNEL_PATH} to Partition 1 (ESP)..."
    cp -f "${KERNEL_PATH}" "${MNT_ESP}/KERNEL"
elif [[ -f "${SCRIPT_DIR}/KERNEL" ]]; then
    echo "Installing kernel from ${SCRIPT_DIR}/KERNEL to Partition 1 (ESP)..."
    cp -f "${SCRIPT_DIR}/KERNEL" "${MNT_ESP}/KERNEL"
else
    echo "ERROR: KERNEL binary not found! Handheld will fail to boot without KERNEL on partition 1." >&2
    sync
    umount "${MNT_ESP}" || true
    losetup -d "${LOOP_DISK}" || true
    exit 1
fi
sync
umount "${MNT_ESP}"

losetup -d "${LOOP_DISK}"
unset LOOP_DISK

echo "=== Step 9: Compressing release disk images ==="
echo "Generating .img.gz archive..."
if command -v pigz >/dev/null 2>&1; then
    pigz -k -f -6 "${OUTPUT_IMG}"
else
    gzip -k -f -6 "${OUTPUT_IMG}"
fi
sha256sum "${OUTPUT_GZ}" > "${OUTPUT_GZ_SHA}"

if command -v zstd >/dev/null 2>&1; then
    echo "Generating .img.zst archive..."
    zstd -T0 -3 -f -k "${OUTPUT_IMG}" -o "${OUTPUT_ZST}"
    sha256sum "${OUTPUT_ZST}" > "${OUTPUT_ZST_SHA}"
fi

echo "=========================================================="
echo " BUILD SUCCESSFUL!"
echo " Image:   ${OUTPUT_IMG}"
echo " Gzip:    ${OUTPUT_GZ}"
if [[ -f "${OUTPUT_ZST}" ]]; then
    echo " Zstd:    ${OUTPUT_ZST}"
fi
echo "=========================================================="
