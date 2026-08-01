#!/bin/bash
#
# This script created with Anthropic Fable
#
# autoinstall.sh — non-interactive Slackware install for cluster nodes.
#
# Runs INSIDE the PXE-booted Slackware installer environment (which already
# provides bash, gptfdisk/sgdisk, dosfstools, lvm2, mkinitrd, and installpkg).
# It BYPASSES Slackware's interactive `setup` and performs the same underlying
# steps directly, while reusing the project tagfiles to decide which packages to
# install. Result: a minimal Slackware node that boots on its own and is
# reachable by Ansible, which then deploys the cluster software.
#
#   Flow:  partition → LVM → mkfs → installpkg (from tagfiles) → chroot config
#          → grub (UEFI; grub-mkconfig→geninitrd builds the initrd) → reboot
#
# Per-node specialization is intentionally tiny: HOSTNAME + ROLE (compute|storage).
# Networking is left at DHCP for first-boot reachability; Ansible applies the real
# bond/VLAN config (rc.inet1.conf.j2) afterward.
#
# SAFETY: this ERASES the role's OS disk. It refuses to run unless CONFIRM=yes.
#
set -euo pipefail

# The Slackware installer env does NOT put /usr/sbin on PATH, so tools like
# partprobe and grub-install (chrooted, which inherits this PATH) aren't found.
# Set a known-good PATH. (Confirmed on hardware: mkinitrd in /sbin worked, but
# grub-install in /usr/sbin failed until /usr/sbin was on PATH.)
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

############################################################################
# Configuration — edit defaults here; per-node values come from the kernel
# command line (node.role=, node.name=, node.cfg=URL) so one image serves all.
############################################################################

# Frozen Slackware mirror, mounted into the installer env by the PXE setup
# (NFS export from node 7 is simplest, so the package tree can be globbed).
#   Expected layout:  $SRCDIR/slackware64/{a,ap,d,l,n,tcl,x}/*.txz
SRCDIR="${SRCDIR:-/source}"

# Tagset source. Two ways to supply it; TAGDIR (local) takes precedence:
#   TAGDIR  — a local directory of tagfiles ($TAGDIR/<series>/tagfile). Handy for a
#             manual/offline run, or the USB bootstrap of node 7 where there's no
#             tagset server yet. Not set by default.
#   TAG_URL — base URL; node 7 serves the project tagsets under
#             /tagsets/<set>/<series>/tagfile (see caddy-pxe.conf). Tagfiles are
#             fetched PER-SERIES at install time rather than baked into the initrd,
#             so they stay in sync with the frozen mirror as slackware-current
#             churns — no initrd rebuild to update them. Passed on the cmdline as
#             tag.url= (boot.ipxe builds it from the boot server); node.cfg can
#             override it (e.g. node 7 itself uses the mini-dev-gui set).
# At least one of the two must be set.
TAGDIR="${TAGDIR:-}"
TAG_URL="${TAG_URL:-}"

# Install series, in dependency order (intersected with the tagset's series).
# Overridable like SRCDIR/TAG_URL. 'k' (kernel source) is omitted by default.
SERIES_ORDER="${SERIES_ORDER:-a ap d l n tcl x xap xfce}"

# installpkg tag handling — CONFIRMED on hardware: with `--tagfile` and NO `--menu`,
# only ADD packages install and SKP are skipped, with no prompts. (`--menu` would
# instead prompt on everything not ADD.) So PKG_MENU stays empty.
PKG_MENU="${PKG_MENU:-}"

# installpkg output style: --terse (default; one line per package, log-friendly),
# --infobox (ncurses progress dialog), or empty "" for the full per-package
# description.
PKG_OUTPUT="${PKG_OUTPUT:---terse}"

# Partition sizing (tunable).
EFI_SIZE="${EFI_SIZE:-128MiB}"      # EFI System Partition (only GRUB lives here)
SYSTEM_SIZE="${SYSTEM_SIZE:-80GiB}" # vg_system PV; root LV is a slice of this,
ROOT_LV_SIZE="${ROOT_LV_SIZE:-64GiB}"  #   leaving the remainder free for snapshots
ROOT_FS="${ROOT_FS:-ext4}"

