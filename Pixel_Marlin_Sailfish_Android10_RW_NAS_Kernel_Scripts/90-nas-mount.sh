#!/system/bin/sh
set -eu

CONFIG_PATH=${1:-/data/adb/nas-mount.conf}
LOG_PATH=${LOG_PATH:-/data/adb/nas-mount.log}
umask 077
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_PATH"; }
fail() {
  log "ERROR: $*"
  echo "ERROR: $*" >&2
  exit 1
}

[ -f "$CONFIG_PATH" ] || fail "configuration is absent: $CONFIG_PATH"
# The installer requires this file to be root-owned mode 0600 before execution.
# shellcheck disable=SC1090
. "$CONFIG_PATH"
: "${PROTOCOL:?}" "${NAS_HOST:?}" "${TARGET:?}" "${MOUNT_MODE:?}" "${REQUIRE_WRITE_TEST:?}"
WAIT_SECONDS=${WAIT_SECONDS:-60}
SELINUX_CONTEXT=${SELINUX_CONTEXT:-}
SMB_SECRET=${SMB_SECRET_OVERRIDE:-${SMB_SECRET:-}}

case "$WAIT_SECONDS" in *[!0-9]* | '') fail "WAIT_SECONDS must be a non-negative integer" ;; esac
case "$SELINUX_CONTEXT" in '' | u:object_r:media_rw_data_file:s0) ;; *) fail "unsupported SELinux context" ;; esac

case "$NAS_HOST" in
  *[!0-9.]* | '') fail "NAS_HOST must be a numeric IPv4 address" ;;
esac
case "$MOUNT_MODE:$REQUIRE_WRITE_TEST" in
  ro:0 | rw:1) ;;
  *) fail "mode/probe mismatch; require ro:0 or rw:1" ;;
