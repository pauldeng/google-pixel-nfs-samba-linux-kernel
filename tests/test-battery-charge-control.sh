#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CONTROL_SCRIPT="$PROJECT_ROOT/Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/97-battery-charge-control.sh"
TEST_ROOT=$(mktemp -d)
START_NODE="$TEST_ROOT/charge_start_level"
STOP_NODE="$TEST_ROOT/charge_stop_level"
LOG_PATH="$TEST_ROOT/control.log"
DISABLE_PATH="$TEST_ROOT/disabled"
INJECTION_MARKER="$TEST_ROOT/injected"

cleanup_test() { rm -rf "$TEST_ROOT"; }
trap cleanup_test EXIT HUP INT TERM

reset_nodes() {
  printf '0\n' >"$START_NODE"
  printf '100\n' >"$STOP_NODE"
}

write_config() {
  printf '%s\n' "$@" >"$TEST_ROOT/config"
  chmod 0600 "$TEST_ROOT/config"
}

run_control() {
  BATTERY_CONTROL_TEST_MODE=1 \
    START_LEVEL_PATH="$START_NODE" \
    STOP_LEVEL_PATH="$STOP_NODE" \
    LOG_PATH="$LOG_PATH" \
    DISABLE_PATH="$DISABLE_PATH" \
    WAIT_SECONDS=0 \
    "$1" "$CONTROL_SCRIPT" "${2:---restore-defaults}"
}

reset_nodes
write_config CHARGE_START_PERCENT=30 CHARGE_STOP_PERCENT=50
run_control /bin/sh "$TEST_ROOT/config" >/dev/null
[ "$(cat "$START_NODE")" = 30 ] && [ "$(cat "$STOP_NODE")" = 50 ] || {
  echo "ERROR: valid thresholds were not applied" >&2
  exit 1
}

# Moving both limits above the current stop value must raise stop first so the
# transient pair never has start >= stop.
write_config CHARGE_START_PERCENT=80 CHARGE_STOP_PERCENT=90
run_control /bin/sh "$TEST_ROOT/config" >/dev/null
[ "$(cat "$START_NODE")" = 80 ] && [ "$(cat "$STOP_NODE")" = 90 ] || {
  echo "ERROR: upward threshold transition was not applied" >&2
  exit 1
}

run_control /bin/sh >/dev/null
[ "$(cat "$START_NODE")" = 0 ] && [ "$(cat "$STOP_NODE")" = 100 ] || {
  echo "ERROR: restore-defaults did not restore 0/100" >&2
  exit 1
}

if grep -Fq '/sys/class/power_supply/battery/charging_enabled' "$CONTROL_SCRIPT"; then
  echo "ERROR: controller must not suspend external input" >&2
  exit 1
fi

touch "$DISABLE_PATH"
write_config CHARGE_START_PERCENT=35 CHARGE_STOP_PERCENT=55
run_control /bin/sh "$TEST_ROOT/config" >/dev/null
[ "$(cat "$START_NODE")" = 0 ] && [ "$(cat "$STOP_NODE")" = 100 ] || {
  echo "ERROR: disable marker did not prevent writes" >&2
  exit 1
}
rm -f "$DISABLE_PATH"

for bad_config in \
  'CHARGE_START_PERCENT=50|CHARGE_STOP_PERCENT=50' \
  'CHARGE_START_PERCENT=48|CHARGE_STOP_PERCENT=50' \
  'CHARGE_START_PERCENT=9|CHARGE_STOP_PERCENT=50' \
  'CHARGE_START_PERCENT=30|CHARGE_STOP_PERCENT=91' \
  'CHARGE_START_PERCENT=30|CHARGE_START_PERCENT=35|CHARGE_STOP_PERCENT=50' \
  'CHARGE_START_PERCENT=30|UNKNOWN_KEY=1|CHARGE_STOP_PERCENT=50'; do
  reset_nodes
  old_ifs=$IFS
  IFS='|'
  # shellcheck disable=SC2086 # Intentional split of the test vector.
  write_config $bad_config
  IFS=$old_ifs
  if run_control /bin/sh "$TEST_ROOT/config" >/dev/null 2>&1; then
    echo "ERROR: invalid configuration was accepted: $bad_config" >&2
    exit 1
  fi
  [ "$(cat "$START_NODE")" = 0 ] && [ "$(cat "$STOP_NODE")" = 100 ] || {
    echo "ERROR: invalid configuration changed native nodes" >&2
    exit 1
  }
done

reset_nodes
write_config "CHARGE_START_PERCENT=\$(touch $INJECTION_MARKER)" CHARGE_STOP_PERCENT=50
if run_control /bin/sh "$TEST_ROOT/config" >/dev/null 2>&1; then
  echo "ERROR: shell expression was accepted as a threshold" >&2
  exit 1
fi
[ ! -e "$INJECTION_MARKER" ] || {
  echo "ERROR: configuration content was executed" >&2
  exit 1
}

reset_nodes
write_config CHARGE_START_PERCENT=30 CHARGE_STOP_PERCENT=50
BATTERY_CONTROL_TEST_FAIL_STOP_WRITE=1
export BATTERY_CONTROL_TEST_FAIL_STOP_WRITE
if run_control /bin/sh "$TEST_ROOT/config" >/dev/null 2>&1; then
  echo "ERROR: simulated stop-node failure was accepted" >&2
  exit 1
fi
unset BATTERY_CONTROL_TEST_FAIL_STOP_WRITE
[ "$(cat "$START_NODE")" = 0 ] && [ "$(cat "$STOP_NODE")" = 100 ] || {
  echo "ERROR: partial application did not restore the original pair" >&2
  exit 1
}

echo "battery charge-control regression tests passed"
