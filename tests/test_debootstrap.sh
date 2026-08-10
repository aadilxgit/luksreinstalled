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
source "$root/lib/debootstrap.sh"
pass(){ printf 'PASS %s\n' "$1"; }

netmask_prefix 255.255.255.0; [[ $REPLY == 24 ]] || { echo "netmask_prefix 255.255.255.0 -> $REPLY"; exit 1; }
netmask_prefix 255.255.0.0;   [[ $REPLY == 16 ]] || { echo "netmask_prefix 255.255.0.0 -> $REPLY"; exit 1; }
netmask_prefix 255.0.0.0;     [[ $REPLY == 8 ]]  || { echo "netmask_prefix 255.0.0.0 -> $REPLY"; exit 1; }
netmask_prefix 255.255.255.252; [[ $REPLY == 30 ]] || { echo "netmask_prefix /30 -> $REPLY"; exit 1; }
netmask_prefix 255.255.255.255; [[ $REPLY == 32 ]] || { echo "netmask_prefix /32 -> $REPLY"; exit 1; }
netmask_prefix 255.255.0.255 && { echo 'netmask_prefix accepted a non-contiguous mask'; exit 1; } || true
pass netmask_prefix

TARGET_DISK=/dev/vda; BOOT_SIZE_MB=1024; SWAP_SIZE_MB=4096
fstab=$(render_engine_fstab)
[[ $fstab == *'/dev/mapper/vg_crypt-root / ext4 defaults 0 1'* ]] || { echo 'fstab missing root line'; exit 1; }
[[ $fstab == *'/dev/mapper/vg_crypt-swap none swap sw 0 0'* ]] || { echo 'fstab missing swap line'; exit 1; }
[[ $fstab == *'/dev/vda2 /boot ext4 defaults 0 2'* ]] || { echo 'fstab missing boot line'; exit 1; }
pass render_engine_fstab

PRIMARY_IFACE=eth0; IPV4_ADDR=203.0.113.10; NETMASK=255.255.255.0; GATEWAY=203.0.113.1; DNS_SERVERS='1.1.1.1 1.0.0.1'
ifaces=$(render_engine_interfaces)
for needle in 'auto eth0' 'iface eth0 inet static' '    address 203.0.113.10' '    netmask 255.255.255.0' '    gateway 203.0.113.1' '    dns-nameservers 1.1.1.1 1.0.0.1'; do
  [[ $ifaces == *"$needle"* ]] || { echo "render_engine_interfaces missing: $needle"; exit 1; }
done
pass render_engine_interfaces

HOSTNAME=debian; DOMAIN=local
hosts=$(render_engine_hosts)
[[ $hosts == *'127.0.1.1 debian.local debian'* ]] || { echo 'render_engine_hosts missing host line'; exit 1; }
pass render_engine_hosts
resolv=$(render_engine_resolv)
[[ $resolv == $'nameserver 1.1.1.1\nnameserver 1.0.0.1' ]] || { echo "render_engine_resolv wrong: $resolv"; exit 1; }
pass render_engine_resolv

# env round-trip: POSIX single-quoted values must survive being sourced back.
DEBIAN_SUITE=trixie; MIRROR=https://deb.debian.org/debian; TIMEZONE=UTC; TMPPW=deadbeef; BOOT_DEV=/dev/vda
envf=$(mktemp /tmp/reinstall-engine-env.XXXXXX)
render_engine_env "$envf"
# shellcheck disable=SC1090
. "$envf"
[[ $TARGET_DISK == /dev/vda && $NETMASK_PREFIX == 24 && $DNS_SERVERS == '1.1.1.1 1.0.0.1' && $TMPPW == deadbeef ]] || { echo 'engine env round-trip failed'; exit 1; }
[[ $FSTAB == "$fstab" && $INTERFACES == "$ifaces" && $HOSTS == "$hosts" && $RESOLV == "$resolv" ]] || { echo 'engine env blocks differ from renderers'; exit 1; }
[[ $DEBOOTSTRAP_INCLUDE == *'dropbear-initramfs'* ]] || { echo 'engine env missing DEBOOTSTRAP_INCLUDE'; exit 1; }
rm -f "$envf"
pass render_engine_env

cmdl=$(debootstrap_cmdline)
[[ $cmdl == *'nomodeset console=ttyS0,115200n8 console=tty0 ip=203.0.113.10::203.0.113.1:255.255.255.0::eth0:off' ]] || { echo "debootstrap_cmdline wrong: $cmdl"; exit 1; }
pass debootstrap_cmdline

