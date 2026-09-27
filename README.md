# BatoSteam Installer

**Version:** 0.1.0
**Author:** Dan Lee
**Company:** None (personal project)
**Licence:** see upstream projects for the operating systems it installs

BatoSteam installs **Batocera** (retro gaming) and **SteamOS** (Valve) on **separate drives** of the same PC. You choose a drive and format options for each OS, and a **rEFInd boot menu** at power-on lets you pick which OS to start.

```
 ┌──────────────── BatoSteam boot menu (rEFInd) ────────────────┐
 │        [ Batocera ]                [ SteamOS ]               │
 │   starts default OS after 10 s   ·   arrow keys / mouse      │
 └──────────────────────────────────────────────────────────────┘
      Drive 1: Batocera + BSBOOT        Drive 2: SteamOS
```

---

## Requirements

- 64-bit PC booting in **UEFI mode** (legacy BIOS is not supported)
- **Secure Boot OFF** (rEFInd, Batocera's EFI loader and SteamOS's steamcl are not signed for Secure Boot)
- **Two drives**: one for Batocera (16 GB or more) and one for SteamOS (64 GB or more recommended)
- Internet connection during install
- A USB stick with **Valve's SteamOS recovery image** (recommended, see below)
- **AMD or Intel graphics** for SteamOS. Official SteamOS has no NVIDIA driver. Batocera supports NVIDIA.

> ⚠️ **SteamOS on a normal PC is unofficial.** Valve supports SteamOS 3 on Steam Deck and selected handhelds. It may boot on other PCs, but hardware support is not guaranteed. The SteamOS stage of this installer is **experimental**.

---

## How to use

### Recommended: run from Valve's SteamOS recovery USB

This live system already contains the SteamOS system image and the `steamos-chroot`, `btrfstune` and `steamcl-install` tools that the installer needs.

1. Download the recovery image: <https://steamdeck-images.steamos.cloud/recovery/steamdeck-repair-latest.img.bz2>
2. Write it to a USB stick (balenaEtcher, Rufus or `bzcat ... | dd`).
3. Boot the PC from the USB stick (UEFI, Secure Boot off). It opens a SteamOS desktop.
4. Open **Konsole** and run:
   ```bash
   curl -L -o batosteam.tar.gz https://github.com/yiddifliddo/BatoSteam/archive/refs/heads/main.tar.gz
   tar xzf batosteam.tar.gz && cd BatoSteam-main
   sudo ./batosteam-installer.sh
   ```
5. Follow the menus:
   1. **Install Batocera + SteamOS**
   2. Pick the **Batocera drive**, then a format option (see the next section)
   3. Pick the **SteamOS drive**, then a format option
   4. Pick the **default OS** for the boot menu
   5. Check the summary and type **ERASE** to confirm
6. When it finishes, remove the USB stick and reboot. The BatoSteam menu appears.

### Alternative: run from any other live Linux USB (Ubuntu, Arch, etc.)

Download and decompress the SteamOS recovery image to a drive with about 10 GB free, then pass it in:

```bash
bunzip2 steamdeck-repair-latest.img.bz2
sudo ./batosteam-installer.sh --steamos-image /path/to/steamdeck-repair-*.img
```

The live system needs `btrfs-progs`, `e2fsprogs`, `dosfstools`, `fdisk` (sfdisk), `curl`, `xz`, `efibootmgr` and `unzip`. For exFAT userdata it also needs `exfatprogs`.

### Command-line options

| Option | What it does |
|---|---|
| `--dry-run` | Goes through every menu and prints each command, but **writes nothing** |
| `--steamos-image FILE` | Uses a decompressed SteamOS recovery `.img` file (for running from another live Linux) |
| `--batocera-image FILE` | Uses a local Batocera `.img.gz` or `.img` instead of downloading one |
| `--repair-boot` | Moves the BatoSteam menu back to the front of the UEFI boot order |
| `--version` / `--help` | Shows the version or help |

---

## Format options

| OS | Option | Result |
|---|---|---|
| Batocera | **Wipe whole drive** | Writes the latest stable Batocera x86_64 image, grows SHARE to fill the drive and adds the 64 MiB `BSBOOT` boot-menu partition |
| Batocera | **Userdata filesystem** | SHARE is formatted as **ext4** (default), **btrfs** or **exFAT** (readable from Windows and macOS). These are the same three filesystems Batocera's own formatter supports. |
| Batocera | **Keep existing userdata** | Unpacks the latest `boot.tar.xz` over the BATOCERA partition, the same way Batocera's own updater does. ROMs, saves, BIOS files and `batocera-boot.conf` are kept. |
| SteamOS | **Wipe whole drive** | Creates Valve's 8-partition A/B layout and installs SteamOS |
| SteamOS | **Keep existing userdata** | Reinstalls both system slots and keeps `home` (installed games, Steam login) |

