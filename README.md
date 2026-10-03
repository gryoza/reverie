# Reverie OS

<p align="center">
  <strong>Pure Valve SteamOS Distribution for Qualcomm Snapdragon Gaming Handhelds</strong><br>
  Built on official Valve SteamOS ARM (Deckard / Frame) userspace, optimized for Snapdragon G3x Gen 2, 8 Gen 3, and 8 Gen 2 (SM8550 & SM8650).
</p>

---

## Bit of Background and Philosophy

I just wanted to boot the Steam Frame OS image on my Android handheld for my next YouTube video, but it turned out to work and perform so well that I thought... why not polish it and let other people enjoy it? Meet Reverie!

### Pure Experience - No Bloatware
Most gaming distributions come stuffed with dozens of preinstalled apps you never asked for. I've always hated it so.. 

**Reverie is a pure SteamOS image with only the essential stack installed.**  
It delivers an authentic Steam Frame OS working out-of-the-box. Any extra launchers, emulators, or tools? That's entirely up to you. It's your console after all.

---

## Overview

**Reverie OS** is not a standalone "From Scratch" image. It's a combination of different projects alongside my own code squeezed into a SteamOS build.

---

## Device Compatibility

Reverie OS is mainly built for AYANEO Pocket S 1k/2k **SM8550 (8 Gen 2 / G3x Gen 2)**. Other devices are supported via ROCKNIX device trees and currently are in an experimental state waiting for someone to try them out. If you test one of them and encounter issues, share your logs and I will be happy to fix them!

| Manufacturer | Device Model | SoC / Platform | Status | Hardware Notes |
| :--- | :--- | :--- | :---: | :--- |
| **AYANEO** | **Pocket S (1K / 2K)** | Snapdragon G3x Gen 2 (SM8550) | 🟢 **Verified & Tested** | **Reference device**. Audio, Bypass Charging, Display Output, TDP control, fan curves, inputs, and gaming verified. |
| **AYANEO** | **Pocket EVO** | Snapdragon G3x Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree. |
| **AYANEO** | **Pocket DMG** | Snapdragon G3x Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree. |
| **AYANEO** | **Pocket DS** | Snapdragon G3x Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree. |
| **AYANEO** | **Pocket ACE** | Snapdragon G3x Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree. |
| **AYANEO** | **Pocket S2** | Snapdragon 8 Gen 3 (SM8650) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree. |
| **AYN** | **Odin 2 / Mini / Portal** | Snapdragon 8 Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree. |
| **AYN** | **Thor** | Snapdragon 8 Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree. |
| **Retroid** | **Pocket 6 / Top-DPad** | Snapdragon 8 Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree. |
| **Retroid** | **Pocket Nova** | Snapdragon 8 Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree. |
| **Retroid** | **Pocket 5 / Mini** | Snapdragon 865 (SM8250) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree. |
| **Retroid** | **Pocket Flip 2** | Snapdragon 865 (SM8250) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree. |
| **KONKR** | **Pocket FIT** | Snapdragon 8 Gen 3 (SM8650) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree. |

---

## Key Features

* **Flexible Dual-Boot & Built-in Internal Installer (`reverie-installer`)**:
  * **100% Portable from MicroSD**: Run entirely off an SD card without modifying or touching your device's internal storage - safe, non-destructive, and perfect for testing.
  * **One-Click Internal Dual-Boot**: Want maximum UFS read/write speeds? Launch the **Reverie Installer** directly from the Desktop. It safely resizes your Android user data partition and installs Reverie OS right alongside Android in dual-boot, letting you switch between Android and SteamOS seamlessly via the ABL menu.
* **Instant Storage Auto-Expansion (`reverie-growfs`)**:
  Download a lightweight 12 GB image. On first boot, Reverie automatically and safely detects your MicroSD card size and expands the Btrfs rootfs to 100% of the card.
