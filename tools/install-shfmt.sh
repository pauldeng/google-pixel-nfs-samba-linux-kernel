#!/usr/bin/env bash
set -euo pipefail

readonly SHFMT_VERSION="3.13.1"
readonly OUTPUT_PATH="${1:-.tools/bin/shfmt}"

if [[ -x $OUTPUT_PATH && $("$OUTPUT_PATH" --version) == "v$SHFMT_VERSION" ]]; then
  exit 0
fi

case "$(uname -m)" in
  x86_64 | amd64)
    readonly SHFMT_ARCH="amd64"
    readonly SHFMT_SHA256="fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1"
    ;;
  aarch64 | arm64)
    readonly SHFMT_ARCH="arm64"
    readonly SHFMT_SHA256="32d92acaa5cd8abb29fc49dac123dc412442d5713967819d8af2c29f1b3857c7"
    ;;
  *)
    echo "ERROR: unsupported shfmt host architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

readonly SHFMT_NAME="shfmt_v${SHFMT_VERSION}_linux_${SHFMT_ARCH}"
readonly SHFMT_URL="https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/${SHFMT_NAME}"
SHFMT_TMP=$(mktemp -d)
readonly SHFMT_TMP
cleanup() { rm -rf -- "$SHFMT_TMP"; }
trap cleanup EXIT INT TERM

curl --fail --location --silent --show-error "$SHFMT_URL" --output "$SHFMT_TMP/$SHFMT_NAME"
printf '%s  %s\n' "$SHFMT_SHA256" "$SHFMT_NAME" | (cd "$SHFMT_TMP" && sha256sum --check -)
mkdir -p "$(dirname -- "$OUTPUT_PATH")"
install -m 0755 "$SHFMT_TMP/$SHFMT_NAME" "$OUTPUT_PATH"
"$OUTPUT_PATH" --version
