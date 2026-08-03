SHFMT ?= .tools/bin/shfmt
RUMDL ?= .tools/bin/rumdl
SHELLCHECK ?= .tools/bin/shellcheck
SHELL_SCRIPTS := $(sort $(wildcard Pixel_Marlin_Sailfish_Android10_RW_NAS_Kernel_Scripts/*.sh tests/*.sh tools/*.sh))

.PHONY: bootstrap-shfmt bootstrap-rumdl bootstrap-shellcheck format-shell check-shell-format check-shellcheck format-markdown check-markdown test-mount-probe test-photo-scan test-battery-control test-remote-quote test-deploy-gates test-companion-manifest format check-format check

bootstrap-shfmt:
	tools/install-shfmt.sh "$(SHFMT)"

bootstrap-rumdl:
	tools/install-rumdl.sh "$(RUMDL)"

bootstrap-shellcheck:
	tools/install-shellcheck.sh "$(SHELLCHECK)"

format-shell: bootstrap-shfmt
	"$(SHFMT)" -w $(SHELL_SCRIPTS)

check-shell-format: bootstrap-shfmt
	"$(SHFMT)" -d $(SHELL_SCRIPTS)

check-shellcheck: bootstrap-shellcheck
	"$(SHELLCHECK)" -x -P SCRIPTDIR $(SHELL_SCRIPTS)

format-markdown: bootstrap-rumdl
	"$(RUMDL)" fmt .

check-markdown: bootstrap-rumdl
	"$(RUMDL)" check .

test-mount-probe: check-shell-format
	bash tests/test-nas-mount-probe.sh
	dash tests/test-nas-mount-probe.sh

test-photo-scan: check-shell-format
	bash tests/test-nas-photos-scan.sh
	dash tests/test-nas-photos-scan.sh

test-battery-control: check-shell-format
	bash tests/test-battery-charge-control.sh
	dash tests/test-battery-charge-control.sh

test-remote-quote: check-shell-format
	bash tests/test-remote-quote.sh

test-deploy-gates: check-shell-format
	bash tests/test-deploy-gates.sh

test-companion-manifest:
	bash tests/test-companion-manifest.sh

format: format-shell format-markdown

check-format: check-shell-format check-markdown

check: check-format check-shellcheck test-mount-probe test-photo-scan test-battery-control test-remote-quote test-deploy-gates test-companion-manifest
