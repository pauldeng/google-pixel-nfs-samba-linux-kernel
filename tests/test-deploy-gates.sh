#!/usr/bin/env bash
# SC2016: the single-quoted strings below are literal source patterns searched
#         for in the scripts under test; expansion would defeat the purpose.
# SC2034: WAIT_SECONDS is read by the wait helper that is eval'd in from
#         90-nas-mount.sh, so ShellCheck cannot see the use.
# SC2329: the stubs below are invoked indirectly, by functions eval'd in from
#         the scripts under test, so ShellCheck sees no call site.
# shellcheck disable=SC2016,SC2034,SC2329
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

# The production call site must capture the classifier's status. errexit aborts
# a failing assignment at that level, which would skip the case block entirely
# and leave every refusal unexplained. Testing the classifier alone missed this.
deploy_src=$(cat "$SCRIPTS/device-deploy.sh")
check "call site captures the classifier status" yes \
  "$([[ $deploy_src == *'evidence_verdict=$(classify_untested_evidence "$state_dir" "$current_sha") || evidence_status=$?'* ]] && echo yes || echo no)"

# Prove the pattern itself keeps the diagnostics reachable under errexit.
call_site_reaches_case() { # $1 = "guarded" | "bare"
  bash -c '
    set -euo pipefail
    classify() { printf "no-evidence\n"; return 1; }
    if [ "$1" = guarded ]; then
      st=0; v=$(classify) || st=$?
    else
      v=$(classify)
    fi
    case "$v" in no-evidence) printf "reached\n" ;; esac
  ' _ "$1" 2>/dev/null || true
}
check "guarded assignment reaches the diagnostics" reached "$(call_site_reaches_case guarded)"
check "bare assignment does not (this was the bug)" "" "$(call_site_reaches_case bare)"

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

# --------------------------------------------- attempt_mount failure handling
# attempt_mount is invoked as the left side of `||`, which disables errexit for
# its entire body in both Bash and mksh. Unguarded operations therefore fall
# through instead of aborting, and a permanent local failure gets misclassified
# as retryable, producing an endless loop.
#
# The stubs must let control reach the mount command, otherwise an earlier
# guard masks the one under test. /system/bin/mount does not exist on the test
# host, so the mount step fails naturally with 127 and would be classified
# retryable unless an earlier guard correctly stops it.
eval "$(sed -n '/^attempt_mount()/,/^}/p' "$SCRIPTS/90-nas-mount.sh")"

ATTEMPT_ROOT=$(mktemp -d)
printf 'a-real-password\n' >"$ATTEMPT_ROOT/secret"
TARGET="$ATTEMPT_ROOT/target"
PROTOCOL=smb SELINUX_CONTEXT="" SMB_SECRET="$ATTEMPT_ROOT/secret" SMB_SOURCE=//x/y
SMB_USER=u MOUNT_MODE=ro service_port=445
log() { :; }
fail() {
  printf 'unexpected-fail\n'
  exit 9
}
fail_probe_and_unmount() {
  printf 'unexpected-fail\n'
  exit 9
}
validate_mount() { return 1; }
mounted_line() { printf ''; }
probe_mount() { return 0; }
wait_for_service_port() { return 0; }

run_attempt() {
  local st=0
  attempt_mount >/dev/null 2>&1 || st=$?
  printf '%s\n' "$st"
}

# Sanity: with everything healthy, the mount step itself fails on this host and
# must be classified retryable. This is the control for the checks below.
rm -rf "$TARGET"
check "a failed mount command alone is retryable" 1 "$(run_attempt)"

# The real regression: if the mount point cannot be created, that is permanent.
# Without an explicit guard the failure falls through to the mount step and is
# misreported as retryable, which loops forever.
rm -rf "$TARGET"
mkdir() { return 1; }
mkdir_verdict=$(run_attempt)
unset -f mkdir
check "an unusable mount point is non-retryable, not an endless retry" 2 "$mkdir_verdict"

command mkdir -p "$TARGET"
wait_for_service_port() { return 1; }
check "an unreachable port stays retryable" 1 "$(run_attempt)"
wait_for_service_port() { return 0; }

printf 'x\n' >"$TARGET/pre-existing"
check "a non-empty target is non-retryable" 2 "$(run_attempt)"
rm -rf "$ATTEMPT_ROOT"

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
check "local faults are not retried" yes \
  "$([[ $mount_src == *'non-retryable condition'* ]] && echo yes || echo no)"
check "remote mount-command failures are retried" yes \
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

# ------------------------------------------------ magisk boot install gating
# This script writes a boot partition, so it must carry the same gates as the
# rest of the project. The Phase 0 procedure it replaces had none of them.
magisk_src=$(cat "$SCRIPTS/install-magisk-boot.sh")
check "binds to codename and locked build" yes \
  "$([[ $magisk_src == *'unsupported device: $device'* && $magisk_src == *'Android build/version mismatch'* ]] && echo yes || echo no)"
check "verifies the stock image, not merely records it" yes \
  "$([[ $magisk_src == *'sha256sum -c stock-boot.img.sha256'* ]] && echo yes || echo no)"
check "compares Fastboot product programmatically" yes \
  "$([[ $magisk_src == *'Fastboot product mismatch'* ]] && echo yes || echo no)"
check "compares Fastboot slot programmatically" yes \
  "$([[ $magisk_src == *'Fastboot slot mismatch'* ]] && echo yes || echo no)"
check "compares unlocked state programmatically" yes \
  "$([[ $magisk_src == *'bootloader is not unlocked'* ]] && echo yes || echo no)"
check "requires an image-bound confirmation token" yes \
  "$([[ $magisk_src == *'FLASHBOOT:$device:$slot:${patched_sha:0:12}'* ]] && echo yes || echo no)"
check "rejects an unpatched image" yes \
  "$([[ $magisk_src == *'identical to the stock image'* ]] && echo yes || echo no)"
check "names the slot explicitly rather than trusting the A/B default" yes \
  "$([[ $magisk_src == *'flash "boot_$slot"'* ]] && echo yes || echo no)"
check "every adb call is bound to the serial" yes \
  "$(printf '%s\n' "$magisk_src" | grep -E '^\s*adb ' | grep -qv 'adb -s "\$serial"\|adb devices' && echo no || echo yes)"

# The glob resolution must terminate, not merely warn. The Markdown version
# ended its failure branch with a successful echo, so zero matches fell through
# to `adb pull ""` and several matches silently selected a stale image.
eval "$(sed -n '/^resolve_patched_image()/,/^}/p' "$SCRIPTS/install-magisk-boot.sh")"
serial=UNUSED
# The resolver compares against names recorded at stage time; an empty
# record means every image found counts as new. set -u needs it defined.
state_dir=$(mktemp -d)
: >"$state_dir/pre-existing-patched.txt"
probe_resolution() { # $1 = newline-separated device listing
  local out
  FAKE_LS=$1
  # Stub the listing helper, not adb: the resolver delegates to it, and the
  # helper's own clean-phone behaviour is asserted separately.
  list_remote_patched() {
    [[ -n $FAKE_LS ]] && printf '%s\n' "$FAKE_LS"
    return 0
  }
  out=$( (resolve_patched_image) 2>/dev/null) && printf 'selected:%s\n' "$out" || printf 'stopped\n'
}
check "zero patched images stops" stopped "$(probe_resolution '')"
check "two patched images stop rather than guessing" stopped \
  "$(probe_resolution '/sdcard/Download/magisk_patched-1_aaa.img
