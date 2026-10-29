#!/bin/sh
set -eu
: "${KERNEL_SRC:?Set KERNEL_SRC to the prepared QDC507 Linux 3.18.44 tree}"
: "${CROSS_COMPILE:?Set CROSS_COMPILE to the ARM EABI compiler prefix}"
directory=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
make -C "$KERNEL_SRC" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" \
  CC="${CROSS_COMPILE}gcc" HOSTCFLAGS=-fcommon KCFLAGS='-fno-pie -fno-pic' \
  M="$directory" modules
