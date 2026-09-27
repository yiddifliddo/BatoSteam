#!/bin/bash
# BatoSteam Installer
# Author: Dan Lee
# Version: 0.2.0
#
# Installs Batocera and SteamOS onto separate drives of one PC, then adds a
# rEFInd boot menu so you can pick which OS to start at power-on.
#
# Usage:
#   sudo ./batosteam-installer.sh                 interactive text menus
#   sudo ./batosteam-installer.sh --dry-run       walk through everything, write nothing
#   sudo ./batosteam-installer.sh --steamos-image /path/steamdeck-repair.img
#   sudo ./batosteam-installer.sh --batocera-image /path/batocera-x86_64.img.gz
#   sudo ./batosteam-installer.sh --repair-boot   put the boot menu first again

set -uo pipefail

BATOSTEAM_VERSION="0.2.0"
BATOSTEAM_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# shellcheck source=lib/common.sh
source "$BATOSTEAM_DIR/lib/common.sh"
# shellcheck source=lib/batocera.sh
source "$BATOSTEAM_DIR/lib/batocera.sh"
# shellcheck source=lib/steamos.sh
source "$BATOSTEAM_DIR/lib/steamos.sh"
# shellcheck source=lib/refind.sh
source "$BATOSTEAM_DIR/lib/refind.sh"
# shellcheck source=lib/detect.sh
source "$BATOSTEAM_DIR/lib/detect.sh"

STEAMOS_IMAGE=""
BATOCERA_IMAGE=""
ACTION=""

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         DRY_RUN=1 ;;
    --steamos-image)   STEAMOS_IMAGE="$2"; shift ;;
    --batocera-image)  BATOCERA_IMAGE="$2"; shift ;;
    --repair-boot)     ACTION=repair ;;
    --version)         echo "BatoSteam Installer $BATOSTEAM_VERSION"; exit 0 ;;
    -h|--help)         usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

UI_TITLE="BatoSteam Installer v$BATOSTEAM_VERSION$([[ $DRY_RUN = 1 ]] && echo '  [DRY RUN - nothing will be written]')"

# Choices made in the menus
BATO_DISK=""; BATO_MODE=""; BATO_FS=""
STEAM_DISK=""; STEAM_MODE=""
DEFAULT_OS="Batocera"

