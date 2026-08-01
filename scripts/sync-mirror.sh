#!/bin/bash
#
# This script created with Anthropic Fable
#
# sync-mirror.sh — refresh node 7's frozen Slackware mirror for provisioning.
#
# Pulls a trimmed copy of slackware64-current from an upstream rsync mirror into a
# local directory that node 7 then NFS-exports (the package tree, for
# `installpkg --root` during install) and HTTP-serves (the boot kernel/initrd, for
# iPXE). Run it manually whenever you want to advance the freeze point; every node
# provisioned afterward installs from the same snapshot.
#
# Usage:  ./sync-mirror.sh [-n|--dry-run]
#
set -euo pipefail

############################################################################
# Configuration
############################################################################

# Upstream rsync mirror of slackware64-current. Slackware mirrors each expose
# their own rsync path, so swap this whole URL to change mirrors — e.g. point it
# at your own local copy (TrueNAS) instead of the public mirror. Keep the
# TRAILING SLASH: it copies the *contents* of slackware64-current into MIRROR_DIR.
UPSTREAM="${UPSTREAM:-rsync://plug-mirror.rcac.purdue.edu/slackware/slackware64-current/}"

# Local mirror directory on node 7 — NFS-exported (read-only) and HTTP-served.
# It must contain ONLY the upstream mirror: keep PXE-service artifacts (iPXE
# binaries, custom initrd, autoinstall.sh) ELSEWHERE, because `--delete` removes
# anything here that isn't upstream. After sync the package tree is at
# $MIRROR_DIR/slackware64/<series>/ (matches autoinstall.sh SRCDIR).
MIRROR_DIR="${MIRROR_DIR:-/srv/slackware/slackware64-current}"

# Paths we don't need for package install + PXE netboot:
#   EFI/      ISO/USB UEFI boot image — not needed (iPXE is our bootloader)
#   source/, testing/, extra/, pasture/, patches/ — bulk we don't install
# Kept (NOT excluded): slackware64/ (packages), kernels/ + isolinux/ (netboot
# bzImage + initrd.img), usb-and-pxe-installers/ (reference).
EXCLUDES=(
    "EFI/*"
    "extra/*"
    "pasture/*"
    "patches/*"
    "source/*"
    "testing/*"
)

# rsync options (mirrors the known-good command).
RSYNC_OPTS=(
    -havP
    --delete --delete-after
    --no-o --no-g
    --safe-links
    --timeout=60
)
# --contimeout only applies to rsync *daemon* connections; it errors on a
# local-path source. Add it only when UPSTREAM is an rsync:// URL (or host::module).
case "$UPSTREAM" in
    rsync://*|*::*) RSYNC_OPTS+=( --contimeout=30 ) ;;
esac

############################################################################
# Run
############################################################################
DRYRUN=()
case "${1:-}" in
    -n|--dry-run) DRYRUN=(--dry-run); echo ">>> DRY RUN — no changes will be made" ;;
    "")           ;;
    *)            echo "usage: $0 [-n|--dry-run]"; exit 1 ;;
esac

exclude_args=()
for e in "${EXCLUDES[@]}"; do exclude_args+=(--exclude "$e"); done

mkdir -p "$MIRROR_DIR"

echo ">>> Syncing $UPSTREAM"
echo ">>>    into $MIRROR_DIR"
rsync "${RSYNC_OPTS[@]}" "${DRYRUN[@]}" "${exclude_args[@]}" "$UPSTREAM" "$MIRROR_DIR/"

echo ">>> Done. Mirror size: $(du -sh "$MIRROR_DIR" 2>/dev/null | cut -f1)"
