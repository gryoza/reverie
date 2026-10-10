#!/bin/bash
set -euo pipefail

# ==============================================================================
# Reverie OS v1.0 Master Image Assembler
# Assembles a standalone, portable bootable Reverie OS image
# (MBR / FAT32 BOOT + Btrfs rootfs) using official Valve Deckard base
# and Reverie system overlays.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OVERLAY_DIR="${REPO_DIR}/overlay"
PLUGINS_DIR="${REPO_DIR}/plugins"
UPDATER_SRC="${REPO_DIR}/updater/reverie-updater"
INSTALLER_SRC="${SCRIPT_DIR}/reverie-installer.py"
WORK_DIR="${WORK_DIR:-${REPO_DIR}/build_output}"

# Parse optional arguments:
# Usage: sudo ./assemble-reverie.sh [path-to-rootfs_vanilla.img] [output-image-path]
# Or:    sudo ./assemble-reverie.sh [output-image-path]
ARG1="${1:-}"
ARG2="${2:-}"

VANILLA_ROOTFS="${VANILLA_ROOTFS:-}"
OUTPUT_IMG="${OUTPUT_IMG:-}"

if [[ -n "${ARG1}" ]]; then
    if [[ -f "${ARG1}" ]]; then
        VANILLA_ROOTFS="${ARG1}"
        if [[ -n "${ARG2}" ]]; then
            OUTPUT_IMG="${ARG2}"
        fi
    else
        OUTPUT_IMG="${ARG1}"
    fi
fi

OUTPUT_IMG="${OUTPUT_IMG:-${WORK_DIR}/reverie-os-v1.1.img}"
OUTPUT_GZ="${OUTPUT_IMG}.gz"
OUTPUT_GZ_SHA="${OUTPUT_GZ}.sha256"
OUTPUT_ZST="${OUTPUT_IMG}.zst"
OUTPUT_ZST_SHA="${OUTPUT_ZST}.sha256"

# ------------------------------------------------------------------------------
# Component Autodetection (all paths relative to REPO_DIR / SCRIPT_DIR / WORK_DIR)
# ------------------------------------------------------------------------------

# 1. Autodetect vanilla rootfs if not explicitly set
if [[ -z "${VANILLA_ROOTFS}" || ! -f "${VANILLA_ROOTFS}" ]]; then
    for cand in \
        "${WORK_DIR}/rootfs_vanilla.img" \
        "${REPO_DIR}/boot/rootfs_vanilla.img" \
        "${REPO_DIR}/rootfs_vanilla.img" \
        "${SCRIPT_DIR}/rootfs_vanilla.img" \
        "${REPO_DIR}/../deckard/rootfs_vanilla.img"; do
        if [[ -f "$cand" ]]; then
            VANILLA_ROOTFS="$cand"
            break
        fi
    done
fi
VANILLA_ROOTFS="${VANILLA_ROOTFS:-${WORK_DIR}/rootfs_vanilla.img}"

# 2. Autodetect universal KERNEL binary
KERNEL_PATH="${KERNEL_PATH:-}"
if [[ -z "${KERNEL_PATH}" || ! -f "${KERNEL_PATH}" ]]; then
    for cand in \
        "${REPO_DIR}/boot/KERNEL" \
        "${REPO_DIR}/KERNEL" \
        "${SCRIPT_DIR}/KERNEL" \
        "${WORK_DIR}/KERNEL" \
        "${REPO_DIR}/../deckard/KERNEL_GOLDEN_UNIVERSAL"; do
        if [[ -f "$cand" ]]; then
            KERNEL_PATH="$cand"
            break
        fi
    done
fi

# 3. Autodetect SM8550 / Linux kernel modules
KERNEL_MODULES_DIR="${KERNEL_MODULES_DIR:-}"
if [[ -z "${KERNEL_MODULES_DIR}" || ! -d "${KERNEL_MODULES_DIR}" ]]; then
    for cand in \
        "${REPO_DIR}/modules/7.2.3" \
        "${REPO_DIR}/modules" \
        "${WORK_DIR}/kernel_files/lib/modules/7.2.3" \
        "${WORK_DIR}/modules" \
        "${REPO_DIR}/../deckard/kernel_files/lib/modules/7.2.3"; do
        if [[ -d "$cand" ]]; then
            KERNEL_MODULES_DIR="$cand"
            break
        fi
    done
