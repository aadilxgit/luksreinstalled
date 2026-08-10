#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${_REINSTALL_HANDOFF_SH:-}" ]]; then return 0; fi
_REINSTALL_HANDOFF_SH=1

# v2: GRUB one-time-boot handoff, replacing v1's kexec -l/-e. kexec jumps straight into
# the installer kernel without a platform/device reset, which can leave a KVM/QEMU
# guest's outgoing virtual GPU driver (bochs-drmfb) in a state the installer kernel's
# DRM probe never resolves. Staging a GRUB entry + a normal `reboot` lets the hypervisor
# reset devices before the installer kernel boots.

build_cmdline() {
    : "${PRIMARY_IFACE:?PRIMARY_IFACE is required}"
    : "${IPV4_ADDR:?IPV4_ADDR is required}"
    : "${NETMASK:?NETMASK is required}"
    : "${GATEWAY:?GATEWAY is required}"
    : "${DNS_SERVERS:?DNS_SERVERS is required}"
    : "${HOSTNAME:?HOSTNAME is required}"
    : "${DOMAIN:?DOMAIN is required}"
    CMDLINE="auto=true priority=critical DEBIAN_FRONTEND=text locale=en_US.UTF-8 keymap=us interface=$PRIMARY_IFACE netcfg/disable_autoconfig=true netcfg/get_ipaddress=$IPV4_ADDR netcfg/get_netmask=$NETMASK netcfg/get_gateway=$GATEWAY netcfg/get_nameservers=$DNS_SERVERS netcfg/confirm_static=true netcfg/get_hostname=$HOSTNAME netcfg/get_domain=$DOMAIN preseed/file=/preseed.cfg console=ttyS0,115200n8 console=tty0 ---"
    printf '%s\n' "$CMDLINE"
}

render_partition_tree() {
    local lead
    if [[ $BOOT_MODE == uefi ]]; then lead='[ESP 538–1075M]'; else lead='[biosgrub 1M]'; fi
    printf '%s → %s [/boot %sM ext4] [LUKS→vg_crypt→ root(rest) ext4, swap %sM]\n' "${TARGET_DISK:-<disk>}" "$lead" "${BOOT_SIZE_MB:-1024}" "${SWAP_SIZE_MB:-4096}"
}

# Impure collector (follows lib/detect.sh's *_collect convention): resolves the facts
# needed to render a self-contained GRUB menuentry for whichever filesystem backs /boot.
detect_boot_grub_facts() {
    local fstype pk pttype
    if mountpoint -q /boot; then
        BOOT_DEV=$(findmnt -no SOURCE /boot)
        GRUB_PATH_PREFIX=""
    else
        BOOT_DEV=$(findmnt -no SOURCE /)
        GRUB_PATH_PREFIX=/boot
    fi
    BOOT_FS_UUID=$(blkid -s UUID -o value "$BOOT_DEV" || true)
    [[ -n $BOOT_FS_UUID ]] || die "cannot determine UUID of boot device $BOOT_DEV"
    fstype=$(findmnt -no FSTYPE "$BOOT_DEV")
    case $fstype in
        ext2|ext3|ext4) BOOT_FS_MODULE=ext2 ;;
        xfs) BOOT_FS_MODULE=xfs ;;
        btrfs) BOOT_FS_MODULE=btrfs ;;
        *) die "unsupported /boot filesystem '$fstype' for GRUB staging" ;;
    esac
    pk=$(lsblk -no PKNAME "$BOOT_DEV" | head -n1)
    pttype=$(lsblk -no PTTYPE "/dev/$pk" 2>/dev/null || true)
    case $pttype in
        gpt) BOOT_PART_MODULE=part_gpt ;;
        dos) BOOT_PART_MODULE=part_msdos ;;
        *) die "unsupported partition table '$pttype' for GRUB staging" ;;
    esac
}

# Pure: no file I/O, no side effects — directly unit-testable with fixture values.
render_boot_entry() {  # $1=cmdline $2=boot_fs_uuid $3=part_module $4=fs_module $5=path_prefix
    local cmdline=$1 uuid=$2 partmod=$3 fsmod=$4 prefix=$5
    cat <<EOF
### BEGIN debian-luks-reinstall ###
menuentry "Debian LUKS Reinstall (staged)" --id debian-luks-reinstall {
	insmod $partmod
	insmod $fsmod
	search --no-floppy --fs-uuid --set=root $uuid
	linux ${prefix}/reinstall/linux $cmdline
	initrd ${prefix}/reinstall/initrd.preseed.gz
}
### END debian-luks-reinstall ###
EOF
}

