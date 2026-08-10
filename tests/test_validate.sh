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
