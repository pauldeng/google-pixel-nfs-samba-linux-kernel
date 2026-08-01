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
serials=()
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
cleanup_remote() {
  root_cmd "rm -f /data/local/tmp/90-nas-mount.sh /data/local/tmp/nas-mount.conf /data/adb/.nas-smb.secret.new" >/dev/null 2>&1 || true
}
trap cleanup_remote EXIT INT TERM
root_cmd id | grep -q 'uid=0(root)' || {
  echo "ERROR: Magisk root is required" >&2
  exit 1
}

mode=$(sed -n 's/^MOUNT_MODE=//p' "$config")
probe=$(sed -n 's/^REQUIRE_WRITE_TEST=//p' "$config")
protocol=$(sed -n 's/^PROTOCOL=//p' "$config")
[[ $mode:$probe == ro:0 || $mode:$probe == rw:1 ]] || {
  echo "ERROR: invalid mode/probe policy" >&2
  exit 1
}
[[ $protocol == smb || $protocol == nfs ]] || {
  echo "ERROR: invalid protocol" >&2
  exit 1
}
if [[ $protocol == smb && ! -f $secret ]]; then
  echo "ERROR: SMB configuration requires a secret file" >&2
  exit 1
fi
if [[ $protocol == nfs && -n $secret ]]; then
  echo "ERROR: NFS configuration must not be paired with an SMB secret" >&2
  exit 1
fi
if [[ $protocol == smb ]]; then
  [[ $(stat -c '%a' "$secret") == 600 ]] || {
    echo "ERROR: local SMB secret must have mode 0600" >&2
    exit 1
  }
  configured_secret=$(sed -n 's/^SMB_SECRET=//p' "$config")
  [[ $configured_secret == /data/adb/nas-smb.secret ]] || {
    echo "ERROR: installed SMB configuration must use SMB_SECRET=/data/adb/nas-smb.secret" >&2
    exit 1
  }
fi

adb -s "$serial" push "$SCRIPT_DIR/90-nas-mount.sh" /data/local/tmp/90-nas-mount.sh
adb -s "$serial" push "$config" /data/local/tmp/nas-mount.conf
if [[ -n $secret ]]; then
  root_cmd "set -e; umask 077; cat > /data/adb/.nas-smb.secret.new; chown 0:0 /data/adb/.nas-smb.secret.new; chmod 0600 /data/adb/.nas-smb.secret.new" <"$secret"
fi
remote="set -e; mkdir -p /data/adb/service.d; cp /data/local/tmp/90-nas-mount.sh /data/adb/service.d/90-nas-mount.sh; cp /data/local/tmp/nas-mount.conf /data/adb/nas-mount.conf; chown 0:0 /data/adb/service.d/90-nas-mount.sh /data/adb/nas-mount.conf; chmod 0755 /data/adb/service.d/90-nas-mount.sh; chmod 0600 /data/adb/nas-mount.conf; rm -f /data/local/tmp/90-nas-mount.sh /data/local/tmp/nas-mount.conf"
if [[ -n $secret ]]; then
  remote="$remote; mv /data/adb/.nas-smb.secret.new /data/adb/nas-smb.secret; chown 0:0 /data/adb/nas-smb.secret; chmod 0600 /data/adb/nas-smb.secret"
fi
root_cmd "$remote"
trap - EXIT INT TERM
echo "Installed service and root-owned configuration. Run the service manually and inspect its log before rebooting."
