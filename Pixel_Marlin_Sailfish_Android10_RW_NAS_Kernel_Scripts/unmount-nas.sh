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
if ! awk -v target="$TARGET" '$2 == target {found=1} END{exit !found}' /proc/mounts; then
  echo "Already unmounted: $TARGET"
  exit 0
fi
/system/bin/sync
/system/bin/umount "$TARGET"
awk -v target="$TARGET" '$2 == target {found=1} END{exit found}' /proc/mounts || {
  echo "ERROR: mount remains present: $TARGET" >&2
  exit 1
}
echo "Unmounted cleanly: $TARGET"
