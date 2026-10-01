#!/bin/bash
# BatoSteam Installer - SteamOS stage (EXPERIMENTAL)
# Author: Dan Lee
# Version: 0.4.0
#
# Installs the official Valve SteamOS 3 onto ANY chosen drive. It follows the same
# steps as Valve's recovery script (repair_device.sh), which is hard-wired to
# /dev/nvme0n1 (the Steam Deck's internal drive).
#
# Where the SteamOS system comes from (STEAMOS_MODE):
#   native - BatoSteam is running on Valve's SteamOS recovery USB: its own rootfs
#            (mounted as /) is copied, frozen during the copy exactly like Valve does.
#   stream - Valve's .img.bz2 (downloaded, or a local file) is decompressed on the fly
#            and ONLY the rootfs partition is written straight to the target drive.
#            No second USB key and no temporary space needed.
#   image  - a local, already decompressed .img is attached as a loop device.
# In stream and image mode Valve's setup tools (steamos-chroot, steamcl-install) are
# run from the freshly written SteamOS rootfs on the target drive.
#
# Valve recovery image layout (checked 2026-09-27, 3.1 and 3.8.14 images):
#   1 esp  2 efi-A  3 rootfs-A (5 GiB btrfs)  4 var-A  5 home

# Deck/Machine/PC image (x86_64). Valve's "latest" link redirects to the newest build.
STEAMOS_RECOVERY_URL="${STEAMOS_RECOVERY_URL:-https://steamdeck-images.steamos.cloud/recovery/steamdeck-repair-latest.img.bz2}"
# Partition sizes from Valve's current repair_device.sh (SteamOS 3.8): esp 256, efi 64,
# rootfs 5120 ("should match the size from the input disk build"), var 256, home = rest.
STEAMOS_ESP_MIB=256
STEAMOS_EFI_MIB=64
STEAMOS_ROOTFS_MIB=5120
STEAMOS_VAR_MIB=256

# Partition numbers of the INSTALLED layout, same as Valve's
S_ESP=1; S_EFI_A=2; S_EFI_B=3; S_ROOT_A=4; S_ROOT_B=5; S_VAR_A=6; S_VAR_B=7; S_HOME=8

STEAMOS_MODE=""         # native | stream | image
STEAMOS_SRC=""          # URL / file given by the user
STEAMOS_SRC_ROOT=""     # native/image: block device holding the rootfs to copy
STEAMOS_SRC_OFFSET=0    # stream: byte offset of rootfs-A inside the decompressed image
STEAMOS_SRC_LEN=0       # size of the source rootfs in bytes
STEAMOS_TOOLROOT=""     # directory we chroot into to run steamos-chroot ("" = host)
STEAMOS_LOOP=""

##
## Helpers
##

# True when running on Valve's SteamOS recovery USB.
steamos_is_recovery_usb() {
  grep -qs '^ID=steamos' /etc/os-release || return 1
  command -v steamos-chroot >/dev/null 2>&1 || return 1
  [[ -d /home/deck/tools ]] || return 1
  [[ $(fs_label "$(findmnt -n -o SOURCE / | sed 's/\[.*\]//')") = rootfs ]]
}

steamos_running_version() { sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"'; }

# Fastest available bzip2 decompressor
steamos_decompressor() {
  local c
  for c in "lbzip2 -dc" "pbzip2 -dc" "bzip2 -dc" "bsdcat"; do
    command -v "${c%% *}" >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  return 1
}

# Shell command that outputs the decompressed recovery image on stdout.
steamos_stream_cmd() {
  local src="$1" dec
  dec="$(steamos_decompressor)" || die "No bzip2 decompressor found (lbzip2, pbzip2, bzip2 or bsdcat)."
  case "$src" in
    http*://*) echo "curl -fsSL --retry 3 '$src' | $dec" ;;
    *.bz2)     echo "$dec < '$src'" ;;
    *)         echo "cat '$src'" ;;
  esac
}

_le64() { od -An -t u8 -j "$2" -N 8 "$1" | tr -d ' '; }
_le32() { od -An -t u4 -j "$2" -N 4 "$1" | tr -d ' '; }

