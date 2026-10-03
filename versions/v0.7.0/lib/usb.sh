#!/bin/bash
# BatoSteam Installer - all-in-one USB key
# Author: Dan Lee
# Version: 0.7.0
#
# Builds ONE USB key that holds:
#   - Valve's official SteamOS recovery system (boots the PC, provides SteamOS)
#   - the BatoSteam installer with a desktop shortcut
#   - rEFInd (boot menu) and optionally the Batocera image, for offline installs
# Valve's own "Wipe Device / Reimage / Repair" desktop shortcuts are moved into a
# clearly named folder, because they always target the FIRST NVMe drive of the PC.
#
# Used by make-usb.sh (Linux PC) and by "batosteam-installer.sh --setup-usb"
# (run on a Valve recovery USB made with Rufus / Balena Etcher on Windows or macOS).

# shellcheck disable=SC2034  # used by make-usb.sh and batosteam-installer.sh
USB_MARGIN_BYTES=$((512 * 1048576))
USB_DECK_UID=1000
USB_VALVE_FOLDER="Steam Deck only - DO NOT USE on a multi-drive PC"
USB_BATOSTEAM_FILES=(batosteam-installer.sh make-usb.sh lib config docs README.md CHANGE_CONTROL.md VERSION)

# Candidate USB drives: NAME<TAB>SIZE<TAB>MODEL<TAB>BYTES
usb_list_candidates() {
  local protected
  protected="$(protected_disks | sort -u | tr '\n' ' ')"
  lsblk -dn -b -P -o NAME,SIZE,MODEL,TRAN,RM,TYPE,RO | while read -r line; do
    local NAME SIZE MODEL TRAN RM TYPE RO
    eval "$line"
    [[ $TYPE = disk && $RO = 0 ]] || continue
    [[ $TRAN = usb || $RM = 1 ]] || continue
    [[ " $protected " = *" $NAME "* ]] && continue
    printf '%s\t%s\t%s\t%s\n' "$NAME" "$(numfmt --to=si "$SIZE" 2>/dev/null || echo "$SIZE")" "${MODEL:-unknown}" "$SIZE"
  done
}

# Size in bytes of the decompressed SteamOS recovery image (from its GPT header).
usb_steamos_image_bytes() {
  local src="$1" hdr last
  hdr="$(mktemp /tmp/batosteam-gpt.XXXX)"
  bash -c "$(steamos_stream_cmd "$src") 2>/dev/null | head -c 1048576 > '$hdr'" || true
  [[ $(dd if="$hdr" bs=1 skip=512 count=8 status=none) = "EFI PART" ]] || { rm -f "$hdr"; return 1; }
  last="$(_le64 "$hdr" 544)"        # backup GPT header LBA = last sector of the image
  rm -f "$hdr"
  echo $(( (last + 1) * 512 ))
}

# Download size of the Batocera image (Content-Length after redirects).
usb_batocera_bytes() {
  local url="$1"
  curl -fsSIL "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{n=$2} END{print n+0}'
}

# Write Valve's image to the USB key (same as Valve's bzcat | dd instructions).
usb_write_steamos() {
  local dev="$1" src="$2"
  release_disk "$dev"
  run wipefs -a "$dev"
  run_sh "$(steamos_stream_cmd "$src") | dd of='$dev' bs=4M iflag=fullblock oflag=sync status=progress" \
    || die "Writing the SteamOS recovery image to $dev failed."
  reread_disk "$dev"
}

# Grow the recovery image's home partition to fill the USB key.
#   $1 USB disk   $2 1 if the key is the running system (online grow)
usb_grow_home() {
  local dev="$1" live="${2:-0}" num part
  num="$(sfdisk -d "$dev" 2>/dev/null | grep 'name="home"' | sed -E 's/^[^ ]*[^0-9]([0-9]+) :.*/\1/')"
  [[ $DRY_RUN = 1 && -z $num ]] && num=5
  [[ -n $num ]] || { warn "No home partition found on $dev - not resized."; return 1; }
  part="$(part_path "$dev" "$num")"
  log "Growing home partition $part to fill $dev"
  run sfdisk --no-reread --relocate gpt-bak-std "$dev" || return 1
  if [[ $live = 1 ]]; then
    run_sh "echo ', +' | sfdisk --no-reread --force -N $num '$dev'" || return 1
    run partx -u "$dev" || return 1            # tell the kernel about the in-use partition
    run resize2fs "$part" || return 1          # ext4 grows online
  else
    run_sh "echo ', +' | sfdisk --no-reread -N $num '$dev'" || return 1
    reread_disk "$dev"
    run e2fsck -fy "$part"
    run resize2fs "$part" || return 1
  fi
}

