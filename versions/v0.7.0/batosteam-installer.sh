#!/bin/bash
# BatoSteam Installer
# Author: Dan Lee
# Version: 0.7.0
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

BATOSTEAM_VERSION="0.7.0"
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
# shellcheck source=lib/network.sh
source "$BATOSTEAM_DIR/lib/network.sh"

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

# Drive tag shown in every drive list
drive_tag() {
  local d="$1" info="${DETECT_INFO[$1]:-empty}"
  if [[ ${DETECT_PROTECTED[$d]:-0} = 1 ]]; then
    [[ ${UNLOCKED[$d]:-0} = 1 ]] && echo "  <UNLOCKED - $info>" || echo "  [PROTECTED - $info]"
  else
    echo "  <empty>"
  fi
}

# Unlock a protected drive on purpose: the user must type WORD + drive name.
#   $1 disk  $2 WORD (OVERWRITE | REPAIR)  $3 explanation
unlock_drive() {
  local disk="$1" word="$2" why="$3" typed want
  want="$word $(basename "$disk")"
  typed="$(ui_input "Unlock $disk" "$disk is PROTECTED:\n  ${DETECT_INFO[$disk]}\n\n$why\n\nTo continue, type exactly:\n  $want" "")" || return 1
  if [[ $typed != "$want" ]]; then
    ui_msg "Still protected" "Text did not match - $disk stays protected. Nothing was changed."
    return 1
  fi
  UNLOCKED[$disk]=1
  log "User unlocked $disk ($word) - ${DETECT_INFO[$disk]}"
}

