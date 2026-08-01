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
# shellcheck source=source-lock.env
. "$SCRIPT_DIR/source-lock.env"
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

# Persistently relaxing SELinux policy must not be possible on an unrelated
# phone. Apply the same device and build gates as deployment, and additionally
# require this project's kernel: the rule exists only because CIFS was built
# into it, so a stock kernel has no business receiving it.
device=$(adb -s "$serial" shell getprop ro.product.device | tr -d '\r')
build=$(adb -s "$serial" shell getprop ro.build.id | tr -d '\r')
version=$(adb -s "$serial" shell getprop ro.build.version.release | tr -d '\r')
release=$(adb -s "$serial" shell uname -r | tr -d '\r')
[[ $device == marlin || $device == sailfish ]] || {
  echo "ERROR: unsupported device: $device" >&2
  exit 1
}
[[ $build == "$ANDROID_BUILD" && $version == "$ANDROID_VERSION" ]] || {
  echo "ERROR: Android build/version mismatch: $build / $version" >&2
  exit 1
}
[[ $release == *"$KERNEL_LOCALVERSION"* ]] || {
  echo "ERROR: this phone is not running the project kernel: $release" >&2
  echo "The rule is only meaningful with the custom CIFS/NFS kernel installed." >&2
  exit 1
}
printf 'Target: %s / %s / %s\n' "$device" "$build" "$release"

# Report whether the denial this rule addresses has actually been observed.
# Not a gate: installing before the first network interruption is legitimate.
denials=$(root_cmd 'dmesg | grep -c "denied { net_raw }"' | tr -d '\r')
if [[ $denials =~ ^[0-9]+$ ]] && ((denials > 0)); then
  printf 'Observed net_raw denials in the current boot: %s\n' "$denials"
else
  echo "No net_raw denials observed yet; installing pre-emptively is expected."
fi

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
# On a file-based-encrypted device Magisk cannot read module rules at pre-init,
# because /data is not decrypted yet. It collects them during boot and stages
# them to an unencrypted location that pre-init can read on the following boot.
# Saying "reboot" here would recreate the exact trap the documentation exists to
# prevent: the first reboot still shows denials and the module looks broken.
crypto=$(adb -s "$serial" shell getprop ro.crypto.type | tr -d '\r')
if [[ $crypto == file || $crypto == block ]]; then
  echo "/data is encrypted (ro.crypto.type=$crypto)."
  echo "Magisk stages module rules for the NEXT boot, so REBOOT TWICE before judging."
  echo "After one reboot the denials are still expected; that is not a failure."
else
  echo "Reboot once, then confirm."
fi
echo
echo "Confirm with both counts at zero, ideally across a deliberate Wi-Fi teardown:"
echo "  adb shell \"su -c 'dmesg | grep -c \\\"denied { net_raw }\\\"'\""
echo "  adb shell \"su -c 'dmesg | grep -c \\\"Error -13 creating socket\\\"'\""
echo
echo "To apply immediately without rebooting (cleared by any reboot):"
echo "  adb shell \"su -c '/data/adb/magisk/magiskpolicy --live \\\"$RULE\\\"'\""
