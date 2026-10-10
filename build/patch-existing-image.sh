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

# 2b. Sanitize and prepare FAT32 boot partition (partition 1)
echo "=== Step 1b: Sanitizing FAT32 partition (partition 1) ==="
MNT_FAT32=$(mktemp -d -t reverie_fat32.XXXXXX)
if mount -t vfat "${LOOP_DEV}p1" "${MNT_FAT32}" 2>/dev/null; then
    mkdir -p "${MNT_FAT32}/logs"
    rm -f "${MNT_FAT32}/reverie-boot-log.txt" 2>/dev/null || true
    cat << 'README' > "${MNT_FAT32}/logs/README.txt"
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
    sync "${MNT_FAT32}"
    umount "${MNT_FAT32}"
fi
rm -rf "${MNT_FAT32}" 2>/dev/null || true

# 3. Inject MangoHud binaries and clean configuration
echo "=== Step 2: Injecting patched MangoHud binaries and configuration ==="
MANGOHUD_BIN_DIR="${MANGOHUD_BIN_DIR:-${REPO_DIR}/bin/mangohud}"
if [[ -d "${MANGOHUD_BIN_DIR}" ]]; then
    echo "Installing patched MangoHud binaries from ${MANGOHUD_BIN_DIR}..."
    mkdir -p "${MNT_DIR}/usr/lib" "${MNT_DIR}/usr/bin"
    if [[ -f "${MANGOHUD_BIN_DIR}/libMangoHud.so" ]]; then
        cp -f "${MANGOHUD_BIN_DIR}/libMangoHud"*.so "${MNT_DIR}/usr/lib/"
        chmod 0755 "${MNT_DIR}/usr/lib/libMangoHud"*.so
        chown 0:0 "${MNT_DIR}/usr/lib/libMangoHud"*.so
    fi
    if [[ -f "${MANGOHUD_BIN_DIR}/mangoapp" ]]; then
        cp -f "${MANGOHUD_BIN_DIR}/mangoapp" "${MNT_DIR}/usr/bin/mangoapp"
        chmod 0755 "${MNT_DIR}/usr/bin/mangoapp"
        chown 0:0 "${MNT_DIR}/usr/bin/mangoapp"
    fi
fi

# Remove legacy broken Masies drop-ins and presets
echo "Cleaning legacy Masies drop-ins and presets..."
rm -f "${MNT_DIR}/usr/lib/systemd/user/steam.service.d/99-odin.conf" \
      "${MNT_DIR}/etc/MangoHud/presets.conf" \
      "${MNT_DIR}/usr/share/MangoHud/presets.conf" \
      "${MNT_DIR}/usr/share/reverie/MangoHud/steam/presets.conf" \
      "${MNT_DIR}/home/steamos/.config/MangoHud/steam/presets.conf" \
      "${MNT_DIR}/home/steamos/.config/MangoHud/presets.conf" \
      "${MNT_DIR}/etc/skel/.config/MangoHud/steam/presets.conf" \
      "${MNT_DIR}/etc/skel/.config/MangoHud/presets.conf"
rm -rf "${MNT_DIR}/usr/share/steamos-odin/MangoHud" \
       "${MNT_DIR}/etc/MangoHud" \
       "${MNT_DIR}/usr/share/MangoHud"

# 4. Inject updated system overlays
echo "=== Step 3: Injecting updated system overlays ==="
cp -a "${REPO_DIR}/overlay/"* "${MNT_DIR}/"

# 5. Install updated updater and installer
echo "=== Step 4: Installing updated installer and updater ==="
mkdir -p "${MNT_DIR}/usr/bin"
cp -f "${REPO_DIR}/build/reverie-installer.py" "${MNT_DIR}/usr/bin/reverie-installer"
cp -f "${REPO_DIR}/updater/reverie-updater" "${MNT_DIR}/usr/bin/reverie-updater"
chmod 0755 "${MNT_DIR}/usr/bin/reverie-installer" "${MNT_DIR}/usr/bin/reverie-updater" "${MNT_DIR}/usr/bin/steamos-update"