# Kernel resolution: real files live under /boot on Debian; / symlinks are optional.
kdir=$(mktemp -d /tmp/reinstall-kern.XXXXXX)
bootd="$kdir/boot"; rootd="$kdir/root"; mkdir -p "$bootd" "$rootd"
# case 1: files in /boot only
printf x > "$bootd/vmlinuz-6.1.0-test"; printf y > "$bootd/initrd.img-6.1.0-test"
pair=$(resolve_host_kernel 6.1.0-test "$bootd" "$rootd") || { echo 'resolve_host_kernel failed with /boot files'; exit 1; }
[[ $pair == "$bootd/vmlinuz-6.1.0-test $bootd/initrd.img-6.1.0-test" ]] || { echo "resolve_host_kernel wrong pair: $pair"; exit 1; }
# case 2: files at root only (no /boot copy)
printf x > "$rootd/vmlinuz-6.1.0-test"; printf y > "$rootd/initrd.img-6.1.0-test"
rm -f "$bootd/vmlinuz-6.1.0-test" "$bootd/initrd.img-6.1.0-test"
pair=$(resolve_host_kernel 6.1.0-test "$bootd" "$rootd") || { echo 'resolve_host_kernel failed with root files'; exit 1; }
[[ $pair == "$rootd/vmlinuz-6.1.0-test $rootd/initrd.img-6.1.0-test" ]] || { echo "resolve_host_kernel root pair wrong: $pair"; exit 1; }
# case 3: neither location
rm -f "$rootd/vmlinuz-6.1.0-test" "$rootd/initrd.img-6.1.0-test"
resolve_host_kernel 6.1.0-test "$bootd" "$rootd" && { echo 'resolve_host_kernel accepted missing files'; exit 1; } || true
rm -rf "$kdir"
pass resolve_host_kernel

# Initrd normalization: the host's COMPRESS setting must not leak into the
# staged initrd — always gzip, always verified.
nidir=$(mktemp -d /tmp/reinstall-initrd.XXXXXX)
head -c 262144 /dev/urandom > "$nidir/rand"
gzip -c "$nidir/rand" > "$nidir/in.gz"
normalize_initrd_to_gzip "$nidir/in.gz" "$nidir/out.gz" || { echo 'normalize failed on gzip input'; exit 1; }
gzip -t "$nidir/out.gz" || { echo 'normalized output is not gzip'; exit 1; }
if command -v zstd >/dev/null 2>&1; then
    zstd -q -c "$nidir/rand" > "$nidir/in.zst"
    normalize_initrd_to_gzip "$nidir/in.zst" "$nidir/out2.gz" || { echo 'normalize failed on zstd input'; exit 1; }
    gzip -t "$nidir/out2.gz" || { echo 'zstd-normalized output is not gzip'; exit 1; }
fi
printf '070701' > "$nidir/in.plain"; head -c 4096 /dev/zero >> "$nidir/in.plain"
normalize_initrd_to_gzip "$nidir/in.plain" "$nidir/out3.gz" || { echo 'normalize failed on plain cpio'; exit 1; }
gzip -t "$nidir/out3.gz" || { echo 'cpio-normalized output is not gzip'; exit 1; }
head -c 64 "$nidir/in.gz" > "$nidir/in.trunc"
normalize_initrd_to_gzip "$nidir/in.trunc" "$nidir/out4.gz" && { echo 'normalize accepted truncated gzip'; exit 1; } || true
[[ -e "$nidir/out4.gz" ]] && { echo 'normalize left a partial output behind'; exit 1; }
rm -rf "$nidir"
pass normalize_initrd_to_gzip

