#!/usr/bin/env bash
# Shared logging and safe command helpers.
[[ ${_REINSTALL_COMMON_SH:-} == 1 ]] && return 0; _REINSTALL_COMMON_SH=1
: "${LOG_LEVEL:=INFO}"; : "${LOG_FILE:=/var/log/reinstall-$(date -u +%Y%m%d-%H%M%S).log}"
REDACT=()
_log_rank(){ case $1 in DEBUG) echo 0;; INFO) echo 1;; WARN) echo 2;; ERROR) echo 3;; esac; }
_scrub(){ local s=$1 x; for x in "${REDACT[@]}"; do [[ -n $x ]] && s=${s//"$x"/***}; done; printf '%s' "$s"; }
init_logging(){ mkdir -p "$(dirname "$LOG_FILE")"; : >"$LOG_FILE"; chmod 600 "$LOG_FILE"; printf '# debian-luks-reinstall argv=%q host=%s utc=%s\n' "$*" "$(hostname)" "$(date -u +%FT%TZ)" >>"$LOG_FILE"; }
_log(){ local l=$1 m; shift; m=$(_scrub "$*"); printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$l" "$m" >>"$LOG_FILE"; if [[ $(_log_rank "$l") -ge $(_log_rank "$LOG_LEVEL") ]]; then printf '[%s] %s\n' "$l" "$m" >&2; fi; }
log_debug(){ _log DEBUG "$@"; }; log_info(){ _log INFO "$@"; }; log_warn(){ _log WARN "$@"; }; log_error(){ _log ERROR "$@"; }; log_step(){ log_info "========== $* =========="; }
redact_add(){ REDACT+=("$1"); }; die(){ log_error "$*"; return 1; }; require_root(){ [[ $(id -u) == 0 ]] || die "must run as root"; }; require_cmd(){ local c; for c; do command -v "$c" >/dev/null || die "missing command: $c"; done; }; confirm_yes(){ local a; read -r a; [[ $a == YES ]]; }
run(){ log_debug "run: $*"; "$@" 2>&1 | tee -a "$LOG_FILE"; local rc=${PIPESTATUS[0]}; ((rc==0)) || log_error "cmd failed (rc=$rc): $*"; return "$rc"; }
