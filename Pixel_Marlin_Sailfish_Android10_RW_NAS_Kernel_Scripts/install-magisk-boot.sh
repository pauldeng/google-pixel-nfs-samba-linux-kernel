#!/usr/bin/env bash
set -euo pipefail

# Root a supported phone by flashing a Magisk-patched boot image.
#
# This exists as a script rather than a documented command sequence because it
# writes a boot partition, and everything else in this project that does so is
# gated the same way: exact device, build, serial and slot binding, verified
# checksums, a retained rollback image, a re-check immediately before the write,
# and an image-bound confirmation token.
#
#   stage  verify the phone, record the stock image and its checksum, push it
#          for patching in the Magisk app
#   flash  resolve exactly one patched image, verify every checksum, re-check
#          Fastboot state, then write the recorded slot behind a token
#   rollback  restore the retained stock image through the same gates, for when
#          the patched image does not boot
#
# The Magisk app patches interactively on the device, so the two phases are
# separated by that manual step. Magisk requires the image be patched on the
# target phone; an image patched elsewhere is not valid here.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=source-lock.env
. "$SCRIPT_DIR/source-lock.env"
# shellcheck source=host-shell-lib.sh
. "$SCRIPT_DIR/host-shell-lib.sh"

action=${1:-}
[[ -n $action ]] || {
  echo "Usage: $0 stage|flash|rollback [options]" >&2
  echo >&2
  echo "  stage     [--workspace PATH] [--factory-zip ZIP]" >&2
  echo "  flash     [--workspace PATH] [--confirm-flash TOKEN]" >&2
  echo "  rollback  [--workspace PATH] --device NAME --slot a|b --serial ID" >&2
  echo "            --confirm-rollback TOKEN" >&2
  echo >&2
  echo "The stock boot image comes from Google's official factory archive for the" >&2
  echo "locked build. This script knows the URL and the published SHA-256 and" >&2
  echo "downloads the archive itself; you do not supply either." >&2
  echo "--factory-zip only points at a copy of that same archive you already have," >&2
  echo "so it can skip the download. It is checked against the same pinned hash." >&2
  echo >&2
  echo "rollback takes the device, slot and serial as arguments because it has to" >&2
  echo "work when the phone no longer boots far enough to answer ADB." >&2
  exit 2
}
shift
workspace="${PWD}/pixel-nas-kernel-workspace"
stock_boot=""
factory_zip=""
confirm_flash=""
confirm_rollback=""
requested_device=""
requested_slot=""
requested_serial=""
while (($#)); do
  case "$1" in
    --workspace)
      workspace=$2
      shift 2
      ;;
    --factory-zip)
      factory_zip=$2
      shift 2
      ;;
    --device)
      requested_device=$2
      shift 2
      ;;
    --slot)
      requested_slot=$2
      shift 2
      ;;
    --serial)
      requested_serial=$2
      shift 2
      ;;
    --confirm-flash)
      confirm_flash=$2
      shift 2
      ;;
    --confirm-rollback)
      confirm_rollback=$2
      shift 2
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      exit 2
      ;;
  esac
done
workspace=$(realpath -m -- "$workspace")

# Phase 0 runs before setup-host-ubuntu-20.04.sh, so this script cannot assume
# that script has installed anything. Check what it actually uses, up front,
# rather than failing a gigabyte into a download.
for required_command in adb fastboot curl unzip openssl sha256sum stat timeout; do
  command -v "$required_command" >/dev/null || {
    echo "ERROR: required command is unavailable: $required_command" >&2
    echo "On Ubuntu: sudo apt-get install --no-install-recommends \\" >&2
    echo "    adb fastboot curl unzip openssl coreutils" >&2
    echo "sudo has no TTY in an agent harness; run that in a real terminal." >&2
    exit 1
  }
done

adb_prop() { adb -s "$serial" shell getprop "$1" | tr -d '\r'; }
root_cmd() {
  local command_arg
  command_arg=$(quote_remote_command "$1")
  adb -s "$serial" shell "su -c $command_arg"
}
fastboot_value() {
  # Fastboot pads some values with a tab; strip all surrounding whitespace.
  fastboot -s "$serial" getvar "$1" 2>&1 | sed -n "s/.*$1://p" | tail -n 1 \
    | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}