fi

# 4. Autodetect Qualcomm Adreno / SM8550 firmware
FIRMWARE_DIR="${FIRMWARE_DIR:-}"
if [[ -z "${FIRMWARE_DIR}" || ! -d "${FIRMWARE_DIR}" ]]; then
    for cand in \
        "${REPO_DIR}/firmware/qcom" \
        "${REPO_DIR}/firmware" \
        "${WORK_DIR}/firmware/qcom" \
        "${WORK_DIR}/firmware" \
        "${REPO_DIR}/../armada/system_files/usr/lib/firmware/qcom"; do
        if [[ -d "$cand" ]]; then
            FIRMWARE_DIR="$cand"
            break
        fi
    done
fi

# 5. Autodetect Steam handheld client bootstrap archive
STEAM_BOOTSTRAP_TAR="${STEAM_BOOTSTRAP_TAR:-}"
if [[ -z "${STEAM_BOOTSTRAP_TAR}" || ! -f "${STEAM_BOOTSTRAP_TAR}" ]]; then
    for cand in \
        "${REPO_DIR}/assets/steam-bootstrap.tar.zst" \
        "${REPO_DIR}/assets/steam-client-arm64-bootstrap.tar.zst" \
        "${WORK_DIR}/steam-bootstrap.tar.zst" \
        "${REPO_DIR}/steam-bootstrap.tar.zst"; do
        if [[ -f "$cand" ]]; then
            STEAM_BOOTSTRAP_TAR="$cand"
            break
        fi
    done
fi

BUILD_ROOTFS="${WORK_DIR}/rootfs_build.img"

echo "=========================================================="
echo " Reverie OS Image Assembler"
echo " Repo Dir:      ${REPO_DIR}"
echo " Output Image:  ${OUTPUT_IMG}"
echo " Vanilla Base:  ${VANILLA_ROOTFS}"
echo " Kernel Binary: ${KERNEL_PATH:-<NOT FOUND>}"
echo " Kernel Mod:    ${KERNEL_MODULES_DIR:-<NOT FOUND>}"
echo " Firmware:      ${FIRMWARE_DIR:-<NOT FOUND>}"
echo " Steam Client:  ${STEAM_BOOTSTRAP_TAR:-<NOT FOUND>}"
echo "=========================================================="

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Must be run with sudo/root." >&2
    exit 1
fi

# Strict validation of required hardware components
if [[ -z "${KERNEL_PATH}" || ! -f "${KERNEL_PATH}" ]]; then
    echo "ERROR: Universal KERNEL binary not found!" >&2
    echo "Please place KERNEL in ${REPO_DIR}/boot/KERNEL or provide KERNEL_PATH." >&2
    exit 1
fi

if [[ -z "${KERNEL_MODULES_DIR}" || ! -d "${KERNEL_MODULES_DIR}" ]]; then
    echo "ERROR: Kernel modules directory not found! Required for hardware drivers." >&2
    echo "Please place modules in ${REPO_DIR}/modules/7.2.3 or provide KERNEL_MODULES_DIR." >&2
    exit 1
fi

if [[ -z "${FIRMWARE_DIR}" || ! -d "${FIRMWARE_DIR}" ]]; then
    echo "ERROR: Qualcomm firmware directory not found! Required for GPU/display initialization." >&2
    echo "Please place firmware in ${REPO_DIR}/firmware/qcom or provide FIRMWARE_DIR." >&2
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
echo "Installing kernel modules from ${KERNEL_MODULES_DIR}..."
mkdir -p "${MNT_ROOTFS}/usr/lib/modules"
if [[ -d "${KERNEL_MODULES_DIR}/7.2.3" ]]; then
    cp -a "${KERNEL_MODULES_DIR}/7.2.3" "${MNT_ROOTFS}/usr/lib/modules/"
elif [[ -f "${KERNEL_MODULES_DIR}/modules.dep" ]]; then
    # Directory itself is the version directory
    kver=$(basename "${KERNEL_MODULES_DIR}")
    mkdir -p "${MNT_ROOTFS}/usr/lib/modules/${kver}"
    cp -a "${KERNEL_MODULES_DIR}/"* "${MNT_ROOTFS}/usr/lib/modules/${kver}/"