/sdcard/Download/magisk_patched-2_bbb.img')"
check "exactly one patched image is selected" "selected:/sdcard/Download/magisk_patched-1_aaa.img" \
  "$(probe_resolution '/sdcard/Download/magisk_patched-1_aaa.img')"

# ------------------------------------------------- boot image authentication
# Creating a checksum then verifying it proves only that a file has not changed;
# it says nothing about provenance. These check that a file really is a boot
# image for this device and build.
eval "$(sed -n '/^# Android boot image header v0/,/^resolve_patched_image()/p' \
  "$SCRIPTS/install-magisk-boot.sh" | sed '$d')"

BOOTDIR=$(mktemp -d)
device=sailfish
make_boot() { # $1=path $2=hardware $3=os_version escapes [$4=kernel_sz $5=ramdisk_sz]
  # Offsets: magic 0, kernel_size 8, ramdisk_size 16, page_size 36,
  # header_version 40, os_version 44, cmdline 64. Body must match the header.
  local ks=${4:-4096} rs=${5:-4096} ps=4096
  # shellcheck disable=SC2059 # $3 carries \x escapes and must be the format.
  {
    printf 'ANDROID!'
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((ks & 255)) $((ks >> 8 & 255)) $((ks >> 16 & 255)) $((ks >> 24 & 255)))"
    head -c 4 /dev/zero
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((rs & 255)) $((rs >> 8 & 255)) $((rs >> 16 & 255)) $((rs >> 24 & 255)))"
    head -c 16 /dev/zero
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((ps & 255)) $((ps >> 8 & 255)) $((ps >> 16 & 255)) $((ps >> 24 & 255)))"
    head -c 4 /dev/zero
    printf "$3"
    head -c 16 /dev/zero
    printf 'androidboot.hardware=%s rest' "$2"
    head -c 4096 /dev/zero
    head -c "$ks" /dev/zero
    head -c "$rs" /dev/zero
  } >"$1"
}
probe_validate() { (validate_boot_image "$1" img) >/dev/null 2>&1 && echo ok || echo rejected; }

make_boot "$BOOTDIR/good.img" sailfish '\x3a\x01\x00\x14'
check "a correct boot image is accepted" ok "$(probe_validate "$BOOTDIR/good.img")"

make_boot "$BOOTDIR/otherdev.img" marlin '\x3a\x01\x00\x14'
check "a boot image for another device is rejected" rejected "$(probe_validate "$BOOTDIR/otherdev.img")"

make_boot "$BOOTDIR/oldbuild.img" sailfish '\x39\x01\x00\x14'
check "a boot image from another build is rejected" rejected "$(probe_validate "$BOOTDIR/oldbuild.img")"

make_boot "$BOOTDIR/nokernel.img" sailfish '\\x3a\\x01\\x00\\x14' 0 4096
check "a zero-length kernel is rejected" rejected "$(probe_validate "$BOOTDIR/nokernel.img")"

make_boot "$BOOTDIR/noramdisk.img" sailfish '\\x3a\\x01\\x00\\x14' 4096 0
check "a zero-length ramdisk is rejected" rejected "$(probe_validate "$BOOTDIR/noramdisk.img")"

make_boot "$BOOTDIR/full.img" sailfish '\\x3a\\x01\\x00\\x14'
head -c 6000 "$BOOTDIR/full.img" >"$BOOTDIR/trunc.img"
check "a truncated image is rejected" rejected "$(probe_validate "$BOOTDIR/trunc.img")"

head -c 4096 /dev/urandom >"$BOOTDIR/junk.img"
check "a random file is rejected" rejected "$(probe_validate "$BOOTDIR/junk.img")"
check "a missing file is rejected" rejected "$(probe_validate "$BOOTDIR/absent.img")"
rm -rf "$BOOTDIR"

magisk_src2=$(cat "$SCRIPTS/install-magisk-boot.sh")
check "both images are authenticated, not just checksummed" yes \
  "$([[ $magisk_src2 == *'validate_boot_image "$stock_boot" "stock boot image"'* &&
    $magisk_src2 == *'validate_boot_image "$state_dir/magisk-patched.img" "patched boot image"'* ]] && echo yes || echo no)"
check "the rollback image is size-checked too" yes \
  "$([[ $magisk_src2 == *'check_fits_partition "$state_dir/stock-boot.img" "stock rollback image"'* ]] && echo yes || echo no)"
check "structural fields are validated" yes \
  "$([[ $magisk_src2 == *'zero-length kernel'* && $magisk_src2 == *'implausible page size'* && $magisk_src2 == *'is truncated'* ]] && echo yes || echo no)"
# ------------------------------------------------ official factory provenance
# The stock boot image has exactly one permitted source: Google's official
# factory archive for the locked build, at a pinned URL, verified against the
# SHA-256 Google publishes. The operator supplies neither. These run the pinning
# logic instead of grepping for its error strings, so removing a check fails.
eval "$(sed -n "/^# Google's official factory archives/,/^obtain_stock_boot()/p" \
  "$SCRIPTS/install-magisk-boot.sh" | sed '$d')"

# shellcheck source=Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/source-lock.env
. "$SCRIPTS/source-lock.env" # verify_factory_pin compares against ANDROID_BUILD

probe_pin() { (verify_factory_pin "$1") >/dev/null 2>&1 && echo ok || echo rejected; }
lower_build=$(printf '%s' "$ANDROID_BUILD" | tr '[:upper:]' '[:lower:]')

for dev in marlin sailfish; do
  pinned_name=$(factory_archive "$dev")
  pinned_sha=$(factory_sha256 "$dev")
  check "$dev has a pinned official archive" ok "$(probe_pin "$dev")"
  # Google names each archive after the first eight digits of its own checksum,
  # so the two constants cross-check each other; a typo in either is caught.
  check "$dev archive name restates its published checksum" "${pinned_sha:0:8}" \
    "$(printf '%s' "$pinned_name" | sed -n 's/.*-factory-\([0-9a-f]*\)\.zip$/\1/p')"
  check "$dev archive is for the locked build" yes \
    "$([[ $pinned_name == "$dev-$lower_build-factory-"* ]] && echo yes || echo no)"
done

check "an unsupported device has no pinned archive" rejected "$(probe_pin walleye)"
check "the archive is fetched from Google's own host" yes \
  "$([[ $FACTORY_BASE_URL == https://dl.google.com/* ]] && echo yes || echo no)"
check "a checksum that disagrees with the archive name is rejected" rejected \
  "$( (
    factory_sha256() { printf '%064d\n' 0; }
    verify_factory_pin sailfish
  ) >/dev/null 2>&1 && echo ok || echo rejected)"
check "a pinned archive from another build is rejected" rejected \
  "$( (
    ANDROID_BUILD=QP1A.190711.020
    verify_factory_pin sailfish
  ) >/dev/null 2>&1 && echo ok || echo rejected)"

ARCHDIR=$(mktemp -d)
head -c 1024 /dev/urandom >"$ARCHDIR/fake.zip"
check "an archive failing its published checksum is rejected" rejected \
  "$( (verify_archive_checksum "$ARCHDIR/fake.zip" "$(factory_sha256 sailfish)") \
    >/dev/null 2>&1 && echo ok || echo rejected)"
