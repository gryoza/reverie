#!/bin/bash
set -euo pipefail

PREFIX="${1:-snapshot}"
DATE=$(date +'%Y%m%d-%H%M%S')
SNAP_DIR="/.snapshots"
SNAP_NAME="${PREFIX}-${DATE}"
MAX_SNAPS=5

mkdir -p "${SNAP_DIR}"

echo "[Reverie] Creating Btrfs safety snapshot: ${SNAP_NAME}"
btrfs subvolume snapshot / "${SNAP_DIR}/${SNAP_NAME}" >/dev/null || {
    echo "[Reverie] Warning: failed to create Btrfs snapshot" >&2
    exit 0
}

# Auto-prune older snapshots of this prefix, keeping last MAX_SNAPS
snaps=($(ls -d "${SNAP_DIR}/${PREFIX}-"* 2>/dev/null | sort -r || true))
if [ "${#snaps[@]}" -gt "${MAX_SNAPS}" ]; then
    for old_snap in "${snaps[@]:${MAX_SNAPS}}"; do
        if [ -d "${old_snap}" ]; then
            echo "[Reverie] Pruning old snapshot: ${old_snap}"
            btrfs subvolume delete "${old_snap}" >/dev/null 2>&1 || true
        fi
    done
fi
exit 0
