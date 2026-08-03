# Development and formatting

All Bash and POSIX shell scripts are formatted with [`shfmt`](https://github.com/mvdan/sh), statically checked with [ShellCheck](https://github.com/koalaman/shellcheck), and Markdown is formatted and linted with [`rumdl`](https://github.com/rvben/rumdl). The repository pins shfmt v3.13.1, ShellCheck v0.11.0, and rumdl v0.2.47, then verifies the official Linux release SHA-256 values before installing each tool under the ignored `.tools/` directory.

Run both formatters after every shell or Markdown edit:

```bash
make format
```

Run every non-mutating quality and regression check before committing:

```bash
make check
```

The regression suite includes the native battery-threshold parser and
transaction tests under both Bash and Dash. Invalid, duplicate, injected, and
partially applied configurations must leave the simulated kernel parameters at
their previous values.

The individual formatting targets are `format-shell`, `check-shell-format`, `format-markdown`, and `check-markdown`; `check-shellcheck` runs static analysis. Policy is stored in `.editorconfig` and `.rumdl.toml`; `shfmt` detects Bash and POSIX dialects from each script's shebang. GitHub Actions runs `make check` whenever Markdown, shell scripts, tests, or quality configuration changes.
