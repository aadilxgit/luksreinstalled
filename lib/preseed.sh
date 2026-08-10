#!/usr/bin/env bash
set -euo pipefail
[[ ${_PRESEED_SH_LOADED:-0} == 1 ]] && return 0
_PRESEED_SH_LOADED=1
# shellcheck disable=SC2016  # $iflabel{ }/$primary{ }/$lvmok{ }/etc. are literal partman-auto recipe DSL tokens, not shell variables — must stay single-quoted
build_recipe(){ local boot=$((BOOT_SIZE_MB-24)); local lead bootable=''; if [[ $BOOT_MODE == uefi ]]; then lead='538 538 1075 free $iflabel{ gpt } $reusemethod{ } method{ efi } format{ } .'; else lead='1 1 1 free $iflabel{ gpt } $reusemethod{ } method{ biosgrub } .'; bootable='$bootable{ }'; fi; printf '%s 768 %s %s ext4 $defaultignore{ } $primary{ } %s method{ format } format{ } use_filesystem{ } filesystem{ ext4 } mountpoint{ /boot } . 2000 2000 -1 ext4 $primary{ } method{ crypto } vg_name{ vg_crypt } . %s %s %s linux-swap $lvmok{ } in_vg{ vg_crypt } lv_name{ swap } method{ swap } format{ } . 4000 10000 -1 ext4 $lvmok{ } in_vg{ vg_crypt } lv_name{ root } method{ format } format{ } use_filesystem{ } filesystem{ ext4 } mountpoint{ / } .' "$lead" "$boot" "$BOOT_SIZE_MB" "$bootable" "$SWAP_SIZE_MB" "$SWAP_SIZE_MB" "$SWAP_SIZE_MB"; }
build_preseed(){ local tmp=$1 crypt=$2 mirror_host=${MIRROR#https://} mirror_dir=/debian; if [[ $mirror_host == */* ]]; then mirror_dir=/${mirror_host#*/}; mirror_host=${mirror_host%%/*}; fi; mkdir -p "$WORKDIR"; cat >"$WORKDIR/preseed.cfg" <<EOF
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select $PRIMARY_IFACE
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_ipaddress string $IPV4_ADDR
d-i netcfg/get_netmask string $NETMASK
d-i netcfg/get_gateway string $GATEWAY
d-i netcfg/get_nameservers string $DNS_SERVERS
d-i netcfg/confirm_static boolean true
d-i netcfg/get_hostname string $HOSTNAME
d-i netcfg/get_domain string $DOMAIN
d-i netcfg/hostname string $HOSTNAME
d-i mirror/country string manual
d-i mirror/protocol string https
d-i mirror/http/hostname string $mirror_host
d-i mirror/http/directory string $mirror_dir
d-i mirror/http/proxy string
d-i mirror/suite string $DEBIAN_SUITE
d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
d-i passwd/user-fullname string $ADMIN_USER
d-i passwd/username string $ADMIN_USER
d-i passwd/user-password-crypted password $crypt
d-i clock-setup/utc boolean true
d-i time/zone string $TIMEZONE
d-i clock-setup/ntp boolean true
d-i partman-auto/method string crypto
d-i partman-auto/disk string $TARGET_DISK
d-i partman-auto/expert_recipe string $(build_recipe)
d-i partman-auto-lvm/guided_size string max
d-i partman-auto-lvm/new_vg_name string vg_crypt
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-crypto/passphrase password $tmp
d-i partman-crypto/passphrase-again password $tmp
d-i partman-crypto/weak_passphrase boolean true
d-i partman-crypto/confirm boolean true
d-i partman-crypto/confirm_nooverwrite boolean true
d-i partman-auto-crypto/erase_disks boolean false
d-i partman-partitioning/choose_label select gpt
d-i partman-partitioning/default_label string gpt
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman-partitioning/confirm_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
$( [[ $BOOT_MODE == uefi ]] && echo 'd-i partman-efi/non_efi_system boolean true' )
d-i base-installer/install-recommends boolean false
d-i apt-setup/non-free-firmware boolean true
tasksel tasksel/first multiselect standard
d-i pkgsel/include string cryptsetup cryptsetup-initramfs dropbear-initramfs lvm2 sudo ufw fail2ban python3-systemd unattended-upgrades apt-listchanges openssh-server ca-certificates
d-i pkgsel/upgrade select full-upgrade
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string $TARGET_DISK
d-i finish-install/reboot_in_progress note
d-i preseed/late_command string /opt/reinstall/late.sh < /dev/null > /target/var/log/vps-postinst.log 2>&1
EOF
  if command -v debconf-set-selections >/dev/null 2>&1; then run debconf-set-selections -c "$WORKDIR/preseed.cfg" || die "generated preseed.cfg failed debconf-set-selections syntax check"; fi
}
