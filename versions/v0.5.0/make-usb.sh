#!/bin/bash
# BatoSteam - make the all-in-one USB key (run on a Linux PC)
# Author: Dan Lee
# Version: 0.5.0
#
# Creates ONE bootable USB key with Valve's official SteamOS recovery system,
# the BatoSteam installer (desktop shortcut) and, optionally, Batocera for offline use.
#
# Usage:
#   sudo ./make-usb.sh                          interactive
#   sudo ./make-usb.sh --device /dev/sdX        choose the USB key up front
#   sudo ./make-usb.sh --with-batocera          include Batocera offline (no question)
#   sudo ./make-usb.sh --no-batocera            do not include Batocera (no question)
#   sudo ./make-usb.sh --steamos-image FILE|URL use a local .img.bz2 / other URL
#   sudo ./make-usb.sh --dry-run                show every step, write nothing
#
# On Windows / macOS: write Valve's image with Rufus / Balena Etcher, boot it, open
# "Terminal with repair tools" and run batosteam-installer.sh --setup-usb (see README).

set -uo pipefail

BATOSTEAM_VERSION="0.5.0"
BATOSTEAM_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BATOSTEAM_LOG="${BATOSTEAM_LOG:-/tmp/batosteam-make-usb.log}"

# shellcheck source=lib/common.sh
source "$BATOSTEAM_DIR/lib/common.sh"
# shellcheck source=lib/batocera.sh
source "$BATOSTEAM_DIR/lib/batocera.sh"
# shellcheck source=lib/steamos.sh
source "$BATOSTEAM_DIR/lib/steamos.sh"
# shellcheck source=lib/usb.sh
source "$BATOSTEAM_DIR/lib/usb.sh"

USB_DEV=""; WITH_BATO=""; STEAMOS_SRC_URL="$STEAMOS_RECOVERY_URL"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)        USB_DEV="$2"; shift ;;
    --with-batocera) WITH_BATO=1 ;;
    --no-batocera)   WITH_BATO=0 ;;
    --steamos-image) STEAMOS_SRC_URL="$2"; shift ;;
    --dry-run)       DRY_RUN=1 ;;
    --version)       echo "BatoSteam make-usb $BATOSTEAM_VERSION"; exit 0 ;;
    -h|--help)       usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

UI_TITLE="BatoSteam USB maker v$BATOSTEAM_VERSION$([[ $DRY_RUN = 1 ]] && echo '  [DRY RUN - nothing will be written]')"

require_root
require_cmds lsblk blkid findmnt sfdisk wipefs dd curl e2fsck resize2fs mount gzip numfmt
steamos_decompressor >/dev/null || die "Install lbzip2 or bzip2 first."
steamos_reject_frame "$STEAMOS_SRC_URL"
: > "$BATOSTEAM_LOG"

# 1. USB key
if [[ -z $USB_DEV ]]; then
  args=()
  while IFS=$'\t' read -r name size model _bytes; do
    args+=("/dev/$name" "$size  $model")
  done < <(usb_list_candidates)
  [[ ${#args[@]} -gt 0 ]] || die "No USB keys found. Plug in a USB key (16 GB or larger)."
  USB_DEV="$(ui_menu "Choose USB key" "This USB key will be COMPLETELY ERASED." "${args[@]}")" || exit 1
fi
[[ -b $USB_DEV || $DRY_RUN = 1 ]] || die "$USB_DEV is not a block device"
[[ " $(protected_disks | tr '\n' ' ') " = *" $(basename "$USB_DEV") "* ]] && die "$USB_DEV holds the running system - refusing."

# 2. Offline Batocera?
if [[ -z $WITH_BATO ]]; then
  if ui_yesno "Batocera offline" "Also put Batocera on the USB key for offline installs?\n\nAdds about 4.5 GB - a 16 GB USB key is enough for both.\nIf you choose No, Batocera is downloaded during the install."; then
    WITH_BATO=1
  else
    WITH_BATO=0
  fi
fi

# 3. Size check
log "Checking image sizes..."
steam_bytes="$(usb_steamos_image_bytes "$STEAMOS_SRC_URL")" || { [[ $DRY_RUN = 1 ]] && steam_bytes=8120172544; } \
  || die "Could not read the SteamOS image from $STEAMOS_SRC_URL"
bato_url=""; bato_bytes=0
if [[ $WITH_BATO = 1 ]]; then
  bato_url="$(batocera_image_url)" || die "Could not look up the latest Batocera image."
  bato_bytes="$(usb_batocera_bytes "$bato_url")"
fi
need=$(( steam_bytes + bato_bytes + USB_MARGIN_BYTES ))
have="$(disk_size_bytes "$USB_DEV" 2>/dev/null || echo 0)"
[[ $DRY_RUN = 1 && $have = 0 ]] && have=$need
log "USB needs $(numfmt --to=si "$need"), $USB_DEV has $(numfmt --to=si "$have")"
[[ $have -ge $need ]] || die "$USB_DEV is too small: needs $(numfmt --to=si "$need"), has $(numfmt --to=si "$have"). Use a 16 GB or larger USB key$([[ $WITH_BATO = 1 ]] && echo ', or skip Batocera offline')."

# 4. Confirm
ui_yesno "Confirm" "USB key: $USB_DEV ($(numfmt --to=si "$have"))\n\nWill contain:\n  * Valve SteamOS recovery (Deck/Machine/PC image)\n  * BatoSteam Installer $BATOSTEAM_VERSION\n$([[ $WITH_BATO = 1 ]] && echo "  * Batocera offline: $(basename "$bato_url")")\n\nEVERYTHING on $USB_DEV will be erased. Continue?" || exit 1
typed="$(ui_input "Final confirmation" "Type ERASE to erase $USB_DEV:" "")" || exit 1
[[ $typed = ERASE ]] || { ui_msg "Cancelled" "Nothing was changed."; exit 1; }

# 5. Write Valve's image, grow home, add BatoSteam
log "== Writing SteamOS recovery image to $USB_DEV"
usb_write_steamos "$USB_DEV" "$STEAMOS_SRC_URL"
usb_grow_home "$USB_DEV" 0 || warn "Could not grow the home partition - Batocera offline may not fit."

homepart="$(part_path "$USB_DEV" "$(sfdisk -d "$USB_DEV" 2>/dev/null | grep 'name="home"' | sed -E 's/^[^ ]*[^0-9]([0-9]+) :.*/\1/')")"
[[ $DRY_RUN = 1 ]] && homepart="$(part_path "$USB_DEV" 5)"
mnt="$(mktemp -d /tmp/batosteam-usbhome.XXXX)"
run mount "$homepart" "$mnt" || die "Could not mount $homepart (your kernel needs ext4 casefold support - most distributions from 2020 on have it)."
usb_install_batosteam "$mnt" "$bato_url"
run sync
run umount "$mnt"
rmdir "$mnt"

ui_msg "USB key ready" "The BatoSteam USB key is ready.\n\n1. Plug it into the PC, turn Secure Boot OFF, boot from USB (UEFI).\n2. On the SteamOS desktop double-click 'BatoSteam Installer'.\n\nDo NOT use the Valve shortcuts in the folder '$USB_VALVE_FOLDER' on a multi-drive PC.\n\nLog: $BATOSTEAM_LOG"
