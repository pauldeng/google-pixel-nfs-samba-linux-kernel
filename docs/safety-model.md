# Safety model and data flow

## Safety model

This work can make the phone unbootable and enables network-filesystem parsers in a kernel frozen in 2019. Read the complete action plan before connecting a phone.

The non-negotiable controls are:

1. Accept only `marlin` or `sailfish` on the exact Android build above.
2. Preserve the exact active rooted boot partition and its checksum before packaging.
3. Replace MagiskBoot's uncompressed kernel component—not blindly flash or insert `Image.lz4-dtb`.
4. Require the base rooted kernel to contain `want_initramfs`, then apply the matching Pixel 1 legacy-SAR `skip_initramfs` → `want_initramfs` patch to the custom kernel.
5. Temporarily boot both the no-op and custom images and require Magisk root after each. Where the bootloader refuses to RAM-boot any image, follow branch B of the deployment policy in [action-plan.md](action-plan.md); it is evidence-gated and is the only route to a flash without a temporary test.
6. Flash only the tested active slot, and only after the operator supplies the exact generated token.
7. Keep authoritative NAS photographs read-only at both the server and client.
8. Keep SMB/NFS on a trusted isolated LAN or VLAN; never expose either service to the internet.

The scripts do not invent confirmation tokens, reset supplied source checkouts, overwrite an existing rollback image, flash both slots, or run a factory-image installer.

## Recommended data flow

The supported Google Photos design is:

```text
read-only NAS source
        ↓
/data/local/tmp/nas-ro
        ↓  bounded, checksum-verified copy
/storage/emulated/0/DCIM/NAS-Inbox
        ↓  explicit MediaStore scan
Google Photos device-folder backup
```

Directly mounting a NAS share into Android's `/mnt/runtime/*` storage views is experimental. Android 10 uses per-app mount namespaces, separate storage views, SELinux, and MediaStore; a mount visible to root is not necessarily visible to Google Photos.

If phone-to-NAS writes are genuinely required, use a different root-only mount, NAS share, and least-privilege writer identity. Never give Google Photos write access to the authoritative NAS archive.

This project does not guarantee Google Photos entitlement, account behavior, indexing, or future service policy. Validate the exact account and app with a disposable image before relying on the workflow.