# 6. Update Reverie-Power plugin
echo "=== Step 5: Updating Reverie-Power Decky plugin ==="
if [[ -d "${REPO_DIR}/plugins/Reverie-Power" ]]; then
    mkdir -p "${MNT_DIR}/home/steamos/homebrew/plugins"
    rm -rf "${MNT_DIR}/home/steamos/homebrew/plugins/Reverie-Power"
    cp -a "${REPO_DIR}/plugins/Reverie-Power" "${MNT_DIR}/home/steamos/homebrew/plugins/"
    # Strip development sources, configs and bytecode from deployed plugin
    rm -rf "${MNT_DIR}/home/steamos/homebrew/plugins/Reverie-Power/src" \
           "${MNT_DIR}/home/steamos/homebrew/plugins/Reverie-Power/build.sh" \
           "${MNT_DIR}/home/steamos/homebrew/plugins/Reverie-Power/rollup.config.js" \
           "${MNT_DIR}/home/steamos/homebrew/plugins/Reverie-Power/tsconfig.json" \
           "${MNT_DIR}/home/steamos/homebrew/plugins/Reverie-Power/"__pycache__ \
           "${MNT_DIR}/home/steamos/homebrew/plugins/Reverie-Power/py_modules/reverie_power/"__pycache__
    if [[ -d "${MNT_DIR}/usr/share/steamos-odin/decky-plugins" ]]; then
        rm -rf "${MNT_DIR}/usr/share/steamos-odin/decky-plugins/Reverie-Power"
        cp -a "${MNT_DIR}/home/steamos/homebrew/plugins/Reverie-Power" "${MNT_DIR}/usr/share/steamos-odin/decky-plugins/"
    fi
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
ln -sf /usr/lib/systemd/system/reverie-boot-debug.service "${MNT_DIR}/etc/systemd/system/multi-user.target.wants/reverie-boot-debug.service" 2>/dev/null || true
mkdir -p "${MNT_DIR}/etc/systemd/system/graphical.target.wants"
ln -sf /usr/lib/systemd/system/reverie-boot-debug-late.service "${MNT_DIR}/etc/systemd/system/graphical.target.wants/reverie-boot-debug-late.service" 2>/dev/null || true
mkdir -p "${MNT_DIR}/usr/lib/systemd/user/gamescope-session.target.wants"
ln -sf ../steamos-powerbuttond.service "${MNT_DIR}/usr/lib/systemd/user/gamescope-session.target.wants/steamos-powerbuttond.service" 2>/dev/null || true

# Compatibility and path fixes
mkdir -p "${MNT_DIR}/var/lib"
ln -sfn /usr/lib/holo/pacmandb "${MNT_DIR}/var/lib/pacman" 2>/dev/null || true
mkdir -p "${MNT_DIR}/usr/lib/steam"
ln -sf /usr/share/applications/steam.desktop "${MNT_DIR}/usr/lib/steam/steam.desktop" 2>/dev/null || true
if [[ -d "${MNT_DIR}/opt/steamvr/bin/linuxarm64" ]]; then
    ln -sf /usr/lib/pulseaudio/libpulsecommon-17.0.so "${MNT_DIR}/opt/steamvr/bin/linuxarm64/libpulsecommon-10.0.so" 2>/dev/null || true
fi
if [[ -d "${MNT_DIR}/usr/share/guestos/fex-mesa/usr/lib32" ]]; then
    ln -sf libkeyutils.so.1 "${MNT_DIR}/usr/share/guestos/fex-mesa/usr/lib32/libkeyutils.so" 2>/dev/null || true
fi
if [[ -d "${MNT_DIR}/etc/ca-certificates" ]] && [[ -d "${MNT_DIR}/usr/share/guestos/fex-mesa/etc" ]]; then
    mkdir -p "${MNT_DIR}/usr/share/guestos/fex-mesa/etc/ca-certificates"
    cp -a "${MNT_DIR}/etc/ca-certificates/"* "${MNT_DIR}/usr/share/guestos/fex-mesa/etc/ca-certificates/" 2>/dev/null || true
fi

# 8. Sanitize image for distribution
echo "=== Step 7: Sanitizing image for distribution ==="
# 8.1. Remove stray Steam library files in rootfs /
rm -f "${MNT_DIR}/libraryfolder.vdf"
rm -rf "${MNT_DIR}/steamapps"