SteamOS always uses ext4 (with casefold) for `home`. This is required by SteamOS, so the filesystem choice only applies to Batocera.

---

## Drive layouts created

**Batocera drive**

| # | Label | FS | Size | Purpose |
|---|---|---|---|---|
| 1 | BATOCERA | FAT32 (ESP) | ~10 GiB | Batocera kernel, system and EFI loader |
| 2 | SHARE | ext4/btrfs/exFAT | rest | ROMs, saves, BIOS, settings |
| 3 | BSBOOT | FAT32 (ESP) | 64 MiB | **rEFInd boot menu** |

**SteamOS drive** (Valve's layout)

| # | Name | Size |
|---|---|---|
| 1 | esp | 64 MiB |
| 2–3 | efi-A / efi-B | 32 MiB each |
| 4–5 | rootfs-A / rootfs-B | 5 GiB each (btrfs, read-only) |
| 6–7 | var-A / var-B | 256 MiB each |
| 8 | home | rest (games) |

### Why the boot menu has its own partition

Batocera's updater treats unknown files on the BATOCERA partition as stale and deletes them. SteamOS's updates manage its `esp`. Keeping rEFInd on `BSBOOT` means neither OS's updates can remove the boot menu.

---

## Troubleshooting

- **The PC boots straight into SteamOS or Batocera without showing the menu.** An OS update or the firmware changed the boot order. Boot the USB again and run `sudo ./batosteam-installer.sh --repair-boot`, or choose "BatoSteam" as the first boot option in your firmware settings.
- **"Secure Boot violation".** Turn Secure Boot off in your firmware settings.
- **SteamOS shows a black screen.** This is usually unsupported graphics (for example NVIDIA). Batocera is unaffected.
- **Log file.** `/tmp/batosteam-install.log` on the live USB.

---

## Project structure

```
BatoSteam/
├── batosteam-installer.sh   main text-menu installer (current version)
├── lib/
│   ├── common.sh            logging, menus, drive detection, safety checks
│   ├── batocera.sh          Batocera install (wipe / keep userdata / filesystem)
│   ├── steamos.sh           SteamOS install (Valve A/B layout, any drive)
│   └── refind.sh            rEFInd boot menu and UEFI boot order
├── config/
│   └── refind.conf          boot menu template
├── versions/
│   └── v0.1.0/              frozen copy of every released version
├── VERSION
├── README.md                this file (with change log)
└── CHANGE_CONTROL.md        formal change-control register
```

Custom menu icons: add `config/icons/os_batocera.png` and `config/icons/os_steamos.png` (128×128 PNG) and they are used automatically.

---

## Safety

- The drive the installer is running from is never offered as a target.
- The same drive cannot be picked for both OSes.
- "Keep userdata" is only offered when the existing layout is detected.
- Wiping requires a summary confirmation **and** typing `ERASE`.
- `--dry-run` writes nothing at all.
- Downloads are checked: rEFInd by pinned SHA-256, Batocera `boot.tar.xz` by MD5, and the Batocera image by gzip integrity.

---

## Upstream sources

- Batocera: <https://github.com/batocera-linux/batocera.linux>. Image layout from `board/batocera/x86/genimage.cfg`; update method from `batocera-upgrade`.
- SteamOS: <https://github.com/ValveSoftware/SteamOS> (issue tracker only, no source code). The install steps follow Valve's recovery-image `repair_device.sh`.
- rEFInd: <https://www.rodsbooks.com/refind/>

---

## Change log

### v0.1.0 (2026-09-27) · Author: Dan Lee
Initial release.
- Text-menu installer (whiptail, then dialog, then plain-terminal fallback)
- Separate drive selection for Batocera and SteamOS, with the running USB hidden and duplicate picks blocked
- Batocera format options: wipe whole drive; SHARE as ext4, btrfs or exFAT; keep existing userdata (upgrade-style reinstall)
- SteamOS (experimental): Valve A/B layout on **any** drive (not only `/dev/nvme0n1`); wipe, or keep `home`
- rEFInd 0.14.2 boot menu on a dedicated `BSBOOT` partition, with a 10 s timeout, a selectable default OS and a fallback loader
- UEFI boot-order handling via `efibootmgr`, plus a `--repair-boot` option
- `--dry-run`, `--steamos-image` and `--batocera-image` options
- Install log at `/tmp/batosteam-install.log`