else
    cp -a "${KERNEL_MODULES_DIR}/"* "${MNT_ROOTFS}/usr/lib/modules/"
fi

echo "Installing Qualcomm firmware from ${FIRMWARE_DIR}..."
mkdir -p "${MNT_ROOTFS}/usr/lib/firmware/qcom"
cp -a "${FIRMWARE_DIR}/"* "${MNT_ROOTFS}/usr/lib/firmware/qcom/"

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
    gpu-trace.service \
    deckard-boot-images.service; do
    ln -sf /dev/null "${MNT_ROOTFS}/etc/systemd/system/${unit}" 2>/dev/null || true
done

# Mask SteamVR user services
mkdir -p "${MNT_ROOTFS}/etc/systemd/user"
for user_unit in steamvr.service steamvr-logs.service steamvr-nested-desktop.service steamvr-proxmicmute.service steamvr-v4l2cam.service; do
    ln -sf /dev/null "${MNT_ROOTFS}/etc/systemd/user/${user_unit}" 2>/dev/null || true
done

# Fix power button sleep by decoupling steamos-powerbuttond from steamvr.service
if [[ -f "${MNT_ROOTFS}/usr/lib/systemd/user/steamos-powerbuttond.service" ]]; then
    sed -i '/Requisite=steamvr.service/d' "${MNT_ROOTFS}/usr/lib/systemd/user/steamos-powerbuttond.service" 2>/dev/null || true
fi

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
sed -i '/PARTLABEL=syspersist/d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/home/d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/var/d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/efi/d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true
sed -i '/\/esp/d' "${MNT_ROOTFS}/etc/fstab" 2>/dev/null || true

# Set hostname to reverie
echo "reverie" > "${MNT_ROOTFS}/etc/hostname"
chmod 0644 "${MNT_ROOTFS}/etc/hostname"

# Force handheld steamdeck VARIANT_ID so Steam Gamepad UI never switches to VR mode
for _osr in "${MNT_ROOTFS}/etc/os-release" "${MNT_ROOTFS}/usr/lib/os-release"; do
    if [[ -f "$_osr" ]]; then
        sed -i 's/^VARIANT_ID=.*/VARIANT_ID="steamdeck"/' "$_osr" 2>/dev/null || true
        grep -q '^VARIANT_ID=' "$_osr" || echo 'VARIANT_ID="steamdeck"' >> "$_osr"
    fi
done

# Fix Valve Steam desktop typo (/usr/share/application -> /usr/share/applications)
mkdir -p "${MNT_ROOTFS}/usr/lib/steam"
ln -sf /usr/share/applications/steam.desktop "${MNT_ROOTFS}/usr/lib/steam/steam.desktop" 2>/dev/null || true

# Fix SteamVR PulseAudio library symlink
if [[ -d "${MNT_ROOTFS}/opt/steamvr/bin/linuxarm64" ]]; then
    ln -sf /usr/lib/pulseaudio/libpulsecommon-17.0.so "${MNT_ROOTFS}/opt/steamvr/bin/linuxarm64/libpulsecommon-10.0.so" 2>/dev/null || true
fi

# Fix FEX guestos relative symlink and CA certificates
if [[ -e "${MNT_ROOTFS}/usr/share/guestos/fex-mesa/usr/lib32/libkeyutils.so" ]]; then
    ln -sf libkeyutils.so.1 "${MNT_ROOTFS}/usr/share/guestos/fex-mesa/usr/lib32/libkeyutils.so" 2>/dev/null || true
fi
if [[ -d "${MNT_ROOTFS}/etc/ca-certificates" ]] && [[ -d "${MNT_ROOTFS}/usr/share/guestos/fex-mesa/etc" ]]; then
    mkdir -p "${MNT_ROOTFS}/usr/share/guestos/fex-mesa/etc/ca-certificates"
    cp -a "${MNT_ROOTFS}/etc/ca-certificates/"* "${MNT_ROOTFS}/usr/share/guestos/fex-mesa/etc/ca-certificates/" 2>/dev/null || true
fi

# Setup Pacman database directory symlink for compatibility
mkdir -p "${MNT_ROOTFS}/var/lib"
ln -sfn /usr/lib/holo/pacmandb "${MNT_ROOTFS}/var/lib/pacman" 2>/dev/null || true

