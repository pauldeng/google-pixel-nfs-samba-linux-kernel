#!/usr/bin/env bash
# SC2016: the single-quoted strings below are literal source patterns searched
#         for in the scripts under test; expansion would defeat the purpose.
# SC2034: WAIT_SECONDS is read by the wait helper that is eval'd in from
#         90-nas-mount.sh, so ShellCheck cannot see the use.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

# Regression coverage for the decision logic that gates flashing and mounting.
# These paths only run on failure, so they never execute during a normal
# hardware run: a previous zero-denial blocker shipped precisely because it
# passed the rest of this suite untouched.

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPTS="$PROJECT_ROOT/Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts"
fails=0
check() {
  local label=$1 want=$2 got=$3
  if [[ $want == "$got" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s (want %q, got %q)\n' "$label" "$want" "$got"
    fails=$((fails + 1))
  fi
}

# ---------------------------------------------------------------- classifier
eval "$(sed -n '/^bootloader_rejects_ram_boot()/,/^}/p' "$SCRIPTS/device-deploy.sh")"
classify() { bootloader_rejects_ram_boot "$1" && echo evidence || echo none; }

check "genuine dtb refusal grants evidence" evidence \
  "$(classify "Booting                FAILED (remote: 'dtb not found')")"
check "unquoted dtb refusal grants evidence" evidence \
  "$(classify "FAILED (remote: dtb not found)")"
check "unknown command grants evidence" evidence \
  "$(classify "FAILED (remote: 'unknown command')")"
check "locked-device refusal is not a limitation" none \
  "$(classify "FAILED (remote: not supported in locked device)")"
check "prose mentioning dtb not found is not evidence" none \
  "$(classify "error: dtb not found in my notes")"
check "boot loop is not evidence" none "$(classify "Booting FAILED (status read failed)")"
check "empty output is not evidence" none "$(classify "")"

# ------------------------------------------------------------ denial counting
eval "$(sed -n '/^count_net_raw_denials()/,/^# End sepolicy helper functions\./p' \
  "$SCRIPTS/install-sepolicy-module.sh" | sed '/^# End sepolicy helper functions\./d')"

check "zero denials returns 0 without aborting" 0 "$(count_net_raw_denials 'clean kernel log')"
check "counts multiple denials" 2 \
  "$(count_net_raw_denials 'avc: denied { net_raw } a
avc: denied { net_raw } b')"
check "empty log returns 0" 0 "$(count_net_raw_denials '')"

# The original defect was structural, not arithmetic: `grep -c` exits 1 on zero
# matches, and the count was computed in a TOP-LEVEL assignment, where errexit
# aborts. Inside a helper invoked from a command substitution the same code does
# not abort, so a purely functional check cannot catch a regression. Assert the
# dangerous shape is absent instead.
sepolicy_src=$(cat "$SCRIPTS/install-sepolicy-module.sh")
check "denials are not counted by a remote grep -c in an assignment" yes \
  "$([[ $sepolicy_src != *'denials=$(root_cmd'*'grep -c'* ]] && echo yes || echo no)"
check "denial count is delegated to the guarded helper" yes \
  "$([[ $sepolicy_src == *'denials=$(count_net_raw_denials'* ]] && echo yes || echo no)"
check "helper keeps its no-match guard" yes \
  "$([[ $sepolicy_src == *"grep -c 'denied { net_raw }') || n=0"* ]] && echo yes || echo no)"

# --------------------------------------------------------- readiness deadline
# Extract the wait helpers, then substitute a fake clock and a scripted probe so
# the deadline can be exercised without a network or real sleeping.
eval "$(sed -n '/^monotonic_seconds()/,/^# End mount probe functions\./p' \
  "$SCRIPTS/90-nas-mount.sh" | sed '/^# End mount probe functions\./d')"

FAKE_NOW=0
PROBE_SUCCEEDS_AT=-1
PROBE_CALLS=0
RUNAWAY=0
monotonic_seconds() { printf '%s\n' "$FAKE_NOW"; }
probe_service_port() {
  # Bound the loop. A deadline computed from a different clock than the one the
  # loop reads never expires, and an unbounded test would hang CI instead of
  # reporting a failure. Break out and let the assertions record it.
  PROBE_CALLS=$((PROBE_CALLS + 1))
  if ((PROBE_CALLS > 500)); then
    RUNAWAY=1
    return 0
  fi
  FAKE_NOW=$((FAKE_NOW + 2)) # each failed probe burns the nc -w 2 timeout
  [[ $PROBE_SUCCEEDS_AT -ge 0 && $FAKE_NOW -ge $PROBE_SUCCEEDS_AT ]]
}
sleep() { FAKE_NOW=$((FAKE_NOW + $1)); }
reset_clock() {
  FAKE_NOW=0
  PROBE_CALLS=0
  RUNAWAY=0
  PROBE_SUCCEEDS_AT=$1
}

WAIT_SECONDS=60
reset_clock -1
wait_for_service_port && r=reachable || r=timeout
check "unreachable port times out" timeout "$r"
check "deadline is honoured, loop does not run away" 0 "$RUNAWAY"
check "gives up at roughly WAIT_SECONDS, not double" yes \
  "$([[ $FAKE_NOW -ge 60 && $FAKE_NOW -le 70 ]] && echo yes || echo "no($FAKE_NOW)")"

WAIT_SECONDS=60
reset_clock 10
wait_for_service_port && r=reachable || r=timeout
check "reachable port returns promptly" reachable "$r"

# A wall-clock correction during boot used to extend or truncate the wait. The
# loop reads a monotonic source, so a jump in wall time cannot affect it, and
# the deadline must come from that same source or the loop never expires.
WAIT_SECONDS=20
reset_clock -1
wait_for_service_port && r=reachable || r=timeout
check "short bound still terminates" timeout "$r"
check "short bound does not run away" 0 "$RUNAWAY"
check "short bound respects its own value" yes \
  "$([[ $FAKE_NOW -ge 20 && $FAKE_NOW -le 30 ]] && echo yes || echo "no($FAKE_NOW)")"
check "wait reads a monotonic source, not the wall clock" yes \
  "$(grep -q '/proc/uptime' "$SCRIPTS/90-nas-mount.sh" && ! grep -q 'deadline=.*date +%s' "$SCRIPTS/90-nas-mount.sh" && echo yes || echo no)"

# ------------------------------------------------------------ evidence wiring
# Guard the invariants that bind branch-B evidence to the images it was
# gathered against; these are assertions about the script, not simulations.
deploy=$(cat "$SCRIPTS/device-deploy.sh")
check "prepare clears stale verdicts" yes \
  "$([[ $deploy == *'rm -f "$state_dir/test-success.env" "$state_dir/test-unsupported.env" "$state_dir/untested-flash.env"'* ]] && echo yes || echo no)"
check "evidence records all three hashes" yes \
  "$([[ $deploy == *'noop_boot_sha=%q\noriginal_boot_sha=%q'* ]] && echo yes || echo no)"
check "flash validates the no-op control hash" yes \
  "$([[ $deploy == *'the no-op control image changed since the evidence was recorded'* ]] && echo yes || echo no)"
check "flash validates the rollback hash" yes \
  "$([[ $deploy == *'the rollback image changed since the evidence was recorded'* ]] && echo yes || echo no)"
check "evidence requires a byte-identical control" yes \
  "$([[ $deploy == *'is not byte-identical'* ]] && echo yes || echo no)"
check "untested record splits attempt from completion" yes \
  "$([[ $deploy == *untested_flash_attempted_utc* && $deploy == *untested_flash_completed_utc* ]] && echo yes || echo no)"

((fails == 0)) || {
  printf 'FAIL: %d check(s) failed\n' "$fails" >&2
  exit 1
}
echo "PASS: deployment and readiness gate regressions"