# pick_disk TITLE EXCLUDE_DISK TARGET_OS MODE -> prints /dev/NAME
#   MODE empty  : only EMPTY drives are offered (protected drives are not listed)
#   MODE fresh  : all drives are listed; protected ones must be unlocked to be used
pick_disk() {
  local title="$1" exclude="${2:-}" target="${3:-}" mode="${4:-empty}"
  local args name size model tran disk hidden choice
  while true; do
    args=(); hidden=0
    while IFS=$'\t' read -r name size model tran; do
      [[ /dev/$name = "$exclude" ]] && continue
      if [[ $mode = empty && ${DETECT_PROTECTED[/dev/$name]:-0} = 1 ]]; then hidden=$((hidden + 1)); continue; fi
      args+=("/dev/$name" "$size  $model  [$tran]$(drive_tag "/dev/$name")")
    done < <(list_disks)
    if [[ ${#args[@]} -eq 0 ]]; then
      ui_msg "$title" "No EMPTY drive is available for $target.\n\n$hidden drive(s) are PROTECTED because they hold an OS or data.\nAdd an empty drive, or use 'Fresh install' to unlock a drive on purpose.\n\nThe drive BatoSteam runs from is always hidden."
      return 1
    fi
    local text="Choose the drive for $target."
    [[ $hidden -gt 0 ]] && text+="\n$hidden protected drive(s) are hidden."
    disk="$(ui_menu "$title" "$text" "${args[@]}")" || return 1
    if [[ ${DETECT_PROTECTED[$disk]:-0} = 1 && ${UNLOCKED[$disk]:-0} != 1 ]]; then
      choice="$(ui_menu "$disk is PROTECTED" "$disk holds:\n  ${DETECT_INFO[$disk]}\n\nBatoSteam will not overwrite it unless you unlock it on purpose." \
        back   "Choose another drive (recommended)" \
        unlock "Unlock and ERASE this drive for $target")" || return 1
      [[ $choice = back ]] && continue
      unlock_drive "$disk" OVERWRITE "Installing $target here will ERASE everything on it." || continue
    fi
    echo "$disk"; return 0
  done
}

batocera_choose_options() {
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
}

# New Batocera install. $1 = empty | fresh (see pick_disk)
setup_batocera_new() {
  BATO_DISK="$(pick_disk "Batocera - choose drive" "$STEAM_DISK" Batocera "$1")" || return 1
  BATO_MODE=wipe
  batocera_choose_options
}

# New SteamOS install. $1 = empty | fresh
setup_steamos_new() {
  STEAM_DISK="$(pick_disk "SteamOS - choose drive (recommended: NVMe M.2, 2 TB+)" "$BATO_DISK" SteamOS "$1")" || return 1
  STEAM_MODE=wipe
  steamos_needs_tools || return 1
  steamos_hardware_check "$STEAM_DISK" || return 1
}

# Pick one complete install of OS $1 (prints the disk, "" if none).
choose_existing() {
  local os="$1" found=() d
  for d in $(printf '%s\n' "${!DETECT_OS[@]}" | sort); do
    [[ ${DETECT_OS[$d]} = "$os" && ${DETECT_VALID[$d]} = 1 ]] && found+=("$d" "${DETECT_INFO[$d]}")
  done
  if [[ ${#found[@]} -eq 0 ]]; then echo ""; return 0; fi
  if [[ ${#found[@]} -eq 2 ]]; then echo "${found[0]}"; return 0; fi
  ui_menu "Existing $os" "More than one $os install was found. Which one should be in the boot menu?" "${found[@]}"
}

incomplete_note() {
  local os="$1" d s=""
  for d in "${!DETECT_OS[@]}"; do
    [[ ${DETECT_OS[$d]} = "$os" && ${DETECT_VALID[$d]} != 1 ]] && s+="\n  $d: ${DETECT_INFO[$d]} (kept PROTECTED - use 'Repair an installed OS')"
  done
  echo "$s"
}

# "Use my existing installation(s)": keep everything found, add only what is missing.
flow_existing() {
  BATO_DISK="$(choose_existing Batocera)" || return 1
  [[ -n $BATO_DISK ]] && BATO_MODE=leave
  STEAM_DISK="$(choose_existing SteamOS)" || return 1
  [[ -n $STEAM_DISK ]] && STEAM_MODE=leave

  ui_msg "Using your existing installation(s)" \
"Found and KEPT (never written to):\n  Batocera: ${BATO_DISK:-not found}$([[ -n $BATO_DISK ]] && echo " - ${DETECT_INFO[$BATO_DISK]}")\n  SteamOS : ${STEAM_DISK:-not found}$([[ -n $STEAM_DISK ]] && echo " - ${DETECT_INFO[$STEAM_DISK]}")$(incomplete_note Batocera)$(incomplete_note SteamOS)\n\nAll drives with an OS or data stay PROTECTED.\nA missing OS can be installed onto an EMPTY drive only."

  if [[ -z $BATO_DISK ]] && ui_yesno "Batocera not found" "No complete Batocera install was found.\n\nInstall Batocera onto an EMPTY drive?"; then
    setup_batocera_new empty || return 1
  fi
  if [[ -z $STEAM_DISK ]] && ui_yesno "SteamOS not found" "No complete SteamOS install was found.\n\nInstall SteamOS onto an EMPTY drive?"; then
    setup_steamos_new empty || return 1
  fi
  [[ -n $BATO_DISK || -n $STEAM_DISK ]] || { ui_msg "Nothing to do" "No OS found and none selected to install."; return 1; }
}

# "Fresh install": install onto empty drives; protected drives must be unlocked on purpose.
flow_fresh() {
  local what
  what="$(ui_menu "Fresh install" "What should be installed?\n\nDrives that hold an OS or data are PROTECTED. To use one you must unlock it and type its name." \
    both     "Batocera + SteamOS (one drive each)" \
    batocera "Batocera only" \
    steamos  "SteamOS only (experimental)")" || return 1
  case $what in
    both)     setup_batocera_new fresh || return 1; setup_steamos_new fresh || return 1 ;;
    batocera) setup_batocera_new fresh || return 1 ;;
    steamos)  setup_steamos_new fresh || return 1 ;;
  esac
  # Keep the other OS in the boot menu if one is already installed elsewhere
  [[ -z $BATO_DISK ]]  && { BATO_DISK="$(choose_existing Batocera)" || return 1; [[ -n $BATO_DISK ]] && BATO_MODE=leave; }
  [[ -z $STEAM_DISK ]] && { STEAM_DISK="$(choose_existing SteamOS)" || return 1; [[ -n $STEAM_DISK ]] && STEAM_MODE=leave; }
  return 0
}

# "Repair an installed OS": reinstall the system but keep games/saves. Needs REPAIR <drive>.
flow_repair() {
  local args=() d os
  for d in $(printf '%s\n' "${!DETECT_OS[@]}" | sort); do
    [[ ${DETECT_OS[$d]} = Batocera || ${DETECT_OS[$d]} = SteamOS ]] && args+=("$d" "${DETECT_INFO[$d]}")
  done
  [[ ${#args[@]} -gt 0 ]] || { ui_msg "Nothing to repair" "No Batocera or SteamOS install was found."; return 1; }
  d="$(ui_menu "Repair an installed OS" "Reinstalls the OS system files.\nKept: Batocera SHARE (ROMs, saves, BIOS, settings) / SteamOS home (games, Steam login).\nReplaced: the OS itself." "${args[@]}")" || return 1
  os="${DETECT_OS[$d]}"
  unlock_drive "$d" REPAIR "The $os SYSTEM files on this drive will be replaced. Your games and saves are kept." || return 1
  if [[ $os = Batocera ]]; then
    BATO_DISK="$d"; BATO_MODE=keep
    STEAM_DISK="$(choose_existing SteamOS)" || return 1; [[ -n $STEAM_DISK ]] && STEAM_MODE=leave
  else
    STEAM_DISK="$d"; STEAM_MODE=keep
    steamos_needs_tools || return 1
    BATO_DISK="$(choose_existing Batocera)" || return 1; [[ -n $BATO_DISK ]] && BATO_MODE=leave
  fi
  return 0
}

summary_text() {
  local s="${1:-The following will happen:}\n\n" d
  if [[ -n $BATO_DISK ]]; then
    s+="BATOCERA -> $BATO_DISK\n"
    case $BATO_MODE in
      wipe)  s+="   ERASE whole drive, SHARE filesystem: $BATO_FS\n"
             s+="   Source: $([[ -n ${BATOCERA_IMAGE:-$BATO_OFFLINE} ]] && basename "${BATOCERA_IMAGE:-$BATO_OFFLINE}" || echo 'download latest')\n" ;;
      keep)  s+="   REPAIR system files, KEEP ROMs/saves/settings\n" ;;
      leave) s+="   KEEP AS IS - not written to (${DETECT_INFO[$BATO_DISK]:-existing install})\n" ;;
    esac
  fi
  if [[ -n $STEAM_DISK ]]; then
    s+="STEAMOS  -> $STEAM_DISK$([[ $STEAM_MODE != leave ]] && echo "  (experimental)")\n"
    case $STEAM_MODE in
      wipe)  s+="   ERASE whole drive\n" ;;
      keep)  s+="   REPAIR system files, KEEP games/home\n" ;;
      leave) s+="   KEEP AS IS - not written to (${DETECT_INFO[$STEAM_DISK]:-existing install})\n" ;;
    esac
    if [[ $STEAM_MODE != leave ]]; then
      case "$STEAMOS_IMAGE" in
        "")     s+="   Source: this USB key (SteamOS $(steamos_running_version))\n" ;;
        http*)  s+="   Source: download latest from Valve\n" ;;
        *)      s+="   Source: $(basename "$STEAMOS_IMAGE")\n" ;;
      esac
    fi
  fi
  for d in $(printf '%s\n' "${!DETECT_PROTECTED[@]}" | sort); do
    [[ ${DETECT_PROTECTED[$d]} = 1 && $d != "$BATO_DISK" && $d != "$STEAM_DISK" ]] && \
      s+="PROTECTED -> $d  not touched (${DETECT_INFO[$d]})\n"
  done
  s+="BOOT MENU -> rEFInd, default: $DEFAULT_OS, 10s timeout\n"
  s+="   (adds a new EFI/refind folder to an EFI partition - nothing existing is replaced)\n"
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
  local flow="$1"
  BATO_DISK=""; STEAM_DISK=""; BATO_MODE=""; STEAM_MODE=""; UNLOCKED=()
  detect_scan 2>/dev/null
  case "$flow" in
    existing) flow_existing || return ;;
    fresh)    flow_fresh    || return ;;
    repair)   flow_repair   || return ;;
  esac
  if [[ ( -z $BATO_DISK || $BATO_MODE = leave ) && ( -z $STEAM_DISK || $STEAM_MODE = leave ) ]]; then
    ui_yesno "Nothing to install" "Nothing will be installed - every OS is kept as it is.\n\nOnly (re)install the boot menu?" || return
  fi
  if [[ -n $BATO_DISK && -n $STEAM_DISK ]]; then
    DEFAULT_OS="$(ui_menu "Boot menu" "Which OS should start if nobody presses a key?" \
      Batocera "Batocera" SteamOS "SteamOS")" || return
  else
    DEFAULT_OS="$([[ -n $BATO_DISK ]] && echo Batocera || echo SteamOS)"
  fi
  # Check the internet BEFORE confirming, so nothing is written if a download can't work
  net_preflight || { ui_msg "Cancelled" "Nothing was changed."; return; }
  confirm_install || return

  : > "$BATOSTEAM_LOG"
  log "BatoSteam Installer $BATOSTEAM_VERSION starting (flow: $flow, dry run: $DRY_RUN)"

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

  # The boot menu lists the OS on every chosen drive (installed, repaired or kept).
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
    detect_scan 2>/dev/null
    choice="$(ui_menu "Main menu" \
"Detected on this PC:\n$(detect_report)\nDrives with an OS or data are PROTECTED - BatoSteam will not overwrite them.\nUEFI only, Secure Boot OFF. SteamOS: NVMe M.2 2 TB+ and AMD Radeon recommended." \
      existing "Use my existing installation(s) - keep them, add only what is missing" \
      fresh    "Fresh install - onto empty drives" \
      repair   "Repair an installed OS - keep games and saves" \
      bootmenu "Repair boot menu (put BatoSteam first again)" \
      network  "Network - status / connect to Wi-Fi" \
      detect   "Show detected installations" \
      drives   "Show drives" \
      quit     "Exit")" || break
    case "$choice" in
      existing|fresh|repair) do_install "$choice" ;;
      bootmenu) refind_repair ;;
      network)  net_menu ;;
      detect)   ui_msg "Detected installations" "$(detect_report)" ;;
      drives)   ui_msg "Drives" "$(lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,PARTLABEL)" ;;
      quit)     break ;;
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