# 8.2. Reset machine-id and hostname for clean first boot
echo -n "" > "${MNT_DIR}/etc/machine-id"
chmod 0444 "${MNT_DIR}/etc/machine-id"
echo "reverie" > "${MNT_DIR}/etc/hostname"
chmod 0644 "${MNT_DIR}/etc/hostname"
mkdir -p "${MNT_DIR}/var/lib/dbus"
ln -sf /etc/machine-id "${MNT_DIR}/var/lib/dbus/machine-id" 2>/dev/null || true

# 8.3. Remove coredumps
rm -rf "${MNT_DIR}/var/lib/systemd/coredump/"* 2>/dev/null || true
rm -rf "${MNT_DIR}/home/.steamos/offload/var/lib/systemd/coredump/"* 2>/dev/null || true

# 8.4. Clear active Steam session tokens, locks, and pipes
rm -f "${MNT_DIR}/home/steamos/.steam/steam.token" \
      "${MNT_DIR}/home/steamos/.steam/steam.pid" \
      "${MNT_DIR}/home/steamos/.steam/steam.pipe" \
      "${MNT_DIR}/home/steamos/.steam/registry.vdf."*.tmp \
      "${MNT_DIR}/home/steamos/.local/share/Steam/.cef-enable-remote-debugging"
rm -rf "${MNT_DIR}/home/steamos/.local/share/Steam/steamapps/common/Steam Controller Configs"
rm -rf "${MNT_DIR}/home/steamos/.local/share/Steam/steamapps/workshop/appworkshop_241100.acf"
rm -rf "${MNT_DIR}/home/steamos/.local/share/Steam/steamapps/workshop/content/241100"
find "${MNT_DIR}/home/steamos/.local/share/Steam/steamapps/" -name "*.lock" -delete 2>/dev/null || true
find "${MNT_DIR}/home/steamos/.local/share/Steam/steamapps/" -name "*.reg.old" -delete 2>/dev/null || true
if compgen -G "${MNT_DIR}/home/steamos/.local/share/Steam/steamapps/appmanifest_*.acf" >/dev/null; then
    sed -i -E 's/"LastOwner"[[:space:]]+"[0-9]+"/"LastOwner"\t\t"0"/' "${MNT_DIR}/home/steamos/.local/share/Steam/steamapps/"appmanifest_*.acf
fi

# 8.5. Clear KDE session state, open tabs, and lock files
rm -rf "${MNT_DIR}/home/steamos/.config/session/"* 2>/dev/null || true
rm -f "${MNT_DIR}/home/steamos/.local/state/dolphinstaterc" \
      "${MNT_DIR}/home/steamos/.local/state/konsolestaterc" \
      "${MNT_DIR}/home/steamos/.local/state/plasmasessionrestorestaterc" \
      "${MNT_DIR}/home/steamos/.local/state/plasmashellstaterc" \
      "${MNT_DIR}/home/steamos/.local/state/systemsettingsstaterc" \
      "${MNT_DIR}/home/steamos/.local/share/baloo/index-lock" \
      "${MNT_DIR}/home/steamos/.local/share/user-places.xbel.bak" \
      "${MNT_DIR}/home/steamos/.local/share/user-places.xbel.tbcache" \
      "${MNT_DIR}/etc/xdg/plasma-workspace/env/set-return-icon.sh" \
      "${MNT_DIR}/home/steamos/.cache/ksycoca"* \
      "${MNT_DIR}/home/steamos/.cache/icon-cache"* 2>/dev/null || true
rm -rf "${MNT_DIR}/home/steamos/.local/share/icons/hicolor" 2>/dev/null || true

