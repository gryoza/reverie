# Credits and Upstream Sources

**Reverie OS** brings an authentic Valve SteamOS experience to Qualcomm Snapdragon gaming handhelds. This project is made possible through the collective efforts of open-source developers, hardware reverse-engineers, and upstream Linux communities.

Original licenses remain with their respective authors. Project-specific integration code, scripts, and overlays are licensed under **GPL-2.0** — see [`LICENSE`](LICENSE).

---

## Base System & Gaming Stack

| Component | Upstream / Author | What Reverie Uses |
| :--- | :--- | :--- |
| **Valve SteamOS ARM (Deckard / Frame)** | Valve | Official aarch64 SteamOS userspace, Steam Gamepad UI, and KDE Plasma session. |
| **Valve Steam (ARM64) & FEX-Emu** | Valve | Game Mode Steam client and x86_64 binary translation runtime. |
| **Gamescope** | Valve | Wayland micro-compositor adapted for Qualcomm MSM DRM backend with hardware display rotation. |
| **KDE Plasma & Frameworks** | [KDE Community](https://kde.org/) | Official SteamOS Desktop Mode (Wayland session). |
| **Arch Linux ARM** | [Arch Linux ARM](https://archlinuxarm.org/) | Base package ecosystem and core system libraries. |

---

## Kernel, Bootloader & Hardware Enablement

| Component | Upstream / Author | What Reverie Uses |
| :--- | :--- | :--- |
| **ROCKNIX ABL** | [ROCKNIX Team](https://github.com/ROCKNIX/abl) | Android Bootloader (ABL) enabling standard Linux boot on Qualcomm Snapdragon handhelds without breaking Android dual-boot. |
| **Qualcomm Linux Kernel & Device Trees** | [ROCKNIX Distribution](https://github.com/ROCKNIX/distribution) & [Linux Kernel](https://www.kernel.org/) | Kernel tree, universal multi-device DTB bundle (23 device trees covering SM8250, SM8550, SM8650, and SM8750). |
| **Armada** | [Armada OS](https://github.com/armada-os/armada) | Qualcomm Linux firmware integration, device quirks references, and architectural inspiration. |
| **MaSieS4Fun** | [SteamOS-Ubuntu / MaSieS4Fun](https://github.com/MaSieS4Fun/SteamOS-Ubuntu) | Plugins and foundational scripts. |
| **ALSA & Audio Topologies** | Qualcomm | ALSA UCM2 mixer configurations and WSA884x speaker amplifier setup for AYANEO Pocket S. |

---

## Graphics & Performance Telemetry

| Component | Upstream / Author | What Reverie Uses |
| :--- | :--- | :--- |
| **Mesa / Freedreno Turnip** | [Mesa3D](https://gitlab.freedesktop.org/mesa/mesa) | High-performance open-source Vulkan 1.4 driver for Qualcomm Adreno 7xx and 8xx GPUs. |
| **MangoHud & MangoApp** | [flightlessmango/MangoHud](https://github.com/flightlessmango/MangoHud) | Performance telemetry overlay integrated directly with Steam Game Mode Quick Access Menu (QAM). |

---

## Decky Loader & Handheld Plugins

| Component | Upstream / Author | What Reverie Uses |
| :--- | :--- | :--- |
| **Decky Loader** | [SteamDeckHomebrew/decky-loader](https://github.com/SteamDeckHomebrew/decky-loader) | Homebrew plugin launcher for Steam Game Mode. |
| **Reverie Power** | Adapted from [Hooandee](https://github.com/Hooandee/panel-de-control) & [MaSieS4Fun](https://github.com/MaSieS4Fun/SteamOS-Ubuntu) | Decky plugin for Qualcomm Snapdragon power profiles, CPU governors, GPU clocks, and custom fan curves. |

---

## Acknowledgements

Special thanks to:
* **Valve Corporation** for building SteamOS and bringing PC gaming to handheld forms.
* The **ROCKNIX** and **Armada** developers for pioneering mainline Linux on Qualcomm Snapdragon handhelds.
* **Hooandee** and **MaSieS4Fun** for early Decky power control implementations.
