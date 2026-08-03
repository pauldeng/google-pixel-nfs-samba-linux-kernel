# Reliability qualification plan

This plan qualifies the unattended Google Photos appliance after any change to
the kernel, SELinux policy, photo mount service, mount path, network handling,
or MediaStore scanning. A previous result does not qualify a changed component.

The reboot-required tests run first because the operator must reconnect the
phone's USB device to the VMware guest after every reboot. Non-reboot fault
injection follows, then a powered overnight soak with the phone and NAS left
on. Battery-powered operation and natural Doze are outside the scope of this
dedicated, continuously mains-powered appliance.

## 1. Rules and responsibilities

- The agent records the baseline, issues ADB commands, measures timings, and
  evaluates every acceptance condition.
- The operator reconnects the Pixel USB device to the VMware guest after each
  reboot and reports `connected` only after VMware shows it attached.
- The operator turns the NAS off or on, or restarts its SMB service, only when
  the agent explicitly asks.
- Change one condition at a time. Do not combine a reboot, Wi-Fi transition,
  and NAS transition unless that combination is the named test.
- Do not reboot without explicit operator approval. Approval for one reboot or
  power-off does not authorize later ones.
- Do not write through the phone's photo mount. Controlled photo additions,
  replacements, renames, and deletions happen server-side in the dedicated NAS
  test folder.
- Stop immediately if the photo mount becomes writable, the source or SELinux
  context is wrong, ordinary DCIM access hangs, the phone becomes unusually
  hot, or unrelated media disappears.
- Do not simulate abrupt power loss with SysRq, a kernel panic, forced battery
  depletion, or filesystem corruption. A clean power-off and cold start are
  the safe approximation on a battery-backed phone.

## 2. Evidence captured for every test

Before the first test, record a baseline. After every transition, capture the
same evidence so results are comparable:

- wall-clock and monotonic start/end times;
- `adb devices -l`, boot completion, uptime, device/build, kernel release, and
  Magisk root;
- the `96-nas-photos.sh` process ID and whether more than one copy exists;
- the installed service checksum and the root ownership/mode of its config and
  SMB secret;
- exact NAS mount source, filesystem type, `ro` mode, SELinux context, and the
  number of propagated mount views;
- file count through `/storage/emulated/0/DCIM/<folder>`;
- image and video MediaStore row counts;
- the Google Photos process mount namespace;
- a uniquely named write-rejection marker, followed by proof that it does not
  exist;
- new service-log lines, CIFS errors, SELinux AVCs, and
  `Error -13 creating socket` messages;
- Photos upload evidence and evidence that already uploaded content was not
  duplicated;
- responsiveness of ADB, `/storage/emulated/0/DCIM`, Settings, and Photos.

The present hardware baseline is five propagated mount entries, 100 files,
88 image rows, 12 video rows, and a read-only CIFS source rooted at
`//192.168.0.233/Multimedia/Photo/Google-Photos-Pixel-Stage`. Re-capture rather
than hard-code those counts if the server-side fixture changes.

## 3. Reboot-required qualification — run first

If native battery charge control is installed, every reboot case must also
record both HTC module parameters, battery health and temperature,
`battery_charging_enabled`, and `charging_enabled`. Require the configured
start/stop pair, and require external input to remain enabled. The one-shot
service must not remain as a resident process.

### 3.1 Reboot with NAS and Wi-Fi available

Prerequisites: NAS on, SMB available, phone Wi-Fi connected, mount healthy, and
no active test-file mutation.

1. Capture the complete baseline and current log endpoint.
2. Ask for explicit permission for this reboot.
3. The agent issues the reboot. The operator does not press phone buttons.
4. The operator reconnects the Pixel USB device to VMware and reports
   `connected`.
5. Measure boot completion, root availability, service start, mount creation,
   MediaStore restoration, and Photos namespace visibility.
6. Wait for the service's paced re-index cycle before judging MediaStore.
7. Compare upload evidence with the pre-reboot snapshot.

Acceptance:

