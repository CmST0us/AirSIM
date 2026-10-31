#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ZIG=${ZIG:-zig}
test "$("$ZIG" version)" = 0.15.2
python3 scripts/prepare_vendor.py
mkdir -p dist
repo=../../..
lc3="$repo/third_party/liblc3"
codec="$repo/shared/lc3"
"$ZIG" cc -target aarch64-linux-musl -static -O2 -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Wl,-s -Ivendor/tinyalsa/include -Ivendor/tinyalsa/src src/audiod.c src/protocol.c src/audio_format.c dist/tinyalsa/pcm.c vendor/tinyalsa/src/pcm_hw.c vendor/tinyalsa/src/limits.c vendor/tinyalsa/src/snd_card_plugin.c -I"$codec" -I"$lc3/include" -DLC3_PLUS=0 -DLC3_PLUS_HR=0 "$codec/airsim_lc3.c" "$lc3"/src/*.c -lm -pthread -o dist/airsim-audiod
shasum -a 256 dist/airsim-audiod