# Look up a GPT partition by name in a disk-image header file.
# Prints "FIRST_LBA LAST_LBA" (512-byte sectors).
gpt_find_part() {
  local hdr="$1" want="$2" lba n esz i off name size
  [[ $(dd if="$hdr" bs=1 skip=512 count=8 status=none) = "EFI PART" ]] || return 1
  lba="$(_le64 "$hdr" 584)"; n="$(_le32 "$hdr" 592)"; esz="$(_le32 "$hdr" 596)"
  size="$(stat -c %s "$hdr")"
  for ((i = 0; i < n; i++)); do
    off=$(( lba * 512 + i * esz ))
    [[ $((off + esz)) -le $size ]] || break
    name="$(dd if="$hdr" bs=1 skip=$((off + 56)) count=72 status=none | tr -d '\0')"
    [[ $name = "$want" ]] || continue
    echo "$(_le64 "$hdr" $((off + 32))) $(_le64 "$hdr" $((off + 40)))"
    return 0
  done
  return 1
}

# Steam Frame is an ARM headset - its image cannot run on a PC.
steamos_reject_frame() {
  [[ ${1,,} = *frame* ]] && die "That is the Steam Frame image (ARM). A PC needs the Steam Deck/Machine/PC image: $STEAMOS_RECOVERY_URL"
  return 0
}

