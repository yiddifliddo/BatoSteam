#!/bin/bash
# BatoSteam Installer - rEFInd boot menu stage
# Author: Dan Lee
# Version: 0.3.0
#
# Puts rEFInd on its own small EFI partition (BSBOOT, created on the Batocera
# drive in wipe mode) so neither Batocera's nor SteamOS's own updates remove it.
# Batocera's upgrader marks unknown files on its BATOCERA partition as stale and
# deletes them, which is why rEFInd is NOT stored there.
# Fallback when there is no BSBOOT: SteamOS's "esp" partition.

REFIND_VERSION="${REFIND_VERSION:-0.14.2}"
REFIND_URL="${REFIND_URL:-https://sourceforge.net/projects/refind/files/${REFIND_VERSION}/refind-bin-${REFIND_VERSION}.zip/download}"
REFIND_SHA256="${REFIND_SHA256:-410c7828c4fec2f2179bd956073522415831d27c00416381b8f71153c190a311}"
REFIND_TIMEOUT="${REFIND_TIMEOUT:-10}"
BOOT_ENTRY_LABEL="BatoSteam"

# Find the partition rEFInd should live on. Prints the partition device.
#   $1 batocera disk ("" if none)   $2 steamos disk ("" if none)
refind_target_partition() {
  local bato="$1" steam="$2" p
  if [[ -n $bato ]]; then
    p="$(part_path "$bato" 3)"
    # In a dry run BSBOOT does not exist yet - it will if Batocera is being wiped.
    if [[ $(fs_label "$p") = "$BSBOOT_LABEL" || ( $DRY_RUN = 1 && ${BATO_MODE:-} = wipe ) ]]; then echo "$p"; return 0; fi
  fi
  if [[ -n $steam ]]; then
    p="$(part_path "$steam" "$S_ESP")"
    if [[ $DRY_RUN = 1 || $(part_label "$p") = esp ]]; then echo "$p"; return 0; fi
  fi
  # Dry run with no drive being wiped: fall back to the Batocera drive's p3 for display.
  if [[ $DRY_RUN = 1 && -n $bato ]]; then part_path "$bato" 3; return 0
  fi
  return 1
}

# Download and verify rEFInd. Prints the unpacked refind/ directory.
refind_fetch() {
  local work="$1" zip="$1/refind.zip"
  run curl -fL --retry 3 -o "$zip" "$REFIND_URL" || die "Download of rEFInd failed"
  if [[ $DRY_RUN != 1 ]]; then
    [[ "$(sha256sum "$zip" | cut -d' ' -f1)" = "$REFIND_SHA256" ]] || die "rEFInd download checksum mismatch"
    if command -v unzip >/dev/null 2>&1; then
      unzip -q "$zip" -d "$work" || die "Unpacking rEFInd failed"
    elif command -v bsdtar >/dev/null 2>&1; then
      bsdtar -xf "$zip" -C "$work" || die "Unpacking rEFInd failed"
    else
      python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$zip" "$work" \
        || die "Unpacking rEFInd failed (need unzip, bsdtar or python3)"
    fi
  fi
  echo "$work/refind-bin-${REFIND_VERSION}/refind"
}

