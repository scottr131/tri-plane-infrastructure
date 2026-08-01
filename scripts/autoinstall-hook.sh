#!/bin/sh
#
# This script created with Anthropic Fable
#
# autoinstall-hook.sh — lives inside the customized installer initrd. The
# installer's `init` calls it after networking is up. It self-gates: it only does
# anything when `autoinstall=1` is on the kernel command line, so a normal boot
# (USB bootstrap of node 7, or any debug boot) falls straight through to the
# interactive installer.
#
# Requires networking already up — pass `nic=auto:eth0:dhcp` on the cmdline so the
# installer's init brings the NIC up BEFORE this hook runs.

AUTO=0; SRC=""
for tok in $(cat /proc/cmdline); do
    case "$tok" in
        autoinstall=1) AUTO=1 ;;
        slack.src=*)   SRC="${tok#slack.src=}" ;;
    esac
done

[ "$AUTO" = "1" ] || exit 0   # interactive boot — let init continue normally

echo "=== autoinstall hook ==="

# Mount the NFS package tree where autoinstall.sh expects it (its SRCDIR=/source).
# DHCP on eth0 can still be settling when this hook runs, so the first mount often
# hits "Network is unreachable". Retry for up to ~30s rather than a fixed sleep, so
# we proceed the moment the NIC is ready and only wait the full timeout on a real
# failure.
if [ -n "$SRC" ]; then
    mkdir -p /source
    echo ">>> mounting package source: $SRC -> /source"
    tries=30
    until mount -t nfs -o ro,nolock "$SRC" /source 2>/dev/null; do
        tries=$((tries - 1))
        if [ "$tries" -le 0 ]; then
            echo "!! NFS mount still failing after ~30s — last error:"
            mount -t nfs -o ro,nolock "$SRC" /source   # run once more, unmuted
            echo "!! dropping to a shell"
            exec /bin/sh
        fi
        sleep 1
    done
fi

# Hand off. autoinstall.sh reads node.cfg=/node.role=/node.name= from the cmdline
# itself. CONFIRM=yes is required by autoinstall.sh; the autoinstall=1 cmdline flag
# above is the real guard against an accidental destructive run.
echo ">>> launching autoinstall.sh"
CONFIRM=yes exec /autoinstall.sh
