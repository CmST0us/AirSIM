#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
CC=${CC:-cc}
mkdir -p dist
"$CC" -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined tests/cadence-options-test.c -o dist/cadence-options-test
./dist/cadence-options-test