# Clean dead ALSA UCM2 symlinks
rm -f "${MNT_ROOTFS}/usr/share/alsa/ucm2/conf.d/sm8550/AYN-Thor.conf" \
      "${MNT_ROOTFS}/usr/share/alsa/ucm2/conf.d/sm8550/ayn-AYNThor-.conf" \
      "${MNT_ROOTFS}/usr/share/alsa/ucm2/conf.d/sm8550/SM8550-HDK.conf" 2>/dev/null || true

# Clean stray video links
rm -f "${MNT_ROOTFS}/video-dec0" "${MNT_ROOTFS}/video-enc0" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 4. Install Steam Client Handheld Bootstrap
# ------------------------------------------------------------------------------
if [[ -n "${STEAM_BOOTSTRAP_TAR}" && -f "${STEAM_BOOTSTRAP_TAR}" ]]; then
    echo "=== Step 4: Installing Steam handheld client bootstrap from ${STEAM_BOOTSTRAP_TAR} ==="
    mkdir -p "${MNT_ROOTFS}/home/steamos/.local/share/Steam"
    tar --zstd -xf "${STEAM_BOOTSTRAP_TAR}" -C "${MNT_ROOTFS}/home/steamos/.local/share/Steam"
    chown -R 1000:1000 "${MNT_ROOTFS}/home/steamos"
else
    echo "WARNING: Steam client bootstrap archive not found! Steam client may need initial internet setup." >&2
fi

# ------------------------------------------------------------------------------
# 5. Apply System Overlays from Repository
# ------------------------------------------------------------------------------
echo "=== Step 5: Applying system overlays from repository ==="
if [[ -d "${OVERLAY_DIR}" ]]; then
    cp -a "${OVERLAY_DIR}/"* "${MNT_ROOTFS}/"
fi

# Remove legacy broken Masies drop-in if present
rm -f "${MNT_ROOTFS}/usr/lib/systemd/user/steam.service.d/99-odin.conf" 2>/dev/null || true

# Clean broken video symlinks in Steam runtime
find "${MNT_ROOTFS}/home/steamos/.local/share/Steam/steamrt"*"/video" -xtype l -delete 2>/dev/null || true

# Ensure executable permissions on scripts and binaries
chmod 0755 "${MNT_ROOTFS}/usr/lib/reverie/"* 2>/dev/null || true
chmod 0755 "${MNT_ROOTFS}/usr/lib/steamos/"* 2>/dev/null || true
chmod 0755 "${MNT_ROOTFS}/usr/local/bin/"* 2>/dev/null || true
chmod 0755 "${MNT_ROOTFS}/usr/bin/"* 2>/dev/null || true
chmod 0755 "${MNT_ROOTFS}/home/steamos/Desktop/"*.desktop 2>/dev/null || true
chmod -R 0755 "${MNT_ROOTFS}/usr/share/icons" "${MNT_ROOTFS}/usr/share/applications" 2>/dev/null || true
chown -R 0:0 "${MNT_ROOTFS}/usr/share/icons" "${MNT_ROOTFS}/usr/share/applications" 2>/dev/null || true
chown -R 1000:1000 "${MNT_ROOTFS}/home/steamos" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 6. Enable Essential Systemd Units
# ------------------------------------------------------------------------------
echo "=== Step 6: Enabling essential services ==="
mkdir -p "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants"
mkdir -p "${MNT_ROOTFS}/etc/systemd/system/basic.target.wants"
mkdir -p "${MNT_ROOTFS}/etc/systemd/system/graphical.target.wants"
mkdir -p "${MNT_ROOTFS}/etc/systemd/system/sound.target.wants"
mkdir -p "${MNT_ROOTFS}/etc/systemd/system/bluetooth.target.wants"
mkdir -p "${MNT_ROOTFS}/etc/systemd/system/NetworkManager.service.wants"
mkdir -p "${MNT_ROOTFS}/etc/systemd/user/default.target.wants"
mkdir -p "${MNT_ROOTFS}/usr/lib/systemd/user/gamescope-session.target.wants"

