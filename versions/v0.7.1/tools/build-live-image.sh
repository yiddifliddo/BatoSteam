#!/bin/bash
# BatoSteam - build the downloadable "BatoSteam Live" USB image
# Author: Dan Lee
# Version: 0.7.1
#
# Produces  dist/batosteam-live-<version>.img  (+ .sha256)
# Write it to a USB drive with Rufus or Balena Etcher, boot the PC from it, and the
# BatoSteam installer starts by itself - no commands needed.
#
# The image is a small Debian 13 live system (free software + redistributable
# firmware) with BatoSteam in /opt/batosteam and rEFInd stored for the boot menu.
# It contains NO Valve files: SteamOS is downloaded from Valve during the install.
#
# Layout: GPT, one FAT32 EFI System partition "BATOSTEAM":
#   /EFI/BOOT/BOOTX64.EFI   GRUB (standalone)        /live/vmlinuz, /live/initrd.img
#   /live/filesystem.squashfs                        /live/batosteam.id
# No loop devices or mounts are needed to assemble the image (mtools), so it also
# builds inside a container (GitHub Actions).
#
# Usage:  sudo ./tools/build-live-image.sh [--out DIR] [--mirror URL] [--keep-work] [--compress]
#         --compress also writes batosteam-live-<version>.img.xz (Rufus and Etcher accept it)
# Needs:  debootstrap, squashfs-tools, dosfstools, mtools, fdisk (sfdisk), grub-efi-amd64-bin, xz-utils

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
OUT="$ROOT/dist"
WORK="${WORK:-/var/tmp/batosteam-live-build}"
MIRROR="http://deb.debian.org/debian"
SUITE=trixie
KEEP=0
COMPRESS=0
REFIND_VERSION=0.14.2
REFIND_SHA256=410c7828c4fec2f2179bd956073522415831d27c00416381b8f71153c190a311
REFIND_URL="https://sourceforge.net/projects/refind/files/${REFIND_VERSION}/refind-bin-${REFIND_VERSION}.zip/download"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)       OUT="$2"; shift ;;
    --mirror)    MIRROR="$2"; shift ;;
    --keep-work) KEEP=1 ;;
    --compress)  COMPRESS=1 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }
for c in debootstrap mksquashfs mkfs.vfat mcopy mmd sfdisk grub-mkstandalone curl sha256sum; do
  command -v "$c" >/dev/null || { echo "Missing tool: $c"; exit 1; }
done

say() { echo -e "\n=== $*"; }
CH="$WORK/rootfs"
IMG="$OUT/batosteam-live-${VERSION}.img"

cleanup() {
  for m in proc sys dev/pts dev; do umount -l "$CH/$m" 2>/dev/null || true; done
  [[ $KEEP = 1 ]] || rm -rf "$WORK"
}
trap cleanup EXIT

rm -rf "$WORK"; mkdir -p "$WORK" "$OUT"

##
## 1. Debian base system
##
say "1/6 Debian $SUITE base system"
KEYRING=()
[[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]] && KEYRING=(--keyring=/usr/share/keyrings/debian-archive-keyring.gpg)
debootstrap --variant=minbase --components=main,contrib,non-free-firmware "${KEYRING[@]}" \
  "$SUITE" "$CH" "$MIRROR"

cat > "$CH/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free-firmware
deb $MIRROR $SUITE-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security $SUITE-security main contrib non-free-firmware
EOF
echo batosteam > "$CH/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 batosteam\n' > "$CH/etc/hosts"

for m in proc sys dev dev/pts; do mkdir -p "$CH/$m"; done
mount -t proc proc "$CH/proc"; mount -t sysfs sys "$CH/sys"
mount --bind /dev "$CH/dev"; mount --bind /dev/pts "$CH/dev/pts"

##
## 2. Packages: kernel, live boot, network (Ethernet + Wi-Fi), disk tools
##
say "2/6 Packages"
PKGS=(
  linux-image-amd64 live-boot systemd-sysv dbus udev kmod procps iproute2 less nano
  network-manager wpasupplicant iw rfkill ca-certificates curl
  firmware-linux-free firmware-misc-nonfree firmware-iwlwifi firmware-realtek firmware-atheros
  firmware-brcm80211 firmware-mediatek firmware-intel-misc firmware-amd-graphics
  btrfs-progs e2fsprogs dosfstools exfatprogs fdisk gdisk parted util-linux
  xz-utils bzip2 lbzip2 gzip unzip tar efibootmgr whiptail squashfs-tools
  pciutils usbutils kbd console-setup-linux
)
# Package names change between Debian releases: install those that exist, report the rest
AVAILABLE=()
chroot "$CH" apt-get update -qq
for p in "${PKGS[@]}"; do
  if chroot "$CH" apt-cache show "$p" >/dev/null 2>&1; then AVAILABLE+=("$p"); else echo "  (skipping $p - not in $SUITE)"; fi
done
DEBIAN_FRONTEND=noninteractive chroot "$CH" apt-get install -y -qq --no-install-recommends "${AVAILABLE[@]}"

