#!/usr/bin/env bash
set -euo pipefail

# Read-only continuity/thermal monitor for the mains-powered Pixel photo
# appliance. This does not change Wi-Fi, mounts, apps, files, or device-idle
# state. Usage:
#   monitor-nas-photos-soak.sh SERIAL [HOURS] [INTERVAL_SECONDS] [LOG_PATH]

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/host-shell-lib.sh
. "$PROJECT_ROOT/Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/host-shell-lib.sh"

serial=${1:-}
hours=${2:-8}
interval=${3:-300}
log_path=${4:-$PROJECT_ROOT/pixel-nas-operator-config/pixel-nas-soak-$(date +%Y%m%d-%H%M%S).log}
max_temperature=${MAX_TEMP_TENTHS_C:-450}
max_service_rss=${MAX_SERVICE_RSS_KIB:-32768}
max_log_growth=${MAX_LOG_GROWTH_BYTES:-1048576}

case "$serial" in '' | *[!A-Za-z0-9._:-]*)
  echo "ERROR: a simple ADB serial is required" >&2
  exit 2
  ;;
esac
for value in "$hours" "$interval" "$max_temperature" "$max_service_rss" "$max_log_growth"; do
  case "$value" in '' | *[!0-9]*)
    echo "ERROR: duration, interval, temperature, RSS, and log limits must be integers" >&2
    exit 2
    ;;
  esac
done
((hours >= 1)) || {
  echo "ERROR: HOURS must be at least 1" >&2
  exit 2
}
((interval >= 60)) || {
  echo "ERROR: INTERVAL_SECONDS must be at least 60" >&2
  exit 2
}
((max_temperature >= 1)) || {
  echo "ERROR: MAX_TEMP_TENTHS_C must be at least 1" >&2
  exit 2
}
((max_service_rss >= 1)) || {
  echo "ERROR: MAX_SERVICE_RSS_KIB must be at least 1" >&2
  exit 2
}
((max_log_growth >= 1)) || {
  echo "ERROR: MAX_LOG_GROWTH_BYTES must be at least 1" >&2
  exit 2
}

[[ ! -e $log_path ]] || {
  echo "ERROR: refusing to overwrite existing monitor log: $log_path" >&2
  exit 1
}
mkdir -p -- "$(dirname -- "$log_path")"
(
  set -o noclobber
  : >"$log_path"
)

root_cmd() {
  local command_arg
  command_arg=$(quote_remote_command "$1")
  timeout 10 adb -s "$serial" shell "su -c $command_arg"
}

device_config=$(root_cmd 'cat /data/adb/nas-photos.conf')
config_value() { awk -F= -v key="$1" '$1 == key {print substr($0, length(key) + 2); exit}' <<<"$device_config"; }
photo_folder=$(config_value PHOTO_FOLDER)
nas_host=$(config_value NAS_HOST)
smb_share=$(config_value SMB_SHARE)
smb_prefix_path=$(config_value SMB_PREFIX_PATH)
case "$photo_folder" in
  '' | *[!A-Za-z0-9._-]* | '.' | '..')
    echo "ERROR: device PHOTO_FOLDER is absent or unsafe" >&2
    exit 1
    ;;
esac
case "$nas_host" in '' | *[!0-9.]*)
  echo "ERROR: device NAS_HOST is absent or unsafe" >&2
  exit 1
  ;;
esac
case "$smb_share" in '' | *','* | */* | *:* | *' '*)
  echo "ERROR: device SMB_SHARE is absent or unsafe" >&2
  exit 1
  ;;
esac
case "$smb_prefix_path" in
  '') ;;
  /* | */ | *','* | *' '* | *\\* | '..' | '../'* | *'/..' | *'/../'*)
    echo "ERROR: device SMB_PREFIX_PATH is unsafe" >&2
    exit 1
    ;;
esac

