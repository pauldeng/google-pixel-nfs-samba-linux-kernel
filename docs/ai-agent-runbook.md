# AI agent runbook

**Audience: an AI agent (Claude, Codex, or similar) driving this project for a user.**

The action plan states policy and reasoning. This file is the execution order, the exact commands, and every trap that has already cost real time on real hardware. Read section 1 before running anything; each trap below was hit for the first time on 2026-08-01/02 and cost between ten minutes and two hours.

Everything here was executed against a real device: Pixel (`sailfish`), Android 10 `QP1A.191005.007.A3`, bootloader `8996-012001-1908071822`, Magisk 29.0, QNAP NAS over SMB 3.0.

## 1. Rules for interacting with the user

**Assume the user will not infer anything.** State exactly which button, exactly when, or state explicitly that they must not touch the device.

| Situation | What to tell the user |
|---|---|
| Any script is running | "Do not press anything. The script reboots the phone itself." |
| A run failed and left the phone at the bootloader screen | "Press the power button to select Start." Say it in those words. |
| Phone hangs on the Google logo over ~60 s | "Hold Power + Volume-Down until it restarts." |
| `sudo` is needed | They must run it in a **real terminal**. `sudo` has no TTY inside the agent harness *or* behind the `!` prefix. |
| A step needs the phone in Android | Say so. `device-deploy.sh flash` starts with an ADB check and fails if the phone is sitting in fastboot. |
| Waiting on a long build | Say roughly how long (~35 min on 4 cores) so they do not interrupt it. |

Never type a flash or rollback token on the user's behalf without them explicitly authorising that specific action. Tokens are printed by the scripts; do not invent them.

**Expect permission prompts to block SELinux work.** `magiskpolicy` and `install-sepolicy-module.sh` are commonly denied by the harness classifier. Do not work around it. Explain what the command does and give the user a `!` one-liner to run themselves.

## 2. Traps, by phase

Symptoms an agent will actually see, and what they mean.

| Symptom | Cause | Action |
|---|---|---|
| `sudo: a terminal is required to read the password` | No TTY in the harness or behind `!` | Install Google platform-tools to `~/.local/bin` without sudo (§4). Only udev rules need sudo. |
| Build exits ~0 but produced nothing | Backgrounded with `nohup`/`setsid`, then reaped | Use the harness's own background mode |
| `file not recognized: File truncated`, `fixdep: error opening depfile`, duplicate `CC` lines | Two builds raced, or a killed build left truncated objects | Rerun incrementally; if it repeats, `--clean-build` |
| Build failed but the log shows no `error:` | The command piped output through `tail`, discarding the failure | Never pipe a build through `tail`. Capture the whole log. |
| `kernel_release=3.18.137-nas1+` | `setlocalversion` adds `+` in a detached worktree | Expected. Match on the `-nas1` substring, not equality. |
| `grep want_initramfs <boot partition>` returns 0 | The kernel inside boot.img is LZ4-compressed | Must `magiskboot unpack` first, then grep the extracted `kernel` |
| `fastboot boot` → `FAILED (remote: 'dtb not found')` | This bootloader cannot RAM-boot an appended-DTB image. Reproduced on fastboot 28.0.2, 29.0.5, 31.0.3, 37.0.1, and with an image byte-identical to the working `boot_b`. | Unfixable. Still run `test`: it records the evidence that unlocks `--confirm-untested` (§7) |
| `ERROR: invalid Fastboot boot partition size: <tab>0x2000000` | Fixed in `49da559`; fastboot pads with a tab | Update the repo if you see this |
| Boot shows "There's an internal problem with your device" | AOSP's `compatibility_matrix.2.xml` requires `CONFIG_NFS_FS=n`; enabling NFS fails VINTF | Cosmetic, once per boot. Dismiss. Do **not** disable NFS. See plan 4.1.1 |
| `test-nas-mount.sh` reports failure but the mount is actually up | Fixed in `0e269aa`; it used `adb pull` on a root-owned `0600` log | Update the repo if you see this |
| Mount reads `Host is down`, `/proc/mounts` still lists it, `CIFS VFS: Error -13 creating socket` every 3 s | `cifsd` denied `net_raw`, cannot rebuild its socket after the session drops | **Blocking for unattended use.** Install the sepolicy module (§10) |
| sepolicy module installed but denials continue after one reboot | `/data` is FBE; Magisk stages module rules for the *next* boot | Reboot a second time before judging. See plan 9.8 |
| Mount absent after a boot where the NAS was down | One-shot service gave up. Fixed: `RETRY_INTERVAL_SECONDS` keeps it trying | Reinstall the service; confirm the key is in `/data/adb/nas-mount.conf` |
| Google Photos never lists the NAS device folder | Photos 7.85 does not surface it even with correct MediaStore bucket metadata | Enable **Back up all device folders**. Uploads work regardless. |
| MediaStore has no rows for files added to the NAS | inotify cannot fire for writes another machine makes; Android never learns they exist | Expected. `96-nas-photos.sh` scans for them. It copies nothing. |
| A large file is copied directly into the watched tree | SMB exposes its path before the copy is complete | Prefer copying into a sibling server-side staging directory and atomically renaming the completed file or directory into the watched tree. The service's stability gate is a safety net, not a transactional server-side upload protocol. |
| All rows for the NAS folder vanish after a reboot | MediaProvider's boot scan runs before the mount exists and prunes them as missing | Expected. The scanner rebuilds the index; Photos deduplicates, so nothing re-uploads. |
| `am broadcast` fails with `Failed transaction (2147483646)` | `cmd` passes its stdin fd to system_server, which cannot read a file labelled `adb_data_file` | Redirect the call's stdin from `/dev/null`. |

