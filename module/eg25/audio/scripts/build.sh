#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ZIG=${ZIG:-zig}
shared=../../rm500/audio
python3 "$shared/scripts/prepare_vendor.py"
mkdir -p dist
opus=../../../third_party/opus
python3 "$shared/scripts/build_opus.py" dist/opus-armv7.a "$ZIG ar" "$ZIG" cc -target arm-linux-musleabi -mcpu=cortex_a7
"$ZIG" cc -target arm-linux-musleabi -mcpu=cortex_a7 -static -O2 -std=c11 -DAIRSIM_EG25 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Wl,-s -I"$shared/vendor/tinyalsa/include" -I"$shared/vendor/tinyalsa/src" -I"$opus/include" "$shared/src/audiod.c" "$shared/src/protocol.c" "$shared/src/audio_format.c" "$shared/src/opus_codec.c" route.c "$shared/dist/tinyalsa/pcm.c" "$shared/vendor/tinyalsa/src/pcm_hw.c" "$shared/vendor/tinyalsa/src/limits.c" "$shared/vendor/tinyalsa/src/snd_card_plugin.c" dist/opus-armv7.a -lm -pthread -o dist/airsim-audiod
