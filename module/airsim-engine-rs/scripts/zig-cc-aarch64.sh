#!/usr/bin/env bash
set -euo pipefail
ZIG="${ZIG:-/tmp/airsim-deploy-tools/zig-aarch64-macos-0.15.2/zig}"
args=()
for a in "$@"; do
  case "$a" in
    --target=*|-Wl,--fix-cortex-a53-843419) ;;
    *) args+=("$a") ;;
  esac
done
exec "$ZIG" cc -target aarch64-linux-musl "${args[@]}"
