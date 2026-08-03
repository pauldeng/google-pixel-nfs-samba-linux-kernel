#!/system/bin/sh
set -eu

# Mount the NAS photo share where Google Photos can see it, and keep MediaStore
# told about new files. Nothing is ever copied to internal flash.
#
# Three facts drive this design, each measured on the target hardware rather
# than assumed:
#
#  1. sdcardfs does not expose mounts made on its lower tree (/data/media), so
#     mounting there is invisible to apps no matter how it is labelled. The
#     mount has to go into a /mnt/runtime view, whose peer group propagates
#     into every app mount namespace.
#  2. MediaStore learns about files from inotify, which cannot fire for writes
#     made on the server by another machine. Files added to the NAS are
#     therefore never noticed on their own; something must scan for them. That
#     scan only indexes - it does not copy.
#  3. While the share is mounted under DCIM, an unreachable NAS makes listing
#     /storage/emulated/0/DCIM itself fail, which degrades the gallery and every
#     media scan. So this service unmounts the share when the NAS goes away and
#     remounts it when the NAS returns; a missing folder is a far smaller
#     problem than a broken DCIM.

CONFIG_PATH=${1:-/data/adb/nas-photos.conf}
LOG_PATH=${LOG_PATH:-/data/adb/nas-photos.log}
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
: "${NAS_HOST:?}" "${SMB_SHARE:?}" "${SMB_USER:?}" "${PHOTO_FOLDER:?}"
SMB_SECRET=${SMB_SECRET_OVERRIDE:-${SMB_SECRET:-}}
: "${SMB_SECRET:?}"
SMB_PREFIX_PATH=${SMB_PREFIX_PATH:-}
WAIT_SECONDS=${WAIT_SECONDS:-60}
SCAN_INTERVAL_SECONDS=${SCAN_INTERVAL_OVERRIDE:-${SCAN_INTERVAL_SECONDS:-300}}
# Reachability is a safety check, not a media-discovery schedule. Keeping this
# separate means a dead mount is removed promptly even when no scan is due.
HEALTH_INTERVAL_SECONDS=${HEALTH_INTERVAL_SECONDS:-15}
# 0 means run forever, which is what an unattended appliance wants. A positive
# value lets a test drive a bounded number of cycles.
MAX_CYCLES=${MAX_CYCLES:-0}
# Bound for any single filesystem call against the mount. A dead NAS makes
# these block for tens of seconds; without a cap one stalled call would stop
# the loop from ever reaching its unmount step.
IO_TIMEOUT=${IO_TIMEOUT:-25}
# Consecutive failed probes required before the share is treated as gone and
# unmounted. Each retry costs the nc timeout plus 5s, so the default reacts in
# well under a minute while ignoring one-off blips.
UNREACHABLE_CONFIRMATIONS=${UNREACHABLE_CONFIRMATIONS:-3}
# Pause between scan broadcasts. Every reboot prunes MediaStore rows for files
# that were not mounted at boot, so the whole folder is re-indexed each time and
# this pace sets how long that takes.
SCAN_PACE_SECONDS=${SCAN_PACE_SECONDS:-1}
# A server-side copy is visible before it is complete. Require the same size
# and mtime across this window, then check once more immediately before asking
# MediaStore to open the file.
FILE_STABILITY_SECONDS=${FILE_STABILITY_SECONDS:-30}
# How many times a file is offered to MediaStore before it is treated as
# unindexable and skipped, rather than rebroadcast on every cycle forever.
REFUSAL_LIMIT=${REFUSAL_LIMIT:-3}
SCAN_WORK_ROOT=${SCAN_WORK_ROOT:-/data/adb}

case "$NAS_HOST" in *[!0-9.]* | '') fail "NAS_HOST must be a numeric IPv4 address" ;; esac
case "$SMB_SHARE" in *','* | */* | *:* | *' '*) fail "SMB share contains an unsupported separator" ;; esac
case "$SMB_USER" in *','* | *' '*) fail "SMB user contains an unsupported separator" ;; esac
case "$SMB_PREFIX_PATH" in
  '') ;;
  /* | */) fail "SMB prefix path must not start or end with a slash" ;;
  *,* | *' '* | *\\*) fail "SMB prefix path contains an unsupported character" ;;
  '..' | '../'* | *'/..' | *'/../'*) fail "SMB prefix path must not contain a parent reference" ;;
