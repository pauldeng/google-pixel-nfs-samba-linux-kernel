# Repository layout

```text
AGENTS.md                  single source of truth for AI agents
CLAUDE.md                  imports AGENTS.md
docs/
  ai-agent-runbook.md
  action-plan.md
  safety-model.md
  quick-start.md
  validation-status.md
  reliability-test-plan.md
  device-identification.md
  repository-layout.md
  development.md
  references.md
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
  install-magisk-boot.sh
  install-sepolicy-module.sh
  install-nas-service.sh
  check-nas-namespace.sh
  verify-nas-service.sh
  unmount-nas.sh
  96-nas-photos.sh
  install-nas-photos.sh
  97-battery-charge-control.sh
  install-battery-charge-control.sh
  battery-charge-control.conf.example
  nas-mount-*.conf.example
  nas-photos.conf.example
  nas-smb.secret.example
  SHA256SUMS
tools/
  monitor-nas-photos-soak.sh
```

Executable logic is intentionally kept out of the Markdown plan. The plan defines policy, ordering, evidence, and stop conditions; the companion directory contains the implementation.

Every host script that passes a complete command through `adb shell` to `su -c` sources `host-shell-lib.sh`; the regression suite rejects a return to hand-built nested single quotes.