ln -sf /usr/lib/systemd/system/reverie-growfs.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/reverie-growfs.service"
ln -sf /usr/lib/systemd/system/reverie-steamclient-fix.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/reverie-steamclient-fix.service"
ln -sf /etc/systemd/system/ayaneo-keys.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/ayaneo-keys.service"
ln -sf /etc/systemd/system/ayaneo-keys.service "${MNT_ROOTFS}/etc/systemd/system/basic.target.wants/ayaneo-keys.service"
ln -sf /usr/lib/systemd/system/plugin_loader.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/plugin_loader.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/inputplumber.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/inputplumber.service" 2>/dev/null || true

# Diagnostic logging services
ln -sf /usr/lib/systemd/system/reverie-boot-debug.service "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/reverie-boot-debug.service" 2>/dev/null || true
ln -sf /usr/lib/systemd/system/reverie-boot-debug-late.service "${MNT_ROOTFS}/etc/systemd/system/graphical.target.wants/reverie-boot-debug-late.service" 2>/dev/null || true

# Gamescope power button daemon
ln -sf ../steamos-powerbuttond.service "${MNT_ROOTFS}/usr/lib/systemd/user/gamescope-session.target.wants/steamos-powerbuttond.service" 2>/dev/null || true

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
# 7. Install Updater, Installer and Plugins
# ------------------------------------------------------------------------------
echo "=== Step 7: Installing Reverie Updater, Installer & Decky Plugin ==="
mkdir -p "${MNT_ROOTFS}/usr/bin"
cp -f "${UPDATER_SRC}" "${MNT_ROOTFS}/usr/bin/reverie-updater"
chmod 0755 "${MNT_ROOTFS}/usr/bin/reverie-updater"
chmod 0755 "${MNT_ROOTFS}/usr/bin/steamos-update" 2>/dev/null || true

cp -f "${INSTALLER_SRC}" "${MNT_ROOTFS}/usr/bin/reverie-installer"
chmod 0755 "${MNT_ROOTFS}/usr/bin/reverie-installer"

mkdir -p "${MNT_ROOTFS}/home/steamos/homebrew/plugins"
if [[ -d "${PLUGINS_DIR}/Reverie-Power" ]]; then
    cp -a "${PLUGINS_DIR}/Reverie-Power" "${MNT_ROOTFS}/home/steamos/homebrew/plugins/"
    # Strip development sources, configs and bytecode from deployed plugin
    rm -rf "${MNT_ROOTFS}/home/steamos/homebrew/plugins/Reverie-Power/src" \
           "${MNT_ROOTFS}/home/steamos/homebrew/plugins/Reverie-Power/build.sh" \
           "${MNT_ROOTFS}/home/steamos/homebrew/plugins/Reverie-Power/rollup.config.js" \
           "${MNT_ROOTFS}/home/steamos/homebrew/plugins/Reverie-Power/tsconfig.json" \
           "${MNT_ROOTFS}/home/steamos/homebrew/plugins/Reverie-Power/"__pycache__ \
           "${MNT_ROOTFS}/home/steamos/homebrew/plugins/Reverie-Power/py_modules/reverie_power/"__pycache__ 2>/dev/null || true
    chown -R 1000:1000 "${MNT_ROOTFS}/home/steamos/homebrew" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 8. Set Credentials & Sanitize Image
# ------------------------------------------------------------------------------
echo "=== Step 8: Setting credentials and sanitizing image ==="
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

# Reset machine-id and hostname for clean first boot
echo -n "" > "${MNT_ROOTFS}/etc/machine-id"
chmod 0444 "${MNT_ROOTFS}/etc/machine-id"
mkdir -p "${MNT_ROOTFS}/var/lib/dbus"
ln -sf /etc/machine-id "${MNT_ROOTFS}/var/lib/dbus/machine-id" 2>/dev/null || true

# Remove embedded SSH host keys (generated on first boot by sshdgenkeys.service)
rm -f "${MNT_ROOTFS}/var/lib/overlays/etc/upper/ssh/ssh_host_"* \
      "${MNT_ROOTFS}/etc/ssh/ssh_host_"* 2>/dev/null || true

# Clear coredumps and stale sessions
rm -rf "${MNT_ROOTFS}/var/lib/systemd/coredump/"* 2>/dev/null || true
rm -rf "${MNT_ROOTFS}/home/.steamos/offload/var/lib/systemd/coredump/"* 2>/dev/null || true

