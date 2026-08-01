#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=host-shell-lib.sh
. "$SCRIPT_DIR/host-shell-lib.sh"
config=${1:-}
secret=${2:-}
[[ -f $config ]] || {
  echo "Usage: $0 CONFIG [SMB_SECRET]" >&2
  exit 2
}
mapfile -t serials < <(adb devices | awk '$2=="device" {print $1}')
((${#serials[@]} == 1)) || {
  echo "ERROR: exactly one authorised ADB device is required" >&2
  exit 1
}
serial=${serials[0]}
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
cleanup_remote() {
  root_cmd "rm -f /data/local/tmp/pixel-nas-mount-test.sh /data/local/tmp/pixel-nas-mount-test.conf /data/local/tmp/pixel-nas-mount-test.secret /data/local/tmp/pixel-nas-mount-test.log" >/dev/null 2>&1 || true
}
trap cleanup_remote EXIT INT TERM
root_cmd id | grep -q 'uid=0(root)' || {
  echo "ERROR: Magisk root is required" >&2
  exit 1
}
adb -s "$serial" push "$SCRIPT_DIR/90-nas-mount.sh" /data/local/tmp/pixel-nas-mount-test.sh
adb -s "$serial" push "$config" /data/local/tmp/pixel-nas-mount-test.conf
remote_prefix="LOG_PATH=/data/local/tmp/pixel-nas-mount-test.log"
if [[ -n $secret ]]; then
  [[ -f $secret ]] || {
    echo "ERROR: secret file not found: $secret" >&2
    exit 1
  }
  adb -s "$serial" push "$secret" /data/local/tmp/pixel-nas-mount-test.secret
  remote_prefix="$remote_prefix SMB_SECRET_OVERRIDE=/data/local/tmp/pixel-nas-mount-test.secret"
fi
local_log="./pixel-nas-mount-test-$(date -u +%Y%m%dT%H%M%SZ).log"
[[ ! -e $local_log ]] || {
  echo "ERROR: refusing to overwrite log: $local_log" >&2
  exit 1
}
fetch_remote_log() {
  # The mount script runs with umask 077, so its log is root-owned mode 0600.
  # `adb pull` runs as the shell user and fails with "Permission denied", which
  # previously discarded the evidence for a failed mount and made a successful
  # mount look like a failure. Read it back through su instead.
  # Callers invoke this from an `if`, which suppresses errexit, so the read
  # status has to be captured explicitly. Without it a truncated or failed
  # privileged cat would be written out as though it were the whole log.
  local contents status=0
  contents=$(root_cmd "cat /data/local/tmp/pixel-nas-mount-test.log") || status=$?
  ((status == 0)) || return 1
  contents=${contents//$'\r'/}
  [[ -n $contents ]] || return 1
  (
    umask 077
    printf '%s\n' "$contents" >"$local_log"
  )
}
remote_command="chmod 0700 /data/local/tmp/pixel-nas-mount-test.sh; chmod 0600 /data/local/tmp/pixel-nas-mount-test.conf /data/local/tmp/pixel-nas-mount-test.secret 2>/dev/null || true; rm -f /data/local/tmp/pixel-nas-mount-test.log; $remote_prefix /data/local/tmp/pixel-nas-mount-test.sh /data/local/tmp/pixel-nas-mount-test.conf"
if ! global_root_cmd "$remote_command"; then
  if fetch_remote_log; then
    echo "Saved failed-mount evidence: $local_log" >&2
  else
    echo "ERROR: the mount failed and produced no readable log" >&2
  fi
  exit 1
fi
fetch_remote_log || {
  echo "ERROR: the mount reported success but its log could not be read" >&2
  exit 1
}
cleanup_remote
trap - EXIT INT TERM
echo "Saved mount evidence: $local_log"
echo "Mount remains active for inspection. Use unmount-nas.sh in the global namespace when finished."
