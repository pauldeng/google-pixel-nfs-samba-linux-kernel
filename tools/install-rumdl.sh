#!/usr/bin/env bash
set -euo pipefail

readonly RUMDL_VERSION="0.2.47"
readonly OUTPUT_PATH="${1:-.tools/bin/rumdl}"

if [[ -x $OUTPUT_PATH && $("$OUTPUT_PATH" --version) == "rumdl $RUMDL_VERSION" ]]; then
  exit 0
fi

case "$(uname -m)" in
  x86_64 | amd64)
    readonly RUMDL_ARCH="x86_64"
    readonly RUMDL_SHA256="55d8eebb1d0f77157de374def175b1ae7db395c36d62fa08f0503311c58cbe5d"
    ;;
  aarch64 | arm64)
    readonly RUMDL_ARCH="aarch64"
    readonly RUMDL_SHA256="a27fda498a684caae5aecd5fb41d8d6eb1690787f218c2b2bf909dc394b7f6e5"
    ;;
  *)
    echo "ERROR: unsupported rumdl host architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

readonly RUMDL_NAME="rumdl-v${RUMDL_VERSION}-${RUMDL_ARCH}-unknown-linux-gnu.tar.gz"
readonly RUMDL_URL="https://github.com/rvben/rumdl/releases/download/v${RUMDL_VERSION}/${RUMDL_NAME}"
RUMDL_TMP=$(mktemp -d)
readonly RUMDL_TMP
cleanup() { rm -rf -- "$RUMDL_TMP"; }
trap cleanup EXIT INT TERM

curl --fail --location --silent --show-error "$RUMDL_URL" --output "$RUMDL_TMP/$RUMDL_NAME"
printf '%s  %s\n' "$RUMDL_SHA256" "$RUMDL_NAME" | (cd "$RUMDL_TMP" && sha256sum --check -)
tar -xzf "$RUMDL_TMP/$RUMDL_NAME" -C "$RUMDL_TMP"
mkdir -p "$(dirname -- "$OUTPUT_PATH")"
install -m 0755 "$RUMDL_TMP/rumdl" "$OUTPUT_PATH"
"$OUTPUT_PATH" --version
