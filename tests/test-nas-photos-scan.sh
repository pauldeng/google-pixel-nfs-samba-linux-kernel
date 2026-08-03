#!/bin/sh
# The production functions are loaded with eval, so ShellCheck cannot see their
# indirect variable and stub-function use. The single-quoted line builds an
# executable fixture whose variables must expand when that fixture runs.
# shellcheck disable=SC2016,SC2034,SC2329
set -eu

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SERVICE="$PROJECT_ROOT/Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/96-nas-photos.sh"
TEST_ROOT=$(mktemp -d)
fails=0

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT HUP INT TERM

check() {
  label=$1
  want=$2
  got=$3
  if [ "$want" = "$got" ]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s (want %s, got %s)\n' "$label" "$want" "$got"
    fails=$((fails + 1))
  fi
}

# Load only the two production functions under test. Their collaborators are
# replaced below so the tests exercise the real stability and health decisions
# without mounting a filesystem or contacting Android services.
eval "$(sed -n '/^scan_health_due()/,/^}/p;/^file_signature()/,/^}/p;/^scan_new_files()/,/^}/p' "$SERVICE")"

mkdir "$TEST_ROOT/bin" "$TEST_ROOT/work" "$TEST_ROOT/app"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >>"$AM_LOG"' >"$TEST_ROOT/bin/am"
chmod 755 "$TEST_ROOT/bin/am"
PATH="$TEST_ROOT/bin:$PATH"
export PATH

APP_TARGET=$TEST_ROOT/app
REFUSED_PATH=$TEST_ROOT/refused
SCAN_WORK_ROOT=$TEST_ROOT/work
PHOTO_FOLDER=NAS-Live
IO_TIMEOUT=5
FILE_STABILITY_SECONDS=1
HEALTH_INTERVAL_SECONDS=15
SCAN_PACE_SECONDS=0
REFUSAL_LIMIT=3

log() { printf '%s\n' "$*" >>"$TEST_ROOT/service.log"; }
refusal_count() { printf '0\n'; }
record_refusal() { printf '%s\n' "$1" >>"$TEST_ROOT/refusal-calls"; }
unmount_share() {
  UNMOUNTED=1
  return 0
}

# ----------------------------------------------------------- stability gate
printf 'complete\n' >"$APP_TARGET/stable.jpg"
printf 'partial\n' >"$APP_TARGET/changing.jpg"
AM_LOG=$TEST_ROOT/am-stability.log
export AM_LOG
: >"$AM_LOG"
INDEX_CALLS=0
SLEEP_CALLS=0
SCAN_RECHECK_SOON=0
indexed_paths() {
  INDEX_CALLS=$((INDEX_CALLS + 1))
  [ "$INDEX_CALLS" -lt 2 ] || printf 'stable.jpg\n'
}
sleep() {
  SLEEP_CALLS=$((SLEEP_CALLS + 1))
  if [ "$SLEEP_CALLS" -eq 1 ]; then
    printf 'still-copying\n' >>"$APP_TARGET/changing.jpg"
  fi
}
monotonic_seconds() { printf '0\n'; }
nas_reachable() { return 0; }

scan_status=0
scan_new_files || scan_status=$?
check "scan succeeds with one stable and one changing file" 0 "$scan_status"
check "only the stable file is broadcast" 1 "$(wc -l <"$AM_LOG" | tr -d ' ')"
check "the stable filename reaches the broadcast" yes \
  "$(grep -q 'stable.jpg' "$AM_LOG" && echo yes || echo no)"
check "the changing filename is deferred" yes \
  "$(grep -q 'changing.jpg' "$AM_LOG" && echo no || echo yes)"
check "a changing file requests an early recheck" 1 "$SCAN_RECHECK_SOON"
check "a changing file does not accrue a refusal" 0 \
  "$([ -f "$TEST_ROOT/refusal-calls" ] && wc -l <"$TEST_ROOT/refusal-calls" || echo 0)"
check "the stability scan removes its workspace" 0 \
  "$(find "$SCAN_WORK_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

# ----------------------------------------------- health during stability wait
rm -f "$APP_TARGET"/* "$TEST_ROOT/refusal-calls"
printf 'a\n' >"$APP_TARGET/a.jpg"
AM_LOG=$TEST_ROOT/am-stability-outage.log
export AM_LOG
: >"$AM_LOG"
FAKE_NOW=0
NAS_CALLS=0
UNMOUNTED=0
FILE_STABILITY_SECONDS=30
SCAN_PACE_SECONDS=0
SCAN_RECHECK_SOON=0
indexed_paths() { return 0; }
sleep() { FAKE_NOW=$((FAKE_NOW + $1)); }
monotonic_seconds() { printf '%s\n' "$FAKE_NOW"; }
nas_reachable() {
  NAS_CALLS=$((NAS_CALLS + 1))
  return 1
}

scan_status=0
scan_new_files || scan_status=$?
check "an outage interrupts the file-stability window" 1 "$scan_status"
check "no file is broadcast after the stability outage" 0 \
  "$(wc -l <"$AM_LOG" | tr -d ' ')"
check "a stability-window outage unmounts the stale share" 1 "$UNMOUNTED"
check "the interrupted stability wait removes its workspace" 0 \
  "$(find "$SCAN_WORK_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

# ------------------------------------------------------- health during scan
rm -f "$APP_TARGET"/* "$TEST_ROOT/refusal-calls"
printf 'a\n' >"$APP_TARGET/a.jpg"
printf 'b\n' >"$APP_TARGET/b.jpg"
printf 'c\n' >"$APP_TARGET/c.jpg"
AM_LOG=$TEST_ROOT/am-health.log
export AM_LOG
: >"$AM_LOG"
FAKE_NOW=0
NAS_CALLS=0
UNMOUNTED=0
FILE_STABILITY_SECONDS=1
SCAN_PACE_SECONDS=10
SCAN_RECHECK_SOON=0
indexed_paths() { return 0; }
sleep() { FAKE_NOW=$((FAKE_NOW + $1)); }
monotonic_seconds() { printf '%s\n' "$FAKE_NOW"; }
nas_reachable() {
  NAS_CALLS=$((NAS_CALLS + 1))
  [ "$NAS_CALLS" -lt 1 ]
}

scan_status=0
scan_new_files || scan_status=$?
check "a confirmed scan-time outage fails the scan" 1 "$scan_status"
check "the scan stops before broadcasting the whole queue" 2 \
  "$(wc -l <"$AM_LOG" | tr -d ' ')"
check "a scan-time outage unmounts the stale share" 1 "$UNMOUNTED"
check "the aborted scan removes its workspace" 0 \
  "$(find "$SCAN_WORK_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

if [ "$fails" -ne 0 ]; then
  printf 'FAIL: %s NAS photo scan regression(s)\n' "$fails" >&2
  exit 1
fi
printf 'PASS: NAS photo stability and scan-health regressions\n'