steamos_partition_table() {
  local disk="$1"
  cat <<EOF
label: gpt
$(part_path "$disk" 1): name="esp",      size=${STEAMOS_ESP_MIB}MiB,  type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
$(part_path "$disk" 2): name="efi-A",    size=${STEAMOS_EFI_MIB}MiB,   type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
$(part_path "$disk" 3): name="efi-B",    size=${STEAMOS_EFI_MIB}MiB,   type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
$(part_path "$disk" 4): name="rootfs-A", size=${STEAMOS_ROOTFS_MIB}MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
$(part_path "$disk" 5): name="rootfs-B", size=${STEAMOS_ROOTFS_MIB}MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
$(part_path "$disk" 6): name="var-A",    size=${STEAMOS_VAR_MIB}MiB,  type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
$(part_path "$disk" 7): name="var-B",    size=${STEAMOS_VAR_MIB}MiB,  type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
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

##
## Source selection
##

# Work out where the SteamOS system comes from.
#   $1 "" (use this recovery USB), a URL, a .img.bz2 file or a decompressed .img file
steamos_prepare_source() {
  local src="${1:-}"
  STEAMOS_SRC="$src"; STEAMOS_TOOLROOT=""; STEAMOS_LOOP=""

  if [[ -z $src ]]; then
    steamos_is_recovery_usb || [[ $DRY_RUN = 1 ]] || die "Not running on Valve's SteamOS recovery USB - choose 'Download from Valve' instead."
    STEAMOS_MODE=native
    STEAMOS_SRC_ROOT="$(findmnt -n -o SOURCE / | sed 's/\[.*\]//')"
    STEAMOS_SRC_LEN="$(blockdev --getsize64 "$STEAMOS_SRC_ROOT" 2>/dev/null || echo $((STEAMOS_ROOTFS_MIB * 1048576)))"
    log "SteamOS source: this recovery USB, SteamOS $(steamos_running_version) ($STEAMOS_SRC_ROOT)"
    return 0
  fi

  steamos_reject_frame "$src"

  if [[ $src != http*://* && $src != *.bz2 ]]; then
    # Decompressed .img file -> loop device
    [[ -f $src ]] || die "SteamOS image not found: $src"
    STEAMOS_MODE=image
    if [[ $DRY_RUN = 1 ]]; then
      STEAMOS_SRC_ROOT=/dev/loopXp3; STEAMOS_SRC_LEN=$((STEAMOS_ROOTFS_MIB * 1048576)); return 0
    fi
    STEAMOS_LOOP="$(losetup -f --show -r -P "$src")" || die "Could not attach $src"
    udevadm settle 2>/dev/null || sleep 2
    local p
    for p in "${STEAMOS_LOOP}"p*; do
      [[ $(part_label "$p") = rootfs-A || $(fs_label "$p") = rootfs ]] && { STEAMOS_SRC_ROOT="$p"; break; }
    done
    [[ -n $STEAMOS_SRC_ROOT ]] || die "No SteamOS rootfs partition found inside $src"
    STEAMOS_SRC_LEN="$(blockdev --getsize64 "$STEAMOS_SRC_ROOT")"
    log "SteamOS source: $STEAMOS_SRC_ROOT from $src (image mode)"
    return 0
  fi

  # Stream mode: read only the partition table first (first 1 MiB of the image)
  [[ $src = http*://* || -f $src ]] || die "SteamOS image not found: $src"
  STEAMOS_MODE=stream
  if [[ $DRY_RUN = 1 ]]; then
    STEAMOS_SRC_OFFSET=$((655360 * 512)); STEAMOS_SRC_LEN=$((STEAMOS_ROOTFS_MIB * 1048576)); return 0
  fi
  local hdr range
  hdr="$(mktemp /tmp/batosteam-gpt.XXXX)"
  log "Reading SteamOS image partition table from $src"
  bash -c "$(steamos_stream_cmd "$src") 2>/dev/null | head -c 1048576 > '$hdr'" || true
  range="$(gpt_find_part "$hdr" rootfs-A)" || { rm -f "$hdr"; die "Could not read the SteamOS image (download failed or not a SteamOS recovery image)."; }
  rm -f "$hdr"
  STEAMOS_SRC_OFFSET=$(( ${range% *} * 512 ))
  STEAMOS_SRC_LEN=$(( (${range#* } - ${range% *} + 1) * 512 ))
  log "SteamOS source: rootfs-A at byte $STEAMOS_SRC_OFFSET, $((STEAMOS_SRC_LEN / 1048576)) MiB (stream mode)"
}

# Make sure the target rootfs partitions are big enough for the source rootfs.
steamos_size_rootfs() {
  local need=$(( (STEAMOS_SRC_LEN + 1048575) / 1048576 ))
  [[ $need -gt $STEAMOS_ROOTFS_MIB ]] && STEAMOS_ROOTFS_MIB=$need
  return 0
}

# Chroot into the target's own rootfs-A so Valve's tools can be used (stream/image).
steamos_prepare_tools_from_target() {
  local rootA="$1" d
  [[ $STEAMOS_MODE = native ]] && return 0
  STEAMOS_TOOLROOT="/tmp/batosteam-steamtool"
  [[ $DRY_RUN = 1 ]] && return 0
  STEAMOS_TOOLROOT="$(mktemp -d /tmp/batosteam-steamtool.XXXX)"
  mount -o ro "$rootA" "$STEAMOS_TOOLROOT" || die "Could not mount the new SteamOS rootfs $rootA"
  # A PC can only run the x86_64 image
  [[ -e $STEAMOS_TOOLROOT/usr/lib/ld-linux-x86-64.so.2 || -e $STEAMOS_TOOLROOT/lib64/ld-linux-x86-64.so.2 ]] \
    || die "This SteamOS image is not for x86_64 PCs (Steam Frame image?). Use the Deck/Machine/PC image."
  [[ -x $STEAMOS_TOOLROOT/usr/bin/steamos-chroot ]] || die "steamos-chroot missing from the SteamOS image."
  for d in dev proc sys run; do mount --rbind "/$d" "$STEAMOS_TOOLROOT/$d"; done
  mount -t tmpfs tmpfs "$STEAMOS_TOOLROOT/tmp"
}

steamos_cleanup_source() {
  [[ $DRY_RUN = 1 ]] && return 0
  if [[ -n $STEAMOS_TOOLROOT && -d $STEAMOS_TOOLROOT ]]; then
    umount -R "$STEAMOS_TOOLROOT" 2>/dev/null; rmdir "$STEAMOS_TOOLROOT" 2>/dev/null
  fi
  [[ -n $STEAMOS_LOOP ]] && losetup -d "$STEAMOS_LOOP" 2>/dev/null
  return 0
}

# Run Valve's steamos-chroot against the target disk. Newer SteamOS (3.5+) needs
# --no-overlay on a fresh install, exactly as Valve's current script does; 3.1 lacks it.
steamos_chroot() {
  local bin=/usr/bin/steamos-chroot opt=()
  [[ -n $STEAMOS_TOOLROOT ]] && bin="$STEAMOS_TOOLROOT/usr/bin/steamos-chroot"
  [[ $DRY_RUN = 1 ]] || ! grep -qs -- '--no-overlay' "$bin" || opt=(--no-overlay)
  [[ $DRY_RUN = 1 ]] && opt=(--no-overlay)
  if [[ -n $STEAMOS_TOOLROOT ]]; then
    run chroot "$STEAMOS_TOOLROOT" steamos-chroot "${opt[@]}" "$@"
  else
    run steamos-chroot "${opt[@]}" "$@"
  fi
}

##
## Imaging
##

# Write the SteamOS rootfs to rootfs-A, copy it to rootfs-B, give both new btrfs UUIDs
# (two identical btrfs UUIDs on one machine cause problems).
steamos_write_roots() {
  local rootA="$1" rootB="$2"
  case $STEAMOS_MODE in
    native)
      # Valve freezes the running rootfs so the copy is consistent
      log "Imaging SteamOS rootfs A from this USB"
      run fsfreeze -f / || die "Could not freeze / for copying"
      run dd if="$STEAMOS_SRC_ROOT" of="$rootA" bs=128M status=progress oflag=sync
      local rc=$?
      run fsfreeze -u /
      [[ $rc = 0 ]] || die "Copying SteamOS rootfs to $rootA failed"
      ;;
    image)
      log "Imaging SteamOS rootfs A from $STEAMOS_SRC"
      run dd if="$STEAMOS_SRC_ROOT" of="$rootA" bs=128M status=progress oflag=sync || die "Copying SteamOS rootfs to $rootA failed"
      ;;
    stream)
      log "Streaming SteamOS rootfs A from $STEAMOS_SRC (download + decompress, this takes a while)"
      local ok
      ok="$(mktemp /tmp/batosteam-ok.XXXX)"; rm -f "$ok"
      # The first MiB is skipped separately so the skip can use a large block size.
      # The download is cut off after rootfs-A - that is expected, so no pipefail here.
      run_sh "set +o pipefail; $(steamos_stream_cmd "$STEAMOS_SRC") 2>/dev/null | { dd bs=1M count=1 iflag=fullblock of=/dev/null status=none && dd iflag=skip_bytes,count_bytes,fullblock skip=$((STEAMOS_SRC_OFFSET - 1048576)) count=$STEAMOS_SRC_LEN bs=4M of='$rootA' oflag=sync status=progress && touch '$ok'; }"
      [[ $DRY_RUN = 1 || -f $ok ]] || die "Streaming SteamOS to $rootA failed (download interrupted?)"
      rm -f "$ok"
      ;;
  esac
  log "Copying rootfs A to rootfs B"
  run dd if="$rootA" of="$rootB" bs=1M count=$(( (STEAMOS_SRC_LEN + 1048575) / 1048576 )) iflag=fullblock status=progress oflag=sync \
    || die "Copying rootfs A to B failed"
  local r
  for r in "$rootA" "$rootB"; do
    run btrfstune -f -u "$r" || die "btrfstune failed on $r"
    run btrfs check "$r"     || die "btrfs check failed on $r - the SteamOS image may be corrupted, try again."
  done
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

# Install SteamOS. steamos_prepare_source must have been called first.
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
  steamos_size_rootfs

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
    if [[ $DRY_RUN != 1 && $(blockdev --getsize64 "$d_rootA") -lt $STEAMOS_SRC_LEN ]]; then
      die "The existing SteamOS system partitions on $disk are too small for this SteamOS version - choose 'wipe' instead."
    fi
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

  steamos_write_roots "$d_rootA" "$d_rootB"
  steamos_prepare_tools_from_target "$d_rootA"

  # (Valve's script also updates Steam Deck BIOS and controller firmware here - Deck only, skipped on a PC.)
  steamos_finalize_part "$disk" A
  steamos_finalize_part "$disk" B
  log "Installing SteamOS EFI loader"
  steamos_chroot --disk "$disk" --partset A -- steamcl-install --flags restricted --force-extra-removable \
    || die "steamcl-install failed"
  log "== SteamOS: done on $disk"
}