# 8.6. Remove legacy project names, obsolete scripts, and legacy debuggers
rm -rf "${MNT_DIR}/home/steamos/homebrew/data/Mononoke-Power" \
       "${MNT_DIR}/home/steamos/homebrew/data/SM8550-Power" \
       "${MNT_DIR}/home/steamos/homebrew/data/SM8550-LED" \
       "${MNT_DIR}/usr/lib/reverie/reverie-updater" \
       "${MNT_DIR}/usr/lib/steamos/sm8550-boot-debug" \
       "${MNT_DIR}/usr/lib/systemd/system/sm8550-boot-debug.service" \
       "${MNT_DIR}/usr/lib/systemd/system/sm8550-boot-debug-late.service" \
       "${MNT_DIR}/etc/systemd/system/multi-user.target.wants/sm8550-boot-debug.service" \
       "${MNT_DIR}/etc/systemd/system/graphical.target.wants/sm8550-boot-debug-late.service" \
       "${MNT_DIR}/usr/lib/systemd/system/mononoke-boot-debug.service" \
       "${MNT_DIR}/usr/lib/systemd/system/mononoke-boot-debug-late.service" \
       "${MNT_DIR}/etc/systemd/system/multi-user.target.wants/mononoke-boot-debug.service" \
       "${MNT_DIR}/etc/systemd/system/graphical.target.wants/mononoke-boot-debug-late.service" \
       "${MNT_DIR}/usr/bin/reverie-dump-logs" \
       "${MNT_DIR}/home/steamos/Desktop/reverie-dump-logs.desktop" \
       "${MNT_DIR}/home/steamos/BOOT-DEBUG-"*.txt \
       "${MNT_DIR}/home/steamos/GAMESCOPE-DEBUG."* \
       "${MNT_DIR}/home/steamos/START-GAMESCOPE-DEBUG.txt" \
       "${MNT_DIR}/home/steamos/sm8550-"*.log \
       "${MNT_DIR}/home/steamos/reverie-debug-"*.tar.gz 2>/dev/null || true

# 8.7. Clear log files and private temporary dirs
truncate -s 0 "${MNT_DIR}/var/log/firewalld" 2>/dev/null || true
truncate -s 0 "${MNT_DIR}/var/log/wtmp" 2>/dev/null || true
truncate -s 0 "${MNT_DIR}/var/log/btmp" 2>/dev/null || true
truncate -s 0 "${MNT_DIR}/var/log/lastlog" 2>/dev/null || true
truncate -s 0 "${MNT_DIR}/home/.steamos/offload/var/log/firewalld" 2>/dev/null || true
truncate -s 0 "${MNT_DIR}/home/.steamos/offload/var/log/wtmp" 2>/dev/null || true
truncate -s 0 "${MNT_DIR}/home/.steamos/offload/var/log/gpu-trace-daemon.log" 2>/dev/null || true
rm -rf "${MNT_DIR}/var/log/journal/"* 2>/dev/null || true
rm -rf "${MNT_DIR}/home/.steamos/offload/var/log/journal/"* 2>/dev/null || true
rm -rf "${MNT_DIR}/var/log/steamos-log-submitter/"* 2>/dev/null || true
rm -rf "${MNT_DIR}/home/.steamos/offload/var/log/steamos-log-submitter/"* 2>/dev/null || true
rm -rf "${MNT_DIR}/var/tmp/systemd-private-"* 2>/dev/null || true
rm -rf "${MNT_DIR}/home/.steamos/offload/var/tmp/systemd-private-"* 2>/dev/null || true
rm -f "${MNT_DIR}/etc/pacman.d/gnupg/pubring.gpg~" 2>/dev/null || true
find "${MNT_DIR}/usr/local/bin" "${MNT_DIR}/usr/lib/reverie" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

# 8.8. Remove embedded SSH host keys (generated on first boot by sshdgenkeys.service)
rm -f "${MNT_DIR}/var/lib/overlays/etc/upper/ssh/ssh_host_"* \
      "${MNT_DIR}/etc/ssh/ssh_host_"* 2>/dev/null || true

# 8.9. Remove dead ALSA UCM2 profiles and phantom fstab mounts
rm -f "${MNT_DIR}/usr/share/alsa/ucm2/conf.d/sm8550/AYN-Thor.conf" \
      "${MNT_DIR}/usr/share/alsa/ucm2/conf.d/sm8550/ayn-AYNThor-.conf" \
      "${MNT_DIR}/usr/share/alsa/ucm2/conf.d/sm8550/SM8550-HDK.conf" 2>/dev/null || true
sed -i "/PARTLABEL=syspersist/d" "${MNT_DIR}/etc/fstab" 2>/dev/null || true

# 8.10. Remove stray root video device symlinks and broken Steam runtime video symlinks
rm -f "${MNT_DIR}/video-dec0" "${MNT_DIR}/video-enc0" 2>/dev/null || true
find "${MNT_DIR}/home/steamos/.local/share/Steam/steamrt"*"/video" -xtype l -delete 2>/dev/null || true