esac
# The folder name becomes a directory under DCIM and a MediaStore bucket. Keep
# it to characters that survive a file: URI without escaping, so the scan
# broadcast does not have to quote anything.
case "$PHOTO_FOLDER" in
  '' | *[!A-Za-z0-9._-]*) fail "PHOTO_FOLDER must be a simple name: A-Z a-z 0-9 . _ -" ;;
  '.' | '..') fail "PHOTO_FOLDER must not be a directory reference" ;;
esac
for value in "$WAIT_SECONDS" "$SCAN_INTERVAL_SECONDS" "$HEALTH_INTERVAL_SECONDS" "$MAX_CYCLES" "$IO_TIMEOUT" "$UNREACHABLE_CONFIRMATIONS" "$SCAN_PACE_SECONDS" "$FILE_STABILITY_SECONDS" "$REFUSAL_LIMIT"; do
  case "$value" in *[!0-9]* | '') fail "timing values must be non-negative integers" ;; esac
done
# Zero is meaningful for some of these and silently destructive for others:
# IO_TIMEOUT=0 means "no timeout" to timeout(1), so a dead NAS could block the
# loop forever; UNREACHABLE_CONFIRMATIONS=0 reduces the check to the single
# probe that once unmounted a live share; REFUSAL_LIMIT=0 skips every file, so
# nothing is ever indexed.
for name in HEALTH_INTERVAL_SECONDS IO_TIMEOUT UNREACHABLE_CONFIRMATIONS FILE_STABILITY_SECONDS REFUSAL_LIMIT; do
  eval "value=\$$name"
  [ "$value" -ge 1 ] || fail "$name must be at least 1; 0 disables the protection it provides"
done

if [ -n "$SMB_PREFIX_PATH" ]; then
  SMB_SOURCE="//$NAS_HOST/$SMB_SHARE/$SMB_PREFIX_PATH"
else
  SMB_SOURCE="//$NAS_HOST/$SMB_SHARE"
fi
# The mount goes into a runtime view; apps reach the same files through
# /storage/emulated/0. Both paths name the same mount.
RUNTIME_TARGET="/mnt/runtime/write/emulated/0/DCIM/$PHOTO_FOLDER"
APP_TARGET="/storage/emulated/0/DCIM/$PHOTO_FOLDER"

monotonic_seconds() { awk '{print int($1)}' /proc/uptime; }
probe_service_port() {
  # Same form as 90-nas-mount.sh, deliberately. toybox nc has no -z: it prints
  # "Unknown option z" and fails every time, which turns the readiness wait into
  # a guaranteed WAIT_SECONDS stall and the reachability check into a permanent
  # "NAS is down".
  /system/bin/toybox nc -4 -w 2 -q 1 "$NAS_HOST" 445 </dev/null >/dev/null 2>&1
}
nas_reachable() {
  # Never tear down a working mount on a single failed probe. A lost packet, a
  # momentarily busy server, or a bug in the probe itself would otherwise
  # unmount the share out from under Photos mid-upload - which is exactly what
  # happened during development when the probe was written with an option
  # toybox nc does not support, so every probe failed and the mount was removed.
  # Confirm with consecutive failures a few seconds apart before believing it.
  probe_service_port && return 0
  tries=1
  while [ "$tries" -lt "$UNREACHABLE_CONFIRMATIONS" ]; do
    sleep 5
    probe_service_port && return 0
    tries=$((tries + 1))
  done
  return 1
}

# scan_new_files enables this guard while it owns a workspace. Every potentially
# blocking stage calls it after its own timeout, so a large queue cannot defer
# the normal health cadence. It performs the protective unmount itself; the
# caller remains responsible for discarding its scan workspace.
SCAN_HEALTH_ACTIVE=0
next_scan_health_at=0
scan_health_due() {
  [ "$SCAN_HEALTH_ACTIVE" -eq 1 ] || return 0
  scan_health_now=$(monotonic_seconds)
  [ "$scan_health_now" -ge "$next_scan_health_at" ] || return 0
  if ! nas_reachable; then
    log "NAS became unreachable during media scan; unmounting to keep DCIM usable"
    unmount_share || true
    return 1
  fi
  next_scan_health_at=$((scan_health_now + HEALTH_INTERVAL_SECONDS))
  return 0
}

