#!/system/bin/sh
set -eu

[ "$#" -eq 4 ] || {
  echo "Usage: $0 BASE_BOOT CUSTOM_IMAGE OUTPUT_NOOP OUTPUT_CUSTOM" >&2
  exit 2
}
BASE_BOOT=$1
CUSTOM_IMAGE=$2
OUTPUT_NOOP=$3
OUTPUT_CUSTOM=$4

for input in "$BASE_BOOT" "$CUSTOM_IMAGE"; do
  [ -f "$input" ] || {
    echo "ERROR: missing input: $input" >&2
    exit 1
  }
done
MAGISKBOOT=$(command -v magiskboot 2>/dev/null || true)
if [ -z "$MAGISKBOOT" ]; then
  for candidate in /data/adb/magisk/magiskboot /data/adb/magisk/busybox/magiskboot /sbin/magiskboot /debug_ramdisk/magiskboot; do
    [ -x "$candidate" ] && {
      MAGISKBOOT=$candidate
      break
    }
  done
fi
[ -n "$MAGISKBOOT" ] || {
  echo "ERROR: magiskboot not found" >&2
  exit 1
}
echo "magiskboot_path=$MAGISKBOOT"
echo "magiskboot_sha256=$(sha256sum "$MAGISKBOOT" | awk '{print $1}')"

WORK=$(mktemp -d /data/local/tmp/pixel-nas-package.XXXXXX)
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM
cp "$BASE_BOOT" "$WORK/base-boot.img"
cp "$CUSTOM_IMAGE" "$WORK/custom-Image"
cd "$WORK"

mkdir base
cd base
"$MAGISKBOOT" unpack ../base-boot.img
[ -f kernel ] || {
  echo "ERROR: MagiskBoot did not extract kernel" >&2
  exit 1
}
[ -f kernel_dtb ] || {
  echo "ERROR: expected Pixel 1 appended kernel_dtb component is absent; do not guess the layout" >&2
  exit 1
}
[ -f ramdisk.cpio ] || {
  echo "ERROR: boot ramdisk is absent" >&2
  exit 1
}
sha256sum kernel kernel_dtb ramdisk.cpio >../base-components.sha256
grep -aFq want_initramfs kernel || {
  echo "ERROR: base rooted kernel lacks want_initramfs; refusing to change its legacy-SAR state" >&2
  exit 1
}
if grep -aFq skip_initramfs kernel; then
  echo "ERROR: base rooted kernel still contains skip_initramfs; legacy-SAR state is ambiguous" >&2
  exit 1
fi
echo "base_legacy_sar=want_initramfs"

# First prove that the installed MagiskBoot can round-trip this exact rooted image.
"$MAGISKBOOT" repack ../base-boot.img ../noop-boot.img
mkdir ../verify-noop
cd ../verify-noop
"$MAGISKBOOT" unpack ../noop-boot.img
(cd ../base && sha256sum -c ../base-components.sha256)
for component in kernel kernel_dtb ramdisk.cpio; do
  [ "$(sha256sum "$component" | awk '{print $1}')" = "$(sha256sum "../base/$component" | awk '{print $1}')" ] || {
    echo "ERROR: no-op repack changed $component" >&2
    exit 1
  }
done

cd ../base
cp ../custom-Image kernel
grep -aFq skip_initramfs kernel || {
  echo "ERROR: custom uncompressed Image lacks skip_initramfs before legacy-SAR patch" >&2
  exit 1
}
"$MAGISKBOOT" hexpatch kernel \
  736B69705F696E697472616D667300 \
  77616E745F696E697472616D667300
grep -aFq want_initramfs kernel || {
  echo "ERROR: legacy-SAR patch evidence is absent" >&2
  exit 1
}
if grep -aFq skip_initramfs kernel; then
  echo "ERROR: unpatched skip_initramfs remains in replacement kernel" >&2
  exit 1
fi
patched_kernel_sha=$(sha256sum kernel | awk '{print $1}')
base_dtb_sha=$(sha256sum kernel_dtb | awk '{print $1}')
base_ramdisk_sha=$(sha256sum ramdisk.cpio | awk '{print $1}')
"$MAGISKBOOT" repack ../base-boot.img ../custom-boot.img

mkdir ../verify-custom
cd ../verify-custom
"$MAGISKBOOT" unpack ../custom-boot.img
[ "$(sha256sum kernel | awk '{print $1}')" = "$patched_kernel_sha" ] || {
  echo "ERROR: replacement kernel changed during repack" >&2
  exit 1
}
[ "$(sha256sum kernel_dtb | awk '{print $1}')" = "$base_dtb_sha" ] || {
  echo "ERROR: kernel_dtb was not preserved" >&2
  exit 1
}
[ "$(sha256sum ramdisk.cpio | awk '{print $1}')" = "$base_ramdisk_sha" ] || {
  echo "ERROR: Magisk ramdisk was not preserved" >&2
  exit 1
}
grep -aFq want_initramfs kernel || {
  echo "ERROR: repacked kernel lacks legacy-SAR patch" >&2
  exit 1
}

cp ../noop-boot.img "$OUTPUT_NOOP"
cp ../custom-boot.img "$OUTPUT_CUSTOM"
sha256sum "$OUTPUT_NOOP" "$OUTPUT_CUSTOM"
echo "Packaging complete with no-op, DTB, ramdisk, and legacy-SAR verification"