check "an archive matching its checksum is accepted" ok \
  "$( (verify_archive_checksum "$ARCHDIR/fake.zip" \
    "$(sha256sum "$ARCHDIR/fake.zip" | awk '{print $1}')") \
    >/dev/null 2>&1 && echo ok || echo rejected)"
rm -rf "$ARCHDIR"

# The real archive nests <device>-<build>/image-<device>-<build>.zip. An
# 'image-*.zip' glob cannot cross that leading directory and matches nothing, so
# build a fixture with the same layout and run the extraction for real.
FIXDIR=$(mktemp -d)
(
  cd "$FIXDIR" || exit 1
  mkdir -p sailfish-qp1a.191005.007.a3
  head -c 2048 /dev/urandom >boot.img
  zip -q -X inner.zip boot.img
  mv inner.zip sailfish-qp1a.191005.007.a3/image-sailfish-qp1a.191005.007.a3.zip
  : >sailfish-qp1a.191005.007.a3/flash-all.sh
  zip -q -r -X -0 outer.zip sailfish-qp1a.191005.007.a3
)
mkdir -p "$FIXDIR/out"
stock_boot=""
check "boot.img is extracted from the real nested layout" ok \
  "$( (extract_boot_from_archive "$FIXDIR/outer.zip" "$FIXDIR/out") >/dev/null 2>&1 && echo ok || echo failed)"
check "the extracted boot.img is the one inside the archive" yes \
  "$([[ -f $FIXDIR/out/boot.img ]] && cmp -s "$FIXDIR/boot.img" "$FIXDIR/out/boot.img" && echo yes || echo no)"
check "the gigabyte inner archive is not left behind" yes \
  "$([[ -z $(find "$FIXDIR/out" -name 'image-*.zip' -print -quit) ]] && echo yes || echo no)"
rm -rf "$FIXDIR"

check "an archive of the wrong size is rejected before hashing" rejected \
  "$( (
    tmp=$(mktemp)
    head -c 16 /dev/zero >"$tmp"
    verify_archive_size "$tmp" "$(factory_size sailfish)"
  ) >/dev/null 2>&1 && echo ok || echo rejected)"
check "an archive of the pinned size passes the size gate" ok \
  "$( (
    tmp=$(mktemp)
    head -c 16 /dev/zero >"$tmp"
    verify_archive_size "$tmp" 16
  ) >/dev/null 2>&1 && echo ok || echo rejected)"

# ------------------------------------------------------- Magisk app provenance
# Step 3 of Phase 0 factory-resets the phone, so the Magisk app is gone. Nothing
# downstream works until it is back, and it must be the validated version from
# the official release, authenticated by its signing certificate.
# The MAGISK_* constants are readonly and already in scope: the eval above
# spans them. Re-evaluating here would abort on the readonly reassignment.
check "the Magisk app is fetched from the official release" yes \
  "$([[ $MAGISK_APK_URL == https://github.com/topjohnwu/Magisk/releases/download/* ]] && echo yes || echo no)"
check "the pinned app URL names the pinned version" yes \
  "$([[ $MAGISK_APK_URL == *"/v$MAGISK_VERSION/Magisk-v$MAGISK_VERSION.apk" ]] && echo yes || echo no)"
check "the app checksum is a SHA-256" yes \
  "$([[ $MAGISK_APK_SHA256 =~ ^[0-9a-f]{64}$ ]] && echo yes || echo no)"
check "the signing certificate is pinned" yes \
  "$([[ $MAGISK_APK_CERT_SHA256 =~ ^([0-9A-F]{2}:){31}[0-9A-F]{2}$ ]] && echo yes || echo no)"
check "the app package is Magisk's" com.topjohnwu.magisk "$MAGISK_PACKAGE"
# The runbook records which version was proven on hardware. A pin that drifts
# from that record is either an unvalidated upgrade or a stale doc.
check "the pinned version matches the hardware-validated one" yes \
  "$(grep -q "Magisk $MAGISK_VERSION" "$PROJECT_ROOT/docs/ai-agent-runbook.md" && echo yes || echo no)"

# The installer must refuse anything whose signer is not John Wu's certificate,
# which is what makes this stronger than a self-recorded file hash.
magisk_src3=$(cat "$SCRIPTS/install-magisk-boot.sh")
check "the app install is gated on the certificate, not only the hash" yes \
  "$([[ $magisk_src3 == *'[[ $fingerprint == "$MAGISK_APK_CERT_SHA256" ]] || {'* ]] && echo yes || echo no)"
check "the installed version is confirmed on the phone after install" yes \
  "$([[ $magisk_src3 == *'expected Magisk app $MAGISK_VERSION on the phone'* ]] && echo yes || echo no)"
check "staging installs the app before pushing boot.img" yes \
  "$(awk '/^  stage\)/,/^  flash\)/' "$SCRIPTS/install-magisk-boot.sh" \
    | awk '/ensure_magisk_app/{a=NR} /push .*boot\.img/{b=NR} END{print (a && b && a < b) ? "yes" : "no"}')"

# The app must be verified and reinstalled even when the reported version
# already matches: a package name and versionName are self-declared and say
# nothing about who signed the app that will patch the boot image.
eval "$(sed -n '/^ensure_magisk_app()/,/^}/p' "$SCRIPTS/install-magisk-boot.sh")"

APPLOG=""
INSTALLED_VERSION=""
installed_magisk_version() { printf '%s\n' "$INSTALLED_VERSION"; }
verify_archive_size() { printf 'size\n' >>"$APPLOG"; }
verify_archive_checksum() { printf 'checksum\n' >>"$APPLOG"; }
verify_apk_signature() {
  printf 'certificate\n' >>"$APPLOG"
  printf '%s\n' "$MAGISK_APK_CERT_SHA256"
}
adb() {
  printf 'install\n' >>"$APPLOG"
  INSTALLED_VERSION=$MAGISK_VERSION
}
probe_app() { # $1 = version already on the phone; echoes the steps performed
  local ws
  ws=$(mktemp -d)
  workspace=$ws
  mkdir -p "$ws/factory"
  : >"$ws/factory/Magisk-v$MAGISK_VERSION.apk" # present, so no download is tried
  APPLOG="$ws/log"
  : >"$APPLOG"
  INSTALLED_VERSION=$1
  serial=STUB
  (ensure_magisk_app) >/dev/null 2>&1 || true
  tr '\n' ',' <"$APPLOG"
  rm -rf "$ws"
}

check "a matching version is still verified and reinstalled" 'size,checksum,certificate,install,' \
  "$(probe_app "$MAGISK_VERSION")"
check "an absent app is verified and installed" 'size,checksum,certificate,install,' \
  "$(probe_app '')"
check "a different version is verified and replaced" 'size,checksum,certificate,install,' \
  "$(probe_app '25.2')"

# A wrong signer must stop before anything is installed.
verify_apk_signature() {
  printf 'certificate\n' >>"$APPLOG"
  printf '%s\n' "AA:BB"
}
check "a wrong signing certificate stops before install" 'size,checksum,certificate,' \
  "$(probe_app "$MAGISK_VERSION")"
verify_apk_signature() {
  printf 'certificate\n' >>"$APPLOG"
  printf '%s\n' "$MAGISK_APK_CERT_SHA256"
}
unset -f adb installed_magisk_version verify_archive_size verify_archive_checksum verify_apk_signature