# Copy BatoSteam onto the recovery home, add the desktop shortcut, park Valve's shortcuts.
#   $1 directory that contains deck/ (the mounted home partition, or / + home -> "/home")
#   $2 Batocera image URL to store offline ("" = none)
usb_install_batosteam() {
  local homeroot="$1" bato_url="${2:-}" dest desk f
  dest="$homeroot/deck/BatoSteam"; desk="$homeroot/deck/Desktop"
  [[ $DRY_RUN = 1 || -d $homeroot/deck ]] || die "$homeroot/deck not found - is this Valve's SteamOS recovery image?"
  log "Copying BatoSteam $BATOSTEAM_VERSION to $dest"
  run mkdir -p "$dest"
  for f in "${USB_BATOSTEAM_FILES[@]}"; do
    [[ -e $BATOSTEAM_DIR/$f ]] && run cp -r "$BATOSTEAM_DIR/$f" "$dest/"
  done

  if [[ -n $bato_url ]]; then
    run mkdir -p "$dest/images"
    run rm -f "$dest"/images/batocera-*.img.gz
    log "Downloading Batocera for offline use: $bato_url"
    run curl -fL --retry 3 -o "$dest/images/$(basename "$bato_url")" "$bato_url" \
      || die "Batocera download failed"
    run gzip -t "$dest/images/$(basename "$bato_url")" || die "Batocera download is corrupted - try again"
  fi

  # rEFInd (boot menu, 4.5 MB) for fully offline installs
  run mkdir -p "$dest/images"
  log "Storing rEFInd $REFIND_VERSION on the USB key for offline installs"
  run curl -fL --retry 3 -o "$dest/images/refind-bin-${REFIND_VERSION}.zip" "$REFIND_URL" \
    || die "rEFInd download failed"
  if [[ $DRY_RUN != 1 && "$(sha256sum "$dest/images/refind-bin-${REFIND_VERSION}.zip" | cut -d' ' -f1)" != "$REFIND_SHA256" ]]; then
    rm -f "$dest/images/refind-bin-${REFIND_VERSION}.zip"
    die "rEFInd download checksum mismatch - try again"
  fi

  # Desktop shortcut (same style as Valve's own shortcuts)
  if [[ $DRY_RUN != 1 ]]; then
    mkdir -p "$desk"
    cat > "$desk/BatoSteam.desktop" <<EOF
[Desktop Entry]
Name=BatoSteam Installer
GenericName=Install Batocera + SteamOS on separate drives
Comment=BatoSteam $BATOSTEAM_VERSION - multi-drive Batocera and SteamOS installer
Exec=sudo /home/deck/BatoSteam/batosteam-installer.sh
Icon=run-install
Path=/home/deck/BatoSteam
StartupNotify=true
Terminal=true
Type=Application
EOF
    chmod 755 "$desk/BatoSteam.desktop"
    # Valve's shortcuts always target the first NVMe drive - move them out of the way
    mkdir -p "$desk/$USB_VALVE_FOLDER"
    for f in Device Deck OS User; do
      [[ -f $desk/$f.desktop ]] && mv -f "$desk/$f.desktop" "$desk/$USB_VALVE_FOLDER/"
    done
    cat > "$desk/$USB_VALVE_FOLDER/README.txt" <<'EOF'
These are Valve's own Steam Deck recovery shortcuts.
They ALWAYS use the FIRST NVMe drive in the PC (/dev/nvme0n1), and
"Wipe Device & Install SteamOS" also runs an NVMe sanitize that erases it completely.
On a PC with more than one drive this can destroy your Batocera install.
Use the "BatoSteam Installer" shortcut on the desktop instead.
EOF
    chown -R "$USB_DECK_UID:$USB_DECK_UID" "$dest" "$desk"
    chmod +x "$dest/batosteam-installer.sh" "$dest/make-usb.sh" 2>/dev/null
  fi
  log "BatoSteam shortcut created on the recovery desktop"
}

# Batocera image stored on this USB key (newest), or "" if none.
usb_offline_batocera() {
  local f
  f="$(find "$BATOSTEAM_DIR/images" -maxdepth 1 -name 'batocera-*.img.gz' 2>/dev/null | sort | tail -n1)"
  echo "$f"
}
