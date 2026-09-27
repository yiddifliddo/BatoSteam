#!/bin/bash
# BatoSteam Installer - shared helpers
# Author: Dan Lee
# Version: 0.1.0
#
# Logging, the text-menu (TUI) wrappers, drive discovery and safety checks.
# Sourced by batosteam-installer.sh - not meant to be run directly.

BATOSTEAM_LOG="${BATOSTEAM_LOG:-/tmp/batosteam-install.log}"
DRY_RUN="${DRY_RUN:-0}"

##
## Logging
##

log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$BATOSTEAM_LOG" >&2; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; ui_msg "Installation stopped" "ERROR: $*\n\nFull log: $BATOSTEAM_LOG"; exit 1; }

# Run a command, or only print it when DRY_RUN=1. Every destructive step goes
# through here so a dry run can never touch a drive.
run() {
  log "+ $*"
  [[ $DRY_RUN = 1 ]] && return 0
  "$@" 2>&1 | tee -a "$BATOSTEAM_LOG" >&2
  return "${PIPESTATUS[0]}"
}

# Same as run, for pipelines passed as a single shell string.
run_sh() {
  log "+ $1"
  [[ $DRY_RUN = 1 ]] && return 0
  bash -o pipefail -c "$1" 2>>"$BATOSTEAM_LOG"
}

##
## Text menu (TUI) - whiptail, then dialog, then plain terminal prompts
##

if command -v whiptail >/dev/null 2>&1; then
  UI=whiptail
elif command -v dialog >/dev/null 2>&1; then
  UI=dialog
else
  UI=plain
fi
UI_TITLE="BatoSteam Installer"

ui_msg() {
  local title="$1" text="$2"
  case $UI in
    whiptail|dialog) $UI --title "$title" --backtitle "$UI_TITLE" --msgbox "$(echo -e "$text")" 20 74 ;;
    *) echo -e "\n== $title ==\n$text\n"; read -r -p "Press Enter to continue..." _ ;;
  esac
}

# Returns 0 for Yes, 1 for No.
ui_yesno() {
  local title="$1" text="$2"
  case $UI in
    whiptail|dialog) $UI --title "$title" --backtitle "$UI_TITLE" --yesno "$(echo -e "$text")" 20 74 ;;
    *)
      echo -e "\n== $title ==\n$text"
      local a; read -r -p "[y/N] " a
      [[ ${a,,} = y || ${a,,} = yes ]]
      ;;
  esac
}

# ui_menu TITLE TEXT TAG1 DESC1 TAG2 DESC2 ...  -> prints chosen TAG, returns 1 on cancel.
ui_menu() {
  local title="$1" text="$2"; shift 2
  case $UI in
    whiptail|dialog)
      $UI --title "$title" --backtitle "$UI_TITLE" --menu "$(echo -e "$text")" 22 78 12 "$@" 3>&1 1>&2 2>&3
      ;;
    *)
      echo -e "\n== $title ==\n$text" >&2
      local tags=() i=1
      while [[ $# -gt 0 ]]; do
        echo "  $i) $2" >&2
        tags+=("$1"); shift 2; i=$((i + 1))
      done
      local n; read -r -p "Choose 1-${#tags[@]} (blank = cancel): " n
      [[ $n =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#tags[@]} ]] || return 1
      echo "${tags[$((n - 1))]}"
      ;;
  esac
}

ui_input() {
  local title="$1" text="$2" default="${3:-}"
  case $UI in
    whiptail|dialog)
      $UI --title "$title" --backtitle "$UI_TITLE" --inputbox "$(echo -e "$text")" 12 74 "$default" 3>&1 1>&2 2>&3
      ;;
    *)
      echo -e "\n== $title ==\n$text" >&2
      local v; read -r -p "> " v
      echo "${v:-$default}"
      ;;
  esac
}

##
## Drives
##

# Partition device path for a disk: /dev/sda + 2 -> /dev/sda2, /dev/nvme0n1 + 2 -> /dev/nvme0n1p2
part_path() {
  local disk="$1" num="$2"
  if [[ $disk =~ [0-9]$ ]]; then echo "${disk}p${num}"; else echo "${disk}${num}"; fi
}

# The disk(s) the installer itself is running from - never offered as a target.
protected_disks() {
  local src
  for mnt in / /run/archiso/bootmnt /run/media/liveuser/rootfs /run/initramfs/live /cdrom /lib/live/mount/medium; do
    src="$(findmnt -n -o SOURCE "$mnt" 2>/dev/null | sed 's/\[.*\]//')" || continue
    [[ -b $src ]] || continue
    lsblk -no PKNAME "$src" 2>/dev/null | head -n1
  done | grep -v '^$' | sort -u
  # The drive holding this script (e.g. a second USB stick)
  src="$(df --output=source "$BATOSTEAM_DIR" 2>/dev/null | tail -n1)"
  [[ -b $src ]] && lsblk -no PKNAME "$src" 2>/dev/null | head -n1
}

# Prints one line per candidate disk: NAME<TAB>SIZE<TAB>MODEL<TAB>TRANSPORT
list_disks() {
  local protected
  protected="$(protected_disks | sort -u | tr '\n' ' ')"
  lsblk -dn -P -o NAME,SIZE,MODEL,TRAN,TYPE,RO | while read -r line; do
    local NAME SIZE MODEL TRAN TYPE RO
    eval "$line"
    [[ $TYPE = disk && $RO = 0 ]] || continue
    [[ $NAME =~ ^(loop|zram|ram|sr) ]] && continue
    [[ " $protected " = *" $NAME "* ]] && continue
    printf '%s\t%s\t%s\t%s\n' "$NAME" "$SIZE" "${MODEL:-unknown}" "${TRAN:-?}"
  done
}

disk_size_bytes() { blockdev --getsize64 "$1"; }

# Unmount everything on a disk before we write to it.
release_disk() {
  local disk="$1" p
  for p in $(lsblk -lnpo NAME "$disk" | tail -n +2); do
    if findmnt -n "$p" >/dev/null 2>&1; then run umount -l "$p" || true; fi
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$p"; then run swapoff "$p" || true; fi
  done
}

# Ask the kernel to re-read a partition table and wait for the device nodes.
reread_disk() {
  local disk="$1"
  [[ $DRY_RUN = 1 ]] && return 0
  partprobe "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || sleep 2
}

part_label()   { blkid -o value -s PARTLABEL "$1" 2>/dev/null; }
fs_label()     { blkid -o value -s LABEL "$1" 2>/dev/null; }
fs_type()      { blkid -o value -s TYPE "$1" 2>/dev/null; }
part_uuid()    { blkid -o value -s PARTUUID "$1" 2>/dev/null; }

##
## Pre-flight
##

require_root() { [[ $EUID -eq 0 ]] || { echo "Please run as root (sudo $0)"; exit 1; }; }

require_uefi() {
  [[ -d /sys/firmware/efi ]] || die "This PC was not booted in UEFI mode. BatoSteam needs UEFI (legacy BIOS is not supported). Enable UEFI in your firmware settings and boot the USB again."
}

require_cmds() {
  local missing=() c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"
}
