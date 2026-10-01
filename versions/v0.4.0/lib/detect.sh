#!/bin/bash
# BatoSteam Installer - detection of existing installs and hardware checks
# Author: Dan Lee
# Version: 0.4.0
#
# Scans every drive for an existing Batocera or SteamOS install and decides whether
# it is complete enough to be "left untouched". Also checks the SteamOS drive and
# graphics card against the recommended hardware.

# Results of detect_scan, keyed by disk (/dev/sdX)
declare -A DETECT_OS=()     # Batocera | SteamOS | ""
declare -A DETECT_VALID=()  # 1 = passes the keep-untouched check
declare -A DETECT_INFO=()   # human readable, e.g. "Batocera 43.1 (complete)"

# Recommended hardware for SteamOS
STEAMOS_MIN_RECOMMENDED_BYTES=1900000000000   # "2 TB" drives report ~2.0e12 bytes

# Mount a partition read-only in a temp dir; prints the mountpoint.
_ro_mount() {
  local p="$1" mnt
  mnt="$(mktemp -d /tmp/batosteam-detect.XXXX)"
  if mount -o ro "$p" "$mnt" 2>/dev/null; then echo "$mnt"; else rmdir "$mnt"; return 1; fi
}
_ro_umount() { umount "$1" 2>/dev/null; rmdir "$1" 2>/dev/null; }

# Batocera version from the squashfs on the BATOCERA partition ("" if unreadable).
_batocera_version() {
  local boot="$1" sq="" v="" m
  [[ -f $boot/boot/batocera ]] && sq="$boot/boot/batocera"
  [[ -z $sq && -f $boot/boot/batocera.update ]] && sq="$boot/boot/batocera.update"
  [[ -n $sq ]] || return 0
  if command -v unsquashfs >/dev/null 2>&1; then
    v="$(unsquashfs -cat "$sq" usr/share/batocera/batocera.version 2>/dev/null | head -n1)"
  else
    m="$(mktemp -d /tmp/batosteam-sq.XXXX)"
    if mount -t squashfs -o ro,loop "$sq" "$m" 2>/dev/null; then
      v="$(head -n1 "$m/usr/share/batocera/batocera.version" 2>/dev/null)"
      umount "$m"
    fi
    rmdir "$m"
  fi
  echo "${v%% *}"
}

# Keep-untouched criteria for Batocera:
#   p1 = FAT "BATOCERA", p2 = "SHARE", boot/linux kernel and EFI/batocera/grubx64.efi present
# Sets DETECT_VERSION. Returns 0 if valid.
batocera_validate() {
  local disk="$1" mnt ok=1
  DETECT_VERSION=""
  batocera_detect "$disk" || return 1
  mnt="$(_ro_mount "$(part_path "$disk" 1)")" || return 1
  [[ -f $mnt/boot/linux ]] || ok=0
  [[ -f $mnt/EFI/batocera/grubx64.efi ]] || ok=0
  [[ -f $mnt/boot/batocera || -f $mnt/boot/batocera.update ]] || ok=0
  DETECT_VERSION="$(_batocera_version "$mnt")"
  _ro_umount "$mnt"
  [[ $ok = 1 ]]
}

# Keep-untouched criteria for SteamOS:
#   all 8 Valve partitions with the right names, and efi/steamos/steamcl.efi on esp
steamos_validate() {
  local disk="$1" mnt i ok=1
  local names=(esp efi-A efi-B rootfs-A rootfs-B var-A var-B home)
  DETECT_VERSION=""
  steamos_detect "$disk" || return 1
  for i in 1 2 3 4 5 6 7 8; do
    [[ $(part_label "$(part_path "$disk" $i)") = "${names[$((i - 1))]}" ]] || ok=0
  done
  mnt="$(_ro_mount "$(part_path "$disk" "$S_ESP")")" || return 1
  [[ -f $mnt/efi/steamos/steamcl.efi || -f $mnt/EFI/steamos/steamcl.efi ]] || ok=0
  _ro_umount "$mnt"
  if mnt="$(_ro_mount "$(part_path "$disk" "$S_ROOT_A")")"; then
    DETECT_VERSION="$(sed -n 's/^VERSION_ID=//p' "$mnt/etc/os-release" 2>/dev/null | tr -d '"')"
    _ro_umount "$mnt"
  fi
  [[ $ok = 1 ]]
}

