#!/usr/bin/env bash
set -euo pipefail

if [[ ! -r /etc/os-release ]]; then
  echo "ERROR: cannot identify the host operating system" >&2
  exit 1
fi
. /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 20.04 ]]; then
  echo "ERROR: Ubuntu 20.04 is required; found ${PRETTY_NAME:-unknown}" >&2
  exit 1
fi

packages=(
  adb fastboot android-sdk-platform-tools-common git build-essential bc
  libssl-dev libelf-dev libncurses5-dev libncursesw5-dev liblz4-tool
  rsync unzip zip curl openssl sqlite3
)
missing=()
for package in "${packages[@]}"; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed' || missing+=("$package")
done
if ((${#missing[@]})); then
  echo "Installing missing packages: ${missing[*]}"
  sudo apt-get update
  sudo apt-get install --no-install-recommends "${missing[@]}"
else
  echo "All required packages are already installed"
fi

for command_name in adb fastboot git make sha256sum lz4c curl unzip openssl sqlite3; do
  command -v "$command_name" >/dev/null || {
    echo "ERROR: required command is unavailable after setup: $command_name" >&2
    exit 1
  }
done

if ! getent group plugdev >/dev/null; then
  sudo groupadd plugdev
fi
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx plugdev; then
  sudo usermod -aG plugdev "$USER"
  echo "Added $USER to plugdev. Log out and back in, then rerun this script."
  exit 10
fi

sudo udevadm control --reload-rules
sudo udevadm trigger
adb version
fastboot --version
echo "Host setup complete"
