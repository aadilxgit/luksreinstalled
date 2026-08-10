#!/usr/bin/env bash
set -euo pipefail

[[ ${_REINSTALL_DEBOOTSTRAP_SH:-0} == 1 ]] && return 0
_REINSTALL_DEBOOTSTRAP_SH=1

# Second install engine (--method debootstrap). Instead of booting the d-i
# kernel — which intermittently deadlocks on some KVM hosts during early USB
# init — this engine builds a custom initramfs from the HOST's own kernel
# (proven reliable) and runs debootstrap from inside it, so the running system
# never has to be unmounted. The engine runs unattended as an initramfs
# init-bottom hook: partition → LUKS (temporary key) → LVM → debootstrap →
# system config → grub-install → postinstall → reboot into the new system.
#
# The staged GRUB entry, arm, confirm, cancel, and reboot machinery is shared
# with the installer method (lib/handoff.sh) — the engine kernel + initramfs
# are staged under the same /boot/reinstall paths.

# Packages that must exist on the host so the engine initramfs can embed them.
# python3: initrd content verification (verify_initrd_content).
DEBOOTSTRAP_APT_PKGS=(debootstrap parted cryptsetup-bin lvm2 python3)
# Packages debootstrap installs inside the new system (mirrors the d-i
# pkgsel/include list; apt-listchanges omitted — the postinstall worker does
# not use it).
DEBOOTSTRAP_INCLUDE='linux-image-amd64,grub-pc,openssh-server,cryptsetup,cryptsetup-initramfs,dropbear-initramfs,lvm2,sudo,ufw,fail2ban,python3-systemd,unattended-upgrades,ca-certificates,ifupdown'

# Pure: dotted netmask -> prefix in REPLY (also used to bake the engine's
# network fallback). Rejects non-contiguous masks.
netmask_prefix() {  # $1 = dotted netmask
    local n=0 o IFS=. seen_zero=0
    for o in $1; do
        case $o in
            255) ((seen_zero)) && return 1; n=$((n + 8)) ;;
            254) ((seen_zero)) && return 1; n=$((n + 7)) ;;
            252) ((seen_zero)) && return 1; n=$((n + 6)) ;;
            248) ((seen_zero)) && return 1; n=$((n + 5)) ;;
            240) ((seen_zero)) && return 1; n=$((n + 4)) ;;
            224) ((seen_zero)) && return 1; n=$((n + 3)) ;;
            192) ((seen_zero)) && return 1; n=$((n + 2)) ;;
            128) ((seen_zero)) && return 1; n=$((n + 1)) ;;
            0) seen_zero=1 ;;
            *) return 1 ;;
        esac
    done
    REPLY=$n
}

# Pure renderers — the engine receives these blocks via its env file.
render_engine_fstab() {  # root / boot / swap (tmpfs lines are appended by the postinstall worker)
    : "${TARGET_DISK:?}"
    cat <<EOF
/dev/mapper/vg_crypt-root / ext4 defaults 0 1
/dev/mapper/vg_crypt-swap none swap sw 0 0
${TARGET_DISK}2 /boot ext4 defaults 0 2
EOF
}

render_engine_interfaces() {
    : "${PRIMARY_IFACE:?}" "${IPV4_ADDR:?}" "${NETMASK:?}" "${GATEWAY:?}" "${DNS_SERVERS:?}"
    cat <<EOF
auto lo
iface lo inet loopback

auto $PRIMARY_IFACE
iface $PRIMARY_IFACE inet static
    address $IPV4_ADDR
    netmask $NETMASK
    gateway $GATEWAY
    dns-nameservers $DNS_SERVERS
EOF
}

render_engine_hosts() {
    : "${HOSTNAME:?}" "${DOMAIN:?}"
    cat <<EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME.$DOMAIN $HOSTNAME

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
}

render_engine_resolv() {
    : "${DNS_SERVERS:?}"
    local ns
    for ns in $DNS_SERVERS; do printf 'nameserver %s\n' "$ns"; done
}

