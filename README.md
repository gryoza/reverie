# Reverie OS

<p align="center">
  <strong>Pure Valve SteamOS Distribution for Qualcomm Snapdragon Gaming Handhelds</strong><br>
  Built on official Valve SteamOS ARM (Deckard / Frame) userspace, optimized for Snapdragon G3x Gen 2, 8 Gen 3, 8 Elite, and 8 Gen 2 (SM8550, SM8650, SM8750 & SM8250).
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
| **AYANEO** | **Pocket EVO** | Snapdragon G3x Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |
| **AYANEO** | **Pocket DMG** | Snapdragon G3x Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |
| **AYANEO** | **Pocket DS** | Snapdragon G3x Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |
| **AYANEO** | **Pocket ACE** | Snapdragon G3x Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |
| **AYANEO** | **Pocket S2** | Snapdragon 8 Gen 3 (SM8650) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |
| **AYN** | **Odin 2 / Mini / Portal** | Snapdragon 8 Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |
| **AYN** | **Odin 3** | Snapdragon 8 Elite (SM8750) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |
| **AYN** | **Thor** | Snapdragon 8 Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |
| **Retroid** | **Pocket 6 / Top-DPad** | Snapdragon 8 Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |
| **Retroid** | **Pocket Nova** | Snapdragon 8 Gen 2 (SM8550) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |
| **Retroid** | **Pocket 5 / Mini** | Snapdragon 865 (SM8250) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |
| **Retroid** | **Pocket Flip 2** | Snapdragon 865 (SM8250) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |
| **KONKR** | **Pocket FIT** | Snapdragon 8 Gen 3 (SM8650) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |
| **KONKR** | **Pocket FIT Elite** | Snapdragon 8 Elite (SM8750) | 🟡 *Supported (Untested)* | Compatible via ROCKNIX ABL device tree & InputPlumber. |

---

## Key Features

* **Dual-Boot and Built-in Internal Installer (`reverie-installer`)**:
  * **Portable from MicroSD**: Run entirely off an SD card without modifying or touching your device's internal storage.
  * **Internal Dual-Boot**: Launch the **Reverie Installer** directly from the Desktop. It safely resizes your Android user data partition and installs Reverie OS right alongside Android in dual-boot, letting you switch between Android and SteamOS seamlessly via the ABL menu.
* **Instant Storage Auto-Expansion (`reverie-growfs`)**:
  Download a lightweight 12 GB image. On first boot, Reverie automatically and safely detects your MicroSD card size and expands the Btrfs rootfs to 100% of the card.
* **Reverie Power (Decky Loader Plugin)**:
  Dedicated handheld power management made for Snapdragon:
  * **TDP & Frequencies**: Adjust CPU cluster governors, CPU limits, and Adreno GPU performance profiles on the fly.
  * **Custom Fan Curves**: Switch between Relaxed, Moderate, and Aggressive.
* **Hardware Controls (`ayaneo-keys`)**:
  * **Home / AYANEO Key**: Directly triggers the Steam Menu overlay.
  * **Menu / Custom Key**: Directly triggers the Quick Access Menu (QAM).
  * **Programmable buttons (LC / RC)**: Mapped as direct virtual gamepad buttons.
* **Display Engine & USB-C Hotplug**:
  Gamescope rendered directly on MSM DRM with hardware display rotation and instant plug-and-play monitor/dock detection in both Game Mode and Desktop Mode.
* **Turnip Mesa Vulkan Driver**:
  Native Vulkan 1.4 driver for Qualcomm Adreno GPUs.
* **FEX-Emu & Proton Gaming**:
  Optimized x86_64 translation stack running native Steam x86_64 games and Windows titles via Proton on ARM64.
* **KDE Plasma Desktop Mode**:
  Switch seamlessly between Steam Game Mode and a full-featured Wayland desktop session for web browsing and productivity.
* **Integrated OTA Updates (`reverie-updater`)**:
  Built-in OTA updater connected directly to GitHub Releases for one-click system upgrades.

---

## Installation Guide

