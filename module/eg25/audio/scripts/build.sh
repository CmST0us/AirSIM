#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ZIG=${ZIG:-zig}
shared=../../rm500/audio
python3 "$shared/scripts/prepare_vendor.py"
mkdir -p dist
repo=../../..
lc3="$repo/third_party/liblc3"
codec="$repo/shared/lc3"
"$ZIG" cc -target arm-linux-musleabi -mcpu=cortex_a7 -static -O2 -std=c11 -DAIRSIM_EG25 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Wl,-s -I"$shared/vendor/tinyalsa/include" -I"$shared/vendor/tinyalsa/src" "$shared/src/audiod.c" "$shared/src/protocol.c" "$shared/src/audio_format.c" route.c "$shared/dist/tinyalsa/pcm.c" "$shared/vendor/tinyalsa/src/pcm_hw.c" "$shared/vendor/tinyalsa/src/limits.c" "$shared/vendor/tinyalsa/src/snd_card_plugin.c" -I"$codec" -I"$lc3/include" -DLC3_PLUS=0 -DLC3_PLUS_HR=0 "$codec/airsim_lc3.c" "$lc3"/src/*.c -lm -pthread -o dist/airsim-audiod
