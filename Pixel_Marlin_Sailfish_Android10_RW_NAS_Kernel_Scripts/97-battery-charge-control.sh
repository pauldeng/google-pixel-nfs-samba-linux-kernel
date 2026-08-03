#!/system/bin/sh
set -eu

# Apply the Pixel 1 kernel's native HTC charge-start/charge-stop hysteresis.
# This is intentionally a one-shot Magisk service, not a polling controller:
# the kernel owns the state machine and continues enforcing its thermal and
# charger-safety decisions. External input is never suspended, so a failure
# cannot deliberately drain a mains-powered phone.

CONFIG_PATH=${1:-/data/adb/battery-charge-control.conf}
LOG_PATH=${LOG_PATH:-/data/adb/battery-charge-control.log}
DISABLE_PATH=${DISABLE_PATH:-/data/adb/battery-charge-control.disabled}
WAIT_SECONDS=${WAIT_SECONDS:-60}
VALIDATE_ONLY=${VALIDATE_ONLY:-0}
BATTERY_CONTROL_TEST_MODE=${BATTERY_CONTROL_TEST_MODE:-0}

if [ "$BATTERY_CONTROL_TEST_MODE" = 1 ]; then
  START_LEVEL_PATH=${START_LEVEL_PATH:?}
  STOP_LEVEL_PATH=${STOP_LEVEL_PATH:?}
else
  START_LEVEL_PATH=/sys/module/htc_battery/parameters/charge_start_level
  STOP_LEVEL_PATH=/sys/module/htc_battery/parameters/charge_stop_level
fi

umask 077
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_PATH"; }
fail() {
  log "ERROR: $*"
  echo "ERROR: $*" >&2
  exit 1
}

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

validate_config() {
  [ -f "$CONFIG_PATH" ] || fail "configuration is absent: $CONFIG_PATH"
  mode=$(stat -c '%a' "$CONFIG_PATH" 2>/dev/null) || fail "cannot stat configuration: $CONFIG_PATH"
  [ "$mode" = 600 ] || fail "configuration must have mode 0600: $CONFIG_PATH"
  if [ "$BATTERY_CONTROL_TEST_MODE" != 1 ]; then
    owner=$(stat -c '%u:%g' "$CONFIG_PATH" 2>/dev/null) || fail "cannot read configuration ownership"
    [ "$owner" = 0:0 ] || fail "configuration must be owned by root:root"
  fi

  CHARGE_START_PERCENT=
  CHARGE_STOP_PERCENT=
  seen_start=0
  seen_stop=0
  line_number=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    case "$line" in
      '' | '#'*) ;;
      CHARGE_START_PERCENT=*)
        [ "$seen_start" -eq 0 ] || fail "duplicate CHARGE_START_PERCENT at line $line_number"
        CHARGE_START_PERCENT=${line#CHARGE_START_PERCENT=}
        seen_start=1
        ;;
      CHARGE_STOP_PERCENT=*)
        [ "$seen_stop" -eq 0 ] || fail "duplicate CHARGE_STOP_PERCENT at line $line_number"
        CHARGE_STOP_PERCENT=${line#CHARGE_STOP_PERCENT=}
        seen_stop=1
        ;;
      *) fail "unknown or malformed configuration at line $line_number" ;;
    esac
  done <"$CONFIG_PATH"

  [ "$seen_start" -eq 1 ] || fail "CHARGE_START_PERCENT is required"
  [ "$seen_stop" -eq 1 ] || fail "CHARGE_STOP_PERCENT is required"
  is_uint "$CHARGE_START_PERCENT" || fail "CHARGE_START_PERCENT must be an integer"
  is_uint "$CHARGE_STOP_PERCENT" || fail "CHARGE_STOP_PERCENT must be an integer"
  [ "$CHARGE_START_PERCENT" -ge 10 ] && [ "$CHARGE_START_PERCENT" -le 80 ] \
    || fail "CHARGE_START_PERCENT must be between 10 and 80"
  [ "$CHARGE_STOP_PERCENT" -ge 20 ] && [ "$CHARGE_STOP_PERCENT" -le 90 ] \
    || fail "CHARGE_STOP_PERCENT must be between 20 and 90"
  [ "$CHARGE_START_PERCENT" -lt "$CHARGE_STOP_PERCENT" ] \
    || fail "CHARGE_START_PERCENT must be lower than CHARGE_STOP_PERCENT"
  gap=$((CHARGE_STOP_PERCENT - CHARGE_START_PERCENT))
  [ "$gap" -ge 5 ] || fail "charge thresholds must be at least 5 percentage points apart"
}

