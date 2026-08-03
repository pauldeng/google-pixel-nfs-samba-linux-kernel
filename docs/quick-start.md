# Operator quick start

For the agent-oriented version with traps and failure signatures, see [ai-agent-runbook.md](ai-agent-runbook.md).

## Host and build quick start

Use Ubuntu 20.04 as a normal user with `sudo` access. First verify the delivered scripts:

```bash
cd Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts
sha256sum -c SHA256SUMS
./setup-host-ubuntu-20.04.sh
```

If the setup script adds the user to `plugdev`, log out and back in, then rerun it.

Build into a dedicated workspace:

```bash
export PIXEL_NAS_WORKSPACE="$HOME/pixel-nas-build-workspace"
./build-kernel.sh --workspace "$PIXEL_NAS_WORKSPACE" --jobs "$(nproc)"
```

The script automatically detects the three locked repositories when they are siblings of this repository. It validates them without fetching or writing to them, creates script-owned local clones under the workspace, and registers build worktrees only in those managed clones. This avoids another network download while preserving the supplied repositories' status and Git worktree metadata.

Repositories elsewhere can be supplied explicitly with the same isolation:

```bash
./build-kernel.sh \
  --workspace "$PIXEL_NAS_WORKSPACE" \
  --jobs "$(nproc)" \
  --kernel-repo ../android-kernel-msm \
  --aarch64-repo ../aarch64-linux-android-4.9 \
  --arm32-repo ../arm-linux-androideabi-4.9
```

Once a managed repository exists under a workspace, it remains authoritative for that workspace. If an explicit repository option is supplied on a later run, the script prints a warning that the option is ignored and directs the operator to use a new workspace to import it.

Verify the generated artifacts:

```bash
cd "$PIXEL_NAS_WORKSPACE/artifacts/common"
sha256sum -c SHA256SUMS
grep -E 'kernel_commit|kernel_release|supported_devices' build-manifest.txt
```

Expected outputs include:

- `Image`: uncompressed kernel used by the MagiskBoot packaging workflow
- `Image.lz4-dtb`: compressed build proof with appended device trees; not flashed directly
- `kernel.config` and `defconfig`
- `source-lock.env` and `build-manifest.txt`
- `SHA256SUMS`

## Device workflow

The phone must have an unlocked bootloader, USB debugging, authorised ADB access, and working Magisk root. Confirm the exact device and build before continuing:

```bash
adb devices
adb shell getprop ro.product.device
adb shell getprop ro.build.id
adb shell getprop ro.boot.slot_suffix
adb shell su -c id
```

From the companion directory, prepare the active-slot backup and device-specific images:

```bash
./device-deploy.sh prepare \
  --workspace "$PIXEL_NAS_WORKSPACE" \
  --device auto
```

Then temporarily boot the no-op image followed by the custom image:

```bash
./device-deploy.sh test \
  --workspace "$PIXEL_NAS_WORKSPACE" \
  --device auto
```

Stop if the custom image fails to boot, Magisk root disappears, `uname -r` lacks `-nas1`, or NFS/CIFS is absent from `/proc/filesystems`.

One exception: if `fastboot boot` is refused for *every* image including the no-op control, that is a bootloader limitation rather than an image defect. `test` records evidence and the deployment policy in [action-plan.md](action-plan.md) describes the evidence-gated untested-flash route.

Permanent flash and rollback are intentionally not abbreviated here. Follow Sections 8 and 11 of the action plan and use only the exact device/slot/hash-bound commands and tokens printed by `device-deploy.sh`.

## NAS testing

The production baseline is a read-only photo source. SMB requires a numeric IPv4 address, a dedicated non-administrator reader account, and a NAS that accepts SMB 3.0/3.02 without requiring SMB 3.1.1 or transport encryption. NFSv3 requires a numeric source address and the explicit `addr=<NAS_IP>` option supplied by the mount script.

Copy an example configuration outside the integrity-covered companion files, edit it, and run the manual test wrapper:

```bash
mkdir -p ../pixel-nas-operator-config
cp nas-mount-smb-ro.conf.example ../pixel-nas-operator-config/nas-mount.conf
cp nas-photos.conf.example ../pixel-nas-operator-config/nas-photos.conf
cp nas-smb.secret.example ../pixel-nas-operator-config/nas-smb.secret
chmod 0600 ../pixel-nas-operator-config/nas-mount.conf \
  ../pixel-nas-operator-config/nas-photos.conf \
  ../pixel-nas-operator-config/nas-smb.secret

# Edit the copied configuration and replace the placeholder secret securely.
./test-nas-mount.sh \
  ../pixel-nas-operator-config/nas-mount.conf \
  ../pixel-nas-operator-config/nas-smb.secret
```

The read-only test requires the exact source, filesystem type, and `ro` mode, then proves that a root write is rejected. NFS and isolated read/write examples are documented in Section 9 of the action plan.

Before installing the persistent service, install the SELinux module:

```bash
./install-sepolicy-module.sh
```

It carries two rules, each derived from an AVC denial observed on this hardware.

`allow kernel kernel capability net_raw` — without it the in-kernel CIFS client cannot rebuild its socket after a network interruption: the session drops during doze, `cifsd` is denied `net_raw`, and the mount stays listed in `/proc/mounts` while every read returns `Host is down`.

`allow media_rw_data_file media_rw_data_file filesystem associate` — without it the photo-share mount is rejected outright, because a `context=` mount needs permission for that label to apply to a filesystem of its own type. Without the context the files are `unlabeled` and every app, Google Photos included, is denied.

On a file-based-encrypted device Magisk stages module rules for the *next* boot, so allow **two reboots** before judging whether it worked. The first boot after installing will fail, and that is expected rather than a fault.

For the Google Photos path, install the photo-share service instead:

```bash
./install-nas-photos.sh ../pixel-nas-operator-config/nas-photos.conf \
  ../pixel-nas-operator-config/nas-smb.secret
```

That mounts the share read-only where Photos can see it and keeps MediaStore informed; it copies nothing to internal flash. It requires user 0 to be unlocked at installation time and refuses any configured screen lock, because credential-encrypted storage would otherwise stay unavailable after an unattended reboot. It also refuses if `90-nas-mount.sh` targets the same share, because two mounts of one share cannot both succeed. Configuration, credential, and service replacements are checksum-verified before atomic activation. See [`safety-model.md`](safety-model.md) for why.

`90-nas-mount.sh` below remains for a *different* share — in particular the isolated read/write case — mounting to a root-only path outside app-visible storage. Install a persistent Magisk service only after the corresponding manual test passes. The service uses a bounded TCP connection check against port 445 for SMB or 2049 for NFS, so NAS appliances that intentionally reject ICMP remain supported. After reboot, run `./verify-nas-service.sh`; it compares the mount from independent `su -mm` and plain `su` shells launched through adb instead of accepting only the service's own view. A pass establishes host-shell visibility only—it does not inspect Google Photos or any other app namespace.
