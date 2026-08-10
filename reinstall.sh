#!/usr/bin/env bash
set -Eeuo pipefail
BASE=$(cd "$(dirname "$0")" && pwd)
source "$BASE/lib/common.sh"
# shellcheck disable=SC1090  # lib/$f.sh iterates a fixed, hardcoded list — not user-controlled input
for f in config detect validate download preseed postinstall initrd handoff debootstrap; do source "$BASE/lib/$f.sh"; done
cat >&2 <<'BANNER'
TTTTT  H   H  EEEEE        H   H   OOO   RRRR   SSSS  EEEEE
  T    H   H  E            H   H  O   O  R   R  S     E    
  T    HHHHH  EEEE         HHHHH  O   O  RRRR   SSSS  EEEE 
  T    H   H  E            H   H  O   O  R R    S     E    
  T    H   H  EEEEE        H   H   OOO   R  RR  SSSS  EEEEE

                         sends his reguards
BANNER
# shellcheck disable=SC2034  # ASSUME_YES is consumed by lib/handoff.sh confirm_handoff and lib/validate.sh, sourced dynamically above
while (($#)); do case $1 in --dry-run) DRY_RUN=yes;; --method) METHOD=$2; shift;; --config) CONFIG_FILE=$2; shift;; --verbose|-v) LOG_LEVEL=DEBUG; config_pin LOG_LEVEL;; --log-file) LOG_FILE=$2; shift; config_pin LOG_FILE;; --assume-yes) ASSUME_YES=yes; config_pin ASSUME_YES;; --cancel) CANCEL=yes;; -h|--help) echo "Usage: reinstall.sh [--dry-run] [--method installer|debootstrap] [--config FILE] [--verbose] [--log-file PATH] [--assume-yes] [--cancel]"; exit 0;; esac; shift; done
METHOD=${METHOD:-installer}
case $METHOD in installer|debootstrap) ;; *) die "unknown --method: $METHOD (expected installer or debootstrap)";; esac
LOG_FILE="${LOG_FILE:-/tmp/reinstall-$(date -u +%Y%m%d-%H%M%S).log}"
init_logging "$@"
if [[ ${CANCEL:-no} == yes ]]; then require_root; cancel_handoff; exit 0; fi
log_step "preflight"
require_root
require_cmd wget cpio gzip zcat sha256sum awk ip lsblk findmnt blkid openssl systemd-detect-virt mountpoint update-grub grub-reboot grub-editenv reboot
guard_virtualization
log_step "config"
load_config "${CONFIG_FILE:-}"
set_defaults
WORKDIR="${WORKDIR:-$(mktemp -d /dev/shm/reinstall.XXXXXX 2>/dev/null || mktemp -d /root/reinstall.XXXXXX)}"
export WORKDIR
trap 'rc=$?; log_error "unexpected failure (rc=$rc) at ${BASH_SOURCE##*/}:$LINENO: $BASH_COMMAND"; exit "$rc"' ERR
trap '[[ -n ${WORKDIR:-} && ${KEEP_WORKDIR:-no} != yes ]] && rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR"
redact_add "$LUKS_PASSPHRASE"
log_step "detect"
detect_collect
log_step "prompt"
prompt_or_require_config
prompt_passphrase; redact_add "$LUKS_PASSPHRASE"
TMPPW=$(openssl rand -hex 32); redact_add "$TMPPW"
ADMIN_PW_CRYPT="${ADMIN_PASSWORD_HASH:-$(openssl passwd -6 "$(openssl rand -hex 16)")}"
log_step "preseed"
build_preseed "$TMPPW" "$ADMIN_PW_CRYPT"
build_postinstall_artifacts "$TMPPW"
if [[ ${DRY_RUN:-no} == yes ]]; then
    render_partition_tree
    if [[ $METHOD == debootstrap ]]; then
        debootstrap_plan
        exit 0
    fi
    cat "$WORKDIR/preseed.cfg"
    build_cmdline
    render_boot_entry "$CMDLINE" 00000000-0000-0000-0000-000000000000 part_gpt ext2 ''
    exit 0
fi
if [[ $METHOD == debootstrap ]]; then
    log_step "debootstrap"
    do_debootstrap_handoff
    exit 0
fi
log_step "download"
download_installer
verify_installer
log_step "payload"
build_payload
log_step "handoff"
do_handoff