wait_for_service_port() {
  wait_deadline=$(($(monotonic_seconds) + WAIT_SECONDS))
  while :; do
    if probe_service_port; then return 0; fi
    [ "$(monotonic_seconds)" -lt "$wait_deadline" ] || return 1
    sleep 2
  done
}

# Read init's mount table, not this process's. Mounting and unmounting go
# through nsenter into PID 1, so inspection must look at the same namespace or
# the two could disagree. Measured on this device they do not - the service runs
# in init's namespace already - but that is Magisk's current behaviour, not a
# contract, and a silent divergence here would mean scanning or unmounting on
# stale information.
mount_line() { grep -m1 " $RUNTIME_TARGET " /proc/1/mounts; }
occupied() { mount_line >/dev/null 2>&1; }
is_mounted() {
  # "Is our mount here", not "is something mounted here". The scan and the
  # protective unmount both act on this answer, so answering yes for a mount
  # this service did not create would mean scanning a stranger's filesystem or
  # tearing down someone else's mount.
  occupied || return 1
  validate_mount quiet
}

storage_ready() {
  # On this file-based-encrypted device, user 0's storage stays locked after a
  # reboot until the screen lock is entered, and /storage/emulated/0 has no
  # contents until then. Mounting into it is impossible before that: mkdir
  # returns "Operation not permitted" and mount returns a bare status 1 that
  # says nothing about the cause. Detect it explicitly so the log names the real
  # reason instead of leaving an operator to reproduce the failure by hand.
  # $1 belongs to the shell entered inside PID 1's namespace.
  # shellcheck disable=SC2016
  in_global_ns sh -c '[ -d "$1" ]' sh "/mnt/runtime/write/emulated/0/DCIM"
}

# Mounts must land in init's mount namespace. That namespace holds the
# /mnt/runtime views as members of a shared peer group, and every app namespace
# is a slave of it, so a mount made there appears inside Photos automatically.
# A mount made in this script's own namespace would be invisible to apps: a
# slave does not propagate back to its master.
in_global_ns() { nsenter --mount=/proc/1/ns/mnt -- "$@"; }

target_is_empty() {
  inspection_status=0
  existing=$(
    in_global_ns timeout "$IO_TIMEOUT" find "$RUNTIME_TARGET" \
      -mindepth 1 -maxdepth 1 -print 2>/dev/null
  ) || inspection_status=$?
  if [ "$inspection_status" -ne 0 ]; then
    log "ERROR: could not inspect $RUNTIME_TARGET within ${IO_TIMEOUT}s; refusing to mount over it"
    return 1
  fi
  if [ -n "$existing" ]; then
    log "ERROR: $RUNTIME_TARGET already contains local files; refusing to mount over and hide them"
    return 1
  fi
  return 0
}

mount_share() {
  storage_ready || {
    log "user storage is locked; waiting for the phone to be unlocked before mounting"
    return 1
  }
  occupied && {
    log "ERROR: $RUNTIME_TARGET is already occupied by another mount; refusing to stack on it"
    return 1
  }
  if ! in_global_ns mkdir -p "$RUNTIME_TARGET" 2>/dev/null; then
    log "ERROR: could not create $RUNTIME_TARGET in init's mount namespace"
    return 1
  fi
  # Mounting over a directory that already holds files hides them for as long as
  # the mount lives. If the operator happens to have a real DCIM folder by this
  # name, that looks exactly like their photos disappearing. Refuse instead.
  target_is_empty || return 1
  PASS=$(tr -d '\r\n' <"$SMB_SECRET") || {
    log "ERROR: cannot read the SMB secret"
    return 1
  }
  # A comma ends an option in the -o list, so a password containing one would
  # silently truncate the options and change what gets mounted. 90-nas-mount.sh
  # already refuses both cases; match it.
  case "$PASS" in
    *','* | '')
      unset PASS
      log "ERROR: the SMB secret is empty or contains a comma, which the mount option list cannot carry"
      return 1
      ;;
  esac
  # nosharesock: CIFS otherwise reuses a superblock shared with any other mount
  # of the same share, and SELinux refuses two mounts of one superblock with
  # different contexts ("Same superblock, different security settings").
  # context=: without it the files are 'unlabeled' and every app is denied.
  # soft: bounds I/O when the server disappears.
  # Do not add echo_interval - this 3.18 kernel rejects the whole mount with
  # "Unknown mount option" and the mount silently never happens.
  # Capture the status explicitly. Writing `cmd` then `mount_status=$?` only
  # survives errexit while every caller happens to invoke this from a condition,
  # and that assumption has silently broken decision logic in this repo before.
  mount_status=0
  mount_error=$(
    in_global_ns /system/bin/mount -t cifs "$SMB_SOURCE" "$RUNTIME_TARGET" -o \
      "ro,vers=3.0,sec=ntlmssp,username=$SMB_USER,password=$PASS,uid=1023,gid=1023,forceuid,forcegid,file_mode=0444,dir_mode=0555,noperm,iocharset=utf8,nosuid,nodev,noexec,soft,nosharesock,actimeo=1,context=u:object_r:media_rw_data_file:s0" 2>&1
  ) || mount_status=$?
  PASS=""
  if [ "$mount_status" -ne 0 ]; then
    log "ERROR: mount failed with status $mount_status: ${mount_error:-no error text}"
    in_global_ns rmdir "$RUNTIME_TARGET" 2>/dev/null || true
    return 1
  fi
  validate_mount || {
    log "removing the mount this run just created because it failed validation"
    unmount_share force
    return 1
  }
  log "mounted $SMB_SOURCE at $RUNTIME_TARGET"
  return 0
}