# Clear active Steam session tokens, locks, and temporary files
rm -f "${MNT_ROOTFS}/home/steamos/.steam/steam.token" \
      "${MNT_ROOTFS}/home/steamos/.steam/steam.pid" \
      "${MNT_ROOTFS}/home/steamos/.steam/steam.pipe" \
      "${MNT_ROOTFS}/home/steamos/.steam/registry.vdf."*.tmp \
      "${MNT_ROOTFS}/home/steamos/.local/share/Steam/.cef-enable-remote-debugging" 2>/dev/null || true
rm -rf "${MNT_ROOTFS}/home/steamos/.local/share/Steam/steamapps/common/Steam Controller Configs" 2>/dev/null || true
rm -rf "${MNT_ROOTFS}/home/steamos/.local/share/Steam/steamapps/workshop/appworkshop_241100.acf" 2>/dev/null || true
rm -rf "${MNT_ROOTFS}/home/steamos/.local/share/Steam/steamapps/workshop/content/241100" 2>/dev/null || true
find "${MNT_ROOTFS}/home/steamos/.local/share/Steam/steamapps/" -name "*.lock" -delete 2>/dev/null || true
find "${MNT_ROOTFS}/home/steamos/.local/share/Steam/steamapps/" -name "*.reg.old" -delete 2>/dev/null || true

# Clear KDE session restore state
rm -rf "${MNT_ROOTFS}/home/steamos/.config/session/"* 2>/dev/null || true
rm -f "${MNT_ROOTFS}/home/steamos/.local/state/dolphinstaterc" \
      "${MNT_ROOTFS}/home/steamos/.local/state/konsolestaterc" \
      "${MNT_ROOTFS}/home/steamos/.local/state/plasmasessionrestorestaterc" \
      "${MNT_ROOTFS}/home/steamos/.local/state/plasmashellstaterc" \
      "${MNT_ROOTFS}/home/steamos/.local/state/systemsettingsstaterc" \
      "${MNT_ROOTFS}/home/steamos/.local/share/baloo/index-lock" \
      "${MNT_ROOTFS}/home/steamos/.local/share/user-places.xbel.bak" \
      "${MNT_ROOTFS}/home/steamos/.local/share/user-places.xbel.tbcache" \
      "${MNT_ROOTFS}/etc/xdg/plasma-workspace/env/set-return-icon.sh" \
      "${MNT_ROOTFS}/home/steamos/.cache/ksycoca"* \
      "${MNT_ROOTFS}/home/steamos/.cache/icon-cache"* 2>/dev/null || true
rm -rf "${MNT_ROOTFS}/home/steamos/.local/share/icons/hicolor" 2>/dev/null || true

# Remove obsolete/legacy scripts and debug logs
rm -rf "${MNT_ROOTFS}/usr/lib/steamos/sm8550-boot-debug" \
       "${MNT_ROOTFS}/usr/lib/systemd/system/sm8550-boot-debug.service" \
       "${MNT_ROOTFS}/usr/lib/systemd/system/sm8550-boot-debug-late.service" \
       "${MNT_ROOTFS}/etc/systemd/system/multi-user.target.wants/sm8550-boot-debug.service" \
       "${MNT_ROOTFS}/etc/systemd/system/graphical.target.wants/sm8550-boot-debug-late.service" \
       "${MNT_ROOTFS}/usr/bin/reverie-dump-logs" \
       "${MNT_ROOTFS}/home/steamos/Desktop/reverie-dump-logs.desktop" \
       "${MNT_ROOTFS}/home/steamos/BOOT-DEBUG-"*.txt \
       "${MNT_ROOTFS}/home/steamos/GAMESCOPE-DEBUG."* \
       "${MNT_ROOTFS}/home/steamos/START-GAMESCOPE-DEBUG.txt" \
       "${MNT_ROOTFS}/home/steamos/sm8550-"*.log \
       "${MNT_ROOTFS}/home/steamos/reverie-debug-"*.tar.gz 2>/dev/null || true

