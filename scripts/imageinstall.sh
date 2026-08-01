#!/bin/bash
#
# This script created with Anthropic Fable
#
# imageinstall.sh — build a base Slackware image tarball (tar.xz) for fast
# node deployment.
#
# Installs the tagfile-selected package set into a scratch directory, then
# archives it. The result can be deployed by autoinstall.sh at provision time
# (set IMAGE_URL or IMAGE_PATH) instead of installing packages from the mirror
# series by series — skipping the slow per-package install step.
#
# configure_system and the bootloader are NOT baked into the image; they run
# per-node at deploy time so node identity (hostname, SSH keys, accounts) stays
# out of the image. The image is a clean, reusable package base.
#
# Run as root on node 7 or the build server (installpkg requires root).
# The mirror and tagset must be accessible the same way as for autoinstall.sh.
#
# Usage:
#   SRCDIR=/srv/slackware/slackware64-current \
#   TAGDIR=/srv/slackware/tagsets/mini-gui    \
#   IMAGE_OUT=/srv/slackware/images/base-mini-gui.tar.xz \
#   ./imageinstall.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source autoinstall.sh to get shared functions: install_packages, log, die.
# The BASH_SOURCE guard in autoinstall.sh prevents its main section from running.
. "$SCRIPT_DIR/autoinstall.sh"

############################################################################
# imageinstall-specific config
############################################################################

# Derive a human-readable tagset name from TAGDIR or TAG_URL for the default
# output filename. Override by setting TAGSET_NAME or IMAGE_OUT directly.
if [ -n "$TAGDIR" ]; then
    TAGSET_NAME="${TAGSET_NAME:-$(basename "$TAGDIR")}"
elif [ -n "$TAG_URL" ]; then
    TAGSET_NAME="${TAGSET_NAME:-$(basename "$TAG_URL")}"
else
    TAGSET_NAME="${TAGSET_NAME:-unknown}"
fi

# Output tarball path. Defaults to the current directory; override to drop the
# image where Caddy can serve it (e.g. /srv/slackware/images/).
IMAGE_OUT="${IMAGE_OUT:-./base-${TAGSET_NAME}.tar.xz}"

############################################################################
# Main
############################################################################
[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -n "$TAGDIR" ] || [ -n "$TAG_URL" ] \
    || die "no tagset source — set TAGDIR=<path> or TAG_URL=http://<node7>/tagsets/<set>"
[ -d "$SRCDIR/slackware64" ] \
    || die "package mirror not found at $SRCDIR/slackware64 — set SRCDIR"

TARGET="$(mktemp -d)"
trap 'rm -rf "$TARGET"' EXIT

log "Installing packages into $TARGET (tagset: $TAGSET_NAME)"
install_packages

log "Archiving → $IMAGE_OUT"
mkdir -p "$(dirname "$IMAGE_OUT")"
# -c create  -J xz  -p preserve permissions (suid bits etc.)  -f output file
# Paths are relative to TARGET so the archive extracts cleanly into any root.
tar -cJpf "$IMAGE_OUT" -C "$TARGET" .

log "Done: $IMAGE_OUT ($(du -h "$IMAGE_OUT" | cut -f1))"
