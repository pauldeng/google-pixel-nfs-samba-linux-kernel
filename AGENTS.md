# AGENTS.md

Single source of truth for any AI agent working in this repository. Provider-neutral. `CLAUDE.md` imports this file; do not duplicate content there.

## Project

Builds a custom Linux 3.18 kernel with built-in NFSv3 and CIFS/SMB2 clients for the first-generation Google Pixel (`sailfish`) and Pixel XL (`marlin`) on Android 10 `QP1A.191005.007.A3`, then mounts a NAS share so photos can reach Google Photos at original quality. The phone is a dedicated, mains-powered, LAN-only appliance.

This flashes a boot partition on real hardware. Mistakes cost the user a device, not a test run.

## Start here

1. [`docs/ai-agent-runbook.md`](docs/ai-agent-runbook.md) — execution order, exact commands, and every trap already hit on hardware. **Read before running anything.**
2. [`docs/action-plan.md`](docs/action-plan.md) — policy, reasoning, acceptance gates.
3. [`docs/validation-status.md`](docs/validation-status.md) — what is proven versus assumed.

**Precedence when documents disagree:** the deployment policy in `docs/action-plan.md` is normative for anything touching temporary boot, flashing or rollback. The runbook gives the procedure, never a different rule. If you find a contradiction, treat it as a bug, follow the action plan, and say so.

## Commands

```bash
make check          # formatting, ShellCheck, regression tests, checksum coverage
make format         # apply shfmt + rumdl
```

`make check` must pass before every commit. Tooling (`shfmt`, `rumdl`, `shellcheck`) is version- and SHA-256-pinned and installs itself into the gitignored `.tools/`.

## Conventions

- Executable logic lives in `Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/`, never inside Markdown.
- After changing any file in that directory, regenerate its manifest:

  ```bash
  cd Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts
  sha256sum $(find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | sort) > SHA256SUMS
  ```

  `tests/test-companion-manifest.sh` fails if the manifest and the delivered files disagree.
- Host scripts are Bash; device scripts are `#!/system/bin/sh` and must stay POSIX-compatible, because Android runs mksh.
- Route every remote command through `quote_remote_command` in `host-shell-lib.sh`. Never hand-build `adb shell "su -c '…'"`.
- `source-lock.env` is immutable input. Report a mismatch; never edit it to match a checkout.
- Operator credentials belong in `pixel-nas-operator-config/` (gitignored, mode `0600`), never in the integrity-covered script directory.

## Hard rules

- **Never invent a flash or rollback token.** The scripts print them. Do not type one on the user's behalf without explicit authorisation for that specific action.
- **Never flash both slots.** One tested slot only.
- **Never reset, clean, or delete a user checkout** or a dirty managed worktree.
- **Never disable SELinux** or add a broad allow rule. Derive narrow rules from observed AVC evidence only.
- **Never suggest `sudo adb`.** Fix udev instead.
- Keep the authoritative NAS data read-only at both server and client.
- Delete only uniquely named disposable probe paths.

## Interacting with the user

Assume nothing is inferred. Say exactly which button, exactly when, or say explicitly not to touch the device.

| Situation | Tell the user |
|---|---|
| A script is running | "Do not press anything. The script reboots the phone itself." |
| A failed run stranded the phone at the bootloader | "Press the power button to select Start." |
| Phone hangs on the Google logo beyond ~60 s | "Hold Power + Volume-Down until it restarts." |
| A step needs `sudo` | They must run it in a **real terminal**. `sudo` has no TTY in the agent harness or behind the `!` prefix. |
| A long build is running | Give the expected duration (~35 min on 4 cores) so they do not interrupt it. |

SELinux commands (`magiskpolicy`, `install-sepolicy-module.sh`) are frequently blocked by harness permission classifiers. Do not work around a denial. Explain what the command does and hand the user a `!` one-liner.

## Reporting

- Verify before claiming success. Prefer evidence the user can check: checksums, `/proc/mounts`, `uname -r`, MediaStore rows.
- If a step is skipped or fails, say so plainly with the output. Do not narrate a plan as though it were a result.
- Correct your own earlier claims when hardware contradicts them; several in this repo's history were wrong and the corrections are recorded in the commit log.