# pick_disk TITLE EXCLUDE_DISK TARGET_OS -> prints /dev/NAME
# Each drive is tagged with what is already installed on it. Picking a drive that
# holds the OTHER operating system needs an extra confirmation.
pick_disk() {
  local title="$1" exclude="${2:-}" target="${3:-}" args=() name size model tran tag disk
  while IFS=$'\t' read -r name size model tran; do
    [[ /dev/$name = "$exclude" ]] && continue
    tag="${DETECT_INFO[/dev/$name]:-}"
    [[ -z $tag || $tag = "empty / other" ]] && tag="" || tag="  <$tag>"
    args+=("/dev/$name" "$size  $model  [$tran]$tag")
  done < <(list_disks)
  [[ ${#args[@]} -gt 0 ]] || { ui_msg "$title" "No suitable drives found.\n\nThe drive BatoSteam is running from is hidden for safety."; return 1; }
  disk="$(ui_menu "$title" "Choose the drive. <...> shows what is already installed on it." "${args[@]}")" || return 1
  local other="${DETECT_OS[$disk]:-}"
  if [[ -n $other && $other != "$target" ]]; then
    ui_yesno "WARNING - $other is installed on this drive" \
"$disk contains:\n  ${DETECT_INFO[$disk]}\n\nInstalling $target here will ERASE $other and everything on the drive.\n\nAre you sure you want to use this drive for $target?" || return 1
  fi
  echo "$disk"
}

setup_batocera() {
  BATO_DISK="$(pick_disk "Batocera - choose drive" "$STEAM_DISK" Batocera)" || return 1
  local opts=()
  [[ ${DETECT_OS[$BATO_DISK]:-} = Batocera && ${DETECT_VALID[$BATO_DISK]:-0} = 1 ]] && \
    opts+=(leave "Leave existing install untouched (${DETECT_INFO[$BATO_DISK]})")
  opts+=(wipe "Wipe whole drive and install Batocera")
  batocera_detect "$BATO_DISK" && opts+=(keep "Keep existing userdata (ROMs, saves) - reinstall system only")
  BATO_MODE="$(ui_menu "Batocera - format options" "Drive: $BATO_DISK" "${opts[@]}")" || return 1
  if [[ $BATO_MODE = wipe ]]; then
    BATO_FS="$(ui_menu "Batocera - userdata filesystem" \
      "Filesystem for the SHARE partition (ROMs, saves, BIOS):" \
      ext4  "ext4  - Batocera default, most reliable (Recommended)" \
      btrfs "btrfs - compression and snapshots" \
      exfat "exFAT - readable/writable from Windows and macOS")" || return 1
    command -v "mkfs.$BATO_FS" >/dev/null 2>&1 || { ui_msg "Missing tool" "mkfs.$BATO_FS is not available on this live system. Choose another filesystem."; return 1; }
  fi
}

steamos_needs_tools() {
  if [[ -z $STEAMOS_IMAGE ]] && ! command -v steamos-chroot >/dev/null 2>&1; then
    STEAMOS_IMAGE="$(ui_input "SteamOS - recovery image" \
"BatoSteam is not running from Valve's SteamOS recovery USB.\n\nEnter the path to a DECOMPRESSED recovery image (.img).\nDownload: $STEAMOS_RECOVERY_URL\nthen: bunzip2 steamdeck-repair-*.img.bz2" "")" || return 1
    [[ -n $STEAMOS_IMAGE ]] || return 1
  fi
  if ! command -v btrfstune >/dev/null 2>&1 || ! command -v mkfs.ext4 >/dev/null 2>&1; then
    ui_msg "Missing tool" "SteamOS install needs btrfs-progs (btrfstune) and e2fsprogs. Boot Valve's SteamOS recovery USB, which has them."
    return 1
  fi
}

setup_steamos() {
  STEAM_DISK="$(pick_disk "SteamOS - choose drive (recommended: NVMe M.2, 2 TB+)" "$BATO_DISK" SteamOS)" || return 1
  local opts=()
  [[ ${DETECT_OS[$STEAM_DISK]:-} = SteamOS && ${DETECT_VALID[$STEAM_DISK]:-0} = 1 ]] && \
    opts+=(leave "Leave existing install untouched (${DETECT_INFO[$STEAM_DISK]})")
  opts+=(wipe "Wipe whole drive and install SteamOS")
  steamos_detect "$STEAM_DISK" && opts+=(keep "Keep existing userdata (games in /home) - reinstall system only")
  STEAM_MODE="$(ui_menu "SteamOS - format options" \
    "Drive: $STEAM_DISK\n\nSteamOS always uses ext4 for userdata (Valve requirement)." "${opts[@]}")" || return 1
  [[ $STEAM_MODE = leave ]] && return 0
  steamos_needs_tools || return 1
  steamos_hardware_check "$STEAM_DISK" || return 1
}

# Add SteamOS to a PC that already has a working Batocera drive - Batocera is not touched.
setup_add_steamos() {
  local found=() d
  for d in "${!DETECT_OS[@]}"; do
    [[ ${DETECT_OS[$d]} = Batocera && ${DETECT_VALID[$d]} = 1 ]] && found+=("$d" "${DETECT_INFO[$d]}")
  done
  if [[ ${#found[@]} -eq 0 ]]; then
    ui_msg "No Batocera found" "No complete Batocera install was found on any drive.\n\nDetected:\n$(detect_report)\n\nUse 'Install Batocera + SteamOS' instead."
    return 1
  elif [[ ${#found[@]} -eq 2 ]]; then
    BATO_DISK="${found[0]}"
  else
    BATO_DISK="$(ui_menu "Existing Batocera" "More than one Batocera drive found. Which one should appear in the boot menu?" "${found[@]}")" || return 1
  fi
  BATO_MODE=leave
  ui_msg "Existing Batocera kept" "Batocera on $BATO_DISK will be LEFT UNTOUCHED:\n  ${DETECT_INFO[$BATO_DISK]}\n\nNext: choose a different drive for SteamOS."
  setup_steamos
}

summary_text() {
  local s="${1:-The following will happen:}\n\n"
  if [[ -n $BATO_DISK ]]; then
    s+="BATOCERA -> $BATO_DISK\n"
    case $BATO_MODE in
      wipe)  s+="   ERASE whole drive, SHARE filesystem: $BATO_FS\n" ;;
      keep)  s+="   Reinstall system, KEEP userdata\n" ;;
      leave) s+="   LEAVE UNTOUCHED (${DETECT_INFO[$BATO_DISK]:-existing install})\n" ;;
    esac
  fi
  if [[ -n $STEAM_DISK ]]; then
    s+="STEAMOS  -> $STEAM_DISK$([[ $STEAM_MODE != leave ]] && echo "  (experimental)")\n"
    case $STEAM_MODE in
      wipe)  s+="   ERASE whole drive\n" ;;
      keep)  s+="   Reinstall system, KEEP games/home\n" ;;
      leave) s+="   LEAVE UNTOUCHED (${DETECT_INFO[$STEAM_DISK]:-existing install})\n" ;;
    esac
  fi
  s+="BOOT MENU -> rEFInd, default: $DEFAULT_OS, 10s timeout\n"
  echo "$s"
}

confirm_install() {
  ui_yesno "Confirm" "$(summary_text)\nContinue?" || return 1
  if [[ $BATO_MODE = wipe || $STEAM_MODE = wipe ]]; then
    local typed
    typed="$(ui_input "Final confirmation" "Data on the drive(s) marked ERASE will be permanently destroyed.\n\nType ERASE to continue:" "")" || return 1
    [[ $typed = ERASE ]] || { ui_msg "Cancelled" "Nothing was changed."; return 1; }
  fi
}

do_install() {
  local what="$1"
  BATO_DISK=""; STEAM_DISK=""; BATO_MODE=""; STEAM_MODE=""
  detect_scan 2>/dev/null
  case "$what" in
    both)     setup_batocera || return; setup_steamos || return ;;
    batocera) setup_batocera || return ;;
    steamos)  setup_steamos  || return ;;
    addsteam) setup_add_steamos || return ;;
  esac
  if [[ ( -z $BATO_DISK || $BATO_MODE = leave ) && ( -z $STEAM_DISK || $STEAM_MODE = leave ) ]]; then
    ui_yesno "Nothing to install" "Every chosen drive is set to 'leave untouched'.\n\nOnly (re)install the boot menu?" || return
  fi
  if [[ -n $BATO_DISK && -n $STEAM_DISK ]]; then
    DEFAULT_OS="$(ui_menu "Boot menu" "Which OS should start if nobody presses a key?" \
      Batocera "Batocera" SteamOS "SteamOS")" || return
  else
    DEFAULT_OS="$([[ -n $BATO_DISK ]] && echo Batocera || echo SteamOS)"
  fi
  confirm_install || return

  : > "$BATOSTEAM_LOG"
  log "BatoSteam Installer $BATOSTEAM_VERSION starting (dry run: $DRY_RUN)"

  if [[ -n $BATO_DISK && $BATO_MODE != leave ]]; then
    if [[ $BATO_MODE = wipe ]]; then
      local src="$BATOCERA_IMAGE"
      [[ -n $src ]] || src="$(batocera_image_url)" || die "Could not look up the latest Batocera image (check internet)."
      log "Batocera image: $src"
      batocera_install_wipe "$BATO_DISK" "$BATO_FS" "$src"
    else
      batocera_install_keep "$BATO_DISK"
    fi
  fi

  if [[ -n $STEAM_DISK && $STEAM_MODE != leave ]]; then
    steamos_prepare_source "$STEAMOS_IMAGE"
    steamos_install "$STEAM_DISK" "$STEAM_MODE"
    steamos_cleanup_source
  fi

  # When only one OS is being (re)installed, keep the other drive's menu entry.
  local menu_bato="$BATO_DISK" menu_steam="$STEAM_DISK" d
  if [[ -z $menu_bato || -z $menu_steam ]]; then
    for d in $(lsblk -dnpo NAME); do
      [[ -z $menu_bato && $d != "$menu_steam" ]] && batocera_detect "$d" && menu_bato="$d"
      [[ -z $menu_steam && $d != "$menu_bato" ]] && steamos_detect "$d"  && menu_steam="$d"
    done
  fi
  refind_install "$menu_bato" "$menu_steam" "$DEFAULT_OS"

  ui_msg "Finished" "Installation complete.\n\n$(summary_text "What was done:")\nBefore rebooting: make sure SECURE BOOT is OFF in your firmware (rEFInd and SteamOS are not signed).\n\nRemove the USB stick and reboot - the BatoSteam menu will appear.\n\nLog: $BATOSTEAM_LOG"
}

