# Pixel NAS Kernel

A custom Linux 3.18 kernel with built-in NFSv3 and CIFS/SMB2 clients for the first-generation Google Pixel, turning a retired phone into a dedicated appliance that uploads photos from a NAS to Google Photos at original quality.

- Pixel XL (`marlin`) and Pixel (`sailfish`)
- Android 10 `QP1A.191005.007.A3`
- Requires an unlocked bootloader and Magisk root

Verified on hardware: kernel flashed, NAS mounted read-only over SMB 3.0, mount surviving reboots and network loss, photo uploaded at original quality. See [validation status](docs/validation-status.md) for what is proven versus assumed.

**This flashes a boot partition and can make the phone unbootable.** The workflow keeps a checksummed rollback image and gates the flash behind explicit tokens, but read the [safety model](docs/safety-model.md) before connecting a device.

| Document | Purpose |
|---|---|
| [AI agent runbook](docs/ai-agent-runbook.md) | Execution order, exact commands, every trap already hit on hardware |
| [Action plan](docs/action-plan.md) | Policy, reasoning, and acceptance gates |
| [Safety model](docs/safety-model.md) | Non-negotiable controls and the recommended data flow |
| [Quick start](docs/quick-start.md) | Host setup, build, device workflow, NAS testing |
| [Validation status](docs/validation-status.md) | Proven on hardware versus still unproven |
| [Device identification](docs/device-identification.md) | Confirming the model and unlockability |
| [Repository layout](docs/repository-layout.md) | Where everything lives |
| [Development](docs/development.md) | Formatting, linting, and the `make check` gate |
| [References](docs/references.md) | Historical context |

## Using an AI agent

This project is built to be driven by an AI coding agent. Instructions live in [`AGENTS.md`](AGENTS.md), the provider-neutral single source of truth. [`CLAUDE.md`](CLAUDE.md) imports it, so Claude Code, Codex, and any agent honouring either convention get identical guidance with nothing to keep in sync.

The agent needs to be able to:

- **Run shell commands** on an Ubuntu 20.04 host with `adb` and `fastboot` available
- **Reach the phone over USB** and the NAS over the LAN
- **Hand `sudo` steps back to you.** `sudo` has no TTY inside an agent harness, so package installs must be run by you in a real terminal
- **Hand SELinux steps back to you.** Permission classifiers commonly block `magiskpolicy` and `install-sepolicy-module.sh`; a well-behaved agent explains the command and lets you run it rather than working around the denial

You should expect it to:

- Tell you **exactly when to press a button on the phone, and when not to touch it**
- Never invent a flash or rollback token
- Verify with evidence you can check, rather than asserting success

## Recommended prompt

Paste this to start a session:

```text
This repository builds a custom Android 10 kernel with NFS and CIFS support for a
first-generation Google Pixel, so the phone can mount a NAS share and upload photos
to Google Photos at original quality.

Read AGENTS.md first, then docs/ai-agent-runbook.md in full before running anything.
The runbook records traps already hit on real hardware; do not rediscover them.

Then tell me:
  1. which phase we are at, based on the current state of the repo and the phone
  2. what you intend to do next and why
  3. anything you need from me, especially sudo or SELinux steps you cannot run

Rules: verify with evidence rather than assuming. Tell me exactly when to press a
button on the phone and when not to touch it. Never invent a flash or rollback
token. Run `make check` before any commit.
```

If you are resuming rather than starting fresh, add:

```text
Start by checking git log, the phone state over adb, and docs/validation-status.md
to work out what is already done. Do not repeat completed steps.
```
