#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
MOUNT_SCRIPT="$PROJECT_ROOT/Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/90-nas-mount.sh"
PROBE_FUNCTIONS=$(awk '
  /^cleanup_rw_probe\(\)/ { emit=1 }
  /^# End mount probe functions\./ { exit }
  emit { print }
' "$MOUNT_SCRIPT")
eval "$PROBE_FUNCTIONS"

TEST_ROOT=$(mktemp -d)
LOG_PATH="$TEST_ROOT/probe.log"
TARGET="$TEST_ROOT/target"
mkdir "$TARGET"
# shellcheck disable=SC2329 # Invoked by trap.
cleanup_test() {
  rm -f "$LOG_PATH"
  rmdir "$TARGET" 2>/dev/null || true
  rmdir "$TEST_ROOT" 2>/dev/null || true
}
trap cleanup_test EXIT HUP INT TERM
log() { printf '%s\n' "$*" >>"$LOG_PATH"; }

export MOUNT_MODE=rw
probe_mount || {
  echo "ERROR: normal read/write probe failed: $PROBE_FAILURE" >&2
  exit 1
}
if find "$TARGET" -mindepth 1 -maxdepth 1 | grep -q .; then
  echo "ERROR: successful read/write probe left files behind" >&2
  exit 1
fi

MOUNT_MODE=ro
if probe_mount; then
  echo "ERROR: read-only probe accepted a successful write" >&2
  exit 1
fi
[ "$PROBE_FAILURE" = "read-only mount accepted a write" ] || {
  echo "ERROR: unexpected read-only failure: $PROBE_FAILURE" >&2
  exit 1
}

# shellcheck disable=SC2329 # Invoked indirectly by the evaluated function.
mkdir() { return 1; }
MOUNT_MODE=rw
if probe_mount; then
  echo "ERROR: mkdir failure was suppressed by conditional function invocation" >&2
  exit 1
fi
unset -f mkdir
[ "$PROBE_FAILURE" = "read/write probe could not create its directory" ] || {
  echo "ERROR: unexpected mkdir failure: $PROBE_FAILURE" >&2
  exit 1
}

echo "mount probe regression tests passed"