# p3 (rest of the OS disk) is TYPED but otherwise left untouched — no PV/VG is
# created on it. Incus/LINSTOR build their own VG or zpool there later (e.g.
# `linstor physical-storage create-device-pool`). DATA_PART_TYPE just sets the
# GPT type code so the partition reads as what it's destined for:
#   lvm — 8e00 (Linux LVM)    zfs — bf01 (Solaris/ZFS; what zpool labels disks)
DATA_PART_TYPE="${DATA_PART_TYPE:-lvm}"

# Per-node identity (overridden by kernel cmdline / node.cfg).
NODE_ROLE="${NODE_ROLE:-}"          # compute | storage  (REQUIRED)
NODE_NAME="${NODE_NAME:-}"          # hostname           (REQUIRED)

# Access bootstrap. The installed system must NOT come up with passwordless root.
# By default root's password is LOCKED and the box is managed as clusteradm via
# SSH key + NOPASSWD sudo. At least ONE access method below must be set, or the
# script aborts before touching the disk.
CLUSTERADM_UID="1050"
CLUSTERADM_PUBKEY="${CLUSTERADM_PUBKEY:-}"   # clusteradm ssh public key (key-only login)
CLUSTERADM_PW="${CLUSTERADM_PW:-}"           # clusteradm password (optional console login)
ROOT_PW="${ROOT_PW:-}"                       # set → root password; empty → root LOCKED
NTP_SERVER="${NTP_SERVER:-pool.ntp.org}"

# Timezone for the installed system. Use a zoneinfo name EXACTLY as it appears
# under /usr/share/zoneinfo (underscores, not spaces), e.g. "America/New_York".
# Set per-node in node.cfg; defaults to UTC. HWCLOCK says whether the machine's
# hardware (RTC) clock reads UTC or local time — UTC is recommended for servers.
TIMEZONE="${TIMEZONE:-UTC}"
HWCLOCK="${HWCLOCK:-UTC}"            # UTC | localtime

# secure_path for clusteradm's sudo (written to /etc/sudoers.d/clusteradm).
# Includes /opt/go/bin: the project's Go package installs to /opt/go-<ver> with an
# /opt/go symlink (kept separate from Slackware's go), present on all nodes.
CLUSTERADM_SECURE_PATH="${CLUSTERADM_SECURE_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/go/bin}"

# Extra boot services to enable, space-separated, WITHOUT the "rc." prefix
# (e.g. ENABLE_SERVICES="rpc nfsd serial"). Each sets the execute bit on
# /etc/rc.d/rc.<name>. sshd + ntpd are always enabled. Run `ls /etc/rc.d` on a
# node to see what's available. Only ever SETS the bit — never clears one.
ENABLE_SERVICES="${ENABLE_SERVICES:-}"

# Last-chance abort window shown after validation, right before the disk is erased.
#   unset         — block until ENTER is pressed (safe default for manual runs).
#   CANCEL_DELAY=0  — no delay, no prompt (unattended PXE installs via node.cfg).
#   CANCEL_DELAY=N  — sleep N seconds then proceed; Ctrl-C during the window aborts.
CANCEL_DELAY="${CANCEL_DELAY:-}"

# Pre-built base image for faster deployment (optional). When either is set,
# deploy_image() is used instead of install_packages() — the package base was
# already installed by imageinstall.sh and archived. configure_system and the
# bootloader still run per-node after extraction; only the slow install_packages
# step is skipped. Set via node.cfg or the kernel cmdline.
#   IMAGE_URL  — fetch over HTTP (wget); e.g. http://node7:8080/images/base.tar.xz
#   IMAGE_PATH — local file; e.g. an NFS path already mounted at /source/images/
IMAGE_URL="${IMAGE_URL:-}"
IMAGE_PATH="${IMAGE_PATH:-}"

TARGET="/mnt"                       # where the new system is assembled

