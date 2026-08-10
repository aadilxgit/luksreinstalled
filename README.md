# Debian LUKS Reinstall

A Bash tool that reinstalls a running Debian 13 (trixie) VPS by staging the text installer as a one-time GRUB boot entry and rebooting into it, creating GPT + unencrypted `/boot` and full-disk LUKS/LVM storage, rotating the temporary installer key to the requested passphrase, configuring Dropbear remote unlock, and applying SSH, firewall, PAM, sysctl, and unattended-upgrade hardening.

## Warning

This tool irreversibly erases the selected disk. Use it only on a VPS with console or provider recovery access. Confirming the final prompt stages a one-time GRUB menu entry pointing at the downloaded installer and reboots; the hypervisor resets the guest before the installer kernel boots, and the current operating system is not restored. Run `--cancel` before that point to remove the staged entry.

## Quick start

Clone the repo, enter it, and copy the example configuration:

```bash
git clone https://github.com/aadilxgit/luksreinstalled.git
cd luksreinstalled
sudo cp reinstall.conf.example reinstall.conf
sudo chmod 600 reinstall.conf
sudo nano reinstall.conf
```

Fill in `TARGET_DISK`, `PRIMARY_IFACE`, `IPV4_ADDR`, `NETMASK`, `GATEWAY`, `DNS_SERVERS`, and `ADMIN_SSH_PUBKEY` (see [Configure](#configure)). Then preview everything the install will do — no downloads, no changes to GRUB or `/boot`:

```bash
sudo ./reinstall.sh --dry-run --config reinstall.conf --log-file /tmp/reinstall.log
```

Review the output, then run the real thing (root is required — hence `sudo`):

```bash
sudo ./reinstall.sh --config reinstall.conf --log-file /var/log/reinstall.log
```

## Requirements

The running system must be:

- Debian-family or another Linux system with Bash and root access.
- amd64.
- A VM or bare-metal host, not an LXC, Docker, OpenVZ, or other container.
- Boots via GRUB (BIOS or UEFI) — the tool stages a one-time `menuentry` in `/etc/grub.d/40_custom` and arms it with `grub-reboot`.
- Connected through a usable static IPv4 configuration.

Host commands required before the destructive phase include `wget`, `cpio`, `gzip`, `zcat`, `sha256sum`, `awk`, `ip`, `lsblk`, `findmnt`, `blkid`, `openssl`, `systemd-detect-virt`, `mountpoint`, `update-grub`, `grub-reboot`, `grub-editenv`, and `reboot`.
### KVM VPS console

The staged installer boots with `nomodeset`, so the display never leaves VGA text mode — the bochs-drm driver does not switch the console to the framebuffer, and the web/VNC console keeps rendering installer output instead of freezing on the framebuffer switch:

```text
... preseed/file=/preseed.cfg nomodeset console=ttyS0,115200n8 console=tty0 ---
```

The last `console=` controls `/dev/console`, so installer text and debconf output appear on the VPS web/VNC console (serial is also active, listed first, for providers that expose it). If the web/VNC console stops updating mid-install, it is a real hang — capture the last line on the console before interrupting, and keep in mind the disk is only erased once partman actually writes the partition table. If the guest later reboots back into the original system with the disk untouched, the installer stalled before partman; retry from the tool (the staging is idempotent) rather than power-cycling mid-install.


## Configure

Copy the example and edit it:

```bash
cp reinstall.conf.example reinstall.conf
chmod 600 reinstall.conf
nano reinstall.conf
```

At minimum set:

```bash
TARGET_DISK="/dev/vda"
PRIMARY_IFACE="eth0"
IPV4_ADDR="203.0.113.10"
NETMASK="255.255.255.0"
GATEWAY="203.0.113.1"
DNS_SERVERS="1.1.1.1 8.8.8.8"
ADMIN_SSH_PUBKEY="ssh-ed25519 AAAA... operator"
```

`ADMIN_SSH_PUBKEY_FILE` may provide additional keys. The tool merges and validates both sources. `LUKS_PASSPHRASE` is preferably entered interactively or supplied through the environment; it must be at least eight characters.

Configuration precedence is:

1. Command-line flags.
2. Interactive confirmation and edits.
3. Exported environment variables.
4. Explicit or auto-loaded configuration file (blank values never override an already-set value).
5. Hardware and network detection.
6. Built-in defaults.

The tool searches `--config FILE`, `$REINSTALL_CONF`, `./reinstall.conf`, and `/etc/reinstall.conf`. Configuration is parsed as allowlisted `KEY=VALUE` data; it is never sourced as shell code.

## Dry run

A dry run generates and prints the preseed, partition summary, installer command line, and the staged GRUB entry it would write, without downloading binaries, staging anything under `/boot`, or touching GRUB:

```bash
sudo ./reinstall.sh --dry-run --config reinstall.conf --log-file /tmp/reinstall.log
```

Review the target disk, interface, address, boot mode, ports, and generated preseed. Confirm that the passphrase does not appear in output or logs.

## Execute

Run from this directory:

```bash
sudo ./reinstall.sh --config reinstall.conf --log-file /var/log/reinstall.log
```

The sequence is:

1. Root and command preflight.
2. Container rejection.
3. Hardware/network detection and configuration confirmation.
4. Passphrase confirmation.
5. Preseed and post-install artifact generation.
6. HTTPS installer download.
7. SHA256 verification of kernel and initrd.
8. Initrd payload assembly and root-level `preseed.cfg` verification.
9. Stage the installer under `/boot/reinstall` and write a one-time GRUB `menuentry`.
10. Arm it with `grub-reboot` for the immediately next boot only.
11. Final `YES` confirmation before disk erasure.
12. Reboot into the staged installer.

### Cancel

`--cancel` removes a staged entry — safe any time between a run that stopped at (or was declined at) the `YES` prompt and the reboot that consumes it. Once the reboot happens, cancellation from this tool is no longer possible.

```bash
sudo ./reinstall.sh --cancel
```

This removes the `debian-luks-reinstall` block from `/etc/grub.d/40_custom`, regenerates `grub.cfg`, clears the armed `next_entry`, and deletes `/boot/reinstall`. It does not detect, prompt, or download anything.

For automation, use `ASSUME_YES=yes` or `--assume-yes`. This bypasses the final destructive confirmation and must not be used without an external approval gate.

## After installation

The installer uses the temporary random LUKS key only during installation. The post-install worker adds the user passphrase, verifies it with `cryptsetup open --test-passphrase`, and removes the temporary key only after verification succeeds.

Unlock the encrypted root remotely through Dropbear on port 22:

```bash
ssh -p 22 root@203.0.113.10
```

The authorized key runs `/bin/cryptroot-unlock`. After the system boots, connect to OpenSSH on the configured port, default 2222:

```bash
ssh -p 2222 admin@203.0.113.10
```

Root SSH login and password authentication are disabled. Keep a second console or SSH session available while validating access.

## Logs and secrets

- Pre-reboot log: configured by `--log-file`, default `/tmp/reinstall-<timestamp>.log` in this implementation.
- Persistent post-install log: `/var/log/vps-postinst.log`.
- Installer secrets are embedded in the RAM-only initrd payload and are removed from the target after the post-install worker exits.
- Logs redact registered passphrases. Never enable global shell tracing.

## Common errors and fixes

### `must run as root`

Run the tool with `sudo` or from a root shell. Do not grant partial capabilities; disk partitioning, staging the GRUB entry, and rebooting all require root.

### `kexec cannot run inside a container`

Run the tool from the VPS host or a full VM. A container has no bootloader of its own to stage a boot entry into, and cannot safely reinstall the host OS this way.

### `missing command: update-grub` or `missing command: cpio`

Install the host prerequisites using the distribution package manager, then rerun the dry run. Do not proceed until the required command is available.

### `insufficient space to stage installer under /boot`

`/boot` (or the root filesystem, if `/boot` is not a separate mount) needs at least twice the combined size of the downloaded kernel and initrd, or 200MiB, whichever is larger. Free space or grow `/boot` before retrying.

### `generated preseed.cfg failed debconf-set-selections syntax check`

The rendered `preseed.cfg` is malformed. Re-run `--dry-run` and inspect the printed preseed; this check catches syntax errors but not `expert_recipe` dot errors — review the partition recipe by hand as well.

### `mirror URL validation failed`

Use an HTTPS URL with a valid DNS authority and no userinfo, query, or fragment:

```text
https://deb.debian.org/debian
```

The installer binary download rejects redirects and verifies both downloaded files against `SHA256SUMS`.

### `checksum entries missing` or `checksum verification failed`

Stop. The installer is never staged or armed at this point. Check network integrity, mirror availability, suite path, and local disk space. Delete the work directory and retry only after confirming the mirror serves the trixie amd64 netboot files.

### `at least one valid SSH public key is required`

Set `ADMIN_SSH_PUBKEY` or `ADMIN_SSH_PUBKEY_FILE` to a complete `ssh-ed25519`, `ssh-rsa`, or ECDSA public key. Do not use a private key.

### Dropbear does not listen after reboot

Verify the configured NIC module, static `ip=` command line, and initramfs contents from the provider console. The target must include the NIC driver in `/etc/initramfs-tools/modules`, then run:

```bash
update-initramfs -u -k all
update-grub
```

### SSH still listens on port 22

Debian trixie uses `ssh.socket`. The post-install worker disables the socket and enables `ssh.service`. From the console verify:

```bash
systemctl is-enabled ssh.socket ssh.service
sshd -T | grep -E '^(port|allowusers|permitrootlogin|passwordauthentication)'
```

### LUKS unlock fails

Do not remove or erase LUKS keyslots manually. Use the provider console, inspect `/var/log/vps-postinst.log`, and confirm that the post-install sequence completed add, verify, then remove. The tool uses exact passphrase bytes with `printf '%s'`, without a trailing newline.

### `Fail2ban reports no log path`

Debian trixie uses the systemd journal by default. The generated jail sets `backend = systemd` and requires `python3-systemd`; do not add an `/var/log/auth.log` path unless rsyslog is intentionally installed.

### Installer dies or the VM resets shortly after booting

Some providers run QEMU with the default ICH9 chipset, which exposes an emulated TCO watchdog (`iTCO_wdt`) that resets the VM when the guest does not service it — the Debian installer has no petting daemon of its own, so the machine can die mid-install with the disk untouched. Detect it on the current system with `dmesg | grep -i tco` (a line like `iTCO_wdt … heartbeat=30 sec` means it is present). This tool already handles it: the installer payload ships `/scripts/init-top/zz-watchdog-pet` (an initramfs hook that pets the watchdog every 5 s for the entire install), the preseed re-arms it via `preseed/early_command`, and the post-install worker installs the `watchdog` service on the target so the new system keeps petting after boot. No configuration needed.

## Verification

Run the non-destructive checks before release:

```bash
bash -n reinstall.sh lib/*.sh tests/*.sh
bash tests/test_artifacts.sh
bash tests/test_validate.sh
bash tests/run.sh
```

Never run `update-grub`, `grub-reboot`, `grub-editenv`, or `reboot` as ad-hoc verification commands, and never write to `/etc/grub.d` or `/boot` outside the tool itself. Use the dry run and provider console to validate configuration before the final confirmation. If the guest reboots back into the original system instead of the staged installer, check `grub-editenv /boot/grub/grubenv list`:

- `next_entry=debian-luks-reinstall` still set — the reboot never went through GRUB; the `grub-reboot` arm did not stick.
- `next_entry=` (empty) — GRUB consumed the entry and booted the installer kernel; the installer stalled before writing the disk. The old system is intact and the retry is safe; use the provider console to capture the last visible line.

## Recovery

If the installer fails before reboot, retain the log and use the provider console. If the new system fails to boot, use provider recovery media or console access. Do not attempt ad-hoc partition or LUKS erasure commands on the target disk; preserve the post-install log and LUKS header for diagnosis.