* **Reverie Power (Decky Loader Plugin)**:
  Dedicated handheld power management engineered specifically for Snapdragon:
  * **TDP & Frequencies**: Adjust CPU cluster governors, CPU limits, and Adreno GPU performance profiles on the fly.
  * **Custom Fan Curves**: Switch between Relaxed, Moderate, and Aggressive.
* **Hardware Controls (`ayaneo-keys`)**:
  * **Home / AYANEO Key**: Directly triggers the Steam Menu overlay.
  * **Menu / Custom Key**: Directly triggers the Quick Access Menu (QAM).
  * **Programmable buttons (LC / RC)**: Mapped as direct virtual gamepad buttons.
* **Turnip Mesa Vulkan Driver**:
  Native Vulkan 1.4 driver for Qualcomm Adreno GPUs.
* **FEX-Emu & Proton Gaming**:
  Optimized x86_64 translation stack running native Steam x86_64 games and Windows titles via Proton on ARM64.
* **Display Engine & USB-C Hotplug**:
  Gamescope rendered directly on MSM DRM with hardware display rotation and instant plug-and-play monitor/dock detection in both Game Mode and Desktop Mode.
* **KDE Plasma Desktop Mode**:
  Switch seamlessly between Steam Game Mode and a full-featured Wayland desktop session for web browsing and productivity.

---

## Installation Guide

### Prerequisites
1. MicroSD card (A2 / V30 recommended, at least 32GB).
2. [ROCKNIX ABL](https://github.com/ROCKNIX/abl) installed on your device.
3. Image flashing software e.g. [balenaEtcher](https://etcher.balena.io/) 

### Flashing & Booting
1. Download the latest `reverie-os-v1.0-release.img.gz` from the [**Releases**](https://github.com/gryoza/reverie/releases) page.
2. Flash the compressed file directly to your MicroSD card using balenaEtcher.
3. Insert the card into your console.
4. Enter ROCKNIX ABL menu during boot:
   - Select **Set device model** → Choose your exact model
   - Select **Switch boot mode**.
   - Select **START**.
5. The first boot takes **1–2 minutes** while the filesystem expands and Steam prepares the environment.
6. (Optional) Switch to Desktop Mode and open Reverie installer for internal install.

### System Credentials
* **User**: `steamos`
* **Password**: `reverie`

---

## Reporting Issues & Sending Debug Logs

Reverie includes an automated hardware and boot logger daemon.

### Quick CLI Management:
1. `reverie-debug status`   - Check current logger status
2. `reverie-debug enable`   - Enable boot diagnostics
3. `reverie-debug disable`  - Disable logger
4. `reverie-debug clean`    - Clear existing log files
5. `reverie-debug collect`  - Bundle logs into `/home/steamos/reverie-debug-<date>.tar.gz`

Boot debug logs are automatically saved to `/home/steamos/`:
- `BOOT-DEBUG-dmesg.txt`
- `BOOT-DEBUG-journal.txt`
- `BOOT-DEBUG-audio.txt`
- `BOOT-DEBUG-late.txt`

Open an [Issue](https://github.com/gryoza/reverie/issues) and attach these files so I can diagnose and fix it for your device!

---

## Credits & Acknowledgements

Reverie OS is built upon the foundational work of the open-source and handheld gaming communities. Detailed component breakdowns, upstream sources, and author credits are documented in [**CREDITS.md**](CREDITS.md).

* **[Valve Corporation](https://www.valvesoftware.com/)** — SteamOS, Gamescope, Deckard ARM64 userspace, and Steam client.
* **[ROCKNIX Team](https://github.com/ROCKNIX)** — ABL bootloader, device tree sources, and Qualcomm Linux enablement.
* **[Armada](https://github.com/armada-os/armada)** — Qualcomm Linux packaging reference, firmware integration, and architectural inspiration.
* **[MaSieS4Fun](https://github.com/MaSieS4Fun/SteamOS-Ubuntu)** — Foundational scripts and Snapdragon handheld research.
