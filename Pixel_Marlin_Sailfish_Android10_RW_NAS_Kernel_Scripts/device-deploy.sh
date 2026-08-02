#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=source-lock.env
. "$SCRIPT_DIR/source-lock.env"
# shellcheck source=host-shell-lib.sh
. "$SCRIPT_DIR/host-shell-lib.sh"

action=${1:-}
[[ -n $action ]] || {
  echo "Usage: $0 prepare|test|flash|rollback [options]" >&2
  exit 2
}
shift
workspace="${PWD}/pixel-nas-kernel-workspace"
expected_device=auto
requested_slot=""
requested_serial=""
confirm_flash=""
confirm_rollback=""
confirm_untested=""
data_backup_confirmed=0
while (($#)); do
  case "$1" in
    --workspace)
      workspace=$2
      shift 2
      ;;
    --device)
      expected_device=$2
      shift 2
      ;;
    --slot)
      requested_slot=${2#_}
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
    --confirm-untested)
      confirm_untested=$2
      shift 2
      ;;
    --data-backup-confirmed)
      data_backup_confirmed=1
      shift
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      exit 2
      ;;
  esac
done
workspace=$(realpath -m -- "$workspace")
artifacts="$workspace/artifacts/common"

adb_serial() {
  local devices
  mapfile -t devices < <(adb devices | awk '$2=="device" {print $1}')
  ((${#devices[@]} == 1)) || {
    echo "ERROR: exactly one authorised ADB device is required" >&2
    exit 1
  }
  printf '%s\n' "${devices[0]}"
}
adb_prop() { adb -s "$serial" shell getprop "$1" | tr -d '\r'; }
root_cmd() {
  local command_arg
  command_arg=$(quote_remote_command "$1")
  adb -s "$serial" shell "su -c $command_arg"
}
wait_adb() {
  adb -s "$serial" wait-for-device
  local count=0
  until [[ $(adb_prop sys.boot_completed) == 1 ]]; do
    ((count++ < 180)) || {
      echo "ERROR: Android did not complete boot" >&2
      exit 1
    }
    sleep 1
  done
}
capture_adb_state() {
  serial=$(adb_serial)
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
  [[ $expected_device == auto || $expected_device == "$device" ]] || {
    echo "ERROR: device mismatch" >&2
    exit 1
  }
  [[ $build == "$ANDROID_BUILD" && $version == "$ANDROID_VERSION" ]] || {
    echo "ERROR: Android build/version mismatch" >&2
    exit 1
  }
  [[ $slot == a || $slot == b ]] || {
    echo "ERROR: invalid slot: $slot" >&2
    exit 1
  }
  [[ $(root_cmd id) == *'uid=0(root)'* ]] || {
    echo "ERROR: Magisk root is required" >&2
    exit 1
  }
  state_dir="$workspace/deploy/${device}-${build}-${serial}/slot-$slot"
}
wait_fastboot() {
  local count=0
  until fastboot -s "$serial" devices | grep -q "^${serial}[[:space:]]"; do
    ((count++ < 60)) || {
      echo "ERROR: Fastboot device did not appear" >&2
      exit 1
    }
    sleep 1
  done
}
fastboot_value() {
  # Fastboot pads some values with a tab, e.g. "partition-size:boot_b:\t 0x2000000",
  # so strip all surrounding whitespace rather than spaces alone.
  fastboot -s "$serial" getvar "$1" 2>&1 | sed -n "s/.*$1://p" | tail -n 1 \
    | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}
check_fastboot_state() {
  local require_recorded_slot=${1:-1}
  wait_fastboot
  [[ $(fastboot_value product) == "$device" ]] || {
    echo "ERROR: Fastboot product mismatch" >&2
    exit 1
  }
  if ((require_recorded_slot)); then
    [[ $(fastboot_value current-slot) == "$slot" ]] || {
      echo "ERROR: Fastboot slot mismatch" >&2
      exit 1
    }
  fi
  [[ $(fastboot_value unlocked) == yes ]] || {
    echo "ERROR: bootloader is not unlocked" >&2
    exit 1
  }
}
bootloader_rejects_ram_boot() {
  # Recognised refusals to boot an image from RAM that the same bootloader
  # boots from flash. Pixel 1 answers "dtb not found" because its device trees
  # are appended to the kernel and only the flash path scans them; measured on
  # Fastboot 28.0.2, 29.0.5, 31.0.3 and 37.0.1.
  #
  # Matched against the whole "FAILED (remote: ...)" phrase rather than a bare
  # substring, so unrelated output mentioning the same words cannot be mistaken
  # for a bootloader limitation.
  case "${1,,}" in
    *"failed (remote: 'dtb not found')"* | *"failed (remote: dtb not found)"*) return 0 ;;
    *"failed (remote: 'unknown command')"* | *"failed (remote: unknown command)"*) return 0 ;;
    *) return 1 ;;
  esac
}
classify_untested_evidence() {
  # Decide whether recorded bootloader-limitation evidence still authorises an
  # untested flash. Emits a verdict word so the decision can be exercised
  # directly against a state directory rather than inferred from a message.
  #
  # Evidence is valid only for the exact three images it was gathered against:
  # a regenerated no-op control or rollback image invalidates it, because
  # neither the proof nor the recovery path would still refer to reality.
  local dir=$1 want_custom=$2
  local custom_boot_sha="" noop_boot_sha="" original_boot_sha=""
  [[ -f $dir/test-unsupported.env ]] || {
    printf 'no-evidence\n'
    return 1
  }
  # shellcheck source=/dev/null
  . "$dir/test-unsupported.env"
  [[ $custom_boot_sha == "$want_custom" ]] || {
    printf 'custom-mismatch\n'
    return 1
  }
  [[ -f $dir/noop-boot.img && $noop_boot_sha == "$(sha256sum "$dir/noop-boot.img" | awk '{print $1}')" ]] || {
    printf 'noop-mismatch\n'
    return 1
  }
  [[ -f $dir/original-boot.img && $original_boot_sha == "$(sha256sum "$dir/original-boot.img" | awk '{print $1}')" ]] || {
    printf 'rollback-mismatch\n'
    return 1
  }
  printf 'ok\n'
  return 0
}
# End deployment decision helpers.
check_partition_size() {
  local image=$1 raw size image_size
  raw=$(fastboot_value "partition-size:boot_$slot")
  [[ $raw =~ ^0[xX][0-9a-fA-F]+$ || $raw =~ ^[0-9]+$ ]] || {
    echo "ERROR: invalid Fastboot boot partition size: $raw" >&2
    exit 1
  }
  size=$((raw))
  image_size=$(stat -c %s "$image")
  ((image_size <= size)) || {
    echo "ERROR: image exceeds boot_$slot ($image_size > $size)" >&2
    exit 1
  }
}