############################################################################
# Helpers
############################################################################
log()  { echo ">>> $*"; }
die()  { echo "!!! $*" >&2; exit 1; }

cancel_window() {
    log "WILL ERASE $OS_DISK  node='$NODE_NAME'  role=$NODE_ROLE"
    if [ -z "${CANCEL_DELAY:-}" ]; then
        log "Press ENTER to proceed, or Ctrl-C to abort."
        read -r _
    elif [ "$CANCEL_DELAY" -gt 0 ] 2>/dev/null; then
        log "Proceeding in ${CANCEL_DELAY}s — Ctrl-C to abort."
        sleep "$CANCEL_DELAY"
    fi
    # CANCEL_DELAY=0: fall through immediately, no message.
}

deploy_image() {
    local img tmpimg=""
    if [ -n "$IMAGE_URL" ]; then
        tmpimg="$(mktemp)"
        log "Fetching image: $IMAGE_URL"
        wget -O "$tmpimg" "$IMAGE_URL" || die "failed to fetch image: $IMAGE_URL"
        img="$tmpimg"
    else
        img="$IMAGE_PATH"
        [ -f "$img" ] || die "image not found: $img"
    fi
    log "Extracting image to $TARGET"
    tar -xJpf "$img" -C "$TARGET"
    if [ -n "$tmpimg" ]; then rm -f "$tmpimg"; fi
}

load_node_config() {
    # Pull node.role / node.name / node.cfg from the kernel command line.
    for tok in $(cat /proc/cmdline); do
        case "$tok" in
            node.role=*) NODE_ROLE="${tok#node.role=}" ;;
            node.name=*) NODE_NAME="${tok#node.name=}" ;;
            node.cfg=*)  NODE_CFG="${tok#node.cfg=}" ;;
            tag.url=*)   TAG_URL="${tok#tag.url=}" ;;
        esac
    done
    # Optional: fetch a per-node config file (e.g. from the MAC->node map on node 7)
    # that can set any of the variables above, including CLUSTERADM_PUBKEY.
    if [ -n "${NODE_CFG:-}" ]; then
        log "Fetching node config: $NODE_CFG"
        wget -qO /tmp/node.cfg "$NODE_CFG" || die "failed to fetch node config: $NODE_CFG"
        source /tmp/node.cfg
    fi

    [ -n "$NODE_ROLE" ] || die "NODE_ROLE not set (node.role=compute|storage)"
    [ -n "$NODE_NAME" ] || die "NODE_NAME not set (node.name=<hostname>)"
    [ -n "$TAGDIR" ] || [ -n "$TAG_URL" ] \
        || die "no tagset source — set TAGDIR=<local path> or tag.url=http://<node7>/tagsets/<set>"

    # Refuse to build a box with no access (it'd be locked out) or, worse, the
    # default passwordless root. Require at least one access method. (Check here,
    # before partition_disk, so we abort before erasing anything.)
    if [ -z "$ROOT_PW" ] && [ -z "$CLUSTERADM_PW" ] && [ -z "$CLUSTERADM_PUBKEY" ]; then
        die "no access method set — provide CLUSTERADM_PUBKEY and/or CLUSTERADM_PW (preferred), or ROOT_PW"
    fi
    [ -n "$CLUSTERADM_PUBKEY" ] || log "note: no CLUSTERADM_PUBKEY — clusteradm won't be key-reachable for Ansible"

    case "$NODE_ROLE" in
        compute) OS_DISK="/dev/nvme0n1" ;;   # OS on NVMe; that's the only disk
        storage) OS_DISK="/dev/sda" ;;       # OS on SATA; NVMe left raw for passthrough
        *) die "Unknown NODE_ROLE '$NODE_ROLE' (expected compute|storage)" ;;
    esac
    case "$DATA_PART_TYPE" in
        lvm|zfs) ;;
        *) die "Unknown DATA_PART_TYPE '$DATA_PART_TYPE' (expected lvm|zfs)" ;;
    esac
    [ -b "$OS_DISK" ] || die "OS disk $OS_DISK not present"
    log "Node $NODE_NAME role=$NODE_ROLE  OS disk=$OS_DISK"
}

