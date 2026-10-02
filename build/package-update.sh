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

# 1. Copy overlay files
if [ -d "${REPO_DIR}/overlay" ]; then
    echo "Adding overlay system files..."
    cp -a "${REPO_DIR}/overlay/"* "${TEMP_DIR}/"
fi

# 2. Add Decky plugin
if [ -d "${REPO_DIR}/plugins/Reverie-Power" ]; then
    echo "Adding Reverie-Power Decky plugin..."
    mkdir -p "${TEMP_DIR}/home/steamos/homebrew/plugins"
    cp -a "${REPO_DIR}/plugins/Reverie-Power" "${TEMP_DIR}/home/steamos/homebrew/plugins/"
fi

# 3. Add reverie-updater and installer
mkdir -p "${TEMP_DIR}/usr/bin"
cp -f "${REPO_DIR}/updater/reverie-updater" "${TEMP_DIR}/usr/bin/reverie-updater"
cp -f "${REPO_DIR}/build/reverie-installer.py" "${TEMP_DIR}/usr/bin/reverie-installer"
chmod 0755 "${TEMP_DIR}/usr/bin/reverie-updater" "${TEMP_DIR}/usr/bin/reverie-installer"

# 4. Stamp version
mkdir -p "${TEMP_DIR}/etc/reverie"
echo "${VERSION_CLEAN}" > "${TEMP_DIR}/etc/reverie/version"

# 5. Optional new KERNEL
if [ -n "${2:-}" ] && [ -f "$2" ]; then
    echo "Adding new KERNEL binary ($2)..."
    cp -f "$2" "${TEMP_DIR}/KERNEL"
fi

# 6. Compress with zstd
echo "Compressing into ${OUTPUT_TAR}..."
tar --zstd -cf "${OUTPUT_TAR}" -C "${TEMP_DIR}" .

# 7. Checksum
(cd "${OUTPUT_DIR}" && sha256sum "${PACKAGE_NAME}" > "${PACKAGE_NAME}.sha256")

echo "=========================================================="
echo " OTA PACKAGE CREATED!"
echo " Package:  ${OUTPUT_TAR} ($(du -h "${OUTPUT_TAR}" | cut -f1))"
echo " Checksum: ${OUTPUT_SHA}"
echo "=========================================================="
