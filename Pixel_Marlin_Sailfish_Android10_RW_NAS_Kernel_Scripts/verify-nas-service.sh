#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=host-shell-lib.sh
. "$SCRIPT_DIR/host-shell-lib.sh"
allow_plain_divergence=0
if [[ ${1:-} == --allow-plain-divergence ]]; then
  allow_plain_divergence=1
  shift
fi
(($# == 0)) || {
  echo "Usage: $0 [--allow-plain-divergence]" >&2
  exit 2
}

mapfile -t serials < <(adb devices | awk '$2=="device" {print $1}')
((${#serials[@]} == 1)) || {
  echo "ERROR: exactly one authorised ADB device is required" >&2
  exit 1
}
serial=${serials[0]}
remote_checker=/data/local/tmp/pixel-nas-namespace-check.sh
root_cmd() {
  local command_arg
  command_arg=$(quote_remote_command "$1")
  adb -s "$serial" shell "su -c $command_arg"
}
global_root_cmd() {
  local command_arg
  command_arg=$(quote_remote_command "$1")
  adb -s "$serial" shell "su -mm -c $command_arg"
}
# shellcheck disable=SC2329 # Invoked by trap.
cleanup_remote() {
  root_cmd "rm -f $remote_checker" >/dev/null 2>&1 || true
}
trap cleanup_remote EXIT INT TERM
root_cmd id | grep -q 'uid=0(root)' || {
  echo "ERROR: Magisk root is required" >&2
  exit 1
}

target=$(root_cmd "sed -n s/^TARGET=//p /data/adb/nas-mount.conf" | tr -d '\r')
case "$target" in
  /data/local/tmp/nas-ro | /data/local/tmp/nas-rw)
    root_only=1
    ;;
  /mnt/runtime/default/emulated/0/DCIM/NAS-Inbox | /mnt/runtime/read/emulated/0/DCIM/NAS-Inbox | /mnt/runtime/write/emulated/0/DCIM/NAS-Inbox)
    root_only=0
    ;;
  *)
    echo "ERROR: installed configuration has an unsupported target: $target" >&2
    exit 1
    ;;
esac

adb -s "$serial" push "$SCRIPT_DIR/check-nas-namespace.sh" "$remote_checker" >/dev/null
root_cmd "chmod 0700 $remote_checker"
set +e
global_output=$(global_root_cmd "$remote_checker $target" 2>&1)
global_status=$?
plain_output=$(root_cmd "$remote_checker $target" 2>&1)
plain_status=$?
set -e
global_output=${global_output//$'\r'/}
plain_output=${plain_output//$'\r'/}

printf '%s\n' '--- su -mm (global namespace) ---' "$global_output"
printf '%s\n' '--- plain su (adbd caller namespace) ---' "$plain_output"
((global_status == 0)) || {
  echo "ERROR: the post-reboot service mount is absent from a separate su -mm shell" >&2
  exit 1
}
global_mount=$(sed -n 's/^mount=//p' <<<"$global_output")
plain_mount=$(sed -n 's/^mount=//p' <<<"$plain_output")
if ((plain_status == 0)) && [[ $plain_mount == "$global_mount" ]]; then
  echo "Host-shell namespace check passed: global su -mm and plain su from adbd see the same mount"
  echo "NOTE: this does not test any app namespace; the Photos experiment still requires /proc/<photos-pid>/mountinfo and its full acceptance gate."
  exit 0
fi

if ((allow_plain_divergence && root_only)); then
  echo "WARNING: plain su does not see the global mount; root-only operations must continue using su -mm" >&2
  exit 0
fi
echo "ERROR: mount visibility diverges between su -mm and plain su" >&2
if ((root_only)); then
  echo "For the supported root-only staging design, review the evidence and rerun with --allow-plain-divergence only if all consumers use su -mm." >&2
else
  echo "Runtime-view divergence rejects the direct-mount experiment." >&2
fi
exit 1
