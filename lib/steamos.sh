#!/bin/bash
# BatoSteam Installer - SteamOS stage (EXPERIMENTAL)
# Author: Dan Lee
# Version: 0.1.0
#
# Installs the official Valve SteamOS 3 onto ANY chosen drive. It follows the same
# steps as Valve's recovery script (repair_device.sh), which is hard-wired to
# /dev/nvme0n1 on the Steam Deck.
#
# Two ways to get the SteamOS system image:
#   native - BatoSteam is running from Valve's SteamOS recovery USB (recommended).
#            The recovery USB's own rootfs and steamos-chroot tool are used.
#   image  - BatoSteam is running from another live Linux; a decompressed recovery
#            image file (steamdeck-repair-*.img) is attached as a loop device.

STEAMOS_RECOVERY_URL="${STEAMOS_RECOVERY_URL:-https://steamdeck-images.steamos.cloud/recovery/steamdeck-repair-latest.img.bz2}"
STEAMOS_ROOTFS_MIB=5120

# Partition numbers, same as Valve's layout
S_ESP=1; S_EFI_A=2; S_EFI_B=3; S_ROOT_A=4; S_ROOT_B=5; S_VAR_A=6; S_VAR_B=7; S_HOME=8

STEAMOS_MODE=""       # native | image
STEAMOS_SRC_ROOT=""   # block device holding the SteamOS rootfs to copy
STEAMOS_TOOLROOT=""   # directory we chroot into to run steamos-chroot ("" = host)
STEAMOS_LOOP=""

steamos_partition_table() {
  local disk="$1"
  cat <<EOF
label: gpt
$(part_path "$disk" 1): name="esp",      size=64MiB,   type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
$(part_path "$disk" 2): name="efi-A",    size=32MiB,   type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
$(part_path "$disk" 3): name="efi-B",    size=32MiB,   type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
$(part_path "$disk" 4): name="rootfs-A", size=${STEAMOS_ROOTFS_MIB}MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
$(part_path "$disk" 5): name="rootfs-B", size=${STEAMOS_ROOTFS_MIB}MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
$(part_path "$disk" 6): name="var-A",    size=256MiB,  type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
$(part_path "$disk" 7): name="var-B",    size=256MiB,  type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
$(part_path "$disk" 8): name="home",                   type=933AC7E1-2EB4-4F13-B844-0E14E2AEF915
EOF
}

# True if the disk already holds Valve's SteamOS layout (so home can be kept).
steamos_detect() {
  local disk="$1"
  [[ $(part_label "$(part_path "$disk" $S_ESP)") = esp ]] &&
  [[ $(part_label "$(part_path "$disk" $S_ROOT_A)") = rootfs-A ]] &&
  [[ $(part_label "$(part_path "$disk" $S_HOME)") = home ]]
}

# Work out where the SteamOS system comes from. Sets STEAMOS_MODE / STEAMOS_SRC_ROOT.
#   $1 optional path to a decompressed recovery .img (image mode)
steamos_prepare_source() {
  local img="${1:-}"
  if [[ -z $img ]] && command -v steamos-chroot >/dev/null 2>&1 && findmnt -n /run/media/liveuser/rootfs >/dev/null 2>&1; then
    STEAMOS_MODE=native
    STEAMOS_SRC_ROOT="$(findmnt -n -o SOURCE /run/media/liveuser/rootfs | sed 's/\[.*\]//')"
    STEAMOS_TOOLROOT=""
    [[ -b $STEAMOS_SRC_ROOT ]] || die "Could not find the SteamOS recovery rootfs device."
    log "SteamOS source: recovery USB rootfs $STEAMOS_SRC_ROOT (native mode)"
    return 0
  fi

  [[ -n $img ]] || die "Not running from the SteamOS recovery USB and no recovery image given."
  [[ -f $img ]] || die "Recovery image not found: $img"
  STEAMOS_MODE=image
  if [[ $DRY_RUN = 1 ]]; then
    STEAMOS_LOOP=/dev/loopX; STEAMOS_SRC_ROOT=/dev/loopXp4; STEAMOS_TOOLROOT=/tmp/batosteam-steamtool
    return 0
  fi
  STEAMOS_LOOP="$(losetup -f --show -r -P "$img")" || die "Could not attach $img"
  udevadm settle 2>/dev/null || sleep 2
  local p
  for p in "${STEAMOS_LOOP}"p*; do
    [[ $(part_label "$p") = rootfs-A || $(fs_label "$p") = rootfs ]] && { STEAMOS_SRC_ROOT="$p"; break; }
  done
  [[ -n $STEAMOS_SRC_ROOT ]] || die "No SteamOS rootfs partition found inside $img"

  # Mount the image's rootfs read-only so we can use its steamos-chroot tool.
  STEAMOS_TOOLROOT="$(mktemp -d /tmp/batosteam-steamtool.XXXX)"
  mount -o ro "$STEAMOS_SRC_ROOT" "$STEAMOS_TOOLROOT" || die "Could not mount SteamOS rootfs from $img"
  local d
  for d in dev proc sys run; do mount --rbind "/$d" "$STEAMOS_TOOLROOT/$d"; done
  mount -t tmpfs tmpfs "$STEAMOS_TOOLROOT/tmp"
  log "SteamOS source: $STEAMOS_SRC_ROOT from $img (image mode)"
}

