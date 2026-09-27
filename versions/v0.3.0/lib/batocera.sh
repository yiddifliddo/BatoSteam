#!/bin/bash
# BatoSteam Installer - Batocera stage
# Author: Dan Lee
# Version: 0.3.0
#
# Batocera x86_64 image layout (from batocera.linux board/batocera/x86/genimage.cfg):
#   p1  BATOCERA  FAT32 (EFI System) ~10 GiB  kernel, squashfs, GRUB/syslinux EFI
#   p2  SHARE     ext4  512 MiB in the image  userdata (ROMs, saves, BIOS)
# BatoSteam adds:
#   p3  BSBOOT    FAT32 (EFI System) 64 MiB   rEFInd boot menu (wipe mode only)

BATOCERA_UPDATE_URL="${BATOCERA_UPDATE_URL:-https://updates.batocera.org}"
BATOCERA_ARCH="${BATOCERA_ARCH:-x86_64}"
BSBOOT_SIZE_MIB=64
BSBOOT_LABEL=BSBOOT

# Full URL of the latest stable image for this arch, read from installs.txt
batocera_image_url() {
  local path
  path="$(curl -fsSL "$BATOCERA_UPDATE_URL/installs.txt" | grep -m1 "^${BATOCERA_ARCH}/stable/")" \
    || return 1
  echo "$BATOCERA_UPDATE_URL/$path"
}

# True if the disk already holds a Batocera layout we can upgrade in place.
batocera_detect() {
  local disk="$1"
  [[ $(fs_label "$(part_path "$disk" 1)") = BATOCERA ]] && [[ $(fs_label "$(part_path "$disk" 2)") = SHARE ]]
}

# Wipe the whole drive and write a fresh Batocera.
#   $1 disk (/dev/sdX)
#   $2 SHARE filesystem: ext4 | btrfs | exfat
#   $3 image source: URL or local .img.gz / .img path
batocera_install_wipe() {
  local disk="$1" sharefs="$2" src="$3"
  local p1 p2 p3
  p1="$(part_path "$disk" 1)"; p2="$(part_path "$disk" 2)"; p3="$(part_path "$disk" 3)"

  log "== Batocera: wiping $disk and writing image"
  release_disk "$disk"
  run wipefs -a "$disk"

  case "$src" in
    http*://*) run_sh "curl -fL --retry 3 '$src' | gunzip -c | dd of='$disk' bs=4M conv=fsync iflag=fullblock status=progress" ;;
    *.gz)      run_sh "gunzip -c '$src' | dd of='$disk' bs=4M conv=fsync iflag=fullblock status=progress" ;;
    *)         run dd if="$src" of="$disk" bs=4M conv=fsync status=progress ;;
  esac \
    || die "Writing the Batocera image to $disk failed (download or checksum error)."
  reread_disk "$disk"

  # The image's backup GPT sits ~10.5 GiB in; move it to the real end of the drive.
  run sfdisk --relocate gpt-bak-std "$disk" || die "Could not fix up the GPT on $disk"
  reread_disk "$disk"

  # Grow SHARE to fill the drive, leaving room for the BSBOOT boot-menu partition.
  local total start size esp=$((BSBOOT_SIZE_MIB * 2048))
  total="$(blockdev --getsz "$disk")"                       # 512-byte sectors
  start="$(sfdisk -d "$disk" 2>/dev/null | grep "^$p2 " | grep -o 'start= *[0-9]*' | grep -o '[0-9]*$')"
  [[ $DRY_RUN = 1 && -z $start ]] && start=21000192
  [[ -n $start ]] || die "Could not read the SHARE partition start on $disk"
  size=$(( (total - 4096 - esp - start) / 2048 * 2048 ))    # 1 MiB aligned, GPT tail kept free
  [[ $size -gt 0 ]] || die "$disk is too small for Batocera"

  run_sh "echo ',${size}' | sfdisk --no-reread -N 2 '$disk'" || die "Could not resize SHARE on $disk"
  run_sh "echo 'start=$((start + size)), size=${esp}, type=U, name=\"batosteam-boot\"' | sfdisk --no-reread --append '$disk'" \
    || die "Could not create the BSBOOT partition on $disk"
  reread_disk "$disk"

  case "$sharefs" in
    ext4)
      # Keep the image's default userdata and just grow it.
      run e2fsck -fy "$p2" || true
      run resize2fs "$p2" || die "Could not grow SHARE on $p2"
      ;;
    btrfs) run mkfs.btrfs -f -L SHARE "$p2" || die "mkfs.btrfs failed on $p2" ;;
    exfat) run mkfs.exfat -n SHARE "$p2"    || die "mkfs.exfat failed on $p2" ;;
    *) die "Unknown SHARE filesystem: $sharefs" ;;
  esac

  run mkfs.vfat -F 32 -n "$BSBOOT_LABEL" "$p3" || die "mkfs.vfat failed on $p3"

  # SHARE already fills the drive, so turn off Batocera's first-boot auto-resize.
  batocera_set_bootconf "$p1" autoresize false
  log "== Batocera: done on $disk (SHARE = $sharefs)"
}

