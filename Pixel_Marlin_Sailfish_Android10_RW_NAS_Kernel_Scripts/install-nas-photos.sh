#!/usr/bin/env bash
set -euo pipefail

# Install the photo-share service: the configuration, the secret, and the
# Magisk service script that mounts the NAS where Google Photos can see it.
#
# Nothing is ever copied to internal flash. The share is mounted read-only into
# a /mnt/runtime view, which propagates into every app mount namespace.
#
# Usage: install-nas-photos.sh CONFIG [SECRET]

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=host-shell-lib.sh
. "$SCRIPT_DIR/host-shell-lib.sh"

config=${1:-}
secret=${2:-}
[[ -f $config ]] || {
  echo "Usage: $0 CONFIG [SECRET]" >&2
  exit 2
}
[[ $(stat -c '%a' "$config") == 600 ]] || {
  echo "ERROR: local photo configuration must have mode 0600" >&2
  exit 1
}
configured_secret=$(sed -n 's/^SMB_SECRET=//p' "$config")
[[ $configured_secret == /data/adb/nas-smb.secret ]] || {
  echo "ERROR: photo configuration must use SMB_SECRET=/data/adb/nas-smb.secret" >&2
  exit 1
}
if [[ -n $secret ]]; then
  [[ -f $secret ]] || {
    echo "ERROR: secret file not found: $secret" >&2
    exit 1
  }
  [[ $(stat -c '%a' "$secret") == 600 ]] || {
    echo "ERROR: local SMB secret must have mode 0600" >&2
    exit 1
  }
fi

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

root_cmd id | grep -q 'uid=0(root)' || {
  echo "ERROR: Magisk root is required" >&2
  exit 1
}

if [[ -z $secret ]]; then
  existing_secret=$(root_cmd 'stat -c "%u:%g:%a" /data/adb/nas-smb.secret 2>/dev/null || true' | tr -d '\r\n')
  [[ $existing_secret == 0:0:600 ]] || {
    echo "ERROR: SECRET was omitted, but /data/adb/nas-smb.secret is not a root-owned mode-0600 file" >&2
    echo "Pass the local mode-0600 secret as the second argument." >&2
    exit 1
  }
fi

# The mount lives in credential-encrypted storage. With a screen lock set, user
# 0 stays locked after every reboot and the mount cannot be made until someone
# types the PIN, which is not an unattended appliance. Refuse rather than
# install something that will silently fail on the next power cut.
# Two different questions, and only the second one matters for unattended
# operation. RUNNING_UNLOCKED merely says the phone is unlocked *right now* - a
# PIN-protected phone reports exactly that once someone has typed the PIN, so
# checking it alone would let the install succeed and then fail on the next
# unattended reboot, which is the very thing this check exists to prevent.
lock_state=$(root_cmd 'dumpsys user 2>/dev/null | grep -m1 "State:"' | tr -d '\r')
case "$lock_state" in
  *RUNNING_UNLOCKED*) ;;
  *)
    echo "ERROR: user 0 is locked right now ($lock_state); unlock the phone and rerun" >&2
    exit 1
    ;;
esac

# Is a credential configured at all? Fail closed: accept only the exact
# success answer and treat everything else as "a lock is set".
#
# The previous version listed the error strings it knew about and accepted
# anything else, which is backwards -- Android 10's LockSettingsShellCommand
# checks the credential before running the subcommand and can report that in
# more than one wording, so an unrecognised message read as success. It also
# piped through `head`, which discards the command's exit status.
lock_rc=0
lock_probe=$(root_cmd 'locksettings get-disabled 2>&1' | tr -d '\r' | tr -d '\n') || lock_rc=$?
if ((lock_rc != 0)) || [[ $lock_probe != "true" ]]; then
  echo "ERROR: this phone does not report an absent screen lock." >&2
  echo >&2
  echo "The mount targets /storage/emulated/0, which is credential-encrypted." >&2
  echo "After every reboot user 0 stays locked until someone types the PIN, so" >&2
  echo "the share cannot be mounted and uploads stall until a human intervenes." >&2
  echo "That is not an unattended appliance." >&2
  echo >&2
  echo "Remove the screen lock (Settings > Security > Screen lock > None) and" >&2
  echo "rerun. This is a deliberate security trade-off for a LAN-only" >&2
  echo "appliance; make it knowingly." >&2
  echo >&2
  echo "Expected exactly 'true' from: locksettings get-disabled" >&2
  echo "  exit status: $lock_rc" >&2
  echo "  output:      ${lock_probe:-<empty>}" >&2
  exit 1
fi

