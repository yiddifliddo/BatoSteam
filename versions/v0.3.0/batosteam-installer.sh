#!/bin/bash
# BatoSteam Installer
# Author: Dan Lee
# Version: 0.3.0
#
# Installs Batocera and SteamOS onto separate drives of one PC, then adds a
# rEFInd boot menu so you can pick which OS to start at power-on.
#
# Usage:
#   sudo ./batosteam-installer.sh                 interactive text menus
#   sudo ./batosteam-installer.sh --dry-run       walk through everything, write nothing
#   sudo ./batosteam-installer.sh --steamos-image URL|FILE   SteamOS source (.img.bz2 or .img)
#   sudo ./batosteam-installer.sh --batocera-image FILE      local batocera-x86_64 .img.gz
#   sudo ./batosteam-installer.sh --repair-boot   put the boot menu first again
#   sudo ./batosteam-installer.sh --setup-usb     on Valve's recovery USB: turn it into
#                                                 the BatoSteam USB key (desktop shortcut)

set -uo pipefail

BATOSTEAM_VERSION="0.3.0"
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
# shellcheck source=lib/usb.sh
source "$BATOSTEAM_DIR/lib/usb.sh"

STEAMOS_IMAGE=""
STEAMOS_IMAGE_SET=0
BATOCERA_IMAGE=""
ACTION=""

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         DRY_RUN=1 ;;
    --steamos-image)   STEAMOS_IMAGE="$2"; STEAMOS_IMAGE_SET=1; shift ;;
    --batocera-image)  BATOCERA_IMAGE="$2"; shift ;;
    --repair-boot)     ACTION=repair ;;
    --setup-usb)       ACTION=setupusb ;;
    --version)         echo "BatoSteam Installer $BATOSTEAM_VERSION"; exit 0 ;;
    -h|--help)         usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

UI_TITLE="BatoSteam Installer v$BATOSTEAM_VERSION$([[ $DRY_RUN = 1 ]] && echo '  [DRY RUN - nothing will be written]')"

# Choices made in the menus
BATO_DISK=""; BATO_MODE=""; BATO_FS=""; BATO_OFFLINE=""
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
    BATO_OFFLINE=""
    local off; off="$(usb_offline_batocera)"
    if [[ -z $BATOCERA_IMAGE && -n $off ]]; then
      BATO_OFFLINE="$(ui_menu "Batocera - source" "A Batocera image is stored on this USB key." \
        "$off" "Use $(basename "$off") from the USB key (offline)" \
        "" "Download the latest Batocera instead")" || return 1
    fi
  fi
}

# Choose where SteamOS comes from. Sets STEAMOS_IMAGE ("" = copy this recovery USB).
steamos_choose_source() {
  [[ $STEAMOS_IMAGE_SET = 1 ]] && return 0
  local opts=() choice f
  opts+=(download "Download the latest SteamOS from Valve (recommended, ~3.4 GB, streamed)")
  steamos_is_recovery_usb && opts+=(usb "Copy SteamOS $(steamos_running_version) from this USB key (offline, faster)")
  while IFS= read -r f; do
    opts+=("$f" "Use $(basename "$f") from the USB key")
  done < <(find "$BATOSTEAM_DIR/images" -maxdepth 1 \( -name 'steamdeck-*.img.bz2' -o -name 'steamdeck-*.img' \) 2>/dev/null | sort)
  opts+=(file "Use another image file (.img.bz2 or .img)")
  choice="$(ui_menu "SteamOS - source" "Where should SteamOS come from?\n\nUse the Steam Deck/Machine/PC image - NOT the Steam Frame image (ARM, will not run on a PC)." "${opts[@]}")" || return 1
  case "$choice" in
    download) STEAMOS_IMAGE="$STEAMOS_RECOVERY_URL" ;;
    usb)      STEAMOS_IMAGE="" ;;
    file)     STEAMOS_IMAGE="$(ui_input "SteamOS - image file" "Full path to the SteamOS recovery image (.img.bz2 or .img):" "")" || return 1
              [[ -f $STEAMOS_IMAGE ]] || { ui_msg "Not found" "File not found: $STEAMOS_IMAGE"; return 1; } ;;
    *)        STEAMOS_IMAGE="$choice" ;;
  esac
  if [[ ${STEAMOS_IMAGE,,} = *frame* ]]; then
    ui_msg "Wrong image" "That is the Steam Frame image (ARM). A PC needs the Steam Deck/Machine/PC image."
    return 1
  fi
}