############################################################################
# Disk: partition + LVM + filesystems
############################################################################
partition_disk() {
    log "Wiping and partitioning $OS_DISK"
    # Tear down any existing LVM so re-runs are clean. (wipefs isn't in the
    # Slackware installer env; sgdisk --zap-all clears GPT+MBR, and pvcreate -ff /
    # mkfs -F below force past any stale signatures.)
    vgchange -an >/dev/null 2>&1 || true
    sgdisk --zap-all "$OS_DISK"

    # p1 EFI, p2 system PV, p3 incus data (rest of disk; typed per
    # DATA_PART_TYPE, otherwise untouched — see the config note above)
    local p3_code
    case "$DATA_PART_TYPE" in
        zfs) p3_code="bf01" ;;
        *)   p3_code="8e00" ;;
    esac
    sgdisk -n1:0:+"$EFI_SIZE"    -t1:ef00 -c1:"EFI"    "$OS_DISK"
    sgdisk -n2:0:+"$SYSTEM_SIZE" -t2:8e00 -c2:"system" "$OS_DISK"
    sgdisk -n3:0:0               -t3:"$p3_code" -c3:"incus" "$OS_DISK"
    sync; partprobe "$OS_DISK"; sleep 2

    # Partition device names differ for nvme (p1) vs sd (1).
    case "$OS_DISK" in
        *nvme*) P1="${OS_DISK}p1"; P2="${OS_DISK}p2"; P3="${OS_DISK}p3" ;;
        *)      P1="${OS_DISK}1";  P2="${OS_DISK}2";  P3="${OS_DISK}3"  ;;
    esac

    # p3 is handed over bare, so clear stale LVM/ZFS labels from any previous
    # install here (the old `pvcreate -ff` on p3 used to bulldoze them, and
    # wipefs isn't in the installer env). LVM's label sits in the first sectors;
    # ZFS keeps two of its four labels at the END of the partition, so zero
    # both edges. Size read from sysfs (in 512-byte sectors) to avoid needing
    # blockdev. Downstream tools that refuse non-empty devices rely on this.
    local p3_sectors
    p3_sectors="$(cat "/sys/class/block/$(basename "$P3")/size")"
    dd if=/dev/zero of="$P3" bs=512 count=16384
    dd if=/dev/zero of="$P3" bs=512 seek=$((p3_sectors - 16384)) count=16384
    sync
}

setup_lvm_fs() {
    log "Creating LVM + filesystems"
    # System VG: root LV is a slice; remainder of the VG stays free for snapshots
    # taken before a base-OS update (lvcreate -s).
    pvcreate -ff -y "$P2"
    vgcreate vg_system "$P2"
    lvcreate -y -L "$ROOT_LV_SIZE" -n lv_root vg_system

    # p3 stays bare (typed per DATA_PART_TYPE) — Incus/LINSTOR/ZFS create their
    # own VG or zpool on it after the node joins the cluster.

    # Filesystems
    mkfs."$ROOT_FS" -F /dev/vg_system/lv_root
    mkfs.vfat -F32 "$P1"

    # Mount target tree
    mount /dev/vg_system/lv_root "$TARGET"
    mkdir -p "$TARGET/boot/efi"
    mount "$P1" "$TARGET/boot/efi"
}