# The signature check must be exercised with real cryptography, not a stub. A
# stubbed extractor cannot tell "this certificate blob is present" apart from
# "the key owning it actually signed something", which is the distinction an
# earlier version of this script got wrong.
eval "$(sed -n '/^verify_apk_signature()/,/^}/p' "$SCRIPTS/install-magisk-boot.sh")"

SIGDIR=$(mktemp -d)
workspace="$SIGDIR/ws"
mkdir -p "$workspace/factory"
(
  cd "$SIGDIR" || exit 1
  for who in publisher impostor; do
    openssl req -x509 -newkey rsa:2048 -keyout "$who.key" -out "$who.crt" \
      -days 2 -nodes -subj "/CN=$who" >/dev/null 2>&1
  done
  mkdir -p apk/META-INF
  printf 'Manifest-Version: 1.0\r\n\r\nName: payload\r\nSHA-256-Digest: irrelevant\r\n\r\n' \
    >apk/META-INF/MANIFEST.MF
  manifest_digest=$(openssl dgst -sha256 -binary apk/META-INF/MANIFEST.MF | openssl base64 -A)
  printf 'Signature-Version: 1.0\r\nSHA-256-Digest-Manifest: %s\r\n\r\n' "$manifest_digest" \
    >apk/META-INF/CERT.SF
  printf 'payload-bytes\n' >apk/payload
  sign() { # $1 = signer name, $2 = file to sign, $3 = output
    openssl smime -sign -in "$2" -out "$3" -outform DER \
      -inkey "$1.key" -signer "$1.crt" -binary -noattr >/dev/null 2>&1
  }
  sign publisher apk/META-INF/CERT.SF apk/META-INF/CERT.RSA
  (cd apk && zip -q -r -X ../good.apk .)

  # Same certificate blob, but the signature was made over different content.
  cp -r apk bad-sig && printf 'tampered\r\n' >>bad-sig/META-INF/CERT.SF
  (cd bad-sig && zip -q -r -X ../tampered-sf.apk .)

  # A different key signs its own CERT.SF; the blob is well formed and yields a
  # fingerprint, but it did not sign this archive's CERT.SF.
  cp -r apk impostor-apk
  sign impostor apk/META-INF/CERT.SF impostor-sig.p7
  cp impostor-sig.p7 impostor-apk/META-INF/CERT.RSA
  (cd impostor-apk && zip -q -r -X ../impostor.apk .)

  # Valid signature over CERT.SF, but MANIFEST.MF no longer matches its digest.
  cp -r apk bad-manifest && printf 'Name: sneaked\r\n\r\n' >>bad-manifest/META-INF/MANIFEST.MF
  (cd bad-manifest && zip -q -r -X ../bad-manifest.apk .)
)
publisher_fp=$(openssl x509 -in "$SIGDIR/publisher.crt" -noout -fingerprint -sha256 \
  | sed 's/^.*Fingerprint=//')
impostor_fp=$(openssl x509 -in "$SIGDIR/impostor.crt" -noout -fingerprint -sha256 \
  | sed 's/^.*Fingerprint=//')

check "a genuine signature yields the signer fingerprint" "$publisher_fp" \
  "$(verify_apk_signature "$SIGDIR/good.apk")"
check "a tampered CERT.SF is rejected" "" \
  "$(verify_apk_signature "$SIGDIR/tampered-sf.apk")"
# A valid signature by the wrong key is still a valid signature. The function's
# job is to report who signed; refusing that signer is the caller's job, via the
# pinned fingerprint. Assert both halves rather than conflating them.
check "another key's valid signature is reported as that key" yes \
  "$([[ $(verify_apk_signature "$SIGDIR/impostor.apk") == "$impostor_fp" ]] && echo yes || echo no)"
check "another key never passes as the publisher" yes \
  "$([[ $(verify_apk_signature "$SIGDIR/impostor.apk") != "$publisher_fp" ]] && echo yes || echo no)"
check "a manifest that no longer matches its digest is rejected" "" \
  "$(verify_apk_signature "$SIGDIR/bad-manifest.apk")"
check "a file that is not an APK is rejected" "" \
  "$(verify_apk_signature "$SIGDIR/publisher.crt")"

# The chain above stops at MANIFEST.MF: it does not re-hash every entry, and it
# does not read the v2/v3 signing block Android itself uses. Entry-level
# tampering is caught by the pinned whole-file checksum, which runs first. Prove
# that layer rather than claiming the signature check covers it.
cp "$SIGDIR/good.apk" "$SIGDIR/entry-tampered.apk"
printf 'evil-bytes\n' >"$SIGDIR/payload"
(cd "$SIGDIR" && zip -q "entry-tampered.apk" payload)
check "entry tampering does not break the CERT.SF chain (documented limit)" "$publisher_fp" \
  "$(verify_apk_signature "$SIGDIR/entry-tampered.apk")"
check "entry tampering is caught by the pinned checksum instead" rejected \
  "$( (verify_archive_checksum "$SIGDIR/entry-tampered.apk" \
    "$(sha256sum "$SIGDIR/good.apk" | awk '{print $1}')") >/dev/null 2>&1 && echo ok || echo rejected)"
rm -rf "$SIGDIR"

# --------------------------------------------------- rollback slot flexibility
# The deployment policy is explicit that the bootloader may fail over to the
# untouched slot after a bad boot, and that recovery must not trust Fastboot's
# current-slot. Rollback runs exactly then, so requiring the slots to agree
# would disable recovery in the only case it exists for. The write names
# boot_<slot> explicitly, so a mismatch cannot reach the safe slot.
eval "$(sed -n '/^require_fastboot_state()/,/^}/p' "$SCRIPTS/install-magisk-boot.sh")"

FB_PRODUCT=sailfish
FB_SLOT=b
FB_UNLOCKED=yes
fastboot() { printf '%s\tfastboot\n' "$serial"; }
fastboot_value() {
  case "$1" in
    product) printf '%s\n' "$FB_PRODUCT" ;;
    current-slot) printf '%s\n' "$FB_SLOT" ;;
    unlocked) printf '%s\n' "$FB_UNLOCKED" ;;
  esac
}
serial=STUB
device=sailfish
slot=b
probe_fb() { (require_fastboot_state "$@") >/dev/null 2>&1 && echo ok || echo rejected; }

FB_SLOT=b
check "flash accepts a matching current slot" ok "$(probe_fb)"
check "rollback accepts a matching current slot" ok "$(probe_fb 0)"

FB_SLOT=a # the bootloader failed over to the untouched slot
check "flash rejects a mismatched current slot" rejected "$(probe_fb)"
check "rollback proceeds after an A/B failover" ok "$(probe_fb 0)"
# Capture, then match. Piping a multi-line producer into `grep -q` under
# pipefail made this check fail intermittently (2 of 15 runs): grep exits on the
# first match while the producer is still writing, and the pipeline's status
# then reflects the producer, not the match. A flaky gate is worse than no gate.
failover_output=$( (require_fastboot_state 0) 2>&1 || true)
check "rollback reports the failover rather than staying silent" yes \
  "$(case $failover_output in *"current slot 'a'"*) echo yes ;; *) echo no ;; esac)"

