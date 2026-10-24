#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ZIG=${ZIG:-/tmp/airsim-r3-toolchain/zig-aarch64-macos-0.15.2/zig}
test "$("$ZIG" version)" = 0.15.2
python3 scripts/prepare_vendor.py
mkdir -p dist
"$ZIG" cc -target aarch64-linux-musl -static -O2 -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -Wl,-s -Ivendor/tinyalsa/include -Ivendor/tinyalsa/src tests/pcm-cadence-probe.c dist/tinyalsa/pcm.c vendor/tinyalsa/src/pcm_hw.c vendor/tinyalsa/src/limits.c vendor/tinyalsa/src/snd_card_plugin.c -pthread -o dist/pcm-cadence-probe
shasum -a 256 dist/pcm-cadence-probe
