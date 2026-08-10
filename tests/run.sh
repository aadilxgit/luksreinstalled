#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
for t in "$root"/tests/test_*.sh; do bash "$t"; done
