#!/bin/bash
set -e

STEAM_DIR="/home/steamos/.local/share/Steam"
SDK_ARM="/home/steamos/.steam/sdkarm64"
LINUX_ARM="${STEAM_DIR}/linuxarm64"

mkdir -p "${SDK_ARM}" "${LINUX_ARM}"

if [ -f "${STEAM_DIR}/steamrtarm64/libtier0_s.so" ]; then
    cp -f "${STEAM_DIR}/steamrtarm64/libtier0_s.so" "${SDK_ARM}/"
    cp -f "${STEAM_DIR}/steamrtarm64/libtier0_s.so" "${LINUX_ARM}/"
fi

if [ -f "${STEAM_DIR}/steamrtarm64/libvstdlib_s.so" ]; then
    cp -f "${STEAM_DIR}/steamrtarm64/libvstdlib_s.so" "${SDK_ARM}/"
    cp -f "${STEAM_DIR}/steamrtarm64/libvstdlib_s.so" "${LINUX_ARM}/"
fi

if [ -f /usr/lib/libnm.so.0.1.0 ]; then
    cp -f /usr/lib/libnm.so.0* "${SDK_ARM}/"
    cp -f /usr/lib/libnm.so.0* "${LINUX_ARM}/"
fi

# Also fix 32-bit and 64-bit linux
mkdir -p /home/steamos/.steam/sdk32 /home/steamos/.steam/sdk64 "${STEAM_DIR}/linux32" "${STEAM_DIR}/linux64"
if [ -d "${STEAM_DIR}/ubuntu12_32" ]; then
    cp -f "${STEAM_DIR}/ubuntu12_32/"lib*.so "${STEAM_DIR}/linux32/" 2>/dev/null || true
    cp -f "${STEAM_DIR}/ubuntu12_32/"lib*.so "/home/steamos/.steam/sdk32/" 2>/dev/null || true
fi

if [ -d "${STEAM_DIR}/ubuntu12_64" ]; then
    cp -f "${STEAM_DIR}/ubuntu12_64/"lib*.so "${STEAM_DIR}/linux64/" 2>/dev/null || true
    cp -f "${STEAM_DIR}/ubuntu12_64/"lib*.so "/home/steamos/.steam/sdk64/" 2>/dev/null || true
fi

chown -R steamos:steamos /home/steamos/.steam /home/steamos/.local/share/Steam 2>/dev/null || true
echo "[Reverie] Steamclient libraries verified and synchronized."

# Remove duplicate library folder pointing to / if Steam ever creates it
python3 - << "PY" 2>/dev/null || true
for path in ["/home/steamos/.local/share/Steam/steamapps/libraryfolders.vdf",
             "/home/steamos/.local/share/Steam/config/libraryfolders.vdf"]:
    try:
        with open(path, "r") as f:
            content = f.read()
        if "\"1\"" in content and "\"path\"\t\t\"/\"" in content:
            lines = content.splitlines()
            out, skip, depth = [], False, 0
            for l in lines:
                if "\"1\"" in l and not skip:
                    skip = True; continue
                if skip:
                    if "{" in l: depth += 1
                    if "}" in l:
                        if depth > 0: depth -= 1
                        else: skip = False
                    continue
                out.append(l)
            with open(path, "w") as f:
                f.write("\n".join(out) + "\n")
    except Exception:
        pass
PY
chown -R steamos:steamos /home/steamos/.local/share/Steam/steamapps/libraryfolders.vdf /home/steamos/.local/share/Steam/config/libraryfolders.vdf 2>/dev/null || true

# Ensure CEF remote debugging flag exists so Decky Loader can inject into Steam
touch /home/steamos/.local/share/Steam/.cef-enable-remote-debugging 2>/dev/null || true
chown steamos:steamos /home/steamos/.local/share/Steam/.cef-enable-remote-debugging 2>/dev/null || true
