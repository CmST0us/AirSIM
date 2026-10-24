#!/bin/sh
set -eu
cd "$(dirname "$0")"
GO=${GO:-go}
mkdir -p dist
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 "$GO" build -trimpath -ldflags='-s -w' -o dist/rm500-linux-arm64 .
if [ "${1:-}" = "--all" ]; then
  CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 "$GO" build -trimpath -ldflags='-s -w' -o dist/rm500-linux-armv7 .
fi