# Writes $WORKDIR/debootstrap.env: every fact + rendered block the engine
# needs. POSIX single-quoted values (the engine runs under busybox ash, which
# would not parse bash %q output); values containing a single quote are
# rejected rather than mishandled.
render_engine_env() {  # $1 = output path
    local fstab interfaces hosts resolv
    fstab=$(render_engine_fstab)
    interfaces=$(render_engine_interfaces)
    hosts=$(render_engine_hosts)
    resolv=$(render_engine_resolv)
    netmask_prefix "$NETMASK" || die "invalid netmask: $NETMASK"
    local prefix=$REPLY
    env_line() {
        local k=$1 v=$2
        case $v in *"'"*) die "value for $k contains a single quote" ;; esac
        printf '%s=%s\n' "$k" "'$v'"
    }
    {
        env_line TARGET_DISK "$TARGET_DISK"
        env_line IFACE "$PRIMARY_IFACE"
        env_line IPV4 "$IPV4_ADDR"
        env_line NETMASK "$NETMASK"
        env_line NETMASK_PREFIX "$prefix"
        env_line GATEWAY "$GATEWAY"
        env_line DNS_SERVERS "$DNS_SERVERS"
        env_line DEBIAN_SUITE "$DEBIAN_SUITE"
        env_line MIRROR "$MIRROR"
        env_line BOOT_SIZE_MB "$BOOT_SIZE_MB"
        env_line SWAP_SIZE_MB "$SWAP_SIZE_MB"
        env_line HOSTNAME "$HOSTNAME"
        env_line DOMAIN "$DOMAIN"
        env_line TIMEZONE "$TIMEZONE"
        env_line TMPPW "$TMPPW"
        env_line STAGE_DEV "${BOOT_DEV:-}"
        env_line DEBOOTSTRAP_INCLUDE "$DEBOOTSTRAP_INCLUDE"
        env_line FSTAB "$fstab"
        env_line INTERFACES "$interfaces"
        env_line HOSTS "$hosts"
        env_line RESOLV "$resolv"
    } > "$1"
    chmod 600 "$1"
}

debootstrap_cmdline() {  # sets + prints CMDLINE; no preseed args, just console + static ip
    : "${IPV4_ADDR:?}" "${GATEWAY:?}" "${NETMASK:?}" "${PRIMARY_IFACE:?}"
    CMDLINE="nomodeset console=ttyS0,115200n8 console=tty0 ip=$IPV4_ADDR::$GATEWAY:$NETMASK::$PRIMARY_IFACE:off"
    printf '%s\n' "$CMDLINE"
}

debootstrap_plan() {  # --dry-run summary; no side effects
    debootstrap_cmdline >/dev/null
    cat <<EOF
method: debootstrap (custom initramfs on the host kernel — no d-i kernel)
target: ${TARGET_DISK:-?} (${BOOT_MODE:-?}) → [biosgrub 1M] [boot ${BOOT_SIZE_MB:-1024}M ext4] [LUKS→vg_crypt: root(rest) ext4, swap ${SWAP_SIZE_MB:-4096}M]
network: ${PRIMARY_IFACE:-?} ${IPV4_ADDR:-?} via ${GATEWAY:-?} dns=${DNS_SERVERS:-?}
suite: ${DEBIAN_SUITE:-trixie} mirror: ${MIRROR:-?}
engine cmdline: $CMDLINE
steps:
  1. rescue-copy the staged kernel+initrd off the old root
  2. partition ${TARGET_DISK:-?} as GPT (biosgrub / boot / LUKS)  3. LUKS (temp key) + LVM + filesystems
  4. debootstrap ${DEBIAN_SUITE:-trixie}   5. fstab / crypttab / interfaces / hostname
  6. grub-install   7. postinstall (passphrase rotation, admin user, dropbear, hardening)
  8. verify + reboot → LUKS prompt on console or dropbear ssh root@${IPV4_ADDR:-?}
EOF
}

