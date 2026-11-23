#!/bin/sh
set -eu
ZIG="${ZIG:-/tmp/airsim-deploy-tools/zig-aarch64-macos-0.15.2/zig}"
exec "$ZIG" ar "$@"
