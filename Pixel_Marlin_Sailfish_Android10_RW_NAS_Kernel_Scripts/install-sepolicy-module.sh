#!/usr/bin/env bash
set -euo pipefail

# Install a Magisk module carrying one SELinux rule:
#
#   allow kernel kernel capability net_raw
#
# Android's CONFIG_ANDROID_PARANOID_NETWORK gates socket creation on
# in_egroup_p(AID_INET) || capable(CAP_NET_RAW) (net/ipv4/af_inet.c). The
# initial CIFS mount succeeds because the socket is created in the mounting
# process's context, which holds the capability. When the SMB session later
# drops, the cifsd kernel thread rebuilds the socket in the u:r:kernel:s0
# domain, SELinux denies net_raw, inet_create returns -EACCES, and the mount
# is permanently dead while still listed in /proc/mounts. Observed on sailfish
# as a 3-second retry loop logging "CIFS VFS: Error -13 creating socket".
#
# The rule grants one capability to kernel threads only. It does not affect
# app domains and does not weaken the INTERNET permission, which is what
# disabling CONFIG_ANDROID_PARANOID_NETWORK would do.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=host-shell-lib.sh
. "$SCRIPT_DIR/host-shell-lib.sh"

MODULE_ID=pixel-nas-sepolicy
MODULE_DIR="/data/adb/modules/$MODULE_ID"
RULE="allow kernel kernel capability net_raw"

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
[[ $(root_cmd 'test -d /data/adb/modules && echo yes' | tr -d '\r') == yes ]] || {
  echo "ERROR: /data/adb/modules is absent; this needs a Magisk installation" >&2
  exit 1
}

install_script=$(
  cat <<EOF
set -e
umask 022
mkdir -p $MODULE_DIR
cat > $MODULE_DIR/module.prop <<'PROP'
id=$MODULE_ID
name=Pixel NAS CIFS reconnect policy
version=v1
versionCode=1
author=pixel-nas-kernel-work
description=Grants CAP_NET_RAW to the kernel domain so the in-kernel CIFS client can rebuild its socket after a network interruption.
PROP
printf '%s\n' '$RULE' > $MODULE_DIR/sepolicy.rule
chown -R 0:0 $MODULE_DIR
chmod 0755 $MODULE_DIR
chmod 0644 $MODULE_DIR/module.prop $MODULE_DIR/sepolicy.rule
rm -f $MODULE_DIR/disable $MODULE_DIR/remove
EOF
)
root_cmd "$install_script"

echo "Installed: $MODULE_DIR"
root_cmd "cat $MODULE_DIR/sepolicy.rule" | tr -d '\r' | sed 's/^/  rule: /'
root_cmd "ls -l $MODULE_DIR" | tr -d '\r' | sed 's/^/  /'

installed_rule=$(root_cmd "cat $MODULE_DIR/sepolicy.rule" | tr -d '\r')
[[ $installed_rule == "$RULE" ]] || {
  echo "ERROR: installed rule does not match the intended rule" >&2
  exit 1
}

echo
echo "Magisk applies sepolicy.rule during early boot. Reboot, then confirm with:"
echo "  adb shell \"su -c 'dmesg | grep -c \\\"denied { net_raw }\\\"'\"   # expect no growth"
echo "  adb shell \"su -c 'dmesg | grep -c \\\"Error -13 creating socket\\\"'\""
