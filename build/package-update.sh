#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [kernel_file]"
    echo "Example: $0 1.0.1"
    echo "Example with kernel: $0 1.0.1 /path/to/KERNEL"
    exit 1
fi

VERSION_CLEAN="${VERSION#v}"
OUTPUT_DIR="${REPO_DIR}/build_output"
mkdir -p "${OUTPUT_DIR}"

PACKAGE_NAME="reverie-update-v${VERSION_CLEAN}.tar.zst"
OUTPUT_TAR="${OUTPUT_DIR}/${PACKAGE_NAME}"
OUTPUT_SHA="${OUTPUT_TAR}.sha256"

TEMP_DIR=$(mktemp -d -t reverie_ota.XXXXXX)
trap 'rm -rf "${TEMP_DIR}"' EXIT

echo "=== Packaging Reverie OS OTA Update v${VERSION_CLEAN} ==="

# Copy overlay files
if [ -d "${REPO_DIR}/overlay" ]; then
    echo "Adding overlay system files..."
    cp -a "${REPO_DIR}/overlay/"* "${TEMP_DIR}/"
    # OTA update must NEVER add installer shortcut to Desktop
    rm -f "${TEMP_DIR}/home/steamos/Desktop/reverie-installer.desktop"
fi

# Add kernel modules and firmware
if [ -d "${REPO_DIR}/modules" ]; then
    echo "Adding kernel modules..."
    mkdir -p "${TEMP_DIR}/usr/lib/modules"
    cp -a "${REPO_DIR}/modules/"* "${TEMP_DIR}/usr/lib/modules/"
fi

if [ -d "${REPO_DIR}/firmware" ]; then
    echo "Adding hardware firmware..."
    mkdir -p "${TEMP_DIR}/usr/lib/firmware"
    cp -a "${REPO_DIR}/firmware/"* "${TEMP_DIR}/usr/lib/firmware/"
fi

# Add Decky plugin (clean production runtime)
if [ -d "${REPO_DIR}/plugins/Reverie-Power" ]; then
    echo "Adding Reverie-Power Decky plugin..."
    mkdir -p "${TEMP_DIR}/home/steamos/homebrew/plugins"
    cp -a "${REPO_DIR}/plugins/Reverie-Power" "${TEMP_DIR}/home/steamos/homebrew/plugins/"
    rm -rf "${TEMP_DIR}/home/steamos/homebrew/plugins/Reverie-Power/src" \
           "${TEMP_DIR}/home/steamos/homebrew/plugins/Reverie-Power/build.sh" \
           "${TEMP_DIR}/home/steamos/homebrew/plugins/Reverie-Power/rollup.config.js" \
           "${TEMP_DIR}/home/steamos/homebrew/plugins/Reverie-Power/tsconfig.json" \
           "${TEMP_DIR}/home/steamos/homebrew/plugins/Reverie-Power/"__pycache__ \
           "${TEMP_DIR}/home/steamos/homebrew/plugins/Reverie-Power/py_modules/reverie_power/"__pycache__
fi

# Add reverie-updater and installer
mkdir -p "${TEMP_DIR}/usr/bin"
cp -f "${REPO_DIR}/updater/reverie-updater" "${TEMP_DIR}/usr/bin/reverie-updater"
cp -f "${REPO_DIR}/build/reverie-installer.py" "${TEMP_DIR}/usr/bin/reverie-installer"
chmod 0755 "${TEMP_DIR}/usr/bin/reverie-updater" "${TEMP_DIR}/usr/bin/reverie-installer"

# Stamp version
mkdir -p "${TEMP_DIR}/etc/reverie"
echo "${VERSION_CLEAN}" > "${TEMP_DIR}/etc/reverie/version"

# Add bootable KERNEL (explicit argument or autodetected)
KERNEL_SRC="${2:-}"
if [ -z "${KERNEL_SRC}" ] && [ -f "${REPO_DIR}/boot/KERNEL" ]; then
    KERNEL_SRC="${REPO_DIR}/boot/KERNEL"
fi

if [ -n "${KERNEL_SRC}" ] && [ -f "${KERNEL_SRC}" ]; then
    echo "Adding bootable KERNEL binary (${KERNEL_SRC})..."
    cp -f "${KERNEL_SRC}" "${TEMP_DIR}/KERNEL"
fi

# Add post-install maintenance & migration script
cat << 'EOF' > "${TEMP_DIR}/post-install.sh"
#!/bin/bash
set -u

echo "[Reverie-Update] Running post-install migration..."

