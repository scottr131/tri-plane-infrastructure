#!/bin/bash
#
# This script created with Anthropic Fable
#
# build-initrd.sh — turn the stock Slackware installer initrd into our auto-install
# initrd: inject autoinstall.sh + the hook, optionally set a root password (so
# dropbear remote login works), and repack. The output feeds BOTH the PXE service
# (served as initrd-auto.img) and the USB image (build-usb-image.sh).
#
# Run as root (cpio preserves ownership). Needs: cpio, gzip and/or xz, file,
# openssl (only if setting a root password).
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

############################################################################
# Configuration
############################################################################
STOCK_INITRD="${STOCK_INITRD:-/srv/slackware/slackware64-current/isolinux/initrd.img}"
OUT_INITRD="${OUT_INITRD:-/srv/pxe/initrd-auto.img}"
AUTOINSTALL_SH="${AUTOINSTALL_SH:-$HERE/autoinstall.sh}"
HOOK_SH="${HOOK_SH:-$HERE/autoinstall-hook.sh}"

# Root password for the installer's dropbear (so remote SSH login works). The
# CLEANER way is the cmdline param `instrootpw=<pw>` — rc.S sets it (line 23), no
# initrd edit needed — so prefer that on boot.ipxe / the USB append line. These
# options bake it into the initrd instead, if you'd rather. Leave empty to skip.
ROOT_PW="${ROOT_PW:-}"
ROOT_AUTHKEY="${ROOT_AUTHKEY:-}"   # optional ssh pubkey for root

# The installer init script (inside the initrd) and the line AFTER which to insert
# the hook call. From the real rc.S (intake/rc.S): networking comes up at
# `SeTnet boot` and dropbear at `rc.dropbear start`, so anchoring after dropbear
# puts the hook past networking and BEFORE the fake `slackware login:` prompt —
# which the hook then bypasses (it exec's autoinstall.sh when autoinstall=1). The
# earlier keyboard-map prompt is skipped by passing `kbd=us` on the cmdline.
INIT_SCRIPT="${INIT_SCRIPT:-etc/rc.d/rc.S}"
INIT_ANCHOR="${INIT_ANCHOR:-/etc/rc.d/rc.dropbear start}"

# In rc.S, dropbear is started right after networking — but DHCP may not have
# finished, so rc.dropbear (which only starts "if a configured interface is
# present") no-ops. Patch that line to delay, then background the whole startup,
# so it gets a configured interface AND rc.S keeps going; also print the IP to the
# console for convenience. (Test 3: the interface can take a while, so default 10.)
DROPBEAR_DELAY="${DROPBEAR_DELAY:-10}"     # seconds; set 0 to disable the patch

############################################################################
die(){ echo "!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
[ -f "$STOCK_INITRD" ] || die "stock initrd not found: $STOCK_INITRD"
[ -f "$AUTOINSTALL_SH" ] || die "autoinstall.sh not found: $AUTOINSTALL_SH"
[ -f "$HOOK_SH" ] || die "hook not found: $HOOK_SH"

# Resolve inputs to absolute paths: STOCK_INITRD is read from inside a `cd`
# subshell during unpack, so a relative path would break (test 3). (OUT_INITRD is
# fine relative — its redirect runs in the parent shell.)
STOCK_INITRD="$(readlink -f "$STOCK_INITRD")"
AUTOINSTALL_SH="$(readlink -f "$AUTOINSTALL_SH")"
HOOK_SH="$(readlink -f "$HOOK_SH")"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ROOTDIR="$WORK/root"; mkdir -p "$ROOTDIR"

# --- Decompress + unpack the cpio initramfs -------------------------------
echo ">>> Unpacking $STOCK_INITRD"
case "$(file -b "$STOCK_INITRD")" in
    *XZ*|*xz*)  DECOMP="xz -dc";   RECOMP="xz -9 --check=crc32" ;;
    *gzip*)     DECOMP="gzip -dc"; RECOMP="gzip -9" ;;
    *) die "unknown initrd compression: $(file -b "$STOCK_INITRD")" ;;
