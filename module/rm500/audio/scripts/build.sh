#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ZIG=${ZIG:-zig}
test "$("$ZIG" version)" = 0.15.2
python3 scripts/prepare_vendor.py
mkdir -p dist
opus=../../../third_party/opus
python3 scripts/build_opus.py dist/opus-aarch64.a "$ZIG ar" "$ZIG" cc -target aarch64-linux-musl
"$ZIG" cc -target aarch64-linux-musl -static -O2 -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Wl,-s -Ivendor/tinyalsa/include -Ivendor/tinyalsa/src -I"$opus/include" src/audiod.c src/protocol.c src/audio_format.c src/opus_codec.c dist/tinyalsa/pcm.c vendor/tinyalsa/src/pcm_hw.c vendor/tinyalsa/src/limits.c vendor/tinyalsa/src/snd_card_plugin.c dist/opus-aarch64.a -lm -pthread -o dist/airsim-audiod
shasum -a 256 dist/airsim-audiod
