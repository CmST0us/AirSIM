#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
CC=${CC:-cc}
mkdir -p dist
"$CC" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -fsanitize=address,undefined -Isrc src/protocol.c tests/protocol_test.c -o dist/protocol-test
./dist/protocol-test
python3 scripts/prepare_vendor.py
"$CC" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -fsanitize=address,undefined -Itests/include -Isrc -Ivendor/tinyalsa/include src/protocol.c src/audio_format.c tests/pcm_flow_test.c -pthread -o dist/pcm-flow-test
./dist/pcm-flow-test
python3 scripts/prepare_state_test.py
for variant in original patched; do
  "$CC" -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -I"dist/state-$variant" tests/pcm_state_test.c -o "dist/pcm-state-$variant-test"
done
set +e
./dist/pcm-state-original-test
original_result=$?
set -e
test "$original_result" -eq 1
./dist/pcm-state-patched-test
"$CC" -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -fsanitize=address,undefined -Isrc src/audio_format.c tests/audio_format_test.c -o dist/audio-format-test
./dist/audio-format-test