case "$action" in
  prepare)
    capture_adb_state
    mkdir -p "$state_dir"
    [[ -f $artifacts/Image && -f $artifacts/SHA256SUMS ]] || {
      echo "ERROR: build artifacts are incomplete" >&2
      exit 1
    }
    (cd "$artifacts" && sha256sum -c SHA256SUMS)
    block="/dev/block/bootdevice/by-name/boot_$slot"
    remote_base="/data/local/tmp/pixel-nas-base-$$.img"
    remote_image="/data/local/tmp/pixel-nas-Image-$$"
    remote_noop="/data/local/tmp/pixel-nas-noop-$$.img"
    remote_custom="/data/local/tmp/pixel-nas-custom-$$.img"
    cleanup_prepare_remote() {
      root_cmd "rm -f $remote_base $remote_image $remote_noop $remote_custom /data/local/tmp/pixel-nas-device-package.sh" >/dev/null 2>&1 || true
    }
    trap cleanup_prepare_remote EXIT INT TERM
    root_cmd "dd if=$block of=$remote_base bs=4096"
    if [[ -f $state_dir/original-boot.img ]]; then
      [[ -f $state_dir/original-boot.img.sha256 ]] || {
        echo "ERROR: existing backup lacks its checksum" >&2
        exit 1
      }
      (cd "$state_dir" && sha256sum -c original-boot.img.sha256)
      recorded_sha=$(sha256sum "$state_dir/original-boot.img" | awk '{print $1}')
      live_sha=$(root_cmd "sha256sum $remote_base" | awk '{print $1}')
      [[ $live_sha == "$recorded_sha" ]] || {
        echo "ERROR: live boot_$slot differs from the immutable backup; preserve this state and prepare in a new workspace" >&2
        exit 1
      }
    else
      adb -s "$serial" pull "$remote_base" "$state_dir/original-boot.img"
      (cd "$state_dir" && sha256sum original-boot.img >original-boot.img.sha256)
    fi
    boot_size=$(root_cmd "blockdev --getsize64 $block" | tr -d '\r')
    adb -s "$serial" push "$artifacts/Image" "$remote_image"
    adb -s "$serial" push "$SCRIPT_DIR/device-package.sh" /data/local/tmp/pixel-nas-device-package.sh
    root_cmd "chmod 0755 /data/local/tmp/pixel-nas-device-package.sh && /data/local/tmp/pixel-nas-device-package.sh $remote_base $remote_image $remote_noop $remote_custom" | tee "$state_dir/package.log"
    adb -s "$serial" pull "$remote_noop" "$state_dir/noop-boot.img"
    adb -s "$serial" pull "$remote_custom" "$state_dir/custom-boot.img"
    root_cmd "rm -f $remote_base $remote_image $remote_noop $remote_custom /data/local/tmp/pixel-nas-device-package.sh"
    trap - EXIT INT TERM
    custom_size=$(stat -c %s "$state_dir/custom-boot.img")
    ((custom_size <= boot_size)) || {
      echo "ERROR: custom image exceeds boot partition" >&2
      exit 1
    }
    (cd "$state_dir" && sha256sum noop-boot.img custom-boot.img >packaged-images.sha256)
    # Regenerating the images invalidates any earlier verdict about them.
    rm -f "$state_dir/test-success.env" "$state_dir/test-unsupported.env" "$state_dir/untested-flash.env"
    original_uname=$(adb -s "$serial" shell uname -r | tr -d '\r')
    fingerprint=$(adb_prop ro.build.fingerprint)
    {
      printf 'device=%q\n' "$device"
      printf 'build=%q\n' "$build"
      printf 'serial=%q\n' "$serial"
      printf 'slot=%q\n' "$slot"
      printf 'boot_partition_size=%q\n' "$boot_size"
      printf 'original_uname=%q\n' "$original_uname"
      printf 'fingerprint=%q\n' "$fingerprint"
    } >"$state_dir/deploy-state.env"
    custom_sha=$(sha256sum "$state_dir/custom-boot.img" | awk '{print $1}')
    rollback_token="ROLLBACK:$device:$slot:$(sha256sum "$state_dir/original-boot.img" | cut -c1-12)"
    echo "Prepared: $state_dir"
    printf 'Test: %q test --workspace %q --device %q\n' "$0" "$workspace" "$device"
    echo "Future flash token: FLASH:$device:$slot:${custom_sha:0:12}"
    echo "Rollback token: $rollback_token"
    printf 'Boot-loop rollback: %q rollback --workspace %q --device %q --slot %q --serial %q --confirm-rollback %q\n' \
      "$0" "$workspace" "$device" "$slot" "$serial" "$rollback_token"
    ;;
  test)
    capture_adb_state
    [[ -f $state_dir/deploy-state.env && -f $state_dir/noop-boot.img && -f $state_dir/custom-boot.img ]] || {
      echo "ERROR: run prepare first" >&2
      exit 1
    }
    (cd "$state_dir" && sha256sum -c packaged-images.sha256)
    custom_sha=$(sha256sum "$state_dir/custom-boot.img" | awk '{print $1}')
    # Any previous verdict is stale the moment we retest.
    rm -f "$state_dir/test-success.env" "$state_dir/test-unsupported.env"
    adb -s "$serial" reboot bootloader
    check_fastboot_state
    # The no-op image is byte-identical in components to the boot partition the
    # bootloader already boots from flash. If it is rejected from RAM, that is
    # proof of a bootloader limitation rather than a defect in our image, and it
    # is the only condition under which an untested flash may later be
    # authorised. Any other failure leaves no evidence behind on purpose.
    noop_sha=$(sha256sum "$state_dir/noop-boot.img" | awk '{print $1}')
    original_sha=$(sha256sum "$state_dir/original-boot.img" | awk '{print $1}')
    noop_status=0
    noop_output=$(fastboot -s "$serial" boot "$state_dir/noop-boot.img" 2>&1) || noop_status=$?
    printf '%s\n' "$noop_output"
    if ((noop_status != 0)); then
      # Branch-B evidence is only as strong as its control. Grant it solely when
      # the refused image is byte-identical to the boot image the bootloader
      # currently boots from flash; component-equivalence is not enough to rule
      # out a defect introduced by repacking.
      if [[ $noop_sha != "$original_sha" ]]; then
        echo "ERROR: 'fastboot boot' was refused, but the no-op image is not byte-identical" >&2
        echo "to the live boot image, so this does not prove a bootloader limitation." >&2
        echo "  no-op:    $noop_sha" >&2
        echo "  original: $original_sha" >&2
        echo "Investigate the repack before considering an untested flash." >&2
        exit 1
      fi
      if bootloader_rejects_ram_boot "$noop_output"; then
        printf 'reason=%q\nfastboot_output=%q\ncustom_boot_sha=%q\nnoop_boot_sha=%q\noriginal_boot_sha=%q\nrecorded_utc=%q\n' \
          'bootloader refused a RAM-booted image byte-identical to the live boot partition' \
          "$noop_output" "$custom_sha" "$noop_sha" "$original_sha" \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          >"$state_dir/test-unsupported.env"
        echo "ERROR: this bootloader cannot RAM-boot an image it boots from flash." >&2
        echo "The reversible acceptance test is impossible here. Evidence recorded in" >&2
        echo "  $state_dir/test-unsupported.env" >&2
        echo "Return the phone to Android, then see the untested-flash procedure." >&2
        exit 1
      fi
      echo "ERROR: 'fastboot boot' failed for a reason other than a known bootloader" >&2
      echo "limitation. This is not grounds for an untested flash. Investigate:" >&2
      printf '%s\n' "$noop_output" >&2
      exit 1
    fi
    wait_adb
    [[ $(root_cmd id) == *'uid=0(root)'* ]] || {
      echo "ERROR: root failed after no-op repack" >&2
      exit 1
    }
    adb -s "$serial" reboot bootloader
    check_fastboot_state
    fastboot -s "$serial" boot "$state_dir/custom-boot.img"
    wait_adb
    [[ $(root_cmd id) == *'uid=0(root)'* ]] || {
      echo "ERROR: root failed after custom temporary boot" >&2
      exit 1
    }
    runtime_release=$(adb -s "$serial" shell uname -r | tr -d '\r')
    [[ $runtime_release == *-nas1* ]] || {
      echo "ERROR: custom kernel identity is absent: $runtime_release" >&2
      exit 1
    }
    root_cmd "cat /proc/filesystems" | grep -Eq '(^|[[:space:]])nfs$' || {
      echo "ERROR: NFS is not registered" >&2
      exit 1
    }
    root_cmd "cat /proc/filesystems" | grep -Eq '(^|[[:space:]])cifs$' || {
      echo "ERROR: CIFS is not registered" >&2
      exit 1
    }
    custom_sha=$(sha256sum "$state_dir/custom-boot.img" | awk '{print $1}')
    printf 'custom_boot_sha=%q\nruntime_release=%q\ntested_utc=%q\n' "$custom_sha" "$runtime_release" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$state_dir/test-success.env"
    echo "Temporary boot passed, including no-op repack and Magisk root survival"
    ;;
  flash)
    ((data_backup_confirmed)) || {
      echo "ERROR: --data-backup-confirmed is required" >&2
      exit 1
    }
    capture_adb_state
    current_sha=$(sha256sum "$state_dir/custom-boot.img" | awk '{print $1}')
    if [[ -f $state_dir/test-success.env ]]; then
      # Normal path: a reversible temporary boot proved this exact image.
      [[ -z $confirm_untested ]] || {
        echo "ERROR: --confirm-untested is not permitted once temporary-test evidence exists" >&2
        exit 1
      }
      custom_boot_sha=""
      # shellcheck source=/dev/null
      . "$state_dir/test-success.env"
      [[ -n $custom_boot_sha ]] || {
        echo "ERROR: temporary-test evidence lacks custom_boot_sha" >&2
        exit 1
      }
      [[ $current_sha == "$custom_boot_sha" ]] || {
        echo "ERROR: tested image checksum changed" >&2
        exit 1
      }
    else
      # Escape hatch for bootloaders that reject `fastboot boot`. Pixel 1
      # (marlin/sailfish) rejects a RAM-booted appended-DTB image with
      # "dtb not found" on every Fastboot release tested, so the reversible
      # acceptance test cannot run at all there. Every other gate still
      # applies; only the temporary-boot evidence is waived, and only when
      # the operator supplies a second image-bound token.
      # An untested flash is permitted only when `test` proved the bootloader
      # cannot RAM-boot at all. A custom image that boots but fails the kernel
      # identity or NFS/CIFS checks leaves no evidence, so it cannot reach here.
      # Capture the status explicitly. The classifier returns non-zero for every
      # refusal, and errexit aborts a failing assignment at this level, which
      # would skip the case below and leave an ordinary stale-evidence refusal
      # completely unexplained.
      evidence_status=0
      evidence_verdict=$(classify_untested_evidence "$state_dir" "$current_sha") || evidence_status=$?
      case "$evidence_verdict" in
        ok) ;;
        no-evidence)
          echo "ERROR: temporary-test evidence is absent and no bootloader-limitation" >&2
          echo "evidence was recorded. Run 'test' first." >&2
          echo "An untested flash requires 'test' to have proven that this bootloader" >&2
          echo "rejects a RAM-booted image it boots from flash. A custom image that" >&2
          echo "boots but fails validation is never eligible." >&2
          exit 1
          ;;
        custom-mismatch)
          echo "ERROR: the recorded bootloader-limitation evidence refers to a different" >&2
          echo "image than the one about to be flashed. Rerun 'test'." >&2
          exit 1
          ;;
        noop-mismatch)
          echo "ERROR: the no-op control image changed since the evidence was recorded." >&2
          echo "Rerun 'test'." >&2
          exit 1
          ;;
        rollback-mismatch)
          echo "ERROR: the rollback image changed since the evidence was recorded." >&2
          echo "Rerun 'test'." >&2
          exit 1
          ;;
        *)
          echo "ERROR: unrecognised evidence verdict: '$evidence_verdict' (status $evidence_status)" >&2
          exit 1
          ;;
      esac
      ((evidence_status == 0)) || {
        echo "ERROR: evidence classifier reported '$evidence_verdict' with status $evidence_status" >&2
        exit 1
      }
      expected_untested="UNTESTED:$device:$slot:${current_sha:0:12}"
      [[ $confirm_untested == "$expected_untested" ]] || {
        echo "ERROR: this bootloader cannot run the reversible test. To flash anyway:" >&2
        echo "  --confirm-untested '$expected_untested'" >&2
        echo "Recovery then depends solely on the rollback image; confirm it is verified and its command is recorded off-host." >&2
        exit 1
      }
      [[ -f $state_dir/original-boot.img && -f $state_dir/original-boot.img.sha256 ]] || {
        echo "ERROR: refusing an untested flash without a rollback image" >&2
        exit 1
      }
      (cd "$state_dir" && sha256sum -c original-boot.img.sha256) || {
        echo "ERROR: rollback image failed verification; refusing an untested flash" >&2
        exit 1
      }
      (cd "$state_dir" && sha256sum -c packaged-images.sha256) || {
        echo "ERROR: packaged images failed verification; refusing an untested flash" >&2
        exit 1
      }
      original_sha=$(sha256sum "$state_dir/original-boot.img" | awk '{print $1}')
      live_sha=$(root_cmd "sha256sum /dev/block/bootdevice/by-name/boot_$slot" | awk '{print $1}')
      [[ $live_sha == "$original_sha" ]] || {
        echo "ERROR: live boot_$slot no longer matches the rollback image; refusing an untested flash" >&2
        exit 1
      }
      untested_flash=1
      echo "WARNING: flashing without temporary-boot evidence; rollback image verified against live boot_$slot"
    fi
    expected="FLASH:$device:$slot:${current_sha:0:12}"
    [[ $confirm_flash == "$expected" ]] || {
      echo "ERROR: exact flash token required: $expected" >&2
      exit 1
    }
    # From here the boot partition may change, so keep the exact recovery
    # command on screen for any non-zero exit, including a failed boot.
    rollback_sha=$(sha256sum "$state_dir/original-boot.img" | awk '{print $1}')
    rollback_token="ROLLBACK:$device:$slot:${rollback_sha:0:12}"
    # The trap runs a function rather than a string built from data. Embedding
    # an expanded path in trap text breaks the trap outright when the workspace
    # contains an apostrophe, which would suppress recovery instructions at the
    # exact moment they are needed.
    # shellcheck disable=SC2329 # Invoked by trap.
    print_recovery() {
      echo >&2
      echo "RECOVERY: enter Fastboot with the hardware key combination, then run:" >&2
      printf '  %q rollback --workspace %q --device %q --slot %q --serial %q --confirm-rollback %q\n' \
        "$0" "$workspace" "$device" "$slot" "$serial" "$rollback_token" >&2
    }
    # shellcheck disable=SC2329 # Invoked by trap.
    on_flash_exit() {
      local flash_status=$?
      ((flash_status == 0)) || print_recovery
    }
    trap on_flash_exit EXIT
    adb -s "$serial" reboot bootloader
    check_fastboot_state
    check_partition_size "$state_dir/custom-boot.img"
    # Split into attempt and completion. An ADB or Fastboot failure before the
    # write must not leave a record claiming the partition was changed, and a
    # failure during the write must still leave a trace that it was started.
    if ((${untested_flash:-0})); then
      printf 'untested_flash_attempted_utc=%q\nuntested_flash_sha=%q\nrollback_sha=%q\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$current_sha" "$original_sha" \
        >"$state_dir/untested-flash.env"
    fi
    fastboot -s "$serial" flash "boot_$slot" "$state_dir/custom-boot.img"
    if ((${untested_flash:-0})); then
      printf 'untested_flash_completed_utc=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >>"$state_dir/untested-flash.env"
    fi
    fastboot -s "$serial" reboot
    wait_adb
    [[ $(adb -s "$serial" shell uname -r | tr -d '\r') == *-nas1* ]] || {
      echo "ERROR: persistent custom kernel verification failed" >&2
      exit 1
    }
    [[ $(root_cmd id) == *'uid=0(root)'* ]] || {
      echo "ERROR: persistent Magisk root verification failed" >&2
      exit 1
    }
    trap - EXIT
    echo "Persistent one-slot flash verified"
    ;;
  rollback)
    [[ $expected_device == marlin || $expected_device == sailfish ]] || {
      echo "ERROR: rollback requires --device marlin|sailfish" >&2
      exit 1
    }
    [[ $requested_slot == a || $requested_slot == b ]] || {
      echo "ERROR: rollback requires --slot a|b" >&2
      exit 1
    }
    [[ -n $requested_serial ]] || {
      echo "ERROR: rollback requires --serial" >&2
      exit 1
    }
    [[ $requested_serial =~ ^[A-Za-z0-9._:-]+$ ]] || {
      echo "ERROR: unsafe rollback serial value" >&2
      exit 1
    }
    device=$expected_device
    slot=$requested_slot
    serial=$requested_serial
    state_dir="$workspace/deploy/${device}-${ANDROID_BUILD}-${serial}/slot-$slot"
    [[ -f $state_dir/original-boot.img && -f $state_dir/original-boot.img.sha256 ]] || {
      echo "ERROR: rollback package is incomplete" >&2
      exit 1
    }
    (cd "$state_dir" && sha256sum -c original-boot.img.sha256)
    original_sha=$(sha256sum "$state_dir/original-boot.img" | awk '{print $1}')
    expected="ROLLBACK:$device:$slot:${original_sha:0:12}"
    [[ $confirm_rollback == "$expected" ]] || {
      echo "ERROR: exact rollback token required: $expected" >&2
      exit 1
    }
    check_fastboot_state 0
    check_partition_size "$state_dir/original-boot.img"
    fastboot -s "$serial" flash "boot_$slot" "$state_dir/original-boot.img"
    fastboot -s "$serial" reboot
    echo "Rollback image restored to boot_$slot"
    ;;
  *)
    echo "ERROR: unknown action: $action" >&2
    exit 2
    ;;
esac
