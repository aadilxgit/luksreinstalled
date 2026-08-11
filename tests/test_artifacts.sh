#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
count=$(awk '/^build_preseed\(\)/{n++} END{print n+0}' "$root/lib/preseed.sh")
[[ $count -eq 1 ]] || { echo "expected one build_preseed, got $count"; exit 1; }
grep -q 'payload/opt/reinstall/late.sh' "$root/lib/initrd.sh" || { echo 'initrd source path missing'; exit 1; }
! grep -q 'WORKDIR/late.sh' "$root/lib/initrd.sh" || { echo 'stale top-level path'; exit 1; }
grep -q 'command="/bin/cryptroot-unlock"' "$root/lib/postinstall.sh"
grep -q 'GRUB_CMDLINE_LINUX="ip=' "$root/lib/postinstall.sh"
grep -q '50unattended-upgrades' "$root/lib/postinstall.sh"
grep -q 'pam_faillock.so' "$root/lib/postinstall.sh"
grep -q 'net.ipv6.conf.default.accept_ra = 0' "$root/lib/postinstall.sh"
! grep -q '^ d-i debian-installer/locale' "$root/lib/preseed.sh"
[[ -e "$root/lib/handoff.sh" ]] || { echo 'lib/handoff.sh missing'; exit 1; }
[[ ! -e "$root/lib/kexec.sh" ]] || { echo 'lib/kexec.sh should not exist (clean cutover)'; exit 1; }
grep -q 'for f in .*handoff' "$root/reinstall.sh" || { echo 'reinstall.sh does not source lib/handoff.sh'; exit 1; }
! grep -q 'for f in .*[^a-z]kexec' "$root/reinstall.sh" || { echo 'reinstall.sh still sources lib/kexec.sh'; exit 1; }
grep -q -- '--cancel' "$root/reinstall.sh" || { echo 'reinstall.sh missing --cancel flag'; exit 1; }
for fn in stage_boot_entry arm_next_boot cancel_handoff confirm_handoff execute_handoff do_handoff render_boot_entry require_boot_space detect_boot_grub_facts; do
  grep -q "$fn" "$root/lib/handoff.sh" || { echo "lib/handoff.sh missing function: $fn"; exit 1; }
done