## 3. Phase 0 — prerequisites the phone must already meet

This project assumes the phone is **already OEM-unlocked, rooted, and running a Magisk-patched boot image**. Verify before anything else; do not assume, and do not proceed on a phone that fails these.

```bash
adb shell getprop ro.product.device        # marlin or sailfish
adb shell getprop ro.build.id              # exactly QP1A.191005.007.A3
adb shell su -c id                         # uid=0(root)
adb shell su -c 'ls /data/adb/magisk/magiskboot'
adb reboot bootloader && fastboot getvar unlocked   # unlocked: yes
fastboot reboot
```

**If the user has not done this, help them — do not just refuse.** It is a prerequisite, not an obstacle, and it is the step most likely to stall a newcomer. Walk them through it in this order, and be explicit about the destructive part:

1. **Enable Developer options.** Settings → About phone → tap **Build number** seven times.
2. **Enable OEM unlocking and USB debugging.** Settings → System → Advanced → Developer options.

   If **OEM unlocking** is greyed out, do not conclude carrier lock yet. Work through these first:
   - **Connect to the internet and wait a few minutes.** The device must check in with Google before the toggle becomes available; this is the most common cause and AOSP calls it out explicitly.
   - **Reboot** and look again.
   - **Complete account setup.** A device still in initial setup, or with no account, often keeps the toggle disabled.
   - **Check for device management.** A work profile or MDM enrolment can block it.

   Only after all of those does carrier or SIM locking become the likely explanation, and then this project cannot proceed on that phone.

3. **Unlock the bootloader.** Tell the user in these words: *this erases everything on the phone.* Have them back up anything they care about first.

   ```bash
   adb reboot bootloader
   fastboot flashing unlock
   ```

   **Tell the user to press Volume-Up to highlight "Unlock the bootloader", then Power to confirm.** The phone factory-resets and reboots. They must walk through Android setup again and re-enable USB debugging.