# Reinstall Batocera system files but keep SHARE (ROMs, saves, settings).
# Same method as batocera-upgrade: unpack boot.tar.xz over the BATOCERA partition.
#   $1 disk
batocera_install_keep() {
  local disk="$1" p1 work mnt
  p1="$(part_path "$disk" 1)"
  batocera_detect "$disk" || [[ $DRY_RUN = 1 ]] || die "$disk does not contain a Batocera install (BATOCERA + SHARE) - choose 'wipe' instead."

  log "== Batocera: reinstalling system on $disk, keeping SHARE"
  release_disk "$disk"
  work="$(mktemp -d /tmp/batosteam-bato.XXXX)"
  mnt="$work/boot"
  mkdir -p "$mnt"

  local base="$BATOCERA_UPDATE_URL/$BATOCERA_ARCH/stable/last"
  run curl -fL --retry 3 -o "$work/boot.tar.xz" "$base/boot.tar.xz" || die "Download of boot.tar.xz failed"
  if run curl -fsL -o "$work/boot.tar.xz.md5" "$base/boot.tar.xz.md5" && [[ $DRY_RUN != 1 ]]; then
    [[ "$(md5sum "$work/boot.tar.xz" | cut -d' ' -f1)" = "$(cut -d' ' -f1 < "$work/boot.tar.xz.md5")" ]] \
      || die "boot.tar.xz checksum mismatch - download corrupted, try again."
    log "boot.tar.xz checksum OK"
  fi

  run mount "$p1" "$mnt" || die "Could not mount $p1"
  # Keep the user's boot settings
  [[ $DRY_RUN = 1 ]] || cp -f "$mnt/batocera-boot.conf" "$work/" 2>/dev/null || true
  run_sh "cd '$mnt' && xz -dc < '$work/boot.tar.xz' | tar xf - --no-same-owner" || { umount "$mnt"; die "Extracting boot.tar.xz failed"; }
  [[ -f $work/batocera-boot.conf ]] && cp -f "$work/batocera-boot.conf" "$mnt/"
  run sync
  run umount "$mnt"
  rm -rf "$work"
  log "== Batocera: system reinstalled on $disk"
}

# Set KEY=VALUE in batocera-boot.conf on the BATOCERA partition.
batocera_set_bootconf() {
  local p1="$1" key="$2" val="$3" mnt
  mnt="$(mktemp -d /tmp/batosteam-bconf.XXXX)"
  run mount "$p1" "$mnt" || { warn "Could not mount $p1 to edit batocera-boot.conf"; return 0; }
  if [[ $DRY_RUN != 1 ]]; then
    if grep -qE "^#?${key}=" "$mnt/batocera-boot.conf" 2>/dev/null; then
      sed -i -E "s|^#?${key}=.*|${key}=${val}|" "$mnt/batocera-boot.conf"
    else
      echo "${key}=${val}" >> "$mnt/batocera-boot.conf"
    fi
  fi
  run umount "$mnt"
  rmdir "$mnt"
}