validate_mount() {
  # Confirm the kernel really recorded a read-only CIFS mount from the expected
  # source, rather than trusting that mount exited zero. Pass "quiet" to use it
  # as a predicate; only the post-mount call should narrate a failure.
  quiet=${1:-}
  vlog() { [ -n "$quiet" ] || log "$@"; }
  line=$(mount_line) || {
    vlog "ERROR: no mount recorded at $RUNTIME_TARGET"
    return 1
  }
  case "$line" in
    *" $RUNTIME_TARGET cifs "*) ;;
    *)
      vlog "ERROR: a non-CIFS filesystem occupies $RUNTIME_TARGET; refusing to touch it"
      return 1
      ;;
  esac
  case "$line" in
    "$SMB_SOURCE $RUNTIME_TARGET cifs ro,"*) ;;
    *)
      vlog "ERROR: mount is not the expected read-only source: $line"
      return 1
      ;;
  esac
  case "$line" in
    *context=u:object_r:media_rw_data_file:s0*) ;;
    *)
      vlog "ERROR: mount lacks the media SELinux context; apps would be denied"
      return 1
      ;;
  esac
  return 0
}

unmount_share() {
  # "force" is for a mount this invocation just created and then found invalid.
  # Without it that mount is indistinguishable from a stranger's and would be
  # deliberately left in place - covering DCIM, and blocking every later retry,
  # because the identity check that protects foreign mounts also protects the
  # broken one. Ordinary outage cleanup keeps the strict check.
  force=${1:-}
  if [ -z "$force" ]; then
    is_mounted || {
      occupied && log "WARNING: $RUNTIME_TARGET is occupied by a mount this service did not create; leaving it alone"
      return 0
    }
  else
    occupied || return 0
  fi
  in_global_ns umount "$RUNTIME_TARGET" 2>/dev/null \
    || in_global_ns umount -l "$RUNTIME_TARGET" 2>/dev/null || {
    log "ERROR: could not unmount $RUNTIME_TARGET"
    return 1
  }
  in_global_ns rmdir "$RUNTIME_TARGET" 2>/dev/null || true
  log "unmounted $RUNTIME_TARGET"
  return 0
}

