#!/system/bin/sh
set -eu

[ "$#" -eq 3 ] || {
  echo "Usage: $0 NAS_SOURCE LOCAL_TARGET RELATIVE_PATH_MANIFEST" >&2
  exit 2
}
NAS_SOURCE=$1
LOCAL_TARGET=$2
MANIFEST=$3
case "$NAS_SOURCE" in /data/local/tmp/nas-ro/* | /data/local/tmp/nas-ro) ;; *)
  echo "ERROR: source must be under the read-only NAS mount" >&2
  exit 1
  ;;
esac
[ "$LOCAL_TARGET" = /storage/emulated/0/DCIM/NAS-Inbox ] || {
  echo "ERROR: unsupported local target" >&2
  exit 1
}
[ -f "$MANIFEST" ] || {
  echo "ERROR: manifest is absent" >&2
  exit 1
}
count=$(grep -cv '^[[:space:]]*$' "$MANIFEST" || true)
[ "$count" -gt 0 ] && [ "$count" -le 100 ] || {
  echo "ERROR: manifest must name 1 to 100 files" >&2
  exit 1
}
mkdir -p "$LOCAL_TARGET"

while IFS= read -r relative || [ -n "$relative" ]; do
  [ -n "$relative" ] || continue
  case "$relative" in /* | .. | ../* | */.. | */../*)
    echo "ERROR: unsafe relative path: $relative" >&2
    exit 1
    ;;
  esac
  if LC_ALL=C printf '%s' "$relative" | grep -q '[[:cntrl:]]'; then
    echo "ERROR: control character in relative path" >&2
    exit 1
  fi
  source_file="$NAS_SOURCE/$relative"
  destination="$LOCAL_TARGET/$(basename "$relative")"
  [ -f "$source_file" ] || {
    echo "ERROR: source is not a regular file: $source_file" >&2
    exit 1
  }
  [ ! -L "$source_file" ] || {
    echo "ERROR: refusing a symbolic-link source: $relative" >&2
    exit 1
  }
  [ ! -e "$destination" ] || {
    echo "ERROR: refusing to overwrite local file: $destination" >&2
    exit 1
  }
  cp "$source_file" "$destination"
  restorecon "$destination" 2>/dev/null || true
  source_sha=$(sha256sum "$source_file" | awk '{print $1}')
  destination_sha=$(sha256sum "$destination" | awk '{print $1}')
  [ "$source_sha" = "$destination_sha" ] || {
    echo "ERROR: checksum mismatch: $relative" >&2
    exit 1
  }
  if ! scan_output=$(am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$destination" 2>&1); then
    echo "ERROR: media-scan broadcast failed for $destination: $scan_output" >&2
    exit 1
  fi
  printf '%s\n' "$scan_output"
  case "$scan_output" in *"Broadcast completed:"*) ;; *)
    echo "ERROR: media-scan broadcast returned no completion evidence for $destination" >&2
    exit 1
    ;;
  esac
  echo "$destination_sha  $destination"
done <"$MANIFEST"
echo "Staged $count file(s); verify MediaStore and Google Photos before removing any local copy"