# Host must be able to build the engine initramfs; missing tool packages are
# installed automatically (this is the same class of change as the tool's
# GRUB staging — the host is being replaced anyway).
debootstrap_preflight() {
    local pkg missing=() cmd
    for pkg in "${DEBOOTSTRAP_APT_PKGS[@]}"; do
        case $pkg in
            cryptsetup-bin) cmd=cryptsetup ;;
            lvm2) cmd=lvm ;;
            *) cmd=$pkg ;;
        esac
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if ((${#missing[@]})); then
        log_warn "host missing engine tools: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive run apt-get install -y --no-install-recommends "${missing[@]}" || die "failed to install host packages: ${missing[*]}"
    fi
    for cmd in mkinitramfs debootstrap parted partprobe cryptsetup pvcreate vgcreate lvcreate vgchange mkfs.ext4 mkswap blkid dpkg wget ip python3; do
        require_cmd "$cmd"
    done
    [[ -d /usr/share/initramfs-tools ]] || die "initramfs-tools is not installed on the host"
    [[ -f /etc/ssl/certs/ca-certificates.crt ]] || die "host is missing /etc/ssl/certs/ca-certificates.crt (needed by the embedded wget)"
    [[ -f /usr/share/debootstrap/functions && -d /usr/share/debootstrap/scripts ]] || die "debootstrap is incomplete on the host"
}

# Writes the static engine script (embedded below). The engine runs as an
# initramfs init-bottom hook under busybox ash: it is sourced by /init, so it
# must not set -e or exit — everything runs inside a subshell and every
# failure path blocks forever (visible on the console) until the user
# power-cycles. All runtime values come from /etc/reinstall-debootstrap.env.
write_engine_script() {  # $1 = output path
    cat >"$1" <<'ENGINE'
#!/bin/sh
# Debian LUKS reinstall engine (debootstrap method). Runs as an initramfs
# init-bottom hook on the HOST's own kernel — no d-i kernel involved, so the
# intermittent early-boot deadlock of the d-i kernel on some KVM hosts is
# avoided entirely. Sourced by /init inside a subshell: never exit, never
# set -e; failures block forever so the console keeps the log visible.

export PATH=/sbin:/bin:/usr/sbin:/usr/bin

log() {
    printf '[engine] %s %s\n' "$(date -u +%FT%TZ 2>/dev/null || echo '?')" "$*" | tee -a /engine.log >/dev/console
}
fail() {
    log "FAILED: $*"
    log "Engine halted. Power-cycle via the provider panel. At GRUB:"
    log "  - 'Debian LUKS reinstall (retry)'  → re-run the engine (it resumes),"
    log "  - the new system's entry           → the install actually finished."
    while :; do sleep 3600; done
}

main() {
    . /etc/reinstall-debootstrap.env 2>/dev/null || fail "engine config /etc/reinstall-debootstrap.env missing"
    for v in TARGET_DISK IFACE IPV4 NETMASK NETMASK_PREFIX GATEWAY DNS_SERVERS BOOT_SIZE_MB SWAP_SIZE_MB HOSTNAME TIMEZONE TMPPW DEBOOTSTRAP_INCLUDE FSTAB INTERFACES HOSTS RESOLV; do
        eval "test -n \"\${$v:-}\"" || fail "engine config missing $v"
    done
    log "start: target=$TARGET_DISK suite=$DEBIAN_SUITE mirror=$MIRROR"
    udevadm settle 2>/dev/null || true

    # --- network (the ip= cmdline normally did this; verify, else manual) ---
    if ! ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q 'inet '; then
        ip link set "$IFACE" up || fail "cannot bring up $IFACE"
        ip addr add "$IPV4/$NETMASK_PREFIX" dev "$IFACE" 2>/dev/null || true
        ip route add default via "$GATEWAY" dev "$IFACE" 2>/dev/null || true
    fi
    : > /etc/resolv.conf
    for ns in $DNS_SERVERS; do printf 'nameserver %s\n' "$ns" >> /etc/resolv.conf; done
    ip route show default | grep -q . || fail "no default route"

    # --- rescue net: copy the staged kernel+initrd OFF the old root before it
    #     is destroyed, so a mid-install crash still leaves a bootable retry ---
    if [ -n "${STAGE_DEV:-}" ]; then
        mkdir -p /oldroot
        mount -o ro "$STAGE_DEV" /oldroot 2>/dev/null || true
        for d in /oldroot/boot/reinstall /oldroot/reinstall; do
            if [ -f "$d/linux" ] && [ -f "$d/initrd.preseed.gz" ]; then
                mkdir -p /rescue
                cp "$d/linux" /rescue/linux
                cp "$d/initrd.preseed.gz" /rescue/initrd.gz
                log "rescue kernel+initrd copied to /rescue"
                break
            fi
        done
        umount -l /oldroot 2>/dev/null || true
    fi

    # --- partition (first run only; resume path skips straight to open) ---
    if ! cryptsetup isLuks "${TARGET_DISK}3" 2>/dev/null; then
        log "partitioning $TARGET_DISK (gpt: biosgrub + boot ${BOOT_SIZE_MB}M + LUKS)"
        parted -s "$TARGET_DISK" -- mklabel gpt \
            mkpart biosgrub 1MiB 2MiB \
            set 1 bios_grub on \
            mkpart boot 2MiB "$((BOOT_SIZE_MB + 2))MiB" \
            mkpart crypt "$((BOOT_SIZE_MB + 2))MiB" 100% || fail "parted failed"
        partprobe "$TARGET_DISK" || true
        sleep 3
        udevadm settle 2>/dev/null || true
        [ -b "${TARGET_DISK}3" ] || fail "partition ${TARGET_DISK}3 did not appear"
        printf '%s' "$TMPPW" > /run/tmp.key
        chmod 600 /run/tmp.key
        cryptsetup luksFormat --type luks2 --batch-mode --key-file=/run/tmp.key "${TARGET_DISK}3" || fail "luksFormat failed"
        log "LUKS container created (temporary key; rotated to the user passphrase at postinstall)"
    else
        log "existing LUKS detected on ${TARGET_DISK}3 — resuming"
        printf '%s' "$TMPPW" > /run/tmp.key
        chmod 600 /run/tmp.key
    fi

    # --- LUKS + LVM + filesystems ---
    LUKS_UUID=$(cryptsetup luksUUID "${TARGET_DISK}3") || fail "cannot read LUKS UUID"
    cryptsetup open "${TARGET_DISK}3" cryptroot --key-file=/run/tmp.key || fail "cryptsetup open failed"
    vgchange -ay 2>/dev/null || true
    if [ ! -e /dev/vg_crypt/root ]; then
        log "creating vg_crypt (swap ${SWAP_SIZE_MB}M + root rest)"
        pvcreate -ff -y /dev/mapper/cryptroot >/dev/null 2>&1 || fail "pvcreate failed"
        vgcreate vg_crypt /dev/mapper/cryptroot >/dev/null 2>&1 || fail "vgcreate failed"
        lvcreate -L "${SWAP_SIZE_MB}M" -n swap vg_crypt >/dev/null 2>&1 || fail "lvcreate swap failed"
        lvcreate -l 100%FREE -n root vg_crypt >/dev/null 2>&1 || fail "lvcreate root failed"
    fi
    [ -e /dev/vg_crypt/swap ] || fail "swap LV missing"
    [ "$(blkid -s TYPE -o value /dev/vg_crypt/root 2>/dev/null)" = ext4 ] || { mkfs.ext4 -q /dev/vg_crypt/root || fail "mkfs root failed"; log "root filesystem created"; }
    [ "$(blkid -s TYPE -o value "${TARGET_DISK}2" 2>/dev/null)" = ext4 ] || { mkfs.ext4 -q "${TARGET_DISK}2" || fail "mkfs boot failed"; log "boot filesystem created"; }
    [ "$(blkid -s TYPE -o value /dev/vg_crypt/swap 2>/dev/null)" = swap ] || mkswap /dev/vg_crypt/swap >/dev/null || fail "mkswap failed"

    mkdir -p /mnt /mnt/boot /mnt/dev /mnt/proc /mnt/sys /mnt/run
    mount /dev/vg_crypt/root /mnt || fail "cannot mount root"
    mount "${TARGET_DISK}2" /mnt/boot || fail "cannot mount boot"
    mount --bind /dev /mnt/dev || fail "bind /dev failed"
    mount --bind /proc /mnt/proc || fail "bind /proc failed"
    mount --bind /sys /mnt/sys || fail "bind /sys failed"
    mount --bind /run /mnt/run || fail "bind /run failed"
    if [ -e /mnt/etc/reinstall-done ]; then
        fail "target already carries a finished install (marker /etc/reinstall-done)"
    fi

    # resolv.conf + hosts must exist before debootstrap stage 2 so its apt
    # update can resolve the mirror.
    printf '%s\n' "$RESOLV" > /mnt/etc/resolv.conf
    printf '%s\n' "$HOSTS" > /mnt/etc/hosts

    # --- rescue boot entry on the new /boot (hand-written grub.cfg — the real
    #     one comes from grub-install + update-grub later) ---
    if [ -d /rescue ]; then
        mkdir -p /mnt/boot/rescue
        cp /rescue/linux /mnt/boot/rescue/linux
        cp /rescue/initrd.gz /mnt/boot/rescue/initrd.gz
    fi
    mkdir -p /mnt/boot/grub
    if [ ! -e /mnt/boot/grub/grub.cfg ]; then
        cat > /mnt/boot/grub/grub.cfg <<EOF
set timeout=10
set default=0
menuentry "Debian LUKS reinstall (retry)" {
	linux /rescue/linux nomodeset console=ttyS0,115200n8 console=tty0 ip=$IPV4::$GATEWAY:$NETMASK::$IFACE:off
	initrd /rescue/initrd.gz
}
EOF
        log "rescue grub.cfg written"
    fi

    # --- debootstrap (resumes if stage 1 completed) ---
    if [ ! -e /mnt/etc/debian_version ]; then
        log "debootstrap $DEBIAN_SUITE from $MIRROR (this takes a while)"
        DEBIAN_FRONTEND=noninteractive /usr/sbin/debootstrap \
            --include="$DEBOOTSTRAP_INCLUDE" \
            "$DEBIAN_SUITE" /mnt "$MIRROR" || fail "debootstrap failed"
        log "debootstrap complete"
    fi

    # --- system config (fstab/crypttab/interfaces/hostname/timezone) ---
    printf '%s\n' "$FSTAB" > /mnt/etc/fstab
    printf 'vg_crypt UUID=%s none luks\n' "$LUKS_UUID" > /mnt/etc/crypttab
    printf '%s\n' "$INTERFACES" > /mnt/etc/network/interfaces
    printf '%s\n' "$HOSTNAME" > /mnt/etc/hostname
    printf '%s\n' "$TIMEZONE" > /mnt/etc/timezone
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /mnt/etc/localtime
    printf 'GRUB_DISABLE_OS_PROBER=true\n' >> /mnt/etc/default/grub
    log "system config written (fstab/crypttab/interfaces/hostname)"

    # --- bootloader ---
    [ -x /mnt/usr/sbin/grub-install ] || fail "grub-install missing in target (debootstrap include failed?)"
    chroot /mnt /usr/sbin/grub-install "$TARGET_DISK" || fail "grub-install failed"
    log "grub-install complete"

    # --- postinstall: passphrase rotation, admin user, dropbear, hardening ---
    mkdir -p /mnt/root
    cp /etc/reinstall-payload/postinstall.sh /mnt/root/vps-postinstall.sh
    cp /etc/reinstall-payload/secrets.env /mnt/root/vps-secrets.env
    chmod 700 /mnt/root/vps-postinstall.sh
    chmod 600 /mnt/root/vps-secrets.env
    log "running postinstall inside the new system"
    if ! chroot /mnt /bin/sh -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; /root/vps-postinstall.sh' > /mnt/var/log/vps-postinst.log 2>&1; then
        fail "postinstall failed — see /var/log/vps-postinst.log on the new root"
    fi
    log "postinstall complete"

    # --- verification ---
    [ -s /mnt/etc/crypttab ] || fail "crypttab missing"
    grep -q 'vg_crypt' /mnt/etc/crypttab || fail "crypttab missing vg_crypt mapping"
    [ -s /mnt/boot/grub/grub.cfg ] || fail "grub.cfg missing"
    LV_UUID=$(blkid -s UUID -o value /dev/vg_crypt/root) || fail "cannot read root fs UUID"
    grep -q "root=UUID=$LV_UUID" /mnt/boot/grub/grub.cfg || grep -q 'root=/dev/mapper/vg_crypt-root' /mnt/boot/grub/grub.cfg || fail "grub.cfg does not point at the vg_crypt root"
    ls /mnt/boot/vmlinuz-* >/dev/null 2>&1 || fail "no kernel installed"
    ls /mnt/boot/initrd.img-* >/dev/null 2>&1 || fail "no initramfs installed"
    ls /mnt/etc/dropbear/initramfs/*host_key >/dev/null 2>&1 || fail "dropbear initramfs host key missing (remote unlock not armed)"
    log "verification passed"

    # --- persistent retry entry (survives future update-grub runs) ---
    cat > /mnt/etc/grub.d/40_custom <<EOF
#!/bin/sh
exec tail -n +3 "\$0"
# This file provides an easy way to add custom menu entries.  Simply type the
# menu entries you want to add after this comment.
menuentry "Debian LUKS reinstall (retry)" {
	linux /rescue/linux nomodeset console=ttyS0,115200n8 console=tty0 ip=$IPV4::$GATEWAY:$NETMASK::$IFACE:off
	initrd /rescue/initrd.gz
}
EOF
    chroot /mnt /usr/sbin/update-grub || fail "update-grub failed"

    printf 'engine finished %s\n' "$(date -u +%FT%TZ)" > /mnt/etc/reinstall-done
    cp /engine.log /mnt/var/log/engine.log 2>/dev/null || true
    log "DONE — rebooting into the new system. Unlock with the LUKS passphrase on the console, or: ssh root@$IPV4 (dropbear, port 22)"
    sync
    sleep 2
    reboot
    fail "reboot did not happen"
}
( main )
ENGINE
    chmod 700 "$1"
}

# Temporary initramfs-tools hook: embeds the engine + its tools into an
# initramfs built from the host's own kernel. Runs once at build time.
write_initramfs_hook() {  # $1 = hook path
    local hook=$1 p_part p_probe p_crypt p_pv p_vg p_lv p_vgc p_mkfs p_swap p_blkid p_dbs p_dpkg p_wget p_ip
    p_part=$(command -v parted) || die "missing parted"
    p_probe=$(command -v partprobe) || die "missing partprobe"
    p_crypt=$(command -v cryptsetup) || die "missing cryptsetup"
    p_pv=$(command -v pvcreate) || die "missing pvcreate"
    p_vg=$(command -v vgcreate) || die "missing vgcreate"
    p_lv=$(command -v lvcreate) || die "missing lvcreate"
    p_vgc=$(command -v vgchange) || die "missing vgchange"
    p_mkfs=$(command -v mkfs.ext4) || die "missing mkfs.ext4"
    p_swap=$(command -v mkswap) || die "missing mkswap"
    p_blkid=$(command -v blkid) || die "missing blkid"
    p_dbs=$(command -v debootstrap) || die "missing debootstrap"
    p_dpkg=$(command -v dpkg) || die "missing dpkg"
    p_wget=$(command -v wget) || die "missing wget"
    p_ip=$(command -v ip) || die "missing ip"
    cat >"$hook" <<EOF
#!/bin/sh
# Temporary hook generated by reinstall.sh --method debootstrap; removed after
# the engine initramfs is built.
. /usr/share/initramfs-tools/hook-functions
PREREQS=""
manual_add_modules $NIC_MODULE lpc_ich iTCO_wdt
copy_exec $p_part /sbin/
copy_exec $p_probe /sbin/
copy_exec $p_crypt /sbin/
copy_exec $p_pv /sbin/
copy_exec $p_vg /sbin/
copy_exec $p_lv /sbin/
copy_exec $p_vgc /sbin/
copy_exec $p_mkfs /sbin/
copy_exec $p_swap /sbin/
copy_exec $p_blkid /sbin/
copy_exec $p_dbs /usr/sbin/
copy_exec $p_dpkg /usr/bin/
copy_exec $p_wget /usr/bin/
copy_exec $p_ip /bin/
mkdir -p \$DESTDIR/usr/share/debootstrap
cp -a /usr/share/debootstrap/functions \$DESTDIR/usr/share/debootstrap/
cp -a /usr/share/debootstrap/scripts \$DESTDIR/usr/share/debootstrap/
mkdir -p \$DESTDIR/etc/dpkg \$DESTDIR/etc/ssl/certs
cp -a /etc/dpkg/. \$DESTDIR/etc/dpkg/
cp -a /etc/ssl/certs/ca-certificates.crt \$DESTDIR/etc/ssl/certs/ 2>/dev/null || true
mkdir -p \$DESTDIR/etc/reinstall-payload
cp $WORKDIR/debootstrap.env \$DESTDIR/etc/reinstall-debootstrap.env
cp $WORKDIR/payload/opt/reinstall/postinstall.sh \$DESTDIR/etc/reinstall-payload/
cp $WORKDIR/payload/opt/reinstall/secrets.env \$DESTDIR/etc/reinstall-payload/
chmod 600 \$DESTDIR/etc/reinstall-debootstrap.env \$DESTDIR/etc/reinstall-payload/secrets.env
chmod 700 \$DESTDIR/etc/reinstall-payload/postinstall.sh
mkdir -p \$DESTDIR/scripts/init-bottom \$DESTDIR/scripts/init-top
cp $WORKDIR/engine.sh \$DESTDIR/scripts/init-bottom/zz-reinstall-engine
chmod 755 \$DESTDIR/scripts/init-bottom/zz-reinstall-engine
cp $WORKDIR/payload/scripts/init-top/zz-watchdog-pet \$DESTDIR/scripts/init-top/zz-watchdog-pet
chmod 755 \$DESTDIR/scripts/init-top/zz-watchdog-pet
EOF
    chmod 755 "$hook"
}

# Pure: locate the host kernel+initrd for a version. Debian keeps the real
# files in /boot and only sometimes exposes /vmlinuz symlinks, so /boot is
# checked first. $2/$3 allow tests to substitute directories.
resolve_host_kernel() {  # $1 = kver, $2 = boot dir (default /boot), $3 = root dir (default /)
    local kver=$1 bootdir=${2:-/boot} rootdir=${3:-/} l i
    for l in "$bootdir/vmlinuz-$kver" "$rootdir/vmlinuz-$kver"; do [[ -f $l ]] && break; done
    for i in "$bootdir/initrd.img-$kver" "$rootdir/initrd.img-$kver"; do [[ -f $i ]] && break; done
    [[ -f $l && -f $i ]] || return 1
    printf '%s %s\n' "$l" "$i"
}

# The host's initramfs-tools may compress with zstd/xz/lz4/bzip2 or not at
# all (COMPRESS= in /etc/initramfs-tools/initramfs.conf), and GRUB on older
# hosts cannot load all of those (notably lz4). The staged initrd is always
# recompressed to gzip so any GRUB's gzio module can load it. Source
# integrity is verified with the matching checker first. Returns 1 with a
# message on stderr on any failure; never leaves a partial $2 behind.
normalize_initrd_to_gzip() {  # $1 = source, $2 = dest
    local src=$1 dst=$2 magic tool
    magic=$(head -c 6 "$src" | od -An -tx1 | tr -d ' \n')
    case $magic in
        1f8b*)        tool=gzip ;;
        28b52ffd*)    tool=zstd ;;
        fd377a585a00) tool=xz ;;
        425a68*)      tool=bzip2 ;;
        04224d18*)    tool=lz4 ;;
        894c5a4f*)    tool=lzop ;;
        30373037*)    tool=cat ;;  # uncompressed newc cpio
        *) echo "initrd: unrecognized compression magic ($magic) in $src" >&2; return 1 ;;
    esac
    if [[ $tool != cat ]]; then
        command -v "$tool" >/dev/null 2>&1 || { echo "initrd: $src is $tool-compressed but $tool is not installed" >&2; return 1; }
        "$tool" -t "$src" 2>/dev/null || { echo "initrd: $src failed $tool integrity check" >&2; return 1; }
    fi
    if [[ $tool == cat ]]; then
        cat "$src" | gzip -1 > "$dst"
    else
        "$tool" -cd "$src" 2>/dev/null | gzip -1 > "$dst"
    fi || { echo "initrd: decompression of $src failed" >&2; rm -f "$dst"; return 1; }
    gzip -t "$dst" 2>/dev/null || { echo "initrd: gzip recompression of $src failed" >&2; rm -f "$dst"; return 1; }
}

# Content check: the staged initrd must decompress to parseable newc cpio
# containing an executable /init. GNU cpio -t stops at the first TRAILER!!!
# (it cannot list the second member of a concatenated archive — Debian images
# prepend an early-microcode member), so this walks ALL members with a small
# python3 parser that mirrors the kernel: namesize includes the NUL, entries
# are 4-byte aligned on the cumulative offset, and after TRAILER!!! the next
# member is tried at both 4-alignment (dracut-style) and the 512-byte block
# boundary (cpio). Trailing zero padding ends the walk. On failure, prints
# what it saw to stderr for diagnosis. Catches a broken engine archive at
# build time, before the reboot.
verify_initrd_content() {  # $1 = gzip-compressed initrd
    zcat "$1" 2>/dev/null | python3 -c '
import sys
data = sys.stdin.buffer.read()
i, n = 0, len(data)
count = 0
seen = []
err = None
while i + 110 <= n:
    if data[i:i+6] != b"070701":
        err = "bad magic at offset %d: %r" % (i, data[i:i+6])
        break
    hdr = data[i:i+110]
    nlen = int(hdr[94:102], 16)
    name = data[i+110:i+110+nlen].rstrip(b"\x00").decode("utf-8", "replace")
    count += 1
    if len(seen) < 5:
        seen.append(name)
    if name == "TRAILER!!!":
        i += 110 + nlen
        j = (i + 3) & ~3   # 4-aligned (dracut-style concatenation)
        if j + 6 <= n and data[j:j+6] == b"070701":
            i = j
        else:
            k = (i + 511) & ~511  # 512-byte block (cpio concatenation)
            if k + 6 <= n and data[k:k+6] == b"070701":
                i = k
            else:
                i = n  # trailing zero padding: no more members
        continue
    if name in ("init", "./init") and int(hdr[14:22], 16) & 0o111:
        sys.exit(0)  # /init present and executable
    i += 110 + nlen
    i = (i + 3) & ~3
    i += int(hdr[54:62], 16)
    i = (i + 3) & ~3
if err:
    print("initrd check failed: %s after %d entries (first: %r)" % (err, count, seen), file=sys.stderr)
    sys.exit(2)
print("initrd check failed: no executable /init among %d entries (first: %r)" % (count, seen), file=sys.stderr)
sys.exit(1)
'
}

# Builds the engine kernel+initrd pair into $WORKDIR/linux and
# $WORKDIR/initrd.preseed.gz (same staging paths the installer method uses,
# so stage_boot_entry / cancel_handoff work unchanged).
build_debootstrap_initramfs() {
    : "${WORKDIR:?}"
    [[ -n ${NIC_MODULE:-} ]] || die "NIC_MODULE not detected"
    local kver hook linux_src initrd_src pair
    kver=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1)
    [[ -n $kver ]] || die "no kernels under /lib/modules"
    pair=$(resolve_host_kernel "$kver") || die "host kernel files for $kver missing (checked /boot/vmlinuz-$kver, /boot/initrd.img-$kver and their / symlinks)"
    read -r linux_src initrd_src <<< "$pair"
    detect_boot_grub_facts  # fills BOOT_DEV for STAGE_DEV
    render_engine_env "$WORKDIR/debootstrap.env"
    write_engine_script "$WORKDIR/engine.sh"
    write_watchdog_pet_hook "$WORKDIR/payload"  # reuse the same pet hook as the installer payload
    hook=/etc/initramfs-tools/hooks/zz-reinstall-engine
    write_initramfs_hook "$hook"
    trap 'rm -f "$hook"' RETURN
    run mkinitramfs -o "$WORKDIR/initrd.tmp" "$kver"
    rm -f "$hook"
    cp "$linux_src" "$WORKDIR/linux"
    normalize_initrd_to_gzip "$WORKDIR/initrd.tmp" "$WORKDIR/initrd.preseed.gz" \
        || die "engine initrd failed integrity check"
    verify_initrd_content "$WORKDIR/initrd.preseed.gz" \
        || die "engine initrd is not a valid cpio archive containing /init — rebuild failed"
    rm -f "$WORKDIR/initrd.tmp"
    log_info "engine initramfs built: kernel $kver, initrd $(stat -c%s "$WORKDIR/initrd.preseed.gz") bytes"
}

do_debootstrap_handoff() {
    debootstrap_preflight
    build_debootstrap_initramfs
    debootstrap_cmdline >/dev/null
    stage_boot_entry "$CMDLINE"
    arm_next_boot
    confirm_handoff || die "confirmation declined"
    execute_handoff
    exit 0
}
