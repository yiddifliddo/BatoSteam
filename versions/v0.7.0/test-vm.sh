#!/bin/bash
# BatoSteam - safe test in a virtual machine (QEMU, UEFI)
# Author: Dan Lee
# Version: 0.7.0
#
# Builds a virtual BatoSteam USB key and two fake NVMe drives (just files), then boots
# them in a UEFI virtual machine. Nothing on the real PC's drives is touched.
#
#   fake NVMe 1 (first NVMe, 64 GB)  - plays your Batocera drive
#   fake NVMe 2 (128 GB)             - target for SteamOS
#
# Usage:
#   sudo ./test-vm.sh                            build what is missing, boot from the USB key
#   sudo ./test-vm.sh --with-batocera-installed  put Batocera on fake NVMe 1 first (like your PC)
#   sudo ./test-vm.sh --no-usb                   boot the fake drives only (after installing)
#   sudo ./test-vm.sh --snapshot NAME            save both fake drives (VM must be off)
#   sudo ./test-vm.sh --restore NAME             go back to a saved snapshot
#   sudo ./test-vm.sh --list-snapshots
#   sudo ./test-vm.sh --reset                    delete the fake drives (keeps the USB key)
#   sudo ./test-vm.sh --reset-all                delete everything, including the USB key
#   sudo ./test-vm.sh --headless                 no window; connect a VNC viewer to 127.0.0.1:5901
#   Options: --dir DIR (default ./vm-test)  --mem MB (default 8192)  --cpus N (default 4)
#
# Needs: qemu-system-x86_64, qemu-img, OVMF (package ovmf / edk2-ovmf) and what make-usb.sh needs.

set -uo pipefail

BATOSTEAM_VERSION="0.7.0"
BATOSTEAM_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BATOSTEAM_LOG="${BATOSTEAM_LOG:-/tmp/batosteam-test-vm.log}"
UI=plain

# shellcheck source=lib/common.sh
source "$BATOSTEAM_DIR/lib/common.sh"
# shellcheck source=lib/batocera.sh
source "$BATOSTEAM_DIR/lib/batocera.sh"

VM_DIR="$PWD/vm-test"
MEM=8192; CPUS=4
WITH_BATO=0; NO_USB=0; HEADLESS=0; ACTION=run; SNAP=""

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-batocera-installed) WITH_BATO=1 ;;
    --no-usb)          NO_USB=1 ;;
    --headless)        HEADLESS=1 ;;
    --snapshot)        ACTION=snapshot; SNAP="$2"; shift ;;
    --restore)         ACTION=restore;  SNAP="$2"; shift ;;
    --list-snapshots)  ACTION=list ;;
    --reset)           ACTION=reset ;;
    --reset-all)       ACTION=resetall ;;
    --dir)             VM_DIR="$2"; shift ;;
    --mem)             MEM="$2"; shift ;;
    --cpus)            CPUS="$2"; shift ;;
    --version)         echo "BatoSteam test-vm $BATOSTEAM_VERSION"; exit 0 ;;
    -h|--help)         usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

USB_IMG="$VM_DIR/batosteam-usb.img"
NVME1="$VM_DIR/nvme1-batocera.qcow2"
NVME2="$VM_DIR/nvme2-steamos.qcow2"
VARS="$VM_DIR/uefi-vars.fd"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1 ($2)"; exit 1; }; }

# UEFI firmware locations differ per Linux distribution
find_ovmf() {
  local pair code vars
  for pair in \
    "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd" \
    "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd" \
    "/usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd" \
    "/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd" \
    "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd:/usr/share/edk2-ovmf/x64/OVMF_VARS.fd" \
    "/usr/share/qemu/ovmf-x86_64-code.bin:/usr/share/qemu/ovmf-x86_64-vars.bin"; do
    code="${pair%%:*}"; vars="${pair#*:}"
    [[ -f $code && -f $vars ]] && { echo "$code:$vars"; return 0; }
  done
  return 1
}

snapshot_all() {
  local op="$1" f
  for f in "$NVME1" "$NVME2"; do
    [[ -f $f ]] || { echo "Missing $f - run ./test-vm.sh first."; exit 1; }
    case $op in
      create)  qemu-img snapshot -c "$SNAP" "$f" && echo "Saved snapshot '$SNAP' of $(basename "$f")" ;;
      restore) qemu-img snapshot -a "$SNAP" "$f" && echo "Restored $(basename "$f") to '$SNAP'" ;;
      list)    echo "== $(basename "$f")"; qemu-img snapshot -l "$f" ;;
    esac
  done
}