##
## 3. BatoSteam + auto-start
##
say "3/6 BatoSteam $VERSION"
mkdir -p "$CH/opt/batosteam/images"
for f in batosteam-installer.sh make-usb.sh lib config docs README.md CHANGE_CONTROL.md VERSION; do
  cp -r "$ROOT/$f" "$CH/opt/batosteam/"
done
chmod +x "$CH/opt/batosteam/"*.sh
# rEFInd for the boot menu, so it never has to be downloaded
curl -fsSL --retry 3 -o "$CH/opt/batosteam/images/refind-bin-${REFIND_VERSION}.zip" "$REFIND_URL"
echo "$REFIND_SHA256  $CH/opt/batosteam/images/refind-bin-${REFIND_VERSION}.zip" | sha256sum -c -

install -m 755 "$ROOT/live/batosteam-live" "$CH/usr/local/bin/batosteam-live"
mkdir -p "$CH/etc/systemd/system/getty@tty1.service.d"
cp "$ROOT/live/getty-autologin.conf" "$CH/etc/systemd/system/getty@tty1.service.d/autologin.conf"
cp "$ROOT/live/bash_profile" "$CH/root/.bash_profile"
chroot "$CH" systemctl enable NetworkManager >/dev/null 2>&1 || true
# Quiet console during boot
echo 'kernel.printk = 3 3 3 3' > "$CH/etc/sysctl.d/20-quiet-printk.conf"

# The initramfs must be able to find the image on a FAT USB drive (or NVMe/SATA)
cat >> "$CH/etc/initramfs-tools/modules" <<EOF
vfat
nls_cp437
nls_ascii
nls_utf8
usb_storage
uas
xhci_pci
ehci_pci
sd_mod
nvme
EOF
chroot "$CH" update-initramfs -u -k all >/dev/null

# Smaller image
chroot "$CH" apt-get clean
rm -rf "$CH"/var/lib/apt/lists/* "$CH"/usr/share/doc/* "$CH"/usr/share/man/* "$CH"/tmp/*
find "$CH/usr/share/locale" -mindepth 1 -maxdepth 1 ! -name 'en*' -exec rm -rf {} + 2>/dev/null || true
for m in proc sys dev/pts dev; do umount -l "$CH/$m"; done

##
## 4. Compressed live filesystem
##
say "4/6 SquashFS"
KVER="$(find "$CH/boot" -maxdepth 1 -name "vmlinuz-*" -printf "%f\n" | sed "s/^vmlinuz-//" | sort -V | tail -n1)"
mkdir -p "$WORK/esp/live" "$WORK/esp/EFI/BOOT"
cp "$CH/boot/vmlinuz-$KVER" "$WORK/esp/live/vmlinuz"
cp "$CH/boot/initrd.img-$KVER" "$WORK/esp/live/initrd.img"
mksquashfs "$CH" "$WORK/esp/live/filesystem.squashfs" -comp xz -b 1M -noappend -quiet -e boot
echo "BatoSteam Live $VERSION" > "$WORK/esp/live/batosteam.id"

##
## 5. GRUB (UEFI)
##
say "5/6 GRUB"
grub-mkstandalone -O x86_64-efi -o "$WORK/esp/EFI/BOOT/BOOTX64.EFI" \
  --modules="part_gpt fat search search_fs_file linux normal configfile echo all_video gfxterm efi_gop" \
  "boot/grub/grub.cfg=$ROOT/live/grub.cfg"

##
## 6. Disk image: GPT + FAT32 EFI partition, assembled without loop devices
##
say "6/6 Disk image"
data_mb=$(( $(du -sm "$WORK/esp" | cut -f1) ))
part_mb=$(( data_mb + data_mb / 10 + 64 ))
img_mb=$(( part_mb + 2 ))
rm -f "$IMG" "$WORK/esp.fat"
truncate -s "${part_mb}M" "$WORK/esp.fat"
mkfs.vfat -F 32 -n BATOSTEAM "$WORK/esp.fat" >/dev/null
MTOOLS_SKIP_CHECK=1 mcopy -s -i "$WORK/esp.fat" "$WORK/esp/EFI" "$WORK/esp/live" ::/
truncate -s "${img_mb}M" "$IMG"
printf 'label: gpt\nstart=2048, size=%s, type=U, name="BATOSTEAM"\n' $(( part_mb * 2048 )) | sfdisk -q "$IMG"
dd if="$WORK/esp.fat" of="$IMG" bs=1M seek=1 conv=notrunc status=none
( cd "$OUT" && sha256sum "$(basename "$IMG")" > "$(basename "$IMG").sha256" )
if [[ $COMPRESS = 1 ]]; then
  say "Compressing"
  xz -T0 -6 -k -f "$IMG"
  ( cd "$OUT" && sha256sum "$(basename "$IMG").xz" > "$(basename "$IMG").xz.sha256" )
fi

say "Done"
ls -lh "$OUT"/batosteam-live-"${VERSION}".img*
echo "Write $IMG to a USB drive (8 GB or larger) with Rufus or Balena Etcher."
