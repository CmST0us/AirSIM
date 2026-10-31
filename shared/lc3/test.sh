#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
codec_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/airsim-lc3-test.XXXXXX")
trap 'rm -rf "$codec_test_dir"' EXIT HUP INT TERM
"${CC:-cc}" -O2 -std=c11 -Wall -Wextra -fsanitize=address,undefined \
  -DLC3_PLUS=0 -DLC3_PLUS_HR=0 -Ithird_party/liblc3/include -Ishared/lc3 \
  shared/lc3/airsim_lc3.c shared/lc3/tests/codec_test.c third_party/liblc3/src/*.c \
  -lm -o "$codec_test_dir/codec-test"
UBSAN_OPTIONS=halt_on_error=1 "$codec_test_dir/codec-test"