############################################################################
# Packages: install the tagfile-selected set from the frozen mirror
############################################################################
install_packages() {
    # installpkg reads the tagfile to decide ADD vs SKP. See the PKG_MENU note
    # above — the exact --menu interaction is unverified and must be tested. The
    # *.txz glob expands in sorted order, so aaa_* install first (glibc-solibs dep).
    #
    # Tagfile per series, from TAGDIR (local) or fetched from TAG_URL. A missing
    # tagfile (no local file / 404) means "no tagfile for this series" and skips it,
    # so the tagset only needs the series it actually selects.
    [ -d "$SRCDIR/slackware64" ] || die "Package tree not found at $SRCDIR/slackware64"
    local tagtmp=""
    if [ -z "$TAGDIR" ]; then
        tagtmp="$(mktemp -d)"
    fi
    for series in $SERIES_ORDER; do
        local dir="$SRCDIR/slackware64/$series"
        local tag
        if [ -n "$TAGDIR" ]; then
            tag="$TAGDIR/$series/tagfile"
            [ -f "$tag" ] || { log "skip series '$series' (no tagfile at $tag)"; continue; }
        else
            tag="$tagtmp/$series.tagfile"
            if ! wget -qO "$tag" "$TAG_URL/$series/tagfile"; then
                log "skip series '$series' (no tagfile at $TAG_URL/$series/tagfile)"
                rm -f "$tag"
                continue
            fi
        fi
        [ -d "$dir" ] || die "missing series dir $dir"
        log "Installing series '$series'"
        installpkg --root "$TARGET" $PKG_OUTPUT $PKG_MENU --tagfile "$tag" "$dir"/*.txz
    done
    # Clean up the fetched-tagfile scratch dir (network path only). Use an `if`, not
    # `[ -n "$tagtmp" ] && rm …`: as the function's LAST statement that idiom returns
    # 1 when $tagtmp is empty (the TAGDIR/local path), which under `set -e` aborts the
    # script right after packages install — before configure_system (test 11).
    if [ -n "$tagtmp" ]; then
        rm -rf "$tagtmp"
    fi
}

############################################################################
# Configure the installed system (inside a chroot)
############################################################################
configure_system() {
    log "Configuring installed system"
    local efi_uuid root_dev
    efi_uuid="$(blkid -s UUID -o value "$P1")"
    root_dev="/dev/vg_system/lv_root"

    # fstab
    cat > "$TARGET/etc/fstab" <<EOF
$root_dev          /          $ROOT_FS  defaults              1 1
UUID=$efi_uuid     /boot/efi  vfat      defaults              0 0
devpts             /dev/pts   devpts    gid=5,mode=620        0 0
proc               /proc      proc      defaults              0 0
tmpfs              /dev/shm   tmpfs     defaults              0 0
EOF

    # Identity
    echo "$NODE_NAME.cluster.local" > "$TARGET/etc/HOSTNAME"
    cat > "$TARGET/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.0.1   $NODE_NAME.cluster.local $NODE_NAME
EOF

    # Networking: DHCP on the onboard NIC for first-boot reachability.
    # Ansible replaces this with the real bond/VLAN config (rc.inet1.conf.j2).
    cat > "$TARGET/etc/rc.d/rc.inet1.conf" <<'EOF'
IFNAME[0]="eth0"
USE_DHCP[0]="yes"
EOF

    # NTP (their builds are time-sensitive)
    sed -i "s/^server .*/server $NTP_SERVER iburst/" "$TARGET/etc/ntp.conf" 2>/dev/null || true

    # Timezone — mirror Slackware's timeconfig non-interactively:
    #   /etc/localtime -> /usr/share/zoneinfo/$TIMEZONE   (symlink, like setzone())
    #   /etc/hardwareclock + /etc/adjtime tell rc.S how the RTC is stored.
    if [ -e "$TARGET/usr/share/zoneinfo/$TIMEZONE" ]; then
        log "Timezone $TIMEZONE (hardware clock: $HWCLOCK)"
        ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$TARGET/etc/localtime"
        rm -f "$TARGET/etc/localtime-copied-from"
        case "$HWCLOCK" in
            localtime) hwc="localtime"; adj="LOCAL" ;;
            *)         hwc="UTC";       adj="UTC"   ;;
        esac
        printf '0.0 0 0.0\n0\n%s\n' "$adj" > "$TARGET/etc/adjtime"
        cat > "$TARGET/etc/hardwareclock" <<EOF
# /etc/hardwareclock
#
# Tells how the hardware clock time is stored.
# You should run timeconfig to edit this file.

