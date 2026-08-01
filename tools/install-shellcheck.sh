#!/usr/bin/env bash
set -euo pipefail

readonly SHELLCHECK_VERSION="0.11.0"
readonly OUTPUT_PATH="${1:-.tools/bin/shellcheck}"

if [[ -x $OUTPUT_PATH && $("$OUTPUT_PATH" --version | awk '/^version:/ {print $2}') == "$SHELLCHECK_VERSION" ]]; then
  exit 0
fi

case "$(uname -m)" in
  x86_64 | amd64)
    readonly SHELLCHECK_ARCH="x86_64"
    readonly SHELLCHECK_SHA256="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
    ;;
  aarch64 | arm64)
    readonly SHELLCHECK_ARCH="aarch64"
    readonly SHELLCHECK_SHA256="12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588"
    ;;
  *)
    echo "ERROR: unsupported ShellCheck host architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

readonly SHELLCHECK_BASENAME="shellcheck-v${SHELLCHECK_VERSION}"
readonly SHELLCHECK_NAME="${SHELLCHECK_BASENAME}.linux.${SHELLCHECK_ARCH}.tar.xz"
readonly SHELLCHECK_URL="https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/${SHELLCHECK_NAME}"
SHELLCHECK_TMP=$(mktemp -d)
readonly SHELLCHECK_TMP
cleanup() { rm -rf -- "$SHELLCHECK_TMP"; }
trap cleanup EXIT INT TERM

curl --fail --location --silent --show-error "$SHELLCHECK_URL" --output "$SHELLCHECK_TMP/$SHELLCHECK_NAME"
printf '%s  %s\n' "$SHELLCHECK_SHA256" "$SHELLCHECK_NAME" | (cd "$SHELLCHECK_TMP" && sha256sum --check -)
tar -xJf "$SHELLCHECK_TMP/$SHELLCHECK_NAME" -C "$SHELLCHECK_TMP"
mkdir -p "$(dirname -- "$OUTPUT_PATH")"
install -m 0755 "$SHELLCHECK_TMP/$SHELLCHECK_BASENAME/shellcheck" "$OUTPUT_PATH"
"$OUTPUT_PATH" --version | sed -n '1,2p'
