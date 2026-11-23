#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
chmod +x "$ROOT/scripts/zig-cc-aarch64.sh" "$ROOT/scripts/zig-ar.sh" "$ROOT/scripts/airsim-audiod-shim.sh"
export CC_aarch64_unknown_linux_musl="$ROOT/scripts/zig-cc-aarch64.sh"
export AR_aarch64_unknown_linux_musl="$ROOT/scripts/zig-ar.sh"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$ROOT/scripts/zig-cc-aarch64.sh"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C target-feature=+crt-static -C link-self-contained=no -C link-arg=-static -C link-arg=-Wl,-s"
cd "$ROOT"
cargo build --release --target aarch64-unknown-linux-musl
mkdir -p "$ROOT/dist/rm500u"
cp "$ROOT/target/aarch64-unknown-linux-musl/release/airsim-agent" "$ROOT/dist/rm500u/airsim-agent"
cp "$ROOT/scripts/airsim-audiod-shim.sh" "$ROOT/dist/rm500u/airsim-audiod"
chmod 0755 "$ROOT/dist/rm500u/airsim-agent" "$ROOT/dist/rm500u/airsim-audiod"
ls -lh "$ROOT/dist/rm500u/airsim-agent" "$ROOT/dist/rm500u/airsim-audiod"