REFUSED_PATH=${REFUSED_PATH:-/data/adb/nas-photos.unindexable}
# State is keyed by path AND the file's size/mtime. Keying by path alone meant a
# file that hit the limit stayed skipped forever, so replacing or repairing it
# at the same path could never make it eligible again. Records are tab
# separated -- count, signature, path -- because a filename may contain spaces.
file_signature() {
  timeout "$IO_TIMEOUT" stat -c '%s:%Y' "$APP_TARGET/$1" 2>/dev/null || printf 'missing\n'
}
refusal_count() {
  want=$1
  [ -f "$REFUSED_PATH" ] || {
    printf '0\n'
    return 0
  }
  while IFS="$(printf '\t')" read -r c recorded_sig recorded_path; do
    [ "$recorded_path" = "$want" ] || continue
    # A changed file is a different file as far as this counter is concerned.
    sig=$(file_signature "$want")
    [ "$recorded_sig" = "$sig" ] || break
    printf '%s\n' "$c"
    return 0
  done <"$REFUSED_PATH"
  printf '0\n'
}
record_refusal() {
  target=$1
  n=$(refusal_count "$target")
  n=$((n + 1))
  sig=$(file_signature "$target")
  : >"$REFUSED_PATH.new"
  if [ -f "$REFUSED_PATH" ]; then
    while IFS="$(printf '\t')" read -r c old_sig old_path; do
      [ -n "$old_path" ] || continue
      [ "$old_path" = "$target" ] && continue
      printf '%s\t%s\t%s\n' "$c" "$old_sig" "$old_path" >>"$REFUSED_PATH.new"
    done <"$REFUSED_PATH"
  fi
  printf '%s\t%s\t%s\n' "$n" "$sig" "$target" >>"$REFUSED_PATH.new"
  mv "$REFUSED_PATH.new" "$REFUSED_PATH"
}

indexed_paths() {
  # Ask MediaStore what it already has for this folder, images and videos both.
  for table in images video; do
    query_status=0
    query_output=$(timeout "$IO_TIMEOUT" content query --uri "content://media/external/$table/media" \
      --projection _data --where "_data LIKE '%/DCIM/$PHOTO_FOLDER/%'" 2>&1) || query_status=$?
    if [ "$query_status" -ne 0 ]; then
      log "ERROR: MediaStore $table query failed with status $query_status: $(printf '%s' "$query_output" | tr '\n' ' ' | cut -c1-200)"
      return 1
    fi
    printf '%s\n' "$query_output" | sed -n "s#^Row: [0-9]* _data=$APP_TARGET/##p"
    scan_health_due || return 1
  done
  return 0
}

