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
# Exercise the real decision path against real state directories rather than
# searching for error text: a message-only check would still pass if the
# comparison behind it were deleted.
eval "$(sed -n '/^classify_untested_evidence()/,/^# End deployment decision helpers\./p' \
  "$SCRIPTS/device-deploy.sh" | sed '/^# End deployment decision helpers\./d')"

EVIDENCE_ROOT=$(mktemp -d)
trap 'rm -rf "$EVIDENCE_ROOT"' EXIT

make_state() { # $1 = name; creates a fully consistent state dir, echoes its path
  local d="$EVIDENCE_ROOT/$1"
  mkdir -p "$d"
  printf 'custom-image-bytes\n' >"$d/custom-boot.img"
  printf 'noop-image-bytes\n' >"$d/noop-boot.img"
  printf 'original-image-bytes\n' >"$d/original-boot.img"
  {
    printf 'custom_boot_sha=%s\n' "$(sha256sum "$d/custom-boot.img" | awk '{print $1}')"
    printf 'noop_boot_sha=%s\n' "$(sha256sum "$d/noop-boot.img" | awk '{print $1}')"
    printf 'original_boot_sha=%s\n' "$(sha256sum "$d/original-boot.img" | awk '{print $1}')"
  } >"$d/test-unsupported.env"
  printf '%s\n' "$d"
}
custom_sha_of() { sha256sum "$1/custom-boot.img" | awk '{print $1}'; }

d=$(make_state good)
check "consistent evidence authorises the flash" ok \
  "$(classify_untested_evidence "$d" "$(custom_sha_of "$d")")"

d=$(make_state missing)
rm -f "$d/test-unsupported.env"
check "absent evidence is refused" no-evidence \
  "$(classify_untested_evidence "$d" "$(custom_sha_of "$d")")"

d=$(make_state rebuilt-custom)
printf 'different-custom-bytes\n' >"$d/custom-boot.img"
check "evidence for a different custom image is refused" custom-mismatch \
  "$(classify_untested_evidence "$d" "$(custom_sha_of "$d")")"

d=$(make_state rebuilt-noop)
printf 'regenerated-noop\n' >"$d/noop-boot.img"
check "a regenerated no-op control invalidates the evidence" noop-mismatch \
  "$(classify_untested_evidence "$d" "$(custom_sha_of "$d")")"

d=$(make_state rebuilt-rollback)
printf 'regenerated-rollback\n' >"$d/original-boot.img"
check "a changed rollback image invalidates the evidence" rollback-mismatch \
  "$(classify_untested_evidence "$d" "$(custom_sha_of "$d")")"

d=$(make_state deleted-noop)
rm -f "$d/noop-boot.img"
check "a missing no-op control is refused" noop-mismatch \
  "$(classify_untested_evidence "$d" "$(custom_sha_of "$d")")"

d=$(make_state deleted-rollback)
rm -f "$d/original-boot.img"
check "a missing rollback image is refused" rollback-mismatch \
  "$(classify_untested_evidence "$d" "$(custom_sha_of "$d")")"

d=$(make_state good2)
check "verdict is non-zero for every refusal" yes \
  "$(classify_untested_evidence "$EVIDENCE_ROOT/missing" x >/dev/null && echo no || echo yes)"

# Ordering invariants that are genuinely textual: the attempt record must be
# written after the size check and the completion record after the write.
deploy=$(cat "$SCRIPTS/device-deploy.sh")
attempt_at=$(printf '%s\n' "$deploy" | grep -n 'untested_flash_attempted_utc' | head -1 | cut -d: -f1)
size_at=$(printf '%s\n' "$deploy" | grep -n 'check_partition_size "\$state_dir/custom-boot.img"' | head -1 | cut -d: -f1)
write_at=$(printf '%s\n' "$deploy" | grep -n 'fastboot -s "\$serial" flash "boot_\$slot" "\$state_dir/custom-boot.img"' | head -1 | cut -d: -f1)
done_at=$(printf '%s\n' "$deploy" | grep -n 'untested_flash_completed_utc' | head -1 | cut -d: -f1)
check "attempt is recorded after the partition-size check" yes \
  "$([[ -n $attempt_at && -n $size_at && $attempt_at -gt $size_at ]] && echo yes || echo no)"