4. **Install Magisk.** Step 3 factory-reset the phone, so the Magisk app is gone with everything else. `stage` reinstalls it before doing anything else: it downloads Magisk 29.0 from the official release, verifies it, installs it over ADB, and confirms the version on the phone. Do not sideload a Magisk build from anywhere else.

   What "verifies" means here, precisely, because it is easy to overstate:

   | Check | What it establishes |
   |---|---|
   | Pinned size and SHA-256 of the whole APK | Every byte matches the official asset. This is the primary protection. |
   | PKCS#7 signature over `META-INF/CERT.SF`, and `CERT.SF`'s digest of `MANIFEST.MF` | The key owning the printed certificate (`CN = John Wu`) really signed this archive's manifest — not merely that its certificate is embedded. |
   | Pinned certificate fingerprint | That signer is the expected publisher. |
   | `adb install -r` succeeds | Android refuses to replace a package signed by a different key, so the app already on the phone shares that signer. |

   It does **not** re-hash all ~1000 entries, and it does not read the v2/v3 APK Signing Block that Android itself verifies (this APK declares `X-Android-APK-Signed: 2`). Entry-level tampering is caught by the pinned whole-file checksum, which runs first — not by the signature check. For complete verification, `apksigner verify --print-certs` is the right tool; it needs a JRE, which Phase 0 does not otherwise require, so it is left as an optional manual cross-check.

   This writes a boot partition, so it runs through a script with the same gates as every other write in this project rather than as loose commands. Nothing to download by hand: the only supported source for the stock boot image is Google's official factory archive for `QP1A.191005.007.A3`, and the script has both the `dl.google.com` URL and the SHA-256 Google publishes beside it built in. Do not pass a `boot.img` from anywhere else — there is no option to, because no published checksum can authenticate a bare member somebody else extracted.

   ```bash
   cd Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts
   ./install-magisk-boot.sh stage --workspace "$HOME/pixel-nas-build-workspace"
   ```

   **Tell the user:** this downloads about 1.4 GB and takes several minutes on a typical link. Do not touch the phone. An interrupted download resumes on the next run; it is not restarted from zero. The archive is cached under `<workspace>/factory/`, so a second run does not download it again. About 3 GB of free disk is needed in the workspace.

   If the archive is already on the machine, point at it with `--factory-zip /path/to/<device>-qp1a.191005.007.a3-factory-<hash>.zip`. That only skips the download; the file is still checked against the same pinned size and checksum, so a copy from anywhere other than Google is refused.

   `stage` verifies codename, build, Android version and slot; verifies the factory archive against the size and checksum Google publishes and extracts `boot.img` itself; authenticates that image as a real boot image for this device and build; **records** any pre-existing patched images without deleting them; and pushes `boot.img` for patching.

   **Tell the user:** unlock the screen, open the Magisk app, then *Install → Select and Patch a File → `/sdcard/Download/boot.img`*. Nothing to press on the bootloader yet.

   ```bash
   ./install-magisk-boot.sh flash --workspace "$HOME/pixel-nas-build-workspace"
   ```

   The first run refuses and prints the required token plus the recovery command. `flash` re-verifies the stock checksum, resolves **exactly one** patched image on the device and stops if there are none or several, refuses an image identical to the stock one, re-reads Fastboot `product`, `current-slot` and `unlocked` and compares them programmatically, checks the image fits the partition, writes `boot_$slot` explicitly, and verifies root afterwards. On any failure it prints the recovery command.

   **Have the user record the recovery command off the host before authorising**, then rerun with `--confirm-flash 'FLASHBOOT:<device>:<slot>:<hash>'`.

   The recovery command is `install-magisk-boot.sh rollback`, which re-verifies the retained stock checksum, re-authenticates the image, re-reads Fastboot product and unlock state, and needs its own `ROLLBACK:` token. A raw `fastboot flash` line is printed underneath it as a last resort only; prefer the gated command.

   Rollback deliberately does **not** require Fastboot's current slot to match the slot it targets. After a bad boot the bootloader may have failed over to the untouched slot, which is exactly when rollback runs; it prints a `NOTE:` about the mismatch and continues, because the write names `boot_<slot>` explicitly and cannot reach the other slot. `flash` keeps the strict check. This follows the deployment policy in [`action-plan.md`](action-plan.md): *do not rely on Fastboot current-slot after a failed boot*.

   **This is the one moment in the whole procedure where the user must touch the phone.** After the write, the phone reboots and the script waits for root. The first `su` raises a Magisk dialog. Tell the user, in these words: *unlock the screen, and when Magisk asks to grant Superuser access to "Shell", press Grant.* The wait is bounded at about three minutes and then fails with instructions; it does not hang.

5. **Re-verify** with the block at the top of this section. `su -c id` must return `uid=0(root)`.