$hwc
EOF
    else
        log "!! TIMEZONE '$TIMEZONE' not found in target zoneinfo — leaving timezone unset"
    fi

    # clusteradm account + sudo + SSH key so Ansible can take over
    chroot "$TARGET" /usr/sbin/useradd -u "$CLUSTERADM_UID" -g users -G wheel \
        -m -s /bin/bash clusteradm
    if [ -n "$CLUSTERADM_PUBKEY" ]; then
        # Create the dir + key file with the host (paths resolve fine), set modes,
        # then fix ownership INSIDE the chroot — clusteradm only exists in the
        # target's passwd, not the installer env, so host `chown -o clusteradm`
        # fails with "unknown user" (test 8).
        mkdir -p "$TARGET/home/clusteradm/.ssh"
        chmod 700 "$TARGET/home/clusteradm/.ssh"
        echo "$CLUSTERADM_PUBKEY" > "$TARGET/home/clusteradm/.ssh/authorized_keys"
        chmod 600 "$TARGET/home/clusteradm/.ssh/authorized_keys"
        chroot "$TARGET" chown -R clusteradm:users /home/clusteradm/.ssh
    fi
    # Passwordless sudo for clusteradm via a drop-in (cleaner than editing the main
    # /etc/sudoers; Slackware's sudoers includes /etc/sudoers.d). Only clusteradm
    # gets it — not all of wheel. sudoers.d files MUST be mode 0440, root-owned.
    install -d -m755 "$TARGET/etc/sudoers.d"
    cat > "$TARGET/etc/sudoers.d/clusteradm" <<EOF
Defaults secure_path="$CLUSTERADM_SECURE_PATH"
clusteradm ALL=(ALL:ALL) NOPASSWD: ALL
EOF
    chmod 0440 "$TARGET/etc/sudoers.d/clusteradm"
    chroot "$TARGET" visudo -cf /etc/sudoers.d/clusteradm >/dev/null \
        || log "!! WARNING: /etc/sudoers.d/clusteradm failed visudo syntax check"

    # --- Passwords: never leave the default passwordless root ---
    # root: locked (no password login) unless ROOT_PW is set. Manage as clusteradm.
    if [ -n "$ROOT_PW" ]; then
        echo "root:$ROOT_PW" | chroot "$TARGET" chpasswd
    else
        chroot "$TARGET" usermod -p '*' root          # '*' = no valid password (locked)
    fi
    # clusteradm: set a password if given; otherwise it stays locked-by-useradd
    # (key-only login, which is fine when CLUSTERADM_PUBKEY is set).
    if [ -n "$CLUSTERADM_PW" ]; then
        echo "clusteradm:$CLUSTERADM_PW" | chroot "$TARGET" chpasswd
    fi

    # Generate the CA certificate bundle so HTTPS verifies on the installed system.
    # installpkg --root doesn't run ca-certificates' post-install, so without this
    # wget/curl to https:// fail to verify certs (test 4: fetching ipxe.efi).
    chroot "$TARGET" update-ca-certificates --fresh >/dev/null 2>&1 \
        || log "!! update-ca-certificates failed — HTTPS may not verify certs"

    # --- SSH: make the box key-only ---
    # Slackware ships `UsePAM no`, under which OpenSSH does its OWN account check and
    # refuses ALL auth (incl. pubkey) to a locked-password account — which is exactly
    # our key-only clusteradm, so pubkey login silently failed (test 9/10). Enabling
    # PAM runs its account/session stage, which permits pubkey on locked accounts;
    # we also turn off every password-based path so the node stays key-only. This is
    # the combo the stock sshd_config's own UsePAM comment recommends. Appended
    # because the stock directives are all commented, so ours are the first (active)
    # occurrence and win. Requires PAM-enabled sshd (Slackware 15+; confirmed).
    log "Hardening sshd: UsePAM + key-only"
    cat >> "$TARGET/etc/ssh/sshd_config" <<'EOF'

