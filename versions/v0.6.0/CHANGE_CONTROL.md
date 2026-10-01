# BatoSteam Installer – Change Control Register

| Field | Value |
|---|---|
| Product | BatoSteam Installer |
| Repository | yiddifliddo/BatoSteam |
| Author / Owner | Dan Lee |
| Company | None (personal project) |
| Current version | 0.6.0 |
| Framework | ISO/IEC 27001:2022 Annex A 8.32 – Change management |

## Change management rules for this repository

1. Every change is recorded below as a new entry. Earlier entries are never edited or removed.
2. Every release bumps the version number (`VERSION`, script headers and `README.md`).
3. Every release is kept permanently as a frozen copy in `versions/vX.Y.Z/`. The repository root always holds the current version.
4. `main` holds the current released version. Each release also has its own `release/vX.Y.Z` branch.
5. The owner approves each change before any code is created or pushed.
6. Each change is tested before release, and the test evidence is recorded in its entry.
7. Each entry states a rollback plan.

---

## Change record

### CR-001 · v0.1.0 · 2026-09-27

| Field | Detail |
|---|---|
| Change ID | CR-001 |
| Version | 0.1.0 (initial release) |
| Date | 2026-09-27 |
| Author | Dan Lee |
| Requested by | Dan Lee |
| Approved by | Dan Lee (design approved before build: rEFInd boot menu, official Valve SteamOS, text-menu UI, format options = wipe / userdata filesystem / keep userdata; release to `main` + `release/v0.1.0`) |
| Type | New product |
| Branches | `main`, `release/v0.1.0` |

**Description**
Created a PC installer that puts Batocera and SteamOS on separate, user-chosen drives, each with its own format options, and adds a rEFInd boot menu for choosing the OS at power-on.

**Reason for change**
Owner requirement: a single installer for a dual-OS gaming PC (Batocera + SteamOS), with each OS on its own drive and a boot selection screen.

**Files added**
- `batosteam-installer.sh`
- `lib/common.sh`
- `lib/batocera.sh`
- `lib/steamos.sh`
- `lib/refind.sh`
- `config/refind.conf`
- `README.md`
- `CHANGE_CONTROL.md`
- `VERSION`
- `versions/v0.1.0/` (frozen copy of all of the above)

**Risk and impact assessment**

| Risk | Level | Mitigation |
|---|---|---|
| Data loss from wiping the wrong drive | High | Installer's own USB is hidden; the same drive can't be chosen twice; summary plus typed `ERASE` confirmation; `--dry-run` mode |
| SteamOS won't run on non-Deck hardware (for example NVIDIA) | Medium | Documented as experimental; Batocera and the boot menu are unaffected |
| An OS update removes or overrides the boot menu | Medium | rEFInd lives on its own `BSBOOT` partition; fallback `EFI/BOOT/BOOTX64.EFI`; `--repair-boot` option |
| A corrupted download is written to disk | Medium | SHA-256 pin (rEFInd), MD5 (Batocera `boot.tar.xz`), gzip integrity plus pipefail (Batocera image) |
| Upstream URLs or tools change | Low | URLs can be overridden with environment variables; a failed download stops the install before any write |

**Testing performed**
- `shellcheck` on all scripts: no findings.
- Batocera wipe path tested on a loop-device "drive" using a mock Batocera GPT image, for SHARE = ext4, btrfs and exFAT. Results: backup GPT relocated; SHARE grown to fill the drive; ext4 contents preserved; `BSBOOT` FAT32 partition created; `sfdisk --verify` reports no errors.
- SteamOS partition table written to a 20 GB loop device: all 8 partitions created with Valve's type GUIDs; `sfdisk --verify` reports no errors.
- Full SteamOS and rEFInd command sequence checked in `--dry-run` mode.
- rEFInd 0.14.2 archive downloaded, contents confirmed, SHA-256 pinned.
- Generated `refind.conf` checked.
- **Not yet tested on real hardware**: actual Batocera/SteamOS images, `steamos-chroot` finalisation, `efibootmgr` changes and booting through rEFInd. Hardware testing is needed before the SteamOS stage can be called stable.

**Rollback plan**
- Code: `main` can be reset to any earlier `versions/vX.Y.Z/` copy or `release/vX.Y.Z` branch. v0.1.0 has no earlier version.
- Installed PC: re-run the installer, or write the official Batocera image or SteamOS recovery image directly. Remove the "BatoSteam" UEFI entry with `efibootmgr -b XXXX -B`.