# Install rEFInd and make it the first UEFI boot entry.
#   $1 batocera disk ("" if not installed)   $2 steamos disk ("" if not installed)
#   $3 default OS: Batocera | SteamOS
refind_install() {
  local bato="$1" steam="$2" default="${3:-Batocera}"
  local target disk partnum work src mnt
  target="$(refind_target_partition "$bato" "$steam")" || die "No EFI partition found for the boot menu."
  disk="/dev/$(lsblk -no PKNAME "$target" 2>/dev/null | head -n1)"
  partnum="$(cat "/sys/class/block/$(basename "$target")/partition" 2>/dev/null)"
  [[ $DRY_RUN = 1 ]] && { disk="${disk%/}"; [[ $disk = /dev/ ]] && disk="${bato:-$steam}"; partnum="${partnum:-3}"; }
  log "== Boot menu: installing rEFInd $REFIND_VERSION to $target"

  work="$(mktemp -d /tmp/batosteam-refind.XXXX)"
  src="$(refind_fetch "$work")"
  [[ -f $src/refind_x64.efi || $DRY_RUN = 1 ]] || die "rEFInd download or unpack failed - see $BATOSTEAM_LOG"
  mnt="$work/esp"; mkdir -p "$mnt"
  run mount "$target" "$mnt" || die "Could not mount $target"

  run mkdir -p "$mnt/EFI/refind/icons"
  run cp "$src/refind_x64.efi" "$mnt/EFI/refind/"
  run cp -r "$src/icons/." "$mnt/EFI/refind/icons/"
  run cp -r "$src/drivers_x64" "$mnt/EFI/refind/"
  # Optional custom icons shipped with BatoSteam (config/icons/*.png)
  if compgen -G "$BATOSTEAM_DIR/config/icons/*.png" >/dev/null; then
    run cp "$BATOSTEAM_DIR"/config/icons/*.png "$mnt/EFI/refind/icons/"
  fi

  # Fallback loader path, so the menu still appears if the firmware forgets NVRAM entries.
  # Only on BSBOOT - never overwrite SteamOS's own esp fallback loader.
  if [[ $(fs_label "$target") = "$BSBOOT_LABEL" || ( $DRY_RUN = 1 && $target != *"$(basename "${steam:-none}")"* ) ]]; then
    run mkdir -p "$mnt/EFI/BOOT"
    run cp "$src/refind_x64.efi" "$mnt/EFI/BOOT/BOOTX64.EFI"
    run cp -r "$src/icons" "$src/drivers_x64" "$mnt/EFI/BOOT/"
  fi

  refind_write_conf "$mnt/EFI/refind/refind.conf" "$bato" "$steam" "$default"
  [[ -d $mnt/EFI/BOOT ]] && run cp "$mnt/EFI/refind/refind.conf" "$mnt/EFI/BOOT/refind.conf"

  run sync
  run umount "$mnt"
  rm -rf "$work"

  refind_set_bootorder "$disk" "$partnum"
  log "== Boot menu: done"
}

refind_write_conf() {
  local out="$1" bato="$2" steam="$3" default="$4"
  local bato_uuid="" steam_uuid="" bato_dis="" steam_dis="" bato_icon=os_linux.png steam_icon=os_arch.png
  [[ -n $bato ]]  && bato_uuid="$(part_uuid "$(part_path "$bato" 1)")"
  [[ -n $steam ]] && steam_uuid="$(part_uuid "$(part_path "$steam" "$S_ESP")")"
  [[ -z $bato_uuid ]]  && { bato_dis="disabled";  bato_uuid=none; }
  [[ -z $steam_uuid ]] && { steam_dis="disabled"; steam_uuid=none; }
  [[ -f $BATOSTEAM_DIR/config/icons/os_batocera.png ]] && bato_icon=os_batocera.png
  [[ -f $BATOSTEAM_DIR/config/icons/os_steamos.png ]]  && steam_icon=os_steamos.png

  log "Writing $out (Batocera=$bato_uuid SteamOS=$steam_uuid default=$default)"
  [[ $DRY_RUN = 1 ]] && return 0
  sed -e "s|@TIMEOUT@|$REFIND_TIMEOUT|" \
      -e "s|@DEFAULT@|$default|" \
      -e "s|@BATO_PARTUUID@|$bato_uuid|"   -e "s|@BATO_DISABLED@|$bato_dis|" \
      -e "s|@STEAM_PARTUUID@|$steam_uuid|" -e "s|@STEAM_DISABLED@|$steam_dis|" \
      -e "s|@BATO_ICON@|$bato_icon|"       -e "s|@STEAM_ICON@|$steam_icon|" \
      "$BATOSTEAM_DIR/config/refind.conf" > "$out"
}

# Create/refresh the "BatoSteam" UEFI entry and put it first in BootOrder.
refind_set_bootorder() {
  local disk="$1" partnum="$2" num order
  command -v efibootmgr >/dev/null 2>&1 || { warn "efibootmgr not found - set '$BOOT_ENTRY_LABEL' as first boot device in your firmware manually."; return 0; }

  # Remove old BatoSteam entries so they don't pile up on reinstall
  for num in $(efibootmgr | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)\*\? $BOOT_ENTRY_LABEL.*/\1/p"); do
    run efibootmgr -q -b "$num" -B
  done
  run efibootmgr -q -c -d "$disk" -p "$partnum" -L "$BOOT_ENTRY_LABEL" -l '\EFI\refind\refind_x64.efi' \
    || { warn "Could not create UEFI boot entry - the fallback loader on BSBOOT will be used."; return 0; }
  [[ $DRY_RUN = 1 ]] && return 0

  num="$(efibootmgr | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)\*\? $BOOT_ENTRY_LABEL.*/\1/p" | head -n1)"
  order="$(efibootmgr | sed -n 's/^BootOrder: //p' | tr ',' '\n' | grep -vix "$num" | paste -sd,)"
  run efibootmgr -q -o "${num}${order:+,$order}"
}

# Menu option: put BatoSteam back to the front of the boot order
# (SteamOS updates can move their own entry to the front).
refind_repair() {
  local d p
  for d in $(lsblk -dnpo NAME); do
    p="$(part_path "$d" 3)"
    if [[ $(fs_label "$p") = "$BSBOOT_LABEL" ]]; then
      refind_set_bootorder "$d" 3
      ui_msg "Boot menu repaired" "BatoSteam boot menu on $p is first in the boot order again."
      return 0
    fi
    p="$(part_path "$d" 1)"
    if [[ $(part_label "$p") = esp && -n $(mount_has_refind "$p") ]]; then
      refind_set_bootorder "$d" 1
      ui_msg "Boot menu repaired" "BatoSteam boot menu on $p is first in the boot order again."
      return 0
    fi
  done
  ui_msg "Nothing found" "No BatoSteam boot menu partition was found on any drive."
}

# Prints "yes" if the partition contains EFI/refind/refind_x64.efi
mount_has_refind() {
  local p="$1" mnt
  mnt="$(mktemp -d /tmp/batosteam-chk.XXXX)"
  if mount -o ro "$p" "$mnt" 2>/dev/null; then
    [[ -f $mnt/EFI/refind/refind_x64.efi ]] && echo yes
    umount "$mnt"
  fi
  rmdir "$mnt"
}
