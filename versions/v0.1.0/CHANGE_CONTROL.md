# BatoSteam Installer – Change Control Register

| Field | Value |
|---|---|
| Product | BatoSteam Installer |
| Repository | yiddifliddo/BatoSteam |
| Author / Owner | Dan Lee |
| Company | None (personal project) |
| Current version | 0.1.0 |
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