scan_new_files() {
  # Index files MediaStore has not seen. This tells the index that files exist;
  # it does not copy them. Runs entirely on the device: driving the same
  # broadcasts one-per-adb-invocation from a host loop was measured to lose 33
  # of 34 requests, so the loop stays here and the result is verified below.
  SCAN_HEALTH_ACTIVE=0
  work=$(mktemp -d "$SCAN_WORK_ROOT/nas-photos-scan.XXXXXX") || {
    log "ERROR: cannot create scan workspace"
    return 1
  }
  SCAN_HEALTH_ACTIVE=1
  next_scan_health_at=$(($(monotonic_seconds) + HEALTH_INTERVAL_SECONDS))
  # Enumerate FILES with paths relative to the mount root, because that is what
  # MediaStore rows reduce to. Listing top-level names with `ls` compared a
  # directory name like "2026" against a row like "2026/IMG.jpg", so every
  # subdirectory looked permanently missing and was rebroadcast every cycle.
  #
  # Do not pipe find straight into sort: the pipeline reports sort's status, so
  # a timed-out walk would yield an empty listing that reads as "nothing new".
  if ! timeout "$IO_TIMEOUT" find "$APP_TARGET" -type f >"$work/raw" 2>/dev/null; then
    log "ERROR: could not walk $APP_TARGET within ${IO_TIMEOUT}s"
    rm -rf "$work"
    SCAN_HEALTH_ACTIVE=0
    return 1
  fi
  if ! scan_health_due; then
    rm -rf "$work"
    SCAN_HEALTH_ACTIVE=0
    return 1
  fi
  sed "s#^$APP_TARGET/##" "$work/raw" | sort >"$work/present"
  if ! indexed_paths >"$work/indexed.raw"; then
    rm -rf "$work"
    SCAN_HEALTH_ACTIVE=0
    return 1
  fi
  sort -u "$work/indexed.raw" >"$work/indexed"
  comm -23 "$work/present" "$work/indexed" >"$work/candidates"
  # Some files will never appear in MediaStore: sidecars, checksum files,
  # anything whose type the scanner does not index. Without this list they stay
  # "missing" forever and are rebroadcast on every cycle, which both wastes
  # network reads and buries a real failure in permanent noise. A file is
  # skipped only after it has been offered and declined REFUSAL_LIMIT times.
  : >"$work/missing"
  skipped=0
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    candidate_refusals=$(refusal_count "$cand")
    if ! scan_health_due; then
      rm -rf "$work"
      SCAN_HEALTH_ACTIVE=0
      return 1
    fi
    if [ "$candidate_refusals" -ge "$REFUSAL_LIMIT" ]; then
      skipped=$((skipped + 1))
    else
      printf '%s\n' "$cand" >>"$work/missing"
    fi
  done <"$work/candidates"
  missing=$(wc -l <"$work/missing" | tr -d ' ')
  if [ "$missing" -eq 0 ]; then
    [ "$skipped" -eq 0 ] || log "scan: nothing new; $skipped file(s) permanently unindexable, see $REFUSED_PATH"
    rm -rf "$work"
    SCAN_HEALTH_ACTIVE=0
    return 0
  fi

  # A file appears in SMB directory listings while another client is still
  # copying it. MediaStore may accept that partial file and never reopen the
  # completed version because the path already has a row. Observe every
  # candidate across a stability window, and carry the observed signature into
  # the broadcast loop so a late change is caught too. Atomic server-side
  # rename remains the preferred ingestion method; this is the safety net.
  : >"$work/observed"
  unstable=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    signature=$(file_signature "$name")
    if ! scan_health_due; then
      rm -rf "$work"
      SCAN_HEALTH_ACTIVE=0
      return 1
    fi
    [ "$signature" != missing ] || {
      unstable=$((unstable + 1))
      SCAN_RECHECK_SOON=1
      continue
    }
    printf '%s\t%s\n' "$signature" "$name" >>"$work/observed"
  done <"$work/missing"
  stability_remaining=$FILE_STABILITY_SECONDS
  while [ "$stability_remaining" -gt 0 ]; do
    stability_pause=$HEALTH_INTERVAL_SECONDS
    [ "$stability_pause" -le "$stability_remaining" ] || stability_pause=$stability_remaining
    sleep "$stability_pause"
    stability_remaining=$((stability_remaining - stability_pause))
    if ! scan_health_due; then
      rm -rf "$work"
      SCAN_HEALTH_ACTIVE=0
      return 1
    fi
  done

  : >"$work/stable"
  while IFS="$(printf '\t')" read -r observed_signature name; do
    [ -n "$name" ] || continue
    if [ "$(file_signature "$name")" = "$observed_signature" ]; then
      printf '%s\t%s\n' "$observed_signature" "$name" >>"$work/stable"
    else
      unstable=$((unstable + 1))
      SCAN_RECHECK_SOON=1
    fi
    if ! scan_health_due; then
      rm -rf "$work"
      SCAN_HEALTH_ACTIVE=0
      return 1
    fi
  done <"$work/observed"
  stable=$(wc -l <"$work/stable" | tr -d ' ')
  if [ "$stable" -eq 0 ]; then
    log "scan: $missing new, none stable for ${FILE_STABILITY_SECONDS}s; $unstable deferred"
    rm -rf "$work"
    SCAN_HEALTH_ACTIVE=0
    return 0
  fi

  sent=0
  reported=0
  broadcast_failed=0
  : >"$work/offered"
  while IFS="$(printf '\t')" read -r observed_signature name; do
    [ -n "$name" ] || continue
    # A large queue may take many minutes. Recheck immediately before each
    # broadcast so a file that changed after the shared stability window is
    # deferred rather than indexed partially.
    current_signature=$(file_signature "$name")
    if ! scan_health_due; then
      rm -rf "$work"
      SCAN_HEALTH_ACTIVE=0
      return 1
    fi
    if [ "$current_signature" != "$observed_signature" ]; then
      unstable=$((unstable + 1))
      SCAN_RECHECK_SOON=1
      continue
    fi
    # Keep the failure text. Reporting only a count meant a scan that indexed
    # nothing looked identical to one with nothing to do, and the cause had to
    # be chased by hand outside the service.
    # </dev/null matters. `am` delegates to `cmd`, which passes its stdin fd to
    # system_server over Binder. Inside this loop stdin is the workspace file in
    # /data/adb, whose adb_data_file label system_server may not read, so every
    # broadcast failed with "Failure calling service activity: Failed
    # transaction (2147483646)" while the identical command worked by hand.
    if scan_output=$(timeout "$IO_TIMEOUT" am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
      -d "file://$APP_TARGET/$name" </dev/null 2>&1); then
      sent=$((sent + 1))
      printf '%s\n' "$name" >>"$work/offered"
    else
      broadcast_failed=$((broadcast_failed + 1))
      SCAN_RECHECK_SOON=1
      if [ "$reported" -eq 0 ]; then
        log "ERROR: scan broadcast failed for $name: $(printf '%s' "$scan_output" | tr '\n' ' ' | cut -c1-200)"
        reported=1
      fi
    fi
    # MediaProvider indexes asynchronously; a short pause keeps a large batch
    # from outrunning it.
    [ "$SCAN_PACE_SECONDS" -eq 0 ] || sleep "$SCAN_PACE_SECONDS"
    # Reachability cannot wait for a thousand-file queue to finish. Check by
    # monotonic time rather than file count, because a timed-out Android call
    # must not multiply the outage bound by the size of a nominal batch.
    if ! scan_health_due; then
      rm -rf "$work"
      SCAN_HEALTH_ACTIVE=0
      return 1
    fi
  done <"$work/stable"
  sleep 5
  if ! indexed_paths >"$work/after.raw"; then
    log "WARNING: MediaStore could not be verified; no refusal counts were changed"
    rm -rf "$work"
    SCAN_HEALTH_ACTIVE=0
    return 1
  fi
  sort -u "$work/after.raw" >"$work/after"
  landed=$(comm -12 "$work/offered" "$work/after" | wc -l | tr -d ' ')
  log "scan: $missing new, $sent broadcast, $landed indexed, $skipped skipped, $unstable unstable deferred"
  if [ "$landed" -ne "$sent" ]; then
    # A refusal means MediaStore accepted the scan request but did not produce a
    # row. A broadcast command that failed was never offered and must remain
    # eligible next cycle. Likewise, a failed verification query above changes
    # no counters. Temporary Android-service failures must not permanently hide
    # valid media.
    comm -23 "$work/offered" "$work/after" | while IFS= read -r stuck; do
      [ -n "$stuck" ] || continue
      record_refusal "$stuck"
    done
    log "WARNING: $((sent - landed)) offered file(s) did not index; retried up to $REFUSAL_LIMIT times before being skipped"
  fi
  [ "$broadcast_failed" -eq 0 ] || log "WARNING: $broadcast_failed scan broadcast(s) failed and remain eligible for the next cycle"
  rm -rf "$work"
  SCAN_HEALTH_ACTIVE=0
  return 0
}

