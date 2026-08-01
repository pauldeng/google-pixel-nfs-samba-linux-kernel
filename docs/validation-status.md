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

Still unvalidated. These are open items, not mandatory gates for the parts already proven:

- rollback (the image is verified and preserved but has not been exercised);
- NFSv3 against a real export;
- the experimental direct-mount-into-shared-storage path;
- overnight Doze behaviour.

Each remains a gate for the specific capability it covers: do not rely on rollback, NFSv3, or the direct shared-storage mount until the matching item is exercised.
