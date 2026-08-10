#!/usr/bin/env bash
set -euo pipefail

[[ ${_REINSTALL_CONFIG_SH:-0} == 1 ]] && return 0
_REINSTALL_CONFIG_SH=1

CONFIG_KEYS=(DEBIAN_SUITE MIRROR TIMEZONE TARGET_DISK PRIMARY_IFACE IPV4_ADDR NETMASK GATEWAY DNS_SERVERS HOSTNAME DOMAIN BOOT_MODE NIC_MODULE ADMIN_USER ADMIN_SSH_PUBKEY ADMIN_SSH_PUBKEY_FILE ADMIN_PASSWORD_HASH SSH_PORT DROPBEAR_PORT WEB_PORTS BOOT_SIZE_MB SWAP_SIZE_MB LUKS_PASSPHRASE ASSUME_YES WORKDIR LOG_FILE LOG_LEVEL)
declare -A CONFIG_ENV_SET=()
# Keys set by command-line flags (--log-file, --verbose, --assume-yes) are pinned
# here so a config file can never override them — a blank LOG_FILE="" in the
# example config used to wipe the CLI log path, breaking every later log write.
declare -A CONFIG_CLI_SET=()
config_pin() { local k; for k in "$@"; do CONFIG_CLI_SET[$k]=1; done; }
# Record which keys arrived via the real process environment BEFORE the defaults below run
# (those defaults would otherwise make every key look "already set" and a config file could
# never override anything — this must happen first, once, as this file is sourced). Checking
# the export attribute (not plain -v) matters for HOSTNAME: bash auto-populates it from the
# OS hostname on every shell startup, even with zero real environment, but never exports it.
_ck=; for _ck in "${CONFIG_KEYS[@]}"; do [[ -v $_ck ]] || continue; case $(declare -p "$_ck" 2>/dev/null) in "declare -x"*) CONFIG_ENV_SET[$_ck]=1 ;; esac; done; unset _ck

# Configuration values (file/env/detection layers populate these globals).
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"; MIRROR="${MIRROR:-https://deb.debian.org/debian}"; TIMEZONE="${TIMEZONE:-UTC}"
TARGET_DISK="${TARGET_DISK:-}"; PRIMARY_IFACE="${PRIMARY_IFACE:-}"; IPV4_ADDR="${IPV4_ADDR:-}"; NETMASK="${NETMASK:-}"; GATEWAY="${GATEWAY:-}"; DNS_SERVERS="${DNS_SERVERS:-}"
[[ ${CONFIG_ENV_SET[HOSTNAME]:-0} == 1 ]] || HOSTNAME=debian; DOMAIN="${DOMAIN:-local}"; BOOT_MODE="${BOOT_MODE:-}"; NIC_MODULE="${NIC_MODULE:-}"
ADMIN_USER="${ADMIN_USER:-admin}"; ADMIN_SSH_PUBKEY="${ADMIN_SSH_PUBKEY:-}"; ADMIN_SSH_PUBKEY_FILE="${ADMIN_SSH_PUBKEY_FILE:-}"; ADMIN_PASSWORD_HASH="${ADMIN_PASSWORD_HASH:-}"
SSH_PORT="${SSH_PORT:-2222}"; DROPBEAR_PORT="${DROPBEAR_PORT:-22}"; WEB_PORTS="${WEB_PORTS:-80 443}"
BOOT_SIZE_MB="${BOOT_SIZE_MB:-1024}"; SWAP_SIZE_MB="${SWAP_SIZE_MB:-4096}"; LUKS_PASSPHRASE="${LUKS_PASSPHRASE:-}"; ASSUME_YES="${ASSUME_YES:-no}"; WORKDIR="${WORKDIR:-}"
LOG_FILE="${LOG_FILE:-}"; LOG_LEVEL="${LOG_LEVEL:-INFO}"

_config_warn() { type log_warn >/dev/null 2>&1 && log_warn "$*" || printf 'WARN: %s\n' "$*" >&2; }
config_key_allowed() { local k=$1 x; for x in "${CONFIG_KEYS[@]}"; do [[ $x == "$k" ]] && return 0; done; return 1; }

# Parse KEY=VALUE without sourcing shell code. Supports quoted values and inline comments.
load_config_file() {
  local file=$1 line key value
  [[ -r $file ]] || { _config_warn "config file is not readable: $file"; return 1; }
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line#"${line%%[![:space:]]*}"}"; [[ -z $line || ${line:0:1} == \# ]] && continue
    [[ $line == *=* ]] || { _config_warn "ignoring malformed config line"; continue; }
    key=${line%%=*}; value=${line#*=}; key="${key//[[:space:]]/}"
    value="${value#"${value%%[![:space:]]*}"}"
    if [[ ${value:0:1} == '"' ]]; then value="${value#\"}"; value="${value%%\"*}"
    elif [[ ${value:0:1} == "'" ]]; then value="${value#\'}"; value="${value%%\'*}"
    else value="${value%%#*}"; value="${value%"${value##*[![:space:]]}"}"; fi
    config_key_allowed "$key" || { _config_warn "unknown config key ignored: $key"; continue; }
    # Never let a config file override command-line flags or exported env vars.
    [[ ${CONFIG_ENV_SET[$key]:-0} == 1 || ${CONFIG_CLI_SET[$key]:-0} == 1 ]] && continue
    # Blank config values mean "auto-detect / use default"; they must not blank
    # out a value already set (e.g. LOG_FILE="" must not erase the log path).
    [[ -z $value && -n ${!key} ]] && continue
    printf -v "$key" '%s' "$value"
  done < "$file"
}

load_config() {
  local explicit=${1:-} f
  if [[ -n $explicit ]]; then [[ -e $explicit ]] || die "config file not found: $explicit"; load_config_file "$explicit"; return; fi
  for f in "${REINSTALL_CONF:-}" ./reinstall.conf /etc/reinstall.conf; do [[ -n $f && -f $f ]] && { load_config_file "$f"; return; }; done
}
set_defaults() { :; }

collect_ssh_keys() {
  local line key file; ADMIN_PUBKEYS=""
  [[ -n $ADMIN_SSH_PUBKEY ]] && ADMIN_PUBKEYS+="$ADMIN_SSH_PUBKEY\n"
  if [[ -n $ADMIN_SSH_PUBKEY_FILE ]]; then
    while IFS= read -r line || [[ -n $line ]]; do [[ -z $line || ${line:0:1} == \# ]] || ADMIN_PUBKEYS+="$line\n"; done < "$ADMIN_SSH_PUBKEY_FILE" || die "cannot read SSH key file"
  fi
  local valid=0 out='' ; while IFS= read -r key; do [[ -z $key ]] && continue; validate_ssh_key "$key" || die "invalid SSH public key"; out+="$key\n"; valid=$((valid+1)); done < <(printf '%b' "$ADMIN_PUBKEYS")
  (( valid > 0 )) || die "at least one valid SSH public key is required"; ADMIN_PUBKEYS=$out
}
