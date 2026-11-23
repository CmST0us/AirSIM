#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
chmod +x "$ROOT/scripts/zig-cc-armv7.sh" "$ROOT/scripts/zig-ar.sh" "$ROOT/scripts/airsim-audiod-shim.sh"
export CC_armv7_unknown_linux_musleabihf="$ROOT/scripts/zig-cc-armv7.sh"
export AR_armv7_unknown_linux_musleabihf="$ROOT/scripts/zig-ar.sh"
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER="$ROOT/scripts/zig-cc-armv7.sh"
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_RUSTFLAGS="-C target-cpu=cortex-a7 -C target-feature=+crt-static -C link-self-contained=no -C link-arg=-static -C link-arg=-Wl,-s"
cd "$ROOT"
cargo build --release --target armv7-unknown-linux-musleabihf
mkdir -p "$ROOT/dist/eg25"
cp "$ROOT/target/armv7-unknown-linux-musleabihf/release/airsim-agent" "$ROOT/dist/eg25/airsim-agent"
cp "$ROOT/scripts/airsim-audiod-shim.sh" "$ROOT/dist/eg25/airsim-audiod"
chmod 0755 "$ROOT/dist/eg25/airsim-agent" "$ROOT/dist/eg25/airsim-audiod"
ls -lh "$ROOT/dist/eg25/airsim-agent" "$ROOT/dist/eg25/airsim-audiod"
