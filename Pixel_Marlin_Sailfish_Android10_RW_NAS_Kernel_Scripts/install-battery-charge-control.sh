#!/usr/bin/env bash
set -euo pipefail

# Install and optionally apply the Pixel 1 kernel's native HTC charge limits.
# Usage:
#   install-battery-charge-control.sh [--apply-now] CONFIG
#   install-battery-charge-control.sh --disable

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=host-shell-lib.sh
. "$SCRIPT_DIR/host-shell-lib.sh"

apply_now=0
disable=0
case ${1:-} in
  --apply-now)
    apply_now=1
    shift
    ;;
  --disable)
    disable=1
    shift
    ;;
esac

if ((disable)); then
  (($# == 0)) || {
    echo "Usage: $0 --disable" >&2
    exit 2
  }
else
  (($# == 1)) || {
    echo "Usage: $0 [--apply-now] CONFIG" >&2
    exit 2
  }
  config=$1
  [[ -f $config ]] || {
    echo "ERROR: configuration file not found: $config" >&2
    exit 1
  }
  [[ $(stat -c '%a' "$config") == 600 ]] || {
    echo "ERROR: local charge configuration must have mode 0600" >&2
    exit 1
  }
  BATTERY_CONTROL_TEST_MODE=1 VALIDATE_ONLY=1 \
    START_LEVEL_PATH=/dev/null STOP_LEVEL_PATH=/dev/null \
    LOG_PATH=/dev/null DISABLE_PATH=/nonexistent \
    /bin/sh "$SCRIPT_DIR/97-battery-charge-control.sh" "$config"
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
device=$(adb -s "$serial" shell getprop ro.product.device | tr -d '\r')
build=$(adb -s "$serial" shell getprop ro.build.id | tr -d '\r')
case "$device" in marlin | sailfish) ;; *)
  echo "ERROR: unsupported device: $device" >&2
  exit 1
  ;;
esac
[[ $build == QP1A.191005.007.A3 ]] || {
  echo "ERROR: unsupported Android build: $build" >&2
  exit 1
}

if ((!disable)); then
  # shellcheck disable=SC2016 # Variables expand in the remote Android shell.
  root_cmd 'set -e
for path in \
  /sys/module/htc_battery/parameters/charge_start_level \
  /sys/module/htc_battery/parameters/charge_stop_level; do
  [ -r "$path" ] && [ -w "$path" ]
  value=$(cat "$path")
  case "$value" in ""|*[!0-9]*) exit 1;; esac
done' || {
    echo "ERROR: this running kernel does not expose usable native HTC charge thresholds" >&2
    exit 1
  }
fi

if ((disable)); then
  root_cmd 'set -e
umask 077
: > /data/adb/battery-charge-control.disabled
chown 0:0 /data/adb/battery-charge-control.disabled
chmod 0600 /data/adb/battery-charge-control.disabled
if [ -x /data/adb/service.d/97-battery-charge-control.sh ]; then
  /data/adb/service.d/97-battery-charge-control.sh --restore-defaults
fi'
  echo "Charge control disabled; native thresholds restored to 0/100 when the installed service was present."
  exit 0
fi

# Fail safe across an interrupted install: a reboot cannot apply a partial
# update while this marker exists. The marker is removed only after both files
# have been checksum-verified and atomically activated.
root_cmd 'set -e; umask 077
: > /data/adb/battery-charge-control.disabled
chown 0:0 /data/adb/battery-charge-control.disabled
chmod 0600 /data/adb/battery-charge-control.disabled'

echo "Installing configuration"
root_cmd 'set -e; umask 077
cat > /data/adb/.battery-charge-control.conf.new
chown 0:0 /data/adb/.battery-charge-control.conf.new
chmod 0600 /data/adb/.battery-charge-control.conf.new' <"$config"
expected_config=$(sha256sum "$config" | awk '{print $1}')
actual_config=$(root_cmd 'sha256sum /data/adb/.battery-charge-control.conf.new' | tr -d '\r' | awk '{print $1}')
if [[ $actual_config != "$expected_config" ]]; then
  root_cmd 'rm -f /data/adb/.battery-charge-control.conf.new'
  echo "ERROR: staged charge configuration checksum mismatch; controller remains disabled" >&2
  exit 1
fi
root_cmd 'mv /data/adb/.battery-charge-control.conf.new /data/adb/battery-charge-control.conf'

echo "Installing one-shot service"
adb -s "$serial" push "$SCRIPT_DIR/97-battery-charge-control.sh" /data/local/tmp/97-battery-charge-control.staged >/dev/null
root_cmd 'set -e
mkdir -p /data/adb/service.d
cp /data/local/tmp/97-battery-charge-control.staged /data/adb/service.d/.97-battery-charge-control.sh.new
chown 0:0 /data/adb/service.d/.97-battery-charge-control.sh.new
chmod 0755 /data/adb/service.d/.97-battery-charge-control.sh.new'
expected_script=$(sha256sum "$SCRIPT_DIR/97-battery-charge-control.sh" | awk '{print $1}')
actual_script=$(root_cmd 'sha256sum /data/adb/service.d/.97-battery-charge-control.sh.new' | tr -d '\r' | awk '{print $1}')
if [[ $actual_script != "$expected_script" ]]; then
  root_cmd 'rm -f /data/adb/service.d/.97-battery-charge-control.sh.new /data/local/tmp/97-battery-charge-control.staged'
  echo "ERROR: staged charge service checksum mismatch; controller remains disabled" >&2
  exit 1
fi
root_cmd 'set -e
mv /data/adb/service.d/.97-battery-charge-control.sh.new /data/adb/service.d/97-battery-charge-control.sh
rm -f /data/local/tmp/97-battery-charge-control.staged
rm -f /data/adb/battery-charge-control.disabled'

echo "Installed and checksum-verified for $device on $build."
if ((apply_now)); then
  echo "Applying native thresholds now"
  if ! root_cmd '/data/adb/service.d/97-battery-charge-control.sh'; then
    root_cmd 'set -e
umask 077
: > /data/adb/battery-charge-control.disabled
chown 0:0 /data/adb/battery-charge-control.disabled
chmod 0600 /data/adb/battery-charge-control.disabled
/data/adb/service.d/97-battery-charge-control.sh --restore-defaults || true'
    echo "ERROR: live application failed; controller disabled for future boots and defaults requested" >&2
    exit 1
  fi
else
  echo "Thresholds were not changed in this Android session."
  echo "Use --apply-now for a no-reboot application, or reboot later after explicit approval."
fi