FB_SLOT=b
FB_PRODUCT=marlin
check "rollback still rejects the wrong product" rejected "$(probe_fb 0)"
FB_PRODUCT=sailfish
FB_UNLOCKED=no
check "rollback still rejects a locked bootloader" rejected "$(probe_fb 0)"
FB_UNLOCKED=yes
unset -f fastboot fastboot_value

check "the rollback action relaxes only the slot check" yes \
  "$(awk '/^  rollback\)/,/^  \*\)/' "$SCRIPTS/install-magisk-boot.sh" \
    | grep -q 'require_fastboot_state 0' && echo yes || echo no)"
check "the flash action keeps the strict slot check" yes \
  "$(awk '/^  flash\)/,/^  rollback\)/' "$SCRIPTS/install-magisk-boot.sh" \
    | grep -qE 'require_fastboot_state$' && echo yes || echo no)"

# ------------------------------------------------------------- bounded waiting
# A pending Magisk Grant dialog must not hang the run: an unbounded su bypasses
# the 180-second limits either side of it and contradicts the "do not touch the
# phone" rule, which this is the one documented exception to.
check "the post-flash root check is bounded" yes \
  "$([[ $magisk_src3 == *'until out=$(timeout 15 adb -s "$serial" shell "su -c $command_arg" 2>/dev/null)'* ]] && echo yes || echo no)"
check "no unbounded root_cmd id remains after the flash" yes \
  "$([[ $magisk_src3 != *'[[ $(root_cmd id) =='* ]] && echo yes || echo no)"
check "the user is told to press Grant before the wait starts" yes \
  "$(awk '/^wait_for_root\(\)/,/^}/' "$SCRIPTS/install-magisk-boot.sh" \
    | awk '/press Grant/{a=NR} /until out=/{b=NR} END{print (a && b && a < b) ? "yes" : "no"}')"

# -------------------------------------------------------------- gated rollback
# The emergency path printed on failure must go through the same gates as the
# flash, not a raw fastboot write.
check "a rollback action exists" yes \
  "$([[ $magisk_src3 == *'  rollback)'* ]] && echo yes || echo no)"
for gate in 'sha256sum -c stock-boot.img.sha256' \
  'validate_boot_image "$state_dir/stock-boot.img" "stock rollback image"' \
  'require_fastboot_state' \
  'check_fits_partition "$state_dir/stock-boot.img" "stock rollback image"'; do
  check "rollback re-checks: ${gate:0:46}" yes \
    "$(awk '/^  rollback\)/,/^  \*\)/' "$SCRIPTS/install-magisk-boot.sh" \
      | grep -qF "$gate" && echo yes || echo no)"
done
check "rollback demands its own token" yes \
  "$(awk '/^  rollback\)/,/^  \*\)/' "$SCRIPTS/install-magisk-boot.sh" \
    | grep -q 'confirm_rollback == "\$expected"' && echo yes || echo no)"
check "the recovery message leads with the gated command" yes \
  "$(awk '/^print_rollback_command\(\)/,/^}/' "$SCRIPTS/install-magisk-boot.sh" \
    | awk '/--confirm-rollback/{a=NR} /LAST RESORT ONLY/{b=NR} END{print (a && b && a < b) ? "yes" : "no"}')"

eval "$(sed -n '/^rollback_token()/,/^}/p' "$SCRIPTS/install-magisk-boot.sh")"
TOKDIR=$(mktemp -d)
printf 'stock-bytes\n' >"$TOKDIR/img"
device=sailfish
slot=b
tok=$(rollback_token "$TOKDIR/img")
check "the rollback token is bound to device, slot and image" yes \
  "$([[ $tok == "ROLLBACK:sailfish:b:$(sha256sum "$TOKDIR/img" | cut -c1-12)" ]] && echo yes || echo no)"
printf 'different-bytes\n' >"$TOKDIR/img"
check "a different image yields a different token" yes \
  "$([[ $(rollback_token "$TOKDIR/img") != "$tok" ]] && echo yes || echo no)"
rm -rf "$TOKDIR"
device=sailfish

# ------------------------------------------------- NAS photo service decisions
# The service mounts the share where Photos can see it and keeps MediaStore
# told about new files. Its two risky decisions are when to tear the mount down
# and whether to trust a mount it just made.
eval "$(sed -n '/^probe_service_port()/,/^}/p;/^nas_reachable()/,/^}/p;/^mount_line()/,/^}/p;/^validate_mount()/,/^}/p' \
  "$SCRIPTS/96-nas-photos.sh")"
log() { :; }
sleep() { :; } # the retry loop must not really wait during tests

PROBE_SCRIPT=""
PROBE_CALLS=0
probe_service_port() {
  PROBE_CALLS=$((PROBE_CALLS + 1))
  case $PROBE_SCRIPT in
    always-up) return 0 ;;
    always-down) return 1 ;;
    up-on-2nd) [[ $PROBE_CALLS -ge 2 ]] ;;
    up-on-3rd) [[ $PROBE_CALLS -ge 3 ]] ;;
  esac
}
probe_reach() {
  PROBE_SCRIPT=$1
  PROBE_CALLS=0
  UNREACHABLE_CONFIRMATIONS=3
  nas_reachable && printf 'reachable:%s\n' "$PROBE_CALLS" || printf 'down:%s\n' "$PROBE_CALLS"
}

check "a reachable NAS costs a single probe" reachable:1 "$(probe_reach always-up)"
# One failed probe must never tear down a working mount: during development a
# probe written with an option toybox nc lacks failed every time and unmounted
# the share out from under an in-flight upload.
check "a transient failure does not report the NAS down" reachable:2 "$(probe_reach up-on-2nd)"
check "recovery on the last allowed probe still counts" reachable:3 "$(probe_reach up-on-3rd)"
check "a genuinely down NAS is confirmed, not assumed" down:3 "$(probe_reach always-down)"

UNREACHABLE_CONFIRMATIONS=1
PROBE_SCRIPT=up-on-2nd
PROBE_CALLS=0
check "one confirmation means no retry at all" down \
  "$(nas_reachable && echo reachable || echo down)"

# The probe must use the form that works on this device. toybox nc has no -z.
photo_src=$(cat "$SCRIPTS/96-nas-photos.sh")
check "the readiness probe does not use the unsupported nc -z" yes \
  "$([[ $photo_src != *'nc -z'* ]] && echo yes || echo no)"
check "the probe uses the toybox form proven by the other service" yes \
  "$([[ $photo_src == *'/system/bin/toybox nc -4 -w 2 -q 1'* ]] && echo yes || echo no)"
# echo_interval does not exist in 3.18; passing it makes the kernel reject the
# entire mount with "Unknown mount option".
check "the mount does not pass echo_interval" yes \
  "$([[ $photo_src != *'echo_interval'* || $photo_src == *'Do not add echo_interval'* ]] && echo yes || echo no)"
check "the mount is made in init's namespace so it reaches apps" yes \
  "$([[ $photo_src == *'nsenter --mount=/proc/1/ns/mnt'* ]] && echo yes || echo no)"

