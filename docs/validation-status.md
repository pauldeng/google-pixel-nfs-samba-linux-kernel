# Validation status

Verified locally on 1 August 2026:

- exact repository origins, peeled refs, commits, and tree objects;
- complete out-of-tree kernel build with the locked GCC 4.9 toolchains;
- `Image`, `Image.lz4-dtb`, configuration, manifest, and artifact checksums;
- incremental rerun using existing local downloads without an unnecessary fetch;
- isolated local imports that leave supplied repository status and worktree metadata unchanged;
- a network-only fresh shallow-clone source-preparation run using `--no-local-autodetect --sources-only`;
- `shfmt` v3.13.1 shell formatting, ShellCheck v0.11.0 static analysis, and `rumdl` v0.2.47 Markdown formatting/linting;
- Bash/POSIX shell syntax and executable modes for the separated scripts;
- Bash/Dash regression coverage for conditional functional-probe failures;
- companion `SHA256SUMS` coverage and verification.

The successful build reported kernel release `3.18.137-nas1+`. The trailing `+` is expected for this clean detached Git worktree; acceptance requires the `-nas1` marker.

Validated on hardware 2026-08-02 (Pixel / sailfish):

- custom kernel flashed to the active slot; `uname -r` reports `3.18.137-nas1+` with Magisk root intact;
- QNAP `Multimedia/Photo/...` mounted read-only over SMB 3.0 at a root-only path, reads byte-identical to the NAS copy, writes refused;
- mount returns automatically about 55 seconds after boot and survives a full Wi-Fi teardown;
- a staged photo reached Google Photos at original quality;
- boot with the NAS powered off: boot completed in 30 s, the service failed cleanly inside its bounded wait, left no mount behind, and the phone was fully usable;
- mount recovery once the NAS returned, in 1.08 s;
- retry behaviour against an unreachable address: three bounded attempts in 29.8 s then a clean give-up, while a genuine misconfiguration was refused immediately rather than retried.

Established as unsupported (a proven negative, not a gap): `fastboot boot` is refused for every image on bootloader 8996-012001-1908071822, verified across four Fastboot releases. See 8.3.1.

Proven on hardware on 2026-08-02, Pixel (`sailfish`), Android 10 `QP1A.191005.007.A3`, kernel `3.18.137-nas1+`, Magisk 29.0, QNAP over SMB 3.0:

- the read-only NAS share mounted into the Photos runtime view, propagating to all four `/mnt/runtime` views and `/storage/emulated`;
- 100 files (88 images, 12 videos, 5.4 GB) visible to Google Photos and present in MediaStore;
- Google Photos uploaded them at original quality, confirmed from its own `backup_item_status` rows carrying server media keys, with items already in the library deduplicated rather than re-uploaded;
- nothing copied to internal flash, `/data` usage unchanged;
- from a clean install and one reboot: booted unlocked in 33 s, mounted in 15 s, re-indexed all 100 files, zero SELinux denials, zero re-upload;
- protective behaviour with the NAS blackholed: the share is unmounted after confirmed unreachability and `ls /storage/emulated/0/DCIM` stays healthy, recovering when the NAS returns.
- the hardened service was installed and checksum-verified without rebooting, then completed a controlled unmount/remount in init's namespace; all five propagated views returned, the app-visible tree contained 100 files, MediaStore contained 88 image and 12 video rows, and Photos' own mount namespace contained all five entries;
- a write through the app-visible path was refused and left no marker; a populated disposable mount target was preserved and not covered; and a simulated MediaStore query failure created no persistent refusal state;
- the documented compressed Photos-database snapshot completed against the real 525 MB database, its required tables and columns were present, and the upload-evidence query returned 101 accepted rows. Photos was restarted and the host snapshot was removed afterward.

Reboot-first reliability qualification ran on 2026-08-02 and 2026-08-03
against installed service SHA-256
`7707d1764d620d2edaa1e4a8355e8538d2742ad0110774912dfd7e45cf55f629`:

- with NAS and Wi-Fi available, Android completed boot normally, exactly one
  service mounted all five read-only views 15 seconds after service start, and
  MediaStore returned to 88 image and 12 video rows after the paced 100-file
  scan;
- with the NAS off, Android and root returned in about 30 seconds, the service
  remained alive without a mount, its initial readiness wait ended after 61
  seconds, and DCIM remained responsive. After the NAS was turned on, the same
  process mounted all five views automatically and restored all MediaStore
  rows;
- with Wi-Fi disabled across reboot, Android and root returned in about 34
  seconds with one service, no mount, and responsive DCIM. Enabling Wi-Fi
  restored SMB reachability in 14 seconds; the unchanged service remounted all
  five views automatically and restored MediaStore;