check "attempt is recorded before the write" yes \
  "$([[ -n $write_at && $attempt_at -lt $write_at ]] && echo yes || echo no)"
check "completion is recorded after the write" yes \
  "$([[ -n $done_at && $done_at -gt $write_at ]] && echo yes || echo no)"
check "prepare clears stale verdicts" yes \
  "$([[ $deploy == *'rm -f "$state_dir/test-success.env" "$state_dir/test-unsupported.env" "$state_dir/untested-flash.env"'* ]] && echo yes || echo no)"

# ------------------------------------------------------------- retry policy
# A one-shot service loses to a NAS that boots more slowly than the phone.
mount_src=$(cat "$SCRIPTS/90-nas-mount.sh")
check "retry interval is configurable" yes \
  "$([[ $mount_src == *'RETRY_INTERVAL_SECONDS=${RETRY_INTERVAL_OVERRIDE:-${RETRY_INTERVAL_SECONDS:-300}}'* ]] && echo yes || echo no)"
check "retry defaults to enabled for the installed service" yes \
  "$([[ $mount_src == *':-300}}'* ]] && echo yes || echo no)"
check "unlimited retries are the default" yes \
  "$([[ $mount_src == *'RETRY_MAX_ATTEMPTS=${RETRY_MAX_ATTEMPTS:-0}'* ]] && echo yes || echo no)"
check "interactive wrapper disables retrying" yes \
  "$([[ $(cat "$SCRIPTS/test-nas-mount.sh") == *'RETRY_INTERVAL_OVERRIDE=0'* ]] && echo yes || echo no)"
check "config errors are not retried" yes \
  "$([[ $mount_src == *'non-retryable condition'* ]] && echo yes || echo no)"
check "a failed mount command is retried" yes \
  "$([[ $mount_src == *'mount command failed with status'* ]] && echo yes || echo no)"

# Exercise the loop's decision table with a scripted attempt sequence.
run_retry_loop() { # $1 = space-separated attempt_mount statuses
  local i=0 attempt=0 attempt_status
  local -a seq
  read -r -a seq <<<"$1"
  local RETRY_INTERVAL_SECONDS=${2:-1} RETRY_MAX_ATTEMPTS=${3:-0}
  RETRY_LOG=""
  while :; do
    attempt=$((attempt + 1))
    attempt_status=${seq[i]:-1}
    i=$((i + 1))
    case "$attempt_status" in
      0)
        RETRY_LOG="mounted after $attempt"
        return 0
        ;;
      2)
        RETRY_LOG="fatal at $attempt"
        return 1
        ;;
    esac
    [[ $RETRY_INTERVAL_SECONDS -gt 0 ]] || {
      RETRY_LOG="no-retry at $attempt"
      return 1
    }
    if [[ $RETRY_MAX_ATTEMPTS -gt 0 && $attempt -ge $RETRY_MAX_ATTEMPTS ]]; then
      RETRY_LOG="gave up after $attempt"
      return 1
    fi
    ((attempt > 50)) && {
      RETRY_LOG="RUNAWAY"
      return 1
    }
  done
}

run_retry_loop "1 1 0" 1 0 || true
check "recovers when the NAS appears later" "mounted after 3" "$RETRY_LOG"
run_retry_loop "1 2" 1 0 || true
check "stops immediately on a config error" "fatal at 2" "$RETRY_LOG"
run_retry_loop "1 1 1" 0 0 || true
check "one-shot mode does not retry" "no-retry at 1" "$RETRY_LOG"
run_retry_loop "1 1 1 1 1" 1 3 || true
check "honours a maximum attempt count" "gave up after 3" "$RETRY_LOG"
run_retry_loop "0" 1 0 || true
check "first-attempt success needs no retry" "mounted after 1" "$RETRY_LOG"

((fails == 0)) || {
  printf 'FAIL: %d check(s) failed\n' "$fails" >&2
  exit 1
}
echo "PASS: deployment and readiness gate regressions"