# Initrd content check: must reject garbage, accept a real newc archive with /init.
vdir=$(mktemp -d /tmp/reinstall-verify.XXXXXX)
mkdir -p "$vdir/root"
printf '#!/bin/sh\nexit 0\n' > "$vdir/root/init"
chmod 755 "$vdir/root/init"
( cd "$vdir/root" && find . | cpio -o -H newc 2>/dev/null | gzip -1 ) > "$vdir/good.gz"
verify_initrd_content "$vdir/good.gz" || { echo 'verify_initrd_content rejected a valid initrd'; exit 1; }
printf 'this is not an initramfs\n' | gzip -1 > "$vdir/bad.gz"
verify_initrd_content "$vdir/bad.gz" && { echo 'verify_initrd_content accepted garbage'; exit 1; } || true
# concatenated archive (Debian early-cpio style): /init lives in member 2 —
# GNU cpio -t would stop at member 1's TRAILER, the python walker must not.
mkdir -p "$vdir/early/kernel/x86/microcode"
printf '\x01\x02' > "$vdir/early/kernel/x86/microcode/fake.bin"
( cd "$vdir/early" && find . | cpio -o -H newc 2>/dev/null ) > "$vdir/concat"
( cd "$vdir/root" && find . | cpio -o -H newc 2>/dev/null ) >> "$vdir/concat"
gzip -1 -c "$vdir/concat" > "$vdir/concat.gz"
verify_initrd_content "$vdir/concat.gz" || { echo 'verify_initrd_content rejected init in member 2'; exit 1; }
# 4-aligned concatenation (dracut-style, no 512 padding between members)
( cd "$vdir/early" && find . | cpio -o -H newc 2>/dev/null ) > "$vdir/concat4"
trailer_end=$(python3 -c '
import sys
d = open(sys.argv[1], "rb").read()
i = d.rfind(b"070701")
while i >= 0:
    nlen = int(d[i+94:i+102], 16)
    name = d[i+110:i+110+nlen].rstrip(b"\x00")
    if name == b"TRAILER!!!":
        i = i + 110 + nlen
        i = (i + 3) & ~3
        print(i)
        break
    i = d.rfind(b"070701", 0, i)
' "$vdir/concat4")
head -c "$trailer_end" "$vdir/concat4" > "$vdir/concat4a"
( cd "$vdir/root" && find . | cpio -o -H newc 2>/dev/null ) >> "$vdir/concat4a"
gzip -1 -c "$vdir/concat4a" > "$vdir/concat4.gz"
verify_initrd_content "$vdir/concat4.gz" || { echo 'verify_initrd_content rejected 4-aligned concatenation'; exit 1; }
# non-executable /init must be rejected
cp -a "$vdir/root/init" "$vdir/root/init.nox"; chmod 644 "$vdir/root/init.nox"
( cd "$vdir/root" && mv init.nox init && find . | cpio -o -H newc 2>/dev/null | gzip -1 ) > "$vdir/nox.gz"
verify_initrd_content "$vdir/nox.gz" && { echo 'verify_initrd_content accepted non-executable init'; exit 1; } || true
rm -rf "$vdir"
pass verify_initrd_content

# The staged entry must carry the engine cmdline, not the d-i one.
grep -q 'stage_boot_entry "$CMDLINE"' "$root/lib/debootstrap.sh" || { echo 'debootstrap handoff must pass the engine cmdline'; exit 1; }
grep -q 'CMDLINE=$1' "$root/lib/handoff.sh" || { echo 'stage_boot_entry must accept a cmdline argument'; exit 1; }
pass engine_cmdline_wiring

# Engine script: static, POSIX-safe, self-halting on failure, no set -e.
eng=$(mktemp /tmp/reinstall-engine.XXXXXX)
write_engine_script "$eng"
bash -n "$eng" || { echo 'engine script fails bash -n'; exit 1; }
grep -qE '^[[:space:]]*set -e([[:space:]]|$)' "$eng" && { echo 'engine must not set -e (sourced by init)'; exit 1; }
grep -q 'while :; do sleep 3600; done' "$eng" || { echo 'engine missing halt loop'; exit 1; }
for needle in 'cryptsetup luksFormat' 'vg_crypt UUID=%s none luks' 'grub-install' 'reinstall-done' 'debootstrap ' 'luksUUID' 'mount --bind /proc /mnt/proc' 'init-bottom' 'exec tail -n +3 "\$0"' 'Debian LUKS reinstall (retry)'; do
  grep -qF -- "$needle" "$eng" || { echo "engine missing: $needle"; exit 1; }
done
rm -f "$eng"
pass write_engine_script

# Initramfs hook embeds engine + tools + watchdog pet hook.
LOG_FILE=/tmp/reinstall-test.log; : >"$LOG_FILE"
NIC_MODULE=virtio_net; WORKDIR=/tmp/reinstall-eng-test
mkdir -p "$WORKDIR/payload/opt/reinstall"
printf x > "$WORKDIR/payload/opt/reinstall/postinstall.sh"; printf y > "$WORKDIR/payload/opt/reinstall/secrets.env"
printf '#!/bin/sh\n' > "$WORKDIR/engine.sh"
write_watchdog_pet_hook "$WORKDIR/payload"
# write_initramfs_hook resolves host tool paths via command -v; fake them.
fakebin=$(mktemp -d /tmp/reinstall-eng-bin.XXXXXX)
for c in parted partprobe cryptsetup pvcreate vgcreate lvcreate vgchange mkfs.ext4 mkswap blkid debootstrap dpkg wget ip; do
  printf '#!/bin/sh\nexit 0\n' > "$fakebin/$c"; chmod +x "$fakebin/$c"
done
hook=$(mktemp /tmp/reinstall-hook.XXXXXX)
PATH="$fakebin:$PATH" write_initramfs_hook "$hook"
bash -n "$hook" || { echo 'hook fails bash -n'; exit 1; }
for needle in 'manual_add_modules virtio_net lpc_ich iTCO_wdt' 'copy_exec ' 'reinstall-debootstrap.env' 'zz-watchdog-pet' 'zz-reinstall-engine' 'debootstrap.env'; do
  grep -qF -- "$needle" "$hook" || { echo "hook missing: $needle"; exit 1; }
done
rm -f "$hook"; rm -rf "$WORKDIR" "$fakebin"
pass write_initramfs_hook

# reinstall.sh wiring: --method flag, lib source, routing.
grep -q -- '--method' "$root/reinstall.sh" || { echo 'reinstall.sh missing --method'; exit 1; }
grep -q 'for f in config detect validate download preseed postinstall initrd handoff debootstrap' "$root/reinstall.sh" || { echo 'reinstall.sh missing debootstrap source'; exit 1; }
grep -q 'do_debootstrap_handoff' "$root/reinstall.sh" || { echo 'reinstall.sh missing debootstrap routing'; exit 1; }
pass reinstall_wiring

plan=$(debootstrap_plan)
[[ $plan == *'method: debootstrap'* && $plan == *'vg_crypt'* && $plan == *'grub-install'* ]] || { echo 'debootstrap_plan incomplete'; exit 1; }
pass debootstrap_plan