- Android boots normally and ADB/root return without manual phone interaction;
- exactly one persistent photo service is running;
- the mount returns automatically with the expected source, CIFS type, `ro`
  mode, and media SELinux context;
- all five propagated views, the baseline file count, and MediaStore counts
  return within the documented bounded startup/re-index period;
- Photos' post-reboot process namespace sees the mount;
- a write remains rejected;
- no new broad SELinux denial, reconnect error, duplicate upload, stale test
  workspace, or credential-permission regression appears.

### 3.2 Reboot with NAS unavailable, then recover

1. Start from a healthy mounted baseline.
2. Ask the operator to shut the NAS down and wait for confirmation that it is
   fully off.
3. Confirm port 445 is unreachable and the service has removed the mount.
4. Confirm ordinary DCIM access remains responsive.
5. Ask for explicit permission for this reboot.
6. Reboot; the operator reconnects the Pixel USB device to VMware and reports
   `connected`.
7. Verify boot completion and root before the NAS is turned on.
8. Confirm the service is alive and retrying, no NAS mount exists, and DCIM,
   Settings, Photos, and ADB remain responsive.
9. Ask the operator to turn the NAS on.
10. Without restarting the phone or service, wait through the configured retry
    interval and measure automatic recovery.

Acceptance:

- an unavailable NAS does not delay Android boot or ADB/root availability;
- no stale or partial mount exists while the NAS is off;
- DCIM remains responsive and unrelated local media remains visible;
- the service keeps retrying according to policy without process multiplication
  or unbounded log spam;
- after the NAS returns, one correct read-only mount propagates to all views,
  file and MediaStore counts recover, and Photos sees the folder;
- recovery does not require manual service restart and causes no duplicate
  upload.

### 3.3 Reboot with Wi-Fi disabled, then recover

1. With the NAS on, disable Wi-Fi and confirm the mount is removed.
2. Ask for explicit permission for this reboot.
3. Reboot with Wi-Fi still disabled; the operator reconnects USB to VMware and
   reports `connected`.
4. Verify boot completion, root, service liveness, absence of the NAS mount, and
   responsive DCIM.
5. Enable Wi-Fi through ADB without restarting the service.
6. Measure association, port reachability, mount recovery, propagation,
   MediaStore recovery, and Photos visibility.

Acceptance is the same as 3.2, with Wi-Fi restoration—not NAS startup—as the
only recovery trigger.

### 3.4 Clean power-off and cold start

This approximates restoration after external power loss without deliberately
corrupting Android storage. Because the Pixel has a battery, removing its
charger is not an abrupt power-loss test.

1. Restore the normal NAS-on, Wi-Fi-on, healthy baseline.
2. Ask for explicit permission to power the phone off.
3. The agent issues a clean power-off and waits for ADB to disappear.
4. The operator presses Power once to start the phone, reconnects its USB device
   to VMware, and reports `connected`.
5. Repeat every acceptance check from 3.1, including checksum, credential mode,
   service cardinality, propagation, MediaStore, Photos, and write rejection.

Any configuration truncation, `.new` file left behind, refusal-state corruption,
or failure to start without unlocking is a hard failure.

## 4. Non-reboot network and NAS fault injection

Run these only after Section 3 passes and the phone is back at a healthy
NAS-on/Wi-Fi-on baseline.

### 4.1 Wi-Fi off and on while mounted

The agent disables Wi-Fi through ADB, measures the three-probe confirmation and
unmount, checks DCIM responsiveness, then enables Wi-Fi and measures automatic
remount. Repeat two more times to expose races and mount stacking.

Each cycle must leave exactly one service, zero mounts while offline, exactly
five propagated entries after recovery, no marker from the write probe, and no
new refusal record caused solely by the outage.

### 4.2 NAS graceful shutdown and startup while mounted

The operator shuts the NAS down only when prompted. Measure how long a normal
filesystem access, reachability confirmation, and unmount take. The agent must
remain able to list ordinary DCIM and use ADB. The operator then starts the NAS;
the existing service must recover without being restarted.