# validate_mount reads /proc/mounts; stub grep so the parsing can be driven.
RUNTIME_TARGET=/mnt/runtime/write/emulated/0/DCIM/NAS-Live
SMB_SOURCE=//192.168.0.233/Multimedia/Photo/Google-Photos-Pixel-Stage
FAKE_MOUNT_LINE=""
grep() {
  [[ -n $FAKE_MOUNT_LINE ]] || return 1
  printf '%s\n' "$FAKE_MOUNT_LINE"
}
probe_validate_mount() { validate_mount >/dev/null 2>&1 && echo ok || echo rejected; }

good="$SMB_SOURCE $RUNTIME_TARGET cifs ro,context=u:object_r:media_rw_data_file:s0,nosuid 0 0"
FAKE_MOUNT_LINE=$good
check "a correct mount validates" ok "$(probe_validate_mount)"
FAKE_MOUNT_LINE=""
check "an absent mount is rejected" rejected "$(probe_validate_mount)"
FAKE_MOUNT_LINE="//192.168.0.9/Other $RUNTIME_TARGET cifs ro,context=u:object_r:media_rw_data_file:s0 0 0"
check "a mount from another source is rejected" rejected "$(probe_validate_mount)"
FAKE_MOUNT_LINE="$SMB_SOURCE $RUNTIME_TARGET cifs rw,context=u:object_r:media_rw_data_file:s0 0 0"
check "a writable mount is rejected" rejected "$(probe_validate_mount)"
FAKE_MOUNT_LINE="$SMB_SOURCE $RUNTIME_TARGET cifs ro,nosuid 0 0"
check "a mount without the media context is rejected" rejected "$(probe_validate_mount)"
unset -f grep sleep log

# The scanner indexes; it must never copy. That is the whole point of the mount.
check "the scanner does not copy files" yes \
  "$(awk '/^scan_new_files\(\)/,/^}/' "$SCRIPTS/96-nas-photos.sh" \
    | grep -qE '(^|[^_[:alnum:]])(cp|dd|cat|install|rsync)[[:space:]]' && echo no || echo yes)"
check "the scanner verifies what actually indexed" yes \
  "$([[ $photo_src == *'landed=$(comm -12 "$work/offered" "$work/after"'* ]] && echo yes || echo no)"
check "the scan loop runs on the device, not per-file from the host" yes \
  "$([[ $photo_src == *'while IFS= read -r name'* ]] && echo yes || echo no)"
check "health polling is independent of the media discovery interval" yes \
  "$([[ $photo_src == *'sleep "$HEALTH_INTERVAL_SECONDS"'* &&
    $photo_src == *'next_scan_at=$((scan_finished_at + SCAN_INTERVAL_SECONDS))'* ]] && echo yes || echo no)"
check "long scans recheck reachability by monotonic time" yes \
  "$([[ $photo_src == *'next_scan_health_at=$(($(monotonic_seconds) + HEALTH_INTERVAL_SECONDS))'* &&
    $photo_src == *'NAS became unreachable during media scan'* ]] && echo yes || echo no)"
check "scanner filesystem and Android calls are bounded" yes \
  "$([[ $photo_src == *'timeout "$IO_TIMEOUT" stat'* &&
    $photo_src == *'timeout "$IO_TIMEOUT" content query'* &&
    $photo_src == *'timeout "$IO_TIMEOUT" am broadcast'* ]] && echo yes || echo no)"
check "new files must remain stable before and immediately before scanning" yes \
  "$([[ $photo_src == *'stability_remaining=$FILE_STABILITY_SECONDS'* &&
    $photo_src == *'NAS became unreachable during media scan'* &&
    $photo_src == *'current_signature=$(file_signature "$name")'* &&
    $photo_src == *'if [ "$current_signature" != "$observed_signature" ]'* ]] && echo yes || echo no)"

# --------------------------------------------- one mount per share, enforced
# CIFS shares a superblock per share and SELinux refuses two mounts of it with
# different context= settings, so whichever service mounts first wins and the
# other retries forever. This actually happened: installing the photo service
# left 90-nas-mount.sh failing every 300s with "Same superblock, different
# security settings". Both sides must refuse rather than collide.
mount_src=$(cat "$SCRIPTS/90-nas-mount.sh")
check "the general mount refuses to fight the photo service for a share" yes \
  "$([[ $mount_src == *'96-nas-photos.sh already serves'* ]] && echo yes || echo no)"
check "that guard compares host and share, not just presence" yes \
  "$([[ $mount_src == *'"$photo_host" = "$this_host"'* && $mount_src == *'"$photo_share" = "$this_share"'* ]] && echo yes || echo no)"
installer_src=$(cat "$SCRIPTS/install-nas-photos.sh")
# Refusing merely because the other service exists would block an expressly
# supported configuration: a separate writer share. Refuse on a real collision
# -- same host and share -- and say so when it is a different one.
check "the photo installer refuses only on a genuine share collision" yes \
  "$([[ $installer_src == *'targets the same share'* &&
    $installer_src == *'$other_host == "$this_host" && $other_share == "$this_share"'* ]] && echo yes || echo no)"
check "a different share is allowed, not refused" yes \
  "$([[ $installer_src == *'That is a different share, so the two do not collide'* ]] && echo yes || echo no)"
# The mount lives in credential-encrypted storage; with a screen lock the
# appliance cannot come up unattended after a power cut.
# RUNNING_UNLOCKED only says the phone is unlocked right now; a PIN-protected
# phone reports it once someone types the PIN. The installer must separately
# establish that no credential is configured, or it lets an install succeed and
# then fail on the next unattended reboot.
check "the photo installer checks the present unlock state" yes \
  "$([[ $installer_src == *'RUNNING_UNLOCKED'* ]] && echo yes || echo no)"
check "the photo installer separately detects a configured screen lock" yes \
  "$([[ $installer_src == *'locksettings get-disabled'* &&
    $installer_src == *'does not report an absent screen lock'* ]] && echo yes || echo no)"
check "the photo installer verifies the staged copy by checksum" yes \
  "$([[ $installer_src == *'the staged service does not match the repository copy'* ]] && echo yes || echo no)"
check "the photo installer distinguishes policy activation from a service update" yes \
  "$([[ $installer_src == *'Updating this service alone'* &&
    $installer_src == *'in-memory code until the next reboot'* &&
    $installer_src != *'REBOOT TWICE before judging'* ]] && echo yes || echo no)"
check "the photo installer pins the on-device secret path" yes \
  "$([[ $installer_src == *'photo configuration must use SMB_SECRET=/data/adb/nas-smb.secret'* ]] && echo yes || echo no)"
check "an omitted photo secret requires an existing protected device file" yes \
  "$([[ $installer_src == *'existing_secret == 0:0:600'* ]] && echo yes || echo no)"

# The service must never act on a mount it did not create: the scan would read a
# stranger's filesystem and the protective unmount would tear it down.
photo_src2=$(cat "$SCRIPTS/96-nas-photos.sh")
check "presence of a mount is not treated as ownership" yes \
  "$([[ $photo_src2 == *'occupied || return 1'* && $photo_src2 == *'validate_mount quiet'* ]] && echo yes || echo no)"
check "a foreign occupant is left alone rather than unmounted" yes \
  "$([[ $photo_src2 == *'occupied by a mount this service did not create'* ]] && echo yes || echo no)"
check "the service refuses to stack on an existing mount" yes \
  "$([[ $photo_src2 == *'refusing to stack on it'* ]] && echo yes || echo no)"
check "a non-CIFS occupant is rejected" yes \
  "$([[ $photo_src2 == *'a non-CIFS filesystem occupies'* ]] && echo yes || echo no)"
