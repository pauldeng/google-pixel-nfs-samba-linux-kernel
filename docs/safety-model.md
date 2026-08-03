# Safety model and data flow

## Safety model

This work can make the phone unbootable and enables network-filesystem parsers in a kernel frozen in 2019. Read the complete action plan before connecting a phone.

The non-negotiable controls are:

1. Accept only `marlin` or `sailfish` on the exact Android build above.
2. Preserve the exact active rooted boot partition and its checksum before packaging.
3. Replace MagiskBoot's uncompressed kernel component—not blindly flash or insert `Image.lz4-dtb`.
4. Require the base rooted kernel to contain `want_initramfs`, then apply the matching Pixel 1 legacy-SAR `skip_initramfs` → `want_initramfs` patch to the custom kernel.
5. Temporarily boot both the no-op and custom images and require Magisk root after each. Where the bootloader refuses to RAM-boot any image, follow branch B of the deployment policy in [action-plan.md](action-plan.md); it is evidence-gated and is the only route to a flash without a temporary test.
6. Flash only the recorded active slot, and only after the operator supplies the exact generated token. "Tested" means branch-A temporary-boot evidence, or branch-B bootloader-limitation evidence bound to that exact image; never neither.
7. Keep authoritative NAS photographs read-only at both the server and client.
8. Keep SMB/NFS on a trusted isolated LAN or VLAN; never expose either service to the internet.

The scripts do not invent confirmation tokens, reset supplied source checkouts, overwrite an existing rollback image, flash both slots, or run a factory-image installer.

## Recommended data flow

The supported Google Photos design is:

```text
read-only NAS source
  mounted read-only into a /mnt/runtime view, in init's mount namespace
/storage/emulated/0/DCIM/<folder>      propagates into every app namespace
  a periodic scan tells MediaStore the files exist; nothing is copied
Google Photos device-folder backup
```

Nothing is copied to internal flash. Photos reads each file in place from the NAS and uploads it at original quality. Installed by `install-nas-photos.sh`; the device service is `96-nas-photos.sh`.

Mounting into a runtime view rather than under `/data/media` is not a preference: sdcardfs does not expose mounts made on its lower tree, so a mount there is invisible to apps whatever its ownership or label. A mount visible to root is still not necessarily visible to Google Photos — the acceptance evidence is a MediaStore row plus a real upload, never a `/proc/mounts` entry.

Three consequences are load-bearing, and each is a safety property rather than a detail:

- **One mount per share.** CIFS shares a single superblock per share and SELinux refuses two mounts of it with different `context=` settings, so a second mount of the same share fails on every attempt. `90-nas-mount.sh` and `96-nas-photos.sh` each refuse rather than compete; do not point both at one share.
- **The share is unmounted when the NAS goes away.** While it is mounted under `DCIM` and the server is unreachable, listing `/storage/emulated/0/DCIM` itself fails, degrading the gallery and every media scan. The service confirms unreachability over several probes, unmounts, and remounts when the NAS returns. A missing folder is a smaller failure than a broken `DCIM`.
- **No screen lock.** `/storage/emulated/0` is credential-encrypted; with a lock set, user 0 stays `RUNNING_LOCKED` after every reboot and the mount cannot be made until someone types the PIN. This is a deliberate trade for an unattended LAN-only appliance and must be stated to the operator, not assumed.

`90-nas-mount.sh` remains available for a separate share — in particular the isolated read/write case — mounting to a root-only path outside app-visible storage.

If phone-to-NAS writes are genuinely required, use a different root-only mount, NAS share, and least-privilege writer identity. Never give Google Photos write access to the authoritative NAS archive.

This project does not guarantee Google Photos entitlement, account behavior, indexing, or future service policy. Validate the exact account and app with a disposable image before relying on the workflow.