**Status:** Released

---

### CR-002 · v0.2.0 · 2026-09-27

| Field | Detail |
|---|---|
| Change ID | CR-002 |
| Version | 0.2.0 (previous: 0.1.0) |
| Date | 2026-09-27 |
| Author | Dan Lee |
| Requested by | Dan Lee |
| Approved by | Dan Lee (plan confirmed before build: all 7 items, version 0.2.0; SteamOS drive rule = warn and allow continue) |
| Type | Feature enhancement plus bug fixes |
| Branches | `main`, `release/v0.2.0` (`release/v0.1.0` unchanged) |

**Description**
- Detect existing Batocera and SteamOS installs, and let the user leave a complete install untouched.
- Add a flow for installing SteamOS on a PC that already has Batocera.
- Recommend an NVMe M.2 drive of 2 TB or larger, plus AMD graphics, for SteamOS.

**Reason for change**
Owner request: keep an already-installed OS if it meets the criteria, support adding SteamOS alongside an existing Batocera, and recommend a 2 TB+ M.2 drive with AMD graphics for SteamOS.

**Files changed**
- Added: `lib/detect.sh`
- Modified: `batosteam-installer.sh`, `lib/common.sh`, `lib/refind.sh`
- Version bump only: `lib/batocera.sh`, `lib/steamos.sh`, `config/refind.conf`
- Docs: `README.md`, `CHANGE_CONTROL.md`, `VERSION`
- Added: frozen copy in `versions/v0.2.0/` (`versions/v0.1.0/` untouched)

**Criteria used for "leave untouched"**
- **Batocera:** `BATOCERA` + `SHARE` labels, plus `boot/linux`, `boot/batocera` (or `.update`) and `EFI/batocera/grubx64.efi`.
- **SteamOS:** all 8 Valve partition names, plus `efi/steamos/steamcl.efi` on `esp`.

**Risk and impact assessment**

| Risk | Level | Mitigation |
|---|---|---|
| A working OS is overwritten by mistake | High | Drives tagged with their installed OS; extra warning before overwriting the other OS; drive left untouched is excluded from the other list |
| An incomplete install is kept and won't boot | Medium | "Leave" is only offered when all file and partition checks pass; failures are shown as INCOMPLETE |
| Undersized or non-AMD SteamOS hardware | Medium | Warning screen with the recommendation; user decides (owner choice: warn, allow continue) |
| Detection mounts drives | Low | All detection mounts are read-only and unmounted straight away |

**Testing performed**
- `shellcheck` on all scripts: no findings.
- Detection unit test with simulated drives (complete Batocera, complete SteamOS, broken Batocera, empty): all four reported correctly, including versions; `detect_find` returns the right drives.
- Hardware warnings: a 1 TB SATA drive gives size and NVMe warnings; a 2 TB NVMe drive gives none; no AMD GPU gives the graphics warning.
- Full menu dry runs in plain mode:
  - **A.** Add SteamOS to a Batocera PC: Batocera kept and excluded from the list, hardware warning shown, SteamOS installed, boot menu placed on SteamOS `esp`.
  - **B.** Both drives set to leave untouched: "boot menu only" prompt; summary and finish screens correct.
  - **C.** Picking the SteamOS drive for Batocera: the overwrite warning appears; answering No cancels.
- Earlier v0.1.0 loop-device partition tests are unaffected (no changes to the partitioning code).
- **Not yet tested on real hardware**, the same as CR-001.

**Rollback plan**
Restore `versions/v0.1.0/` to the repository root, or check out `release/v0.1.0`. No on-disk format changes were made in v0.2.0, so PCs installed with either version are compatible.

**Status:** Released

---

### CR-003 · v0.3.0 · 2026-09-27