main_menu() {
  local choice
  while true; do
    choice="$(ui_menu "Main menu" \
"Install Batocera and SteamOS on separate drives with a boot menu.\n\nUEFI only. Secure Boot must be OFF.\nSteamOS on non-Steam-Deck PCs is unofficial.\nRecommended for SteamOS: NVMe M.2 SSD 2 TB+ and AMD Radeon graphics." \
      detect   "Show detected installations" \
      both     "Install Batocera + SteamOS (one drive each)" \
      addsteam "Add SteamOS to my Batocera PC (keeps Batocera untouched)" \
      batocera "Install / reinstall Batocera only" \
      steamos  "Install / reinstall SteamOS only (experimental)" \
      repair   "Repair boot menu (put BatoSteam first again)" \
      drives   "Show drives" \
      quit     "Exit")" || break
    case "$choice" in
      detect) detect_scan 2>/dev/null; ui_msg "Detected installations" "$(detect_report)" ;;
      both|batocera|steamos|addsteam) do_install "$choice" ;;
      repair) refind_repair ;;
      drives) ui_msg "Drives" "$(lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,PARTLABEL)" ;;
      quit)   break ;;
    esac
  done
}

require_root
require_uefi
require_cmds lsblk blkid findmnt sfdisk wipefs dd gunzip xz tar curl mkfs.vfat mkfs.ext4 e2fsck resize2fs md5sum sha256sum

if [[ $ACTION = repair ]]; then
  refind_repair
else
  main_menu
fi
