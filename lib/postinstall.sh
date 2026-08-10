#!/usr/bin/env bash
set -euo pipefail
[[ ${_POSTINSTALL_SH_LOADED:-0} == 1 ]] && return 0
_POSTINSTALL_SH_LOADED=1
build_postinstall_artifacts(){ local tmp=$1 d="$WORKDIR/payload/opt/reinstall"; mkdir -p "$d"; cat >"$d/late.sh" <<'EOF'
#!/bin/sh
set -u
cp /opt/reinstall/postinstall.sh /target/root/vps-postinstall.sh; cp /opt/reinstall/secrets.env /target/root/vps-secrets.env
chmod 700 /target/root/vps-postinstall.sh /target/root/vps-secrets.env
in-target /bin/sh /root/vps-postinstall.sh; rc=$?
shred -u /target/root/vps-secrets.env 2>/dev/null || rm -f /target/root/vps-secrets.env; rm -f /target/root/vps-postinstall.sh; exit "$rc"
EOF
cat >"$d/postinstall.sh" <<'EOF'
#!/bin/sh
set -eu
. /root/vps-secrets.env
log(){ printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
dev=$(blkid -t TYPE=crypto_LUKS -o device | head -n1); [ -n "$dev" ] || exit 10
printf '%s' "$TMPPW" >/run/tmp.key
printf '%s' "$USERPW" | cryptsetup luksAddKey "$dev" --key-file=/run/tmp.key --new-keyfile=- --batch-mode
printf '%s' "$USERPW" | cryptsetup open --test-passphrase "$dev" --key-file=-
cryptsetup luksRemoveKey "$dev" --key-file=/run/tmp.key; shred -u /run/tmp.key 2>/dev/null || rm -f /run/tmp.key
id "$ADMIN_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ADMIN_USER"; usermod -aG sudo "$ADMIN_USER"
if [ -n "$ADMIN_PASSWORD_HASH" ]; then usermod -p "$ADMIN_PASSWORD_HASH" "$ADMIN_USER"; rm -f /etc/sudoers.d/90-$ADMIN_USER; else passwd -l "$ADMIN_USER"; printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" >/etc/sudoers.d/90-$ADMIN_USER; chmod 440 /etc/sudoers.d/90-$ADMIN_USER; fi
mkdir -p "/home/$ADMIN_USER/.ssh"; printf '%s\n' "$ADMIN_PUBKEYS" > "/home/$ADMIN_USER/.ssh/authorized_keys"; chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"; chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
mkdir -p /etc/ssh/sshd_config.d; printf 'Port %s\nPermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nKbdInteractiveAuthentication no\nAllowUsers %s\n' "$SSH_PORT" "$ADMIN_USER" >/etc/ssh/sshd_config.d/99-hardening.conf
systemctl disable --now ssh.socket || true; systemctl enable --now ssh.service || true
mkdir -p /etc/dropbear/initramfs; : > /etc/dropbear/initramfs/authorized_keys; for key in $DROPBEAR_KEYS; do printf 'restrict,command="/bin/cryptroot-unlock" %s\n' "$key" >>/etc/dropbear/initramfs/authorized_keys; done; chmod 600 /etc/dropbear/initramfs/authorized_keys; printf 'DROPBEAR_OPTIONS="-j -k %s"\n' "${DROPBEAR_PORT:+-p $DROPBEAR_PORT}" >/etc/dropbear/initramfs/dropbear.conf
printf '%s\n' "$NIC_MODULE" >>/etc/initramfs-tools/modules
ufw default deny incoming; ufw default allow outgoing; ufw allow "$SSH_PORT/tcp"; ufw allow "$DROPBEAR_PORT/tcp"; for p in $WEB_PORTS; do ufw allow "$p/tcp"; done; ufw --force enable
mkdir -p /etc/fail2ban; printf '[DEFAULT]\nbackend = systemd\nbantime = 1h\nfindtime = 10m\nmaxretry = 5\n[sshd]\nenabled = true\nport = %s\nbackend = systemd\n' "$SSH_PORT" >/etc/fail2ban/jail.local
cat >>/etc/default/grub <<GRUB
GRUB_CMDLINE_LINUX="ip=$IPV4::$GATEWAY:$NETMASK::$IFACE:off console=ttyS0,115200n8 console=tty0"
GRUB
cat >/etc/apt/apt.conf.d/50unattended-upgrades <<'UPG'
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=\${distro_codename},label=Debian";
        "origin=Debian,codename=\${distro_codename},label=Debian-Security";
        "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
UPG
cat >/etc/pam.d/common-auth <<'PAM'
auth  required   pam_faillock.so preauth
auth  [success=1 default=ignore] pam_unix.so nullok
auth  [default=die] pam_faillock.so authfail
auth  sufficient pam_faillock.so authsucc
auth  requisite  pam_deny.so
auth  required   pam_permit.so
PAM
printf 'account required pam_faillock.so\n' >>/etc/pam.d/common-account
cat >/etc/sysctl.d/99-hardening.conf <<'SYSCTL'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.perf_event_paranoid = 3
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
SYSCTL
cat >/etc/security/faillock.conf <<'FAIL'
deny = 5
fail_interval = 900
unlock_time = 600
dir = /var/lib/faillock
silent
FAIL
mkdir -p /var/lib/faillock
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT
printf 'tmpfs /tmp tmpfs rw,nosuid,nodev,noexec,relatime,size=2G 0 0\ntmpfs /dev/shm tmpfs rw,nosuid,nodev,noexec,relatime 0 0\n' >>/etc/fstab
update-initramfs -u -k all; update-grub
EOF
cat >"$d/secrets.env" <<EOF
TMPPW=$(printf '%q' "$tmp")
USERPW=$(printf '%q' "$LUKS_PASSPHRASE")
ADMIN_USER=$(printf '%q' "$ADMIN_USER")
ADMIN_PUBKEYS=$(printf '%q' "$ADMIN_PUBKEYS")
DROPBEAR_KEYS=$(printf '%q' "$ADMIN_PUBKEYS")
SSH_PORT=$(printf '%q' "$SSH_PORT")
DROPBEAR_PORT=$(printf '%q' "$DROPBEAR_PORT")
IPV4=$(printf '%q' "$IPV4_ADDR"); NETMASK=$(printf '%q' "$NETMASK"); GATEWAY=$(printf '%q' "$GATEWAY"); IFACE=$(printf '%q' "$PRIMARY_IFACE"); NIC_MODULE=$(printf '%q' "$NIC_MODULE"); DNS=$(printf '%q' "$DNS_SERVERS"); WEB_PORTS=$(printf '%q' "$WEB_PORTS"); ADMIN_PASSWORD_HASH=$(printf '%q' "$ADMIN_PASSWORD_HASH")
EOF
chmod 700 "$d/late.sh" "$d/postinstall.sh"; chmod 600 "$d/secrets.env"; }
