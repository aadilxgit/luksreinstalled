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
[[ $cmdl == *'nomodeset console=ttyS0,115200n8 console=tty0 ip=203.0.113.10::203.0.113.1:255.255.255.0::any:off net.ifnames=0 biosdevname=0' ]] || { echo "debootstrap_cmdline wrong: $cmdl"; exit 1; }
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
for needle in 'cryptsetup luksFormat' 'vg_crypt UUID=%s none luks' 'grub-install' 'reinstall-done' 'debootstrap ' 'luksUUID' 'mount --bind /proc /mnt/proc' 'init-premount' 'exec tail -n +3 "\$0"' 'Debian LUKS reinstall (retry)'; do
  grep -qF -- "$needle" "$eng" || { echo "engine missing: $needle"; exit 1; }
done
rm -f "$eng"
pass write_engine_script

# Engine injection into the unpacked initrd tree: files land at the engine's
# runtime paths with the right modes; a missing payload must fail loudly.
LOG_FILE=/tmp/reinstall-test.log; : >"$LOG_FILE"
NIC_MODULE=virtio_net; WORKDIR=$(mktemp -d /tmp/reinstall-eng-test.XXXXXX)
mkdir -p "$WORKDIR/payload/opt/reinstall"
printf '#!/bin/sh\n' > "$WORKDIR/payload/opt/reinstall/postinstall.sh"; printf y > "$WORKDIR/payload/opt/reinstall/secrets.env"
printf '#!/bin/sh\n' > "$WORKDIR/engine.sh"; chmod +x "$WORKDIR/engine.sh"
printf 'ENV=1\n' > "$WORKDIR/debootstrap.env"
write_watchdog_pet_hook "$WORKDIR/payload"
tree=$(mktemp -d /tmp/reinstall-eng-tree.XXXXXX)
inject_engine_into_tree "$tree" || { echo 'inject_engine_into_tree failed'; exit 1; }
[[ -x "$tree/scripts/init-premount/zz-reinstall-engine" ]] || { echo 'engine not injected/executable'; exit 1; }
[[ -x "$tree/scripts/init-top/zz-watchdog-pet" ]] || { echo 'watchdog hook not injected/executable'; exit 1; }
[[ -f "$tree/scripts/init-premount/ORDER" ]] && grep -q 'zz-reinstall-engine' "$tree/scripts/init-premount/ORDER" || { echo 'engine not registered in init-premount/ORDER'; exit 1; }
[[ -f "$tree/scripts/init-top/ORDER" ]] && grep -q 'zz-watchdog-pet' "$tree/scripts/init-top/ORDER" || { echo 'watchdog pet not registered in init-top/ORDER'; exit 1; }
[[ -f "$tree/etc/reinstall-debootstrap.env" && "$(stat -c %a "$tree/etc/reinstall-debootstrap.env")" == 600 ]] || { echo 'env not injected with 600'; exit 1; }
[[ -f "$tree/etc/reinstall-payload/postinstall.sh" && "$(stat -c %a "$tree/etc/reinstall-payload/postinstall.sh")" == 700 ]] || { echo 'postinstall.sh not injected with 700'; exit 1; }
[[ -f "$tree/etc/reinstall-payload/secrets.env" && "$(stat -c %a "$tree/etc/reinstall-payload/secrets.env")" == 600 ]] || { echo 'secrets.env not injected with 600'; exit 1; }
rm -rf "$tree"; mkdir -p "$tree"
rm -f "$WORKDIR/payload/opt/reinstall/secrets.env"
inject_engine_into_tree "$tree" && { echo 'inject accepted missing payload'; exit 1; } || true
[[ -e "$tree/scripts" ]] && { echo 'inject left a partial tree behind'; exit 1; }
rm -rf "$WORKDIR" "$tree"
pass inject_engine_into_tree