check "the secret is rejected when empty or comma-bearing" yes \
  "$([[ $photo_src2 == *"*','* | '')"* ]] && echo yes || echo no)"

# The scan compares file paths, not top-level names: a directory name would
# never match a nested row and would be rebroadcast forever.
check "the scan enumerates files recursively, not top-level names" yes \
  "$([[ $photo_src2 == *'find "$APP_TARGET" -type f'* && $photo_src2 != *'ls -A "$APP_TARGET"'* ]] && echo yes || echo no)"
check "listed paths are made relative to the mount root" yes \
  "$([[ $photo_src2 == *'sed "s#^$APP_TARGET/##"'* ]] && echo yes || echo no)"
# Grepping for the helper's name passes while it is defined but never called.
# Assert it is invoked from the scan, and exercise the counter for real.
check "the scan actually records refusals, not just defines the helper" yes \
  "$(awk '/^scan_new_files\(\)/,/^}/' "$SCRIPTS/96-nas-photos.sh" \
    | grep -q 'record_refusal "\$stuck"' && echo yes || echo no)"
check "the scan consults the refusal count before rebroadcasting" yes \
  "$(awk '/^scan_new_files\(\)/,/^}/' "$SCRIPTS/96-nas-photos.sh" \
    | grep -q 'refusal_count "\$cand"' && echo yes || echo no)"

# Credentials must not transit shell-readable storage on the way in.
check "the installer streams the secret instead of pushing it" yes \
  "$([[ $installer_src == *'cat > /data/adb/.nas-smb.secret.new'* &&
    $installer_src != *'push "$secret"'* ]] && echo yes || echo no)"
check "the installer streams the config too" yes \
  "$([[ $installer_src == *'cat > /data/adb/.nas-photos.conf.new'* ]] && echo yes || echo no)"
check "local inputs are validated before any device configuration write" yes \
  "$([[ $(grep -n 'local SMB secret must have mode 0600' "$SCRIPTS/install-nas-photos.sh" | cut -d: -f1) -lt $(grep -n 'Installing configuration' "$SCRIPTS/install-nas-photos.sh" | cut -d: -f1) ]] && echo yes || echo no)"
check "the config is checksum-verified before atomic activation" yes \
  "$([[ $installer_src == *'sha256sum /data/adb/.nas-photos.conf.new'* &&
    $installer_src == *'mv /data/adb/.nas-photos.conf.new /data/adb/nas-photos.conf'* ]] && echo yes || echo no)"
check "the secret is checksum-verified before atomic activation" yes \
  "$([[ $installer_src == *'sha256sum /data/adb/.nas-smb.secret.new'* &&
    $installer_src == *'mv /data/adb/.nas-smb.secret.new /data/adb/nas-smb.secret'* ]] && echo yes || echo no)"
check "the service is checksum-verified before atomic activation" yes \
  "$([[ $installer_src == *'sha256sum /data/adb/service.d/.96-nas-photos.sh.new'* &&
    $installer_src == *'mv /data/adb/service.d/.96-nas-photos.sh.new /data/adb/service.d/96-nas-photos.sh'* ]] && echo yes || echo no)"
check "a documented example configuration exists" yes \
  "$([[ -f $SCRIPTS/nas-photos.conf.example ]] && echo yes || echo no)"

# The normative plan must not contradict what ships.
plan=$(cat "$PROJECT_ROOT/docs/action-plan.md")
check "the plan no longer calls the direct mount experimental" yes \
  "$([[ $plan != *'Direct integration is experimental'* &&
    $plan != *'direct mount remains experimental'* ]] && echo yes || echo no)"
check "the plan no longer ranks local staging first" yes \
  "$([[ $plan != *'| 1 | Read-only root NAS mount plus bounded local staging'* ]] && echo yes || echo no)"
check "the plan states the module carries two rules" yes \
  "$([[ $plan == *'The module carries two rules'* ]] && echo yes || echo no)"
check "the validation summary no longer calls the direct mount unexercised" yes \
  "$([[ $plan != *'direct shared-storage mount and NAS-off boot remain unexercised'* ]] && echo yes || echo no)"

quick_start=$(cat "$PROJECT_ROOT/docs/quick-start.md")
check "quick start creates the photo configuration it installs" yes \
  "$([[ $quick_start == *'cp nas-photos.conf.example ../pixel-nas-operator-config/nas-photos.conf'* ]] && echo yes || echo no)"
check "quick start supplies the photo installer credential" yes \
  "$([[ $quick_start == *'./install-nas-photos.sh ../pixel-nas-operator-config/nas-photos.conf'*'../pixel-nas-operator-config/nas-smb.secret'* ]] && echo yes || echo no)"

# A mount this run just created and then found invalid must still be removable.
# The identity check that protects a stranger's mount also matched the broken
# one, so it was classified as foreign and left covering DCIM, blocking every
# later retry.
check "a freshly created invalid mount is force-unmounted" yes \
  "$(awk '/^mount_share\(\)/,/^}/' "$SCRIPTS/96-nas-photos.sh" \
    | grep -q 'unmount_share force' && echo yes || echo no)"
check "force skips the ownership check but still requires an occupant" yes \
  "$([[ $photo_src2 == *'occupied || return 0'* ]] && echo yes || echo no)"
check "ordinary cleanup keeps the strict ownership check" yes \
  "$(awk '/^unmount_share\(\)/,/^}/' "$SCRIPTS/96-nas-photos.sh" \
    | grep -q 'if \[ -z "\$force" \]' && echo yes || echo no)"

# Inspection must read the namespace the mutations happen in.
check "mount inspection reads init's mount table" yes \
  "$([[ $photo_src2 == *'grep -m1 " $RUNTIME_TARGET " /proc/1/mounts'* ]] && echo yes || echo no)"
check "no lifecycle check reads the service's own /proc/mounts" yes \
  "$([[ $photo_src2 != *'" /proc/mounts"'* && $photo_src2 != *'$RUNTIME_TARGET " /proc/mounts'* ]] && echo yes || echo no)"

# Mounting over a populated directory hides the operator's own files.
check "a non-empty target is refused rather than hidden" yes \
  "$([[ $photo_src2 == *'already contains local files; refusing to mount over and hide them'* ]] && echo yes || echo no)"

# Exercise the mountpoint guard rather than only looking for its message. An
# inspection error must fail closed, and the command must run through the same
# namespace helper used for mount and unmount.
eval "$(sed -n '/^target_is_empty()/,/^}/p' "$SCRIPTS/96-nas-photos.sh")"
TDIR=$(mktemp -d)
RUNTIME_TARGET=$TDIR
IO_TIMEOUT=1
log() { :; }
in_global_ns() { "$@"; }
target_result() {
  if target_is_empty; then
    echo 0
  else
    echo $?
  fi
}
check "an empty target passes the behavioral guard" 0 "$(target_result)"
touch "$TDIR/local-photo.jpg"
check "a populated target fails the behavioral guard" 1 "$(target_result)"
in_global_ns() { return 124; }
check "an inspection timeout fails closed" 1 "$(target_result)"
rm -rf "$TDIR"