Record whether normal `umount` or lazy unmount was required. Any unbounded
unmount or DCIM hang is a reliability failure even if the next remount succeeds.

### 4.3 SMB-service restart with NAS host still reachable

If QNAP permits it, the operator restarts only the SMB service while the NAS
host and Wi-Fi remain reachable. This is distinct from powering the NAS off:
port 445 can return while the old kernel CIFS session remains stale.

Acceptance requires either transparent CIFS reconnection or a bounded discard
and remount. If TCP is reachable but mounted-path I/O repeatedly fails while the
service merely logs scan errors, stop the campaign and harden the service with
a consecutive filesystem-failure recovery policy before the overnight soak.

### 4.4 Short network flapping

Perform two controlled Wi-Fi off/on cycles separated by less than one scan
interval, then one longer outage that crosses the confirmation threshold.

- Short transient loss must not tear down a healthy mount prematurely.
- Confirmed loss must unmount it.
- Recovery must never stack mounts, start extra service processes, leak scan
  workspaces, or make the mount writable.

## 5. Android service and indexing resilience

### 5.1 Photos process restart

Force-stop and restart Google Photos without changing the mount. Its new PID's
mount namespace must contain all propagated views. The folder, MediaStore rows,
and prior upload state must remain intact.

### 5.2 MediaProvider failure and recovery

Exercise a failed `content query` and, separately where a controlled new test
file is available, a failed scan broadcast. A failed query or undelivered
broadcast must not increment persistent refusal state. The next healthy cycle
must retry the file.

### 5.3 Controlled server-side media changes

Use disposable files in the dedicated NAS test folder:

1. add one image and one video at the top level;
2. add one image in a nested directory;
3. add an unsupported sidecar or text file;
4. replace a refused test file at the same path with changed size or mtime;
5. rename and then delete only these disposable server-side files.

Supported files must receive MediaStore rows and upload once. The unsupported
file must stop being rebroadcast after the configured limit. Replacing it must
reset the refusal count. Renames/deletions must eventually converge without
changing unrelated NAS or cloud content.

### 5.4 Bulk media and interrupted-copy stress

This test is worth running because it exercises scanner duration, memory and
state growth, MediaStore pacing, duplicate suppression, video reads, and
recovery during active indexing. Run it only with a disposable, uniquely named
fixture whose manifest and checksums were captured before it enters the watched
tree.

Use approximately 1,000 representative files: images and videos, nested
directories, one large video, names containing spaces and Unicode, unsupported
sidecars, and a small controlled set of duplicate-content files. Prefer copying
the fixture to a server-side sibling staging directory and atomically renaming
the completed directory into the watched tree. That is the safe operating
pattern and prevents MediaStore from observing half-written files.

Exercise incomplete-file handling separately with one disposable large video
copied slowly directly into the watched tree. The service must not permanently
index the partial version. It must wait for stable size and mtime, or detect the
later change and rescan the completed file. Remove only that disposable case
after recording the result.

During a long scan, perform one short Wi-Fi interruption. Reachability checks
must continue during indexing; the one-file-per-second scan must not postpone
health handling until the entire queue completes. With 1,000 files the serial
scan takes at least 17 minutes, so this test must prove that the interleaved
monotonic health checks preserve the shorter outage bound throughout that
backlog.

Acceptance requires:

- manifest file counts and checksums remain unchanged on the read-only client;
- every supported stable file receives the correct MediaStore row and is
  offered to Photos once, while unsupported files converge to bounded refusal
  state;
- no partial file remains indexed after the server copy completes;
- duplicate content does not cause unexplained duplicate cloud uploads;
- Wi-Fi loss is detected and handled within the health bound even while the
  scan backlog is non-empty;
- memory, process count, temporary workspaces, refusal-state size, service-log
  growth, mount count, and DCIM responsiveness remain bounded; and
- removal of the disposable fixture converges without changing unrelated NAS
  or cloud content.

### 5.5 Process and state hygiene