- after an approved clean power-off and physical cold start, boot completed,
  the service mounted all five views in 15 seconds, and the scan completed at
  uptime 183 seconds with 100 indexed files and zero skips. The service and
  secret remained root-owned with modes 0755 and 0600 respectively, the
  installed checksum still matched, Photos' restarted process saw all five
  mounts, the write probe was rejected without leaving a marker, no temporary
  snapshot or `.new` file remained, and the Photos database still contained
  101 accepted-upload rows;
- every final state contained exactly one service and five CIFS views with the
  expected source, read-only mode, and media SELinux context. No NAS-specific
  AVC, `Error -13 creating socket`, or CIFS error appeared.

That checksum exposed a reliability defect. A Wi-Fi teardown while mounted
left stale views in place and a DCIM access blocked until the combined
scan/health loop reached its next 300-second cycle; the measured automatic
unmount occurred after 285 seconds. Wi-Fi restoration similarly waited 292
seconds before the remount attempt even though SMB was reachable after 14
seconds. The behavior was bounded and data-safe, so the reboot cases above
remain passes for that checksum, but it was not acceptable for unattended use.

The defect was corrected and tested without rebooting on 2026-08-03 as service
SHA-256
`0645d2b4674b3efb3b558df6fc51a04686bb10df8555464f3971f32a8b4fa6c7`:

- a 15-second health cadence is independent of the 300-second media discovery
  schedule, and monotonic checks continue through candidate inspection,
  stability waits, MediaStore queries, and long broadcast queues;
- filesystem, `stat`, MediaStore-query, and broadcast calls have explicit
  bounds; new files must retain the same size and mtime for 30 seconds and pass
  the same check immediately before broadcast;
- focused Bash and Dash regressions changed a file during its stability window
  and proved it was deferred without a refusal; separate simulated outages
  interrupted both the stability wait and an active broadcast queue, unmounted
  the share, stopped further broadcasts, and removed their workspaces;
- after replacing exactly one running service process, three real Wi-Fi
  outages automatically unmounted in 24, 23, and 23 seconds instead of 285
  seconds. DCIM was responsive while offline, and the unchanged singleton
  process remounted all five views in 7, 18, and 5 seconds;
- two additional two-second Wi-Fi flaps preserved all five mounts, emitted no
  outage log, and created no second process or stacked mount; and
- the final baseline was one service, five correctly sourced and labelled
  read-only CIFS views, 100 files, 88 image rows, 12 video rows, and five views
  in a restarted Photos process. The write probe was rejected, DCIM remained
  responsive, no scan workspace, refusal state, or `.new` file remained, and
  there was no NAS-specific kernel AVC, CIFS error, or socket denial.

A provisional mains-powered continuity and thermal observation then ran from
00:46:03 to 08:48:09 AEST on 2026-08-03 with that same service checksum and
configuration:

- 97 samples at approximately five-minute intervals covered 28,925 seconds
  (8 h 2 min). Every sample reported one service, five mounts, Wi-Fi enabled,
  responsive DCIM, battery level 100%, and zero anomalies;
- temperature remained between 18.0 and 36.7 °C, and the service log stayed
  exactly 3,468 bytes. The service PID remained `16049`; the end RSS was
  2,104 KiB;
- the phone remained on mains power with the screen off. Spot and end snapshots
  reported `mCharging=true`, `mScreenOn=false`, `mState=ACTIVE`, and
  `mLightState=ACTIVE`, which is the expected charging state and is not a
  battery-powered Doze result;
- the independent end snapshot revalidated the exact CIFS source, all five
  expected targets, `ro` mode, media SELinux context, matching installed
  service checksum, protected-file modes, 100 files, 88 image rows, 12 video
  rows, and five mounts in Photos' process namespace;
- DCIM responded in 139 ms, the root write probe was rejected without leaving
  its marker, no scan workspace, refusal record, staged `.new` file, relevant
  AVC, CIFS error, or socket denial remained; and
- a fresh, stable Photos database snapshot still contained 101 accepted rows
  and 101 distinct upload keys. The temporary 525 MB database and compressed
  host snapshot were removed, Photos restarted, and its new process again saw
  all five mounts.

The mode-`0600` evidence log is retained locally at
`pixel-nas-operator-config/pixel-nas-soak-20260803.log`, an ignored operator
path. This observation passed its continuity and thermal scope. It remains
provisional until the outstanding operator-dependent fault tests pass on the
same kernel, policy, service checksum, and configuration; any resulting repair
invalidates it and requires another soak.

