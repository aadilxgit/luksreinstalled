#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${_REINSTALL_INITRD_SH:-}" ]]; then return 0; fi
_REINSTALL_INITRD_SH=1

# Reads a cpio file listing on stdin; exits 1 unless every payload file is present.
check_payload_entries() {
    awk '$0=="preseed.cfg"{p=1} $0=="opt/reinstall/late.sh"{l=1} $0=="opt/reinstall/postinstall.sh"{po=1} $0=="opt/reinstall/secrets.env"{s=1} $0=="scripts/init-top/zz-watchdog-pet"{w=1} END{exit !(p&&l&&po&&s&&w)}'
}

# Writes the initramfs hook that keeps the hypervisor's watchdog serviced for the
# whole installer run. Runs from /scripts/init-top (early in the initramfs); the
# background pet loop outlives the init shell, so it covers the installer too.
# Any byte pets the watchdog — never write 'V': that byte is the magic-close
# sequence that DISARMS the watchdog when the fd closes.
write_watchdog_pet_hook() {  # $1 = payload root
    local hook="$1/scripts/init-top/zz-watchdog-pet"
    mkdir -p "$(dirname "$hook")"
    cat >"$hook" <<'EOF'
#!/bin/sh
( while :; do
    modprobe iTCO_wdt 2>/dev/null || modprobe i6300esb 2>/dev/null || true
    if [ -e /dev/watchdog ]; then printf 'x' >/dev/watchdog 2>/dev/null || true; fi
    sleep 5
  done ) &
EOF
    chmod 0755 "$hook"
}

# Assemble the offline installer payload and append it to the downloaded initrd.
build_payload() {
    : "${WORKDIR:?WORKDIR is required}"
    require_cmd find cpio gzip zcat cp cat
    local payload="$WORKDIR/payload" artifacts="$WORKDIR/payload/opt/reinstall"
    mkdir -p "$payload/opt/reinstall"
    [[ -s "$WORKDIR/preseed.cfg" ]] || die "preseed.cfg missing or empty"
    [[ -s "$artifacts/late.sh" ]] || die "late.sh missing or empty"
    [[ -s "$artifacts/postinstall.sh" ]] || die "postinstall.sh missing or empty"
    [[ -s "$artifacts/secrets.env" ]] || die "secrets.env missing or empty"
    write_watchdog_pet_hook "$payload"
    cp "$WORKDIR/preseed.cfg" "$payload/preseed.cfg"
    chmod 0644 "$payload/preseed.cfg"
    chmod 0700 "$payload/opt/reinstall/late.sh" "$payload/opt/reinstall/postinstall.sh"
    chmod 0600 "$payload/opt/reinstall/secrets.env"
    ( cd "$payload" && find . -print | cpio -o -H newc ) 2>/dev/null | gzip -9 > "$WORKDIR/payload.cpio.gz"
    zcat "$WORKDIR/payload.cpio.gz" | cpio -t 2>/dev/null | check_payload_entries || die "payload cpio missing required files"
    cp "$WORKDIR/initrd.gz" "$WORKDIR/initrd.preseed.gz"
    cat "$WORKDIR/payload.cpio.gz" >> "$WORKDIR/initrd.preseed.gz"
    [[ -s "$WORKDIR/initrd.preseed.gz" ]] || die "initrd append failed"
    # The kernel must unpack the *final* staged initrd. gzip -t tests every
    # concatenated member (base initrd + payload), so a truncated or corrupt
    # append aborts staging instead of booting a broken initrd that stalls the
    # installer invisibly. (cpio -t cannot be used here: GNU cpio stops at the
    # first archive's TRAILER!!! and never lists the appended member.)
    gzip -t "$WORKDIR/initrd.preseed.gz" || die "staged initrd.preseed.gz failed gzip integrity check"
}
