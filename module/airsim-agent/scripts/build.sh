#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
GO=${GO:-go}
mkdir -p dist
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOPROXY=off GOTOOLCHAIN=local "$GO" build -trimpath -ldflags='-s -w' -o dist/airsim-agent ./cmd/airsim-agent
shasum -a 256 dist/airsim-agent