# Clear system journals, logs, and private tmp
truncate -s 0 "${MNT_ROOTFS}/var/log/firewalld" 2>/dev/null || true
truncate -s 0 "${MNT_ROOTFS}/var/log/wtmp" 2>/dev/null || true
truncate -s 0 "${MNT_ROOTFS}/var/log/btmp" 2>/dev/null || true
truncate -s 0 "${MNT_ROOTFS}/var/log/lastlog" 2>/dev/null || true
rm -rf "${MNT_ROOTFS}/var/log/journal/"* 2>/dev/null || true
rm -rf "${MNT_ROOTFS}/var/log/steamos-log-submitter/"* 2>/dev/null || true
rm -rf "${MNT_ROOTFS}/var/tmp/systemd-private-"* 2>/dev/null || true
rm -f "${MNT_ROOTFS}/var/lib/overlays/etc/upper/pacman.d/gnupg/S."* \
      "${MNT_ROOTFS}/etc/pacman.d/gnupg/S."* \
      "${MNT_ROOTFS}/home/steamos/.local/share/Steam/config/htmlcache/Singleton"* \
      "${MNT_ROOTFS}/var/log/README" 2>/dev/null || true

# Set SteamOS update branch default to rel
mkdir -p "${MNT_ROOTFS}/var/lib/steamos"
echo "rel" > "${MNT_ROOTFS}/var/lib/steamos/selected-branch"
chown -R 1000:1000 "${MNT_ROOTFS}/var/lib/steamos" 2>/dev/null || true
chmod 0775 "${MNT_ROOTFS}/var/lib/steamos" 2>/dev/null || true
chmod 0664 "${MNT_ROOTFS}/var/lib/steamos/selected-branch" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 9. Package Final Disk Image
# ------------------------------------------------------------------------------
echo "=== Step 9: Packaging 12 GiB bootable disk image ==="
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

# Setup Partition 1 (ESP / REVERIE): Kernel and Diagnostic Logs
mount "${LOOP_DISK}p1" "${MNT_ESP}"
echo "Installing kernel from ${KERNEL_PATH} to Partition 1 (ESP)..."
cp -f "${KERNEL_PATH}" "${MNT_ESP}/KERNEL"

# Prepare /logs folder and README for Windows / Mac / Android users
mkdir -p "${MNT_ESP}/logs"
cat << 'README' > "${MNT_ESP}/logs/README.txt"
Reverie OS Diagnostic Logs
==========================
This folder contains system boot logs, diagnostics, and hardware reports:
- reverie-boot-log.txt : Summary overview of the latest boot
- dmesg.log            : Full Linux kernel buffer
- journal.log          : Full systemd journal
- gamescope.log        : Gamescope session logs and crashes
- audio.log            : PipeWire, WirePlumber, ALSA sinks and cards
- audio-setup.log      : Hardware mixer initialization trace
- display.log          : DRM connectors, modes, and backlight
- system-info.txt      : Hardware, kernel, version, and disk layout

All files are plain text and can be opened in Windows Notepad or macOS TextEdit.
README

sync
umount "${MNT_ESP}"
losetup -d "${LOOP_DISK}"
unset LOOP_DISK

if [[ "${SKIP_COMPRESS:-0}" == "1" ]]; then
    echo "=== Skipping compression (SKIP_COMPRESS=1) ==="
else
    echo "=== Step 10: Compressing release disk images ==="
    echo "Generating .img.gz archive..."
    if command -v pigz >/dev/null 2>&1; then
        pigz -k -f -6 "${OUTPUT_IMG}"
    else
        gzip -k -f -1 "${OUTPUT_IMG}"
    fi
    sha256sum "${OUTPUT_GZ}" > "${OUTPUT_GZ_SHA}"

    if command -v zstd >/dev/null 2>&1; then
        echo "Generating .img.zst archive..."
        zstd -T0 -3 -f -k "${OUTPUT_IMG}" -o "${OUTPUT_ZST}"
        sha256sum "${OUTPUT_ZST}" > "${OUTPUT_ZST_SHA}"
    fi
fi

echo "=========================================================="
echo " BUILD SUCCESSFUL!"
echo " Raw Image: ${OUTPUT_IMG}"
if [[ -f "${OUTPUT_GZ}" ]]; then
    echo " Gzip:      ${OUTPUT_GZ} ($(cat "${OUTPUT_GZ_SHA}" | awk '{print $1}'))"
fi
if [[ -f "${OUTPUT_ZST}" ]]; then
    echo " Zstd:      ${OUTPUT_ZST} ($(cat "${OUTPUT_ZST_SHA}" | awk '{print $1}'))"
fi
echo "=========================================================="