# 8.11. Remove stale sockets and singleton locks
rm -f "${MNT_DIR}/var/lib/overlays/etc/upper/pacman.d/gnupg/S."* \
      "${MNT_DIR}/etc/pacman.d/gnupg/S."* \
      "${MNT_DIR}/home/steamos/.local/share/Steam/config/htmlcache/Singleton"* \
      "${MNT_DIR}/var/log/README" 2>/dev/null || true

# 9. Set permissions and ownership
echo "=== Step 8: Setting file permissions and ownership ==="
chmod 0755 "${MNT_DIR}" "${MNT_DIR}/usr" "${MNT_DIR}/usr/bin" "${MNT_DIR}/usr/lib" 2>/dev/null || true
chown 0:0 "${MNT_DIR}" "${MNT_DIR}/usr" "${MNT_DIR}/usr/bin" "${MNT_DIR}/usr/lib" 2>/dev/null || true
chmod 0755 "${MNT_DIR}/usr/lib/reverie/"* 2>/dev/null || true
chmod 0755 "${MNT_DIR}/usr/lib/steamos/"* 2>/dev/null || true
chmod 0755 "${MNT_DIR}/usr/local/bin/"* 2>/dev/null || true
chmod 0755 "${MNT_DIR}/home/steamos/Desktop/"*.desktop 2>/dev/null || true
chmod -R 0755 "${MNT_DIR}/usr/share/icons" "${MNT_DIR}/usr/share/applications" 2>/dev/null || true
chown -R 0:0 "${MNT_DIR}/usr/share/icons" "${MNT_DIR}/usr/share/applications" 2>/dev/null || true
chown -R 1000:1000 "${MNT_DIR}/home/steamos" 2>/dev/null || true
mkdir -p "${MNT_DIR}/var/lib/steamos"
echo "rel" > "${MNT_DIR}/var/lib/steamos/selected-branch"
chown -R 1000:1000 "${MNT_DIR}/var/lib/steamos" 2>/dev/null || true
chmod 0775 "${MNT_DIR}/var/lib/steamos" 2>/dev/null || true
chmod 0664 "${MNT_DIR}/var/lib/steamos/selected-branch" 2>/dev/null || true
chown -R 0:0 "${MNT_DIR}/etc/sudoers.d" "${MNT_DIR}/etc/sudoers" 2>/dev/null || true
chmod 0440 "${MNT_DIR}/etc/sudoers.d/"* 2>/dev/null || true

# 10. Sync and unmount
echo "=== Step 9: Syncing filesystem and detaching loop device ==="
sync
umount -R "${MNT_DIR}"
losetup -d "${LOOP_DEV}"
unset LOOP_DEV

echo "=== PATCHING AND SANITIZING COMPLETE! ==="

# 10. Compress to .img.gz and .img.zst
OUTPUT_GZ="${TARGET_IMG}.gz"
OUTPUT_GZ_SHA="${OUTPUT_GZ}.sha256"
OUTPUT_ZST="${TARGET_IMG}.zst"
OUTPUT_ZST_SHA="${OUTPUT_ZST}.sha256"

echo "=== Step 9: Compressing patched image ==="
if command -v pigz >/dev/null 2>&1; then
    echo "Compressing with pigz..."
    pigz -k -f -6 "${TARGET_IMG}"
else
    echo "Compressing with gzip..."
    gzip -k -f -1 "${TARGET_IMG}"
fi
sha256sum "${OUTPUT_GZ}" > "${OUTPUT_GZ_SHA}"

if command -v zstd >/dev/null 2>&1; then
    echo "Compressing with zstd..."
    zstd -T0 -3 -f -k "${TARGET_IMG}" -o "${OUTPUT_ZST}"
    sha256sum "${OUTPUT_ZST}" > "${OUTPUT_ZST_SHA}"
fi

echo "=========================================================="
echo " RELEASE IMAGE READY!"
echo " Raw Image: ${TARGET_IMG}"
echo " Gzip:      ${OUTPUT_GZ} ($(cat "${OUTPUT_GZ_SHA}" | awk '{print $1}'))"
if [[ -f "${OUTPUT_ZST}" ]]; then
    echo " Zstd:      ${OUTPUT_ZST} ($(cat "${OUTPUT_ZST_SHA}" | awk '{print $1}'))"
fi
echo "=========================================================="