capture_adb_state() {
  local devices
  mapfile -t devices < <(adb devices | awk '$2=="device" {print $1}')
  ((${#devices[@]} == 1)) || {
    echo "ERROR: exactly one authorised ADB device is required" >&2
    exit 1
  }
  serial=${devices[0]}
  [[ $serial =~ ^[A-Za-z0-9._:-]+$ ]] || {
    echo "ERROR: unsafe ADB serial value" >&2
    exit 1
  }
  device=$(adb_prop ro.product.device)
  build=$(adb_prop ro.build.id)
  version=$(adb_prop ro.build.version.release)
  slot=$(adb_prop ro.boot.slot_suffix)
  slot=${slot#_}
  [[ $device == marlin || $device == sailfish ]] || {
    echo "ERROR: unsupported device: $device" >&2
    exit 1
  }
  [[ $build == "$ANDROID_BUILD" && $version == "$ANDROID_VERSION" ]] || {
    echo "ERROR: Android build/version mismatch: $build / $version" >&2
    echo "This procedure is locked to $ANDROID_BUILD / Android $ANDROID_VERSION." >&2
    exit 1
  }
  [[ $slot == a || $slot == b ]] || {
    echo "ERROR: invalid slot: $slot" >&2
    exit 1
  }
  state_dir="$workspace/magisk-install/${device}-${build}-${serial}/slot-$slot"
}
require_fastboot_state() {
  # $1 = require Fastboot's current slot to equal the recorded slot (default 1).
  #
  # Before a flash it must match: the phone booted normally, so a disagreement
  # means the recorded state is stale and the write could land on the wrong
  # slot. Before a rollback it must NOT be required. The deployment policy is
  # explicit that the bootloader may have failed over to the untouched slot
  # after a bad boot (docs/action-plan.md, "Do not rely on Fastboot current-slot
  # after a failed boot"), and that is precisely when rollback runs. Rejecting
  # there would disable recovery in the only situation it exists for. Both paths
  # write boot_<slot> by name, so a mismatch cannot reach the safe slot; report
  # it and continue. device-deploy.sh draws the same distinction.
  local require_recorded_slot=${1:-1}
  local count=0
  until fastboot -s "$serial" devices | grep -q "^${serial}[[:space:]]"; do
    ((count++ < 60)) || {
      echo "ERROR: Fastboot device did not appear" >&2
      exit 1
    }
    sleep 1
  done
  local got
  got=$(fastboot_value product)
  [[ $got == "$device" ]] || {
    echo "ERROR: Fastboot product mismatch: got '$got', expected '$device'" >&2
    exit 1
  }
  got=$(fastboot_value current-slot)
  if ((require_recorded_slot)); then
    [[ $got == "$slot" ]] || {
      echo "ERROR: Fastboot slot mismatch: got '$got', expected '$slot'" >&2
      exit 1
    }
  elif [[ $got != "$slot" ]]; then
    echo "NOTE: Fastboot reports current slot '$got', but this targets slot '$slot'."
    echo "That is expected after a failed boot; the bootloader fell back to the"
    echo "untouched slot. Continuing: the write names boot_$slot explicitly, so"
    echo "the other slot is not affected."
  fi
  got=$(fastboot_value unlocked)
  [[ $got == yes ]] || {
    echo "ERROR: bootloader is not unlocked (unlocked='$got')" >&2
    exit 1
  }
}
# Android boot image header v0: magic at 0, header_version at 40, os_version at
# 44, cmdline at 64 for 512 bytes. os_version packs
# (major<<25)|(minor<<18)|(patch<<11)|((year-2000)<<4)|month.
#
# 335544634 is Android 10.0.0 with security patch 2019-10, which is what
# QP1A.191005.007.A3 ships. Verified by decoding the boot partition dumped from
# a sailfish running that build. Pinning it here rather than in source-lock.env
# keeps that file about the kernel build; this constant is about boot images.
readonly EXPECTED_OS_VERSION=335544634

boot_image_u32() { od -An -tu4 -j"$2" -N4 "$1" | tr -d ' '; }
describe_os_version() {
  printf 'android %d.%d.%d patch %d-%02d' \
    $(((10#$1 >> 25) & 0x7f)) $(((10#$1 >> 18) & 0x7f)) $(((10#$1 >> 11) & 0x7f)) \
    $((2000 + ((10#$1 >> 4) & 0x7f))) $((10#$1 & 0xf))
}
validate_boot_image() {
  # Establish that a file really is a boot image for THIS device and build.
  # Creating a checksum and then verifying it proves only that the file has not
  # changed since; it says nothing about where the file came from. A boot image
  # from a different Pixel or a different Android 10 build would otherwise be
  # accepted, and so would a random file with the right name.
  local path=$1 label=$2 magic header_version os_version cmdline
  [[ -f $path ]] || {
    echo "ERROR: $label is not a file: $path" >&2
    exit 1
  }
  magic=$(dd if="$path" bs=8 count=1 2>/dev/null | tr -d '\0')
  [[ $magic == 'ANDROID!' ]] || {
    echo "ERROR: $label is not an Android boot image (magic '$magic')" >&2
    exit 1
  }
  header_version=$(boot_image_u32 "$path" 40)
  [[ $header_version == 0 ]] || {
    echo "ERROR: $label has boot header version $header_version; this device uses 0" >&2
    exit 1
  }
  os_version=$(boot_image_u32 "$path" 44)
  [[ $os_version == "$EXPECTED_OS_VERSION" ]] || {
    printf 'ERROR: %s targets %s, but this project requires %s\n' \
      "$label" "$(describe_os_version "$os_version")" "$(describe_os_version "$EXPECTED_OS_VERSION")" >&2
    exit 1
  }
  cmdline=$(dd if="$path" bs=1 skip=64 count=512 2>/dev/null | tr -d '\0')
  [[ $cmdline == *"androidboot.hardware=$device"* ]] || {
    echo "ERROR: $label is not built for $device; its cmdline names a different board" >&2
    exit 1
  }
  # A correct header is not enough. Without these, a truncated or crafted
  # header-only file passes every check above and reaches Fastboot.
  local kernel_size ramdisk_size page_size actual_size required_size pages
  kernel_size=$(boot_image_u32 "$path" 8)
  ramdisk_size=$(boot_image_u32 "$path" 16)
  page_size=$(boot_image_u32 "$path" 36)
  ((kernel_size > 0)) || {
    echo "ERROR: $label declares a zero-length kernel" >&2
    exit 1
  }
  ((ramdisk_size > 0)) || {
    echo "ERROR: $label declares a zero-length ramdisk" >&2
    exit 1
  }
  case "$page_size" in
    2048 | 4096 | 8192 | 16384) ;;
    *)
      echo "ERROR: $label declares an implausible page size: $page_size" >&2
      exit 1
      ;;
  esac
  # Header page, then each component rounded up to a whole number of pages.
  pages=$((1 + (kernel_size + page_size - 1) / page_size + (ramdisk_size + page_size - 1) / page_size))
  required_size=$((pages * page_size))
  actual_size=$(stat -c %s "$path")
  ((actual_size >= required_size)) || {
    echo "ERROR: $label is truncated: $actual_size bytes, but its header describes at least $required_size" >&2
    exit 1
  }
  printf '%s: valid boot image for %s, %s (kernel %s B, ramdisk %s B)\n' \
    "$label" "$device" "$(describe_os_version "$os_version")" "$kernel_size" "$ramdisk_size"
}
check_fits_partition() {
  local path=$1 label=$2 raw size
  raw=$(fastboot_value "partition-size:boot_$slot")
  [[ $raw =~ ^0[xX][0-9a-fA-F]+$ || $raw =~ ^[0-9]+$ ]] || {
    echo "ERROR: invalid Fastboot boot partition size: $raw" >&2
    exit 1
  }
  size=$(stat -c %s "$path")
  ((size <= $((raw)))) || {
    echo "ERROR: $label exceeds boot_$slot ($size > $((raw)))" >&2
    exit 1
  }
}
list_remote_patched() {
  # A glob matching nothing must not look like a transport failure. Remote `ls`
  # exits 1 when there are no matches, which under pipefail aborted staging on a
  # clean phone. Loop instead and end with `true`, so only genuine ADB errors
  # produce a non-zero status.
  # shellcheck disable=SC2016 # $f is expanded by the device shell, not here.
  adb -s "$serial" shell \
    'for f in /sdcard/Download/magisk_patched-*.img; do [ -e "$f" ] && echo "$f"; done; true' \
    | tr -d '\r' | sed '/^$/d'
}
resolve_patched_image() {
  # `adb pull` does not expand remote globs, and Magisk gives each patched image
  # a random suffix, so stale images from earlier attempts accumulate. Resolve
  # on the device and require exactly one match; anything else must stop.
  # Freshness evidence must exist. Treating a missing record as "everything is
  # new" would make every stale image eligible again.
  [[ -r $state_dir/pre-existing-patched.txt ]] || {
    echo "ERROR: no staging record at $state_dir/pre-existing-patched.txt" >&2
    echo "Run 'stage' first; without it a stale patched image cannot be told from a new one." >&2
    exit 1
  }
  local -a found
  mapfile -t found < <(list_remote_patched)
  # Only consider images that did not exist when we staged. Deleting every
  # magisk_patched-*.img would remove files this workflow never created, and the
  # project rule is to touch only uniquely identified disposable paths.
  local -a fresh=()
  local candidate
  for candidate in "${found[@]}"; do
    grep -Fqx -- "$candidate" "$state_dir/pre-existing-patched.txt" || fresh+=("$candidate")
  done
  ((${#fresh[@]} != 0)) || {
    echo "ERROR: no newly patched image found in /sdcard/Download." >&2
    if ((${#found[@]} != 0)); then
      echo "These were already present before staging and are ignored:" >&2
      printf '  %s\n' "${found[@]}" >&2
    fi
    echo "Patch the staged boot image in the Magisk app, then rerun." >&2
    exit 1
  }
  ((${#fresh[@]} == 1)) || {
    echo "ERROR: found ${#fresh[@]} newly patched images; expected exactly one:" >&2
    printf '  %s\n' "${fresh[@]}" >&2
    echo "Remove the ones you do not want on the phone yourself, then rerun." >&2
    exit 1
  }
  printf '%s\n' "${fresh[0]}"
}

# Google's official factory archives for ANDROID_BUILD, pinned here for the
# same reason as EXPECTED_OS_VERSION: they describe boot images, not the kernel
# source that source-lock.env locks.
#
# Each SHA-256 is the value Google publishes beside the archive at
# https://developers.google.com/android/images. Google names every archive
# after the first eight hex digits of that same hash, so the filename restates
# the checksum; verify_factory_pin cross-checks the two and the build ID, which
# turns a mistyped constant into a refusal instead of a bad download.
readonly FACTORY_BASE_URL="https://dl.google.com/dl/android/aosp"
factory_archive() {
  case "$1" in
    marlin) printf 'marlin-qp1a.191005.007.a3-factory-bef66533.zip\n' ;;
    sailfish) printf 'sailfish-qp1a.191005.007.a3-factory-d4552659.zip\n' ;;
    *) return 1 ;;
  esac
}
factory_sha256() {
  case "$1" in
    marlin) printf 'bef6653301371b66bd7fca968cf52013c0bf6862f0c7a70a275b0f0d45ab3888\n' ;;
    sailfish) printf 'd455265945bb936a653730031af7d7a4aba70dc0c775024666a53491c9833b61\n' ;;
    *) return 1 ;;
  esac
}
# Content-Length as served by FACTORY_BASE_URL. The checksum is the real
# authority; this exists so the common failures — a captive portal returning an
# HTML login page, a proxy truncating the transfer — are reported as what they
# are instead of as a checksum mismatch after hashing a gigabyte of nonsense.
factory_size() {
  case "$1" in
    marlin) printf '1395394747\n' ;;
    sailfish) printf '1386103670\n' ;;
    *) return 1 ;;
  esac
}
verify_factory_pin() {
  local dev=$1 name sha lower_build
  name=$(factory_archive "$dev") || {
    echo "ERROR: no official factory archive is pinned for device '$dev'" >&2
    exit 1
  }
  sha=$(factory_sha256 "$dev") || {
    echo "ERROR: no published checksum is pinned for device '$dev'" >&2
    exit 1
  }
  [[ $sha =~ ^[0-9a-f]{64}$ ]] || {
    echo "ERROR: the pinned checksum for $dev is not a SHA-256" >&2
    exit 1
  }
  [[ $name == "$dev-"*"-factory-${sha:0:8}.zip" ]] || {
    echo "ERROR: the pinned archive name and checksum for $dev disagree" >&2
    echo "  archive:  $name" >&2
    echo "  checksum: $sha (Google names the archive after its first 8 digits)" >&2
    exit 1
  }
  lower_build=$(printf '%s' "$ANDROID_BUILD" | tr '[:upper:]' '[:lower:]')
  [[ $name == "$dev-$lower_build-factory-"* ]] || {
    echo "ERROR: the pinned archive for $dev is not build $ANDROID_BUILD: $name" >&2
    exit 1
  }
}
require_free_space() {
  local dir=$1 need_mib=$2 free_mib
  free_mib=$(df -Pm "$dir" | awk 'NR==2 {print $4}')
  [[ $free_mib =~ ^[0-9]+$ ]] || {
    echo "ERROR: could not read free space for $dir" >&2
    exit 1
  }
  ((free_mib >= need_mib)) || {
    echo "ERROR: not enough free space in $dir" >&2
    echo "  need:      $need_mib MiB" >&2
    echo "  available: $free_mib MiB" >&2
    exit 1
  }
}
verify_archive_size() {
  local path=$1 want=$2 actual
  actual=$(stat -c %s -- "$path")
  ((actual == want)) || {
    echo "ERROR: the factory archive is not the size Google serves" >&2
    echo "  expected: $want bytes" >&2
    echo "  actual:   $actual bytes" >&2
    echo "A short file usually means the download was interrupted or a proxy" >&2
    echo "returned an error page. Delete it and rerun:" >&2
    echo "  rm -f -- $path" >&2
    exit 1
  }
}
verify_archive_checksum() {
  local path=$1 want=$2 actual
  actual=$(sha256sum "$path" | awk '{print $1}')
  [[ $actual == "$want" ]] || {
    echo "ERROR: the factory archive does not match the checksum Google publishes" >&2
    echo "  expected: $want" >&2
    echo "  actual:   $actual" >&2
    echo "Delete it and rerun so the download starts clean:" >&2
    echo "  rm -f -- $path" >&2
    exit 1
  }
}
download_factory_archive() {
  # $1 = destination path, $2 = archive filename
  local dest=$1 name=$2 url="$FACTORY_BASE_URL/$2"
  command -v curl >/dev/null || {
    echo "ERROR: curl is required to download the factory archive" >&2
    exit 1
  }
  echo "Downloading Google's official factory archive for $device."
  echo "  $url"
  echo "This is about 1.4 GB. Expect several minutes. Do not touch the phone."
  # -C - resumes a part file, so an interrupted download is not restarted from
  # zero. The checksum is verified afterwards either way.
  curl -fL --retry 3 --retry-delay 5 -C - --progress-bar -o "$dest.part" "$url" || {
    echo "ERROR: the download failed. Rerun to resume it." >&2
    exit 1
  }
  mv -- "$dest.part" "$dest"
  echo "Downloaded: $dest"
}
# The Magisk app itself. Step 3 of the runbook factory-resets the phone, which
# removes every app, so nothing can be assumed present.
#
# Pinned to 29.0 because that is the version actually flashed and proven on this
# hardware, not because newer releases are incompatible. Checked against v30.7
# (2026-02-23): minSdk is 23 in both, so Android 10 is still supported; the
# legacy-SAR path in native/src/init/ is unchanged; and the
# skip_initramfs -> want_initramfs hexpatch this project depends on is
# byte-identical in scripts/boot_patch.sh. So 30.7 would very likely work.
# It is not pinned here because nothing in it is needed by a LAN-only appliance
# that never updates, and because v30.7 changes MagiskSU to stop dropping
# capabilities by default, which is adjacent to the CAP_NET_RAW behaviour this
# project had to work around. Moving the pin would turn a hardware-proven
# element into an assumed one; it is a four-constant change if you want it.
#
# Unlike Google, GitHub publishes no checksum beside a release asset, so
# MAGISK_APK_SHA256 was recorded from the official asset rather than quoted from
# an independent attestation: it detects a corrupted or substituted download,
# but it is not a third-party guarantee. MAGISK_APK_CERT_SHA256 is the stronger
# check. It is the fingerprint of the certificate the APK is signed with
# (C=TW, L=Taipei, CN=John Wu), which is the same key across Magisk releases, so
# it does not depend on trusting this file's own hash.
readonly MAGISK_VERSION="29.0"
readonly MAGISK_PACKAGE="com.topjohnwu.magisk"
readonly MAGISK_APK_URL="https://github.com/topjohnwu/Magisk/releases/download/v29.0/Magisk-v29.0.apk"
readonly MAGISK_APK_SHA256="99d40df1a68a05a5e78452a9cd4f2d753434d7622baeeb44ea14ae8238c1a9ca"
readonly MAGISK_APK_SIZE=11801932
readonly MAGISK_APK_CERT_SHA256="B4:CB:83:B4:DA:D9:9F:99:7D:BE:87:2F:01:3A:A1:6C:14:EE:C4:1D:16:70:21:F3:71:F7:E1:33:0F:27:3E:E6"

installed_magisk_version() {
  adb -s "$serial" shell dumpsys package "$MAGISK_PACKAGE" 2>/dev/null \
    | sed -n 's/^[[:space:]]*versionName=//p' | head -1 | tr -d '\r'
}
verify_apk_signature() {
  # Verify the v1 (JAR) signature chain and echo the signer certificate
  # fingerprint. Any failure yields an empty string, which cannot match the
  # pinned value.
  #
  # What this establishes: the private key belonging to the printed certificate
  # produced the PKCS#7 signature over META-INF/CERT.SF, and CERT.SF carries a
  # digest committing to META-INF/MANIFEST.MF, which lists a digest for every
  # entry in the archive.
  #
  # What it does NOT establish, stated plainly because an earlier version of
  # this script overclaimed it: reading a certificate out of CERT.RSA and
  # fingerprinting it proves only that the blob is present, so that alone was
  # not authentication at all. Even with the signature check below, this does
  # not re-hash the ~1000 entries, and it does not touch the v2/v3 APK Signing
  # Block -- which is what Android itself verifies, since this APK declares
  # X-Android-APK-Signed: 2. Complete verification is `apksigner verify
  # --print-certs`; it needs a JRE, and Phase 0 runs before host setup, so that
  # is left as an optional manual cross-check rather than a dependency here.
  #
  # The pinned whole-file SHA-256 remains the primary protection for this exact
  # APK. This chain adds that those bytes carry a signature made by the expected
  # publisher's key, rather than merely embedding their certificate.
  local apk=$1 dir fp="" want="" got="" algorithm digest_flag
  dir=$(mktemp -d "$workspace/factory/apksig-XXXXXX") || return 0
  if unzip -q -o -j "$apk" 'META-INF/CERT.RSA' 'META-INF/CERT.SF' \
    'META-INF/MANIFEST.MF' -d "$dir" 2>/dev/null \
    && openssl smime -verify -inform DER -in "$dir/CERT.RSA" \
      -content "$dir/CERT.SF" -noverify -out /dev/null 2>/dev/null; then
    # Which manifest digest the signer used varies; Magisk 29.0 uses SHA-1 here
    # even though the archive is SHA-256 throughout. Follow what CERT.SF says.
    for algorithm in SHA-256 SHA1; do
      want=$(sed -n "s/^$algorithm-Digest-Manifest: //p" "$dir/CERT.SF" \
        | tr -d '\r' | head -1)
      [[ -n $want ]] || continue
      case "$algorithm" in
        SHA-256) digest_flag=-sha256 ;;
        *) digest_flag=-sha1 ;;
      esac
      got=$(openssl dgst "$digest_flag" -binary "$dir/MANIFEST.MF" 2>/dev/null \
        | openssl base64 -A)
      break
    done
    if [[ -n $want && $want == "$got" ]] \
      && openssl pkcs7 -inform DER -in "$dir/CERT.RSA" -print_certs \
        -out "$dir/cert.pem" 2>/dev/null; then
      fp=$(openssl x509 -in "$dir/cert.pem" -noout -fingerprint -sha256 2>/dev/null \
        | sed 's/^.*Fingerprint=//')
    fi
  fi
  rm -rf -- "$dir"
  printf '%s\n' "$fp"
}
ensure_magisk_app() {
  # Always verify and reinstall, even when the reported version already matches.
  # A package name and a versionName are self-declared strings: any APK can
  # claim both, so they establish nothing about who signed the app that will
  # perform the boot patch. Returning early on a version match would let an
  # independently sideloaded Magisk skip the certificate check entirely.
  #
  # Reinstalling closes that hole without needing to pull the installed APK
  # back: Android refuses to replace a package with one signed by a different
  # key, so `adb install -r` succeeding after the pinned APK has passed its own
  # certificate check proves the app on the phone shares that signer.
  local got apk cache_dir fingerprint
  got=$(installed_magisk_version)
  if [[ $got == "$MAGISK_VERSION" ]]; then
    echo "Magisk app $MAGISK_VERSION is already installed; reinstalling to confirm its signer."
  elif [[ -n $got ]]; then
    echo "Magisk app $got is installed; this procedure needs $MAGISK_VERSION."
  fi
  cache_dir="$workspace/factory"
  mkdir -p "$cache_dir"
  apk="$cache_dir/Magisk-v$MAGISK_VERSION.apk"
  if [[ ! -f $apk ]]; then
    echo "Downloading the official Magisk $MAGISK_VERSION app."
    echo "  $MAGISK_APK_URL"
    curl -fL --retry 3 --retry-delay 5 -C - --progress-bar -o "$apk.part" "$MAGISK_APK_URL" || {
      echo "ERROR: the Magisk app download failed. Rerun to resume it." >&2
      exit 1
    }
    mv -- "$apk.part" "$apk"
  fi
  verify_archive_size "$apk" "$MAGISK_APK_SIZE"
  verify_archive_checksum "$apk" "$MAGISK_APK_SHA256"
  fingerprint=$(verify_apk_signature "$apk")
  [[ $fingerprint == "$MAGISK_APK_CERT_SHA256" ]] || {
    echo "ERROR: the Magisk app failed signature verification" >&2
    echo "  expected: $MAGISK_APK_CERT_SHA256" >&2
    echo "  actual:   ${fingerprint:-<none readable>}" >&2
    echo "Delete it and rerun: rm -f -- $apk" >&2
    exit 1
  }
  echo "Magisk app matches its pinned checksum and signing certificate."
  adb -s "$serial" install -r "$apk" || {
    echo "ERROR: installing the Magisk app failed" >&2
    echo "If this reports a signature or UPDATE_INCOMPATIBLE failure, the phone" >&2
    echo "already has a Magisk app signed by a different key. That app is not" >&2
    echo "the one this procedure verified, and it must not be used to patch a" >&2
    echo "boot image. Have the user uninstall it, then rerun:" >&2
    echo "  adb -s $serial uninstall $MAGISK_PACKAGE" >&2
    exit 1
  }
  got=$(installed_magisk_version)
  [[ $got == "$MAGISK_VERSION" ]] || {
    echo "ERROR: expected Magisk app $MAGISK_VERSION on the phone, found '${got:-none}'" >&2
    exit 1
  }
  echo "Installed Magisk app $MAGISK_VERSION ($MAGISK_PACKAGE)."
}

wait_for_root() {
  # The very first su request raises a Grant dialog on the phone, so this is the
  # one point in the whole procedure where the user must touch the device. An
  # unbounded `su -c id` waits for that press forever, which contradicts the
  # "do not touch the phone while a script runs" rule and defeats the bounded
  # waits above it. Each attempt is capped so a pending dialog cannot hang the
  # run, and the instruction is printed before the first attempt, not after it.
  local count=0 out command_arg
  command_arg=$(quote_remote_command id)
  echo
  echo "ACTION REQUIRED ON THE PHONE, and only this:"
  echo "  1. Unlock the screen."
  echo "  2. When Magisk asks to grant Superuser access to 'Shell', press Grant."
  echo "Do not press anything else. Do not touch the bootloader."
  echo
  until out=$(timeout 15 adb -s "$serial" shell "su -c $command_arg" 2>/dev/null) \
    && [[ $out == *'uid=0(root)'* ]]; do
    ((count++ < 12)) || {
      echo "ERROR: root was not granted within about three minutes of the flash" >&2
      echo "Open the Magisk app and check Superuser, then rerun this command." >&2
      exit 1
    }
    sleep 1
  done
  echo "Root granted."
}

rollback_token() {
  # $1 = path to the retained stock image
  local sha
  sha=$(sha256sum "$1" | awk '{print $1}')
  printf 'ROLLBACK:%s:%s:%s\n' "$device" "$slot" "${sha:0:12}"
}
print_rollback_command() {
  # The emergency path must go through the same gates as every other write in
  # this project: re-verified checksum, re-checked Fastboot product/slot/unlock
  # state, and its own token. A bare `fastboot flash` bypasses all three, so it
  # is kept only as a clearly marked last resort for when this script is gone.
  local token
  token=$(rollback_token "$state_dir/stock-boot.img")
  printf '  %q rollback --workspace %q \\\n' "$SCRIPT_DIR/install-magisk-boot.sh" "$workspace"
  printf '      --device %q --slot %q --serial %q \\\n' "$device" "$slot" "$serial"
  printf '      --confirm-rollback %q\n' "$token"
  echo
  echo "LAST RESORT ONLY, if that script is unavailable. This bypasses every"
  echo "check the line above performs:"
  printf '  fastboot -s %q flash %q %q\n' "$serial" "boot_$slot" "$state_dir/stock-boot.img"
}

extract_dir=""
remove_extract_dir() { [[ -z $extract_dir ]] || rm -rf -- "$extract_dir"; }
extract_boot_from_archive() {
  # $1 = verified factory archive, $2 = directory to extract into.
  # Sets the global stock_boot. Kept separate from the download so the archive
  # layout can be exercised against a fixture.
  local archive=$1 dest=$2 inner
  # The glob must be able to cross the leading directory component: members are
  # named <device>-<build>/image-..., so an 'image-*.zip' pattern matches
  # nothing at all.
  inner=$(unzip -Z1 "$archive" '*image-*.zip' 2>/dev/null | head -1)
  [[ -n $inner ]] || {
    echo "ERROR: no image-*.zip inside the factory archive" >&2
    exit 1
  }
  unzip -q -o -j "$archive" "$inner" -d "$dest"
  unzip -q -o -j "$dest/$(basename "$inner")" boot.img -d "$dest"
  [[ -f $dest/boot.img ]] || {
    echo "ERROR: no boot.img inside $inner" >&2
    exit 1
  }
  rm -f -- "$dest/$(basename "$inner")"
  stock_boot="$dest/boot.img"
  echo "Extracted boot.img from $inner"
}
obtain_stock_boot() {
  # Sets the global stock_boot to a boot.img extracted from Google's official
  # factory archive for this device. Progress goes to stdout, so the path is
  # returned in a global rather than by echoing it.
  local dev=$1 name sha size archive cache_dir inner
  verify_factory_pin "$dev"
  name=$(factory_archive "$dev")
  sha=$(factory_sha256 "$dev")
  size=$(factory_size "$dev")
  cache_dir="$workspace/factory"
  mkdir -p "$cache_dir"
  if [[ -n $factory_zip ]]; then
    [[ -f $factory_zip ]] || {
      echo "ERROR: factory archive not found: $factory_zip" >&2
      exit 1
    }
    archive=$factory_zip
    echo "Using the local copy you supplied: $archive"
  elif [[ -f $cache_dir/$name ]]; then
    archive="$cache_dir/$name"
    echo "Using the archive already downloaded: $archive"
  else
    # The download lands here, so the archive itself must fit.
    require_free_space "$cache_dir" 1400
    download_factory_archive "$cache_dir/$name" "$name"
    archive="$cache_dir/$name"
  fi
  verify_archive_size "$archive" "$size"
  verify_archive_checksum "$archive" "$sha"
  echo "Factory archive matches the checksum Google publishes for $name."
  # The archive nests <device>-<build>/image-<device>-<build>.zip, which holds
  # boot.img. The inner archive is stored uncompressed and is about 1.3 GB, so
  # extract inside the workspace rather than /tmp, where a tmpfs is routinely
  # smaller than that. It is removed again as soon as boot.img is out.
  require_free_space "$cache_dir" 1350
  extract_dir=$(mktemp -d "$cache_dir/extract-XXXXXX")
  trap remove_extract_dir EXIT
  extract_boot_from_archive "$archive" "$extract_dir"
}

case "$action" in
  stage)
    capture_adb_state
    mkdir -p "$state_dir"
    # Before the factory download, not after: the app is 12 MB and the archive
    # is 1.4 GB, so a phone that will not accept the app should fail in seconds
    # rather than after a long transfer. Nothing later works without it — the
    # patching step happens inside this app, and step 3 of Phase 0 factory-reset
    # the phone, so it is not there any more.
    ensure_magisk_app
    # Provenance is built in, not supplied by the operator. Structure, device
    # and build can all be verified from the header, but none of that shows the
    # image came from Google. A checksum only means something when it is
    # compared against the artefact it actually describes, and the only hash
    # Google publishes is for the factory archive. So this script takes exactly
    # one source: that archive, at a pinned official URL, verified against the
    # pinned published hash. There is deliberately no option to hand it a bare
    # boot.img, because no published checksum can authenticate one.
    obtain_stock_boot "$device"
    validate_boot_image "$stock_boot" "stock boot image"
    install -m 0644 "$stock_boot" "$state_dir/stock-boot.img"
    (cd "$state_dir" && sha256sum stock-boot.img >stock-boot.img.sha256)
    (cd "$state_dir" && sha256sum -c stock-boot.img.sha256)
    printf 'device=%q\nbuild=%q\nserial=%q\nslot=%q\nstaged_utc=%q\n' \
      "$device" "$build" "$serial" "$slot" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >"$state_dir/magisk-state.env"
    adb -s "$serial" shell 'mkdir -p /sdcard/Download'
    # Record what is already there rather than deleting it. `flash` then accepts
    # only a filename that appears afterwards.
    list_remote_patched >"$state_dir/pre-existing-patched.txt"
    adb -s "$serial" push "$state_dir/stock-boot.img" /sdcard/Download/boot.img
    echo
    echo "Staged: $state_dir"
    pre_count=$(wc -l <"$state_dir/pre-existing-patched.txt")
    printf 'Pre-existing patched images recorded and ignored: %s (none deleted)\n' "$pre_count"
    echo
    echo "On the phone: Magisk app -> Install -> Select and Patch a File -> /sdcard/Download/boot.img"
    printf 'Then: %q flash --workspace %q\n' "$0" "$workspace"
    ;;

  flash)
    capture_adb_state
    [[ -f $state_dir/stock-boot.img && -f $state_dir/stock-boot.img.sha256 ]] || {
      echo "ERROR: run 'stage' first; no verified stock image for this device/slot" >&2
      exit 1
    }
    # Verify rather than merely record: an unverified rollback is no rollback.
    (cd "$state_dir" && sha256sum -c stock-boot.img.sha256) || {
      echo "ERROR: the stock boot image failed verification; refusing to flash" >&2
      exit 1
    }
    remote_patched=$(resolve_patched_image)
    [[ -n $remote_patched ]] || {
      echo "ERROR: could not resolve a patched image" >&2
      exit 1
    }
    echo "Patched image on device: $remote_patched"
    adb -s "$serial" pull "$remote_patched" "$state_dir/magisk-patched.img"
    (cd "$state_dir" && sha256sum magisk-patched.img >magisk-patched.img.sha256)
    (cd "$state_dir" && sha256sum -c magisk-patched.img.sha256)
    validate_boot_image "$state_dir/magisk-patched.img" "patched boot image"
    patched_sha=$(sha256sum "$state_dir/magisk-patched.img" | awk '{print $1}')
    stock_sha=$(sha256sum "$state_dir/stock-boot.img" | awk '{print $1}')
    [[ $patched_sha != "$stock_sha" ]] || {
      echo "ERROR: the patched image is identical to the stock image; Magisk did not patch it" >&2
      exit 1
    }
    # Magisk works by rewriting the ramdisk, so an identical ramdisk size means
    # whatever changed, it was not a Magisk patch. magiskboot would let us prove
    # this properly, but it is not on the phone until Magisk is installed.
    stock_ramdisk=$(boot_image_u32 "$state_dir/stock-boot.img" 16)
    patched_ramdisk=$(boot_image_u32 "$state_dir/magisk-patched.img" 16)
    [[ $stock_ramdisk != "$patched_ramdisk" ]] || {
      echo "ERROR: the patched image has the same ramdisk size as stock ($stock_ramdisk B)." >&2
      echo "Magisk rewrites the ramdisk, so this does not look like a patched image." >&2
      exit 1
    }
    printf 'Ramdisk changed by patching: %s B -> %s B\n' "$stock_ramdisk" "$patched_ramdisk"

    expected="FLASHBOOT:$device:$slot:${patched_sha:0:12}"
    [[ $confirm_flash == "$expected" ]] || {
      echo "ERROR: this writes boot_$slot on $device ($serial) and is not reversible" >&2
      echo "without the recorded stock image. To authorise, rerun with:" >&2
      echo "  --confirm-flash '$expected'" >&2
      echo >&2
      echo "Record this recovery command somewhere off this host first:" >&2
      print_rollback_command >&2
      exit 1
    }

    adb -s "$serial" reboot bootloader
    require_fastboot_state
    check_fits_partition "$state_dir/magisk-patched.img" "patched image"
    # A rollback image that cannot be written back is not a rollback.
    check_fits_partition "$state_dir/stock-boot.img" "stock rollback image"

    # shellcheck disable=SC2329 # Invoked by trap.
    print_recovery() {
      echo >&2
      echo "RECOVERY: enter Fastboot with the hardware key combination, then run:" >&2
      print_rollback_command >&2
    }
    # shellcheck disable=SC2329 # Invoked by trap.
    on_exit() {
      local st=$?
      ((st == 0)) || print_recovery
    }
    trap on_exit EXIT

    fastboot -s "$serial" flash "boot_$slot" "$state_dir/magisk-patched.img"
    fastboot -s "$serial" reboot
    # `adb wait-for-device` blocks forever. If the patched image never brings ADB
    # up, an unbounded wait means the recovery command below is never printed,
    # which is exactly when the operator needs it.
    count=0
    until [[ $(adb -s "$serial" get-state 2>/dev/null) == device ]]; do
      ((count++ < 180)) || {
        echo "ERROR: the phone did not return to ADB within 180 seconds after the flash" >&2
        exit 1
      }
      sleep 1
    done
    count=0
    until [[ $(adb_prop sys.boot_completed) == 1 ]]; do
      ((count++ < 180)) || {
        echo "ERROR: Android did not complete boot after the flash" >&2
        exit 1
      }
      sleep 1
    done
    wait_for_root
    trap - EXIT
    echo "Magisk root verified on $device ($serial), slot $slot"
    echo "Stock rollback image retained: $state_dir/stock-boot.img"
    ;;

  rollback)
    # Deliberately does not call capture_adb_state: rollback is needed exactly
    # when the patched image will not boot far enough to answer ADB, so device,
    # slot and serial are supplied rather than read from the phone.
    [[ $requested_device == marlin || $requested_device == sailfish ]] || {
      echo "ERROR: rollback requires --device marlin|sailfish" >&2
      exit 1
    }
    [[ $requested_slot == a || $requested_slot == b ]] || {
      echo "ERROR: rollback requires --slot a|b" >&2
      exit 1
    }
    [[ $requested_serial =~ ^[A-Za-z0-9._:-]+$ ]] || {
      echo "ERROR: rollback requires --serial with a safe value" >&2
      exit 1
    }
    device=$requested_device
    slot=$requested_slot
    serial=$requested_serial
    build=$ANDROID_BUILD
    state_dir="$workspace/magisk-install/${device}-${build}-${serial}/slot-$slot"
    [[ -f $state_dir/stock-boot.img && -f $state_dir/stock-boot.img.sha256 ]] || {
      echo "ERROR: no retained stock image for $device ($serial) slot $slot" >&2
      echo "Looked in: $state_dir" >&2
      exit 1
    }
    (cd "$state_dir" && sha256sum -c stock-boot.img.sha256)
    expected=$(rollback_token "$state_dir/stock-boot.img")
    [[ $confirm_rollback == "$expected" ]] || {
      echo "ERROR: this writes boot_$slot on $device ($serial). To authorise:" >&2
      echo "  --confirm-rollback '$expected'" >&2
      exit 1
    }
    validate_boot_image "$state_dir/stock-boot.img" "stock rollback image"
    require_fastboot_state 0
    check_fits_partition "$state_dir/stock-boot.img" "stock rollback image"
    fastboot -s "$serial" flash "boot_$slot" "$state_dir/stock-boot.img"
    fastboot -s "$serial" reboot
    echo "Stock boot image restored to boot_$slot on $device ($serial)."
    echo "The phone reboots itself. Do not press anything."
    ;;
  *)
    echo "ERROR: unknown action: $action" >&2
    exit 2
    ;;
esac
