# Repository layout

```text
AI_AGENT_RUNBOOK.md
Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Action_Plan.md
Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/
  source-lock.env
  host-shell-lib.sh
  nas-kernel.config
  setup-host-ubuntu-20.04.sh
  build-kernel.sh
  device-package.sh
  device-deploy.sh
  90-nas-mount.sh
  test-nas-mount.sh
  install-sepolicy-module.sh
  install-nas-service.sh
  check-nas-namespace.sh
  verify-nas-service.sh
  unmount-nas.sh
  stage-photos.sh
  nas-mount-*.conf.example
  nas-smb.secret.example
  SHA256SUMS
```

Executable logic is intentionally kept out of the Markdown plan. The plan defines policy, ordering, evidence, and stop conditions; the companion directory contains the implementation.

Every host script that passes a complete command through `adb shell` to `su -c` sources `host-shell-lib.sh`; the regression suite rejects a return to hand-built nested single quotes.
