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
# Seconds between retries after a transient failure; 0 disables retrying. The
# override lets an interactive test fail fast instead of looping for hours.
RETRY_INTERVAL_SECONDS=${RETRY_INTERVAL_OVERRIDE:-${RETRY_INTERVAL_SECONDS:-300}}
# 0 means keep trying indefinitely, which is what an unattended appliance wants.
RETRY_MAX_ATTEMPTS=${RETRY_MAX_ATTEMPTS:-0}

case "$WAIT_SECONDS" in *[!0-9]* | '') fail "WAIT_SECONDS must be a non-negative integer" ;; esac
case "$RETRY_INTERVAL_SECONDS" in *[!0-9]* | '') fail "RETRY_INTERVAL_SECONDS must be a non-negative integer" ;; esac
case "$RETRY_MAX_ATTEMPTS" in *[!0-9]* | '') fail "RETRY_MAX_ATTEMPTS must be a non-negative integer" ;; esac
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
  # Optional subdirectory below the share. The locked CIFS client splits a
  # device name into vol->UNC and vol->prepath, so mounting a directory rather
  # than the whole share narrows what the phone can see. Spaces are rejected
  # because /proc/mounts escapes them as \040, which would break the
  # source-matching that validate_mount depends on.
  SMB_PREFIX_PATH=${SMB_PREFIX_PATH:-}
  case "$SMB_PREFIX_PATH" in
    '') ;;
    /* | */) fail "SMB prefix path must not start or end with a slash" ;;
    *,* | *' '* | *\\*) fail "SMB prefix path contains an unsupported character" ;;
    '..' | '../'* | *'/..' | *'/../'*) fail "SMB prefix path must not contain a parent reference" ;;
  esac
  if [ -n "$SMB_PREFIX_PATH" ]; then
    SMB_SOURCE="//$NAS_HOST/$SMB_SHARE/$SMB_PREFIX_PATH"
  else
    SMB_SOURCE="//$NAS_HOST/$SMB_SHARE"
  fi
  EXPECTED_SOURCE="$SMB_SOURCE"
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
# Monotonic seconds. Android corrects the wall clock during boot once the
# network is up, which is exactly when this service runs: a backward correction
# would extend the wait far beyond WAIT_SECONDS and a forward one would end it
# early. /proc/uptime is unaffected by those corrections.
monotonic_seconds() { awk '{print int($1)}' /proc/uptime; }
probe_service_port() {
  /system/bin/toybox nc -4 -w 2 -q 1 "$NAS_HOST" "$service_port" </dev/null >/dev/null 2>&1
}
wait_for_service_port() {
  # Bounded by elapsed time, not by counting sleeps: each failed probe also
  # burns the `nc -w 2` connection timeout, so counting only the sleeps made
  # every wait run for roughly twice WAIT_SECONDS. The final probe may overshoot
  # the deadline by its own timeout, which is bounded and expected.
  wait_deadline=$(($(monotonic_seconds) + WAIT_SECONDS))
  while ! probe_service_port; do
    [ "$(monotonic_seconds)" -lt "$wait_deadline" ] || return 1
    sleep 2
  done
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

if [ "$PROTOCOL" = smb ]; then
  service_port=445
else
  service_port=2049
fi

# One mount attempt. 0 = mounted, 1 = worth retrying, 2 = do not retry.
#
# Remote conditions retry; local ones do not. Anything that depends on the NAS
# being ready -- the port not answering, or the mount command failing while the
# server is still starting its shares -- is retried indefinitely, because a NAS
# that boots more slowly than the phone must not leave the appliance idle. A
# fault on this side cannot be fixed by waiting: an unusable or occupied mount
# point, an unreadable or malformed secret, or a mount that comes up with the
# wrong source, type or mode all stop immediately.
# Every fallible operation below is guarded explicitly. This function is called
# as the left side of `||`, which disables errexit for its whole body in both
# Bash and mksh, so an unguarded failure would fall through: a mkdir that could
# not create the mount point once turned a permanent local misconfiguration
# into an endless retry loop.
attempt_mount() {
  if validate_mount; then
    if ! probe_mount; then
      fail_probe_and_unmount "existing mount failed functional probe"
    fi
    log "existing mount validated: $TARGET"
    return 0
  fi
  if [ -n "$(mounted_line)" ]; then
    log "ERROR: target is occupied by a different or invalid mount"
    return 2
  fi

  if ! mkdir -p "$TARGET"; then
    log "ERROR: could not create the mount point $TARGET"
    return 2
  fi
  if [ ! -d "$TARGET" ]; then
    log "ERROR: mount point is not a directory: $TARGET"
    return 2
  fi
  target_entries=$(find "$TARGET" -mindepth 1 -maxdepth 1 2>/dev/null) || {
    log "ERROR: could not inspect the mount point $TARGET"
    return 2
  }
  if [ -n "$target_entries" ]; then
    log "ERROR: refusing to hide non-empty target"
    return 2
  fi

  if ! wait_for_service_port; then
    log "$PROTOCOL TCP port $service_port not reachable within $WAIT_SECONDS seconds"
    return 1
  fi
  log "$PROTOCOL TCP port $service_port is reachable"

  context_opt=""
  [ -n "$SELINUX_CONTEXT" ] && context_opt=",context=$SELINUX_CONTEXT"
  mount_rc=0
  if [ "$PROTOCOL" = smb ]; then
    [ -r "$SMB_SECRET" ] || {
      log "ERROR: SMB secret is unreadable"
      return 2
    }
    PASS=$(tr -d '\r\n' <"$SMB_SECRET") || {
      log "ERROR: could not read the SMB secret"
      return 2
    }
    case "$PASS" in *','* | '')
      unset PASS
      log "ERROR: SMB password is empty or contains a comma"
      return 2
      ;;
    esac
    modes="file_mode=0444,dir_mode=0555"
    [ "$MOUNT_MODE" = rw ] && modes="file_mode=0664,dir_mode=0775"
    /system/bin/mount -t cifs "$SMB_SOURCE" "$TARGET" \
      -o "$MOUNT_MODE,vers=3.0,sec=ntlmssp,username=$SMB_USER,password=$PASS,uid=1023,gid=1023,forceuid,forcegid,$modes,noperm,iocharset=utf8,nosuid,nodev,noexec$context_opt" || mount_rc=$?
    unset PASS
  else
    /system/bin/mount -t nfs "$NAS_HOST:$NFS_EXPORT" "$TARGET" \
      -o "$MOUNT_MODE,vers=3,proto=tcp,nolock,hard,noatime,nosuid,nodev,noexec,addr=$NAS_HOST$context_opt" || mount_rc=$?
  fi
  if [ "$mount_rc" -ne 0 ]; then
    # The port answered but the mount did not complete. A NAS that has started
    # its listener before its shares are ready looks exactly like this, so treat
    # it as retryable rather than fatal.
    log "mount command failed with status $mount_rc"
    return 1
  fi

  if ! validate_mount; then
    if ! /system/bin/umount "$TARGET"; then
      fail "new mount failed source/type/mode validation and cleanup unmount also failed"
    fi
    log "ERROR: new mount failed source/type/mode validation; mount was unmounted"
    return 2
  fi
  if ! probe_mount; then
    fail_probe_and_unmount "new mount failed functional probe"
  fi
  log "mounted and validated: $TARGET"
  return 0
}

# A one-shot service loses to a slow NAS: if the phone finishes booting before
# the NAS finishes starting Samba, nothing ever tries again and the appliance
# sits idle until someone notices. Keep retrying on transient failures.
attempt=0
while :; do
  attempt=$((attempt + 1))
  attempt_status=0
  attempt_mount || attempt_status=$?
  case "$attempt_status" in
    0) exit 0 ;;
    2) fail "attempt $attempt hit a non-retryable condition; see the log above" ;;
  esac
  [ "$RETRY_INTERVAL_SECONDS" -gt 0 ] || fail "attempt $attempt failed and retrying is disabled"
  if [ "$RETRY_MAX_ATTEMPTS" -gt 0 ] && [ "$attempt" -ge "$RETRY_MAX_ATTEMPTS" ]; then
    fail "giving up after $attempt attempts"
  fi
  log "attempt $attempt failed; retrying in $RETRY_INTERVAL_SECONDS seconds"
  sleep "$RETRY_INTERVAL_SECONDS"
done