# System permissions & directories
mkdir -p /var/lib/steamos
chown -R steamos:steamos /var/lib/steamos 2>/dev/null || true
chmod 0775 /var/lib/steamos 2>/dev/null || true
chmod 0755 /usr/bin/reverie-updater /usr/bin/steamos-update /usr/bin/reverie-debug /usr/bin/inputplumber 2>/dev/null || true
chmod 0755 /usr/lib/reverie/* /usr/lib/steamos/* 2>/dev/null || true

# Fix libserialport symlink & remove obsolete build
rm -f /usr/lib/libserialport.so.0.1.1 2>/dev/null || true
if [ -f /usr/lib/libserialport.so.0.1.0 ]; then
    ln -sfn libserialport.so.0.1.0 /usr/lib/libserialport.so.0 2>/dev/null || true
fi

# Clean legacy VR headset services & mask deckard-boot-images
ln -sfn /dev/null /etc/systemd/system/deckard-boot-images.service 2>/dev/null || true

# Remove obsolete sm8550-boot-debug units
systemctl stop sm8550-boot-debug.service sm8550-boot-debug-late.service 2>/dev/null || true
systemctl disable sm8550-boot-debug.service sm8550-boot-debug-late.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/sm8550-boot-debug.service \
      /etc/systemd/system/graphical.target.wants/sm8550-boot-debug-late.service \
      /usr/lib/systemd/system/sm8550-boot-debug.service \
      /usr/lib/systemd/system/sm8550-boot-debug-late.service \
      /usr/lib/steamos/sm8550-boot-debug \
      /usr/bin/reverie-dump-logs \
      /home/steamos/Desktop/reverie-dump-logs.desktop \
      /usr/lib/systemd/user/steam.service.d/99-odin.conf 2>/dev/null || true

# Enable unified reverie services & inputplumber
mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/graphical.target.wants
ln -sfn /usr/lib/systemd/system/reverie-boot-debug.service /etc/systemd/system/multi-user.target.wants/reverie-boot-debug.service 2>/dev/null || true
ln -sfn /usr/lib/systemd/system/reverie-boot-debug-late.service /etc/systemd/system/graphical.target.wants/reverie-boot-debug-late.service 2>/dev/null || true
ln -sfn /usr/lib/systemd/system/inputplumber.service /etc/systemd/system/multi-user.target.wants/inputplumber.service 2>/dev/null || true

# Ensure pacman compatibility symlink
mkdir -p /var/lib
ln -sfn /usr/lib/holo/pacmandb /var/lib/pacman 2>/dev/null || true

# 7. Clean up deprecated plasma env scripts and broken local icon shadows
rm -f /etc/xdg/plasma-workspace/env/set-return-icon.sh 2>/dev/null || true
if [ -d /home/steamos/.local/share/icons/hicolor ] && [ ! -f /home/steamos/.local/share/icons/hicolor/index.theme ]; then
    rm -rf /home/steamos/.local/share/icons/hicolor 2>/dev/null || true
fi

# 8. Rebuild desktop application database and icon caches
chmod 0755 /home/steamos/Desktop/*.desktop 2>/dev/null || true
chown -R steamos:steamos /home/steamos/Desktop 2>/dev/null || true
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
fi
rm -f /home/steamos/.cache/ksycoca* /home/steamos/.cache/icon-cache* 2>/dev/null || true
if command -v kbuildsycoca6 >/dev/null 2>&1; then
    runuser -u steamos -- env XDG_MENU_PREFIX=plasma- kbuildsycoca6 --noincremental 2>/dev/null || true
elif command -v kbuildsycoca5 >/dev/null 2>&1; then
    runuser -u steamos -- env XDG_MENU_PREFIX=plasma- kbuildsycoca5 --noincremental 2>/dev/null || true
fi

# 9. Remove installer desktop shortcuts if running from internal storage
ROOT_DEV="$(findmnt -no SOURCE / 2>/dev/null || true)"
if [[ -n "$ROOT_DEV" && "$ROOT_DEV" != /dev/mmcblk* && "$ROOT_DEV" != /dev/loop* ]]; then
    rm -f /home/steamos/Desktop/reverie-installer.desktop \
          /home/steamos/.local/share/applications/reverie-installer.desktop \
          /usr/share/applications/reverie-installer.desktop 2>/dev/null || true
fi

# Clean up temporary post-install script from rootfs
rm -f /post-install.sh 2>/dev/null || true

systemctl daemon-reload 2>/dev/null || true
echo "[Reverie-Update] Post-install migration finished successfully."
EOF
chmod 0755 "${TEMP_DIR}/post-install.sh"

# Compress with zstd
echo "Compressing into ${OUTPUT_TAR}..."
tar --zstd -cf "${OUTPUT_TAR}" -C "${TEMP_DIR}" .

# Checksum
(cd "${OUTPUT_DIR}" && sha256sum "${PACKAGE_NAME}" > "${PACKAGE_NAME}.sha256")

echo "=========================================================="
echo " OTA PACKAGE CREATED!"
echo " Package:  ${OUTPUT_TAR} ($(du -h "${OUTPUT_TAR}" | cut -f1))"
echo " Checksum: ${OUTPUT_SHA}"
echo "=========================================================="
