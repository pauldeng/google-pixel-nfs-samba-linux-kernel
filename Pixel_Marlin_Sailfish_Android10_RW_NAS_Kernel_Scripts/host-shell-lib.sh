#!/usr/bin/env bash

# Quote one complete command as one POSIX-shell argument. Host scripts use this
# before passing commands through adb shell to su -c.
# shellcheck disable=SC2329 # Public function sourced by companion host scripts.
quote_remote_command() {
  local value=${1//\'/\'\\\'\'}
  printf "'%s'" "$value"
}