# Require at least double the staged payload size, floored at 200MiB, free under /boot.
require_boot_space() {
    : "${WORKDIR:?WORKDIR is required}"
    local needed avail min
    needed=$(( $(stat -c%s "$WORKDIR/linux") + $(stat -c%s "$WORKDIR/initrd.preseed.gz") ))
    avail=$(df --output=avail -B1 /boot 2>/dev/null | tail -n1) || true
    [[ -n ${avail:-} ]] || avail=$(df --output=avail -B1 / | tail -n1)
    min=$(( needed * 2 > 200*1024*1024 ? needed * 2 : 200*1024*1024 ))
    (( avail >= min )) || die "insufficient space to stage installer under /boot (have ${avail}B, need >= ${min}B or 200MiB)"
}

# Highest-risk new function: mutates the running host's bootloader configuration.
stage_boot_entry() {
    require_cmd update-grub
    [[ -n ${BOOT_FS_UUID:-} ]] || detect_boot_grub_facts
    require_boot_space
    mkdir -p /boot/reinstall
    chmod 0700 /boot/reinstall
    run cp "$WORKDIR/linux" /boot/reinstall/linux
    run cp "$WORKDIR/initrd.preseed.gz" /boot/reinstall/initrd.preseed.gz
    chmod 0600 /boot/reinstall/linux /boot/reinstall/initrd.preseed.gz
    # shellcheck disable=SC2016  # "$0" must stay literal — it is written into the generated 40_custom script, to expand there at its own runtime, not here
    [[ -s /etc/grub.d/40_custom ]] || { printf '#!/bin/sh\nexec tail -n +3 "$0"\n' >/etc/grub.d/40_custom; chmod +x /etc/grub.d/40_custom; }
    sed -i '/^### BEGIN debian-luks-reinstall ###$/,/^### END debian-luks-reinstall ###$/d' /etc/grub.d/40_custom
    build_cmdline >/dev/null
    render_boot_entry "$CMDLINE" "$BOOT_FS_UUID" "$BOOT_PART_MODULE" "$BOOT_FS_MODULE" "$GRUB_PATH_PREFIX" >> /etc/grub.d/40_custom
    run update-grub
}

arm_next_boot() {
    require_cmd grub-reboot grub-editenv
    run grub-reboot debian-luks-reinstall
    run grub-editenv /boot/grub/grubenv list
}

# Reverses stage_boot_entry/arm_next_boot. Safe to call any time before execute_handoff
# actually reboots; harmless if nothing was ever staged.
cancel_handoff() {
    require_cmd update-grub grub-editenv
    [[ -f /etc/grub.d/40_custom ]] && sed -i '/^### BEGIN debian-luks-reinstall ###$/,/^### END debian-luks-reinstall ###$/d' /etc/grub.d/40_custom
    run update-grub
    run grub-editenv /boot/grub/grubenv unset next_entry
    rm -rf /boot/reinstall
    log_info "staged reinstall boot entry removed"
}

confirm_handoff() {
    local summary
    summary=$(render_partition_tree)
    log_info "network: ${IPV4_ADDR:-} / ${NETMASK:-} via ${GATEWAY:-} (${PRIMARY_IFACE:-})"
    log_info "target: ${TARGET_DISK:-} boot=${BOOT_MODE:-} suite=${DEBIAN_SUITE:-trixie} ports=${DROPBEAR_PORT:-22}/${SSH_PORT:-2222}"
    log_info "partition: $summary"
    [[ "${ASSUME_YES:-no}" == yes ]] && return 0
    confirm_yes "Type YES to wipe ${TARGET_DISK:-target disk} and reinstall"
}

execute_handoff() {
    log_warn "point of no return: rebooting into staged installer"
    sync
    reboot
}

do_handoff() {
    stage_boot_entry
    arm_next_boot
    confirm_handoff || die "confirmation declined"
    execute_handoff
    exit 0
}