| Field | Detail |
|---|---|
| Change ID | CR-003 |
| Version | 0.3.0 (previous: 0.2.0) |
| Date | 2026-09-27 |
| Author | Dan Lee |
| Requested by | Dan Lee (supplied Valve's "Installing SteamOS via USB key" instructions; asked to include SteamOS within the installer) |
| Approved by | Dan Lee (chose "Both A + B": built-in SteamOS download/stream, plus the all-in-one USB key; offline Batocera optional, asked when making the key; version 0.3.0) |
| Type | Feature enhancement plus bug fixes |
| Branches | `main`, `release/v0.3.0` (`release/v0.1.0` and `release/v0.2.0` unchanged) |

**Description**
- **A.** The installer obtains SteamOS itself. It streams Valve's official Deck/Machine/PC image and writes only the rootfs partition to the target drive. It can also copy from the recovery USB it runs on, or use a local image file.
- **B.** `make-usb.sh` (Linux) and `--setup-usb` (for keys written with Rufus or Balena Etcher on Windows/macOS) build a single BatoSteam USB key: Valve's recovery system, the BatoSteam installer with a desktop shortcut, and optional offline Batocera.

**Reason for change**
Owner request to include SteamOS within the BatoSteam installer, following Valve's USB-key instructions.

**Research performed**
- Valve's official recovery images (`steamdeck-recovery-4` 3.1 and `steamdeck-repair-latest` 3.8.14) were streamed and inspected. Each has 5 partitions (esp, efi-A, rootfs-A 5 GiB btrfs, var-A, home); the image sizes are 7.7 GB and 8.1 GB.
- The desktop shortcuts and `/home/deck/tools/repair_device.sh` were read from the images. Findings:
  1. The running rootfs is `/`, which Valve freezes during the copy. The public copy used in v0.1.0 had `/run/media/liveuser/rootfs`, which is wrong.
  2. The current partition sizes are esp 256 MiB and efi 64 MiB.
  3. `steamos-chroot --no-overlay` is used on SteamOS 3.5+.
  4. "Wipe Device & Install SteamOS" also sanitizes `/dev/nvme0n1`.
  5. Steam Deck BIOS and controller firmware updates are included; they are Deck-only and skipped by BatoSteam.

**Files changed**
- Added: `make-usb.sh`, `lib/usb.sh`
- Rewritten: `lib/steamos.sh` (native / stream / image modes, GPT reader, x86_64 check, Valve 3.8 sizes)
- Modified: `batosteam-installer.sh` (SteamOS source menu, offline Batocera, `--setup-usb`, recovery-USB warning, sources in the summary)
- Version bump only: `lib/common.sh`, `lib/batocera.sh`, `lib/refind.sh`, `lib/detect.sh`, `config/refind.conf`
- Docs: `README.md`, `CHANGE_CONTROL.md`, `VERSION`
- Added: frozen copy in `versions/v0.3.0/` (v0.1.0 and v0.2.0 untouched)

**Risk and impact assessment**

| Risk | Level | Mitigation |
|---|---|---|
| The user runs Valve's shortcuts and wipes the Batocera NVMe drive | High | Shortcuts moved into a warning folder with a README; a warning is shown when BatoSteam starts on a recovery USB |
| Wrong USB key erased by `make-usb.sh` | High | Only USB or removable drives listed; the running system is refused; size check; summary plus typed `ERASE` |
| A download is cut off or corrupted during streaming | Medium | Completion marker, a full `btrfs check` on both rootfs copies, and a `gzip -t` check of the offline Batocera image |
| The Steam Frame (ARM) image is used | Medium | Rejected by file name, and by an x86_64 loader check inside the image |
| Online growth of the running USB's home partition (`--setup-usb`) | Medium | Only done when offline Batocera is chosen; uses the kernel's online resize (`partx -u`, `resize2fs`); a failure only skips offline Batocera |
| Older SteamOS (3.1) copied from an old USB key | Low | "Download latest" is listed first and recommended; SteamOS updates itself after install |

**Testing performed**
- `shellcheck` on all scripts: no findings.
- **Stream mode (real):** SteamOS 3.8.14 streamed from Valve's server onto a 20 GB loop "drive". The rootfs was located from the image's GPT (offset 335544320, 5120 MiB); rootfs-A and rootfs-B were written with new, distinct btrfs UUIDs; both passed `btrfs check`; home ext4 was created. The Valve setup steps (`steamos-chroot`) were stubbed because the test kernel cannot mount btrfs.
- **`make-usb.sh` (real):** Valve's 8.1 GB image was written to a 15.5 GB loop "USB key", and the home partition was grown from 1.7 GB to 9.6 GB (GPT relocated, `e2fsck` clean, `resize2fs` OK). The final mount could not be tested because the test kernel lacks ext4 casefold support; the error message was confirmed.
- **Shortcut step:** tested on a copy of Valve's `deck/Desktop` layout. The BatoSteam shortcut was created; Device/OS/User shortcuts were moved to the warning folder with a README; Tools was kept; owner uid 1000.
- **GPT reader:** checked against a Python parse of both Valve images.
- **Installer menus (dry run):** source menu, summary with source lines, and the full add-SteamOS flow.
- **Not yet tested on real hardware.**

**Rollback plan**
Restore `versions/v0.2.0/` to the repository root, or check out `release/v0.2.0`. Installed PCs are unaffected: the drive layouts are compatible, except that new SteamOS installs use Valve's newer, larger esp/efi sizes.

**Status:** Released

---

### CR-004 · v0.4.0 · 2026-10-01

| Field | Detail |
|---|---|
| Change ID | CR-004 |
| Version | 0.4.0 (previous: 0.3.0) |
| Date | 2026-10-01 |
| Author | Dan Lee |
| Requested by | Dan Lee ("How can I check this works without killing my PC set up"; PC currently has Batocera installed) |
| Approved by | Dan Lee (chose: add `test-vm.sh`; change the boot menu to a graphical one; style "Split screen"; "Yes, build v0.4.0") |
| Type | Feature enhancement plus bug fix |
| Branches | `main`, `release/v0.4.0` (earlier release branches unchanged) |

**Description**
- Safe virtual-machine test harness (`test-vm.sh`).
- Graphical split-screen theme for the rEFInd boot menu, with original artwork, a generator script, and real screenshots.

**Reason for change**
The owner needs to prove the installer works without risking the existing Batocera PC, and wants a graphical boot menu.

**Files changed**
- Added: `test-vm.sh`, `tools/make-theme.py`, `config/theme/` (background, os_batocera, os_steamos, selection_big, selection_small), `docs/boot-menu-screenshot.png`, `docs/boot-menu-screenshot-steamos.png`, `docs/boot-menu-preview.png`
- Modified: `config/refind.conf` (theme settings, mouse option removed), `lib/refind.sh` (copies the theme and font, theme icons by default), `lib/usb.sh` (also copies `docs/` to the USB key)
- Version bump only: `batosteam-installer.sh`, `make-usb.sh`, `lib/common.sh`, `lib/batocera.sh`, `lib/steamos.sh`, `lib/detect.sh`
- Docs: `README.md`, `CHANGE_CONTROL.md`, `VERSION`
- Added: frozen copy in `versions/v0.4.0/` (earlier versions untouched)

**Risk and impact assessment**

| Risk | Level | Mitigation |
|---|---|---|
| The test VM touches the real drives | High (if it happened) | The VM only uses image files in `./vm-test`; no host block device is passed to QEMU; the only host write is the USB image file through a loop device |
| The theme fails to load on some firmware | Low | rEFInd falls back to its defaults if an image fails; the boot entries are unaffected |
| Different screen aspect ratio | Low | `banner_scale fillscreen` scales the background; icons and text are drawn by rEFInd at native resolution |
| Trademark concerns with logos | Low | All artwork is original; official logos are only used if the owner adds them |

**Testing performed**
- `shellcheck` on all scripts: no findings.
- **Real rEFInd test:** the real `refind_install` code wrote the boot partition. It was booted with rEFInd 0.14.2 under QEMU (q35, OVMF), with mock BATOCERA and SteamOS `esp` partitions matched by PARTUUID. Results:
  - The theme renders at 1920×1080 and both entries are found.
  - The first run showed no selection highlight or label (caused by mouse mode) and a garbled 28 px font. Both were fixed (mouse option removed, 24 px font).
  - Re-tested: the default entry is highlighted, the label is clean, Right arrow moves to SteamOS, and the 10 s countdown boots the default entry.
- **`test-vm.sh`:**
  - Headless boot of the fake drives works.
  - Snapshot create, list and restore work, and reset-all works.
  - `--with-batocera-installed` was tested with a local mock Batocera image: written to fake NVMe 1 (qcow2, resized to 64 GiB) with its partitions intact.
  - The virtual USB build uses the `make-usb.sh` tested in CR-003; its final mount needs a host kernel with ext4 casefold support, which this test container lacks.
- **Not yet tested on real hardware.**

**Rollback plan**
Restore `versions/v0.3.0/` or check out `release/v0.3.0`. To return an installed PC to the plain menu, re-run v0.3.0's "Repair boot menu" install, or delete `EFI/refind/themes` and the theme lines from `refind.conf`.

**Status:** Released

---

### CR-005 · v0.5.0 · 2026-10-01

| Field | Detail |
|---|---|
| Change ID | CR-005 |
| Version | 0.5.0 (previous: 0.4.0) |
| Date | 2026-10-01 |
| Author | Dan Lee |
| Requested by | Dan Lee ("It must not overwrite the installed OS such as Batocera. Give users the option to start from a fresh install OR scan and use the installation that's already there") |
| Approved by | Dan Lee (chose: protected drives unlock only by typing `OVERWRITE <drive>`; incomplete installs also protected; "Yes, build v0.5.0") |
| Type | Safety enhancement plus behaviour change |
| Branches | `main`, `release/v0.5.0` (earlier release branches unchanged) |

**Description**
- New start screen: **Use my existing installation(s)**, **Fresh install**, and **Repair an installed OS**.
- Drives with an OS (complete or incomplete) or other data are **PROTECTED** and can only be written after a typed, per-drive unlock.
- The install code now has a second, independent safety check.

**Reason for change**
Owner requirement: an installed OS (for example Batocera) must never be overwritten. Users choose between a fresh install and using what is already there.

**Gaps closed (v0.4.0 behaviour)**
1. A drive with Batocera could be wiped after a single Yes/No warning.
2. "Keep userdata – reinstall system" replaced the OS, as an ordinary format option.
3. Drives with other data showed as "empty / other" with no protection.
4. Protection existed only in the menus.

**Files changed**
- `lib/detect.sh`: `detect_disk`, `DETECT_PROTECTED`, `UNLOCKED`, other-data detection, the `guard_writable` safety check, and `[PROTECTED]` in the report
- `lib/common.sh`: the `safety_check` wrapper (refuses to write if the safety module is missing)
- `lib/batocera.sh`, `lib/steamos.sh`: call `safety_check` before any write (wipe and repair)
- `batosteam-installer.sh`: new main menu and flows (`flow_existing`, `flow_fresh`, `flow_repair`), `pick_disk` with empty-only and locked modes, `unlock_drive`, and a summary listing protected drives
- Version bump only: `make-usb.sh`, `test-vm.sh`, `lib/refind.sh`, `lib/usb.sh`, `config/refind.conf`, `tools/make-theme.py`
- Docs: `README.md`, `CHANGE_CONTROL.md`, `VERSION`
- Added: frozen copy in `versions/v0.5.0/` (earlier versions untouched)

**Risk and impact assessment**

| Risk | Level | Mitigation |
|---|---|---|
| Installed OS overwritten by mistake | High → Low | Hidden or locked in the menus; typed per-drive unlock; independent re-scan in the install code; summary lists protected drives |
| A drive wrongly detected as empty | Medium | Any partition or filesystem signature (via lsblk and blkid) marks a drive as protected; only truly empty drives are unprotected |
| The user cannot reuse an old drive | Low | **Fresh install** → Unlock → `OVERWRITE <drive>` |
| The boot menu writes to a kept drive's EFI partition | Low | Only a new `EFI/refind` folder is added; no existing file is replaced; documented |

**Testing performed**
- `shellcheck` on all scripts: no findings.
- **Safety stop, called directly with the menus bypassed** (simulated PC: Batocera NVMe, empty NVMe, NTFS SATA):
  - Wipe on Batocera → SAFETY STOP, **no write commands**.
  - Repair on Batocera → SAFETY STOP.
  - Wipe on NTFS → SAFETY STOP.
  - Wipe on the empty drive → allowed (writes only to that drive).
  - Unlocked Batocera drive → allowed, and logged.
  - Safety module missing → nothing written.
- **Menu dry runs:**
  - Existing: Batocera kept, SteamOS offered only the empty drive ("1 protected drive hidden"), NTFS drive listed as PROTECTED in the summary.
  - Fresh: the protected drive was locked; wrong unlock text kept it protected; "Choose another drive" went back; `OVERWRITE sda` unlocked only sda; the summary listed the Batocera drive as protected and untouched.
  - Repair: wrong text → still protected; `REPAIR nvme0n1` → repair allowed, and logged.
  - Start screen showed the detected drives with `[PROTECTED]`.
- **Bug found and fixed during testing:** the repair flow returned "failure" when no other OS was found, so it stopped silently.
- **Not yet tested on real hardware.**

**Rollback plan**
Restore `versions/v0.4.0/` or check out `release/v0.4.0`. No on-disk format changes.

**Status:** Released

---

### CR-006 · v0.6.0 · 2026-10-01

| Field | Detail |
|---|---|
| Change ID | CR-006 |
| Version | 0.6.0 (previous: 0.5.0) |
| Date | 2026-10-01 |
| Author | Dan Lee |
| Requested by | Dan Lee ("Will it download the packages over Wi-Fi or Ethernet - how is network set up for downloading updates") |
| Approved by | Dan Lee (chose: "Network check + connect" and "Fully offline USB key") |
| Type | Feature enhancement plus bug fix |
| Branches | `main`, `release/v0.6.0` (earlier release branches unchanged) |

**Description**
- Network check before installing, with Wi-Fi connect and a network status screen.
- rEFInd is stored on the BatoSteam USB key so installs can be fully offline.
- README section on networking and OS updates.

**Reason for change**
The owner asked how BatoSteam connects for downloads and updates. The review found three gaps:
1. There was no connection check (it only failed when a download started).
2. rEFInd was always downloaded, so a fully offline install wasn't possible.
3. There was no way to connect Wi-Fi from BatoSteam.

**Research performed**
Valve's current recovery image (SteamOS 3.8.14) was streamed and its rootfs inspected. It contains `NetworkManager`, `nmcli`, `nmtui`, `iwctl`, `wpa_cli`, `whiptail`, `curl` and `unzip`, so the Wi-Fi connect feature can rely on `nmcli`.

**Files changed**
- Added: `lib/network.sh` (status, needed-download list, reachability check, Wi-Fi connect, network menu, preflight)
- Modified:
  - `lib/common.sh`: `ui_password`, hidden input that is never logged
  - `lib/refind.sh`: `refind_offline_zip`; uses the USB key's verified copy first
  - `lib/usb.sh`: stores rEFInd on the key
  - `make-usb.sh`: sources `refind.sh`
  - `batosteam-installer.sh`: preflight before confirmation; "Network" main-menu item
- Version bump only: `test-vm.sh`, `lib/batocera.sh`, `lib/steamos.sh`, `lib/detect.sh`, `config/refind.conf`, `tools/make-theme.py`
- Docs: `README.md`, `CHANGE_CONTROL.md`, `VERSION`
- Added: frozen copy in `versions/v0.6.0/` (earlier versions untouched)

**Risk and impact assessment**

| Risk | Level | Mitigation |
|---|---|---|
| Wi-Fi password exposure | Medium | Hidden input field; never passed through the logging `run` helper; the password variable is cleared after use; the log was checked to contain no password |
| False "no internet" | Medium | Checks the exact files and URLs that will be downloaded (fixed during testing); "Check again" is always offered |
| Desktop Wi-Fi card not supported by the recovery kernel | Low | Clear message; Ethernet and USB tethering documented; offline USB key |
| Offline rEFInd copy corrupted | Low | SHA-256 checked when stored and when used; falls back to download |

**Testing performed**
- `shellcheck` on all scripts: no findings.
- **Needed-download list:**
  - Your setup (keep Batocera + download SteamOS) → SteamOS + rEFInd.
  - Fresh install → Batocera + SteamOS + rEFInd.
  - Fully offline (SteamOS from USB, Batocera offline, rEFInd on the key) → nothing; "fully offline".
- **Reachability (real, from the test machine):** Valve image URL, Batocera and SourceForge all OK after the fix. Before the fix, Valve's bare server address failed.
- **Preflight:**
  - Offline → the screen lists the missing downloads and the network status; Cancel returns with "Nothing was changed".
  - Check again after the connection appears → continues.
- **Wi-Fi connect (simulated nmcli):**
  - The list is de-duplicated and sorted by signal, and "Cafe:Guest" is parsed correctly.
  - Open network connected without a password; hidden network sent `hidden yes`; a wrong password showed the error.
  - **No password appeared in the log.**
- **Full installer dry run:** the network check runs before the confirmation screen; the main menu shows "Network".
- **USB key:** rEFInd was stored on a copy of the recovery home and verified; the installer on the key picks it up.
- **Not yet tested on real hardware** (real Wi-Fi hardware and NetworkManager).

**Rollback plan**
Restore `versions/v0.5.0/` or check out `release/v0.5.0`. No on-disk format changes.

**Status:** Released
