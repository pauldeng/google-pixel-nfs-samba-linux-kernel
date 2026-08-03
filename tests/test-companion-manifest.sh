#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
COMPANION_DIR="$PROJECT_ROOT/Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts"
cd "$COMPANION_DIR"

sha256sum -c SHA256SUMS
manifest_files=$(awk 'NF == 2 {print $2}' SHA256SUMS | sort)
actual_files=$(find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | sort)
[[ $manifest_files == "$actual_files" ]] || {
  echo "ERROR: companion SHA256SUMS coverage differs from delivered files" >&2
  diff -u <(printf '%s\n' "$manifest_files") <(printf '%s\n' "$actual_files") >&2 || true
  exit 1
}
[[ -x 96-nas-photos.sh ]] || {
  echo "ERROR: 96-nas-photos.sh must be executable before installation" >&2
  exit 1
}
echo "PASS: companion checksums and manifest coverage"