# --- cluster provisioning: key-only login (see node/provisioning/README.md) ---
UsePAM yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF

    # --- Boot services: set the execute bit on /etc/rc.d/rc.<name> ---
    # Always enable sshd (Ansible/SSH; regenerates host keys on first boot) + ntpd
    # (time). Add more via ENABLE_SERVICES. Only ever SETS the bit, never clears.
    local f
    for svc in sshd ntpd $ENABLE_SERVICES; do
        f="$TARGET/etc/rc.d/rc.$svc"
        if [ -f "$f" ]; then
            chmod +x "$f"
            log "service enabled: rc.$svc"
        else
            log "!! service rc.$svc not found in /etc/rc.d — skipping (package not installed?)"
        fi
    done
}

############################################################################
# Bootloader: initrd for LVM root + GRUB (UEFI)
############################################################################
install_bootloader() {
    log "Installing GRUB (UEFI)"
    # Bind mounts so chrooted tools (grub-install, grub-mkconfig→geninitrd,
    # efibootmgr) work,
    # including EFI variable access for the NVRAM boot entry. (Matches the known-
    # good set from intake/mounts.sh, incl. /dev/shm.)
    for d in /proc /dev /dev/pts /dev/shm /sys; do mount --bind "$d" "$TARGET$d"; done
    mount --bind /sys/firmware/efi/efivars "$TARGET/sys/firmware/efi/efivars" 2>/dev/null || true

    # grub-mkconfig calls Slackware's geninitrd, which needs `strings` (binutils)
    # to inspect the kernel. If binutils is missing (mini-gui tags it SKP),
    # geninitrd silently fails and grub.cfg ends up with no real initrd → the
    # system panics mounting root. Ensure binutils is present. (Best fix is to
    # mark binutils ADD in the tagfile; this is the safety net.)
    if [ ! -x "$TARGET/usr/bin/strings" ]; then
        local bpkg
        bpkg="$(ls "$SRCDIR"/slackware64/d/binutils-*.txz 2>/dev/null | head -1)"
        if [ -n "$bpkg" ]; then
            log "binutils missing in target — installing $(basename "$bpkg") for geninitrd"
            installpkg --root "$TARGET" "$bpkg" >/dev/null
        else
            die "binutils not in target and not found in mirror; grub initrd would fail"
        fi
    fi

    # GRUB for UEFI.
    chroot "$TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --bootloader-id=Slackware --recheck
    chroot "$TARGET" grub-mkconfig -o /boot/grub/grub.cfg

    # grub-mkconfig's automatic initrd handling does NOT reliably produce a working
    # initrd, so build it explicitly with Slackware's geninitrd (test 3: without
    # this the system panics on root mount; running geninitrd by hand fixed it).
    # Needs binutils/strings, ensured above.
    log "Generating initrd with geninitrd"
    chroot "$TARGET" geninitrd /boot/vmlinuz
}

############################################################################
# Main — guarded so sourcing this file (e.g. from imageinstall.sh) loads the
# functions without triggering the install.
############################################################################
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    [ "$(id -u)" -eq 0 ] || die "must run as root"
    [ "${CONFIRM:-no}" = "yes" ] || die "refusing to erase disks: set CONFIRM=yes to proceed"

    load_node_config
    cancel_window
    partition_disk
    setup_lvm_fs
    if [ -n "$IMAGE_URL" ] || [ -n "$IMAGE_PATH" ]; then
        deploy_image
    else
        install_packages
    fi
    configure_system
    install_bootloader

    log "Done. Unmounting and rebooting into $NODE_NAME ($NODE_ROLE)."
    sync
    umount -R "$TARGET" || true
    vgchange -an || true
    sync
    # reboot -f: immediate reboot(2), bypassing the installer init's ::shutdown
    # sequence. NOTE: this runs in the installer env, NOT in a chroot.
    reboot -f
    # Fallback: reboot -f has been seen NOT to take effect when autoinstall.sh is run
    # manually over SSH in the installer env (test 3). If we're still here, force an
    # immediate reboot via magic sysrq (disks already synced + unmounted above).
    sleep 3
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
    echo b > /proc/sysrq-trigger 2>/dev/null || true
fi
