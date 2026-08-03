# Battery charge control

This feature is optional. Before every installation or change, ask the operator
whether to enable it. If it is already installed, read back and report the
current values, then ask whether to keep, change, or disable them. Never infer
consent merely because the phone stays on mains power.

For an enable/change decision, ask for both values in plain language:

- **upper/full capacity**: the percentage at which battery charging stops
  (`CHARGE_STOP_PERCENT`), default **50%**;
- **lower/low capacity**: the percentage at which charging may resume
  (`CHARGE_START_PERCENT`), default **30%**.

If the operator declines or does not answer, do not install, change, or disable
anything. Leave the phone's current charging behavior unchanged.

The first-generation Pixel kernel in this project already contains HTC's
native charge-start/charge-stop hysteresis. The supported controller configures
that kernel facility once at boot; it does not poll battery state, replace the
OEM charger state machine, or suspend external input.

This is the stability-first behavior for a mains-powered appliance:

- At or above `CHARGE_STOP_PERCENT`, the kernel adds its manufacturing charge
  disable reason and stops charging the battery.
- Above `CHARGE_START_PERCENT`, it keeps that reason active.
- At or below `CHARGE_START_PERCENT`, it removes only that reason. Temperature,
  charger, battery-ID, over-voltage, and other OEM safety reasons still decide
  whether charging is actually permitted.
- Mains input remains enabled. The phone may therefore stay near the upper
  threshold for a long time rather than deliberately discharging to the lower
  threshold. The lower threshold controls when charging may resume after
  natural discharge or a power interruption.

The implementation never writes the generic `charging_enabled` input-suspend
control. Forcing that control off would make the phone run from its battery
while plugged in and would turn a controller failure into an avoidable shutdown
risk.

## Configure and install

Continue only after the operator has explicitly opted in and selected the two
thresholds. The 30/50 values below are recommendations, not implied consent.

Keep the live configuration in the ignored operator directory:

```bash
cp Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/battery-charge-control.conf.example \
  pixel-nas-operator-config/battery-charge-control.conf
chmod 0600 pixel-nas-operator-config/battery-charge-control.conf
```

The default example is:

```text
CHARGE_START_PERCENT=30
CHARGE_STOP_PERCENT=50
```

Install without changing the current Android session:

```bash
Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/install-battery-charge-control.sh \
  pixel-nas-operator-config/battery-charge-control.conf
```

Install and apply immediately without rebooting:

```bash
Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/install-battery-charge-control.sh \
  --apply-now pixel-nas-operator-config/battery-charge-control.conf
```

The installer accepts only one authorised ADB device, Magisk root, a supported
Pixel codename, and build `QP1A.191005.007.A3`. It validates the configuration
before touching the phone, stages root-owned files, verifies their SHA-256
checksums, and atomically activates them. An interrupted install leaves a
disable marker, so a partial update cannot run at the next boot.

No kernel rebuild is required. `97-battery-charge-control.sh` is a one-shot
Magisk `service.d` script: it applies the two values and exits. The kernel owns
the continuing hysteresis.

## Change thresholds

Edit the external configuration and rerun the installer with `--apply-now`.
No reboot is required. Validation requires:

- integer values only;
- start from 10 through 80;
- stop from 20 through 90;
- start lower than stop; and
- at least five percentage points between them.

Unknown, duplicate, malformed, or shell-like values are rejected without
writing either kernel parameter.

## Verify

```bash
adb shell su -c 'cat /sys/module/htc_battery/parameters/charge_start_level'
adb shell su -c 'cat /sys/module/htc_battery/parameters/charge_stop_level'
adb shell su -c 'cat /sys/class/power_supply/battery/battery_charging_enabled'
adb shell su -c 'cat /sys/class/power_supply/battery/charging_enabled'
adb shell su -c 'cat /data/adb/battery-charge-control.log'
```

With a healthy battery already above the stop threshold, the expected result
is battery charging disabled while external input remains enabled. Do not treat
one observation as complete qualification. Observe temperature, reported
capacity, charging state, USB/ADB stability, NAS service health, and Photos
operation over a full natural cycle.

## Disable and recover

```bash
Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/install-battery-charge-control.sh \
  --disable
```

This creates a persistent root-owned disable marker and asks the installed
service to restore the kernel defaults `start=0`, `stop=100`. It retains the
configuration and service for inspection and later re-enablement. Reinstalling
a valid configuration removes the marker.

The parameters are volatile and reset when the kernel restarts. A permanent
hard brick is therefore not a credible failure mode for the parameter writes.
The persistent service must nevertheless be reboot-tested before it is called
qualified. Reboot only with explicit operator approval.

## Acceptance tests

Before unattended use, require all of the following:

1. `make check` passes, including Bash/Dash configuration and rollback tests.
2. The exact two module parameters exist, are writable by root, and read back
   the requested pair.
3. Applying an upper threshold below the current healthy charge stops battery
   charging without setting `charging_enabled` to zero.
4. Restoring `0/100` permits charging again when OEM safety state allows it.
5. Reapplying the configured pair succeeds without starting a resident process.
6. Battery temperature and health remain acceptable during observation.
7. USB debugging, the NAS service, MediaStore, and Photos remain stable.
8. After explicit approval, one reboot reapplies the exact values and leaves
   exactly one NAS service with all expected mounts.
9. A longer mains-powered soak covers a natural threshold transition or records
   plainly that the battery remains held near the upper threshold.