### Prerequisites
1. MicroSD card (A2 / V30 recommended, at least 32GB).
2. [ROCKNIX ABL](https://github.com/ROCKNIX/abl) installed on your device.
3. Image flashing software e.g. [balenaEtcher](https://etcher.balena.io/) 

### Flashing & Booting (Clean Install)
1. Download the latest `reverie-os-v1.1-release.img.gz` from the [**Releases**](https://github.com/gryoza/reverie/releases) page.
2. Flash the compressed file directly to your MicroSD card using balenaEtcher.
3. Insert the card into your console.
4. Enter ROCKNIX ABL menu during boot:
   - Select **Set device model** → Choose your exact model
   - Select **Switch boot mode**.
   - Select **START**.
5. The first boot takes **1–2 minutes** while the filesystem expands and Steam prepares the environment.
6. (Optional) Switch to Desktop Mode and open Reverie installer for internal install.

### Updating Reverie OS (OTA)
If you already have Reverie OS installed, you do not need to reflash your card:
* **Via Steam Game Mode**: Go to **Settings** → **System** → **Check for Updates** and apply the update.
* **Via Terminal**: Download `reverie-update-vX.X.X.tar.zst` and run:
  ```bash
  sudo reverie-updater --apply /path/to/reverie-update-vX.X.X.tar.zst
  ```
  Or to check and apply directly from GitHub Releases:
  ```bash
  sudo reverie-updater --apply
  ```

### System Credentials
* **User**: `steamos`
* **Password**: `reverie`

---

## Reporting Issues & Diagnostic Logs

Reverie OS features an automated hardware diagnostic and logging system.

### FAT32 Boot Partition Logs (`/logs/`):
All boot logs and diagnostics are written directly to the **`logs/`** folder on the first partition (**FAT32**, labeled `REVERIE`). 
You can inspect them on any **Windows PC, macOS, Linux, or Android** device simply by inserting your MicroSD card:

* **`reverie-boot-log.txt`** — High-level overview of the latest boot (failed units, session status, devices).
* **`dmesg.log`** — Full Linux kernel ring buffer.
* **`journal.log`** — Full systemd journal.
* **`journal-errors.log`** — Errors and critical alerts extracted from the journal.
* **`gamescope.log`** — Gamescope compositor session logs and crashes.
* **`audio.log`** — PipeWire, WirePlumber, ALSA sinks, sources, and card states.
* **`display.log`** — DRM connectors, display modes, panel rotation, and backlight status.
* **`system-info.txt`** — System hardware specs, kernel cmdline, OS release, and disk partitions.

### Diagnostic CLI Tool (`reverie-debug`):
Manage diagnostics directly from Konsole in Desktop Mode or via SSH:
* `reverie-debug status` — Check logger status and list log files stored on the FAT32 partition.
* `reverie-debug enable` — Enable diagnostic logging on boot.
* `reverie-debug disable` — Disable diagnostic logging.
* `reverie-debug clean` — Wipe all log files from the FAT32 `/logs/` folder.
* `reverie-debug boot-dump manual` — Trigger an immediate live diagnostics dump to FAT32 `/logs/`.

Attach these files when opening an [Issue](https://github.com/gryoza/reverie/issues) to help diagnose hardware problems for your console!

---

## Credits & Acknowledgements

Reverie OS is built upon the foundational work of the open-source and handheld gaming communities. Detailed component breakdowns, upstream sources, and author credits are documented in [**CREDITS.md**](CREDITS.md).

* **[Valve Corporation](https://www.valvesoftware.com/)** — SteamOS, Gamescope, Deckard ARM64 userspace, and Steam client.
* **[ROCKNIX Team](https://github.com/ROCKNIX)** — ABL bootloader, device tree sources, and Qualcomm Linux enablement.
* **[Armada](https://github.com/armada-os/armada)** — Qualcomm Linux packaging reference, firmware integration, and architectural inspiration.
* **[MaSieS4Fun](https://github.com/MaSieS4Fun/SteamOS-Ubuntu)** — Foundational scripts and Snapdragon handheld research.
