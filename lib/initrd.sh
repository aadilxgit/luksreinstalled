#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${_REINSTALL_INITRD_SH:-}" ]]; then return 0; fi
_REINSTALL_INITRD_SH=1

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
    cp "$WORKDIR/preseed.cfg" "$payload/preseed.cfg"
    chmod 0644 "$payload/preseed.cfg"
    chmod 0700 "$payload/opt/reinstall/late.sh" "$payload/opt/reinstall/postinstall.sh"
    chmod 0600 "$payload/opt/reinstall/secrets.env"
    ( cd "$payload" && find . -print | cpio -o -H newc ) 2>/dev/null | gzip -9 > "$WORKDIR/payload.cpio.gz"
    zcat "$WORKDIR/payload.cpio.gz" | cpio -t 2>/dev/null | awk '$0=="preseed.cfg"{p=1} $0=="opt/reinstall/late.sh"{l=1} $0=="opt/reinstall/postinstall.sh"{po=1} $0=="opt/reinstall/secrets.env"{s=1} END{exit !(p&&l&&po&&s)}' || die "payload cpio missing required files"
    cp "$WORKDIR/initrd.gz" "$WORKDIR/initrd.preseed.gz"
    cat "$WORKDIR/payload.cpio.gz" >> "$WORKDIR/initrd.preseed.gz"
    [[ -s "$WORKDIR/initrd.preseed.gz" ]] || die "initrd append failed"
}