steamos_cleanup_source() {
  [[ $STEAMOS_MODE = image && $DRY_RUN != 1 ]] || return 0
  [[ -n $STEAMOS_TOOLROOT ]] && umount -R "$STEAMOS_TOOLROOT" 2>/dev/null && rmdir "$STEAMOS_TOOLROOT"
  [[ -n $STEAMOS_LOOP ]] && losetup -d "$STEAMOS_LOOP" 2>/dev/null
  return 0
}

# Run Valve's steamos-chroot against the target disk.
steamos_chroot() {
  if [[ -n $STEAMOS_TOOLROOT ]]; then
    run chroot "$STEAMOS_TOOLROOT" steamos-chroot "$@"
  else
    run steamos-chroot "$@"
  fi
}

# Copy the SteamOS rootfs into a slot and give it a fresh btrfs UUID
# (two identical btrfs UUIDs on one machine cause problems).
steamos_image_root() {
  local src="$1" dst="$2"
  run dd if="$src" of="$dst" bs=128M status=progress oflag=sync || die "Copying rootfs to $dst failed"
  run btrfstune -f -u "$dst" || die "btrfstune failed on $dst"
  run btrfs check "$dst" || die "btrfs check failed on $dst"
}

steamos_finalize_part() {
  local disk="$1" set="$2"
  log "Finalizing SteamOS partition set $set"
  steamos_chroot --disk "$disk" --partset "$set" -- mkdir -p /efi/SteamOS
  steamos_chroot --disk "$disk" --partset "$set" -- mkdir -p /esp/SteamOS/conf
  steamos_chroot --disk "$disk" --partset "$set" -- steamos-partsets /efi/SteamOS/partsets
  steamos_chroot --disk "$disk" --partset "$set" -- steamos-bootconf create --image "$set" --conf-dir /esp/SteamOS/conf --efi-dir /efi --set title "$set"
  steamos_chroot --disk "$disk" --partset "$set" -- grub-mkimage
  steamos_chroot --disk "$disk" --partset "$set" -- update-grub
}

# Install SteamOS.
#   $1 disk
#   $2 mode: wipe (whole drive) | keep (reinstall system, keep home = games)
steamos_install() {
  local disk="$1" mode="$2"
  local d_esp d_efia d_efib d_rootA d_rootB d_varA d_varB d_home
  d_esp="$(part_path "$disk" $S_ESP)";     d_efia="$(part_path "$disk" $S_EFI_A)"
  d_efib="$(part_path "$disk" $S_EFI_B)";  d_rootA="$(part_path "$disk" $S_ROOT_A)"
  d_rootB="$(part_path "$disk" $S_ROOT_B)"; d_varA="$(part_path "$disk" $S_VAR_A)"
  d_varB="$(part_path "$disk" $S_VAR_B)";  d_home="$(part_path "$disk" $S_HOME)"

  release_disk "$disk"

  if [[ $mode = wipe ]]; then
    log "== SteamOS: wiping $disk and writing Valve's partition layout"
    run wipefs -a "$disk"
    run_sh "cat <<'EOF' | sfdisk '$disk'
$(steamos_partition_table "$disk")
EOF" || die "Partitioning $disk failed"
    reread_disk "$disk"
  else
    log "== SteamOS: reinstalling system on $disk, keeping home (games)"
    steamos_detect "$disk" || [[ $DRY_RUN = 1 ]] || die "$disk does not contain Valve's SteamOS layout - choose 'wipe' instead."
  fi

  # var is always recreated (Valve does the same - stale overlays break a fresh rootfs)
  run mkfs.ext4 -F -L var "$d_varA" || die "mkfs var-A failed"
  run mkfs.ext4 -F -L var "$d_varB" || die "mkfs var-B failed"

  if [[ $mode = wipe ]]; then
    run mkfs.ext4 -F -O casefold -T huge -L home "$d_home" || die "mkfs home failed"
    run tune2fs -m 0 "$d_home"
  fi

  run mkfs.vfat -n esp "$d_esp"  || die "mkfs esp failed"
  run mkfs.vfat -n efi "$d_efia" || die "mkfs efi-A failed"
  run mkfs.vfat -n efi "$d_efib" || die "mkfs efi-B failed"

  log "Imaging SteamOS rootfs A"; steamos_image_root "$STEAMOS_SRC_ROOT" "$d_rootA"
  log "Imaging SteamOS rootfs B"; steamos_image_root "$STEAMOS_SRC_ROOT" "$d_rootB"

  steamos_finalize_part "$disk" A
  steamos_finalize_part "$disk" B
  log "Installing SteamOS EFI loader"
  steamos_chroot --disk "$disk" --partset A -- steamcl-install --flags restricted --force-extra-removable \
    || die "steamcl-install failed"
  log "== SteamOS: done on $disk"
}