target_suffix="/DCIM/$photo_folder"
expected_source="//$nas_host/$smb_share"
[[ -z $smb_prefix_path ]] || expected_source="$expected_source/$smb_prefix_path"
repository_service="$PROJECT_ROOT/Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/96-nas-photos.sh"
expected_service_hash=$(sha256sum "$repository_service" | awk '{print $1}')
installed_service_hash=$(root_cmd 'sha256sum /data/adb/service.d/96-nas-photos.sh' | awk '{print $1}' | tr -d '\r')
[[ $installed_service_hash == "$expected_service_hash" ]] || {
  echo "ERROR: installed service checksum does not match the repository copy" >&2
  exit 1
}
protected_modes=$(root_cmd 'stat -c "%n:%u:%g:%a" /data/adb/nas-photos.conf /data/adb/nas-smb.secret')
[[ $protected_modes == *'/data/adb/nas-photos.conf:0:0:600'* && $protected_modes == *'/data/adb/nas-smb.secret:0:0:600'* ]] || {
  echo "ERROR: device config or secret is not root-owned mode 0600" >&2
  exit 1
}
duration=$((hours * 3600))
start_epoch=$(date +%s)
sample=0
anomalies=0
baseline_service_pid=
baseline_log_bytes=

record() { printf '%s\n' "$*" | tee -a "$log_path"; }
record "monitor_start=$(date --iso-8601=seconds) serial=$serial hours=$hours interval=$interval max_temp_tenths_c=$max_temperature max_service_rss_kib=$max_service_rss max_log_growth_bytes=$max_log_growth service_sha256=$installed_service_hash"