Only then does the `want_initramfs` gate in section 5 make sense: that string exists because Magisk hexpatched the kernel, so it is also a check that step 4 genuinely worked.

## 4. Phase 1 — host

```bash
for t in adb fastboot; do command -v $t; done
```

If missing, do **not** rely on `setup-host-ubuntu-20.04.sh` alone — its `apt-get` needs sudo, which will fail in the harness. Install without sudo:

```bash
cd ~ && mkdir -p .platform-tools-dl && cd .platform-tools-dl
curl -fsSL -o pt.zip https://dl.google.com/android/repository/platform-tools-latest-linux.zip
unzip -q pt.zip
mkdir -p ~/.local/bin
mv platform-tools ~/.local/share-platform-tools
ln -sf ~/.local/share-platform-tools/adb ~/.local/bin/adb
ln -sf ~/.local/share-platform-tools/fastboot ~/.local/bin/fastboot
export PATH="$HOME/.local/bin:$PATH"
```

This is also *better* than the apt route: Ubuntu 20.04 ships adb 1:8.1.0 (2018-era), which is a poor choice for flashing a Pixel.

**Only if `adb devices` reports `no permissions`**, ask the user to run in a real terminal:

```text
sudo apt-get install --no-install-recommends android-sdk-platform-tools-common
```

Never suggest `sudo adb`.

## 5. Phase 2 — build

```bash
cd ~/pixel-nas-kernel-work/Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts
./build-kernel.sh --workspace "$HOME/pixel-nas-build-workspace" --jobs "$(nproc)"
```

Run it in the harness's background mode, never `nohup ... &`. Tell the user ~35 minutes on 4 cores. Do not pipe through `tail`.

Success looks like:

```text
kernel_release=3.18.137-nas1+
Image  Image.lz4-dtb  kernel.config  defconfig  source-lock.env  build-manifest.txt  SHA256SUMS
```

## 6. Phase 3 — verify the phone

Tell the user: plug in the phone, unlock the screen, approve the RSA prompt if it appears.

```bash
adb devices
adb shell getprop ro.product.device      # marlin or sailfish
adb shell getprop ro.build.id            # must be exactly QP1A.191005.007.A3
adb shell getprop ro.boot.slot_suffix
adb shell su -c id                       # uid=0(root)
adb shell su -c 'ls -l /data/adb/magisk/magiskboot'
```

Then the gate that decides whether packaging can run at all. **Do not grep the raw partition** — the kernel is LZ4-compressed and you will get a false zero:

```bash
adb shell "su -c 'set -e
W=/data/local/tmp/precheck; rm -rf \$W; mkdir -p \$W; cd \$W
SLOT=\$(getprop ro.boot.slot_suffix)
dd if=/dev/block/bootdevice/by-name/boot\$SLOT of=boot.img bs=4096 2>/dev/null
/data/adb/magisk/magiskboot unpack boot.img
echo -n \"want_initramfs: \"; grep -ac want_initramfs kernel
echo -n \"skip_initramfs: \"; grep -ac skip_initramfs kernel
cd /; rm -rf \$W'"
```

Required: `want_initramfs: 1`, `skip_initramfs: 0`. Anything else means the phone is not in the Magisk-patched state `device-package.sh` requires, and it will refuse.

## 7. Phase 4 — package

```bash
./device-deploy.sh prepare --workspace "$HOME/pixel-nas-build-workspace" --device auto
```

Reads only. Tell the user not to press anything.

It prints a **rollback token and command — have the user record them off the machine** (phone photo, paper). On this hardware the no-op repack came back byte-identical to the original boot image, which is a stronger result than the script requires.

## 8. Phase 5 — flash

**Run `test` first. Always.** Do not skip to an untested flash.

On this hardware `fastboot boot` is refused for every image, so `test` fails and records `test-unsupported.env` as proof of a bootloader limitation. Only that file unlocks `--confirm-untested`.

This distinction matters: a custom image that **boots but fails validation** (no `-nas1`, no NFS/CIFS, lost root) produces no evidence and must never be flashed. `test` enforces that; do not attempt to work around it. Branch B of the deployment policy in [action-plan.md](action-plan.md) is the normative statement.