# A failed MediaStore query used to be hidden by a pipe to sed. That made every
# file look absent and eventually added valid media to the permanent refusal
# list. Exercise the helper's status and assert only delivered broadcasts are
# eligible to accrue a refusal.
eval "$(sed -n '/^indexed_paths()/,/^}/p' "$SCRIPTS/96-nas-photos.sh")"
PHOTO_FOLDER=NAS-Live
APP_TARGET=/storage/emulated/0/DCIM/NAS-Live
IO_TIMEOUT=5
content_stub_dir=$(mktemp -d)
printf '#!/bin/sh\nexit 23\n' >"$content_stub_dir/content"
chmod 755 "$content_stub_dir/content"
original_path=$PATH
PATH="$content_stub_dir:$PATH"
indexed_result() {
  if indexed_paths >/dev/null; then
    echo 0
  else
    echo $?
  fi
}
check "a MediaStore query failure is observable" 1 "$(indexed_result)"
PATH=$original_path
rm -rf "$content_stub_dir"
check "refusals are recorded only for successfully offered paths" yes \
  "$(awk '/^scan_new_files\(\)/,/^}/' "$SCRIPTS/96-nas-photos.sh" \
    | grep -q 'comm -23 "\$work/offered" "\$work/after"' && echo yes || echo no)"

# Zero silently disables these guards.
check "zero is rejected for the guards it would disable" yes \
  "$([[ $photo_src2 == *'must be at least 1; 0 disables the protection it provides'* ]] && echo yes || echo no)"

# Refusal state keyed by path alone outlived the file it described.
eval "$(sed -n '/^file_signature()/,/^}/p;/^refusal_count()/,/^}/p;/^record_refusal()/,/^}/p' "$SCRIPTS/96-nas-photos.sh")"
RDIR=$(mktemp -d)
APP_TARGET=$RDIR
REFUSED_PATH=$RDIR/state
IO_TIMEOUT=5
printf 'one\n' >"$RDIR/f.jpg"
check "an unseen file starts at zero" 0 "$(refusal_count f.jpg)"
record_refusal f.jpg
record_refusal f.jpg
check "refusals accumulate for an unchanged file" 2 "$(refusal_count f.jpg)"
sleep 1
printf 'replaced-with-different-content\n' >"$RDIR/f.jpg"
check "replacing the file clears its refusal count" 0 "$(refusal_count f.jpg)"
record_refusal f.jpg
check "the replaced file starts counting again" 1 "$(refusal_count f.jpg)"
printf 'x\n' >"$RDIR/other name.jpg"
record_refusal 'other name.jpg'
check "a path containing a space is tracked correctly" 1 "$(refusal_count 'other name.jpg')"
check "the space-bearing path does not disturb the other" 1 "$(refusal_count f.jpg)"
rm -rf "$RDIR"
unset REFUSED_PATH APP_TARGET

# The screen-lock probe must fail closed.
check "the lock probe accepts only the exact success answer" yes \
  "$([[ $installer_src == *'[[ $lock_probe != "true" ]]'* ]] && echo yes || echo no)"
check "the lock probe honours the command's exit status" yes \
  "$([[ $installer_src == *'|| lock_rc=$?'* && $installer_src == *'((lock_rc != 0))'* ]] && echo yes || echo no)"
check "the lock probe no longer pipes through head" yes \
  "$([[ $installer_src != *'locksettings get-disabled 2>&1 | head'* ]] && echo yes || echo no)"

# The removed copy-in path must not be advertised as a fallback.
check "no rank advertises a copy into shared storage" yes \
  "$([[ $plan != *'plus an explicit copy into shared storage'* ]] && echo yes || echo no)"
check "the plan states plainly there is no copy-in fallback" yes \
  "$([[ $plan == *'There is no copy-in fallback'* ]] && echo yes || echo no)"

# The staging path is gone: it copied NAS files into internal flash, which is
# the thing the direct mount exists to avoid.
check "stage-photos.sh is gone from the scripts directory" yes \
  "$([[ ! -e $SCRIPTS/stage-photos.sh ]] && echo yes || echo no)"
check "no document still describes the copy-in path" yes \
  "$(grep -rlq 'stage-photos' "$PROJECT_ROOT/docs" 2>/dev/null && echo no || echo yes)"
check "the manifest no longer lists the removed script" yes \
  "$(grep -q 'stage-photos' "$SCRIPTS/SHA256SUMS" && echo no || echo yes)"

# ------------------------------------------------------------ host dependencies
# Phase 0 runs before setup-host-ubuntu-20.04.sh, so the script checks its own
# tools; setup must also install them for the later phases.
for dep in curl unzip openssl; do
  check "install-magisk-boot checks for $dep up front" yes \
    "$(awk '/^for required_command in/{print; exit}' "$SCRIPTS/install-magisk-boot.sh" \
      | grep -qw "$dep" && echo yes || echo no)"
  check "host setup installs $dep" yes \
    "$(grep -q "^  rsync unzip zip.*\b$dep\b\|^  .*\b$dep\b" <(sed -n '/^packages=(/,/^)/p' \
      "$SCRIPTS/setup-host-ubuntu-20.04.sh") && echo yes || echo no)"
done
check "host setup installs sqlite3 for upload-evidence queries" yes \
  "$(grep -qw sqlite3 <(sed -n '/^packages=(/,/^)/p' \
    "$SCRIPTS/setup-host-ubuntu-20.04.sh") && echo yes || echo no)"

# There must be no way to hand the script an arbitrary boot image: no published
# checksum can authenticate one. Exercised through real argument parsing, with a
# stub adb so nothing reaches a phone. Exit 2 is "unknown option"; the last case
# proves a supported option still parses, so 2 really means rejected.
STUBDIR=$(mktemp -d)
printf '#!/bin/sh\nexit 0\n' >"$STUBDIR/adb"
chmod +x "$STUBDIR/adb"
probe_opt() {
  (PATH="$STUBDIR:$PATH" bash "$SCRIPTS/install-magisk-boot.sh" stage "$@" >/dev/null 2>&1)
  echo $?
}
check "a bare --stock-boot is refused" 2 "$(probe_opt --stock-boot /nonexistent.img)"
check "--stock-boot-sha256 is refused" 2 "$(probe_opt --stock-boot-sha256 deadbeef)"
check "--factory-zip-sha256 is refused" 2 "$(probe_opt --factory-zip-sha256 deadbeef)"
check "a supported option still parses" 1 "$(probe_opt --workspace "$STUBDIR/ws")"
rm -rf "$STUBDIR"

check "the remote listing survives a clean phone" yes \
  "$([[ $magisk_src2 == *'done; true'* ]] && echo yes || echo no)"
check "missing staging evidence fails closed" yes \
  "$([[ $magisk_src2 == *'no staging record at'* ]] && echo yes || echo no)"
check "staging records rather than deletes user files" yes \
  "$([[ $magisk_src2 != *'rm -f /sdcard/Download/magisk_patched-*.img'* &&
    $magisk_src2 == *pre-existing-patched.txt* ]] && echo yes || echo no)"
check "the post-flash wait is bounded" yes \
  "$([[ $magisk_src2 != *'adb -s "$serial" wait-for-device'* &&
    $magisk_src2 == *'did not return to ADB within 180 seconds'* ]] && echo yes || echo no)"

((fails == 0)) || {
  printf 'FAIL: %d check(s) failed\n' "$fails" >&2
  exit 1
}
echo "PASS: deployment and readiness gate regressions"
