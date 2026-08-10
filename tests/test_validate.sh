#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/lib/common.sh"
source "$root/lib/config.sh"
source "$root/lib/validate.sh"
source "$root/lib/detect.sh"
source "$root/lib/preseed.sh"
source "$root/lib/postinstall.sh"
source "$root/lib/initrd.sh"
source "$root/lib/handoff.sh"
pass(){ printf 'PASS %s\n' "$1"; }
validate_mirror_url https://deb.debian.org/debian && pass validate
BOOT_MODE=uefi BOOT_SIZE_MB=1024 SWAP_SIZE_MB=4096; recipe=$(build_recipe); [[ $recipe == *'768 1000 1024 ext4'* ]] && pass recipe
PRIMARY_IFACE=eth0; IPV4_ADDR=192.0.2.1; NETMASK=255.255.255.0; GATEWAY=192.0.2.254; DNS_SERVERS='1.1.1.1'; HOSTNAME=debian; DOMAIN=local; build_cmdline | grep -q 'console=ttyS0,115200n8 console=tty0 ---' && pass cmdline
entry=$(render_boot_entry 'auto=true console=ttyS0,115200n8 console=tty0 ---' 'AAAA-BBBB' part_gpt ext2 '')
for needle in '### BEGIN debian-luks-reinstall ###' 'menuentry "Debian LUKS Reinstall (staged)" --id debian-luks-reinstall' 'insmod part_gpt' 'insmod ext2' 'search --no-floppy --fs-uuid --set=root AAAA-BBBB' 'linux /reinstall/linux auto=true console=ttyS0,115200n8 console=tty0 ---' 'initrd /reinstall/initrd.preseed.gz' '### END debian-luks-reinstall ###'; do
  [[ $entry == *"$needle"* ]] || { echo "render_boot_entry (no prefix) missing: $needle"; exit 1; }
done
pass render_boot_entry_root
entry_boot=$(render_boot_entry 'auto=true console=ttyS0,115200n8 console=tty0 ---' 'AAAA-BBBB' part_gpt ext2 /boot)
[[ $entry_boot == *'linux /boot/reinstall/linux auto=true console=ttyS0,115200n8 console=tty0 ---'* ]] || { echo 'render_boot_entry (/boot prefix) missing linux line'; exit 1; }
[[ $entry_boot == *'initrd /boot/reinstall/initrd.preseed.gz'* ]] || { echo 'render_boot_entry (/boot prefix) missing initrd line'; exit 1; }
pass render_boot_entry_boot
BOOT_MODE=bios; [[ $(render_partition_tree) == *'[biosgrub 1M]'* && $(render_partition_tree) != *ESP* ]] || { echo 'render_partition_tree (bios) missing biosgrub'; exit 1; }
pass render_partition_tree_bios
BOOT_MODE=uefi; [[ $(render_partition_tree) == *'[ESP 538–1075M]'* ]] || { echo 'render_partition_tree (uefi) missing ESP'; exit 1; }
pass render_partition_tree_uefi
# A suppressed (below-LOG_LEVEL) message must never fail under errexit — the
# [[ ]] inside _log used to leak status 1 through log_debug -> run() and killed
# the script on the first real download step.
LOG_FILE=/tmp/reinstall-test.log; : >"$LOG_FILE"; LOG_LEVEL=INFO; log_debug "suppressed debug message"; pass log_debug_suppressed
# Config file must not clobber command-line flags (the LOG_FILE="" wipe bug).
LOG_FILE=/tmp/reinstall.log; ASSUME_YES=yes; config_pin LOG_FILE ASSUME_YES
load_config_file "$root/reinstall.conf.example"
[[ $LOG_FILE == /tmp/reinstall.log && $ASSUME_YES == yes ]] || { echo 'config file overrode pinned CLI values'; exit 1; }
pass config_pin_cli
# Blank config values must not blank out values set outside the file.
LOG_FILE=/tmp/keep.log; WORKDIR=/tmp/keep.work
load_config_file "$root/reinstall.conf.example"
[[ $LOG_FILE == /tmp/keep.log && $WORKDIR == /tmp/keep.work ]] || { echo 'blank config values clobbered runtime vars'; exit 1; }
pass config_blank_no_clobber
# Full payload assembly: artifacts are written straight into the payload tree
# by build_postinstall_artifacts; build_payload must not self-copy and must
# append a cpio containing every required file.
if command -v cpio >/dev/null && command -v gzip >/dev/null && command -v zcat >/dev/null; then
  WORKDIR=$(mktemp -d /tmp/reinstall-test.XXXXXX)
  printf 'd-i test\n' > "$WORKDIR/preseed.cfg"
  printf 'x' | gzip > "$WORKDIR/initrd.gz"
  TMPPW=tmpkey; LUKS_PASSPHRASE=testpass123; ADMIN_USER=cain; ADMIN_PUBKEYS='ssh-ed25519 AAA x'; SSH_PORT=2222; DROPBEAR_PORT=22; WEB_PORTS='80 443'; NIC_MODULE=ixgbe; ADMIN_PASSWORD_HASH='$6$x$y'
  build_postinstall_artifacts "$TMPPW"
  build_payload
  [[ -s "$WORKDIR/initrd.preseed.gz" && "$(stat -c %s "$WORKDIR/initrd.preseed.gz")" -gt "$(stat -c %s "$WORKDIR/initrd.gz")" ]] || { echo 'payload append failed'; exit 1; }
  pass payload_build
  rm -rf "$WORKDIR"
else
  echo 'SKIP payload_build (cpio/gzip/zcat missing)'
fi
