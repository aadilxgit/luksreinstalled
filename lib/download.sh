#!/usr/bin/env bash
set -euo pipefail
[[ ${_DOWNLOAD_SH_LOADED:-0} == 1 ]] && return 0
_DOWNLOAD_SH_LOADED=1
# shellcheck source=lib/common.sh
source "${BASH_SOURCE[0]%/*}/common.sh" 2>/dev/null || true
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh" 2>/dev/null || true

dl() { local url=$1 dest=$2; require_cmd wget; run wget --https-only --max-redirect=0 --tries=3 --timeout=30 -O "$dest" "$url"; }
download_installer() {
  validate_mirror_url "$MIRROR"
  mkdir -p "${WORKDIR:?}"
  local base="$MIRROR/dists/$DEBIAN_SUITE/main/installer-amd64/current/images"
  dl "$base/SHA256SUMS" "$WORKDIR/SHA256SUMS"
  dl "$base/netboot/debian-installer/amd64/linux" "$WORKDIR/linux"
  dl "$base/netboot/debian-installer/amd64/initrd.gz" "$WORKDIR/initrd.gz"
}
verify_installer() {
  local check="$WORKDIR/SHA256SUMS.check"
  awk '$2=="./netboot/debian-installer/amd64/linux"{print $1"  linux"} $2=="./netboot/debian-installer/amd64/initrd.gz"{print $1"  initrd.gz"}' "$WORKDIR/SHA256SUMS" > "$check"
  if [[ $(wc -l < "$check") -ne 2 ]]; then rm -f "$WORKDIR/linux" "$WORKDIR/initrd.gz"; die "checksum entries missing"; fi
  if ! (cd "$WORKDIR" && sha256sum -c SHA256SUMS.check); then rm -f "$WORKDIR/linux" "$WORKDIR/initrd.gz"; die "checksum verification failed"; fi
}