case $ACTION in
  snapshot) snapshot_all create;  exit $? ;;
  restore)  snapshot_all restore; exit $? ;;
  list)     snapshot_all list;    exit $? ;;
  reset)    rm -f "$NVME1" "$NVME2" "$VARS"; echo "Fake drives deleted (USB key kept)."; exit 0 ;;
  resetall) rm -rf "$VM_DIR"; echo "Test VM deleted."; exit 0 ;;
esac

need qemu-system-x86_64 "install qemu-system-x86 / qemu-full"
need qemu-img "install qemu-utils / qemu-img"
OVMF="$(find_ovmf)" || { echo "UEFI firmware (OVMF) not found - install the 'ovmf' or 'edk2-ovmf' package."; exit 1; }
mkdir -p "$VM_DIR"
: > "$BATOSTEAM_LOG"

# 1. Virtual BatoSteam USB key (a 16 GB file), built with the real make-usb.sh
if [[ $NO_USB = 0 && ! -f $USB_IMG ]]; then
  require_root
  need losetup "util-linux"
  log "Building the virtual BatoSteam USB key: $USB_IMG"
  truncate -s 16G "$USB_IMG"
  loopdev="$(losetup -fP --show "$USB_IMG")" || die "losetup failed"
  if ! "$BATOSTEAM_DIR/make-usb.sh" --device "$loopdev" --no-batocera; then
    losetup -d "$loopdev"; rm -f "$USB_IMG"
    die "make-usb.sh failed - see /tmp/batosteam-make-usb.log"
  fi
  losetup -d "$loopdev"
fi

# 2. Fake NVMe drives
if [[ ! -f $NVME1 ]]; then
  if [[ $WITH_BATO = 1 ]]; then
    url="$(batocera_image_url)" || die "Could not look up the Batocera image."
    log "Installing Batocera onto fake NVMe 1 (like your PC): $url"
    raw="$VM_DIR/batocera.raw"
    curl -fL --retry 3 "$url" | gunzip -c > "$raw" || { rm -f "$raw"; die "Batocera download failed"; }
    qemu-img convert -O qcow2 "$raw" "$NVME1" && rm -f "$raw"
    qemu-img resize "$NVME1" 64G >/dev/null
  else
    qemu-img create -f qcow2 "$NVME1" 64G >/dev/null
  fi
  log "Created $NVME1"
fi
[[ -f $NVME2 ]] || { qemu-img create -f qcow2 "$NVME2" 128G >/dev/null; log "Created $NVME2"; }
[[ -f $VARS ]] || cp "${OVMF#*:}" "$VARS"
# The image files belong to the user who ran sudo, so they can be deleted without root
[[ -n ${SUDO_USER:-} ]] && chown -R "$SUDO_USER": "$VM_DIR" 2>/dev/null

# 3. Boot
accel=(-accel tcg -cpu max)
if [[ -w /dev/kvm ]]; then
  accel=(-accel kvm -cpu host)
else
  warn "KVM not available - the VM will be VERY slow (enable virtualisation in your BIOS)."
fi
# shellcheck disable=SC2054  # commas are part of the QEMU option
display=(-display gtk,zoom-to-fit=on)
[[ $HEADLESS = 1 ]] && display=(-display none -vnc 127.0.0.1:1)
usb=()
[[ $NO_USB = 0 ]] && usb=(-drive "file=$USB_IMG,format=raw,if=none,id=usbkey"
                         -device "usb-storage,bus=xhci.0,drive=usbkey,bootindex=0")

cat <<EOF

BatoSteam test VM
  USB key  : $([[ $NO_USB = 0 ]] && echo "$USB_IMG" || echo "not attached (--no-usb)")
  NVMe 1   : $NVME1  (first NVMe - plays your Batocera drive)
  NVMe 2   : $NVME2
  Display  : $([[ $HEADLESS = 1 ]] && echo "VNC 127.0.0.1:5901" || echo "window")
Tips: press ESC at the TianoCore logo for the firmware boot menu.
      The VM has no AMD GPU - BatoSteam warns about that; just continue.
      Take a snapshot before risky tests:  sudo ./test-vm.sh --snapshot before-install
EOF

exec qemu-system-x86_64 -machine q35 "${accel[@]}" -smp "$CPUS" -m "$MEM" \
  -drive "if=pflash,format=raw,readonly=on,file=${OVMF%%:*}" \
  -drive "if=pflash,format=raw,file=$VARS" \
  -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 \
  "${usb[@]}" \
  -drive "file=$NVME1,format=qcow2,if=none,id=nvme1" -device "nvme,drive=nvme1,serial=BATOCERA-TEST,bootindex=1" \
  -drive "file=$NVME2,format=qcow2,if=none,id=nvme2" -device "nvme,drive=nvme2,serial=STEAMOS-TEST,bootindex=2" \
  -device virtio-vga \
  -nic user,model=virtio-net-pci \
  "${display[@]}"