while :; do
  now_epoch=$(date +%s)
  elapsed=$((now_epoch - start_epoch))
  now=$(date --iso-8601=seconds)
  device_state=$(timeout 10 adb -s "$serial" get-state 2>/dev/null || printf 'unavailable')

  if [[ $device_state == device ]]; then
    process_output=$(root_cmd 'ps -A -o PID,RSS,ARGS' 2>/dev/null || true)
    service_count=$(awk '($3 == "sh" || $3 == "/system/bin/sh") && $4 == "/data/adb/service.d/96-nas-photos.sh" && NF == 4 {n++} END {print n+0}' <<<"$process_output")
    service_pid=$(awk '($3 == "sh" || $3 == "/system/bin/sh") && $4 == "/data/adb/service.d/96-nas-photos.sh" && NF == 4 {print $1; exit}' <<<"$process_output")
    service_rss=$(awk '($3 == "sh" || $3 == "/system/bin/sh") && $4 == "/data/adb/service.d/96-nas-photos.sh" && NF == 4 {sum += $2} END {print sum+0}' <<<"$process_output")
    mount_output=$(root_cmd mount 2>/dev/null || true)
    mount_count=$(awk -v suffix="$target_suffix" '
      function expected(path) {
        return path == "/storage/emulated/0" suffix ||
          path == "/mnt/runtime/default/emulated/0" suffix ||
          path == "/mnt/runtime/read/emulated/0" suffix ||
          path == "/mnt/runtime/write/emulated/0" suffix ||
          path == "/mnt/runtime/full/emulated/0" suffix
      }
      expected($3) && $5 == "cifs" {n++}
      END {print n+0}
    ' <<<"$mount_output")
    valid_mount_count=$(awk -v suffix="$target_suffix" -v source="$expected_source" '
      function expected(path) {
        return path == "/storage/emulated/0" suffix ||
          path == "/mnt/runtime/default/emulated/0" suffix ||
          path == "/mnt/runtime/read/emulated/0" suffix ||
          path == "/mnt/runtime/write/emulated/0" suffix ||
          path == "/mnt/runtime/full/emulated/0" suffix
      }
      $1 == source && expected($3) && $5 == "cifs" && $6 ~ /^\(ro,/ && $6 ~ /context=u:object_r:media_rw_data_file:s0/ {n++}
      END {print n+0}
    ' <<<"$mount_output")
    wifi=$(timeout 10 adb -s "$serial" shell settings get global wifi_on 2>/dev/null | tr -d '\r' || true)
    if timeout 5 adb -s "$serial" shell "ls /storage/emulated/0/DCIM >/dev/null"; then
      dcim_status=0
    else
      dcim_status=$?
    fi
    battery=$(timeout 10 adb -s "$serial" shell dumpsys battery 2>/dev/null || true)
    temperature=$(awk '/temperature:/ {print $2; exit}' <<<"$battery")
    battery_level=$(awk '/level:/ {print $2; exit}' <<<"$battery")
    charging_status=$(awk '/status:/ {print $2; exit}' <<<"$battery")
    device_idle=$(timeout 10 adb -s "$serial" shell dumpsys deviceidle 2>/dev/null || true)
    idle_charging=$(awk 'match($0, /mCharging=[^ ]+/) {print substr($0, RSTART + 10, RLENGTH - 10); exit}' <<<"$device_idle")
    screen_on=$(awk 'match($0, /mScreenOn=[^ ]+/) {print substr($0, RSTART + 10, RLENGTH - 10); exit}' <<<"$device_idle")
    idle_state=$(awk 'match($0, /mState=[^ ]+/) {print substr($0, RSTART + 7, RLENGTH - 7); exit}' <<<"$device_idle")
    light_idle_state=$(awk 'match($0, /mLightState=[^ ]+/) {print substr($0, RSTART + 12, RLENGTH - 12); exit}' <<<"$device_idle")
    log_bytes=$(root_cmd 'stat -c %s /data/adb/nas-photos.log' 2>/dev/null | tr -d '\r' || true)

    sample_bad=0
    [[ $service_count == 1 && $mount_count == 5 && $valid_mount_count == 5 && $wifi == 1 && $dcim_status == 0 ]] || sample_bad=1
    [[ $temperature =~ ^[0-9]+$ && $temperature -le $max_temperature ]] || sample_bad=1
    [[ $service_pid =~ ^[0-9]+$ && $service_rss =~ ^[0-9]+$ && $service_rss -gt 0 && $service_rss -le $max_service_rss && $log_bytes =~ ^[0-9]+$ ]] || sample_bad=1
    [[ $charging_status == 2 || $charging_status == 5 ]] || sample_bad=1
    [[ $idle_charging == true && $screen_on == false && $idle_state == ACTIVE ]] || sample_bad=1
    if [[ $service_count == 1 && $service_pid =~ ^[0-9]+$ ]]; then
      [[ -n $baseline_service_pid ]] || baseline_service_pid=$service_pid
      [[ $service_pid == "$baseline_service_pid" ]] || sample_bad=1
    fi
    if [[ $log_bytes =~ ^[0-9]+$ ]]; then
      [[ -n $baseline_log_bytes ]] || baseline_log_bytes=$log_bytes
      log_growth=$((log_bytes - baseline_log_bytes))
      ((log_growth >= 0 && log_growth <= max_log_growth)) || sample_bad=1
    else
      log_growth=unknown
    fi
    if ((sample_bad != 0)); then
      anomalies=$((anomalies + 1))
    fi
    record "sample=$(printf '%03d' "$sample") time=$now elapsed=${elapsed}s adb=device service=$service_count service_pid=${service_pid:-unknown} service_rss_kib=$service_rss mounts=$mount_count valid_mounts=$valid_mount_count wifi=$wifi dcim=$dcim_status temp_tenths_c=${temperature:-unknown} battery=${battery_level:-unknown} charging_status=${charging_status:-unknown} idle_charging=${idle_charging:-unknown} screen_on=${screen_on:-unknown} idle_state=${idle_state:-unknown} light_idle_state=${light_idle_state:-unknown} log_bytes=${log_bytes:-unknown} log_growth_bytes=$log_growth anomaly=$sample_bad anomalies=$anomalies"
  else
    anomalies=$((anomalies + 1))
    record "sample=$(printf '%03d' "$sample") time=$now elapsed=${elapsed}s adb=$device_state anomaly=1 anomalies=$anomalies"
  fi

  ((elapsed >= duration)) && break
  sample=$((sample + 1))
  sleep_for=$interval
  ((elapsed + sleep_for <= duration)) || sleep_for=$((duration - elapsed))
  sleep "$sleep_for"
done

record "monitor_complete=$(date --iso-8601=seconds) samples=$((sample + 1)) anomalies=$anomalies"
((anomalies == 0))