log "service starting for $SMB_SOURCE -> $APP_TARGET"
if wait_for_service_port; then
  is_mounted || mount_share || log "initial mount failed; the retry loop continues"
else
  log "NAS not reachable within ${WAIT_SECONDS}s; will keep checking"
fi

cycle=0
next_scan_at=0
while :; do
  cycle=$((cycle + 1))
  if nas_reachable; then
    if ! is_mounted && mount_share; then
      next_scan_at=0
    fi
    if is_mounted && [ "$(monotonic_seconds)" -ge "$next_scan_at" ]; then
      SCAN_RECHECK_SOON=0
      scan_status=0
      scan_new_files || scan_status=$?
      scan_finished_at=$(monotonic_seconds)
      if [ "$scan_status" -ne 0 ] || [ "$SCAN_RECHECK_SOON" -eq 1 ]; then
        next_scan_at=$((scan_finished_at + HEALTH_INTERVAL_SECONDS))
      else
        next_scan_at=$((scan_finished_at + SCAN_INTERVAL_SECONDS))
      fi
      [ "$scan_status" -eq 0 ] || log "scan cycle failed"
    fi
  elif is_mounted; then
    # Protect the media tree. With the share mounted and the server gone,
    # listing DCIM itself fails, which breaks the gallery and every media scan.
    log "NAS unreachable after $UNREACHABLE_CONFIRMATIONS probes; unmounting to keep DCIM usable"
    unmount_share || true
    next_scan_at=0
  fi
  [ "$MAX_CYCLES" -eq 0 ] || [ "$cycle" -lt "$MAX_CYCLES" ] || break
  [ "$SCAN_INTERVAL_SECONDS" -gt 0 ] || break
  sleep "$HEALTH_INTERVAL_SECONDS"
done
log "service exiting after $cycle cycle(s)"