steamos_needs_tools() {
  steamos_choose_source || return 1
  local missing=() c
  for c in btrfstune btrfs mkfs.ext4 mkfs.vfat chroot; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if [[ -n $STEAMOS_IMAGE && ( $STEAMOS_IMAGE = http* || $STEAMOS_IMAGE = *.bz2 ) ]]; then
    steamos_decompressor >/dev/null || missing+=("bzip2")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    ui_msg "Missing tools" "SteamOS install needs: ${missing[*]}\n\nBoot the BatoSteam / Valve SteamOS recovery USB key, which has them all."
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
      wipe)  s+="   ERASE whole drive, SHARE filesystem: $BATO_FS\n"
             s+="   Source: $([[ -n ${BATOCERA_IMAGE:-$BATO_OFFLINE} ]] && basename "${BATOCERA_IMAGE:-$BATO_OFFLINE}" || echo 'download latest')\n" ;;
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
    if [[ $STEAM_MODE != leave ]]; then
      case "$STEAMOS_IMAGE" in
        "")     s+="   Source: this USB key (SteamOS $(steamos_running_version))\n" ;;
        http*)  s+="   Source: download latest from Valve\n" ;;
        *)      s+="   Source: $(basename "$STEAMOS_IMAGE")\n" ;;
      esac
    fi
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
      [[ -n $src ]] || src="$BATO_OFFLINE"
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

# On Valve's recovery USB (written with Rufus / Balena Etcher): make it the BatoSteam key.
setup_usb() {
  steamos_is_recovery_usb || [[ $DRY_RUN = 1 ]] || die "--setup-usb must be run on Valve's SteamOS recovery USB key."
  local usbdisk bato_url="" need have
  usbdisk="/dev/$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /home | sed 's/\[.*\]//')" 2>/dev/null | head -n1)"
  if ui_yesno "Batocera offline" "Also store Batocera on this USB key for offline installs?\n\nAdds about 4.5 GB (16 GB or larger USB key needed).\nThe USB key's home partition is grown to fill the key first."; then
    bato_url="$(batocera_image_url)" || die "Could not look up the latest Batocera image (check internet)."
    need=$(( $(usb_batocera_bytes "$bato_url") + USB_MARGIN_BYTES ))
    usb_grow_home "$usbdisk" 1 || warn "Could not grow the home partition."
    have="$(df --output=avail -B1 /home | tail -n1)"
    [[ $DRY_RUN = 1 || $have -ge $need ]] || die "Not enough space on the USB key for Batocera ($(numfmt --to=si "$need") needed, $(numfmt --to=si "$have") free). Use a 16 GB or larger key, or skip offline Batocera."
  fi
  usb_install_batosteam /home "$bato_url"
  ui_msg "USB key ready" "This USB key is now the BatoSteam USB key.\n\nA 'BatoSteam Installer' shortcut is on the desktop. Valve's own shortcuts were moved into the folder:\n  $USB_VALVE_FOLDER\n\nNext time just boot this key and double-click 'BatoSteam Installer'."
}

# Warn once when running on Valve's recovery USB.
recovery_usb_warning() {
  steamos_is_recovery_usb || return 0
  ui_msg "Valve SteamOS recovery USB detected" \
"You are running on Valve's SteamOS recovery USB (SteamOS $(steamos_running_version)).\n\nDo NOT use Valve's desktop shortcuts on this PC:\n  'Wipe Device & Install SteamOS' / 'Reimage Steam Deck'\n  'Repair SteamOS' / 'Reinstall SteamOS' / 'Clear local user data'\nThey always use the FIRST NVMe drive (and 'Wipe Device' sanitizes it) - that may be your Batocera drive.\n\nUse BatoSteam instead - it lets you choose the drive."
}

main_menu() {
  recovery_usb_warning
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
elif [[ $ACTION = setupusb ]]; then
  setup_usb
else
  main_menu
fi
