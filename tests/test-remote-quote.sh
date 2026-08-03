#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LIBRARY="$PROJECT_ROOT/Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/host-shell-lib.sh"
# shellcheck source=../Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/host-shell-lib.sh
. "$LIBRARY"

original="printf '%s\\n' \"apostrophe: a'b\""
quoted=$(quote_remote_command "$original")
eval "set -- su -c $quoted"
[[ $# == 3 && $1 == su && $2 == -c && $3 == "$original" ]] || {
  echo "FAIL: remote command quoting changed the command" >&2
  exit 1
}

consumers=(device-deploy.sh install-battery-charge-control.sh install-nas-service.sh test-nas-mount.sh verify-nas-service.sh)
for consumer in "${consumers[@]}"; do
  script="$PROJECT_ROOT/Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/$consumer"
  # shellcheck disable=SC2016 # Assert the literal source expression.
  grep -Fq '. "$SCRIPT_DIR/host-shell-lib.sh"' "$script" || {
    echo "FAIL: $consumer does not source the shared remote-command quoting helper" >&2
    exit 1
  }
  if grep -Eq "shell \"su (-mm )?-c '" "$script"; then
    echo "FAIL: $consumer still hand-builds a single-quoted su command" >&2
    exit 1
  fi
done

echo "PASS: remote quoting preserves apostrophes and all host consumers use the shared helper"