wait_for_nodes() {
  waited=0
  while :; do
    if [ -r "$START_LEVEL_PATH" ] && [ -w "$START_LEVEL_PATH" ] \
      && [ -r "$STOP_LEVEL_PATH" ] && [ -w "$STOP_LEVEL_PATH" ]; then
      return 0
    fi
    [ "$waited" -lt "$WAIT_SECONDS" ] || return 1
    sleep 1
    waited=$((waited + 1))
  done
}

read_level() {
  value=$(cat "$1" 2>/dev/null) || return 1
  is_uint "$value" || return 1
  printf '%s\n' "$value"
}

write_level() {
  path=$1
  value=$2
  if [ "$BATTERY_CONTROL_TEST_MODE" = 1 ] \
    && [ "${BATTERY_CONTROL_TEST_FAIL_STOP_WRITE:-0}" = 1 ] \
    && [ "$path" = "$STOP_LEVEL_PATH" ]; then
    return 1
  fi
  printf '%s\n' "$value" >"$path" || return 1
  actual=$(read_level "$path") || return 1
  [ "$actual" = "$value" ]
}

restore_pair() {
  restore_start=$1
  restore_stop=$2
  # Restore the upper bound first so the intermediate pair remains ordered.
  write_level "$STOP_LEVEL_PATH" "$restore_stop" || true
  write_level "$START_LEVEL_PATH" "$restore_start" || true
}

apply_pair() {
  requested_start=$1
  requested_stop=$2
  old_start=$(read_level "$START_LEVEL_PATH") || fail "cannot read native charge-start parameter"
  old_stop=$(read_level "$STOP_LEVEL_PATH") || fail "cannot read native charge-stop parameter"

  # Preserve an ordered intermediate pair when moving thresholds in either
  # direction. For example, 30/50 -> 80/90 must raise stop before start, while
  # 80/90 -> 30/50 must lower start before stop.
  if [ "$requested_start" -lt "$old_stop" ]; then
    first_path=$START_LEVEL_PATH
    first_value=$requested_start
    first_name=charge-start
    second_path=$STOP_LEVEL_PATH
    second_value=$requested_stop
    second_name=charge-stop
  else
    first_path=$STOP_LEVEL_PATH
    first_value=$requested_stop
    first_name=charge-stop
    second_path=$START_LEVEL_PATH
    second_value=$requested_start
    second_name=charge-start
  fi

  if ! write_level "$first_path" "$first_value"; then
    restore_pair "$old_start" "$old_stop"
    fail "could not set or verify native $first_name parameter"
  fi
  if ! write_level "$second_path" "$second_value"; then
    restore_pair "$old_start" "$old_stop"
    fail "could not set or verify native $second_name parameter; restored previous values"
  fi

  log "applied native charge hysteresis: start=$requested_start stop=$requested_stop"
  printf 'Applied native charge hysteresis: start=%s%% stop=%s%%\n' "$requested_start" "$requested_stop"
}

case "$CONFIG_PATH" in
  --restore-defaults)
    wait_for_nodes || fail "native HTC charge-threshold parameters are unavailable"
    apply_pair 0 100
    exit 0
    ;;
esac

validate_config
[ "$VALIDATE_ONLY" = 1 ] && {
  printf 'Valid charge configuration: start=%s%% stop=%s%%\n' "$CHARGE_START_PERCENT" "$CHARGE_STOP_PERCENT"
  exit 0
}

[ ! -e "$DISABLE_PATH" ] || {
  log "controller is disabled by $DISABLE_PATH; leaving kernel defaults unchanged"
  exit 0
}

is_uint "$WAIT_SECONDS" || fail "WAIT_SECONDS must be a non-negative integer"
wait_for_nodes || fail "native HTC charge-threshold parameters are unavailable after ${WAIT_SECONDS}s"
apply_pair "$CHARGE_START_PERCENT" "$CHARGE_STOP_PERCENT"