esac
( cd "$ROOTDIR" && $DECOMP "$STOCK_INITRD" | cpio -idm --quiet )
[ -f "$ROOTDIR/$INIT_SCRIPT" ] || echo "!! note: $INIT_SCRIPT not found in initrd (verify layout)"

# --- Inject our scripts ----------------------------------------------------
echo ">>> Injecting autoinstall.sh + hook"
install -m755 "$AUTOINSTALL_SH" "$ROOTDIR/autoinstall.sh"
install -m755 "$HOOK_SH"        "$ROOTDIR/autoinstall-hook.sh"

# --- Root password / key (for dropbear remote login) ----------------------
if [ -n "$ROOT_PW" ]; then
    echo ">>> Setting root password in initrd"
    [ -f "$ROOTDIR/etc/shadow" ] || die "no etc/shadow in initrd"
    HASH="$(openssl passwd -6 "$ROOT_PW")"
    sed -i "s|^root:[^:]*:|root:${HASH}:|" "$ROOTDIR/etc/shadow"
fi
if [ -n "$ROOT_AUTHKEY" ]; then
    echo ">>> Installing root authorized_keys"
    install -d -m700 "$ROOTDIR/root/.ssh"
    printf '%s\n' "$ROOT_AUTHKEY" > "$ROOTDIR/root/.ssh/authorized_keys"
    chmod 600 "$ROOTDIR/root/.ssh/authorized_keys"
fi

# --- Patch the init script: dropbear timing, then our hook -----------------
INIT="$ROOTDIR/$INIT_SCRIPT"

# Delay + background dropbear so DHCP can finish and rc.S keeps going:
#   /etc/rc.d/rc.dropbear start   ->   ( sleep 2; /etc/rc.d/rc.dropbear start ) &
DROPBEAR_LINE='/etc/rc.d/rc.dropbear start'
if [ "$DROPBEAR_DELAY" != "0" ] && [ -f "$INIT" ] \
   && grep -qF "$DROPBEAR_LINE" "$INIT" && ! grep -q 'sleep .*rc\.dropbear' "$INIT"; then
    echo ">>> Patching dropbear start: delay ${DROPBEAR_DELAY}s + background + show IP"
    sed -i "s|^[[:space:]]*${DROPBEAR_LINE}\$|( sleep ${DROPBEAR_DELAY}; ${DROPBEAR_LINE}; ip addr show eth0 ) \&|" "$INIT"
elif [ "$DROPBEAR_DELAY" != "0" ]; then
    echo "!! dropbear start line not found (or already patched) — skipping delay patch"
fi

HOOK_CALL='[ -x /autoinstall-hook.sh ] && /autoinstall-hook.sh'
if [ -f "$INIT" ] && grep -q '/autoinstall-hook.sh' "$INIT"; then
    echo ">>> $INIT_SCRIPT already calls the hook"
elif [ -n "$INIT_ANCHOR" ] && [ -f "$INIT" ] && grep -qF "$INIT_ANCHOR" "$INIT"; then
    echo ">>> Inserting hook call after anchor: $INIT_ANCHOR"
    awk -v anchor="$INIT_ANCHOR" -v call="$HOOK_CALL" '
        {print}
        index($0, anchor){print call}
    ' "$INIT" > "$INIT.new" && mv "$INIT.new" "$INIT"
    chmod 755 "$INIT"
else
    echo "!! ----------------------------------------------------------------"
    echo "!! $INIT_SCRIPT NOT auto-patched (anchor not found). Confirm INIT_ANCHOR"
    echo "!! against the real script, or add this line after 'rc.dropbear start':"
    echo "!!     $HOOK_CALL"
    echo "!! Building the initrd WITHOUT the auto-run hook for now."
    echo "!! ----------------------------------------------------------------"
fi

# --- Repack ----------------------------------------------------------------
echo ">>> Repacking -> $OUT_INITRD"
mkdir -p "$(dirname "$OUT_INITRD")"
( cd "$ROOTDIR" && find . | cpio -o -H newc --quiet | $RECOMP ) > "$OUT_INITRD"
echo ">>> Done: $OUT_INITRD ($(du -h "$OUT_INITRD" | cut -f1))"