Phone must be **in Android**, not the bootloader. Tell the user: *do not press anything, the script reboots the phone itself.*

```bash
./device-deploy.sh flash --workspace "$HOME/pixel-nas-build-workspace" \
  --device <device> --data-backup-confirmed \
  --confirm-flash 'FLASH:<device>:<slot>:<hash>' \
  --confirm-untested 'UNTESTED:<device>:<slot>:<hash>'
```

Both tokens come from the scripts. The untested path re-verifies the rollback image against the live partition before writing and prints the recovery command on any failure.

Verify: `uname -r` contains `-nas1`, root still works, `nfs` and `cifs` in `/proc/filesystems`.

## 9. Phase 6 — NAS discovery

Do this from the Ubuntu host before touching the phone. No credentials needed for protocol probing.

Check ports 445, 139, 111, 2049. If `smbclient` is absent and sudo is unavailable, probe SMB dialects with a raw `python3` socket — the decisive question is whether the server accepts **SMB 3.0**, since this kernel maxes at 3.02 and has no transport encryption.

For NFS, query mountd's real TCP port from portmapper, not 2049. An empty export list with `accept_stat=0` means genuinely no exports configured.

With `smbclient`, keep credentials out of `ps` by using an auth file:

```bash
umask 077; printf 'username = %s\npassword = %s\n' USER PASS > auth
smbclient -L //NAS -A auth
```

**Share enumeration is not access.** Test each share with `-c ls` and confirm denials on the ones that should be denied. Test write refusal explicitly with `put`.

## 10. Phase 7 — mount, and the rule that makes it usable

Config lives outside the integrity-covered directory:

```bash
mkdir -p ../pixel-nas-operator-config
cp nas-mount-smb-ro.conf.example ../pixel-nas-operator-config/nas-mount.conf
chmod 0600 ../pixel-nas-operator-config/nas-mount.conf
```

Set `NAS_HOST` (numeric IPv4 only — this CIFS client cannot resolve names), `SMB_SHARE`, `SMB_USER`, and optionally `SMB_PREFIX_PATH` to narrow the mount to one directory below the share. Prefer the narrow mount.

```bash
./test-nas-mount.sh ../pixel-nas-operator-config/nas-mount.conf \
                    ../pixel-nas-operator-config/nas-smb.secret
```

**Then install the SELinux module before the persistent service.** Without it the mount dies on the first doze cycle and never recovers.

Expect the harness to block this. Give the user:

```text
! cd ~/pixel-nas-kernel-work/Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts && ./install-sepolicy-module.sh
```

Then `./install-nas-service.sh <conf> <secret>`, and **reboot twice** — on FBE the rule only takes effect on the second boot. Judging after one reboot will make a working module look broken.

Acceptance, both zero across a deliberate Wi-Fi teardown:

```bash
adb shell "su -c 'dmesg | grep -c \"denied { net_raw }\"'"
adb shell "su -c 'dmesg | grep -c \"Error -13 creating socket\"'"
```

Retire any other CIFS module: `touch /data/adb/modules/<id>/remove`, then reboot.

## 11. Phase 8 — Google Photos

Nothing is copied to the phone. `96-nas-photos.sh` mounts the share where Photos
can see it and keeps MediaStore informed; Photos uploads in place from the NAS.
Reachability uses a separate short health cadence and is also checked during a
long media scan. New candidates must remain size/mtime-stable before they are
offered to MediaStore.

```bash
cd Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts
cp nas-photos.conf.example ../pixel-nas-operator-config/nas-photos.conf
chmod 0600 ../pixel-nas-operator-config/nas-photos.conf \
  ../pixel-nas-operator-config/nas-smb.secret
# Edit nas-photos.conf, then install both configuration and credential.
./install-nas-photos.sh ../pixel-nas-operator-config/nas-photos.conf \
  ../pixel-nas-operator-config/nas-smb.secret
```

The installer validates all local inputs before changing the phone. It streams
the configuration and secret to root-only `.new` files, checksum-verifies the
staged configuration, secret, and service, then activates each with an atomic
rename. Never replace those protected files with an `adb push` to
`/data/local/tmp`.