# Fill DETECT_* for every drive in the machine.
detect_scan() {
  local d
  DETECT_OS=(); DETECT_VALID=(); DETECT_INFO=()
  for d in $(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}'); do
    [[ $d =~ /dev/(loop|zram|ram|sr) ]] && continue
    DETECT_OS[$d]=""; DETECT_VALID[$d]=0; DETECT_INFO[$d]="empty / other"
    if batocera_detect "$d"; then
      DETECT_OS[$d]=Batocera
      if batocera_validate "$d"; then
        DETECT_VALID[$d]=1; DETECT_INFO[$d]="Batocera ${DETECT_VERSION:-(version unknown)} - complete"
      else
        DETECT_INFO[$d]="Batocera - INCOMPLETE (boot files missing)"
      fi
    elif steamos_detect "$d"; then
      DETECT_OS[$d]=SteamOS
      if steamos_validate "$d"; then
        DETECT_VALID[$d]=1; DETECT_INFO[$d]="SteamOS ${DETECT_VERSION:-(version unknown)} - complete"
      else
        DETECT_INFO[$d]="SteamOS - INCOMPLETE (partitions or loader missing)"
      fi
    fi
    log "Detected $d: ${DETECT_INFO[$d]}"
  done
}

# First valid drive holding the given OS ("" if none). Excludes $2.
detect_find() {
  local os="$1" exclude="${2:-}" d
  for d in "${!DETECT_OS[@]}"; do
    [[ $d = "$exclude" ]] && continue
    [[ ${DETECT_OS[$d]} = "$os" && ${DETECT_VALID[$d]} = 1 ]] && { echo "$d"; return 0; }
  done
  return 1
}

detect_report() {
  local s="" d size model
  for d in $(printf '%s\n' "${!DETECT_OS[@]}" | sort); do
    size="$(lsblk -dno SIZE "$d" 2>/dev/null | tr -d ' ')"
    model="$(lsblk -dno MODEL "$d" 2>/dev/null | sed 's/ *$//')"
    s+="$d  $size  ${model:-unknown}\n    -> ${DETECT_INFO[$d]}\n"
  done
  echo "${s:-No drives found.}"
}

##
## SteamOS hardware recommendations: NVMe M.2, 2 TB or larger, AMD graphics
##

# Prints warning lines for the chosen SteamOS drive (nothing if it meets the recommendation).
steamos_drive_warnings() {
  local disk="$1" bytes tran
  bytes="$(disk_size_bytes "$disk" 2>/dev/null || echo 0)"
  tran="$(lsblk -dno TRAN "$disk" 2>/dev/null | tr -d ' ')"
  [[ $bytes -lt $STEAMOS_MIN_RECOMMENDED_BYTES ]] && \
    echo "- Drive is $(lsblk -dno SIZE "$disk" | tr -d ' '). 2 TB or larger is recommended - modern games are 100+ GB each."
  [[ $tran != nvme ]] && \
    echo "- Drive is ${tran:-unknown type}, not an NVMe M.2 SSD. NVMe is recommended for load times and shader cache."
  return 0
}

# Prints warning lines about the graphics card (nothing if an AMD GPU is present).
steamos_gpu_warnings() {
  local dev class vendor amd=0 nvidia=0 intel=0
  for dev in /sys/bus/pci/devices/*; do
    class="$(cat "$dev/class" 2>/dev/null)"; vendor="$(cat "$dev/vendor" 2>/dev/null)"
    [[ $class = 0x03* ]] || continue   # display controllers
    case "$vendor" in
      0x1002) amd=1 ;;
      0x10de) nvidia=1 ;;
      0x8086) intel=1 ;;
    esac
  done
  [[ $amd = 1 ]] && return 0
  [[ $nvidia = 1 ]] && echo "- NVIDIA graphics detected. SteamOS has NO NVIDIA driver - expect a black screen. AMD Radeon is recommended."
  [[ $intel = 1 ]]  && echo "- Only Intel graphics detected. SteamOS support is limited. AMD Radeon is recommended."
  [[ $nvidia = 0 && $intel = 0 ]] && echo "- No AMD graphics detected. AMD Radeon is recommended for SteamOS."
  return 0
}

# Returns 0 if the user accepts (or there is nothing to warn about).
steamos_hardware_check() {
  local disk="$1" w
  w="$(steamos_drive_warnings "$disk"; steamos_gpu_warnings)"
  [[ -z $w ]] && return 0
  log "SteamOS hardware warnings for $disk: $(echo "$w" | tr '\n' ' ')"
  ui_yesno "SteamOS - hardware recommendation" \
"Recommended for SteamOS:\n  * NVMe M.2 SSD, 2 TB or larger\n  * AMD Radeon graphics\n\nThis PC:\n$w\n\nYou can still continue. Install SteamOS on $disk anyway?"
}