esac
if [ "$PROTOCOL" = smb ]; then
  : "${SMB_SHARE:?}" "${SMB_USER:?}" "${SMB_SECRET:?}"
  case "$SMB_SHARE" in *','* | */* | *:* | *' '*) fail "SMB share contains an unsupported separator" ;; esac
  case "$SMB_USER" in *','* | *' '*) fail "SMB user contains an unsupported separator" ;; esac
  EXPECTED_SOURCE="//$NAS_HOST/$SMB_SHARE"
elif [ "$PROTOCOL" = nfs ]; then
  : "${NFS_EXPORT:?}"
  case "$NFS_EXPORT" in /*) ;; *) fail "NFS export must be an absolute path" ;; esac
  case "$NFS_EXPORT" in *','* | *' '*) fail "NFS export contains an unsupported separator" ;; esac
  EXPECTED_SOURCE="$NAS_HOST:$NFS_EXPORT"
else
  fail "unsupported protocol: $PROTOCOL"
fi
case "$TARGET" in
  /data/local/tmp/nas-ro | /data/local/tmp/nas-rw) ;;
  /mnt/runtime/default/emulated/0/DCIM/NAS-Inbox | /mnt/runtime/read/emulated/0/DCIM/NAS-Inbox | /mnt/runtime/write/emulated/0/DCIM/NAS-Inbox)
    [ "${ALLOW_EXPERIMENTAL_RUNTIME_TARGET:-0}" = 1 ] || fail "runtime-view targets require explicit ALLOW_EXPERIMENTAL_RUNTIME_TARGET=1"
    ;;
  *) fail "target is outside the approved root-only or experimental paths: $TARGET" ;;
esac

mounted_line() { awk -v target="$TARGET" '$2 == target {print; exit}' /proc/mounts; }
validate_mount() {
  line=$(mounted_line)
  [ -n "$line" ] || return 1
  echo "$line" | awk -v source="$EXPECTED_SOURCE" '$1 == source {ok=1} END{exit !ok}' || return 1
  echo "$line" | awk -v mode="$MOUNT_MODE" '{n=split($4,a,","); for(i=1;i<=n;i++) if(a[i]==mode) found=1} END{exit !found}' || return 1
  echo "$line" | awk -v protocol="$PROTOCOL" '{expected=(protocol=="smb"?"cifs":"nfs"); exit !($3==expected)}' || return 1
}
PROBE_FAILURE=""
cleanup_rw_probe() {
  [ -n "${probe:-}" ] || return 0
  rm -f "$probe/create.txt" "$probe/renamed.txt" 2>/dev/null || true
  rmdir "$probe" 2>/dev/null || true
}
record_rw_probe_failure() {
  PROBE_FAILURE=$1
  cleanup_rw_probe
  log "ERROR: $PROBE_FAILURE" || true
}
probe_mount() {
  PROBE_FAILURE=""
  if [ "$MOUNT_MODE" = ro ]; then
    marker="$TARGET/.pixel-must-not-write-$$"
    if touch "$marker" 2>/dev/null; then
      PROBE_FAILURE="read-only mount accepted a write"
      if ! rm -f "$marker"; then
        PROBE_FAILURE="$PROBE_FAILURE and marker cleanup failed"
      fi
      log "ERROR: $PROBE_FAILURE" || true
      return 1
    fi
    if ! log "read-only write-rejection probe passed"; then
      PROBE_FAILURE="read-only probe passed but evidence logging failed"
      return 1
    fi
    return 0
  fi
  probe="$TARGET/.pixel-rw-test-$$"
  if ! mkdir "$probe"; then
    record_rw_probe_failure "read/write probe could not create its directory"
    return 1
  fi
  if ! printf 'alpha\n' >"$probe/create.txt"; then
    record_rw_probe_failure "read/write probe could not create its file"
    return 1
  fi
  if ! printf 'beta\n' >>"$probe/create.txt"; then
    record_rw_probe_failure "read/write probe could not append to its file"
    return 1
  fi
  if ! tail -n 1 "$probe/create.txt" | grep -qx beta; then
    record_rw_probe_failure "read/write probe could not read back appended data"
    return 1
  fi
  if ! mv "$probe/create.txt" "$probe/renamed.txt"; then
    record_rw_probe_failure "read/write probe could not rename its file"
    return 1
  fi
  if ! sha256sum "$probe/renamed.txt" >>"$LOG_PATH"; then
    record_rw_probe_failure "read/write probe could not checksum its file"
    return 1
  fi
  if ! rm "$probe/renamed.txt"; then
    record_rw_probe_failure "read/write probe could not delete its file"
    return 1
  fi
  if ! rmdir "$probe"; then
    record_rw_probe_failure "read/write probe could not delete its directory"
    return 1
  fi
  if ! log "read/write create/read/append/rename/checksum/delete probe passed"; then
    PROBE_FAILURE="read/write probe passed but evidence logging failed"
    return 1
  fi
  return 0
}
# End mount probe functions.

trap cleanup_rw_probe EXIT
trap 'cleanup_rw_probe; exit 1' HUP INT TERM

fail_probe_and_unmount() {
  probe_context=$1
  probe_reason=${PROBE_FAILURE:-unknown functional-probe failure}
  if ! /system/bin/umount "$TARGET"; then
    fail "$probe_context: $probe_reason; cleanup unmount also failed"
  fi
  fail "$probe_context: $probe_reason; mount was unmounted"
}

if validate_mount; then
  if ! probe_mount; then
    fail_probe_and_unmount "existing mount failed functional probe"
  fi
  log "existing mount validated: $TARGET"
  exit 0
elif [ -n "$(mounted_line)" ]; then
  fail "target is occupied by a different or invalid mount"
fi

mkdir -p "$TARGET"
if find "$TARGET" -mindepth 1 -maxdepth 1 | grep -q .; then
  fail "refusing to hide non-empty target"
fi

elapsed=0
if [ "$PROTOCOL" = smb ]; then
  service_port=445
else
  service_port=2049
fi
while ! /system/bin/toybox nc -4 -w 2 -q 1 "$NAS_HOST" "$service_port" </dev/null >/dev/null 2>&1; do
  [ "$elapsed" -lt "$WAIT_SECONDS" ] || fail "$PROTOCOL TCP port $service_port did not become reachable within $WAIT_SECONDS seconds"
  sleep 2
  elapsed=$((elapsed + 2))
done
log "$PROTOCOL TCP port $service_port is reachable"

context_opt=""
[ -n "$SELINUX_CONTEXT" ] && context_opt=",context=$SELINUX_CONTEXT"
if [ "$PROTOCOL" = smb ]; then
  [ -r "$SMB_SECRET" ] || fail "SMB secret is unreadable"
  PASS=$(tr -d '\r\n' <"$SMB_SECRET")
  case "$PASS" in *','* | '')
    unset PASS
    fail "SMB password is empty or contains a comma"
    ;;
  esac
  modes="file_mode=0444,dir_mode=0555"
  [ "$MOUNT_MODE" = rw ] && modes="file_mode=0664,dir_mode=0775"
  /system/bin/mount -t cifs "//$NAS_HOST/$SMB_SHARE" "$TARGET" \
    -o "$MOUNT_MODE,vers=3.0,sec=ntlmssp,username=$SMB_USER,password=$PASS,uid=1023,gid=1023,forceuid,forcegid,$modes,noperm,iocharset=utf8,nosuid,nodev,noexec$context_opt"
  unset PASS
elif [ "$PROTOCOL" = nfs ]; then
  /system/bin/mount -t nfs "$NAS_HOST:$NFS_EXPORT" "$TARGET" \
    -o "$MOUNT_MODE,vers=3,proto=tcp,nolock,hard,noatime,nosuid,nodev,noexec,addr=$NAS_HOST$context_opt"
fi

if ! validate_mount; then
  if ! /system/bin/umount "$TARGET"; then
    fail "new mount failed source/type/mode validation and cleanup unmount also failed"
  fi
  fail "new mount failed source/type/mode validation; mount was unmounted"
fi
if ! probe_mount; then
  fail_probe_and_unmount "new mount failed functional probe"
fi
log "mounted and validated: $TARGET"