if root_cmd 'ls /data/adb/service.d/90-nas-mount.sh' >/dev/null 2>&1; then
  # Only a genuine collision is a problem. A separate writer share is an
  # expressly supported configuration, so compare host and share rather than
  # refusing merely because the other service exists.
  other_host=$(root_cmd "sed -n 's/^NAS_HOST=//p' /data/adb/nas-mount.conf 2>/dev/null | head -1" | tr -d '\r')
  other_share=$(root_cmd "sed -n 's/^SMB_SHARE=//p' /data/adb/nas-mount.conf 2>/dev/null | head -1" | tr -d '\r')
  this_host=$(sed -n 's/^NAS_HOST=//p' "$config" | head -1)
  this_share=$(sed -n 's/^SMB_SHARE=//p' "$config" | head -1)
  if [[ -n $other_host && $other_host == "$this_host" && $other_share == "$this_share" ]]; then
    echo "ERROR: 90-nas-mount.sh is installed and targets the same share," >&2
    echo "  //$this_host/$this_share" >&2
    echo "CIFS shares one superblock per share and SELinux rejects a second" >&2
    echo "mount of it with a different context, so whichever mounts first wins" >&2
    echo "and the other fails on every attempt. Retire it, or point it at a" >&2
    echo "different share." >&2
    exit 1
  fi
  echo "Note: 90-nas-mount.sh is installed for //$other_host/$other_share." >&2
  echo "That is a different share, so the two do not collide." >&2
fi

echo "Installing configuration"
root_cmd "set -e; umask 077; cat > /data/adb/.nas-photos.conf.new
chown 0:0 /data/adb/.nas-photos.conf.new; chmod 0600 /data/adb/.nas-photos.conf.new" <"$config"
expected_config=$(sha256sum "$config" | awk '{print $1}')
actual_config=$(root_cmd 'sha256sum /data/adb/.nas-photos.conf.new' | tr -d '\r' | awk '{print $1}')
if [[ $actual_config != "$expected_config" ]]; then
  root_cmd 'rm -f /data/adb/.nas-photos.conf.new'
  echo "ERROR: staged photo configuration checksum mismatch" >&2
  exit 1
fi
root_cmd 'mv /data/adb/.nas-photos.conf.new /data/adb/nas-photos.conf'

if [[ -n $secret ]]; then
  echo "Installing secret"
  # Pipe it straight into a root-owned file. `adb push` lands world-readable in
  # /data/local/tmp, and a NAS password was found sitting there at mode 0666
  # weeks after a manual test. install-nas-service.sh already does it this way.
  root_cmd "set -e; umask 077; cat > /data/adb/.nas-smb.secret.new
  chown 0:0 /data/adb/.nas-smb.secret.new; chmod 0600 /data/adb/.nas-smb.secret.new" <"$secret"
  expected_secret=$(sha256sum "$secret" | awk '{print $1}')
  actual_secret=$(root_cmd 'sha256sum /data/adb/.nas-smb.secret.new' | tr -d '\r' | awk '{print $1}')
  if [[ $actual_secret != "$expected_secret" ]]; then
    root_cmd 'rm -f /data/adb/.nas-smb.secret.new'
    echo "ERROR: staged SMB secret checksum mismatch" >&2
    exit 1
  fi
  root_cmd 'mv /data/adb/.nas-smb.secret.new /data/adb/nas-smb.secret'
fi

echo "Installing service"
adb -s "$serial" push "$SCRIPT_DIR/96-nas-photos.sh" /data/local/tmp/96-nas-photos.staged >/dev/null
root_cmd 'mkdir -p /data/adb/service.d
cp /data/local/tmp/96-nas-photos.staged /data/adb/service.d/.96-nas-photos.sh.new
chown 0:0 /data/adb/service.d/.96-nas-photos.sh.new
chmod 0755 /data/adb/service.d/.96-nas-photos.sh.new'

expected=$(sha256sum "$SCRIPT_DIR/96-nas-photos.sh" | awk '{print $1}')
actual=$(root_cmd 'sha256sum /data/adb/service.d/.96-nas-photos.sh.new' | tr -d '\r' | awk '{print $1}')
[[ $expected == "$actual" ]] || {
  root_cmd 'rm -f /data/adb/service.d/.96-nas-photos.sh.new /data/local/tmp/96-nas-photos.staged'
  echo "ERROR: the staged service does not match the repository copy" >&2
  echo "  expected: $expected" >&2
  echo "  actual:   $actual" >&2
  exit 1
}
root_cmd 'mv /data/adb/service.d/.96-nas-photos.sh.new /data/adb/service.d/96-nas-photos.sh
rm -f /data/local/tmp/96-nas-photos.staged'

echo
echo "Installed and checksum-verified:"
root_cmd 'ls -l /data/adb/service.d/96-nas-photos.sh /data/adb/nas-photos.conf' | tr -d '\r' | sed 's/^/  /'
echo
echo "The SELinux rule this mount needs ships in install-sepolicy-module.sh."
echo "If that module has not already been installed and activated, follow its"
echo "reboot instructions before judging the mount. Updating this service alone"
echo "does not require two reboots."
echo
echo "An already-running service keeps its in-memory code until the next reboot."
echo "To activate this copy immediately, stop that one exact PID and start one"
echo "replacement; never launch a second copy alongside it."
echo
echo "After the next start, verify with:"
echo "  adb shell \"su -c 'cat /data/adb/nas-photos.log'\""
echo "  adb shell \"su -c 'grep -c \\\"cifs\\\" /proc/mounts'\""
echo "  adb shell 'ls /storage/emulated/0/DCIM/<folder> | wc -l'"
