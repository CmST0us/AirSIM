#!/usr/bin/env bash
set -euo pipefail
ZIG="${ZIG:-/tmp/airsim-deploy-tools/zig-aarch64-macos-0.15.2/zig}"
args=()
for a in "$@"; do
  case "$a" in
    --target=*) ;;
    *) args+=("$a") ;;
  esac
done
exec "$ZIG" cc -target arm-linux-musleabihf -mcpu=cortex_a7 "${args[@]}"
