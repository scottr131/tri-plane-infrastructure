#!/bin/bash
#
# This script created with Anthropic Fable
#
# build-usb-image.sh — wrap the stock Slackware usbboot.img with our customized
# initrd (from build-initrd.sh), producing a ready-to-dd image for USB-booting a
# node (primarily node 7, which can't PXE itself). Run as root (loop mount).
#
# The substantive customization is in the initrd; this script only swaps that
# initrd into the image and points you at the boot configs to add default params.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

############################################################################
# Configuration
############################################################################
STOCK_IMG="${STOCK_IMG:-/srv/slackware/slackware64-current/usb-and-pxe-installers/usbboot.img}"
CUSTOM_INITRD="${CUSTOM_INITRD:-/srv/pxe/initrd-auto.img}"
OUT_IMG="${OUT_IMG:-$HERE/custom-usbboot.img}"

# Default boot params we WANT on the append line. For node 7 we want networking +
# dropbear but INTERACTIVE (deliberately NO autoinstall=1, so it won't auto-wipe).
APPEND_PARAMS="${APPEND_PARAMS:-kbd=us nic=auto:eth0:dhcp}"

############################################################################
die(){ echo "!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
[ -f "$STOCK_IMG" ] || die "stock usbboot.img not found: $STOCK_IMG"
[ -f "$CUSTOM_INITRD" ] || die "custom initrd not found: $CUSTOM_INITRD (run build-initrd.sh first)"

cp -f "$STOCK_IMG" "$OUT_IMG"

LOOP="$(losetup -fP --show "$OUT_IMG")"
MNT="$(mktemp -d)"
cleanup(){ umount "$MNT" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

# usbboot.img may be a bare FAT (mount $LOOP) or partitioned (mount ${LOOP}p1).
if [ -b "${LOOP}p1" ]; then PART="${LOOP}p1"; else PART="$LOOP"; fi
mount "$PART" "$MNT" || die "could not mount $PART — confirm image layout"

echo ">>> Image contents (top levels):"; ( cd "$MNT" && ls -R . | head -40 )

# --- Swap in our initrd ----------------------------------------------------
TARGET_INITRD="$(find "$MNT" -iname 'initrd.img' | head -1)"
[ -n "$TARGET_INITRD" ] || die "initrd.img not found inside image — confirm layout"
echo ">>> Replacing $(echo "$TARGET_INITRD" | sed "s|$MNT||")"
cp -f "$CUSTOM_INITRD" "$TARGET_INITRD"

# --- Boot params: append to the UEFI grub.cfg 'linux' lines ----------------
# We boot fully UEFI, so we patch EFI/BOOT/grub.cfg (syslinux.cfg is CSM/BIOS only
# and left untouched). Every bootable "linux ..." entry gets APPEND_PARAMS appended
# to the end of the line. Default APPEND_PARAMS is interactive-safe (no
# autoinstall=1); override it for a full-auto USB.
GRUB_CFG="$MNT/EFI/BOOT/grub.cfg"
[ -f "$GRUB_CFG" ] || GRUB_CFG="$(find "$MNT" -ipath '*/EFI/BOOT/grub.cfg' | head -1)"
if [ -n "$APPEND_PARAMS" ] && [ -n "$GRUB_CFG" ] && [ -f "$GRUB_CFG" ]; then
    echo ">>> Appending to grub.cfg 'linux' lines: $APPEND_PARAMS"
    sed -i "s|^\([[:space:]]*linux[[:space:]].*\)\$|\1 $APPEND_PARAMS|" "$GRUB_CFG"
    echo ">>> Patched entries:"; grep -n '^[[:space:]]*linux[[:space:]]' "$GRUB_CFG" | sed 's/^/      /'
elif [ -z "$APPEND_PARAMS" ]; then
    echo ">>> APPEND_PARAMS empty — leaving grub.cfg unchanged"
else
    die "grub.cfg not found under EFI/BOOT — confirm image layout"
fi

sync
echo ">>> Done: $OUT_IMG"
echo ">>> Write to USB:  dd if=$OUT_IMG of=/dev/sdX bs=4M status=progress oflag=sync"