**Prerequisite the user must accept:** the phone must have **no screen lock**.
`/storage/emulated/0` is credential-encrypted, so with a lock set user 0 stays
`RUNNING_LOCKED` after every reboot and the mount cannot be made until someone
types the PIN. Say this plainly; it is a security trade-off, and it is theirs.

The SELinux rule the mount needs ships in `install-sepolicy-module.sh`. On a
new policy-module install, `/data` FBE means Magisk cannot stage that rule for
pre-init until the first reboot, so **reboot twice** before judging the policy.
If the module is already active and only the photo service or configuration
changed, this two-reboot requirement does not apply; restart exactly one
service process for a non-reboot check, then repeat the checksum-specific
reboot matrix when the operator approves it.

Verify, in this order:

```bash
adb shell "su -c 'grep -c \"NAS-Live cifs\" /proc/mounts'"          # expect 5, one per view
adb shell 'ls /storage/emulated/0/DCIM/NAS-Live | wc -l'
adb shell content query --uri content://media/external/images/media \
  --projection _id --where "\"_data LIKE '%NAS-Live%'\""
adb shell "su -c 'cat /data/adb/nas-photos.log'"
```

**Tell the user:** in Google Photos, enable backup for the folder under *Photos
settings → Backup → Back up device folders*. If it is not listed — Photos 7.85
often does not list it — enable **Back up all device folders**. Confirm the
quality setting is **Original**; that is the entire premise of using this phone.

Proof of upload is not "the folder appeared". Stop Photos briefly so its
database and WAL form a stable snapshot, then stream the snapshot to the host.
Do not leave the app database in `/data/local/tmp`:

```bash
adb shell am force-stop com.google.android.apps.photos
adb exec-out "su -c 'cd /data/data/com.google.android.apps.photos/databases && tar -czf - gphotos0.db*'" >gphotos-db.tar.gz
mkdir -p gphotos-db
tar -xzf gphotos-db.tar.gz -C gphotos-db
sqlite3 gphotos-db/gphotos0.db \
  'SELECT lm.dedup_key, bis.state, bis.media_key_on_upload
     FROM local_media AS lm
     JOIN backup_item_status AS bis USING (dedup_key)
    WHERE bis.state = 1 AND length(bis.media_key_on_upload) > 0;'
rm -rf gphotos-db gphotos-db.tar.gz
adb shell monkey -p com.google.android.apps.photos 1
```

The query requires host `sqlite3`. A returned row with `state` 1 and a non-empty
`media_key_on_upload` means the server accepted it. Items with no row but a
matching `remote_media` entry were deduplicated because that content is already
in the library — not failures. Corroborate with per-uid transmitted bytes; bytes
sent close to bytes on the share indicates original quality rather than
re-encoding.

Expect a full re-index after every reboot: MediaProvider prunes rows for files
that were not mounted during its boot scan. That costs about a second per file
at the default pace and triggers no re-upload.

## 12. State reached on 2026-08-02

Working and persistent across reboots: custom kernel `3.18.137-nas1+` with Magisk root; QNAP subdirectory mounted read-only over SMB 3.0, auto-mounting ~55 s after boot and surviving Wi-Fi teardown; one photo uploaded to Google Photos at original quality.

Also proven: boot with the NAS powered off completes in about 30 seconds, the service fails inside its bounded wait without blocking boot, and leaves no mount behind. The direct mount is proven too: from a clean install and one reboot the phone booted unlocked in 33 s, mounted in 15 s, re-indexed 100 files, and Google Photos uploaded them at original quality with nothing copied to internal flash.

Not yet proven: rollback (image verified and preserved, never exercised); NFSv3 against a real export; long-term mains-powered behaviour with the runtime-view mount in place.

## 13. Reliability qualification

After changing any installed kernel, policy, mount service, mount path, network
handling, or scanner behavior, execute
[`reliability-test-plan.md`](reliability-test-plan.md). Its reboot-required group
runs first because this environment requires the operator to reconnect the Pixel
USB device to VMware after each reboot. Complete the non-reboot NAS/Wi-Fi fault
tests next, then run the powered overnight continuity/thermal soak. The
supported appliance is continuously mains-powered; do not add an unpowered
natural-Doze gate.
