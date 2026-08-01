#!/system/bin/sh
set -eu

TARGET=${1:-}
case "$TARGET" in
  /data/local/tmp/nas-ro | /data/local/tmp/nas-rw | /mnt/runtime/default/emulated/0/DCIM/NAS-Inbox | /mnt/runtime/read/emulated/0/DCIM/NAS-Inbox | /mnt/runtime/write/emulated/0/DCIM/NAS-Inbox) ;;
  *)
    echo "ERROR: approved explicit target argument required" >&2
    exit 2
    ;;
esac

namespace=$(readlink /proc/self/ns/mnt 2>/dev/null || echo unavailable)
printf 'namespace=%s\n' "$namespace"
line=$(awk -v target="$TARGET" '$2 == target {print; exit}' /proc/mounts)
if [ -z "$line" ]; then
  echo "ERROR: target is not visible in this mount namespace: $TARGET" >&2
  exit 3
fi
printf 'mount=%s\n' "$line"