# reinstall.sh wiring: --method flag, lib source, routing.
grep -q -- '--method' "$root/reinstall.sh" || { echo 'reinstall.sh missing --method'; exit 1; }
grep -q 'for f in config detect validate download preseed postinstall initrd handoff debootstrap' "$root/reinstall.sh" || { echo 'reinstall.sh missing debootstrap source'; exit 1; }
grep -q 'do_debootstrap_handoff' "$root/reinstall.sh" || { echo 'reinstall.sh missing debootstrap routing'; exit 1; }
pass reinstall_wiring

plan=$(debootstrap_plan)
[[ $plan == *'method: debootstrap'* && $plan == *'vg_crypt'* && $plan == *'grub-install'* ]] || { echo 'debootstrap_plan incomplete'; exit 1; }
pass debootstrap_plan
# safe_copy symlink test: UsrMerge symlinks (same basename) must not create self-referential symlinks (ELOOP).
tdir=$(mktemp -d /tmp/reinstall-safecopy.XXXXXX)
DESTDIR=$tdir
copy_exec() { mkdir -p "$DESTDIR/$2"; touch "$DESTDIR/$2/$(basename "$1")"; }
copy_file() { mkdir -p "$DESTDIR/$2"; touch "$DESTDIR/$2/$(basename "$1")"; }

# 1. UsrMerge case: /sbin/ip -> /usr/bin/ip (same basename "ip")
src=/sbin/ip; target_dir=/sbin/; real_src=/usr/bin/ip
copy_exec "$real_src" "$target_dir"
if [ "$(basename "$src")" != "$(basename "$real_src")" ]; then
    mkdir -p "$DESTDIR/$target_dir"
    ln -sf "$(basename "$real_src")" "$DESTDIR/$target_dir/$(basename "$src")"
fi
[[ -f "$DESTDIR/sbin/ip" && ! -L "$DESTDIR/sbin/ip" ]] || { echo 'safe_copy created self-referential symlink for UsrMerge'; exit 1; }

# 2. Alternatives case: /sbin/ip -> /sbin/ip.iproute2 (different basenames)
src=/sbin/ip; target_dir=/sbin/; real_src=/sbin/ip.iproute2
copy_exec "$real_src" "$target_dir"
if [ "$(basename "$src")" != "$(basename "$real_src")" ]; then
    mkdir -p "$DESTDIR/$target_dir"
    ln -sf "$(basename "$real_src")" "$DESTDIR/$target_dir/$(basename "$src")"
fi
[[ -L "$DESTDIR/sbin/ip" && "$(readlink "$DESTDIR/sbin/ip")" == "ip.iproute2" ]] || { echo 'safe_copy failed to create alternative symlink'; exit 1; }
# 3. Pre-existing busybox symlink cleanup: /sbin/mkfs.ext4 -> busybox
mkdir -p "$DESTDIR/bin" "$DESTDIR/sbin"
touch "$DESTDIR/bin/busybox"
ln -sf busybox "$DESTDIR/sbin/mkfs.ext4"
src=/sbin/mkfs.ext4; target_dir=/sbin/; real_src=/sbin/mke2fs
sname=$(basename "$src"); rname=$(basename "$real_src")
rm -f "$DESTDIR/$target_dir/$sname" "$DESTDIR/$target_dir/$rname"
rm -f "$DESTDIR/sbin/$sname" "$DESTDIR/bin/$sname" "$DESTDIR/usr/sbin/$sname" "$DESTDIR/usr/bin/$sname" 2>/dev/null || true
rm -f "$DESTDIR/sbin/$rname" "$DESTDIR/bin/$rname" "$DESTDIR/usr/sbin/$rname" "$DESTDIR/usr/bin/$rname" 2>/dev/null || true
copy_exec "$real_src" "$target_dir"
if [ "$sname" != "$rname" ]; then
    mkdir -p "$DESTDIR/$target_dir"
    ln -sf "$rname" "$DESTDIR/$target_dir/$sname"
fi
[[ -L "$DESTDIR/sbin/mkfs.ext4" && "$(readlink "$DESTDIR/sbin/mkfs.ext4")" == "mke2fs" ]] || { echo 'safe_copy failed to replace busybox symlink for mkfs.ext4'; exit 1; }
rm -rf "$tdir"
pass safe_copy_symlinks