Bulk-test preparation also began without exposing partial files to the phone.
The operator copied into the sibling NAS directory
`Google-Photos-Pixel-Stage-INCOMING`, outside the narrowed phone mount. Three
read-only SMB listings at 08:55:56, 09:00:57, and 09:05:57 AEST were identical:
1,207 files and 35,957,821,786 bytes. This proves ten minutes of aggregate
stability, not source completeness or content integrity. Obtain the source
manifest/checksums and operator copy-success confirmation before any
server-side atomic promotion into the watched tree. No bulk scan or cloud
upload stress has started yet.

These non-reboot results validate the latency fix. They do not substitute for
the reboot-first matrix on the new checksum; repeat that matrix before calling
this exact service fully qualified.

Native battery charge control was implemented and tested without rebooting on
2026-08-03. The implementation uses the existing HTC kernel
`charge_start_level`/`charge_stop_level` algorithm rather than a polling loop or
the generic external-input suspend control:

- the live sailfish baseline exposed writable numeric native parameters at
  `0/100`, reported battery health `Good`, temperature 31.5–32.2 °C, and both
  battery charging and external input enabled;
- the checksum-verified one-shot service applied `30/50`; the kernel then
  reported battery charging disabled while external input remained enabled;
- the installed configuration, service, and log were root-owned at modes
  `0600`, `0755`, and `0600`; device SHA-256 values matched the host, and no
  charge-controller process remained;
- the documented disable path created its protected marker, restored `0/100`,
  and returned battery charging permission to enabled without changing external
  input;
- reinstalling and reapplying `30/50` succeeded; and
- 13 samples over approximately three minutes held `30/50`, health `Good`,
  temperature 29.5–33.2 °C, battery charging disabled, external input enabled,
  zero resident charge-controller processes, NAS service PID `16049`, and all
  five CIFS views. ADB remained connected throughout.

This proves safe application, read-back, disable/restore, and short-term
coexistence with the NAS appliance. It does not yet prove a natural decline to
30%, restart of charging at the lower threshold, or a long-duration thermal
result. Because mains input deliberately remains active,
the battery may stay near the upper threshold for a long time; that is safer
than forcing discharge and must not be misreported as a failed controller.

The operator then explicitly approved one reboot-persistence test. Android and
root returned normally; at uptime 40 seconds the one-shot service had logged a
fresh application of `30/50`, both parameters read back exactly, the installed
hashes and modes still matched, no charge-controller process remained, battery
charging was disabled, and external input remained enabled. The NAS service
returned as PID `932` with all five propagated Android storage views. Kernel
CIFS debug data confirmed those views were one server, one share, and one CIFS
mount—not five independent NAS connections.

The reboot also reproduced the separate thermal workload behavior. The battery
sensor initially reported 63.5–63.7 °C/`Overheat` while Photos rose to about
109% of one CPU core. At the operator's direction Photos was left running. Once
the operator removed the NAS files, Photos fell to approximately 5–8% CPU and
the reported battery temperature fell through 61.5, 59.0, 54.2, 49.0, and
45.5 °C, then remained 35.5–36.2 °C/`Good`. Across the observation the native
limit kept battery charging disabled without suspending mains input, and the
NAS service and views remained stable.

Deleting the files directly on the NAS left no files in the mounted directory
but left 476 image and 36 video MediaStore rows at the measured point. This is
consistent with the established lack of local inotify events for server-side
changes. It is a separate indexing-lifecycle gap: the current scanner discovers
and indexes stable new paths but does not reconcile rows whose remote paths
were deleted during a scan. Do not interpret those rows as remaining NAS files.

Requires no screen lock, because `/storage/emulated/0` is credential-encrypted.

Still unvalidated. These are open items, not mandatory gates for the parts already proven:

- rollback (the image is verified and preserved but has not been exercised);
- NFSv3 against a real export;
- the reboot-first fault matrix for service checksum `0645d2b4...`;
- a graceful NAS shutdown and automatic startup recovery on that checksum;
- SMB-service restart while the NAS host remains reachable, specifically the stale-session case;
- controlled new, replaced, renamed, deleted, and unsupported server-side files;
- bulk media and interrupted-copy stress qualification;
- native battery-threshold behavior across a natural lower-bound transition,
  and a longer powered observation;
- deterministic reconciliation of stale MediaStore rows after server-side
  deletion during an active scan;
- promotion of the provisional powered observation after those short tests pass
  unchanged, followed by longer multi-day observation.

Each remains a gate for the specific capability it covers: do not rely on rollback or NFSv3 until the matching item is exercised.

The required ordering, evidence, stop conditions, VMware USB reconnection steps,
and overnight acceptance criteria are defined in
[`reliability-test-plan.md`](reliability-test-plan.md).