Verify recovery after deliberately stopping the service and starting exactly
one replacement. Confirm that a pre-existing foreign mount and a populated
local target are refused and preserved. Confirm no test leaves behind:

- additional `96-nas-photos.sh` processes;
- `nas-photos-scan.*` workspaces;
- `.new` state files;
- disposable marker files or directories;
- host-side Photos database snapshots;
- secrets in `/data/local/tmp`, logs, process output, or tracked files.

## 6. Powered overnight continuity and thermal soak

Prefer to start after every short fault test passes and the normal mounted
state is restored. If operator-dependent fault injection is still pending, a
stable system may be observed overnight first, but label that evidence
provisional. It becomes qualifying evidence only if the remaining short tests
pass with the exact same kernel, policy, service checksum, and configuration.
Any resulting repair or relevant configuration change invalidates the earlier
soak and requires it to be repeated.

Leave the phone for 8–12 hours with:

- NAS and SMB service on;
- Wi-Fi on;
- phone connected to a reliable charger on a ventilated, nonflammable surface;
- screen off;
- Google Photos running normally;
- device-idle and battery-optimization settings unchanged;
- ADB connected if convenient, but not required.

Do not leave a swollen, damaged, or unusually hot battery unattended.

Capture a start snapshot, then an end snapshot containing uptime, service PID,
mount entries, counts, Photos namespace, upload state, service-log delta,
`dumpsys deviceidle`, Wi-Fi state, battery/thermal state, CIFS messages, and
SELinux denials.

For a read-only five-minute continuity/thermal sample throughout the interval,
run the separate host helper and keep its output in the ignored operator
evidence directory:

```bash
tools/monitor-nas-photos-soak.sh <adb-serial> 8 300 \
  pixel-nas-operator-config/pixel-nas-soak-YYYYMMDD.log
```

The helper refuses to overwrite evidence, checks that the installed service
matches the repository copy, verifies root ownership and mode `0600` for the
configuration and secret, and validates all five exact mount targets on every
sample. It also detects a changed service PID, unresponsive DCIM, loss of
charging, a lit screen, a non-`ACTIVE` charging idle state, temperature above
45 °C, service RSS above 32 MiB, log truncation, or more than 1 MiB of log
growth. The last three limits can be tightened for a campaign with
`MAX_TEMP_TENTHS_C`, `MAX_SERVICE_RSS_KIB`, and `MAX_LOG_GROWTH_BYTES`.

Record `mCharging`, `mScreenOn`, `mState`, and `mLightState` from
`dumpsys deviceidle`. `mCharging=true`, `mScreenOn=false`, and
`mState=ACTIVE` are expected for the supported deployment. Do not describe a
charging run as a Doze test. Frequent ADB polling is acceptable for a monitored
continuity run, but record the polling interval because it adds wakeups.

Acceptance:

- no reboot, service exit, duplicate service, stale mount, or DCIM hang;
- mount remains read-only and usable, or recovers automatically from a measured
  Wi-Fi interruption;
- file and MediaStore counts remain consistent;
- no `net_raw`, `associate`, or unexpected app-domain AVC denial;
- no repeating CIFS reconnect storm or unbounded log growth;
- Photos retains visibility and does not duplicate accepted uploads;
- device temperature and charging behaviour remain normal.

Longer multi-day observation remains advisable after the first overnight pass.

## 7. Result classification

- **Pass:** every required observation is present and no stop condition occurs.
- **Conditional pass:** the behavior is safe but a documented timing threshold
  needs adjustment; repeat the affected test after changing it.
- **Fail:** wrong/writable mount, stale session without recovery, hung DCIM,
  missing automatic restart, permanent refusal after a transient failure,
  duplicate upload, credential exposure, broad SELinux change, or unexplained
  data loss.
- **Not tested:** operator action, elapsed soak time, or required evidence was
  unavailable. Never report this as a pass.

Record successful evidence and remaining gaps in
[`validation-status.md`](validation-status.md). A reboot-era result is valid
only for the exact installed service checksum that was tested.
